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
public struct VarDCTDCImage: Equatable {
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

private func computeDCDequant(_ g: VarDCTDCGlobalInfo) -> DCDequant {
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

/// Shared parse state for a VarDCT frame: everything through `ProcessDCGlobal`,
/// plus the per-section readers. Used by both the DC-image and AC-metadata
/// decoders so the header/TOC/DC-global prefix is parsed once.
struct VarDCTSetup {
    let metadata: JXLImageMetadata
    let frameHeader: FrameHeader
    let dim: FrameDimensions
    let dcGlobal: VarDCTDCGlobalDecoded
    let dequant: DCDequant
    let coalesced: Bool
    /// Section 0 reader, positioned immediately after `ProcessDCGlobal`.
    let r0: BitReader
    let cs: [UInt8]
    let dataStart: Int
    let offsets: [Int]
    let sizes: [Int]

    func sectionReader(_ logicalIndex: Int) -> BitReader {
        let start = dataStart + offsets[logicalIndex]
        return BitReader(Array(cs[start..<(start + sizes[logicalIndex])]))
    }

    /// The reader to use for DC group `dcg`: the shared section-0 reader for a
    /// coalesced single-section frame, else the DC group's own section.
    func dcGroupReader(_ dcg: Int) -> BitReader {
        coalesced ? r0 : sectionReader(1 + dcg)
    }

    /// DC group `dcg`'s rect in block units.
    func dcGroupRect(_ dcg: Int) -> (x0: Int, y0: Int, w: Int, h: Int) {
        let gx = dcg % dim.xsizeDCGroups
        let gy = dcg / dim.xsizeDCGroups
        let x0 = gx * dim.groupDim
        let y0 = gy * dim.groupDim
        return (x0, y0, min(dim.groupDim, dim.xsizeBlocks - x0),
            min(dim.groupDim, dim.ysizeBlocks - y0))
    }
}

/// Parses a VarDCT frame through `ProcessDCGlobal`. Restricted to the currently
/// supported subset: single-pass, 4:4:4, no patches/splines/noise.
func setupVarDCT(_ data: [UInt8]) throws -> VarDCTSetup {
    let parsed = try JXLContainer.parse(data)
    guard parsed.codestream.count >= 2,
        parsed.codestream[0] == 0xFF, parsed.codestream[1] == 0x0A
    else { throw JXLError.invalidSignature }

    let reader = BitReader(parsed.codestream)
    reader.skip(16)
    let size = SizeHeader(reader)
    let metadata = JXLImageMetadata(reader)
    CustomTransformData.skip(reader, xybEncoded: metadata.xybEncoded)
    if metadata.colorEncoding.wantICC { throw JXLError.unsupported("embedded ICC profile") }
    reader.alignToByte()

    let ctx = FrameContext(metadata: metadata, width: size.width, height: size.height)
    let frameHeader = FrameHeader(reader: reader, context: ctx)
    guard !frameHeader.isModular else { throw JXLError.unsupported("Modular frame is not VarDCT") }
    guard frameHeader.frameType == .regular else {
        throw JXLError.unsupported("non-regular VarDCT frame")
    }
    guard frameHeader.numPasses == 1 else {
        throw JXLError.unsupported("progressive (multi-pass) VarDCT frames")
    }
    guard frameHeader.chromaChannelMode == [0, 0, 0] else {
        throw JXLError.unsupported("chroma-subsampled VarDCT frames")
    }
    // No patches/splines/noise: those precede DequantMatrices.DecodeDC and are
    // not yet parsed.
    guard frameHeader.flags == 0 else {
        throw JXLError.unsupported("VarDCT frame features (patches/splines/noise)")
    }

    let dim = frameHeader.frameDimensions(ctx)
    let entries = numTocEntries(
        numGroups: dim.numGroups, numDCGroups: dim.numDCGroups,
        numPasses: Int(frameHeader.numPasses))
    guard let toc = readGroupOffsets(reader, tocEntries: entries) else {
        throw JXLError.malformed("could not read TOC")
    }
    let dataStart = reader.bitPosition / 8
    let cs = parsed.codestream

    let coalesced = dim.numGroups == 1 && frameHeader.numPasses == 1

    // ProcessDCGlobal (section 0), keeping the global tree/code/context map.
    let start0 = dataStart + toc.offsets[0]
    let r0 = BitReader(Array(cs[start0..<(start0 + Int(toc.sizes[0]))]))
    let dcGlobal = try readVarDCTDCGlobal(r0)
    let dequant = computeDCDequant(dcGlobal.info)

    return VarDCTSetup(
        metadata: metadata, frameHeader: frameHeader, dim: dim, dcGlobal: dcGlobal,
        dequant: dequant, coalesced: coalesced, r0: r0, cs: cs, dataStart: dataStart,
        offsets: toc.offsets, sizes: toc.sizes.map(Int.init))
}

/// Decodes the dequantized XYB DC image of a single-pass, 4:4:4 VarDCT frame.
public func decodeVarDCTDCImage(from data: [UInt8]) throws -> VarDCTDCImage {
    let s = try setupVarDCT(data)
    let dim = s.dim
    let bw = dim.xsizeBlocks
    let bh = dim.ysizeBlocks
    var planeX = [Float](repeating: 0, count: bw * bh)
    var planeY = [Float](repeating: 0, count: bw * bh)
    var planeB = [Float](repeating: 0, count: bw * bh)

    // ProcessDCGroup: decode each DC group's VarDCTDC stream into the planes.
    for dcg in 0..<dim.numDCGroups {
        let rect = s.dcGroupRect(dcg)
        try decodeVarDCTDC(
            s.dcGroupReader(dcg), groupIndex: dcg, rectW: rect.w, rectH: rect.h,
            dcGlobal: s.dcGlobal, dequant: s.dequant,
            destX: &planeX, destY: &planeY, destB: &planeB,
            destW: bw, x0: rect.x0, y0: rect.y0)
    }

    adaptiveDCSmoothing(
        dcFactors: s.dequant.mulDC, w: bw, h: bh, x: &planeX, y: &planeY, b: &planeB)

    return VarDCTDCImage(widthBlocks: bw, heightBlocks: bh, x: planeX, y: planeY, b: planeB)
}

public func decodeVarDCTDCImage(from data: Data) throws -> VarDCTDCImage {
    try decodeVarDCTDCImage(from: [UInt8](data))
}

public func decodeVarDCTDCImage(contentsOf url: URL) throws -> VarDCTDCImage {
    try decodeVarDCTDCImage(from: try Data(contentsOf: url))
}

/// Decodes and dequantizes one DC group's `VarDCTDC` stream into the planes.
/// Mirrors `ModularFrameDecoder::DecodeVarDCTDC` + `DequantDC` (4:4:4 path).
private func decodeVarDCTDC(
    _ br: BitReader, groupIndex: Int, rectW: Int, rectH: Int,
    dcGlobal: VarDCTDCGlobalDecoded, dequant: DCDequant,
    destX: inout [Float], destY: inout [Float], destB: inout [Float],
    destW: Int, x0: Int, y0: Int
) throws {
    // extra_precision: 2 bits; mul = 1 / (1 << extra_precision).
    let extraPrecision = Int(br.read(2))
    let mul = 1.0 / Float(1 << extraPrecision)

    // 3 channels at block resolution. libjxl reorders channels via
    // `c < 2 ? c^1 : c`; for 4:4:4 that only affects which channel index gets a
    // subsampling shift, so with no subsampling we decode channels 0,1,2 in
    // order. After decode: channel[0]=Y(luma), channel[1]=X, channel[2]=B.
    let image = ModularImage(
        w: rectW, h: rectH, bitdepth: 8, channelCount: 3)
    // group_id property (props[1]) = ModularStreamId::VarDCTDC(group).ID = 1 + group.
    let streamID = 1 + groupIndex
    _ = try modularDecode(
        br, image: image, groupID: streamID,
        globalTree: dcGlobal.tree, globalCode: dcGlobal.code, globalCtxMap: dcGlobal.ctxMap)

    // DequantDC (4:4:4): in.channel[0]=Y, [1]=X, [2]=B.
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

    for yy in 1..<(h - 1) {
        for xx in 1..<(w - 1) {
            let c = yy * w + xx
            let top = c - w
            let bot = c + w

            var gap: Float = 0.5
            var mc = [Float](repeating: 0, count: 3)
            var sm = [Float](repeating: 0, count: 3)
            let chans = [inX, inY, inB]
            for ch in 0..<3 {
                let p = chans[ch]
                let tl = p[top - 1], tc = p[top], tr = p[top + 1]
                let ml = p[c - 1], center = p[c], mr = p[c + 1]
                let bl = p[bot - 1], bc = p[bot], brr = p[bot + 1]
                let corner = (tl + tr) + (bl + brr)
                let side = (ml + mr) + (tc + bc)
                let smoothed = corner * kSmoothW2 + side * kSmoothW1 + center * kSmoothW0
                mc[ch] = center
                sm[ch] = smoothed
                gap = max(gap, abs((center - smoothed) / dcFactors[ch]))
            }
            var factor = 3.0 - 4.0 * gap
            if factor < 0 { factor = 0 }
            x[c] = (sm[0] - mc[0]) * factor + mc[0]
            y[c] = (sm[1] - mc[1]) * factor + mc[1]
            b[c] = (sm[2] - mc[2]) * factor + mc[2]
        }
    }
}
