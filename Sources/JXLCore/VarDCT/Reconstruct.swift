// Reconstruct.swift
//
// VarDCT reconstruction to XYB planes: dequantize AC coefficients (with
// chroma-from-luma), insert the lowest frequencies from the DC image, apply the
// block's inverse transform (any strategy up to 32x32 — see Transforms.swift),
// then the Gaborish and EPF (edge-preserving) restoration filters when enabled
// (libjxl GaborishStage / EPF1Stage). Per-strategy dequant matrices come from
// DequantWeights.swift.
//
// The output is an `XYBImage`; conversion to display pixels is the color
// pipeline's job (Color/ColorManagement.swift).
//
// Restrictions: transforms up to 32x32 (no DCT64+), single pass, 4:4:4.

import Foundation

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

extension FrameDecoder {
    /// Reconstructs the frame's XYB planes: dequant + chroma-from-luma, LLF
    /// insertion from the DC image, per-block inverse transforms, then the
    /// enabled restoration filters. Handles all AC strategies up to 32x32.
    func reconstructXYB() throws -> XYBImage {
        let lf = try varDCTLowFrequency()
        let coeffs = try varDCTCoefficients()
        let dcGlobalInfo = try varDCTDCGlobal().info
        let meta = lf.metadata
        let dc = lf.dc

        for b in coeffs.blocks where b.strategy >= kStrategyQuantTable.count {
            throw JXLError.unsupported("VarDCT transforms larger than 32x32")
        }

        // Dequant tables per quant-table kind, computed once for the kinds in use.
        var dequantTables = [[Float]?](repeating: nil, count: QuantTableKind.allCases.count)
        for b in coeffs.blocks {
            let kind = kStrategyQuantTable[Int(b.strategy)]
            if dequantTables[kind.rawValue] == nil {
                dequantTables[kind.rawValue] = defaultDequantTable(kind)
            }
        }

        let invGlobalScale = Float(1 << 16) / Float(dcGlobalInfo.quantizer.globalScale)
        let xDmMul = powf(1.0 / 1.25, Float(frameHeader.xQmScale) - 2.0)
        let bDmMul = powf(1.0 / 1.25, Float(frameHeader.bQmScale) - 2.0)

        // Chroma-from-luma bases.
        let cc = dcGlobalInfo.colorCorrelation
        let colorFactor = Float(cc?.colorFactor ?? 84)
        let colorScale = 1.0 / colorFactor
        let baseX = cc?.baseCorrelationX ?? 0.0
        let baseB = cc?.baseCorrelationB ?? 1.0

        let bw = dim.xsizeBlocks
        let rowStride = bw * 8
        let paddedH = dim.ysizeBlocks * 8
        var planeX = [Float](repeating: 0, count: rowStride * paddedH)
        var planeY = planeX
        var planeB = planeX

        // Scratch buffers reused across blocks (max transform is 32x32 = 1024).
        var scratchX = [Float](repeating: 0, count: 1024)
        var scratchY = [Float](repeating: 0, count: 1024)
        var scratchB = [Float](repeating: 0, count: 1024)
        var scratchTmp = [Float](repeating: 0, count: 1024)

        planeX.withUnsafeMutableBufferPointer { pX in
        planeY.withUnsafeMutableBufferPointer { pY in
        planeB.withUnsafeMutableBufferPointer { pB in
        scratchX.withUnsafeMutableBufferPointer { sXBuf in
        scratchY.withUnsafeMutableBufferPointer { sYBuf in
        scratchB.withUnsafeMutableBufferPointer { sBBuf in
        scratchTmp.withUnsafeMutableBufferPointer { tmpBuf in
            let bufX = sXBuf.baseAddress!
            let bufY = sYBuf.baseAddress!
            let bufB = sBBuf.baseAddress!
            let tmp = tmpBuf.baseAddress!

            for blk in coeffs.blocks {
                let bx = blk.bx
                let by = blk.by
                let strategy = Int(blk.strategy)
                let size = blk.coveredX * blk.coveredY * 64
                let quant = Float(meta.quantField[by * bw + bx])
                let scaledDequant = invGlobalScale / quant
                let ctX = bx / 8
                let ctY = by / 8
                let cmapW = meta.colorTileWidth
                let xCC = baseX + Float(meta.ytoxMap[ctY * cmapW + ctX]) * colorScale
                let bCC = baseB + Float(meta.ytobMap[ctY * cmapW + ctX]) * colorScale

                // Dequantize with quant biases + chroma-from-luma (elementwise: the
                // dequant matrix layout matches the coefficient storage).
                let table = dequantTables[kStrategyQuantTable[strategy].rawValue]!
                table.withUnsafeBufferPointer { t in
                    blk.coeff[0].withUnsafeBufferPointer { cX in
                    blk.coeff[1].withUnsafeBufferPointer { cY in
                    blk.coeff[2].withUnsafeBufferPointer { cB in
                        for k in 0..<size {
                            let xMul = t[k] * scaledDequant * xDmMul
                            let yMul = t[size + k] * scaledDequant
                            let bMul = t[2 * size + k] * scaledDequant * bDmMul
                            let dqXcc = adjustQuantBias(cX[k], 0) * xMul
                            let dqY = adjustQuantBias(cY[k], 1) * yMul
                            let dqBcc = adjustQuantBias(cB[k], 2) * bMul
                            bufY[k] = dqY
                            bufX[k] = xCC * dqY + dqXcc
                            bufB[k] = bCC * dqY + dqBcc
                        }
                    }
                    }
                    }
                }

                // Insert the lowest frequencies from the DC image.
                let dcOrigin = by * dc.widthBlocks + bx
                insertLLF(bufX, strategy: strategy, dc: dc.x, dcStride: dc.widthBlocks, dcOrigin: dcOrigin)
                insertLLF(bufY, strategy: strategy, dc: dc.y, dcStride: dc.widthBlocks, dcOrigin: dcOrigin)
                insertLLF(bufB, strategy: strategy, dc: dc.b, dcStride: dc.widthBlocks, dcOrigin: dcOrigin)

                // Inverse transform straight into the padded XYB planes.
                let origin = by * 8 * rowStride + bx * 8
                for (buf, plane) in [(bufX, pX.baseAddress!), (bufY, pY.baseAddress!), (bufB, pB.baseAddress!)] {
                    let out = plane + origin
                    switch strategy {
                    case 1:
                        identityTransform(buf, pixels: out, stride: rowStride)
                    case 2:
                        dct2x2Transform(buf, pixels: out, stride: rowStride)
                    case 3:
                        dct4x4Transform(buf, pixels: out, stride: rowStride, scratch: tmp)
                    case 12:
                        dct4x8Transform(buf, pixels: out, stride: rowStride, scratch: tmp)
                    case 13:
                        dct8x4Transform(buf, pixels: out, stride: rowStride, scratch: tmp)
                    case 14, 15, 16, 17:
                        afvTransform(kind: strategy - 14, buf, pixels: out, stride: rowStride, scratch: tmp)
                    default:
                        scaledIDCT(
                            buf, h: kStrategyBlockH[strategy], w: kStrategyBlockW[strategy],
                            pixels: out, stride: rowStride, tmp: tmp)
                    }
                }
            }
        }
        }
        }
        }
        }
        }
        }

        // Gaborish restoration filter (libjxl GaborishStage), on the full XYB
        // planes with 1-pixel mirror border.
        if frameHeader.loopFilterGab {
            let fh = frameHeader
            gaborish(&planeX, w: rowStride, h: paddedH, weight1: fh.gabXWeight1, weight2: fh.gabXWeight2)
            gaborish(&planeY, w: rowStride, h: paddedH, weight1: fh.gabYWeight1, weight2: fh.gabYWeight2)
            gaborish(&planeB, w: rowStride, h: paddedH, weight1: fh.gabBWeight1, weight2: fh.gabBWeight2)
        }
        // EPF (edge-preserving filter). For epf_iters == 1 only the single middle
        // pass (EPF1) runs (libjxl dec_cache.cc). Operates on the block-padded XYB.
        if frameHeader.loopFilterEpfIters >= 1 {
            let quantScale = Float(dcGlobalInfo.quantizer.globalScale) / Float(1 << 16)
            let sigmaInv = computeEPFSigma(meta: meta, quantScale: quantScale)
            epf1(
                x: &planeX, y: &planeY, b: &planeB, w: rowStride, h: paddedH,
                sigmaInv: sigmaInv, bw: dim.xsizeBlocks)
        }

        return XYBImage(
            width: dim.xsize, height: dim.ysize, stride: rowStride, paddedHeight: paddedH,
            x: planeX, y: planeY, b: planeB)
    }
}

/// Decodes a single-pass, 4:4:4 VarDCT frame to an 8-bit sRGB image
/// (interleaved RGB, row-major). Handles all AC strategies up to 32x32.
@_spi(Stages) public func reconstructVarDCTImage(from data: [UInt8]) throws -> (width: Int, height: Int, rgb: [UInt8]) {
    let xyb = try FrameDecoder(data: data).reconstructXYB()
    return (xyb.width, xyb.height, xybToSRGB8Interleaved(xyb))
}

@_spi(Stages) public func reconstructVarDCTImage(from data: Data) throws -> (width: Int, height: Int, rgb: [UInt8]) {
    try reconstructVarDCTImage(from: [UInt8](data))
}
