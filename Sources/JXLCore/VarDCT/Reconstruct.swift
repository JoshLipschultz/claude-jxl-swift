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
// Restrictions: single pass; chroma subsampling for YCbCr frames only.

import Foundation

// MARK: - AdjustQuantBias (libjxl quantizer-inl.h)

// Scalars, not a [Float]: this runs per coefficient on every worker thread,
// and a global array would be re-retained (one shared contended refcount) per
// access.
private let kQuantBiasX: Float = 1.0 - 0.05465007330715401
private let kQuantBiasY: Float = 1.0 - 0.07005449891748593
private let kQuantBiasB: Float = 1.0 - 0.049935103337343655
private let kQuantBiasNumerator: Float = 0.145

@inline(__always)
private func quantBias(_ c: Int) -> Float {
    c == 0 ? kQuantBiasX : (c == 1 ? kQuantBiasY : kQuantBiasB)
}

@inline(__always)
private func adjustQuantBias(_ q: Int32, _ c: Int) -> Float {
    if q == 0 { return 0 }
    if q == 1 { return quantBias(c) }
    if q == -1 { return -quantBias(c) }
    let qf = Float(q)
    return qf - kQuantBiasNumerator / qf
}

// MARK: - Gaborish (libjxl GaborishStage)

/// In-place 3x3 Gaborish convolution with 1-pixel mirror border. `weight1` is
/// the edge (N/S/E/W) weight, `weight2` the corner weight; the center is 1,
/// then all are normalized to sum to 1. Output rows depend only on the input
/// snapshot, so rows run concurrently.
private func gaborish(_ p: inout [Float], w: Int, h: Int, weight1: Float, weight2: Float) {
    let div = 1.0 + 4.0 * (weight1 + weight2)
    let c0 = 1.0 / div
    let c1 = weight1 / div
    let c2 = weight2 / div
    let srcCopy = p
    srcCopy.withUnsafeBufferPointer { srcBuf in
        p.withUnsafeMutableBufferPointer { dstBuf in
            nonisolated(unsafe) let src = srcBuf.baseAddress!
            nonisolated(unsafe) let dst = dstBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                @inline(__always) func at(_ x: Int, _ yy: Int) -> Float {
                    // Mirror: -1 -> 0, w -> w-1 (edge-reflecting, libjxl Mirror).
                    let mx = x < 0 ? 0 : (x >= w ? w - 1 : x)
                    let my = yy < 0 ? 0 : (yy >= h ? h - 1 : yy)
                    return src[my * w + mx]
                }
                for x in 0..<w {
                    let center = src[y * w + x]
                    let side = at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)
                    let corner =
                        at(x - 1, y - 1) + at(x + 1, y - 1) + at(x - 1, y + 1) + at(x + 1, y + 1)
                    dst[y * w + x] = center * c0 + side * c1 + corner * c2
                }
            }
        }
    }
}

// MARK: - EPF (edge-preserving filter, libjxl stage_epf.cc EPF1Stage)

private let kInvSigmaNum: Float = -1.1715728752538099024
private let kEpfMinSigma: Float = -3.90524291751269967465540850526868
private let kEpfChannelScaleX: Float = 40.0
private let kEpfChannelScaleY: Float = 5.0
private let kEpfChannelScaleB: Float = 3.5
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
/// Output rows depend only on the input snapshots, so rows run concurrently;
/// the neighborhood SAD is fully scalarized (no per-pixel temporaries).
private func epf1(
    x: inout [Float], y: inout [Float], b: inout [Float], w: Int, h: Int,
    sigmaInv: [Float], bw: Int
) {
    let sxCopy = x, syCopy = y, sbCopy = b
    sxCopy.withUnsafeBufferPointer { sxBuf in
    syCopy.withUnsafeBufferPointer { syBuf in
    sbCopy.withUnsafeBufferPointer { sbBuf in
    sigmaInv.withUnsafeBufferPointer { sigBuf in
    x.withUnsafeMutableBufferPointer { xBuf in
    y.withUnsafeMutableBufferPointer { yBuf in
    b.withUnsafeMutableBufferPointer { bBuf in
        nonisolated(unsafe) let sx = sxBuf.baseAddress!
        nonisolated(unsafe) let sy = syBuf.baseAddress!
        nonisolated(unsafe) let sb = sbBuf.baseAddress!
        nonisolated(unsafe) let sig = sigBuf.baseAddress!
        nonisolated(unsafe) let dx_ = xBuf.baseAddress!
        nonisolated(unsafe) let dy_ = yBuf.baseAddress!
        nonisolated(unsafe) let db_ = bBuf.baseAddress!

        DispatchQueue.concurrentPerform(iterations: h) { cy in
            @inline(__always) func mir(_ i: Int, _ n: Int) -> Int {
                var v = i
                if v < 0 { v = -v - 1 }
                if v >= n { v = 2 * n - 1 - v }
                return max(0, min(n - 1, v))
            }
            @inline(__always) func px(_ p: UnsafePointer<Float>, _ xx: Int, _ yy: Int) -> Float {
                p[mir(yy, h) * w + mir(xx, w)]
            }
            // Plus-neighborhood SAD between (cx,cy) and (cx+dx,cy+dy) on one plane.
            @inline(__always) func sadPlane(
                _ p: UnsafePointer<Float>, _ cx: Int, _ dx: Int, _ dy: Int
            ) -> Float {
                var d: Float = 0
                d += abs(px(p, cx, cy) - px(p, cx + dx, cy + dy))
                d += abs(px(p, cx - 1, cy) - px(p, cx + dx - 1, cy + dy))
                d += abs(px(p, cx + 1, cy) - px(p, cx + dx + 1, cy + dy))
                d += abs(px(p, cx, cy - 1) - px(p, cx + dx, cy + dy - 1))
                d += abs(px(p, cx, cy + 1) - px(p, cx + dx, cy + dy + 1))
                return d
            }
            // 3-channel SAD with epf_channel_scale weights.
            @inline(__always) func sad(_ cx: Int, _ dx: Int, _ dy: Int) -> Float {
                sadPlane(sx, cx, dx, dy) * kEpfChannelScaleX
                    + sadPlane(sy, cx, dx, dy) * kEpfChannelScaleY
                    + sadPlane(sb, cx, dx, dy) * kEpfChannelScaleB
            }

            let borderRow = (cy % 8 == 0) || (cy % 8 == 7)
            let sigRow = (cy / 8) * bw
            for cx in 0..<w {
                let rowSigma = sig[sigRow + (cx / 8)]
                if rowSigma < kEpfMinSigma { continue }  // too sharp: unchanged
                let onEdge = borderRow || (cx % 8 == 0) || (cx % 8 == 7)
                let sm = onEdge ? kEpfSadMulSm * kEpfBorderSadMul : kEpfSadMulSm
                let invSigma = rowSigma * sm

                var wsum: Float = 1
                var accX = sx[cy * w + cx]
                var accY = sy[cy * w + cx]
                var accB = sb[cy * w + cx]
                @inline(__always) func tap(_ dx: Int, _ dy: Int) {
                    let weight = max(0, 1 + sad(cx, dx, dy) * invSigma)
                    wsum += weight
                    accX += weight * px(sx, cx + dx, cy + dy)
                    accY += weight * px(sy, cx + dx, cy + dy)
                    accB += weight * px(sb, cx + dx, cy + dy)
                }
                tap(0, -1)
                tap(-1, 0)
                tap(1, 0)
                tap(0, 1)
                let invW = 1.0 / wsum
                dx_[cy * w + cx] = accX * invW
                dy_[cy * w + cx] = accY * invW
                db_[cy * w + cx] = accB * invW
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

// MARK: - Full reconstruction

/// Dispatches one varblock's inverse transform. Free function with no captures
/// so the per-block hot loop carries no closure context.
@inline(__always)
private func applyInverseTransform(
    _ strategy: Int, _ buf: UnsafeMutablePointer<Float>, _ out: UnsafeMutablePointer<Float>,
    stride: Int, tmp: UnsafeMutablePointer<Float>
) {
    switch strategy {
    case 1:
        identityTransform(buf, pixels: out, stride: stride)
    case 2:
        dct2x2Transform(buf, pixels: out, stride: stride)
    case 3:
        dct4x4Transform(buf, pixels: out, stride: stride, scratch: tmp)
    case 12:
        dct4x8Transform(buf, pixels: out, stride: stride, scratch: tmp)
    case 13:
        dct8x4Transform(buf, pixels: out, stride: stride, scratch: tmp)
    case 14, 15, 16, 17:
        afvTransform(kind: strategy - 14, buf, pixels: out, stride: stride, scratch: tmp)
    default:
        scaledIDCT(
            buf, h: kStrategyBlockH[strategy], w: kStrategyBlockW[strategy],
            pixels: out, stride: stride, tmp: tmp)
    }
}

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


        // Dequant tables per quant-table kind, computed once for the kinds in use.
        let acGlobal = try varDCTACGlobal()
        var dequantTables = [[Float]?](repeating: nil, count: QuantTableKind.allCases.count)
        for b in coeffs.blocks {
            let kind = kStrategyQuantTable[Int(b.strategy)]
            if dequantTables[kind.rawValue] == nil {
                // RAW-encoded tables (JPEG transcodes) override the library defaults.
                dequantTables[kind.rawValue] =
                    acGlobal.customDequant[kind.rawValue] ?? defaultDequantTable(kind)
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

        // Varblocks tile the plane exactly, so every block writes a disjoint
        // pixel region — any partition of the block list can run concurrently.
        // Every shared input crosses into the workers as a raw pointer: passing
        // shared `[Float]`s (DC planes, dequant tables) into per-block calls
        // costs an atomic retain/release pair per call, and under 10 threads
        // those refcounts become contended cachelines that dominate the stage.
        let blocks = coeffs.blocks
        let workers = max(1, min(blocks.count, ProcessInfo.processInfo.activeProcessorCount))

        // Dequant tables as manually-managed buffers (a few KB total).
        var tablePtrs = [UnsafePointer<Float>?](repeating: nil, count: dequantTables.count)
        for (kind, table) in dequantTables.enumerated() where table != nil {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: table!.count)
            p.update(from: table!, count: table!.count)
            tablePtrs[kind] = UnsafePointer(p)
        }
        defer { for p in tablePtrs { p.map { UnsafeMutablePointer(mutating: $0).deallocate() } } }

        let dcW = dc.widthBlocks
        let acMeta = meta
        let shifts = frameHeader.channelShifts
        guard shifts.h[1] == 0 && shifts.v[1] == 0 else {
            throw JXLError.unsupported("subsampled luma channel")
        }
        let hX = shifts.h[0], vX = shifts.v[0]
        let hB = shifts.h[2], vB = shifts.v[2]

        planeX.withUnsafeMutableBufferPointer { pX in
        planeY.withUnsafeMutableBufferPointer { pY in
        planeB.withUnsafeMutableBufferPointer { pB in
        dc.x.withUnsafeBufferPointer { dcXBuf in
        dc.y.withUnsafeBufferPointer { dcYBuf in
        dc.b.withUnsafeBufferPointer { dcBBuf in
        blocks.withUnsafeBufferPointer { blockBuf in
            nonisolated(unsafe) let outX = pX.baseAddress!
            nonisolated(unsafe) let outY = pY.baseAddress!
            nonisolated(unsafe) let outB = pB.baseAddress!
            nonisolated(unsafe) let dcX = dcXBuf.baseAddress!
            nonisolated(unsafe) let dcY = dcYBuf.baseAddress!
            nonisolated(unsafe) let dcB = dcBBuf.baseAddress!
            nonisolated(unsafe) let blks = blockBuf
            nonisolated(unsafe) let tabs = tablePtrs

            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                let lo = blks.count * worker / workers
                let hi = blks.count * (worker + 1) / workers
                // Per-worker scratch (max transform is 256x256 = 65536 coefficients).
                let bufX = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
                let bufY = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
                let bufB = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
                let tmp = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
                defer {
                    bufX.deallocate()
                    bufY.deallocate()
                    bufB.deallocate()
                    tmp.deallocate()
                }

                for i in lo..<hi {
                    // One struct copy per block; each block's arrays are
                    // thread-unique, so their refcounts never contend, and
                    // plain element reads below don't retain at all.
                    let blk = blks[i]
                    let bx = blk.bx
                    let by = blk.by
                    let strategy = Int(blk.strategy)
                    let size = blk.coveredX * blk.coveredY * 64
                    let quant = Float(acMeta.quantField[by * bw + bx])
                    let scaledDequant = invGlobalScale / quant
                    let ctX = bx / 8
                    let ctY = by / 8
                    let cmapW = acMeta.colorTileWidth
                    let xCC = baseX + Float(acMeta.ytoxMap[ctY * cmapW + ctX]) * colorScale
                    let bCC = baseB + Float(acMeta.ytobMap[ctY * cmapW + ctX]) * colorScale

                    // Dequantize with quant biases + chroma-from-luma (elementwise: the
                    // dequant matrix layout matches the coefficient storage).
                    // Subsampled chroma carries coefficients only at aligned
                    // block positions (empty otherwise); its plane region is
                    // the packed top-left of the full-stride plane.
                    let t = tabs[kStrategyQuantTable[strategy].rawValue]!
                    let cX = blk.coeff[0]
                    let cY = blk.coeff[1]
                    let cB = blk.coeff[2]
                    for k in 0..<size {
                        let yMul = t[size + k] * scaledDequant
                        bufY[k] = adjustQuantBias(cY[k], 1) * yMul
                    }
                    if !cX.isEmpty {
                        for k in 0..<size {
                            let xMul = t[k] * scaledDequant * xDmMul
                            bufX[k] = adjustQuantBias(cX[k], 0) * xMul + xCC * bufY[k]
                        }
                    }
                    if !cB.isEmpty {
                        for k in 0..<size {
                            let bMul = t[2 * size + k] * scaledDequant * bDmMul
                            bufB[k] = adjustQuantBias(cB[k], 2) * bMul + bCC * bufY[k]
                        }
                    }

                    // Insert the lowest frequencies from the DC image, then
                    // inverse-transform each present channel at its (possibly
                    // subsampled) plane position.
                    insertLLF(bufY, strategy: strategy, dc: dcY, dcStride: dcW, dcOrigin: by * dcW + bx)
                    applyInverseTransform(
                        strategy, bufY, outY + by * 8 * rowStride + bx * 8, stride: rowStride, tmp: tmp)
                    if !cX.isEmpty {
                        let sbx = bx >> hX
                        let sby = by >> vX
                        insertLLF(bufX, strategy: strategy, dc: dcX, dcStride: dcW, dcOrigin: sby * dcW + sbx)
                        applyInverseTransform(
                            strategy, bufX, outX + sby * 8 * rowStride + sbx * 8, stride: rowStride, tmp: tmp)
                    }
                    if !cB.isEmpty {
                        let sbx = bx >> hB
                        let sby = by >> vB
                        insertLLF(bufB, strategy: strategy, dc: dcB, dcStride: dcW, dcOrigin: sby * dcW + sbx)
                        applyInverseTransform(
                            strategy, bufB, outB + sby * 8 * rowStride + sbx * 8, stride: rowStride, tmp: tmp)
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

        // Subsampled chroma: expand the packed regions to full resolution
        // (triangle filter, libjxl chroma-upsampling stages).
        if hX != 0 || vX != 0 {
            planeX = upsampleChroma(
                planeX, stride: rowStride, paddedH: paddedH, hshift: hX, vshift: vX,
                chromaW: (bw >> hX) * 8, chromaH: (dim.ysizeBlocks >> vX) * 8)
        }
        if hB != 0 || vB != 0 {
            planeB = upsampleChroma(
                planeB, stride: rowStride, paddedH: paddedH, hshift: hB, vshift: vB,
                chromaW: (bw >> hB) * 8, chromaH: (dim.ysizeBlocks >> vB) * 8)
        }

        return XYBImage(
            width: dim.xsize, height: dim.ysize, stride: rowStride, paddedHeight: paddedH,
            x: planeX, y: planeY, b: planeB)
    }
}

/// Doubles a packed chroma region to full resolution with libjxl's
/// half-phase triangle filter (`HorizontalChromaUpsamplingStage` /
/// `VerticalChromaUpsamplingStage`): `out[2x] = (in[x-1] + 3 in[x]) / 4`,
/// `out[2x+1] = (3 in[x] + in[x+1]) / 4`, edges mirrored. The input occupies
/// the top-left `chromaW x chromaH` of a full-stride plane.
private func upsampleChroma(
    _ plane: [Float], stride: Int, paddedH: Int, hshift: Int, vshift: Int,
    chromaW: Int, chromaH: Int
) -> [Float] {
    var cur = plane
    var w = chromaW
    var h = chromaH
    for _ in 0..<hshift {
        var out = [Float](repeating: 0, count: stride * paddedH)
        cur.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let r = y * stride
                    for x in 0..<w {
                        let c = src[r + x]
                        let p = src[r + max(x - 1, 0)]
                        let n = src[r + min(x + 1, w - 1)]
                        dst[r + 2 * x] = 0.25 * p + 0.75 * c
                        dst[r + 2 * x + 1] = 0.75 * c + 0.25 * n
                    }
                }
            }
        }
        cur = out
        w *= 2
    }
    for _ in 0..<vshift {
        var out = [Float](repeating: 0, count: stride * paddedH)
        cur.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let top = max(y - 1, 0) * stride
                    let mid = y * stride
                    let bot = min(y + 1, h - 1) * stride
                    for x in 0..<w {
                        let c = src[mid + x]
                        dst[2 * y * stride + x] = 0.25 * src[top + x] + 0.75 * c
                        dst[(2 * y + 1) * stride + x] = 0.75 * c + 0.25 * src[bot + x]
                    }
                }
            }
        }
        cur = out
        h *= 2
    }
    return cur
}

/// Decodes a single-pass, 4:4:4 VarDCT frame to an 8-bit sRGB image
/// (interleaved RGB, row-major). Handles all AC strategies up to 32x32.
@_spi(Stages) public func reconstructVarDCTImage(from data: [UInt8]) throws -> (width: Int, height: Int, rgb: [UInt8]) {
    let decoder = try FrameDecoder(data: data)
    let xyb = try decoder.reconstructXYB()
    if decoder.frameHeader.colorTransform == .ycbcr {
        return (xyb.width, xyb.height, ycbcrToRGB8Interleaved(xyb))
    }
    let spec = try makeOutputColorSpec(decoder.metadata.colorEncoding)
    return (xyb.width, xyb.height, xybToRGB8Interleaved(xyb, spec: spec))
}

@_spi(Stages) public func reconstructVarDCTImage(from data: Data) throws -> (width: Int, height: Int, rgb: [UInt8]) {
    try reconstructVarDCTImage(from: [UInt8](data))
}
