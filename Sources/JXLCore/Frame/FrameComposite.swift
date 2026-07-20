// FrameComposite.swift
//
// Frame-level blending for animations (libjxl stage_blending.cc +
// blending.cc PerformBlending + alpha.cc): each presented frame composites
// onto an image-sized canvas taken from a reference slot, honoring the
// frame's crop/origin, per-channel blend modes, and alpha semantics, all on
// transfer-encoded float samples (blending runs after the color transform).
// `JXL.decodeFrames` drives the sequential loop and stores composited frames
// back into reference slots for later frames.

import Foundation

/// One frame's pixels as float planes in the output (encoded) space:
/// 3 color planes plus the extra channels, each `width*height` row-major.
struct FloatFrame {
    let width: Int
    let height: Int
    var planes: [[Float]]
}

/// The composition canvas: image-sized float planes (3 color + extras).
struct FrameCanvas {
    let width: Int
    let height: Int
    var planes: [[Float]]

    init(width: Int, height: Int, channels: Int) {
        self.width = width
        self.height = height
        planes = Array(
            repeating: [Float](repeating: 0, count: width * height), count: channels)
    }
}

// MARK: - alpha.cc primitives (exact ports, including the clamp quirk in the
// alpha-plane variant, which is what djxl executes)

@inline(__always)
func clamp01(_ x: Float) -> Float { max(min(1, x), 0) }

/// Color blend with alpha (PerformAlphaBlending, separate-channel form).
func alphaBlendColor(
    bg: UnsafePointer<Float>, bga: UnsafePointer<Float>,
    fg: UnsafePointer<Float>, fga: UnsafePointer<Float>,
    out: UnsafeMutablePointer<Float>, count: Int, premultiplied: Bool, clamp: Bool
) {
    if premultiplied {
        for x in 0..<count {
            let fa = clamp ? clamp01(fga[x]) : fga[x]
            out[x] = fg[x] + bg[x] * (1 - fa)
        }
    } else {
        for x in 0..<count {
            let fa = clamp ? clamp01(fga[x]) : fga[x]
            let newA = 1 - (1 - fa) * (1 - bga[x])
            let rNewA = newA > 0 ? 1 / newA : 0
            out[x] = (fg[x] * fa + bg[x] * bga[x] * (1 - fa)) * rNewA
        }
    }
}

/// Alpha-plane blend (PerformAlphaBlending where bg==bga and fg==fga).
/// libjxl v0.11 had the clamp condition inverted here; v0.12 fixed it —
/// we follow v0.12 (clamp means clamp).
func alphaBlendAlpha(
    bga: UnsafePointer<Float>, fga: UnsafePointer<Float>,
    out: UnsafeMutablePointer<Float>, count: Int, clamp: Bool
) {
    for x in 0..<count {
        let fa = clamp ? clamp01(fga[x]) : fga[x]
        out[x] = 1 - (1 - fa) * (1 - bga[x])
    }
}

func alphaWeightedAdd(
    bg: UnsafePointer<Float>, fg: UnsafePointer<Float>, fga: UnsafePointer<Float>,
    out: UnsafeMutablePointer<Float>, count: Int, clamp: Bool
) {
    if clamp {
        for x in 0..<count { out[x] = bg[x] + fg[x] * clamp01(fga[x]) }
    } else {
        for x in 0..<count { out[x] = bg[x] + fg[x] * fga[x] }
    }
}

func mulBlend(
    bg: UnsafePointer<Float>, fg: UnsafePointer<Float>,
    out: UnsafeMutablePointer<Float>, count: Int, clamp: Bool
) {
    if clamp {
        for x in 0..<count { out[x] = bg[x] * clamp01(fg[x]) }
    } else {
        for x in 0..<count { out[x] = bg[x] * fg[x] }
    }
}

// MARK: - PerformBlending (frame flavor: modes 0-4 mapped per stage_blending)

/// Blends one row segment. `bg` and `fg` are per-channel row pointers (color
/// first, then extras); `out` overwrites in place. All arrays are `count`
/// samples. Mirrors blending.cc PerformBlending with the frame BlendMode
/// mapping (kBlend -> kBlendAbove, kAlphaWeightedAdd -> ...AddAbove).
private func blendRowSegment(
    bg: [[Float]], bgOffsets: [Int], fg: [[Float]], fgOffsets: [Int],
    out: inout [[Float]], outOffset: Int, count: Int,
    colorInfo: JXLBlendingInfo, ecInfo: [JXLBlendingInfo],
    extraChannels: [JXLExtraChannelInfo]
) {
    guard count > 0 else { return }
    let numEC = ecInfo.count
    var hasAlpha = false
    for info in extraChannels where info.type == 0 { hasAlpha = true }

    // Temporary rows (blend into temp, then copy — matches libjxl, which
    // needs this because out may alias bg or fg).
    var tmp = [[Float]](repeating: [Float](repeating: 0, count: count), count: 3 + numEC)

    // Extra channels first (pre-blending alpha is what color blending reads).
    for i in 0..<numEC {
        let info = ecInfo[i]
        let c = 3 + i
        bg[c].withUnsafeBufferPointer { bgBuf in
        fg[c].withUnsafeBufferPointer { fgBuf in
        tmp[c].withUnsafeMutableBufferPointer { outBuf in
            let bgp = bgBuf.baseAddress! + bgOffsets[c]
            let fgp = fgBuf.baseAddress! + fgOffsets[c]
            let outp = outBuf.baseAddress!
            switch info.mode {
            case 1:  // kAdd
                for x in 0..<count { outp[x] = bgp[x] + fgp[x] }
            case 2:  // kBlend
                let a = 3 + Int(info.alphaChannel)
                let premult = extraChannels[Int(info.alphaChannel)].alphaAssociated
                bg[a].withUnsafeBufferPointer { bgaBuf in
                fg[a].withUnsafeBufferPointer { fgaBuf in
                    let bgap = bgaBuf.baseAddress! + bgOffsets[a]
                    let fgap = fgaBuf.baseAddress! + fgOffsets[a]
                    if c == a {
                        alphaBlendAlpha(
                            bga: bgap, fga: fgap, out: outp, count: count, clamp: info.clamp)
                    } else {
                        alphaBlendColor(
                            bg: bgp, bga: bgap, fg: fgp, fga: fgap, out: outp,
                            count: count, premultiplied: premult, clamp: info.clamp)
                    }
                }
                }
            case 3:  // kAlphaWeightedAdd
                let a = 3 + Int(info.alphaChannel)
                fg[a].withUnsafeBufferPointer { fgaBuf in
                    alphaWeightedAdd(
                        bg: bgp, fg: fgp, fga: fgaBuf.baseAddress! + fgOffsets[a],
                        out: outp, count: count, clamp: info.clamp)
                }
            case 4:  // kMul
                mulBlend(bg: bgp, fg: fgp, out: outp, count: count, clamp: info.clamp)
            default:  // kReplace
                for x in 0..<count { outp[x] = fgp[x] }
            }
        }
        }
        }
    }

    // Color channels.
    let alphaIdx = 3 + Int(colorInfo.alphaChannel)
    switch colorInfo.mode {
    case 1:  // kAdd
        for c in 0..<3 {
            for x in 0..<count { tmp[c][x] = bg[c][bgOffsets[c] + x] + fg[c][fgOffsets[c] + x] }
        }
    case 2:  // kBlend (kBlendAbove)
        if hasAlpha {
            let premult = extraChannels[Int(colorInfo.alphaChannel)].alphaAssociated
            for c in 0..<3 {
                bg[c].withUnsafeBufferPointer { bgBuf in
                fg[c].withUnsafeBufferPointer { fgBuf in
                bg[alphaIdx].withUnsafeBufferPointer { bgaBuf in
                fg[alphaIdx].withUnsafeBufferPointer { fgaBuf in
                tmp[c].withUnsafeMutableBufferPointer { outBuf in
                    alphaBlendColor(
                        bg: bgBuf.baseAddress! + bgOffsets[c],
                        bga: bgaBuf.baseAddress! + bgOffsets[alphaIdx],
                        fg: fgBuf.baseAddress! + fgOffsets[c],
                        fga: fgaBuf.baseAddress! + fgOffsets[alphaIdx],
                        out: outBuf.baseAddress!, count: count,
                        premultiplied: premult, clamp: colorInfo.clamp)
                }
                }
                }
                }
                }
            }
        } else {
            for c in 0..<3 {
                for x in 0..<count { tmp[c][x] = fg[c][fgOffsets[c] + x] }
            }
        }
    case 3:  // kAlphaWeightedAdd
        if hasAlpha {
            for c in 0..<3 {
                bg[c].withUnsafeBufferPointer { bgBuf in
                fg[c].withUnsafeBufferPointer { fgBuf in
                fg[alphaIdx].withUnsafeBufferPointer { fgaBuf in
                tmp[c].withUnsafeMutableBufferPointer { outBuf in
                    alphaWeightedAdd(
                        bg: bgBuf.baseAddress! + bgOffsets[c],
                        fg: fgBuf.baseAddress! + fgOffsets[c],
                        fga: fgaBuf.baseAddress! + fgOffsets[alphaIdx],
                        out: outBuf.baseAddress!, count: count, clamp: colorInfo.clamp)
                }
                }
                }
                }
            }
        } else {
            for c in 0..<3 {
                for x in 0..<count { tmp[c][x] = bg[c][bgOffsets[c] + x] + fg[c][fgOffsets[c] + x] }
            }
        }
    case 4:  // kMul
        for c in 0..<3 {
            bg[c].withUnsafeBufferPointer { bgBuf in
            fg[c].withUnsafeBufferPointer { fgBuf in
            tmp[c].withUnsafeMutableBufferPointer { outBuf in
                mulBlend(
                    bg: bgBuf.baseAddress! + bgOffsets[c],
                    fg: fgBuf.baseAddress! + fgOffsets[c],
                    out: outBuf.baseAddress!, count: count, clamp: colorInfo.clamp)
            }
            }
            }
        }
    default:  // kReplace
        for c in 0..<3 {
            for x in 0..<count { tmp[c][x] = fg[c][fgOffsets[c] + x] }
        }
    }

    for c in 0..<(3 + numEC) {
        out[c].replaceSubrange(outOffset..<(outOffset + count), with: tmp[c])
    }
}

// MARK: - Whole-frame composition (stage_blending ProcessRow + padding rows)

/// Composites `fg` (the decoded frame, positioned at `origin` in image space)
/// onto image-sized output planes: rows/columns outside the frame copy the
/// background reference; covered segments blend per the header's infos.
/// `references` returns the canvas saved in a slot (nil = never written =
/// zeros background).
func compositeFrame(
    fg: FloatFrame, header: FrameHeader, imageWidth: Int, imageHeight: Int,
    extraChannels: [JXLExtraChannelInfo],
    references: (Int) -> FrameCanvas?
) -> FrameCanvas {
    let numEC = extraChannels.count
    let channels = 3 + numEC
    var out = FrameCanvas(width: imageWidth, height: imageHeight, channels: channels)

    // Per-channel background canvases: color from the color source, each EC
    // from its own source (stage_blending).
    let colorBG = references(Int(header.blendingInfo.source))
    var ecBGs: [FrameCanvas?] = []
    for i in 0..<numEC {
        let source = i < header.ecBlendingInfo.count ? Int(header.ecBlendingInfo[i].source) : 0
        ecBGs.append(references(source))
    }
    let zeroRow = [Float](repeating: 0, count: imageWidth)

    @inline(__always) func bgPlane(_ c: Int) -> [Float]? {
        c < 3 ? colorBG?.planes[c] : ecBGs[c - 3].map { $0.planes[c] }
    }

    let originX = Int(header.frameX0)
    let originY = Int(header.frameY0)

    for y in 0..<imageHeight {
        // Background fill for the whole row first.
        for c in 0..<channels {
            if let bg = bgPlane(c) {
                out.planes[c].replaceSubrange(
                    (y * imageWidth)..<(y * imageWidth + imageWidth),
                    with: bg[(y * imageWidth)..<(y * imageWidth + imageWidth)])
            } else {
                out.planes[c].replaceSubrange(
                    (y * imageWidth)..<(y * imageWidth + imageWidth), with: zeroRow)
            }
        }
        // Covered segment of this row, if any.
        let fy = y - originY
        guard fy >= 0, fy < fg.height else { continue }
        var bgX = originX
        var fgX = 0
        var count = fg.width
        if bgX < 0 {
            fgX -= bgX
            count += bgX
            bgX = 0
        }
        count = min(count, imageWidth - bgX)
        guard count > 0 else { continue }

        // Build per-channel bg/fg row views. bg rows read from `out` (already
        // background-filled), which matches libjxl blending in place over fg
        // with bg pointers into the reference.
        var bgRows: [[Float]] = []
        var bgOffsets: [Int] = []
        var fgRows: [[Float]] = []
        var fgOffsets: [Int] = []
        for c in 0..<channels {
            bgRows.append(bgPlane(c) ?? zeroRow)
            bgOffsets.append(bgPlane(c) != nil ? y * imageWidth + bgX : 0)
            fgRows.append(fg.planes[c])
            fgOffsets.append(fy * fg.width + fgX)
        }
        blendRowSegment(
            bg: bgRows, bgOffsets: bgOffsets, fg: fgRows, fgOffsets: fgOffsets,
            out: &out.planes, outOffset: y * imageWidth + bgX, count: count,
            colorInfo: header.blendingInfo, ecInfo: header.ecBlendingInfo,
            extraChannels: extraChannels)
    }
    return out
}

// MARK: - Canvas -> JXLDecodedImage quantization

/// Quantizes an encoded-space canvas to the requested output format.
/// `dither` applies blue-noise dithering to the 8-bit color channels
/// (extra channels come from native integers — dithering them is a no-op by
/// construction, so they keep the plain round).
func quantizeCanvas(
    _ canvas: FrameCanvas, colorChannels: Int, extraChannels: Int,
    format: JXLSampleFormat, dither: Bool = false
) -> JXLDecodedImage {
    let n = canvas.width * canvas.height
    let width = canvas.width
    var planes: [[Int32]] = []
    for (c, plane) in canvas.planes.enumerated() {
        var out = [Int32](repeating: 0, count: n)
        switch format {
        case .uint8:
            if dither && c < colorChannels {
                for i in 0..<n {
                    out[i] = Int32(ditherQuantize8(plane[i], i % width, i / width, c))
                }
                break
            }
            for i in 0..<n { out[i] = Int32((clamp01(plane[i]) * 255).rounded()) }
        case .uint16:
            for i in 0..<n { out[i] = Int32((clamp01(plane[i]) * 65535).rounded()) }
        case .float32:
            for i in 0..<n { out[i] = Int32(bitPattern: plane[i].bitPattern) }
        }
        planes.append(out)
    }
    let bits: Int
    let isFloat: Bool
    switch format {
    case .uint8:
        bits = 8
        isFloat = false
    case .uint16:
        bits = 16
        isFloat = false
    case .float32:
        bits = 32
        isFloat = true
    }
    return JXLDecodedImage(
        width: canvas.width, height: canvas.height, colorChannels: colorChannels,
        extraChannels: extraChannels, bitsPerSample: bits, isFloat: isFloat,
        planes: planes, iccProfile: nil)
}
