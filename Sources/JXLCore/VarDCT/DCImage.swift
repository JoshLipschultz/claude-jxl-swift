// DCImage.swift
//
// VarDCT DC-image decode (ISO/IEC 18181-1 §I — the low-frequency / DC pass).
//
// For a VarDCT frame the three color planes are XYB. Their DC coefficients (one
// per 8x8 block) are stored as a small Modular image — one sample per block —
// using the frame's global MA tree. This file reproduces libjxl v0.11.2's
// `ModularFrameDecoder::DecodeVarDCTDC` (+ `DequantDC`) and
// `AdaptiveDCSmoothing`, producing the dequantized XYB DC planes at block
// resolution. This is the first stage of the lossy pipeline; AC coefficients,
// the inverse DCT, and XYB->RGB color land on top of it.
//
// Restrictions (matching the current fixture corpus): 4:4:4 (no chroma
// subsampling), a single pass, and library/default quant tables. Multiple DC
// groups are supported; per-DC-group `ModularDC`/`AcMetadata` payloads are not
// consumed here because the DC image only needs the `VarDCTDC` stream.

import Foundation

/// Dequantized XYB DC planes at block resolution (one sample per 8x8 block).
/// `x` and `b` are the chroma planes, `y` the luma plane.
@_spi(Stages) public struct VarDCTDCImage: Equatable, Sendable {
    public let widthBlocks: Int
    public let heightBlocks: Int
    public var x: [Float]
    public var y: [Float]
    public var b: [Float]
}

/// DC dequantization multipliers derived from the quantizer + color-correlation
/// metadata (libjxl `Quantizer::MulDC` and `ColorCorrelation::DCFactors`).
struct DCDequant {
    /// Per-channel DC step (X, Y, B), already including `Quantizer::MulDC`.
    let mulDC: [Float]
    /// Chroma-from-luma DC factors: `[YtoX, _, YtoB]`.
    let cfl: [Float]
}

func computeDCDequant(_ g: VarDCTDCGlobalInfo) -> DCDequant {
    let globalScale = Float(g.quantizer.globalScale)
    let quantDC = Float(g.quantizer.quantDC)
    // inv_global_scale_ = kGlobalScaleDenom / global_scale_; (kGlobalScaleDenom = 1<<16)
    let invGlobalScale = Float(1 << 16) / globalScale
    let invQuantDC = invGlobalScale / quantDC

    // DequantMatrices::DCQuant(c): default {1/4096, 1/512, 1/256}, else the
    // F16-coded values already scaled by 1/128 in `readVarDCTDCGlobal`.
    let dcQuant: [Float] =
        g.dcQuantIsDefault ? [1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0] : g.dcQuant
    let mulDC = (0..<3).map { invQuantDC * dcQuant[$0] }

    // ColorCorrelation DC factors. Defaults: factor 84, baseX 0, baseB 1 (kYToBRatio).
    let cc = g.colorCorrelation
    let colorFactor = Float(cc?.colorFactor ?? 84)
    let colorScale = 1.0 / colorFactor
    let baseX = cc?.baseCorrelationX ?? 0.0
    let baseB = cc?.baseCorrelationB ?? 1.0
    let yToXDC = Float(cc?.yToXDC ?? 0)
    let yToBDC = Float(cc?.yToBDC ?? 0)
    let cfl = [baseX + yToXDC * colorScale, 0, baseB + yToBDC * colorScale]

    return DCDequant(mulDC: mulDC, cfl: cfl)
}

/// The decoded low-frequency layer of a VarDCT frame: the dequantized XYB DC
/// planes and the AC metadata (strategies, quant field, EPF sharpness, CfL
/// maps). Both live in the same per-DC-group TOC sections (`VarDCTDC` then
/// `AcMetadata` behind one ANS final-state check), so they are decoded together
/// in a single pass per group.
struct VarDCTLowFrequency {
    let dc: VarDCTDCImage
    let metadata: VarDCTACMetadata
}

/// Decodes every DC group's `VarDCTDC` + `AcMetadata` (libjxl `ProcessDCGroup`)
/// in one pass, then applies adaptive DC smoothing. For a coalesced frame this
/// leaves `d.r0` positioned at HfGlobal.
func decodeVarDCTLowFrequency(_ d: FrameDecoder) throws -> VarDCTLowFrequency {
    let dcGlobal = try d.varDCTDCGlobal()
    let dequant = try d.varDCTDCDequant()
    let dim = d.dim
    let bw = dim.xsizeBlocks
    let bh = dim.ysizeBlocks
    var planeX = [Float](repeating: 0, count: bw * bh)
    var planeY = [Float](repeating: 0, count: bw * bh)
    var planeB = [Float](repeating: 0, count: bw * bh)

    let ctw = divCeil(bw, kColorTileDimInBlocks)
    let cth = divCeil(bh, kColorTileDimInBlocks)
    var meta = VarDCTACMetadata(
        widthBlocks: bw, heightBlocks: bh,
        strategy: [UInt8](repeating: 0, count: bw * bh),
        isFirstBlock: [Bool](repeating: false, count: bw * bh),
        quantField: [Int32](repeating: 0, count: bw * bh),
        epfSharpness: [UInt8](repeating: 0, count: bw * bh),
        ytoxMap: [Int8](repeating: 0, count: ctw * cth),
        ytobMap: [Int8](repeating: 0, count: ctw * cth),
        colorTileWidth: ctw, colorTileHeight: cth, varblockCount: 0, usedACs: 0,
        dcQuantContext: [UInt8](repeating: 0, count: bw * bh))
    // `valid[i]` mirrors libjxl AcStrategyImage validity: a block is valid once
    // covered by a placed varblock.
    var valid = [Bool](repeating: false, count: bw * bh)
    var totalVarblocks = 0
    var usedACs: UInt32 = 0

    let shifts = d.frameHeader.channelShifts
    for dcg in 0..<dim.numDCGroups {
        let rect = d.dcGroupRect(dcg)
        let reader = d.dcGroupReader(dcg)
        try decodeVarDCTDC(
            reader, groupIndex: dcg, rectW: rect.w, rectH: rect.h,
            dcGlobal: dcGlobal, dequant: dequant, shifts: shifts,
            destX: &planeX, destY: &planeY, destB: &planeB,
            destW: bw, x0: rect.x0, y0: rect.y0, dcQuantContext: &meta.dcQuantContext)
        // (ModularDC reads nothing without extra channels.)
        try decodeAcMetadataGroup(
            reader, groupIndex: dcg, rect: rect, dim: dim,
            dcGlobal: dcGlobal, meta: &meta, valid: &valid,
            totalVarblocks: &totalVarblocks, usedACs: &usedACs)
    }
    meta.varblockCount = totalVarblocks
    meta.usedACs = usedACs

    // libjxl runs adaptive smoothing only for 4:4:4 frames without the
    // kSkipAdaptiveDCSmoothing flag (JPEG transcodes set it).
    if d.frameHeader.flags & 128 == 0 && d.frameHeader.chromaIs444 {
        adaptiveDCSmoothing(
            dcFactors: dequant.mulDC, w: bw, h: bh, x: &planeX, y: &planeY, b: &planeB)
    }

    let dc = VarDCTDCImage(widthBlocks: bw, heightBlocks: bh, x: planeX, y: planeY, b: planeB)
    return VarDCTLowFrequency(dc: dc, metadata: meta)
}

/// Decodes the dequantized XYB DC image of a single-pass, 4:4:4 VarDCT frame.
@_spi(Stages) public func decodeVarDCTDCImage(from data: [UInt8]) throws -> VarDCTDCImage {
    try FrameDecoder(data: data).varDCTLowFrequency().dc
}

@_spi(Stages) public func decodeVarDCTDCImage(from data: Data) throws -> VarDCTDCImage {
    try decodeVarDCTDCImage(from: [UInt8](data))
}

@_spi(Stages) public func decodeVarDCTDCImage(contentsOf url: URL) throws -> VarDCTDCImage {
    try decodeVarDCTDCImage(from: try Data(contentsOf: url))
}

/// Decodes and dequantizes one DC group's `VarDCTDC` stream into the planes.
/// Mirrors `ModularFrameDecoder::DecodeVarDCTDC` + `DequantDC`. Subsampled
/// channels occupy the top-left `(w >> h, h >> v)` region of their full-stride
/// plane, exactly like libjxl's shifted rects into the shared DC image.
private func decodeVarDCTDC(
    _ br: BitReader, groupIndex: Int, rectW: Int, rectH: Int,
    dcGlobal: VarDCTDCGlobalDecoded, dequant: DCDequant, shifts: (h: [Int], v: [Int]),
    destX: inout [Float], destY: inout [Float], destB: inout [Float],
    destW: Int, x0: Int, y0: Int, dcQuantContext: inout [UInt8]
) throws {
    // extra_precision: 2 bits; mul = 1 / (1 << extra_precision).
    let extraPrecision = Int(br.read(2))
    let mul = 1.0 / Float(1 << extraPrecision)

    // 3 channels at block resolution, modular order [Y, X, B]: libjxl assigns
    // plane channel c to modular channel `c < 2 ? c^1 : c` and shrinks it by
    // that plane channel's subsampling shift (floor).
    let image = ModularImage(
        w: rectW, h: rectH, bitdepth: 8, channelCount: 3)
    for c in 0..<3 {
        let mc = c < 2 ? c ^ 1 : c
        image.channels[mc] = ModularChannel(
            w: rectW >> shifts.h[c], h: rectH >> shifts.v[c])
    }
    // group_id property (props[1]) = ModularStreamId::VarDCTDC(group).ID = 1 + group.
    let streamID = 1 + groupIndex
    _ = try modularDecode(
        br, image: image, groupID: streamID,
        globalTree: dcGlobal.tree, globalCode: dcGlobal.code, globalCtxMap: dcGlobal.ctxMap)

    let is444 = shifts.h == [0, 0, 0] && shifts.v == [0, 0, 0]
    if is444 {
        // DequantDC (4:4:4): in.channel[0]=Y, [1]=X, [2]=B, with DC CfL.
        let facX = dequant.mulDC[0] * mul
        let facY = dequant.mulDC[1] * mul
        let facB = dequant.mulDC[2] * mul
        let cflX = dequant.cfl[0]
        let cflB = dequant.cfl[2]
        let qY = image.channels[0].pixels
        let qX = image.channels[1].pixels
        let qB = image.channels[2].pixels

        for yy in 0..<rectH {
            let srcRow = yy * rectW
            let dstRow = (y0 + yy) * destW + x0
            for xx in 0..<rectW {
                let inY = Float(qY[srcRow + xx]) * facY
                let inX = Float(qX[srcRow + xx]) * facX
                let inB = Float(qB[srcRow + xx]) * facB
                destY[dstRow + xx] = inY
                destX[dstRow + xx] = inY * cflX + inX
                destB[dstRow + xx] = inY * cflB + inB
            }
        }
    } else {
        // Subsampled (libjxl DequantDC non-444 path): per-channel factor, no
        // DC CfL, shifted rects.
        func dequantChannel(_ c: Int, _ dest: inout [Float]) {
            let mc = c < 2 ? c ^ 1 : c
            let q = image.channels[mc].pixels
            let w = rectW >> shifts.h[c]
            let h = rectH >> shifts.v[c]
            let dx0 = x0 >> shifts.h[c]
            let dy0 = y0 >> shifts.v[c]
            let fac = dequant.mulDC[c] * mul
            for yy in 0..<h {
                let srcRow = yy * w
                let dstRow = (dy0 + yy) * destW + dx0
                for xx in 0..<w {
                    dest[dstRow + xx] = Float(q[srcRow + xx]) * fac
                }
            }
        }
        dequantChannel(1, &destY)
        dequantChannel(0, &destX)
        dequantChannel(2, &destB)
    }

    // quant_dc (libjxl DequantDC tail): per-block DC context byte from the
    // quantized values, bucketed by the block context map's DC thresholds.
    // Channel mapping mirrors libjxl: plane c reads modular channel
    // `c < 2 ? c^1 : c` at that plane's subsampling shift.
    let bctx = dcGlobal.info.blockContextMap
    if bctx.numDCContexts > 1 {
        let tX = bctx.dcThresholds[0]
        let tY = bctx.dcThresholds[1]
        let tB = bctx.dcThresholds[2]
        let qX = image.channels[1].pixels
        let qY = image.channels[0].pixels
        let qB = image.channels[2].pixels
        let wX = rectW >> shifts.h[0]
        let wY = rectW >> shifts.h[1]
        let wB = rectW >> shifts.h[2]
        for y in 0..<rectH {
            let rowX = (y >> shifts.v[0]) * wX
            let rowY = (y >> shifts.v[1]) * wY
            let rowB = (y >> shifts.v[2]) * wB
            let dstRow = (y0 + y) * destW + x0
            for x in 0..<rectW {
                var bucketX = 0
                var bucketY = 0
                var bucketB = 0
                let vX = qX[rowX + (x >> shifts.h[0])]
                let vY = qY[rowY + (x >> shifts.h[1])]
                let vB = qB[rowB + (x >> shifts.h[2])]
                for t in tX where vX > t { bucketX += 1 }
                for t in tY where vY > t { bucketY += 1 }
                for t in tB where vB > t { bucketB += 1 }
                var bucket = bucketX
                bucket = bucket * (tB.count + 1) + bucketB
                bucket = bucket * (tY.count + 1) + bucketY
                dcQuantContext[dstRow + x] = UInt8(truncatingIfNeeded: bucket)
            }
        }
    }
}

// Adaptive DC smoothing weights (libjxl compressed_dc.cc).
private let kSmoothW1: Float = 0.20345139757231578
private let kSmoothW2: Float = 0.0334829185968739
private let kSmoothW0: Float = 1.0 - 4.0 * (kSmoothW1 + kSmoothW2)

/// In-place adaptive DC smoothing (libjxl `AdaptiveDCSmoothing`). A 3x3 blur is
/// blended back toward the original by a factor that vanishes where the local
/// gap (in quant steps) is large, preserving edges. Borders are left unchanged.
private func adaptiveDCSmoothing(
    dcFactors: [Float], w: Int, h: Int,
    x: inout [Float], y: inout [Float], b: inout [Float]
) {
    if h <= 2 || w <= 2 { return }
    // Read from copies; only interior pixels are written back. The blend factor
    // couples all three channels (the gap is the max over channels), so the
    // three planes are processed together per pixel.
    let inX = x
    let inY = y
    let inB = b

    let facX = dcFactors[0]
    let facY = dcFactors[1]
    let facB = dcFactors[2]
    // 3x3 smooth of one plane at `c`; returns (center, smoothed).
    @inline(__always) func smooth(_ p: [Float], _ c: Int, _ top: Int, _ bot: Int) -> (Float, Float) {
        let corner = (p[top - 1] + p[top + 1]) + (p[bot - 1] + p[bot + 1])
        let side = (p[c - 1] + p[c + 1]) + (p[top] + p[bot])
        return (p[c], corner * kSmoothW2 + side * kSmoothW1 + p[c] * kSmoothW0)
    }
    for yy in 1..<(h - 1) {
        for xx in 1..<(w - 1) {
            let c = yy * w + xx
            let top = c - w
            let bot = c + w

            let (mcX, smX) = smooth(inX, c, top, bot)
            let (mcY, smY) = smooth(inY, c, top, bot)
            let (mcB, smB) = smooth(inB, c, top, bot)
            var gap: Float = 0.5
            gap = max(gap, abs((mcX - smX) / facX))
            gap = max(gap, abs((mcY - smY) / facY))
            gap = max(gap, abs((mcB - smB) / facB))
            var factor = 3.0 - 4.0 * gap
            if factor < 0 { factor = 0 }
            x[c] = (smX - mcX) * factor + mcX
            y[c] = (smY - mcY) * factor + mcY
            b[c] = (smB - mcB) * factor + mcB
        }
    }
}
