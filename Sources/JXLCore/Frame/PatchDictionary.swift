// PatchDictionary.swift
//
// The patch dictionary (ISO/IEC 18181-1 §C.4.5; libjxl dec_patch_dictionary):
// rectangular crops of previously stored reference frames, blended onto the
// presented frame at entropy-coded positions. Decoded from the head of the
// DC-global section when the frame header sets kPatches (flags bit 2), before
// DequantMatrices.DecodeDC. Rendering happens after the restoration filters
// and before the color transform, so patches operate in the frame's encoded
// color space (XYB for lossy files).

import Foundation

/// A reference frame decoded to pre-color-transform XYB planes (row-major,
/// width×height), the space patches blend in.
struct ReferenceXYBFrame {
    let width: Int
    let height: Int
    let x: [Float]
    let y: [Float]
    let b: [Float]
}

/// PatchBlendMode (dec_patch_dictionary.h). Alpha-driven modes fall back to
/// their alpha-free semantics when the image has no alpha channel (libjxl
/// PerformBlending `has_alpha == false`): kBlend* copies the patch, and
/// kAlphaWeightedAdd* adds it.
enum PatchBlendMode: UInt32 {
    case none = 0
    case replace = 1
    case add = 2
    case mul = 3
    case blendAbove = 4
    case blendBelow = 5
    case alphaWeightedAddAbove = 6
    case alphaWeightedAddBelow = 7

    static let count: UInt32 = 8

    var usesAlpha: Bool {
        self == .blendAbove || self == .blendBelow
            || self == .alphaWeightedAddAbove || self == .alphaWeightedAddBelow
    }
    var usesClamp: Bool { usesAlpha || self == .mul }
}

struct PatchBlending {
    var mode: PatchBlendMode
    var alphaChannel: UInt32
    var clamp: Bool
}

/// Position and size of a patch's source crop in its reference frame.
struct PatchReferencePosition {
    let ref: Int
    let x0: Int
    let y0: Int
    let xsize: Int
    let ysize: Int
}

/// One placement of a reference crop in the presented frame.
struct PatchPosition {
    let x: Int
    let y: Int
    let refPosIndex: Int
}

struct PatchDictionary {
    let refPositions: [PatchReferencePosition]
    let positions: [PatchPosition]
    /// `blendingsStride` entries per position: color first, then one per extra
    /// channel.
    let blendings: [PatchBlending]
    let blendingsStride: Int

    var isEmpty: Bool { positions.isEmpty }
}

// Context numbers (§C.4.5 Listing C.2; patch_dictionary_internal.h).
private let kNumRefPatchContext = 0
private let kReferenceFrameContext = 1
private let kPatchSizeContext = 2
private let kPatchReferencePositionContext = 3
private let kPatchPositionContext = 4
private let kPatchBlendModeContext = 5
private let kPatchOffsetContext = 6
private let kPatchCountContext = 7
private let kPatchAlphaChannelContext = 8
private let kPatchClampContext = 9
private let kNumPatchDictionaryContexts = 10

private let kMaxNumReferenceFrames = 4

/// Mirrors `PatchDictionary::Decode`. `xsize`/`ysize` are the padded frame
/// dimensions; `referenceSize` reports the stored dimensions of a reference
/// slot (nil when the slot is empty).
func decodePatchDictionary(
    _ br: BitReader, xsize: Int, ysize: Int, numExtraChannels: Int,
    referenceSize: (Int) -> (width: Int, height: Int)?
) throws -> PatchDictionary {
    let blendingsStride = numExtraChannels + 1
    guard
        let (code, contextMap) = decodeHistograms(
            br, numContexts: kNumPatchDictionaryContexts, disallowLZ77: false)
    else { throw JXLError.malformed("could not read patch dictionary histograms") }
    let decoder = ANSSymbolReader(code: code, reader: br)
    func readNum(_ context: Int) -> Int {
        Int(decoder.readHybridUint(context, br, contextMap: contextMap))
    }

    let numRefPatch = readNum(kNumRefPatchContext)
    // Limit max memory usage of patches to about 66 bytes per pixel.
    let numPixels = xsize * ysize
    let maxRefPatches = 1024 + numPixels / 4
    let maxPatches = maxRefPatches * 4
    let maxBlendingInfos = maxPatches * 4
    guard numRefPatch <= maxRefPatches else {
        throw JXLError.malformed("too many patches in dictionary")
    }

    var refPositions: [PatchReferencePosition] = []
    var positions: [PatchPosition] = []
    var blendings: [PatchBlending] = []
    var totalPatches = 0
    var nextSize = 1

    for _ in 0..<numRefPatch {
        let ref = readNum(kReferenceFrameContext)
        guard ref < kMaxNumReferenceFrames, let refDim = referenceSize(ref) else {
            throw JXLError.malformed("invalid patch reference frame ID")
        }
        let x0 = readNum(kPatchReferencePositionContext)
        let y0 = readNum(kPatchReferencePositionContext)
        let pxsize = readNum(kPatchSizeContext) + 1
        let pysize = readNum(kPatchSizeContext) + 1
        guard x0 + pxsize <= refDim.width, y0 + pysize <= refDim.height else {
            throw JXLError.malformed("invalid position specified in reference frame")
        }
        var idCount = readNum(kPatchCountContext)
        guard idCount <= maxPatches else {
            throw JXLError.malformed("too many patches in dictionary")
        }
        idCount += 1
        totalPatches += idCount
        guard totalPatches <= maxPatches else {
            throw JXLError.malformed("too many patches in dictionary")
        }
        if nextSize < totalPatches {
            nextSize = min(nextSize * 2, maxPatches)
        }
        guard nextSize * blendingsStride <= maxBlendingInfos else {
            throw JXLError.malformed("too many patches in dictionary")
        }
        positions.reserveCapacity(nextSize)
        blendings.reserveCapacity(nextSize * blendingsStride)

        let chooseAlpha = numExtraChannels > 1
        for i in 0..<idCount {
            var px: Int
            var py: Int
            if i == 0 {
                px = readNum(kPatchPositionContext)
                py = readNum(kPatchPositionContext)
            } else {
                let deltaX = unpackSignedPatch(readNum(kPatchOffsetContext))
                let deltaY = unpackSignedPatch(readNum(kPatchOffsetContext))
                px = positions[positions.count - 1].x + deltaX
                py = positions[positions.count - 1].y + deltaY
                guard px >= 0, py >= 0 else {
                    throw JXLError.malformed("invalid patch: negative coordinate")
                }
            }
            guard px + pxsize <= xsize, py + pysize <= ysize else {
                throw JXLError.malformed("invalid patch position \(px),\(py)")
            }
            for _ in 0..<blendingsStride {
                let rawMode = readNum(kPatchBlendModeContext)
                guard rawMode < Int(PatchBlendMode.count),
                    let mode = PatchBlendMode(rawValue: UInt32(rawMode))
                else { throw JXLError.malformed("invalid patch blend mode") }
                var alphaChannel: UInt32 = 0
                if mode.usesAlpha && chooseAlpha {
                    alphaChannel = UInt32(readNum(kPatchAlphaChannelContext))
                    guard alphaChannel < UInt32(numExtraChannels) else {
                        throw JXLError.malformed("invalid alpha channel for blending")
                    }
                }
                var clamp = false
                if mode.usesClamp {
                    clamp = readNum(kPatchClampContext) != 0
                }
                blendings.append(
                    PatchBlending(mode: mode, alphaChannel: alphaChannel, clamp: clamp))
            }
            positions.append(PatchPosition(x: px, y: py, refPosIndex: refPositions.count))
        }
        refPositions.append(
            PatchReferencePosition(ref: ref, x0: x0, y0: y0, xsize: pxsize, ysize: pysize))
    }

    guard decoder.checkANSFinalState() else {
        throw JXLError.malformed("patch dictionary ANS checksum failure")
    }
    return PatchDictionary(
        refPositions: refPositions, positions: positions, blendings: blendings,
        blendingsStride: blendingsStride)
}

private func unpackSignedPatch(_ u: Int) -> Int {
    let v = UInt64(u)
    let magnitude = Int(v >> 1)
    return (v & 1) == 1 ? -magnitude - 1 : magnitude
}

// MARK: - Rendering

/// Blends every patch onto the reconstructed XYB image (libjxl stage_patches +
/// PerformBlending, color channels only — the dictionary decode rejects
/// patches that touch extra channels). Patches are applied in dictionary
/// order, which preserves the relative order of overlapping patches.
func renderPatches(
    _ dict: PatchDictionary, into image: inout XYBImage,
    reference: (Int) throws -> ReferenceXYBFrame
) throws {
    guard !dict.isEmpty else { return }

    // Decode each referenced frame once up front.
    var refs: [Int: ReferenceXYBFrame] = [:]
    for refPos in dict.refPositions where refs[refPos.ref] == nil {
        refs[refPos.ref] = try reference(refPos.ref)
    }

    let width = image.width
    let height = image.height
    let stride = image.stride
    var blendError: JXLError? = nil

    image.x.withUnsafeMutableBufferPointer { bx in
        image.y.withUnsafeMutableBufferPointer { by in
            image.b.withUnsafeMutableBufferPointer { bb in
                let planes = [bx.baseAddress!, by.baseAddress!, bb.baseAddress!]
                for (index, pos) in dict.positions.enumerated() {
                    let refPos = dict.refPositions[pos.refPosIndex]
                    let ref = refs[refPos.ref]!
                    let blending = dict.blendings[index * dict.blendingsStride]
                    guard blending.mode != .none else { continue }
                    // This renderer carries color planes only; alpha- or
                    // extra-channel-involving blends need the full-plane
                    // renderer (native modular path).
                    for j in 0..<dict.blendingsStride {
                        let b = dict.blendings[index * dict.blendingsStride + j]
                        if b.mode.usesAlpha || (b.mode != .none && j > 0) {
                            blendError = JXLError.unsupported(
                                "patches touching extra channels in VarDCT frames")
                        }
                    }
                    guard blendError == nil else { break }
                    // Clip to the visible region (patches may reach into the
                    // block padding, which is never displayed).
                    let y1 = min(pos.y + refPos.ysize, height)
                    let x1 = min(pos.x + refPos.xsize, width)
                    guard pos.y < y1, pos.x < x1 else { continue }
                    let fgPlanes = [ref.x, ref.y, ref.b]
                    for c in 0..<3 {
                        let out = planes[c]
                        fgPlanes[c].withUnsafeBufferPointer { fgBuf in
                            let fg = fgBuf.baseAddress!
                            for y in pos.y..<y1 {
                                let outRow = y * stride
                                let fgRow = (refPos.y0 + y - pos.y) * ref.width + refPos.x0 - pos.x
                                blendPatchRow(
                                    out: out, fg: fg, outRow: outRow, fgRow: fgRow,
                                    x0: pos.x, x1: x1, mode: blending.mode,
                                    clamp: blending.clamp)
                            }
                        }
                    }
                }
            }
        }
    }
    if let e = blendError { throw e }
}

/// Full-plane patch rendering (libjxl stage_patches + blending.cc
/// PerformBlending, all eight PatchBlendModes including the alpha-driven and
/// "below" variants): blends every patch onto image-sized float planes
/// (3 color + one per extra channel). Used by native-space Modular frames,
/// whose pipeline carries every channel. References must supply the same
/// plane layout.
func renderPatchesMulti(
    _ dict: PatchDictionary, planes: inout [[Float]], width: Int, height: Int,
    extraChannels: [JXLExtraChannelInfo],
    reference: (Int) throws -> FloatFrame
) throws {
    guard !dict.isEmpty else { return }
    let numEC = extraChannels.count
    precondition(planes.count == 3 + numEC)

    var refs: [Int: FloatFrame] = [:]
    for refPos in dict.refPositions where refs[refPos.ref] == nil {
        refs[refPos.ref] = try reference(refPos.ref)
    }

    for (index, pos) in dict.positions.enumerated() {
        let refPos = dict.refPositions[pos.refPosIndex]
        let ref = refs[refPos.ref]!
        guard ref.planes.count == 3 + numEC else {
            throw JXLError.malformed("patch reference frame channel layout")
        }
        let base = index * dict.blendingsStride
        let colorInfo = dict.blendings[base]
        let ecInfo = Array(dict.blendings[(base + 1)..<(base + dict.blendingsStride)])
        // Clip to the visible region (positions are validated against the
        // padded frame, which extends past the visible edge).
        let y1 = min(pos.y + refPos.ysize, height)
        let x1 = min(pos.x + refPos.xsize, width)
        guard pos.y < y1, pos.x < x1 else { continue }
        let count = x1 - pos.x
        for y in pos.y..<y1 {
            let outOffset = y * width + pos.x
            let fgOffset = (refPos.y0 + y - pos.y) * ref.width + refPos.x0
            performPatchBlendRow(
                bg: planes, bgOffset: outOffset, fg: ref.planes, fgOffset: fgOffset,
                out: &planes, outOffset: outOffset, count: count,
                colorInfo: colorInfo, ecInfo: ecInfo, extraChannels: extraChannels)
        }
    }
}

/// One row of blending.cc PerformBlending in the full 8-mode PatchBlendMode
/// space. `bg`/`fg` are full plane arrays (color first, then extras) read at
/// the given offsets; results land in `out` (which may alias `bg` — a
/// temporary row is used, as in libjxl). "Below" modes swap the layer roles;
/// alpha-weighted adds of the alpha channel onto itself reduce to the
/// background copy (alpha.cc's `fg == fga` shortcut).
private func performPatchBlendRow(
    bg: [[Float]], bgOffset: Int, fg: [[Float]], fgOffset: Int,
    out: inout [[Float]], outOffset: Int, count: Int,
    colorInfo: PatchBlending, ecInfo: [PatchBlending],
    extraChannels: [JXLExtraChannelInfo]
) {
    guard count > 0 else { return }
    let numEC = ecInfo.count
    var hasAlpha = false
    for info in extraChannels where info.type == 0 { hasAlpha = true }
    var tmp = [[Float]](repeating: [Float](repeating: 0, count: count), count: 3 + numEC)

    // Row segment helpers over the array+offset views.
    func withRow(_ src: [[Float]], _ c: Int, _ off: Int, _ body: (UnsafePointer<Float>) -> Void) {
        src[c].withUnsafeBufferPointer { body($0.baseAddress! + off) }
    }
    func intoTmp(_ c: Int, _ body: (UnsafeMutablePointer<Float>) -> Void) {
        tmp[c].withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
    func copyRow(_ src: [[Float]], _ c: Int, _ off: Int, into t: Int) {
        tmp[t].replaceSubrange(0..<count, with: src[c][off..<(off + count)])
    }

    // Extra channels first (pre-blending alpha is what color blending reads).
    for i in 0..<numEC {
        let info = ecInfo[i]
        let c = 3 + i
        let a = 3 + Int(info.alphaChannel)
        switch info.mode {
        case .add:
            withRow(bg, c, bgOffset) { bgp in
                withRow(fg, c, fgOffset) { fgp in
                    intoTmp(c) { outp in
                        for x in 0..<count { outp[x] = bgp[x] + fgp[x] }
                    }
                }
            }
        case .blendAbove:
            let premult = extraChannels[Int(info.alphaChannel)].alphaAssociated
            if c == a {
                withRow(bg, a, bgOffset) { bgap in
                    withRow(fg, a, fgOffset) { fgap in
                        intoTmp(c) { outp in
                            alphaBlendAlpha(
                                bga: bgap, fga: fgap, out: outp, count: count, clamp: info.clamp)
                        }
                    }
                }
            } else {
                withRow(bg, c, bgOffset) { bgp in
                withRow(bg, a, bgOffset) { bgap in
                withRow(fg, c, fgOffset) { fgp in
                withRow(fg, a, fgOffset) { fgap in
                    intoTmp(c) { outp in
                        alphaBlendColor(
                            bg: bgp, bga: bgap, fg: fgp, fga: fgap, out: outp,
                            count: count, premultiplied: premult, clamp: info.clamp)
                    }
                }
                }
                }
                }
            }
        case .blendBelow:
            let premult = extraChannels[Int(info.alphaChannel)].alphaAssociated
            if c == a {
                withRow(fg, a, fgOffset) { bgap in
                    withRow(bg, a, bgOffset) { fgap in
                        intoTmp(c) { outp in
                            alphaBlendAlpha(
                                bga: bgap, fga: fgap, out: outp, count: count, clamp: info.clamp)
                        }
                    }
                }
            } else {
                withRow(fg, c, fgOffset) { bgp in
                withRow(fg, a, fgOffset) { bgap in
                withRow(bg, c, bgOffset) { fgp in
                withRow(bg, a, bgOffset) { fgap in
                    intoTmp(c) { outp in
                        alphaBlendColor(
                            bg: bgp, bga: bgap, fg: fgp, fga: fgap, out: outp,
                            count: count, premultiplied: premult, clamp: info.clamp)
                    }
                }
                }
                }
                }
            }
        case .alphaWeightedAddAbove:
            if c == a {
                copyRow(bg, c, bgOffset, into: c)  // alpha.cc fg == fga shortcut
            } else {
                withRow(bg, c, bgOffset) { bgp in
                withRow(fg, c, fgOffset) { fgp in
                withRow(fg, a, fgOffset) { fgap in
                    intoTmp(c) { outp in
                        alphaWeightedAdd(
                            bg: bgp, fg: fgp, fga: fgap, out: outp, count: count,
                            clamp: info.clamp)
                    }
                }
                }
                }
            }
        case .alphaWeightedAddBelow:
            if c == a {
                copyRow(fg, c, fgOffset, into: c)  // roles swapped, same shortcut
            } else {
                withRow(fg, c, fgOffset) { bgp in
                withRow(bg, c, bgOffset) { fgp in
                withRow(bg, a, bgOffset) { fgap in
                    intoTmp(c) { outp in
                        alphaWeightedAdd(
                            bg: bgp, fg: fgp, fga: fgap, out: outp, count: count,
                            clamp: info.clamp)
                    }
                }
                }
                }
            }
        case .mul:
            withRow(bg, c, bgOffset) { bgp in
                withRow(fg, c, fgOffset) { fgp in
                    intoTmp(c) { outp in
                        mulBlend(bg: bgp, fg: fgp, out: outp, count: count, clamp: info.clamp)
                    }
                }
            }
        case .replace:
            copyRow(fg, c, fgOffset, into: c)
        case .none:
            copyRow(bg, c, bgOffset, into: c)
        }
    }

    // Color channels (the alpha-weighted blends also rewrite the alpha plane,
    // per PerformAlphaBlending's four-plane form).
    let a = 3 + Int(colorInfo.alphaChannel)
    func addColor() {
        for c in 0..<3 {
            withRow(bg, c, bgOffset) { bgp in
                withRow(fg, c, fgOffset) { fgp in
                    intoTmp(c) { outp in
                        for x in 0..<count { outp[x] = bgp[x] + fgp[x] }
                    }
                }
            }
        }
    }
    func copyColor(_ src: [[Float]], _ off: Int) {
        for c in 0..<3 { copyRow(src, c, off, into: c) }
    }
    func blendWeighted(bottom: [[Float]], bottomOff: Int, top: [[Float]], topOff: Int) {
        let premult = extraChannels[Int(colorInfo.alphaChannel)].alphaAssociated
        for c in 0..<3 {
            withRow(bottom, c, bottomOff) { bgp in
            withRow(bottom, a, bottomOff) { bgap in
            withRow(top, c, topOff) { fgp in
            withRow(top, a, topOff) { fgap in
                intoTmp(c) { outp in
                    alphaBlendColor(
                        bg: bgp, bga: bgap, fg: fgp, fga: fgap, out: outp,
                        count: count, premultiplied: premult, clamp: colorInfo.clamp)
                }
            }
            }
            }
            }
        }
        withRow(bottom, a, bottomOff) { bgap in
            withRow(top, a, topOff) { fgap in
                intoTmp(a) { outp in
                    alphaBlendAlpha(
                        bga: bgap, fga: fgap, out: outp, count: count, clamp: colorInfo.clamp)
                }
            }
        }
    }
    func addWeighted(bottom: [[Float]], bottomOff: Int, top: [[Float]], topOff: Int) {
        for c in 0..<3 {
            withRow(bottom, c, bottomOff) { bgp in
            withRow(top, c, topOff) { fgp in
            withRow(top, a, topOff) { fgap in
                intoTmp(c) { outp in
                    alphaWeightedAdd(
                        bg: bgp, fg: fgp, fga: fgap, out: outp, count: count,
                        clamp: colorInfo.clamp)
                }
            }
            }
            }
        }
    }

    switch colorInfo.mode {
    case .add:
        addColor()
    case .alphaWeightedAddAbove:
        if hasAlpha {
            addWeighted(bottom: bg, bottomOff: bgOffset, top: fg, topOff: fgOffset)
        } else { addColor() }
    case .alphaWeightedAddBelow:
        if hasAlpha {
            addWeighted(bottom: fg, bottomOff: fgOffset, top: bg, topOff: bgOffset)
        } else { addColor() }
    case .blendAbove:
        if hasAlpha {
            blendWeighted(bottom: bg, bottomOff: bgOffset, top: fg, topOff: fgOffset)
        } else { copyColor(fg, fgOffset) }
    case .blendBelow:
        if hasAlpha {
            blendWeighted(bottom: fg, bottomOff: fgOffset, top: bg, topOff: bgOffset)
        } else { copyColor(fg, fgOffset) }
    case .mul:
        for c in 0..<3 {
            withRow(bg, c, bgOffset) { bgp in
                withRow(fg, c, fgOffset) { fgp in
                    intoTmp(c) { outp in
                        mulBlend(bg: bgp, fg: fgp, out: outp, count: count, clamp: colorInfo.clamp)
                    }
                }
            }
        }
    case .replace:
        copyColor(fg, fgOffset)
    case .none:
        copyColor(bg, bgOffset)
    }

    for c in 0..<(3 + numEC) {
        out[c].replaceSubrange(outOffset..<(outOffset + count), with: tmp[c])
    }
}

/// One row of color blending, alpha-free semantics (PerformBlending with
/// `has_alpha == false`).
private func blendPatchRow(
    out: UnsafeMutablePointer<Float>, fg: UnsafePointer<Float>,
    outRow: Int, fgRow: Int, x0: Int, x1: Int, mode: PatchBlendMode, clamp: Bool
) {
    switch mode {
    case .none:
        break
    case .replace, .blendAbove, .blendBelow:
        for x in x0..<x1 { out[outRow + x] = fg[fgRow + x] }
    case .add, .alphaWeightedAddAbove, .alphaWeightedAddBelow:
        for x in x0..<x1 { out[outRow + x] += fg[fgRow + x] }
    case .mul:
        if clamp {
            for x in x0..<x1 {
                out[outRow + x] *= min(max(fg[fgRow + x], 0), 1)
            }
        } else {
            for x in x0..<x1 { out[outRow + x] *= fg[fgRow + x] }
        }
    }
}
