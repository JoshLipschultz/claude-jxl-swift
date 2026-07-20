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
let kColorTileDimInBlocks = 8

// AcStrategy::covered_blocks_x / covered_blocks_y LUTs (ac_strategy.h).
let kCoveredBlocksX: [Int] = [
    1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4, 1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32,
]
let kCoveredBlocksY: [Int] = [
    1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2, 1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16,
]

/// Per-DC-group AC metadata, indexed in the full block grid.
@_spi(Stages) public struct VarDCTACMetadata: Equatable, Sendable {
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
    /// Per-block DC context byte (libjxl `quant_dc`): bucketed quantized DC
    /// values when the block context map has DC thresholds; all zero otherwise.
    public var dcQuantContext: [UInt8]
}

/// Decodes the AC metadata for every DC group of a VarDCT frame, alongside the
/// `VarDCTDC` stream that precedes it in each DC group section. Returns the
/// assembled full-frame metadata. (The full low-frequency pass lives in
/// `decodeVarDCTLowFrequency`, DCImage.swift.)
@_spi(Stages) public func decodeVarDCTACMetadata(from data: [UInt8]) throws -> VarDCTACMetadata {
    try FrameDecoder(data: data).varDCTLowFrequency().metadata
}

@_spi(Stages) public func decodeVarDCTACMetadata(from data: Data) throws -> VarDCTACMetadata {
    try decodeVarDCTACMetadata(from: [UInt8](data))
}

/// Decodes the low-frequency layer plus the AC-global (HfGlobal) layer:
/// coefficient orders and AC histograms. Validates the coefficient-order ANS
/// stream's final state.
@_spi(Stages) public func decodeVarDCTACGlobalForFrame(from data: [UInt8]) throws
    -> (metadata: VarDCTACMetadata, acGlobal: VarDCTACGlobal)
{
    let d = try FrameDecoder(data: data)
    return (try d.varDCTLowFrequency().metadata, try d.varDCTACGlobal())
}

@_spi(Stages) public func decodeVarDCTACGlobalForFrame(from data: Data) throws
    -> (metadata: VarDCTACMetadata, acGlobal: VarDCTACGlobal)
{
    try decodeVarDCTACGlobalForFrame(from: [UInt8](data))
}

/// Decodes one DC group's `AcMetadata` stream and writes the group's rect of
/// the full-frame metadata fields (raw pointers so DC groups can decode
/// concurrently). Returns the group's varblock count and used-strategy mask.
func decodeAcMetadataGroup(
    _ br: BitReader, groupIndex: Int, rect: (x0: Int, y0: Int, w: Int, h: Int),
    dim: FrameDimensions, dcGlobal: VarDCTDCGlobalDecoded,
    strategy: UnsafeMutablePointer<UInt8>, isFirstBlock: UnsafeMutablePointer<Bool>,
    quantField: UnsafeMutablePointer<Int32>, epfSharpness: UnsafeMutablePointer<UInt8>,
    ytoxMap: UnsafeMutablePointer<Int8>, ytobMap: UnsafeMutablePointer<Int8>,
    valid: UnsafeMutablePointer<Bool>,
    widthBlocks: Int, heightBlocks: Int, colorTileWidth: Int
) throws -> (varblocks: Int, usedACs: UInt32) {
    var usedACs: UInt32 = 0
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
            let dst = (ctY0 + y) * colorTileWidth + (ctX0 + x)
            ytoxMap[dst] = Int8(clamping: v0)
            ytobMap[dst] = Int8(clamping: v1)
        }
    }

    // Block-by-block: assign strategies/quant, advancing `num` only at the
    // top-left of each new varblock (libjxl DecodeAcMetadata main loop).
    let acsRow = image.channels[2].pixels  // row 0 = strategy, row 1 = quant
    let qfRow0 = count  // index offset for row 1
    let epf = image.channels[3].pixels
    let bw = widthBlocks
    var num = 0
    let xlim = min(bw, rect.x0 + rect.w)
    let ylim = min(heightBlocks, rect.y0 + rect.h)

    for iy in 0..<rect.h {
        let y = rect.y0 + iy
        for ix in 0..<rect.w {
            let x = rect.x0 + ix
            let sharpness = epf[iy * rect.w + ix]
            guard sharpness >= 0, Int(sharpness) < kEpfSharpEntries else {
                throw JXLError.malformed("corrupted EPF sharpness field")
            }
            epfSharpness[y * bw + x] = UInt8(truncatingIfNeeded: sharpness)
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
                    strategy[pos] = UInt8(truncatingIfNeeded: raw)
                    isFirstBlock[pos] = (dx | dy) == 0
                }
            }
            // The quant value covers the whole varblock (libjxl fills every
            // covered row); EPF sigma reads it per 8x8 cell.
            let qf = Int(acsRow[qfRow0 + num])
            let quant = Int32(1 + max(0, min(kQuantMax - 1, qf)))
            for dy in 0..<cby {
                for dx in 0..<cbx {
                    quantField[(y + dy) * bw + (x + dx)] = quant
                }
            }
            num += 1
        }
    }
    guard num == count else { throw JXLError.malformed("AC metadata: \(num) != count \(count)") }
    return (count, usedACs)
}
