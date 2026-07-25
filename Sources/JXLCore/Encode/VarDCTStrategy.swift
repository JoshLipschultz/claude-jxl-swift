// VarDCTStrategy.swift
//
// E5e: variable-size AC transforms for the lossy VarDCT encoder — DCT8
// (AC strategy 0) plus DCT16 (AC strategy 4), chosen per aligned 2x2 block
// cell by rate-distortion. This file holds the two pieces of DCT16 machinery
// that are pure math, so `VarDCTEncoder` keeps only the bitstream walk:
//
//   1. The LLF <-> DC coupling. A DCT16 varblock's four lowest-frequency
//      coefficients are NOT in the AC token stream: the decoder fills them
//      from the DC image with `insertLLF` (DCTTransforms.swift) after AC
//      dequant and before the inverse transform. `encDCT16DCFromLLF` is the
//      exact numeric inverse of that function for strategy 4, so the four DC
//      samples this encoder quantizes are precisely the ones that reproduce
//      the forward transform's 2x2 corner.
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

/// True at the LLF position(s) of a varblock of `size` coefficients (64 =
/// DCT8, one LLF at index 0; 256 = DCT16, the 2x2 corner).
@inline(__always)
func encIsLLF(size: Int, _ k: Int) -> Bool {
    size == 64 ? k == 0 : encIsDCT16LLF(k)
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

/// The single quant value a 2x2 cell's DCT16 varblock carries: the rounded
/// mean of its four blocks' own adaptive-quant values (E5b). The decoder fills
/// every covered block with one coded value, so there is nothing finer to
/// carry; the same number is used for the RD comparison so both candidates are
/// judged under one quantization step.
@inline(__always)
func encCellQuant(_ blockQuant: [Int32], gw: Int, bxl: Int, byl: Int) -> Int32 {
    let a = blockQuant[byl * gw + bxl]
    let b = blockQuant[byl * gw + bxl + 1]
    let c = blockQuant[(byl + 1) * gw + bxl]
    let d = blockQuant[(byl + 1) * gw + bxl + 1]
    return min(256, max(1, (a + b + c + d + 2) / 4))
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
func encStrategyACCost(
    cX: UnsafePointer<Float>, cY: UnsafePointer<Float>, cB: UnsafePointer<Float>,
    table: UnsafePointer<Float>, order: UnsafePointer<UInt32>,
    size: Int, covered: Int, scaledDequant: Float, lambda: Float
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
    return Float(size) * dist + lambda * rate
}
