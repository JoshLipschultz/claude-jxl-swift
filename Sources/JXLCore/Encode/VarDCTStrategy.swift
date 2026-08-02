// VarDCTStrategy.swift
//
// E5e/E5l: variable-size AC transforms for the lossy VarDCT encoder — DCT8
// (AC strategy 0), DCT16 (strategy 4) and DCT32 (strategy 5), chosen
// hierarchically per aligned 2x2 / 4x4 block cell by rate-distortion. This
// file holds the pieces that are pure math, so `VarDCTEncoder` keeps only the
// bitstream walk:
//
//   1. The LLF <-> DC coupling. A large varblock's lowest-frequency
//      coefficients are NOT in the AC token stream: the decoder fills them
//      from the DC image with `insertLLF` (DCTTransforms.swift) after AC
//      dequant and before the inverse transform. `encDCT16DCFromLLF` /
//      `encDCT32DCFromLLF` are the exact numeric inverses of that function for
//      strategies 4 and 5, so the DC samples this encoder quantizes are
//      precisely the ones that reproduce the forward transform's 2x2 / 4x4
//      corner.
//
//   2. The per-cell RD choice (`encStrategyACCost`): the pixel-domain
//      distortion + lambda * rate of quantizing one candidate transform's
//      luma AC coefficients, in units both candidates share.
//
// The load-bearing rule, as everywhere in the encoder: every constant here is
// read off the decoder that consumes it, not off the spec.

import Foundation

/// AC strategy indices this encoder places (`AcStrategyType`).
let kEncStrategyDCT8 = 0
let kEncStrategyDCT16 = 4
let kEncStrategyDCT32 = 5

// MARK: - LLF <-> DC coupling (inverse of insertLLF, strategy 4)
//
// `insertLLF` for a 2x2-covering strategy computes, from the four DC-image
// samples D[iy][ix] under the varblock (iy/ix = 0,1):
//
//   H[v][u] = 2-point scaled forward DCT of (D[v][0], D[v][1])
//           = ((D[v][0] + D[v][1]) / 2, (D[v][0] - D[v][1]) / 2)
//   V[u][v] = 2-point scaled forward DCT of (H[0][u], H[1][u])
//   coeffs[u*16 + v] = V[u][v] * s[v] * s[u]
//
// with s = `DCTResampleScales<2, 16>` = kResampleScale2 (DCTTransforms.swift).
// Both stages are involutive up to the factor 2 (F0 = (f0+f1)/2, F1 =
// (f0-f1)/2  <=>  f0 = F0+F1, f1 = F0-F1), so the inverse below is exact.

/// `kResampleScale2[1]` from DCTTransforms.swift (`[1.0, 1.108937...]`).
let kEncResampleScale2: Float = 1.108937353592731823

/// The four DC-image samples (row-major: D00, D01, D10, D11 at block offsets
/// (0,0), (1,0), (0,1), (1,1)) that `insertLLF(strategy: 4)` turns back into
/// the DCT16 coefficient corner `c[0]`, `c[1]`, `c[16]`, `c[17]`.
@inline(__always)
func encDCT16DCFromLLF(_ c: UnsafePointer<Float>) -> (Float, Float, Float, Float) {
    let s = kEncResampleScale2
    let v00 = c[0]  // s[0] * s[0] == 1
    let v01 = c[1] / s  // storage u=0, v=1  -> vertical frequency
    let v10 = c[16] / s  // storage u=1, v=0  -> horizontal frequency
    let v11 = c[17] / (s * s)
    let h00 = v00 + v01  // H[0][0]
    let h10 = v00 - v01  // H[1][0]
    let h01 = v10 + v11  // H[0][1]
    let h11 = v10 - v11  // H[1][1]
    return (h00 + h01, h00 - h01, h10 + h11, h10 - h11)
}

/// True at the four LLF storage positions of a DCT16 varblock — `u < 2 && v <
/// 2` in the `S[u*16 + v]` layout, i.e. exactly `computeNaturalCoeffOrder(cbx:
/// 2, cby: 2)`'s first four entries {0, 1, 16, 17}. These are filled from the
/// DC image, never coded in the AC stream.
@inline(__always)
func encIsDCT16LLF(_ k: Int) -> Bool { (k >> 4) < 2 && (k & 15) < 2 }

/// True at the four LLF storage positions of a DCT32 varblock — `u < 4 && v <
/// 4` in the `S[u*32 + v]` layout, i.e. exactly `computeNaturalCoeffOrder(cbx:
/// 4, cby: 4)`'s first sixteen entries. Filled from the DC image, never coded.
@inline(__always)
func encIsDCT32LLF(_ k: Int) -> Bool { (k >> 5) < 4 && (k & 31) < 4 }

/// True at the LLF position(s) of a varblock of `size` coefficients (64 =
/// DCT8, one LLF at index 0; 256 = DCT16, the 2x2 corner; 1024 = DCT32, the
/// 4x4 corner).
@inline(__always)
func encIsLLF(size: Int, _ k: Int) -> Bool {
    switch size {
    case 64: return k == 0
    case 256: return encIsDCT16LLF(k)
    default: return encIsDCT32LLF(k)
    }
}

// MARK: - LLF <-> DC coupling (inverse of insertLLF, strategy 5)
//
// The DCT32 case is the same construction one level up: `insertLLF` for a
// 4x4-covering strategy takes the 4x4 patch of DC samples D[iy][ix] under the
// varblock and computes
//
//   rows[v][u] = 4-point forward scaled DCT of D[v][0..3]      (horizontal)
//   f_u[v]     = 4-point forward scaled DCT of rows[0..3][u]   (vertical)
//   coeffs[u*32 + v] = f_u[v] * s[v] * s[u],  s = kResampleScale4
//
// so the inverse is: undo the two resample scales, then apply the 4-point
// scaled INVERSE DCT twice. The 4-point forward there is
// `F[k] = w(k)/4 Σ_x f(x) cos((2x+1)kπ/8)`, whose exact inverse is
// `f(x) = Σ_k w(k) cos((2x+1)kπ/8) F[k]` — i.e. `makeIDCTBasis(4)` — because
// `Σ_k w(k)² cos((2x+1)kπ/8) cos((2y+1)kπ/8) = 4·δ(x,y)`. Both tables below
// are therefore read off the decoder, not off the spec, exactly as for DCT16.

/// `kResampleScale4` from DCTTransforms.swift.
let kEncResampleScale4: [Float] = [
    1.0, 1.025760096781116015, 1.108937353592731823, 1.270559368765487251,
]

/// `makeIDCTBasis(4)`: `b[x*4 + k] = w(k) * cos((2x+1) k π / 8)`.
let kEncIDCT4Basis: [Float] = {
    var b = [Float](repeating: 0, count: 16)
    for x in 0..<4 {
        for k in 0..<4 {
            let w: Double = k == 0 ? 1.0 : 2.0.squareRoot()
            b[x * 4 + k] = Float(w * cos(Double(2 * x + 1) * Double(k) * Double.pi / 8))
        }
    }
    return b
}()

/// The sixteen DC-image samples (row-major over the varblock's 4x4 block
/// patch) that `insertLLF(strategy: 5)` turns back into the DCT32 coefficient
/// corner `c[u*32 + v]`, `u, v < 4`. Writes 16 floats to `out`.
@inline(__always)
func encDCT32DCFromLLF(_ c: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
    kEncResampleScale4.withUnsafeBufferPointer { s in
        kEncIDCT4Basis.withUnsafeBufferPointer { b in
            // Undo the vertical stage: rows[v][u] for u, v < 4.
            var rows = [Float](repeating: 0, count: 16)
            for u in 0..<4 {
                var f = (Float(0), Float(0), Float(0), Float(0))
                f.0 = c[u * 32] / s[u]
                f.1 = c[u * 32 + 1] / (s[1] * s[u])
                f.2 = c[u * 32 + 2] / (s[2] * s[u])
                f.3 = c[u * 32 + 3] / (s[3] * s[u])
                for v in 0..<4 {
                    rows[v * 4 + u] =
                        b[v * 4] * f.0 + b[v * 4 + 1] * f.1 + b[v * 4 + 2] * f.2
                        + b[v * 4 + 3] * f.3
                }
            }
            // Undo the horizontal stage: D[iy][ix].
            for iy in 0..<4 {
                let r0 = rows[iy * 4], r1 = rows[iy * 4 + 1]
                let r2 = rows[iy * 4 + 2], r3 = rows[iy * 4 + 3]
                for ix in 0..<4 {
                    out[iy * 4 + ix] =
                        b[ix * 4] * r0 + b[ix * 4 + 1] * r1 + b[ix * 4 + 2] * r2
                        + b[ix * 4 + 3] * r3
                }
            }
        }
    }
}

// MARK: - Strategy selection (rate-distortion)
//
// Units. This repo's scaled inverse DCT gives every basis function of an NxN
// transform squared pixel-norm N*N, so a coefficient error e costs N*N*e² of
// pixel SSE — i.e. `size` * e², since size == covered * 64 == the varblock's
// pixel count. Weighting each candidate's coefficient-space squared error by
// its own `size` therefore puts DCT8 and DCT16 in the SAME pixel-SSE units
// over the same 16x16 region (4 * 64 * Σe² vs 256 * Σe²), which is the only
// way the comparison can be honest — the transforms have different
// coefficient counts and different basis normalizations.
//
// Rate is plain bits (`encRDQuant`'s own model: a per-nonzero floor plus
// log2|q|), NOT weighted by size: a bit is a bit whichever transform emits it.
// Weighting rate by size too would make DCT16's bits 4x more expensive than
// DCT8's, which is exactly backwards.
//
// Lambda then has pixel-SSE-per-bit units and must be identical for both
// candidates. It is anchored to the same convention `encRDQuant` uses
// (lambda ∝ step², so the decision is invariant across quality settings):
// `kRDLambda0 * kEncStratRefEnergy * scaledDequant²`, where
// `kEncStratRefEnergy` is one fixed number derived from the DCT8 table's luma
// AC steps. `JXL_DCT16_LAMBDA` scales it for offline sweeps.
//
// All THREE channels are costed. A luma-only model was tried first and it was
// wrong in a way the measurements caught: the DCT16 quant table's chroma seeds
// are far finer than DCT8's at the lowest AC frequencies (X 8996 vs 3150, B
// 1157 vs 512), so a DCT16 varblock resolves chroma detail four 8x8 blocks
// would have thrown away — real bits that a luma-only model cannot see. On the
// 6 MP noise bench that made the selector pick DCT16 for ~63% of blocks even
// when judged on modeled rate alone, while the actual stream grew 22%.
//
// The per-color-tile chroma-from-luma fit (E5c) does not exist yet at decision
// time — it is accumulated from whichever transform each varblock ends up
// using — so the cost model uses the DEFAULT correlation the bitstream
// baselines on (X against 0, B against the reconstructed Y). Both candidates
// are judged under the same assumption, so the comparison stays fair.

/// Selection master switch. `JXL_DCT16=0` forces the all-DCT8 (E5d) encoder;
/// the suite pins that path byte-identical to the pre-E5e bitstream.
let kEncDCT16Enabled: Bool = {
    if let s = ProcessInfo.processInfo.environment["JXL_DCT16"] { return s != "0" }
    return true
}()

/// DCT32 (AC strategy 5) master switch. `JXL_DCT32=0` restricts the encoder to
/// the E5e DCT8+DCT16 mix, which is how the E5l addition is isolated when
/// measuring. DCT32 is only ever considered where DCT16 already is.
///
/// A note on why DCT32 is NOT gated behind its own frame race the way DCT16 is
/// (see the E5f discussion below): DCT16 and DCT32 land in the SAME block
/// context. `kStrategyOrder` maps strategy 4 -> order bucket 2 and strategy 5
/// -> bucket 3, and the default block context map's luma row is
/// [0, 1, 2, 2, 3, ...] — buckets 2 and 3 both select cluster 2 (and both
/// chroma rows likewise select 9). So mixing DCT32 into a frame that already
/// contains DCT16 adds NO new ANS histogram bucket, which is exactly the
/// frame-global cost that made the DCT16-vs-DCT8 decision unpriceable per
/// cell. The per-cell RD choice can therefore stand on its own here, and the
/// existing large-vs-all-DCT8 race still covers the case where large
/// transforms should not be used at all.
let kEncDCT32Enabled: Bool = {
    if let s = ProcessInfo.processInfo.environment["JXL_DCT32"] { return s != "0" }
    return true
}()

/// Admission test for the DCT32 candidate: evaluate a 4x4 super-cell only when
/// at least one of its four 2x2 cells already chose DCT16. `JXL_DCT32_GATE=0`
/// evaluates every super-cell, which is how the gate was verified — it is a
/// SPEED gate, not a quality one, and must stay one.
let kEncDCT32Gate: Bool = {
    if let s = ProcessInfo.processInfo.environment["JXL_DCT32_GATE"] { return s != "0" }
    return true
}()

/// Scale on the strategy-selection lambda (offline RD sweeps).
let kEncStratLambdaScale: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_DCT16_LAMBDA"], let v = Float(s) {
        return v
    }
    return 1.0
}()

/// Modeled bits a varblock costs per channel beyond its coefficients: the
/// non-zero-count token plus its effect on the neighbours' predictions. Four
/// DCT8 varblocks pay this four times where one DCT16 pays it once, which is a
/// real part of why large transforms win on flat content.
let kEncStratBlockBits: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_DCT16_BLOCKBITS"], let v = Float(s) {
        return v
    }
    return 2.0
}()

/// Modeled bits per ZERO coded before the last non-zero of the scan. Counting
/// only non-zeros is not an honest rate model here and measurement said so:
/// `decodeACGroupPass` walks the coefficient order from `covered` until the
/// non-zero budget is exhausted, so every zero BEFORE the last non-zero costs
/// a zero-density token. A 256-coefficient DCT16 scan pays that on far more
/// positions than four 64-coefficient DCT8 scans do, which is exactly the
/// hidden cost that made DCT16 lose ~35% size at q70 on the noisy 6 MP bench
/// when the model ignored it. Zeros are cheap but not free; 0.22 bits was the
/// best of a {0, 0.1, 0.22, 0.35, 0.5} sweep across both fixtures.
let kEncStratZeroBits: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_DCT16_ZEROBITS"], let v = Float(s) {
        return v
    }
    return 0.22
}()

// E5f NEGATIVE RESULT, recorded so it is not retried: a per-cell "scan depth"
// guard (reject DCT16 when its non-zeros run deeper than a fraction of the
// 256-coefficient scan) was implemented and swept over {0.45, 0.30, 0.20,
// 0.12} against a guard-disabled control in the same run. It does not work,
// for a reason worth keeping: scan depth is dominated by the QUANT STEP, not
// by content. At q90 the fine step leaves non-zeros deep in the scan even for
// smooth cells, so every threshold <= 0.45 rejected ALL DCT16 blocks and
// reproduced the DCT8-only result exactly (30847 B / 37.643 dB), destroying
// E5e's entire q90 win (27264 B / 39.940 dB) — while the noisy bench still
// never approached the DCT8-only 138482 B (best 155001 at depth 0.12).
//
// Both that sweep and the earlier `kEncStratZeroBits` sweep floor around
// 155-156 KB on the noisy bench, well above pure DCT8. That common floor is
// the actual mechanism: DCT16 blocks use a different block-context bucket
// than DCT8 (`kStrategyOrder`), so ANY mixture fragments the ANS histograms —
// a frame-global cost no per-cell criterion can price. On such content the
// choice is effectively all-or-nothing, which is why the fix below is a
// FRAME-LEVEL race rather than a smarter per-cell test.

/// Lambda for the E5f frame-level race, in SSE per byte per squared quant
/// step. The race scores each candidate as `SSE + lambda * step^2 * bytes`,
/// so it slides along the same rate/quality tradeoff the coefficient RD uses
/// and a merely-smaller-but-worse candidate cannot win. Calibrated so the
/// measured cases land the way true RD says they should: the noisy bench at
/// q70 (DCT16 +23% size for +0.07 dB) picks all-DCT8, while the photo (DCT16
/// smaller AND higher PSNR at every quality) picks DCT16 — the latter is
/// decided on both axes at once, so it is insensitive to this constant.
let kEncFrameRaceLambda: Double = {
    if let s = ProcessInfo.processInfo.environment["JXL_FRAME_RACE_LAMBDA"],
        let v = Double(s)
    {
        return v
    }
    return 6.0
}()

/// Reference squared luma AC step at unit `scaledDequant`, already in
/// pixel-SSE units (mean of the DCT8 table's Y AC dequant values squared,
/// times the 8x8 basis energy 64). Fixed and shared by both candidates, so the
/// selection lambda is a single well-defined number that still scales as
/// step² across quality settings.
let kEncStratRefEnergy: Float = {
    let t = defaultDequantTable(.dct)
    var s: Float = 0
    for k in 1..<64 { s += t[64 + k] * t[64 + k] }
    return 64 * s / 63
}()

/// The single quant value a multi-block varblock carries: the rounded mean of
/// its `cov * cov` blocks' own adaptive-quant values (E5b). The decoder fills
/// every covered block with one coded value, so there is nothing finer to
/// carry; the same number is used for the RD comparison so all candidates over
/// a region are judged under one quantization step.
@inline(__always)
func encCellQuant(_ blockQuant: [Int32], gw: Int, bxl: Int, byl: Int, cov: Int = 2) -> Int32 {
    var s: Int32 = 0
    for dy in 0..<cov {
        let row = (byl + dy) * gw + bxl
        for dx in 0..<cov { s += blockQuant[row + dx] }
    }
    let n = Int32(cov * cov)
    return min(256, max(1, (s + n / 2) / n))
}

/// Pixel-domain RD cost of one candidate transform over all three channels:
/// `size * Σ (c - recon)² + lambda * rate`, with `recon` mirroring the
/// decoder's `adjustQuantBias` and every quantized value chosen by the same
/// `encRDQuant` the real encode uses.
///
/// The walk is the DECODER'S walk: `order` (the strategy's natural coefficient
/// order) from `covered` to `size`, which skips exactly the LLF positions and
/// visits the rest in the scan the zero-density coder uses — so "how far into
/// the scan the last non-zero sits", and hence how many zero tokens each
/// channel pays, is measured, not assumed. `table` is the candidate's dequant
/// table (`[X size, Y size, B size]`).
/// Returns the RD cost and, as `scanDepth`, the deepest position in the
/// coefficient scan at which ANY channel still has a non-zero (relative to
/// `size`). Scan depth is the signal the E5f guard uses: a large transform
/// earns its place by CONCENTRATING energy at low frequencies, so a candidate
/// whose non-zeros run deep into a 256-coefficient scan is precisely the
/// content (noise) where the modeled rate underestimates the real cost.
func encStrategyACCost(
    cX: UnsafePointer<Float>, cY: UnsafePointer<Float>, cB: UnsafePointer<Float>,
    table: UnsafePointer<Float>, order: UnsafePointer<UInt32>,
    size: Int, covered: Int, scaledDequant: Float, lambda: Float,
    scanDepth: UnsafeMutablePointer<Float>? = nil
) -> Float {
    var dist: Float = 0
    var nzBits: Float = 0
    var nonzerosX = 0, nonzerosY = 0, nonzerosB = 0
    var lastX = covered - 1, lastY = covered - 1, lastB = covered - 1
    for k in covered..<size {
        let idx = Int(order[k])
        // Y first: the B channel's baseline correlation is against the value
        // the decoder will reconstruct for Y, not against the source.
        let yMul = table[size + idx] * scaledDequant
        let cy = cY[idx]
        let qy = encRDQuant(
            c: cy, mul: yMul, q0: Int32((cy / yMul).rounded()), bias: kEncQuantBiasY)
        let recY = encAdjustQuantBias(qy, kEncQuantBiasY) * yMul
        var e = cy - recY
        dist += e * e
        if qy != 0 {
            nzBits += kRDNonzeroBits + log2(Float(abs(qy)))
            nonzerosY += 1
            lastY = k
        }

        let xMul = table[idx] * scaledDequant
        let cx = cX[idx]  // default correlation baseX == 0
        let qx = encRDQuant(
            c: cx, mul: xMul, q0: Int32((cx / xMul).rounded()), bias: kEncQuantBiasX)
        e = cx - encAdjustQuantBias(qx, kEncQuantBiasX) * xMul
        dist += e * e
        if qx != 0 {
            nzBits += kRDNonzeroBits + log2(Float(abs(qx)))
            nonzerosX += 1
            lastX = k
        }

        let bMul = table[2 * size + idx] * scaledDequant
        let cb = cB[idx] - recY  // default correlation baseB == 1
        let qb = encRDQuant(
            c: cb, mul: bMul, q0: Int32((cb / bMul).rounded()), bias: kEncQuantBiasB)
        e = cb - encAdjustQuantBias(qb, kEncQuantBiasB) * bMul
        dist += e * e
        if qb != 0 {
            nzBits += kRDNonzeroBits + log2(Float(abs(qb)))
            nonzerosB += 1
            lastB = k
        }
    }
    let zeros =
        Float(lastY + 1 - covered - nonzerosY) + Float(lastX + 1 - covered - nonzerosX)
        + Float(lastB + 1 - covered - nonzerosB)
    let rate = 3 * kEncStratBlockBits + nzBits + kEncStratZeroBits * zeros
    if let scanDepth {
        let deepest = max(lastY, max(lastX, lastB))
        scanDepth.pointee = Float(deepest + 1) / Float(size)
    }
    return Float(size) * dist + lambda * rate
}
