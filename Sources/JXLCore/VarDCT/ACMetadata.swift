// ACMetadata.swift
//
// VarDCT per-DC-group "AC metadata" decode (libjxl v0.11.2
// `ModularFrameDecoder::DecodeAcMetadata`). This is the second half of a DC
// group section (after `VarDCTDC`): it carries everything the AC coefficient
// decode and reconstruction need *except* the coefficients themselves —
//
//   * the AC strategy field: which variable-size DCT (2x2 … 256x256) tiles each
//     8x8 block position, stored once per varblock at its top-left,
//   * the raw quant field: a per-block quantization multiplier index,
//   * the EPF sharpness field: per-block edge-preserving-filter strength,
//   * the per-color-tile chroma-from-luma maps (YtoX, YtoB) for AC.
//
// These four are stored as one 4-channel Modular image decoded with the frame's
// global tree. Decoding it correctly — strategies that tile the grid exactly
// with `num == count` varblocks — is a strong bit-exactness check on the
// preceding `VarDCTDC` stream too, since both share one bounded TOC section and
// one ANS final-state check.
//
// Restrictions match the DC decode: 4:4:4, single pass, no extra channels.

import Foundation

let kVarDCTNumStrategies = 27  // AcStrategy::kNumValidStrategies
private let kEpfSharpEntries = 8
private let kQuantMax = 256  // Quantizer::kQuantMax
private let kColorTileDimInBlocks = 8

// AcStrategy::covered_blocks_x / covered_blocks_y LUTs (ac_strategy.h).
let kCoveredBlocksX: [Int] = [
    1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4, 1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32,
]
let kCoveredBlocksY: [Int] = [
    1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2, 1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16,
]

/// Per-DC-group AC metadata, indexed in the full block grid.
public struct VarDCTACMetadata: Equatable {
    public let widthBlocks: Int
    public let heightBlocks: Int
    /// Raw AC strategy (`AcStrategyType`) at each block. Covered (non-top-left)
    /// blocks of a multi-block varblock repeat the strategy of their top-left.
    public var strategy: [UInt8]
    /// `true` at the top-left block of each varblock.
    public var isFirstBlock: [Bool]
    /// Raw quant field per block: `1 + clamp(coded, 0, kQuantMax-1)`.
    public var quantField: [Int32]
    /// EPF sharpness per block (0…7).
    public var epfSharpness: [UInt8]
    /// Chroma-from-luma maps at color-tile (64px = 8 block) resolution.
    public var ytoxMap: [Int8]
    public var ytobMap: [Int8]
    public var colorTileWidth: Int
    public var colorTileHeight: Int
    /// Total number of varblocks across the frame.
    public var varblockCount: Int
    /// Bitmask of AC strategies used (`1 << AcStrategyType`), libjxl `used_acs`.
    public var usedACs: UInt32
}

/// Decodes the AC metadata for every DC group of a VarDCT frame, alongside the
/// `VarDCTDC` stream that precedes it in each DC group section. Returns the
/// assembled full-frame metadata.
public func decodeVarDCTACMetadata(from data: [UInt8]) throws -> VarDCTACMetadata {
    try decodeLowFrequency(setupVarDCT(data))
}

/// Decodes the low-frequency layer (every DC group's `VarDCTDC` + `AcMetadata`)
/// for an already-parsed frame, leaving `s.r0` positioned at HfGlobal for a
/// coalesced single-section frame.
func decodeLowFrequency(_ s: VarDCTSetup) throws -> VarDCTACMetadata {
    let dim = s.dim
    let bw = dim.xsizeBlocks
    let bh = dim.ysizeBlocks
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
        colorTileWidth: ctw, colorTileHeight: cth, varblockCount: 0, usedACs: 0)
    // `valid[i]` mirrors libjxl AcStrategyImage validity: a block is valid once
    // covered by a placed varblock.
    var valid = [Bool](repeating: false, count: bw * bh)
    var totalVarblocks = 0
    var usedACs: UInt32 = 0

    for dcg in 0..<dim.numDCGroups {
        let rect = s.dcGroupRect(dcg)
        let reader = s.dcGroupReader(dcg)
        // ProcessDCGroup: VarDCTDC, then (ModularDC reads nothing without extra
        // channels), then DecodeAcMetadata. Decode and discard the DC here; the
        // public DC-image path produces the dequantized planes.
        try skipVarDCTDC(reader, groupIndex: dcg, rectW: rect.w, rectH: rect.h, dcGlobal: s.dcGlobal)
        try decodeAcMetadataGroup(
            reader, groupIndex: dcg, rect: rect, dim: dim,
            dcGlobal: s.dcGlobal, meta: &meta, valid: &valid, totalVarblocks: &totalVarblocks,
            usedACs: &usedACs)
    }
    meta.varblockCount = totalVarblocks
    meta.usedACs = usedACs
    return meta
}

public func decodeVarDCTACMetadata(from data: Data) throws -> VarDCTACMetadata {
    try decodeVarDCTACMetadata(from: [UInt8](data))
}

/// Decodes the low-frequency layer plus the AC-global (HfGlobal) layer:
/// coefficient orders and AC histograms. Validates the coefficient-order ANS
/// stream's final state.
public func decodeVarDCTACGlobalForFrame(from data: [UInt8]) throws
    -> (metadata: VarDCTACMetadata, acGlobal: VarDCTACGlobal)
{
    let s = try setupVarDCT(data)
    let meta = try decodeLowFrequency(s)
    // HfGlobal: continues in section 0 for a coalesced frame, else its own
    // section at index numDCGroups + 1.
    let acReader = s.coalesced ? s.r0 : s.sectionReader(s.dim.numDCGroups + 1)
    let acg = try decodeVarDCTACGlobal(
        acReader, dim: s.dim, numPasses: Int(s.frameHeader.numPasses),
        blockContextMap: s.dcGlobal.info.blockContextMap, usedACs: meta.usedACs)
    return (meta, acg)
}

public func decodeVarDCTACGlobalForFrame(from data: Data) throws
    -> (metadata: VarDCTACMetadata, acGlobal: VarDCTACGlobal)
{
    try decodeVarDCTACGlobalForFrame(from: [UInt8](data))
}

/// Decodes the `VarDCTDC` stream to advance the reader past it (the DC values
/// themselves are produced by the DC-image path). Mirrors `DecodeVarDCTDC`
/// up to and including the modular decode.
private func skipVarDCTDC(
    _ br: BitReader, groupIndex: Int, rectW: Int, rectH: Int, dcGlobal: VarDCTDCGlobalDecoded
) throws {
    _ = br.read(2)  // extra_precision
    let image = ModularImage(w: rectW, h: rectH, bitdepth: 8, channelCount: 3)
    _ = try modularDecode(
        br, image: image, groupID: 1 + groupIndex,
        globalTree: dcGlobal.tree, globalCode: dcGlobal.code, globalCtxMap: dcGlobal.ctxMap)
}

/// Decodes one DC group's `AcMetadata` stream and writes into `meta`/`valid`.
private func decodeAcMetadataGroup(
    _ br: BitReader, groupIndex: Int, rect: (x0: Int, y0: Int, w: Int, h: Int),
    dim: FrameDimensions, dcGlobal: VarDCTDCGlobalDecoded,
    meta: inout VarDCTACMetadata, valid: inout [Bool], totalVarblocks: inout Int,
    usedACs: inout UInt32
) throws {
    let upperBound = rect.w * rect.h
    let count = Int(br.read(ceilLog2Nonzero(UInt32(upperBound)))) + 1

    // 4-channel image: [0]=YtoX map, [1]=YtoB map (both color-tile res),
    // [2]=(count x 2) ACS+QF, [3]=(w x h) EPF sharpness.
    let crW = divCeil(rect.w, kColorTileDimInBlocks)
    let crH = divCeil(rect.h, kColorTileDimInBlocks)
    let image = ModularImage(w: rect.w, h: rect.h, bitdepth: 8, channelCount: 4)
    image.channels[0] = ModularChannel(w: crW, h: crH, hshift: 3, vshift: 3)
    image.channels[1] = ModularChannel(w: crW, h: crH, hshift: 3, vshift: 3)
    image.channels[2] = ModularChannel(w: count, h: 2)
    image.channels[3] = ModularChannel(w: rect.w, h: rect.h)

    // group_id property = ModularStreamId::ACMetadata(group).ID.
    let streamID = 1 + 2 * dim.numDCGroups + groupIndex
    _ = try modularDecode(
        br, image: image, groupID: streamID,
        globalTree: dcGlobal.tree, globalCode: dcGlobal.code, globalCtxMap: dcGlobal.ctxMap)

    // ConvertPlaneAndClamp into the full-frame color-tile maps (clamp to int8).
    let ctX0 = rect.x0 >> 3
    let ctY0 = rect.y0 >> 3
    for y in 0..<crH {
        for x in 0..<crW {
            let v0 = image.channels[0].pixels[y * crW + x]
            let v1 = image.channels[1].pixels[y * crW + x]
            let dst = (ctY0 + y) * meta.colorTileWidth + (ctX0 + x)
            meta.ytoxMap[dst] = Int8(clamping: v0)
            meta.ytobMap[dst] = Int8(clamping: v1)
        }
    }

    // Block-by-block: assign strategies/quant, advancing `num` only at the
    // top-left of each new varblock (libjxl DecodeAcMetadata main loop).
    let acsRow = image.channels[2].pixels  // row 0 = strategy, row 1 = quant
    let qfRow0 = count  // index offset for row 1
    let epf = image.channels[3].pixels
    let bw = meta.widthBlocks
    var num = 0
    let xlim = min(bw, rect.x0 + rect.w)
    let ylim = min(meta.heightBlocks, rect.y0 + rect.h)

    for iy in 0..<rect.h {
        let y = rect.y0 + iy
        for ix in 0..<rect.w {
            let x = rect.x0 + ix
            let sharpness = epf[iy * rect.w + ix]
            guard sharpness >= 0, Int(sharpness) < kEpfSharpEntries else {
                throw JXLError.malformed("corrupted EPF sharpness field")
            }
            meta.epfSharpness[y * bw + x] = UInt8(truncatingIfNeeded: sharpness)
            if valid[y * bw + x] { continue }
            guard num < count else { throw JXLError.malformed("AC metadata: too few varblocks") }
            let raw = acsRow[num]
            guard raw >= 0, Int(raw) < kVarDCTNumStrategies else {
                throw JXLError.malformed("invalid AC strategy \(raw)")
            }
            usedACs |= UInt32(1) << UInt32(raw)
            let cbx = kCoveredBlocksX[Int(raw)]
            let cby = kCoveredBlocksY[Int(raw)]
            // Block must not overflow its AC group or the image.
            let nextXAC = (x / dim.groupDim + 1) * dim.groupDim
            let nextYAC = (y / dim.groupDim + 1) * dim.groupDim
            guard x + cbx <= nextXAC, x + cbx <= xlim else {
                throw JXLError.malformed("AC strategy x overflow")
            }
            guard y + cby <= nextYAC, y + cby <= ylim else {
                throw JXLError.malformed("AC strategy y overflow")
            }
            // Place the varblock: mark covered blocks valid, repeat strategy.
            for dy in 0..<cby {
                for dx in 0..<cbx {
                    let pos = (y + dy) * bw + (x + dx)
                    if valid[pos] { throw JXLError.malformed("AC strategy block overlap") }
                    valid[pos] = true
                    meta.strategy[pos] = UInt8(truncatingIfNeeded: raw)
                    meta.isFirstBlock[pos] = (dx | dy) == 0
                }
            }
            let qf = Int(acsRow[qfRow0 + num])
            meta.quantField[y * bw + x] = Int32(1 + max(0, min(kQuantMax - 1, qf)))
            num += 1
        }
    }
    guard num == count else { throw JXLError.malformed("AC metadata: \(num) != count \(count)") }
    totalVarblocks += count
}
