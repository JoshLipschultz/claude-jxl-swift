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

func metaApplyTransform(_ image: ModularImage, transform t: ModularTransform) throws {
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
    default:
        throw ModularDecodeError.unsupportedTransform
    }
}

/// Undoes the transforms applied to a decoded Modular image, in reverse order.
func undoTransforms(_ image: ModularImage, transforms: [ModularTransform]) throws {
    for t in transforms.reversed() {
        switch t.id {
        case .rct:
            invRCT(image, beginC: Int(t.beginC), rctType: Int(t.rctType))
        case .palette:
            try invPalette(
                image, beginC: Int(t.beginC), nbColors: Int(t.nbColors), nbDeltas: Int(t.nbDeltas),
                predictor: Int(t.predictor))
        default:
            throw ModularDecodeError.unsupportedTransform
        }
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
/// the palette (libjxl InvPalette, the nb_deltas == 0 path).
func invPalette(_ image: ModularImage, beginC: Int, nbColors: Int, nbDeltas: Int, predictor: Int) throws {
    if nbDeltas != 0 { throw ModularDecodeError.unsupportedTransform }  // delta palette not yet
    guard !image.channels.isEmpty else { throw ModularDecodeError.unsupportedTransform }

    let nb = image.channels[0].h  // palette height = number of color channels
    let c0 = beginC + 1
    guard nb >= 1, c0 < image.channels.count else { throw ModularDecodeError.unsupportedTransform }
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

    for c in 0..<nb {
        for y in 0..<h {
            for x in 0..<w {
                let index = Int(indexPlane[y * w + x])
                image.channels[c0 + c].pixels[y * w + x] = getPaletteValue(
                    palette.pixels, onerow: onerow, index: index, c: c, paletteSize: palette.w,
                    bitDepth: bitDepth)
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
