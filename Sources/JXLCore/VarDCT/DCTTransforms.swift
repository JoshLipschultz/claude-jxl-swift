// Transforms.swift
//
// Inverse VarDCT transforms (libjxl v0.11.2 dec_transforms-inl.h): the scaled
// inverse DCT for all rectangular sizes up to 32x32, the special 8x8 transforms
// (IDENTITY, DCT2X2, DCT4X4, DCT4X8, DCT8X4, AFV0-3), and the LLF-from-DC
// insertion (ReinterpretingDCT).
//
// Conventions (matching libjxl's ComputeScaledIDCT):
//   * An HxW block's coefficients are stored as min(H,W) rows x max(H,W)
//     columns. For H >= W ("tall", incl. square) storage is transposed:
//     S[u*H + v] = F[v][u]; for H < W it is natural: S[v*W + u] = F[v][u]
//     (v = vertical frequency < H, u = horizontal < W).
//   * The 1D basis is the self-normalizing DCT-III: w(0) = 1, w(k>0) = sqrt(2),
//     so a pure-DC block reconstructs to a flat block equal to the DC value.

import Foundation

private let kSqrt2: Float = 1.41421356237

/// 1D IDCT basis for size N: `basis[x*N + k] = w(k) * cos((2x+1) k pi / 2N)`.
/// Stored as a manually-managed pointer (never freed — a few KB of process
/// lifetime tables): returning a global `[Float]` from the per-block hot path
/// retains/releases one shared refcount from every worker thread, and that
/// contended cacheline dominated parallel reconstruction.
private func makeIDCTBasis(_ n: Int) -> UnsafePointer<Float> {
    let m = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
    for x in 0..<n {
        for k in 0..<n {
            let w: Double = k == 0 ? 1.0 : 2.0.squareRoot()
            m[x * n + k] = Float(w * cos(Double(2 * x + 1) * Double(k) * Double.pi / Double(2 * n)))
        }
    }
    return UnsafePointer(m)
}

nonisolated(unsafe) private let idctBasis4 = makeIDCTBasis(4)
nonisolated(unsafe) private let idctBasis8 = makeIDCTBasis(8)
nonisolated(unsafe) private let idctBasis16 = makeIDCTBasis(16)
nonisolated(unsafe) private let idctBasis32 = makeIDCTBasis(32)
nonisolated(unsafe) private let idctBasis64 = makeIDCTBasis(64)
nonisolated(unsafe) private let idctBasis128 = makeIDCTBasis(128)
nonisolated(unsafe) private let idctBasis256 = makeIDCTBasis(256)

private func idctBasis(_ n: Int) -> UnsafePointer<Float> {
    switch n {
    case 4: return idctBasis4
    case 8: return idctBasis8
    case 16: return idctBasis16
    case 32: return idctBasis32
    case 64: return idctBasis64
    case 128: return idctBasis128
    default: return idctBasis256
    }
}

/// Separable scaled inverse DCT of an HxW block. `coeffs` holds H*W values in
/// the storage layout above; the result is written to `pixels` (row-major,
/// `stride` floats per row). `tmp` needs H*W floats of scratch.
func scaledIDCT(
    _ coeffs: UnsafeMutablePointer<Float>, h: Int, w: Int,
    pixels: UnsafeMutablePointer<Float>, stride: Int, tmp: UnsafeMutablePointer<Float>
) {
    let bh = idctBasis(h)
    let bw = idctBasis(w)
    if h >= w {
        // Transposed storage: S[u*h + v]. Pass 1 inverts the vertical
        // frequencies of each storage row; pass 2 the horizontal ones.
        for u in 0..<w {
            let row = coeffs + u * h
            let out = tmp + u * h
            for y in 0..<h {
                var s: Float = 0
                let basisRow = bh + y * h
                for v in 0..<h { s += basisRow[v] * row[v] }
                out[y] = s
            }
        }
        for y in 0..<h {
            let dst = pixels + y * stride
            for x in 0..<w {
                var s: Float = 0
                let basisRow = bw + x * w
                for u in 0..<w { s += basisRow[u] * tmp[u * h + y] }
                dst[x] = s
            }
        }
    } else {
        // Natural storage: S[v*w + u].
        for v in 0..<h {
            let row = coeffs + v * w
            let out = tmp + v * w
            for x in 0..<w {
                var s: Float = 0
                let basisRow = bw + x * w
                for u in 0..<w { s += basisRow[u] * row[u] }
                out[x] = s
            }
        }
        for y in 0..<h {
            let dst = pixels + y * stride
            let basisRow = bh + y * h
            for x in 0..<w {
                var s: Float = 0
                for v in 0..<h { s += basisRow[v] * tmp[v * w + x] }
                dst[x] = s
            }
        }
    }
}

// MARK: - LLF from DC (libjxl LowestFrequenciesFromDC / ReinterpretingDCT)

/// `DCTResampleScales<N, 8N>`: scale for reinterpreting an N-point DCT's
/// coefficients as the lowest frequencies of an 8N-point DCT.
private let kResampleScale2: [Float] = [1.0, 1.108937353592731823]
private let kResampleScale4: [Float] = [
    1.0, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251,
]
private let kResampleScale8: [Float] = [
    1.0, 1.0063534990068217, 1.0257600967811158, 1.0593017296817173,
    1.1089373535927318, 1.1777765381970435, 1.2705593687654873, 1.3944898413647777,
]
private let kResampleScale16: [Float] = [
    1.0, 1.0015830492062623, 1.0063534990068217, 1.0143759095928793,
    1.0257600967811158, 1.0406645869480142, 1.0593017296817173, 1.0819447744633812,
    1.1089373535927318, 1.1407059950032632, 1.1777765381970435, 1.2207956782315876,
    1.2705593687654873, 1.3280505578213306, 1.3944898413647777, 1.4714043176061107,
]
private let kResampleScale32: [Float] = [
    1.0, 1.0003954307206069, 1.0015830492062623, 1.0035668445360069,
    1.0063534990068217, 1.009952439375063, 1.0143759095928793, 1.0196390660647288,
    1.0257600967811158, 1.0327603660498115, 1.0406645869480142, 1.049501024072585,
    1.0593017296817173, 1.0701028169146336, 1.0819447744633812, 1.0948728278734026,
    1.1089373535927318, 1.124194353004584, 1.1407059950032632, 1.158541237256391,
    1.1777765381970435, 1.1984966740820495, 1.2207956782315876, 1.244777922949508,
    1.2705593687654873, 1.2982690107339132, 1.3280505578213306, 1.3600643892400104,
    1.3944898413647777, 1.4315278911623237, 1.4714043176061107, 1.5143734423314616,
]

private func resampleScales(_ n: Int) -> [Float] {
    switch n {
    case 1: return [1.0]
    case 2: return kResampleScale2
    case 4: return kResampleScale4
    case 8: return kResampleScale8
    case 16: return kResampleScale16
    default: return kResampleScale32
    }
}

/// Forward scaled DCT-II of n values (n <= 4): F[k] = w(k)/n * sum f(x) cos(...).
private func forwardScaledDCT(_ input: [Float], _ n: Int) -> [Float] {
    if n == 1 { return input }
    var out = [Float](repeating: 0, count: n)
    for k in 0..<n {
        let w: Double = k == 0 ? 1.0 : 2.0.squareRoot()
        var s = 0.0
        for x in 0..<n {
            s += Double(input[x]) * cos(Double(2 * x + 1) * Double(k) * Double.pi / Double(2 * n))
        }
        out[k] = Float(w * s / Double(n))
    }
    return out
}

/// Fills the lowest-frequency coefficients of a varblock from the DC image:
/// a cy x cx scaled DCT of the covered blocks' DC values, resample-scaled and
/// written into the top-left of the coefficient storage. For 1x1 strategies
/// this is simply `coeffs[0] = dc`.
func insertLLF(
    _ coeffs: UnsafeMutablePointer<Float>, strategy: Int,
    dc: UnsafePointer<Float>, dcStride: Int, dcOrigin: Int
) {
    let cx = kCoveredBlocksX[strategy]
    let cy = kCoveredBlocksY[strategy]
    if cx == 1 && cy == 1 {
        coeffs[0] = dc[dcOrigin]
        return
    }
    // 2D forward scaled DCT of the cy x cx DC values (separable, sizes <= 4).
    var rows = [[Float]]()
    rows.reserveCapacity(cy)
    for iy in 0..<cy {
        var row = [Float](repeating: 0, count: cx)
        for ix in 0..<cx { row[ix] = dc[dcOrigin + iy * dcStride + ix] }
        rows.append(forwardScaledDCT(row, cx))
    }
    let h = kStrategyBlockH[strategy]
    let w = kStrategyBlockW[strategy]
    let cm = max(h, w)
    let vScale = resampleScales(cy)
    let hScale = resampleScales(cx)
    for u in 0..<cx {
        var col = [Float](repeating: 0, count: cy)
        for v in 0..<cy { col[v] = rows[v][u] }
        let f = forwardScaledDCT(col, cy)
        for v in 0..<cy {
            let value = f[v] * vScale[v] * hScale[u]
            if h >= w {
                coeffs[u * cm + v] = value
            } else {
                coeffs[v * cm + u] = value
            }
        }
    }
}

// MARK: - Special 8x8 transforms

/// libjxl IDENTITY inverse: 4x4 sub-blocks of "delta from a shared base" pixels.
func identityTransform(
    _ coeffs: UnsafeMutablePointer<Float>, pixels: UnsafeMutablePointer<Float>, stride: Int
) {
    let block00 = coeffs[0]
    let block01 = coeffs[1]
    let block10 = coeffs[8]
    let block11 = coeffs[9]
    let dcs: [Float] = [
        block00 + block01 + block10 + block11,
        block00 + block01 - block10 - block11,
        block00 - block01 + block10 - block11,
        block00 - block01 - block10 + block11,
    ]
    for y in 0..<2 {
        for x in 0..<2 {
            let blockDC = dcs[y * 2 + x]
            var residualSum: Float = 0
            for iy in 0..<4 {
                for ix in 0..<4 {
                    if ix == 0 && iy == 0 { continue }
                    residualSum += coeffs[(y + iy * 2) * 8 + x + ix * 2]
                }
            }
            let base = blockDC - residualSum * (1.0 / 16)
            pixels[(4 * y + 1) * stride + 4 * x + 1] = base
            for iy in 0..<4 {
                for ix in 0..<4 {
                    if ix == 1 && iy == 1 { continue }
                    pixels[(y * 4 + iy) * stride + x * 4 + ix] =
                        coeffs[(y + iy * 2) * 8 + x + ix * 2] + base
                }
            }
            pixels[y * 4 * stride + x * 4] = coeffs[(y + 2) * 8 + x + 2] + base
        }
    }
}

/// One level of the DCT2X2 inverse: expands the top-left SxS corner in place
/// (libjxl IDCT2TopBlock, operating on an 8-wide buffer).
private func idct2TopBlock(_ block: UnsafeMutablePointer<Float>, _ s: Int) {
    let num = s / 2
    var temp = [Float](repeating: 0, count: 64)
    for y in 0..<num {
        for x in 0..<num {
            let c00 = block[y * 8 + x]
            let c01 = block[y * 8 + num + x]
            let c10 = block[(y + num) * 8 + x]
            let c11 = block[(y + num) * 8 + num + x]
            temp[y * 2 * 8 + x * 2] = c00 + c01 + c10 + c11
            temp[y * 2 * 8 + x * 2 + 1] = c00 + c01 - c10 - c11
            temp[(y * 2 + 1) * 8 + x * 2] = c00 - c01 + c10 - c11
            temp[(y * 2 + 1) * 8 + x * 2 + 1] = c00 - c01 - c10 + c11
        }
    }
    for y in 0..<s {
        for x in 0..<s { block[y * 8 + x] = temp[y * 8 + x] }
    }
}

func dct2x2Transform(
    _ coeffs: UnsafeMutablePointer<Float>, pixels: UnsafeMutablePointer<Float>, stride: Int
) {
    idct2TopBlock(coeffs, 2)
    idct2TopBlock(coeffs, 4)
    idct2TopBlock(coeffs, 8)
    for y in 0..<8 {
        for x in 0..<8 { pixels[y * stride + x] = coeffs[y * 8 + x] }
    }
}

func dct4x4Transform(
    _ coeffs: UnsafeMutablePointer<Float>, pixels: UnsafeMutablePointer<Float>, stride: Int,
    scratch: UnsafeMutablePointer<Float>
) {
    let block00 = coeffs[0]
    let block01 = coeffs[1]
    let block10 = coeffs[8]
    let block11 = coeffs[9]
    let dcs: [Float] = [
        block00 + block01 + block10 + block11,
        block00 + block01 - block10 - block11,
        block00 - block01 + block10 - block11,
        block00 - block01 - block10 + block11,
    ]
    var block = [Float](repeating: 0, count: 16)
    for y in 0..<2 {
        for x in 0..<2 {
            block[0] = dcs[y * 2 + x]
            for iy in 0..<4 {
                for ix in 0..<4 {
                    if ix == 0 && iy == 0 { continue }
                    block[iy * 4 + ix] = coeffs[(y + iy * 2) * 8 + x + ix * 2]
                }
            }
            block.withUnsafeMutableBufferPointer {
                scaledIDCT(
                    $0.baseAddress!, h: 4, w: 4,
                    pixels: pixels + y * 4 * stride + x * 4, stride: stride, tmp: scratch)
            }
        }
    }
}

func dct4x8Transform(
    _ coeffs: UnsafeMutablePointer<Float>, pixels: UnsafeMutablePointer<Float>, stride: Int,
    scratch: UnsafeMutablePointer<Float>
) {
    let dc0 = coeffs[0] + coeffs[8]
    let dc1 = coeffs[0] - coeffs[8]
    var block = [Float](repeating: 0, count: 32)
    for y in 0..<2 {
        block[0] = y == 0 ? dc0 : dc1
        for iy in 0..<4 {
            for ix in 0..<8 {
                if ix == 0 && iy == 0 { continue }
                block[iy * 8 + ix] = coeffs[(y + iy * 2) * 8 + ix]
            }
        }
        block.withUnsafeMutableBufferPointer {
            scaledIDCT(
                $0.baseAddress!, h: 4, w: 8,
                pixels: pixels + y * 4 * stride, stride: stride, tmp: scratch)
        }
    }
}

func dct8x4Transform(
    _ coeffs: UnsafeMutablePointer<Float>, pixels: UnsafeMutablePointer<Float>, stride: Int,
    scratch: UnsafeMutablePointer<Float>
) {
    let dc0 = coeffs[0] + coeffs[8]
    let dc1 = coeffs[0] - coeffs[8]
    var block = [Float](repeating: 0, count: 32)
    for x in 0..<2 {
        block[0] = x == 0 ? dc0 : dc1
        for iy in 0..<4 {
            for ix in 0..<8 {
                if ix == 0 && iy == 0 { continue }
                block[iy * 8 + ix] = coeffs[(x + iy * 2) * 8 + ix]
            }
        }
        block.withUnsafeMutableBufferPointer {
            scaledIDCT(
                $0.baseAddress!, h: 8, w: 4,
                pixels: pixels + x * 4, stride: stride, tmp: scratch)
        }
    }
}

// MARK: - AFV (libjxl AFVIDCT4x4 + AFVTransformToPixels)

/// The 16 4x4 AFV basis images (libjxl k4x4AFVBasis), row-major.
private let k4x4AFVBasis: [Float] = [
    0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25,
    0.876902929799142, 0.2206518106944235, -0.10140050393753763, -0.1014005039375375, 0.2206518106944236, -0.10140050393753777, -0.10140050393753772, -0.10140050393753763, -0.10140050393753758, -0.10140050393753769, -0.1014005039375375, -0.10140050393753768, -0.10140050393753768, -0.10140050393753759, -0.10140050393753763, -0.10140050393753741,
    0.0, 0.0, 0.40670075830260755, 0.44444816619734445, 0.0, 0.0, 0.19574399372042936, 0.2929100136981264, -0.40670075830260716, -0.19574399372042872, 0.0, 0.11379074460448091, -0.44444816619734384, -0.29291001369812636, -0.1137907446044814, 0.0,
    0.0, 0.0, -0.21255748058288748, 0.3085497062849767, 0.0, 0.4706702258572536, -0.1621205195722993, 0.0, -0.21255748058287047, -0.16212051957228327, -0.47067022585725277, -0.1464291867126764, 0.3085497062849487, 0.0, -0.14642918671266536, 0.4251149611657548,
    0.0, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    -0.4105377591765233, 0.6235485373547691, -0.06435071657946274, -0.06435071657946266, 0.6235485373547694, -0.06435071657946284, -0.0643507165794628, -0.06435071657946274, -0.06435071657946272, -0.06435071657946279, -0.06435071657946266, -0.06435071657946277, -0.06435071657946277, -0.06435071657946273, -0.06435071657946274, -0.0643507165794626,
    0.0, 0.0, -0.4517556589999482, 0.15854503551840063, 0.0, -0.04038515160822202, 0.0074182263792423875, 0.39351034269210167, -0.45175565899994635, 0.007418226379244351, 0.1107416575309343, 0.08298163094882051, 0.15854503551839705, 0.3935103426921022, 0.0829816309488214, -0.45175565899994796,
    0.0, 0.0, -0.304684750724869, 0.5112616136591823, 0.0, 0.0, -0.290480129728998, -0.06578701549142804, 0.304684750724884, 0.2904801297290076, 0.0, -0.23889773523344604, -0.5112616136592012, 0.06578701549142545, 0.23889773523345467, 0.0,
    0.0, 0.0, 0.3017929516615495, 0.25792362796341184, 0.0, 0.16272340142866204, 0.09520022653475037, 0.0, 0.3017929516615503, 0.09520022653475055, -0.16272340142866173, -0.35312385449816297, 0.25792362796341295, 0.0, -0.3531238544981624, -0.6035859033230976,
    0.0, 0.0, 0.40824829046386274, 0.0, 0.0, 0.0, 0.0, -0.4082482904638628, -0.4082482904638635, 0.0, 0.0, -0.40824829046386296, 0.0, 0.4082482904638634, 0.408248290463863, 0.0,
    0.0, 0.0, 0.1747866975480809, 0.0812611176717539, 0.0, 0.0, -0.3675398009862027, -0.307882213957909, -0.17478669754808135, 0.3675398009862011, 0.0, 0.4826689115059883, -0.08126111767175039, 0.30788221395790305, -0.48266891150598584, 0.0,
    0.0, 0.0, -0.21105601049335784, 0.18567180916109802, 0.0, 0.0, 0.49215859013738733, -0.38525013709251915, 0.21105601049335806, -0.49215859013738905, 0.0, 0.17419412659916217, -0.18567180916109904, 0.3852501370925211, -0.1741941265991621, 0.0,
    0.0, 0.0, -0.14266084808807264, -0.3416446842253372, 0.0, 0.7367497537172237, 0.24627107722075148, -0.08574019035519306, -0.14266084808807344, 0.24627107722075137, 0.14883399227113567, -0.04768680350229251, -0.3416446842253373, -0.08574019035519267, -0.047686803502292804, -0.14266084808807242,
    0.0, 0.0, -0.13813540350758585, 0.3302282550303788, 0.0, 0.08755115000587084, -0.07946706605909573, -0.4613374887461511, -0.13813540350758294, -0.07946706605910261, 0.49724647109535086, 0.12538059448563663, 0.3302282550303805, -0.4613374887461554, 0.12538059448564315, -0.13813540350758452,
    0.0, 0.0, -0.17437602599651067, 0.0702790691196284, 0.0, -0.2921026642334881, 0.3623817333531167, 0.0, -0.1743760259965108, 0.36238173335311646, 0.29210266423348785, -0.4326608024727445, 0.07027906911962818, 0.0, -0.4326608024727457, 0.34875205199302267,
    0.0, 0.0, 0.11354987314994337, -0.07417504595810355, 0.0, 0.19402893032594343, -0.435190496523228, 0.21918684838857466, 0.11354987314994257, -0.4351904965232251, 0.5550443808910661, -0.25468277124066463, -0.07417504595810233, 0.2191868483885728, -0.25468277124066413, 0.1135498731499429,
]

private func afvIDCT4x4(_ coeffs: [Float], _ pixels: inout [Float]) {
    k4x4AFVBasis.withUnsafeBufferPointer { basis in
        for i in 0..<16 {
            var s: Float = 0
            for j in 0..<16 { s += coeffs[j] * basis[j * 16 + i] }
            pixels[i] = s
        }
    }
}

func afvTransform(
    kind: Int, _ coeffs: UnsafeMutablePointer<Float>,
    pixels: UnsafeMutablePointer<Float>, stride: Int, scratch: UnsafeMutablePointer<Float>
) {
    let afvX = kind & 1
    let afvY = kind / 2
    let block00 = coeffs[0]
    let block01 = coeffs[1]
    let block10 = coeffs[8]
    let dcs: [Float] = [
        (block00 + block10 + block01) * 4.0,
        block00 + block10 - block01,
        block00 - block10,
    ]
    // AFV quadrant: (even, even) coefficient positions.
    var coeff = [Float](repeating: 0, count: 16)
    coeff[0] = dcs[0]
    for iy in 0..<4 {
        for ix in 0..<4 {
            if ix == 0 && iy == 0 { continue }
            coeff[iy * 4 + ix] = coeffs[iy * 2 * 8 + ix * 2]
        }
    }
    var afvBlock = [Float](repeating: 0, count: 16)
    afvIDCT4x4(coeff, &afvBlock)
    for iy in 0..<4 {
        for ix in 0..<4 {
            pixels[(iy + afvY * 4) * stride + afvX * 4 + ix] =
                afvBlock[(afvY == 1 ? 3 - iy : iy) * 4 + (afvX == 1 ? 3 - ix : ix)]
        }
    }
    // DCT4x4 in the horizontally adjacent quadrant: (odd, even) positions.
    var block = [Float](repeating: 0, count: 32)
    block[0] = dcs[1]
    for iy in 0..<4 {
        for ix in 0..<4 {
            if ix == 0 && iy == 0 { continue }
            block[iy * 4 + ix] = coeffs[iy * 2 * 8 + ix * 2 + 1]
        }
    }
    block.withUnsafeMutableBufferPointer {
        scaledIDCT(
            $0.baseAddress!, h: 4, w: 4,
            pixels: pixels + afvY * 4 * stride + (afvX == 1 ? 0 : 4), stride: stride,
            tmp: scratch)
    }
    // DCT4x8 in the vertically adjacent half: odd rows.
    block[0] = dcs[2]
    for iy in 0..<4 {
        for ix in 0..<8 {
            if ix == 0 && iy == 0 { continue }
            block[iy * 8 + ix] = coeffs[(1 + iy * 2) * 8 + ix]
        }
    }
    block.withUnsafeMutableBufferPointer {
        scaledIDCT(
            $0.baseAddress!, h: 4, w: 8,
            pixels: pixels + (afvY == 1 ? 0 : 4) * stride, stride: stride, tmp: scratch)
    }
}
