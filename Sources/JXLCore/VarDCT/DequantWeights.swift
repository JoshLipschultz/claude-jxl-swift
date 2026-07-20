// DequantWeights.swift
//
// Default VarDCT dequantization matrices (libjxl v0.11.2 quant_weights.cc,
// `DequantMatricesLibraryDef` + `ComputeQuantTable`). Each AC strategy maps to
// one of 11 quant-table kinds; a table holds, per channel, one dequant value
// (= 1 / quant weight) per coefficient, laid out exactly like the strategy's
// coefficient storage (min(H,W) rows x max(H,W) columns of 8x8 blocks), so
// dequantization is a flat elementwise multiply.
//
// Only the default (library) tables are supported, matching the rest of the
// VarDCT path; custom-encoded tables are rejected upstream.

import Foundation

/// Quant-table kind indices (libjxl QuantTable), for tables 0...10 which cover
/// AC strategies 0...17 (up to 32x32). Larger DCTs (64+) are not supported.
enum QuantTableKind: Int, CaseIterable {
    case dct = 0        // DCT8
    case identity = 1
    case dct2x2 = 2
    case dct4x4 = 3
    case dct16x16 = 4
    case dct32x32 = 5
    case dct8x16 = 6    // also DCT16X8
    case dct8x32 = 7    // also DCT32X8
    case dct16x32 = 8   // also DCT32X16
    case dct4x8 = 9     // also DCT8X4
    case afv = 10       // AFV0..3
    case dct64 = 11
    case dct32x64 = 12  // also DCT64X32
    case dct128 = 13
    case dct64x128 = 14 // also DCT128X64
    case dct256 = 15
    case dct128x256 = 16  // also DCT256X128
}

/// AC strategy (0...17) -> quant table kind (libjxl kAcStrategyToQuantTableMap).
let kStrategyQuantTable: [QuantTableKind] = [
    .dct, .identity, .dct2x2, .dct4x4, .dct16x16, .dct32x32,
    .dct8x16, .dct8x16, .dct8x32, .dct8x32, .dct16x32, .dct16x32,
    .dct4x8, .dct4x8, .afv, .afv, .afv, .afv,
    .dct64, .dct32x64, .dct32x64, .dct128, .dct64x128, .dct64x128,
    .dct256, .dct128x256, .dct128x256,
]

/// Pixel rows (height) of each AC strategy's transform, 0...26.
let kStrategyBlockH: [Int] = [
    8, 8, 8, 8, 16, 32, 16, 8, 32, 8, 32, 16, 8, 8, 8, 8, 8, 8,
    64, 64, 32, 128, 128, 64, 256, 256, 128,
]
/// Pixel columns (width) of each AC strategy's transform, 0...26.
let kStrategyBlockW: [Int] = [
    8, 8, 8, 8, 16, 32, 8, 16, 8, 32, 16, 32, 8, 8, 8, 8, 8, 8,
    64, 32, 64, 128, 64, 128, 256, 128, 256,
]

private let kSqrt2: Float = 1.41421356237

private func mult(_ v: Float) -> Float { v > 0 ? 1 + v : 1 / (1 - v) }

/// libjxl `InterpolateVec`: `pos` is already scaled into band index space.
private func interpolateScaled(_ pos: Float, _ bands: [Float]) -> Float {
    let idx = Int(pos)
    let a = bands[idx]
    let b = bands[idx + 1 < bands.count ? idx + 1 : idx]
    return a * powf(b / a, pos - Float(idx))
}

/// libjxl `Interpolate`: rescales `pos` from [0, max] into band index space.
private func interpolate(_ pos: Float, _ max: Float, _ bands: [Float]) -> Float {
    interpolateScaled(pos * Float(bands.count - 1) / max, bands)
}

private func expandBands(_ distanceBands: [Float]) -> [Float] {
    var bands = [Float](repeating: 0, count: distanceBands.count)
    bands[0] = distanceBands[0]
    for i in 1..<distanceBands.count { bands[i] = bands[i - 1] * mult(distanceBands[i]) }
    return bands
}

/// libjxl `GetQuantWeights`: distance-band interpolated weights for a
/// rows x cols table, `out[c*rows*cols + y*cols + x]`.
private func dctQuantWeights(rows: Int, cols: Int, dist: [[Float]]) -> [Float] {
    var out = [Float](repeating: 0, count: 3 * rows * cols)
    for c in 0..<3 {
        let bands = expandBands(dist[c])
        let scale = Float(bands.count - 1) / (kSqrt2 + 1e-6)
        let rcpcol = scale / Float(cols - 1)
        let rcprow = scale / Float(rows - 1)
        for y in 0..<rows {
            let dy = Float(y) * rcprow
            for x in 0..<cols {
                let dx = Float(x) * rcpcol
                let d = (dx * dx + dy * dy).squareRoot()
                out[c * rows * cols + y * cols + x] =
                    bands.count == 1 ? bands[0] : interpolateScaled(d, bands)
            }
        }
    }
    return out
}

// MARK: - Default table parameters (DequantMatricesLibraryDef)

private let kDCT8Dist: [[Float]] = [
    [3150.0, 0.0, -0.4, -0.4, -0.4, -2.0],
    [560.0, 0.0, -0.3, -0.3, -0.3, -0.3],
    [512.0, -2.0, -1.0, 0.0, -1.0, -2.0],
]
private let kIdentityWeights: [[Float]] = [
    [280.0, 3160.0, 3160.0],
    [60.0, 864.0, 864.0],
    [18.0, 200.0, 200.0],
]
private let kDCT2Weights: [[Float]] = [
    [3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0],
    [960.0, 640.0, 320.0, 180.0, 140.0, 120.0],
    [640.0, 320.0, 128.0, 64.0, 32.0, 16.0],
]
private let kDCT4Dist: [[Float]] = [
    [2200.0, 0.0, 0.0, 0.0],
    [392.0, 0.0, 0.0, 0.0],
    [112.0, -0.25, -0.25, -0.5],
]
private let kDCT16Dist: [[Float]] = [
    [
        8996.8725711814115328, -1.3000777393353804, -0.49424529824571225,
        -0.439093774457103443, -0.6350101832695744, -0.90177264050827612,
        -1.6162099239887414,
    ],
    [
        3191.48366296844234752, -0.67424582104194355, -0.80745813428471001,
        -0.44925837484843441, -0.35865440981033403, -0.31322389111877305,
        -0.37615025315725483,
    ],
    [
        1157.50408145487200256, -2.0531423165804414, -1.4, -0.50687130033378396,
        -0.42708730624733904, -1.4856834539296244, -4.9209142884401604,
    ],
]
private let kDCT32Dist: [[Float]] = [
    [
        15718.40830982518931456, -1.025, -0.98, -0.9012, -0.4, -0.48819395464,
        -0.421064, -0.27,
    ],
    [
        7305.7636810695983104, -0.8041958212306401, -0.7633036457487539,
        -0.55660379990111464, -0.49785304658857626, -0.43699592683512467,
        -0.40180866526242109, -0.27321683125358037,
    ],
    [
        3803.53173721215041536, -3.060733579805728, -2.0413270132490346,
        -2.0235650159727417, -0.5495389509954993, -0.4, -0.4, -0.3,
    ],
]
private let kDCT8X16Dist: [[Float]] = [
    [7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5],
    [1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2],
    [506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6],
]
private let kDCT8X32Dist: [[Float]] = [
    [
        16283.2494710648897, -1.7812845336559429, -1.6309059012653515,
        -1.0382179034313539, -0.85, -0.7, -0.9, -1.2360638576849587,
    ],
    [
        5089.15750884921511936, -0.320049391452786891, -0.35362849922161446,
        -0.30340000000000003, -0.61, -0.5, -0.5, -0.6,
    ],
    [
        3397.77603275308720128, -0.321327362693153371, -0.34507619223117997,
        -0.70340000000000003, -0.9, -1.0, -1.0, -1.1754605576265209,
    ],
]
private let kDCT16X32Dist: [[Float]] = [
    [
        13844.97076442300573, -0.97113799999999995, -0.658, -0.42026, -0.22712,
        -0.2206, -0.226, -0.6,
    ],
    [
        4798.964084220744293, -0.61125308982767057, -0.83770786552491361,
        -0.79014862079498627, -0.2692727459704829, -0.38272769465388551,
        -0.22924222653091453, -0.20719098826199578,
    ],
    [1807.236946760964614, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5],
]
private let kDCT4X8Dist: [[Float]] = [
    [2198.050556016380522, -0.96269623020744692, -0.76194253026666783, -0.6551140670773547],
    [764.3655248643528689, -0.92630200888366945, -0.9675229603596517, -0.27845290869168118],
    [527.107573587542228, -1.4594385811273854, -1.450082094097871593, -1.5843722511996204],
]
private let kAFVWeights: [[Float]] = [
    [3072.0, 3072.0, 256.0, 256.0, 256.0, 414.0, 0.0, 0.0, 0.0],
    [1024.0, 1024.0, 50.0, 50.0, 50.0, 58.0, 0.0, 0.0, 0.0],
    [384.0, 384.0, 12.0, 12.0, 12.0, 22.0, -0.25, -0.25, -0.25],
]
// libjxl kFreqs (AFV): frequency of each (even,even) position's basis function.
private let kAFVFreqs: [Float] = [
    0, 0, 0.8517778890324296, 5.37778436506804,
    0, 0, 4.734747904497923, 5.449245381693219,
    1.6598270267479331, 4, 7.275749096817861, 10.423227632456525,
    2.662932286148962, 7.630657783650829, 8.962388608184032, 12.97166202570235,
]

// DCT64...DCT256 distance bands (DequantMatricesLibraryDef): identical band
// tails with per-size scale factors on the seeds; square kinds use one seed
// triple, rectangular kinds another.
private func bigDCTDist(scale: Float, square: Bool) -> [[Float]] {
    let seeds: (Float, Float, Float) = square
        ? (26629.073922049845, 9311.3238710010046, 4992.2486445538634)
        : (23629.073922049845, 8611.3238710010046, 4492.2486445538634)
    let xTail: [Float] = [
        -1.025, -0.78, -0.65012, -0.19041574084286472, -0.20819395464,
        -0.421064, -0.32733845535848671,
    ]
    let yTail: [Float] = [
        -0.3041958212306401, -0.3633036457487539, -0.35660379990111464,
        -0.3443074455424403, -0.33699592683512467, -0.30180866526242109,
        -0.27321683125358037,
    ]
    let bTail: [Float] = [-1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]
    return [
        [scale * seeds.0] + xTail,
        [scale * seeds.1] + yTail,
        [scale * seeds.2] + bTail,
    ]
}

// MARK: - Table construction (weights, natural quant-table layout)

private func computeWeights(_ kind: QuantTableKind) -> [Float] {
    switch kind {
    case .dct:
        return dctQuantWeights(rows: 8, cols: 8, dist: kDCT8Dist)
    case .identity:
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for i in 0..<64 { w[64 * c + i] = kIdentityWeights[c][0] }
            w[64 * c + 1] = kIdentityWeights[c][1]
            w[64 * c + 8] = kIdentityWeights[c][1]
            w[64 * c + 9] = kIdentityWeights[c][2]
        }
        return w
    case .dct2x2:
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            let dw = kDCT2Weights[c]
            let s = c * 64
            w[s] = 1  // never used (LLF)
            w[s + 1] = dw[0]
            w[s + 8] = dw[0]
            w[s + 9] = dw[1]
            for y in 0..<2 {
                for x in 0..<2 {
                    w[s + y * 8 + x + 2] = dw[2]
                    w[s + (y + 2) * 8 + x] = dw[2]
                    w[s + (y + 2) * 8 + x + 2] = dw[3]
                }
            }
            for y in 0..<4 {
                for x in 0..<4 {
                    w[s + y * 8 + x + 4] = dw[4]
                    w[s + (y + 4) * 8 + x] = dw[4]
                    w[s + (y + 4) * 8 + x + 4] = dw[5]
                }
            }
        }
        return w
    case .dct4x4:
        let w4 = dctQuantWeights(rows: 4, cols: 4, dist: kDCT4Dist)
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for y in 0..<8 {
                for x in 0..<8 {
                    w[c * 64 + y * 8 + x] = w4[c * 16 + (y / 2) * 4 + (x / 2)]
                }
            }
            // Default dct4multipliers are 1.0, so no adjustment of (0,1)/(1,0)/(1,1).
        }
        return w
    case .dct16x16:
        return dctQuantWeights(rows: 16, cols: 16, dist: kDCT16Dist)
    case .dct32x32:
        return dctQuantWeights(rows: 32, cols: 32, dist: kDCT32Dist)
    case .dct8x16:
        return dctQuantWeights(rows: 8, cols: 16, dist: kDCT8X16Dist)
    case .dct8x32:
        return dctQuantWeights(rows: 8, cols: 32, dist: kDCT8X32Dist)
    case .dct16x32:
        return dctQuantWeights(rows: 16, cols: 32, dist: kDCT16X32Dist)
    case .dct4x8:
        let w48 = dctQuantWeights(rows: 4, cols: 8, dist: kDCT4X8Dist)
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for y in 0..<8 {
                for x in 0..<8 {
                    w[c * 64 + y * 8 + x] = w48[c * 32 + (y / 2) * 8 + x]
                }
            }
            // Default dct4x8multiplier is 1.0, so no adjustment of (0,1).
        }
        return w
    case .dct64:
        return dctQuantWeights(rows: 64, cols: 64, dist: bigDCTDist(scale: 0.9, square: true))
    case .dct32x64:
        return dctQuantWeights(rows: 32, cols: 64, dist: bigDCTDist(scale: 0.65, square: false))
    case .dct128:
        return dctQuantWeights(rows: 128, cols: 128, dist: bigDCTDist(scale: 1.8, square: true))
    case .dct64x128:
        return dctQuantWeights(rows: 64, cols: 128, dist: bigDCTDist(scale: 1.3, square: false))
    case .dct256:
        return dctQuantWeights(rows: 256, cols: 256, dist: bigDCTDist(scale: 3.6, square: true))
    case .dct128x256:
        return dctQuantWeights(rows: 128, cols: 256, dist: bigDCTDist(scale: 2.6, square: false))
    case .afv:
        let w48 = dctQuantWeights(rows: 4, cols: 8, dist: kDCT4X8Dist)
        let w44 = dctQuantWeights(rows: 4, cols: 4, dist: kDCT4Dist)
        let lo: Float = 0.8517778890324296
        let hi: Float = 12.97166202570235 - lo + 1e-6
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            let afv = kAFVWeights[c]
            let bands = expandBands([afv[5], afv[6], afv[7], afv[8]])
            let s = c * 64
            w[s] = 1  // LLF, unused
            w[s + 1 * 8 + 0] = afv[0]  // (0, 1)
            w[s + 0 * 8 + 1] = afv[1]  // (1, 0)
            w[s + 2 * 8 + 0] = afv[2]  // (0, 2)
            w[s + 0 * 8 + 2] = afv[3]  // (2, 0)
            w[s + 2 * 8 + 2] = afv[4]  // (2, 2)
            // Remaining (even, even) positions from the AFV frequency bands.
            for y in 0..<4 {
                for x in 0..<4 {
                    if x < 2 && y < 2 { continue }
                    w[s + (2 * y) * 8 + 2 * x] = interpolate(kAFVFreqs[y * 4 + x] - lo, hi, bands)
                }
            }
            // 4x8 weights in odd rows (except position (1,0) handled above).
            for y in 0..<4 {
                for x in 0..<8 {
                    if x == 0 && y == 0 { continue }
                    w[s + (2 * y + 1) * 8 + x] = w48[c * 32 + y * 8 + x]
                }
            }
            // 4x4 weights in even rows / odd columns (except (0,1)).
            for y in 0..<4 {
                for x in 0..<4 {
                    if x == 0 && y == 0 { continue }
                    w[s + (2 * y) * 8 + 2 * x + 1] = w44[c * 16 + y * 4 + x]
                }
            }
        }
        return w
    }
}

/// Default dequant matrices (1 / weight) for all table kinds, `[c][coeff]`
/// flattened, in the corresponding strategies' coefficient-storage layout.
/// Computed once per process on first use (tables are frame-independent
/// defaults); global `let` initialization is lazy and thread-safe.
private let dequantTables: [[Float]] = QuantTableKind.allCases.map { kind in
    var table = computeWeights(kind)
    for i in 0..<table.count { table[i] = 1.0 / table[i] }
    return table
}

func defaultDequantTable(_ kind: QuantTableKind) -> [Float] {
    dequantTables[kind.rawValue]
}

// MARK: - Custom-encoded quant matrices (libjxl quant_weights.cc Decode +
// ComputeQuantTable, modes 1-6; mode 0 = library and mode 7 = RAW are handled
// by the caller). Reads the mode's parameters from `br`, computes the weight
// matrix through the same builders as the library defaults, and returns the
// dequant table (1 / weight) in coefficient-storage layout, or nil if the
// bitstream is malformed.

private let kAlmostZeroQ: Float = 1e-8

/// libjxl `DecodeDctParams`: `num_distance_bands = read(4) + 1`, then 3×num
/// F16 bands; each channel's seed is validated and scaled by 64.
private func readDctParams(_ br: BitReader) -> [[Float]]? {
    let numBands = Int(br.read(4)) + 1
    var dist = [[Float]](repeating: [], count: 3)
    for c in 0..<3 {
        var band = [Float](repeating: 0, count: numBands)
        for i in 0..<numBands { band[i] = br.readF16() }
        if band[0] < kAlmostZeroQ { return nil }
        band[0] *= 64
        dist[c] = band
    }
    return dist
}

/// The dequant table (1 / weight) for one AC coefficient, with the validity
/// check libjxl applies before inverting.
private func invert(_ weights: [Float]) -> [Float]? {
    var table = weights
    for i in 0..<table.count {
        let w = table[i]
        if w >= 1.0 / kAlmostZeroQ || w < kAlmostZeroQ { return nil }
        table[i] = 1.0 / w
    }
    return table
}

/// Reads a custom-encoded quant matrix (modes 1-6) for table `idx` and returns
/// its dequant table, matching `ComputeQuantTable`.
func decodeCustomQuantTable(_ br: BitReader, mode: Int, idx: Int) -> [Float]? {
    switch mode {
    case 1:  // kQuantModeID (num == 64)
        var id = [[Float]](repeating: [0, 0, 0], count: 3)
        for c in 0..<3 {
            for i in 0..<3 {
                let v = br.readF16()
                if abs(v) < kAlmostZeroQ { return nil }
                id[c][i] = v * 64
            }
        }
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for i in 0..<64 { w[64 * c + i] = id[c][0] }
            w[64 * c + 1] = id[c][1]
            w[64 * c + 8] = id[c][1]
            w[64 * c + 9] = id[c][2]
        }
        return invert(w)

    case 2:  // kQuantModeDCT2 (num == 64)
        var dw = [[Float]](repeating: [Float](repeating: 0, count: 6), count: 3)
        for c in 0..<3 {
            for i in 0..<6 {
                let v = br.readF16()
                if abs(v) < kAlmostZeroQ { return nil }
                dw[c][i] = v * 64
            }
        }
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            let d = dw[c]
            let s = c * 64
            w[s] = 0xBAD  // LLF, unused
            w[s + 1] = d[0]
            w[s + 8] = d[0]
            w[s + 9] = d[1]
            for y in 0..<2 {
                for x in 0..<2 {
                    w[s + y * 8 + x + 2] = d[2]
                    w[s + (y + 2) * 8 + x] = d[2]
                    w[s + (y + 2) * 8 + x + 2] = d[3]
                }
            }
            for y in 0..<4 {
                for x in 0..<4 {
                    w[s + y * 8 + x + 4] = d[4]
                    w[s + (y + 4) * 8 + x] = d[4]
                    w[s + (y + 4) * 8 + x + 4] = d[5]
                }
            }
        }
        return invert(w)

    case 3:  // kQuantModeDCT4 (num == 64)
        var mult = [[Float]](repeating: [0, 0], count: 3)
        for c in 0..<3 {
            for i in 0..<2 {
                let v = br.readF16()
                if abs(v) < kAlmostZeroQ { return nil }
                mult[c][i] = v
            }
        }
        guard let dist = readDctParams(br) else { return nil }
        let w44 = dctQuantWeights(rows: 4, cols: 4, dist: dist)
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for y in 0..<8 {
                for x in 0..<8 { w[c * 64 + y * 8 + x] = w44[c * 16 + (y / 2) * 4 + (x / 2)] }
            }
            w[c * 64 + 1] /= mult[c][0]
            w[c * 64 + 8] /= mult[c][0]
            w[c * 64 + 9] /= mult[c][1]
        }
        return invert(w)

    case 4:  // kQuantModeDCT4X8 (num == 64)
        var mult = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            let v = br.readF16()
            if abs(v) < kAlmostZeroQ { return nil }
            mult[c] = v
        }
        guard let dist = readDctParams(br) else { return nil }
        let w48 = dctQuantWeights(rows: 4, cols: 8, dist: dist)
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            for y in 0..<8 {
                for x in 0..<8 { w[c * 64 + y * 8 + x] = w48[c * 32 + (y / 2) * 8 + x] }
            }
            w[c * 64 + 8] /= mult[c]
        }
        return invert(w)

    case 5:  // kQuantModeAFV (num == 64)
        var afv = [[Float]](repeating: [Float](repeating: 0, count: 9), count: 3)
        for c in 0..<3 {
            for i in 0..<9 { afv[c][i] = br.readF16() }
            for i in 0..<6 { afv[c][i] *= 64 }
        }
        guard let dist = readDctParams(br), let dist44 = readDctParams(br) else { return nil }
        let w48 = dctQuantWeights(rows: 4, cols: 8, dist: dist)
        let w44 = dctQuantWeights(rows: 4, cols: 4, dist: dist44)
        let lo: Float = 0.8517778890324296
        let hi: Float = 12.97166202570235 - lo + 1e-6
        var w = [Float](repeating: 0, count: 3 * 64)
        for c in 0..<3 {
            let a = afv[c]
            let bands = expandBands([a[5], a[6], a[7], a[8]])
            if bands[0] < kAlmostZeroQ { return nil }
            let s = c * 64
            w[s] = 1
            w[s + 1 * 8 + 0] = a[0]
            w[s + 0 * 8 + 1] = a[1]
            w[s + 2 * 8 + 0] = a[2]
            w[s + 0 * 8 + 2] = a[3]
            w[s + 2 * 8 + 2] = a[4]
            for y in 0..<4 {
                for x in 0..<4 {
                    if x < 2 && y < 2 { continue }
                    w[s + (2 * y) * 8 + 2 * x] = interpolate(kAFVFreqs[y * 4 + x] - lo, hi, bands)
                }
            }
            for y in 0..<4 {
                for x in 0..<8 {
                    if x == 0 && y == 0 { continue }
                    w[s + (2 * y + 1) * 8 + x] = w48[c * 32 + y * 8 + x]
                }
            }
            for y in 0..<4 {
                for x in 0..<4 {
                    if x == 0 && y == 0 { continue }
                    w[s + (2 * y) * 8 + 2 * x + 1] = w44[c * 16 + y * 4 + x]
                }
            }
        }
        return invert(w)

    case 6:  // kQuantModeDCT (the general parametric DCT, any table size)
        guard let dist = readDctParams(br) else { return nil }
        let rows = kRequiredQuantSizeX[idx] * 8
        let cols = kRequiredQuantSizeY[idx] * 8
        return invert(dctQuantWeights(rows: rows, cols: cols, dist: dist))

    default:
        return nil
    }
}
