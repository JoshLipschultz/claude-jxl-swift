// Transforms.swift
//
// Inverse Modular transforms (libjxl modular/transform/*). Transforms are undone
// in reverse order after the channels are decoded. So far: the reversible color
// transform (RCT, 42 types = 6 permutations × 7 mixings, incl. YCoCg).
// Palette and Squeeze undo are not yet implemented.

import Foundation

/// Applies a transform's channel-layout change before decoding (libjxl
/// Transform::MetaApply). RCT keeps the layout; Palette collapses channels into
/// an index plane plus a palette meta-channel.
/// libjxl `CheckEqualChannels`: the channel range must lie within the image and
/// every channel in it must match the first one's dimensions. Transforms index
/// with stream-controlled `begin_c`/`num_c`, so this is the bounds gate for
/// hostile input.
private func checkEqualChannels(_ image: ModularImage, _ begin: Int, _ end: Int) -> Bool {
    guard begin >= 0, begin <= end, end < image.channels.count else { return false }
    let first = image.channels[begin]
    for c in begin...end {
        let ch = image.channels[c]
        if ch.w != first.w || ch.h != first.h { return false }
    }
    return true
}

func metaApplyTransform(_ image: ModularImage, transform t: inout ModularTransform) throws {
    switch t.id {
    case .rct:
        // No layout change, but validate here so decode never reaches an
        // out-of-range or malformed RCT (libjxl InvRCT: rct_type < 42).
        guard Int(t.rctType) < 42, checkEqualChannels(image, Int(t.beginC), Int(t.beginC) + 2)
        else { throw ModularDecodeError.invalidTransform }
    case .palette:
        guard t.numC >= 1,
            checkEqualChannels(image, Int(t.beginC), Int(t.beginC) + Int(t.numC) - 1)
        else { throw ModularDecodeError.invalidTransform }
        metaPalette(
            image, beginC: Int(t.beginC), endC: Int(t.beginC) + Int(t.numC) - 1,
            nbColors: Int(t.nbColors), nbDeltas: Int(t.nbDeltas))
    case .squeeze:
        try metaSqueeze(image, params: &t.squeezes)
    default:
        throw ModularDecodeError.unsupportedTransform
    }
}

/// Undoes the transforms applied to a decoded Modular image, in reverse order.
/// `wpHeader` is the stream's weighted-predictor header (delta palette with
/// the Weighted predictor runs its own WP state during the undo).
func undoTransforms(
    _ image: ModularImage, transforms: [ModularTransform], wpHeader: WPHeader = WPHeader()
) throws {
    for t in transforms.reversed() {
        switch t.id {
        case .rct:
            invRCT(image, beginC: Int(t.beginC), rctType: Int(t.rctType))
        case .palette:
            try invPalette(
                image, beginC: Int(t.beginC), nbColors: Int(t.nbColors), nbDeltas: Int(t.nbDeltas),
                predictor: Int(t.predictor), wpHeader: wpHeader)
        case .squeeze:
            try invSqueeze(image, params: t.squeezes)
        default:
            throw ModularDecodeError.unsupportedTransform
        }
    }
}

// MARK: - Squeeze (libjxl modular/transform/squeeze.cc)

private let kMaxFirstPreviewSize = 8

/// The default squeeze sequence for an image with no explicit parameters
/// (libjxl DefaultSqueezeParameters): optional 4:2:0-style chroma squeezes,
/// then alternating full-channel-range squeezes until both dimensions are at
/// most 8.
private func defaultSqueezeParameters(_ image: ModularImage) -> [SqueezeParams] {
    let nbChannels = image.channels.count - image.nbMetaChannels
    var parameters: [SqueezeParams] = []
    var w = image.channels[image.nbMetaChannels].w
    var h = image.channels[image.nbMetaChannels].h
    let wide = w > h

    if nbChannels > 2 && image.channels[image.nbMetaChannels + 1].w == w
        && image.channels[image.nbMetaChannels + 1].h == h {
        // Assume channels 1 and 2 are chroma; squeeze them first.
        let beginC = UInt32(image.nbMetaChannels + 1)
        parameters.append(
            SqueezeParams(horizontal: true, inPlace: false, beginC: beginC, numC: 2))
        parameters.append(
            SqueezeParams(horizontal: false, inPlace: false, beginC: beginC, numC: 2))
    }
    var params = SqueezeParams(
        horizontal: true, inPlace: true, beginC: UInt32(image.nbMetaChannels),
        numC: UInt32(nbChannels))
    if !wide && h > kMaxFirstPreviewSize {
        params.horizontal = false
        parameters.append(params)
        h = (h + 1) / 2
    }
    while w > kMaxFirstPreviewSize || h > kMaxFirstPreviewSize {
        if w > kMaxFirstPreviewSize {
            params.horizontal = true
            parameters.append(params)
            w = (w + 1) / 2
        }
        if h > kMaxFirstPreviewSize {
            params.horizontal = false
            parameters.append(params)
            h = (h + 1) / 2
        }
    }
    return parameters
}

private func checkSqueezeParams(_ p: SqueezeParams, channelCount: Int) throws {
    let c1 = Int(p.beginC)
    let c2 = Int(p.beginC) + Int(p.numC) - 1
    guard c1 >= 0, c1 < channelCount, c2 >= 0, c2 < channelCount, c2 >= c1 else {
        throw ModularDecodeError.invalidTransform
    }
}

/// Channel-layout change for Squeeze (libjxl MetaSqueeze): each parameter
/// halves the listed channels in one direction and inserts placeholder
/// residual channels (in place right after the range, or appended).
func metaSqueeze(_ image: ModularImage, params: inout [SqueezeParams]) throws {
    if params.isEmpty {
        guard image.channels.count > image.nbMetaChannels else {
            throw ModularDecodeError.invalidTransform
        }
        params = defaultSqueezeParameters(image)
    }
    for parameter in params {
        try checkSqueezeParams(parameter, channelCount: image.channels.count)
        let beginC = Int(parameter.beginC)
        let endC = beginC + Int(parameter.numC) - 1
        if beginC < image.nbMetaChannels {
            guard endC < image.nbMetaChannels, parameter.inPlace else {
                throw ModularDecodeError.invalidTransform
            }
            image.nbMetaChannels += Int(parameter.numC)
        }
        let offset = parameter.inPlace ? endC + 1 : image.channels.count
        for c in beginC...endC {
            guard image.channels[c].hshift <= 30, image.channels[c].vshift <= 30 else {
                throw ModularDecodeError.invalidTransform
            }
            let w = image.channels[c].w
            let h = image.channels[c].h
            guard w > 0, h > 0 else { throw ModularDecodeError.invalidTransform }
            var residualW = w
            var residualH = h
            if parameter.horizontal {
                image.channels[c].w = (w + 1) / 2
                if image.channels[c].hshift >= 0 { image.channels[c].hshift += 1 }
                residualW = w - (w + 1) / 2
            } else {
                image.channels[c].h = (h + 1) / 2
                if image.channels[c].vshift >= 0 { image.channels[c].vshift += 1 }
                residualH = h - (h + 1) / 2
            }
            image.channels[c].pixels = [Int32](
                repeating: 0, count: max(0, image.channels[c].w * image.channels[c].h))
            var placeholder = ModularChannel(
                w: residualW, h: residualH,
                hshift: image.channels[c].hshift, vshift: image.channels[c].vshift)
            placeholder.pixels = [Int32](repeating: 0, count: max(0, residualW * residualH))
            image.channels.insert(placeholder, at: offset + (c - beginC))
        }
    }
}

/// The squeeze residual predictor (libjxl SmoothTendency): estimates C−D from
/// the previous output pixel, this average, and the next average, with
/// monotonicity clamps that avoid ringing.
@inline(__always)
private func smoothTendency(_ B: Int64, _ a: Int64, _ n: Int64) -> Int64 {
    var diff: Int64 = 0
    if B >= a && a >= n {
        diff = (4 * B - 3 * n - a + 6) / 12
        if diff - (diff & 1) > 2 * (B - a) { diff = 2 * (B - a) + 1 }
        if diff + (diff & 1) > 2 * (a - n) { diff = 2 * (a - n) }
    } else if B <= a && a <= n {
        diff = (4 * B - 3 * n - a - 6) / 12
        if diff + (diff & 1) < 2 * (B - a) { diff = 2 * (B - a) - 1 }
        if diff - (diff & 1) < 2 * (a - n) { diff = 2 * (a - n) }
    }
    return diff
}

/// Undoes one horizontal squeeze of channel `c` using residuals in `rc`.
private func invHSqueeze(_ image: ModularImage, _ c: Int, _ rc: Int) throws {
    let chin = image.channels[c]
    let res = image.channels[rc]
    guard chin.w == (chin.w + res.w + 1) / 2 || chin.w == divCeil(chin.w + res.w, 2),
        chin.h == res.h || res.w == 0 || res.h == 0
    else { throw ModularDecodeError.invalidTransform }

    if res.w == 0 {
        // Output has the same dimensions as the input.
        image.channels[c].hshift -= 1
        return
    }
    var chout = ModularChannel(
        w: chin.w + res.w, h: chin.h, hshift: chin.hshift - 1, vshift: chin.vshift)
    if res.h == 0 {
        image.channels[c] = chout
        return
    }
    chin.pixels.withUnsafeBufferPointer { avgBuf in
    res.pixels.withUnsafeBufferPointer { resBuf in
    chout.pixels.withUnsafeMutableBufferPointer { outBuf in
        nonisolated(unsafe) let avg = avgBuf.baseAddress!
        nonisolated(unsafe) let residual = resBuf.baseAddress!
        nonisolated(unsafe) let out = outBuf.baseAddress!
        let inW = chin.w
        let resW = res.w
        let outW = chin.w + res.w
        DispatchQueue.concurrentPerform(iterations: chin.h) { y in
            let pAvg = avg + y * inW
            let pRes = residual + y * resW
            let pOut = out + y * outW
            for x in 0..<resW {
                let diffMinusTendency = Int64(pRes[x])
                let a = Int64(pAvg[x])
                let nextAvg = x + 1 < inW ? Int64(pAvg[x + 1]) : a
                let left = x > 0 ? Int64(pOut[(x << 1) - 1]) : a
                let tendency = smoothTendency(left, a, nextAvg)
                let diff = diffMinusTendency + tendency
                let A = a + (diff / 2)
                pOut[x << 1] = Int32(truncatingIfNeeded: A)
                pOut[(x << 1) + 1] = Int32(truncatingIfNeeded: A - diff)
            }
            if outW & 1 == 1 { pOut[outW - 1] = pAvg[inW - 1] }
        }
    }
    }
    }
    image.channels[c] = chout
}

/// Undoes one vertical squeeze of channel `c` using residuals in `rc`.
private func invVSqueeze(_ image: ModularImage, _ c: Int, _ rc: Int) throws {
    let chin = image.channels[c]
    let res = image.channels[rc]
    guard chin.h == divCeil(chin.h + res.h, 2), chin.w == res.w || res.w == 0 || res.h == 0
    else { throw ModularDecodeError.invalidTransform }

    if res.h == 0 {
        image.channels[c].vshift -= 1
        return
    }
    var chout = ModularChannel(
        w: chin.w, h: chin.h + res.h, hshift: chin.hshift, vshift: chin.vshift - 1)
    if res.w == 0 {
        image.channels[c] = chout
        return
    }
    chin.pixels.withUnsafeBufferPointer { avgBuf in
    res.pixels.withUnsafeBufferPointer { resBuf in
    chout.pixels.withUnsafeMutableBufferPointer { outBuf in
        nonisolated(unsafe) let avg = avgBuf.baseAddress!
        nonisolated(unsafe) let residual = resBuf.baseAddress!
        nonisolated(unsafe) let out = outBuf.baseAddress!
        let w = chin.w
        let inH = chin.h
        let resH = res.h
        // Columns are independent; split into 64-wide slices (libjxl
        // kColsPerThread) since rows carry the vertical dependency.
        let slices = divCeil(w, 64)
        DispatchQueue.concurrentPerform(iterations: slices) { task in
            let x0 = task * 64
            let x1 = min(x0 + 64, w)
            for y in 0..<resH {
                let pRes = residual + y * w
                let pAvg = avg + y * w
                let pNavg = avg + (y + 1 < inH ? y + 1 : y) * w
                let pOut = out + (y << 1) * w
                let pNout = out + ((y << 1) + 1) * w
                let pPrev: UnsafePointer<Int32> =
                    y > 0 ? UnsafePointer(out + ((y << 1) - 1) * w) : pAvg
                for x in x0..<x1 {
                    let a = Int64(pAvg[x])
                    let nextAvg = Int64(pNavg[x])
                    let top = Int64(pPrev[x])
                    let tendency = smoothTendency(top, a, nextAvg)
                    let diff = Int64(pRes[x]) + tendency
                    let outV = a + (diff / 2)
                    pOut[x] = Int32(truncatingIfNeeded: outV)
                    pNout[x] = Int32(truncatingIfNeeded: outV - diff)
                }
            }
        }
    }
    }
    }
    if chout.h & 1 == 1 {
        let y = chin.h - 1
        for x in 0..<chin.w {
            chout.pixels[(y << 1) * chin.w + x] = chin.pixels[y * chin.w + x]
        }
    }
    image.channels[c] = chout
}

/// Undoes the whole squeeze sequence in reverse order (libjxl InvSqueeze).
func invSqueeze(_ image: ModularImage, params: [SqueezeParams]) throws {
    for parameter in params.reversed() {
        try checkSqueezeParams(parameter, channelCount: image.channels.count)
        let beginC = Int(parameter.beginC)
        let endC = beginC + Int(parameter.numC) - 1
        let offset = parameter.inPlace ? endC + 1 : image.channels.count + beginC - endC - 1
        if beginC < image.nbMetaChannels {
            guard image.nbMetaChannels > Int(parameter.numC) else {
                throw ModularDecodeError.invalidTransform
            }
            image.nbMetaChannels -= Int(parameter.numC)
        }
        for c in beginC...endC {
            let rc = offset + c - beginC
            guard rc < image.channels.count,
                image.channels[c].w >= image.channels[rc].w,
                image.channels[c].h >= image.channels[rc].h
            else { throw ModularDecodeError.invalidTransform }
            if parameter.horizontal {
                try invHSqueeze(image, c, rc)
            } else {
                try invVSqueeze(image, c, rc)
            }
        }
        image.channels.removeSubrange(offset..<(offset + (endC - beginC + 1)))
    }
}

// MARK: - Palette (libjxl modular/transform/palette.cc)

private let kRgbChannels = 3
private let kLargeCube = 5
private let kSmallCube = 4
private let kSmallCubeBits = 2
private let kLargeCubeOffset = kSmallCube * kSmallCube * kSmallCube  // 64

/// Layout change for the Palette transform: replace `numC` channels at `beginC`
/// with a single index channel and prepend a palette meta-channel.
func metaPalette(_ image: ModularImage, beginC: Int, endC: Int, nbColors: Int, nbDeltas: Int) {
    let nb = endC - beginC + 1
    if beginC >= image.nbMetaChannels {
        image.nbMetaChannels += 1
    } else {
        image.nbMetaChannels += 2 - nb
    }
    image.channels.removeSubrange((beginC + 1)..<(endC + 1))
    var palette = ModularChannel(w: nbColors + nbDeltas, h: nb, hshift: -1, vshift: -1)
    palette.pixels = [Int32](repeating: 0, count: (nbColors + nbDeltas) * nb)
    image.channels.insert(palette, at: 0)
}

/// Inverse Palette: reconstruct the color channels by looking each index up in
/// the palette (libjxl InvPalette), including the delta-palette path where
/// indices below `nbDeltas` add the looked-up delta to a per-pixel prediction
/// (any of the 14 predictors; a fresh WP state per channel for Weighted).
func invPalette(
    _ image: ModularImage, beginC: Int, nbColors: Int, nbDeltas: Int, predictor: Int,
    wpHeader: WPHeader
) throws {
    guard !image.channels.isEmpty else { throw ModularDecodeError.unsupportedTransform }

    let nb = image.channels[0].h  // palette height = number of color channels
    let c0 = beginC + 1
    guard nb >= 1, c0 < image.channels.count else { throw ModularDecodeError.unsupportedTransform }
    guard predictor < 14 else { throw ModularDecodeError.invalidTransform }
    let w = image.channels[c0].w
    let h = image.channels[c0].h
    let hshift = image.channels[c0].hshift
    let vshift = image.channels[c0].vshift

    for _ in 1..<max(1, nb) where nb > 1 {
        image.channels.insert(ModularChannel(w: w, h: h, hshift: hshift, vshift: vshift), at: c0 + 1)
    }

    let palette = image.channels[0]
    let onerow = palette.w
    let bitDepth = min(image.bitdepth, 24)
    let indexPlane = image.channels[c0].pixels  // copy (outputs alias the index channel)

    if w == 0 {
        // Nothing to do (avoid touching empty channels with non-zero height).
    } else if nbDeltas == 0 && predictor == 0 {
        for c in 0..<nb {
            for y in 0..<h {
                for x in 0..<w {
                    var index = Int(indexPlane[y * w + x])
                    if nb == 1 {
                        // libjxl clamps out-of-range indices in the
                        // single-channel fast path.
                        index = min(max(index, 0), palette.w - 1)
                    }
                    image.channels[c0 + c].pixels[y * w + x] = getPaletteValue(
                        palette.pixels, onerow: onerow, index: index, c: c,
                        paletteSize: palette.w, bitDepth: bitDepth)
                }
            }
        }
    } else {
        // Delta palette: indices below nbDeltas add their palette entry to a
        // prediction from the already-reconstructed output channel.
        for c in 0..<nb {
            let wpState = predictor == 6 ? WPState(header: wpHeader, xsize: w, ysize: h) : nil
            image.channels[c0 + c].pixels.withUnsafeMutableBufferPointer { px in
                for y in 0..<h {
                    let rowBase = y * w
                    let prevBase = (y - 1) * w
                    let prevPrevBase = (y - 2) * w
                    for x in 0..<w {
                        let index = Int(indexPlane[rowBase + x])
                        let entry = getPaletteValue(
                            palette.pixels, onerow: onerow, index: index, c: c,
                            paletteSize: palette.w, bitDepth: bitDepth)
                        var val = Int(entry)
                        if index < nbDeltas {
                            // libjxl runs the predictor (incl. the WP predict)
                            // only for delta pixels; UpdateErrors below runs
                            // for every pixel regardless.
                            let left = x > 0 ? Int(px[rowBase + x - 1]) : (y > 0 ? Int(px[prevBase + x]) : 0)
                            let top = y > 0 ? Int(px[prevBase + x]) : left
                            let topleft = (x > 0 && y > 0) ? Int(px[prevBase + x - 1]) : left
                            let topright = (x + 1 < w && y > 0) ? Int(px[prevBase + x + 1]) : top
                            let leftleft = x > 1 ? Int(px[rowBase + x - 2]) : left
                            let toptop = y > 1 ? Int(px[prevPrevBase + x]) : top
                            let toprightright = (x + 2 < w && y > 0) ? Int(px[prevBase + x + 2]) : topright
                            let wpPred = wpState?.predict(
                                x: x, y: y, xsize: w, N: top, W: left, NE: topright,
                                NW: topleft, NN: toptop, computeProperties: false,
                                properties: nil, offset: 0) ?? 0
                            let guess = predictOne(
                                predictor, left: left, top: top, toptop: toptop,
                                topleft: topleft, topright: topright, leftleft: leftleft,
                                toprightright: toprightright, wpPred: wpPred)
                            val = guess + Int(entry)
                        }
                        px[rowBase + x] = Int32(truncatingIfNeeded: val)
                        wpState?.updateErrors(Int(px[rowBase + x]), x: x, y: y, xsize: w)
                    }
                }
            }
        }
    }

    if c0 >= image.nbMetaChannels {
        image.nbMetaChannels -= 1
    } else {
        image.nbMetaChannels -= 2 - nb
    }
    image.channels.removeFirst()
}

@inline(__always)
private func paletteScale(_ value: Int, _ bitDepth: Int) -> Int {
    (value * ((1 << bitDepth) - 1)) >> 2
}

/// Resolves a palette index to a component value, including the implicit
/// delta-palette and color-cube ranges (libjxl GetPaletteValue).
func getPaletteValue(_ palette: [Int32], onerow: Int, index idx0: Int, c: Int, paletteSize: Int, bitDepth: Int)
    -> Int32 {
    var index = idx0
    if index < 0 {
        if c >= kRgbChannels { return 0 }
        index = -(index + 1)
        index %= 1 + 2 * (kDeltaPalette.count - 1)
        let mult = (index & 1) == 0 ? -1 : 1
        var result = Int(kDeltaPalette[(index + 1) >> 1][c]) * mult
        if bitDepth > 8 { result *= 1 << (bitDepth - 8) }
        return Int32(truncatingIfNeeded: result)
    } else if paletteSize <= index && index < paletteSize + kLargeCubeOffset {
        if c >= kRgbChannels { return 0 }
        var i = index - paletteSize
        i >>= c * kSmallCubeBits
        return Int32(truncatingIfNeeded: paletteScale(i % kSmallCube, bitDepth) + (1 << max(0, bitDepth - 3)))
    } else if index >= paletteSize + kLargeCubeOffset {
        if c >= kRgbChannels { return 0 }
        var i = index - paletteSize - kLargeCubeOffset
        if c == 1 { i /= kLargeCube } else if c == 2 { i /= kLargeCube * kLargeCube }
        return Int32(truncatingIfNeeded: paletteScale(i % kLargeCube, bitDepth))
    }
    return palette[c * onerow + index]
}

private let kDeltaPalette: [[Int32]] = [
    [0, 0, 0], [4, 4, 4], [11, 0, 0], [0, 0, -13], [0, -12, 0], [-10, -10, -10],
    [-18, -18, -18], [-27, -27, -27], [-18, -18, 0], [0, 0, -32], [-32, 0, 0], [-37, -37, -37],
    [0, -32, -32], [24, 24, 45], [50, 50, 50], [-45, -24, -24], [-24, -45, -45], [0, -24, -24],
    [-34, -34, 0], [-24, 0, -24], [-45, -45, -24], [64, 64, 64], [-32, 0, -32], [0, -32, 0],
    [-32, 0, 32], [-24, -45, -24], [45, 24, 45], [24, -24, -45], [-45, -24, 24], [80, 80, 80],
    [64, 0, 0], [0, 0, -64], [0, -64, -64], [-24, -24, 45], [96, 96, 96], [64, 64, 0],
    [45, -24, -24], [34, -34, 0], [112, 112, 112], [24, -45, -45], [45, 45, -24], [0, -32, 32],
    [24, -24, 45], [0, 96, 96], [45, -24, 24], [24, -45, -24], [-24, -45, 24], [0, -64, 0],
    [96, 0, 0], [128, 128, 128], [64, 0, 64], [144, 144, 144], [96, 96, 0], [-36, -36, 36],
    [45, -24, -45], [45, -45, -24], [0, 0, -96], [0, 128, 128], [0, 96, 0], [45, 24, -45],
    [-128, 0, 0], [24, -45, 24], [-45, 24, -45], [64, 0, -64], [64, -64, -64], [96, 0, 96],
    [45, -45, 24], [24, 45, -45], [64, 64, -64], [128, 128, 0], [0, 0, -128], [-24, 45, -45],
]

/// Inverse reversible color transform (libjxl InvRCT).
func invRCT(_ image: ModularImage, beginC m: Int, rctType: Int) {
    if rctType == 0 { return }
    let permutation = rctType / 7
    let custom = rctType % 7
    let w = image.channels[m].w
    let h = image.channels[m].h

    // Output channel positions after the permutation.
    let o0 = m + (permutation % 3)
    let o1 = m + ((permutation + 1 + permutation / 3) % 3)
    let o2 = m + ((permutation + 2 - permutation / 3) % 3)

    if custom == 0 {
        // Permute-only: move the three planes into their output positions.
        let c0 = image.channels[m]
        let c1 = image.channels[m + 1]
        let c2 = image.channels[m + 2]
        image.channels[o0] = c0
        image.channels[o1] = c1
        image.channels[o2] = c2
        return
    }

    let second = custom >> 1
    let third = custom & 1
    for y in 0..<h {
        for x in 0..<w {
            // Read all three inputs first (output planes may alias inputs).
            let inA = Int(image.channels[m].at(x, y))
            let inB = Int(image.channels[m + 1].at(x, y))
            let inC = Int(image.channels[m + 2].at(x, y))
            let r0: Int
            let r1: Int
            let r2: Int
            if custom == 6 {  // YCoCg
                let tmp = inA - (inC >> 1)  // Y - (Cg>>1)
                let g = inC + tmp
                let b = tmp - (inB >> 1)  // tmp - (Co>>1)
                r0 = b + inB  // R = B + Co
                r1 = g
                r2 = b
            } else {
                var first = inA
                var sec = inB
                var thd = inC
                if third == 1 { thd = thd &+ first }
                if second == 1 {
                    sec = sec &+ first
                } else if second == 2 {
                    sec = sec &+ ((first &+ thd) >> 1)
                }
                first = inA
                r0 = first
                r1 = sec
                r2 = thd
            }
            image.channels[o0].set(x, y, Int32(truncatingIfNeeded: r0))
            image.channels[o1].set(x, y, Int32(truncatingIfNeeded: r1))
            image.channels[o2].set(x, y, Int32(truncatingIfNeeded: r2))
        }
    }
}
