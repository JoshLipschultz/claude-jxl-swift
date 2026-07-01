// Reconstruct.swift
//
// VarDCT reconstruction to pixels for the DCT8 (plain 8x8) case: dequantize AC
// coefficients (with chroma-from-luma), insert the DC, inverse-DCT each block,
// then XYB -> linear -> sRGB. The DCT itself is implemented directly from its
// mathematical definition (a separable inverse DCT-III) rather than by
// transliterating libjxl's recursive butterfly; the normalization is pinned by
// the requirement that a pure-DC block reconstructs to a flat block equal to the
// DC (mean) value, and verified end-to-end against djxl.
//
// The Gaborish and EPF (edge-preserving) restoration filters are applied when
// enabled (libjxl GaborishStage / EPF1Stage); on the current DCT8 fixtures the
// encoder leaves Gaborish off and the EPF sigma is large enough to be
// near-identity, so they do not change output there but are ready for images
// that use them.
//
// Restrictions: DCT8 blocks only (larger transforms not yet handled), single
// pass, 4:4:4. Matches djxl to ~54 dB (numerical precision) on DCT8.

import Foundation

// MARK: - DCT8 quantization weights (libjxl GetQuantWeights, DCT path)

private let kSqrt2: Float = 1.41421356237

private func mult(_ v: Float) -> Float { v > 0 ? 1 + v : 1 / (1 - v) }

/// Distance-band interpolation (libjxl InterpolateVec): a * (b/a)^frac.
private func interpolate(_ pos: Float, _ bands: [Float]) -> Float {
    let idx = Int(pos)
    let frac = pos - Float(idx)
    let a = bands[idx]
    let b = idx + 1 < bands.count ? bands[idx + 1] : bands[idx]
    return a * powf(b / a, frac)
}

/// The DCT8 dequant "matrix" (= 1 / quant weights), 3 channels x 64, in
/// row-major frequency layout `[c*64 + v*8 + u]`.
private func computeDCT8DequantTable() -> [Float] {
    // libjxl DequantMatricesLibraryDef::DCT distance bands (X, Y, B), 6 bands.
    let dist: [[Float]] = [
        [3150.0, 0.0, -0.4, -0.4, -0.4, -2.0],
        [560.0, 0.0, -0.3, -0.3, -0.3, -0.3],
        [512.0, -2.0, -1.0, 0.0, -1.0, -2.0],
    ]
    let numBands = 6
    let scale = Float(numBands - 1) / (kSqrt2 + 1e-6)
    let rcp = scale / 7.0  // (COLS-1) = (ROWS-1) = 7
    var table = [Float](repeating: 0, count: 3 * 64)
    for c in 0..<3 {
        var bands = [Float](repeating: 0, count: numBands)
        bands[0] = dist[c][0]
        for i in 1..<numBands { bands[i] = bands[i - 1] * mult(dist[c][i]) }
        for y in 0..<8 {
            let dy = Float(y) * rcp
            for x in 0..<8 {
                let dx = Float(x) * rcp
                let d = (dx * dx + dy * dy).squareRoot()
                let weight = interpolate(d, bands)
                table[c * 64 + y * 8 + x] = 1.0 / weight
            }
        }
    }
    return table
}

// MARK: - 8x8 inverse DCT (separable DCT-III, DC = mean)

/// Precomputed 1D IDCT basis: `basis[x*8 + u] = w(u) * cos((2x+1)u pi / 16)`,
/// with w(0)=1 (DC -> flat) and w(u>0)=sqrt(2), matching libjxl's DCT-III
/// normalization (cf. the 2-point butterfly `p0=c0+c1, p1=c0-c1`).
private let idctBasis8: [Float] = {
    var m = [Float](repeating: 0, count: 64)
    for x in 0..<8 {
        for u in 0..<8 {
            let w: Float = u == 0 ? 1.0 : kSqrt2
            m[x * 8 + u] = w * cosf(Float(2 * x + 1) * Float(u) * Float.pi / 16.0)
        }
    }
    return m
}()

private func transpose8(_ a: inout [Float]) {
    for v in 0..<8 { for u in (v + 1)..<8 { a.swapAt(v * 8 + u, u * 8 + v) } }
}

/// In-place separable 8x8 inverse DCT. `block[v*8+u]` holds coefficient F[v][u];
/// on return holds pixel values row-major.
private func idct8x8(_ block: inout [Float]) {
    var tmp = [Float](repeating: 0, count: 64)
    // Columns: for each column u, invert over v.
    for u in 0..<8 {
        for y in 0..<8 {
            var s: Float = 0
            for v in 0..<8 { s += block[v * 8 + u] * idctBasis8[y * 8 + v] }
            tmp[y * 8 + u] = s
        }
    }
    // Rows: for each row y, invert over u. Each 1D pass is self-normalizing
    // (w(0)=1 makes pure DC reconstruct to a flat DC), so there is no overall
    // 1/N^2 factor.
    for y in 0..<8 {
        for x in 0..<8 {
            var s: Float = 0
            for u in 0..<8 { s += tmp[y * 8 + u] * idctBasis8[x * 8 + u] }
            block[y * 8 + x] = s
        }
    }
}

// MARK: - AdjustQuantBias (libjxl quantizer-inl.h)

private let kDefaultQuantBias: [Float] = [
    1.0 - 0.05465007330715401, 1.0 - 0.07005449891748593, 1.0 - 0.049935103337343655, 0.145,
]

private func adjustQuantBias(_ q: Int32, _ c: Int) -> Float {
    if q == 0 { return 0 }
    if q == 1 { return kDefaultQuantBias[c] }
    if q == -1 { return -kDefaultQuantBias[c] }
    let qf = Float(q)
    return qf - kDefaultQuantBias[3] / qf
}

// MARK: - XYB -> linear -> sRGB

private let kOpsinBias: Float = 0.0037930732552754493
private let kInverseOpsin: [Float] = [
    11.031566901960783, -9.866943921568629, -0.16462299647058826,
    -3.254147380392157, 4.418770392156863, -0.16462299647058826,
    -3.6588512862745097, 2.7129230470588235, 1.9459282392156863,
]

private func srgbEncode(_ d: Float) -> Float {
    let v = max(0, min(1, d))
    return v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1.0 / 2.4) - 0.055
}

/// XYB -> sRGB 8-bit, matching libjxl XybToRgb + the sRGB transfer function.
private func xybToSRGB8(x: Float, y: Float, b: Float) -> (UInt8, UInt8, UInt8) {
    // libjxl opsin_biases_cbrt = cbrt(-bias) = -cbrt(bias), and XybToRgb
    // subtracts it — i.e. adds cbrt(bias) — to recover cbrt(mixed).
    let biasCbrt = cbrtf(kOpsinBias)
    let gr = (y + x) + biasCbrt
    let gg = (y - x) + biasCbrt
    let gb = b + biasCbrt
    let mr = gr * gr * gr - kOpsinBias
    let mg = gg * gg * gg - kOpsinBias
    let mb = gb * gb * gb - kOpsinBias
    let lr = kInverseOpsin[0] * mr + kInverseOpsin[1] * mg + kInverseOpsin[2] * mb
    let lg = kInverseOpsin[3] * mr + kInverseOpsin[4] * mg + kInverseOpsin[5] * mb
    let lb = kInverseOpsin[6] * mr + kInverseOpsin[7] * mg + kInverseOpsin[8] * mb
    func to8(_ l: Float) -> UInt8 { UInt8(max(0, min(255, (srgbEncode(l) * 255).rounded()))) }
    return (to8(lr), to8(lg), to8(lb))
}

// MARK: - Gaborish (libjxl GaborishStage)

/// In-place 3x3 Gaborish convolution with 1-pixel mirror border. `weight1` is
/// the edge (N/S/E/W) weight, `weight2` the corner weight; the center is 1,
/// then all are normalized to sum to 1.
private func gaborish(_ p: inout [Float], w: Int, h: Int, weight1: Float, weight2: Float) {
    let div = 1.0 + 4.0 * (weight1 + weight2)
    let c0 = 1.0 / div
    let c1 = weight1 / div
    let c2 = weight2 / div
    let src = p
    @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
        // Mirror: -1 -> 0, w -> w-1 (edge-reflecting, matching libjxl Mirror).
        let mx = x < 0 ? 0 : (x >= w ? w - 1 : x)
        let my = y < 0 ? 0 : (y >= h ? h - 1 : y)
        return src[my * w + mx]
    }
    for y in 0..<h {
        for x in 0..<w {
            let center = src[y * w + x]
            let side = at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)
            let corner =
                at(x - 1, y - 1) + at(x + 1, y - 1) + at(x - 1, y + 1) + at(x + 1, y + 1)
            p[y * w + x] = center * c0 + side * c1 + corner * c2
        }
    }
}

// MARK: - EPF (edge-preserving filter, libjxl stage_epf.cc EPF1Stage)

private let kInvSigmaNum: Float = -1.1715728752538099024
private let kEpfMinSigma: Float = -3.90524291751269967465540850526868
private let kEpfChannelScale: [Float] = [40.0, 5.0, 3.5]
private let kEpfQuantMul: Float = 0.46
private let kEpfBorderSadMul: Float = 0.6666666666666666
private let kEpfSadMulSm: Float = 1.65

/// Per-block inverse sigma (`1/sigma`) for EPF, from the quant field and EPF
/// sharpness (libjxl ComputeSigma). `epfSharpLut[s] = s/7` (default).
private func computeEPFSigma(meta: VarDCTACMetadata, quantScale: Float) -> [Float] {
    let bw = meta.widthBlocks
    let bh = meta.heightBlocks
    var inv = [Float](repeating: 0, count: bw * bh)
    for by in 0..<bh {
        for bx in 0..<bw {
            let q = Float(meta.quantField[by * bw + bx])
            let sharp = Float(meta.epfSharpness[by * bw + bx]) / 7.0
            let sigmaQuant = kEpfQuantMul / (quantScale * q * kInvSigmaNum)
            var sigma = sigmaQuant * sharp
            sigma = min(-1e-4, sigma)
            inv[by * bw + bx] = 1.0 / sigma
        }
    }
    return inv
}

/// One EPF1 pass over the XYB planes. `sigmaInv` is per-block `1/sigma`.
private func epf1(
    x: inout [Float], y: inout [Float], b: inout [Float], w: Int, h: Int,
    sigmaInv: [Float], bw: Int
) {
    let sx = x, sy = y, sb = b
    @inline(__always) func mir(_ i: Int, _ n: Int) -> Int {
        var v = i
        if v < 0 { v = -v - 1 }
        if v >= n { v = 2 * n - 1 - v }
        return max(0, min(n - 1, v))
    }
    @inline(__always) func px(_ p: [Float], _ xx: Int, _ yy: Int) -> Float {
        p[mir(yy, h) * w + mir(xx, w)]
    }
    // 3x3-plus SAD between the plus-neighborhoods at (cx,cy) and (cx+dx,cy+dy),
    // summed over channels with epf_channel_scale.
    @inline(__always) func sad(_ cx: Int, _ cy: Int, _ dx: Int, _ dy: Int) -> Float {
        var s: Float = 0
        for (p, sc) in [(sx, kEpfChannelScale[0]), (sy, kEpfChannelScale[1]), (sb, kEpfChannelScale[2])]
        {
            var d: Float = 0
            d += abs(px(p, cx, cy) - px(p, cx + dx, cy + dy))
            d += abs(px(p, cx - 1, cy) - px(p, cx + dx - 1, cy + dy))
            d += abs(px(p, cx + 1, cy) - px(p, cx + dx + 1, cy + dy))
            d += abs(px(p, cx, cy - 1) - px(p, cx + dx, cy + dy - 1))
            d += abs(px(p, cx, cy + 1) - px(p, cx + dx, cy + dy + 1))
            s += d * sc
        }
        return s
    }
    for cy in 0..<h {
        let borderRow = (cy % 8 == 0) || (cy % 8 == 7)
        for cx in 0..<w {
            let rowSigma = sigmaInv[(cy / 8) * bw + (cx / 8)]
            if rowSigma < kEpfMinSigma { continue }  // too sharp: unchanged
            let onEdge = borderRow || (cx % 8 == 0) || (cx % 8 == 7)
            let sm = onEdge ? kEpfSadMulSm * kEpfBorderSadMul : kEpfSadMulSm
            let invSigma = rowSigma * sm

            var wsum: Float = 1
            var accX = sx[cy * w + cx]
            var accY = sy[cy * w + cx]
            var accB = sb[cy * w + cx]
            for (dx, dy) in [(0, -1), (-1, 0), (1, 0), (0, 1)] {
                let weight = max(0, 1 + sad(cx, cy, dx, dy) * invSigma)
                wsum += weight
                accX += weight * px(sx, cx + dx, cy + dy)
                accY += weight * px(sy, cx + dx, cy + dy)
                accB += weight * px(sb, cx + dx, cy + dy)
            }
            let invW = 1.0 / wsum
            x[cy * w + cx] = accX * invW
            y[cy * w + cx] = accY * invW
            b[cy * w + cx] = accB * invW
        }
    }
}

// MARK: - Full reconstruction

/// Decodes a DCT8-only, single-pass, 4:4:4 VarDCT frame to an 8-bit sRGB image
/// (interleaved RGB, row-major). Restoration filters are not applied.
public func reconstructVarDCTImage(from data: [UInt8]) throws -> (width: Int, height: Int, rgb: [UInt8]) {
    let s = try setupVarDCT(data)
    let meta = try decodeLowFrequency(s)
    let acReader = s.coalesced ? s.r0 : s.sectionReader(s.dim.numDCGroups + 1)
    let acGlobal = try decodeVarDCTACGlobal(
        acReader, dim: s.dim, numPasses: Int(s.frameHeader.numPasses),
        blockContextMap: s.dcGlobal.info.blockContextMap, usedACs: meta.usedACs)
    let coeffs = try decodeVarDCTCoefficients(from: data)
    let dc = try decodeVarDCTDCImage(from: data)

    for b in coeffs.blocks where b.strategy != 0 {
        throw JXLError.unsupported("VarDCT reconstruction currently handles DCT8 blocks only")
    }
    _ = acGlobal

    let dequantTable = computeDCT8DequantTable()
    let invGlobalScale = Float(1 << 16) / Float(s.dcGlobal.info.quantizer.globalScale)
    let xDmMul = powf(1.0 / 1.25, Float(s.frameHeader.xQmScale) - 2.0)
    let bDmMul = powf(1.0 / 1.25, Float(s.frameHeader.bQmScale) - 2.0)

    // Chroma-from-luma bases.
    let cc = s.dcGlobal.info.colorCorrelation
    let colorFactor = Float(cc?.colorFactor ?? 84)
    let colorScale = 1.0 / colorFactor
    let baseX = cc?.baseCorrelationX ?? 0.0
    let baseB = cc?.baseCorrelationB ?? 1.0

    let bw = s.dim.xsizeBlocks
    let pxW = s.dim.xsize
    let pxH = s.dim.ysize
    // Full-resolution XYB planes.
    var planeX = [Float](repeating: 0, count: bw * 8 * s.dim.ysizeBlocks * 8)
    var planeY = planeX
    var planeB = planeX
    let rowStride = bw * 8
    let paddedH = s.dim.ysizeBlocks * 8

    for blk in coeffs.blocks {
        let bx = blk.bx
        let by = blk.by
        let quant = Float(meta.quantField[by * bw + bx])
        let scaledDequant = invGlobalScale / quant
        let ctX = bx / 8
        let ctY = by / 8
        let cmapW = meta.colorTileWidth
        let xCC = baseX + Float(meta.ytoxMap[ctY * cmapW + ctX]) * colorScale
        let bCC = baseB + Float(meta.ytobMap[ctY * cmapW + ctX]) * colorScale

        var bX = [Float](repeating: 0, count: 64)
        var bY = [Float](repeating: 0, count: 64)
        var bB = [Float](repeating: 0, count: 64)
        for k in 0..<64 {
            let xMul = dequantTable[k] * scaledDequant * xDmMul
            let yMul = dequantTable[64 + k] * scaledDequant
            let bMul = dequantTable[128 + k] * scaledDequant * bDmMul
            let dqXcc = adjustQuantBias(blk.coeff[0][k], 0) * xMul
            let dqY = adjustQuantBias(blk.coeff[1][k], 1) * yMul
            let dqBcc = adjustQuantBias(blk.coeff[2][k], 2) * bMul
            bY[k] = dqY
            bX[k] = xCC * dqY + dqXcc
            bB[k] = bCC * dqY + dqBcc
        }
        // Insert DC (LowestFrequenciesFromDC, DCT8: single LLF).
        let dcIdx = by * dc.widthBlocks + bx
        bX[0] = dc.x[dcIdx]
        bY[0] = dc.y[dcIdx]
        bB[0] = dc.b[dcIdx]

        // Coefficients are stored transposed relative to the pixel layout
        // (libjxl folds a transpose into ComputeScaledIDCT).
        transpose8(&bX)
        transpose8(&bY)
        transpose8(&bB)
        idct8x8(&bX)
        idct8x8(&bY)
        idct8x8(&bB)

        let px0 = bx * 8
        let py0 = by * 8
        for yy in 0..<8 {
            for xx in 0..<8 {
                let dst = (py0 + yy) * rowStride + (px0 + xx)
                planeX[dst] = bX[yy * 8 + xx]
                planeY[dst] = bY[yy * 8 + xx]
                planeB[dst] = bB[yy * 8 + xx]
            }
        }
    }

    // Gaborish restoration filter (libjxl GaborishStage), on the full XYB
    // planes with 1-pixel mirror border.
    if s.frameHeader.loopFilterGab {
        let fh = s.frameHeader
        gaborish(&planeX, w: rowStride, h: paddedH, weight1: fh.gabXWeight1, weight2: fh.gabXWeight2)
        gaborish(&planeY, w: rowStride, h: paddedH, weight1: fh.gabYWeight1, weight2: fh.gabYWeight2)
        gaborish(&planeB, w: rowStride, h: paddedH, weight1: fh.gabBWeight1, weight2: fh.gabBWeight2)
    }
    // EPF (edge-preserving filter). For epf_iters == 1 only the single middle
    // pass (EPF1) runs (libjxl dec_cache.cc). Operates on the block-padded XYB.
    if s.frameHeader.loopFilterEpfIters >= 1 {
        let quantScale = Float(s.dcGlobal.info.quantizer.globalScale) / Float(1 << 16)
        let sigmaInv = computeEPFSigma(meta: meta, quantScale: quantScale)
        epf1(
            x: &planeX, y: &planeY, b: &planeB, w: rowStride, h: paddedH,
            sigmaInv: sigmaInv, bw: s.dim.xsizeBlocks)
    }

    var rgb = [UInt8](repeating: 0, count: pxW * pxH * 3)
    for y in 0..<pxH {
        for x in 0..<pxW {
            let src = y * rowStride + x
            let (r, g, b) = xybToSRGB8(x: planeX[src], y: planeY[src], b: planeB[src])
            let dst = (y * pxW + x) * 3
            rgb[dst] = r
            rgb[dst + 1] = g
            rgb[dst + 2] = b
        }
    }
    return (pxW, pxH, rgb)
}

public func reconstructVarDCTImage(from data: Data) throws -> (width: Int, height: Int, rgb: [UInt8]) {
    try reconstructVarDCTImage(from: [UInt8](data))
}
