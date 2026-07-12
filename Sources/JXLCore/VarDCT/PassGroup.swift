// PassGroup.swift
//
// VarDCT per-group AC coefficient entropy decode (libjxl v0.11.2 dec_group.cc
// `DecodeGroupImpl` + `DecodeACVarBlock`). For each varblock, for each channel
// (in Y, X, B order), it reads the number of non-zero AC coefficients, then the
// coefficients themselves in the block's frequency ("coeff order") scan, using
// the block-context map for entropy contexts. The decoded values are quantized
// integers; dequantization + inverse DCT come next.
//
// Validation: the per-pass ANS stream ends with a final-state check (libjxl
// `CheckANSFinalState`), so a clean decode of every group is bit-exact.
//
// Restrictions match the rest of the VarDCT path: single pass, 4:4:4.

import Foundation

private let kDCTBlockSize = 64
private let kNonZeroBuckets = 37
private let kZeroDensityContextCount = 458
private let kZeroDensityContextLimit = 474

// libjxl ac_context.h frequency/non-zero clustering tables.
private let kCoeffFreqContext: [Int] = [
    0xBAD, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
]
private let kCoeffNumNonzeroContext: [Int] = [
    0xBAD, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123,
    152, 152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180, 180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
]

/// One decoded varblock: position, strategy, and quantized coefficients per
/// channel. The coefficient buffer has `coveredX*coveredY*kDCTBlockSize`
/// entries; the first `coveredX*coveredY` (LLF) positions are left zero here and
/// are filled from the DC image during reconstruction.
public struct VarDCTBlock {
    public let bx: Int
    public let by: Int
    public let strategy: UInt8
    public let coveredX: Int
    public let coveredY: Int
    /// `[channel][coveredX*coveredY*64]`, indexed in the block's coeff layout.
    public var coeff: [[Int32]]
}

/// All decoded varblocks of a frame plus a decode summary.
public struct VarDCTCoefficients {
    public let blocks: [VarDCTBlock]
    public let totalNonZeros: Int
}

// MARK: - Block context map (libjxl BlockCtxMap)

private func blockCtxContext(
    _ m: VarDCTBlockContextMap, dcIdx: Int, qf: Int32, ord: Int, c: Int
) -> Int {
    var qfIdx = 0
    for t in m.qfThresholds where UInt32(bitPattern: qf) > t { qfIdx += 1 }
    var idx = c < 2 ? c ^ 1 : 2
    idx = idx * kNumCoeffOrders + ord
    idx = idx * (m.qfThresholds.count + 1) + qfIdx
    idx = idx * m.numDCContexts + dcIdx
    return Int(m.contextMap[idx])
}

private func blockCtxNonZeroContext(_ m: VarDCTBlockContextMap, nonZeros: Int, blockCtx: Int) -> Int {
    var nz = nonZeros
    if nz >= 64 { nz = 64 }
    let ctx: Int = nz < 8 ? nz : 4 + nz / 2
    return ctx * m.numContexts + blockCtx
}

private func blockCtxZeroDensityOffset(_ m: VarDCTBlockContextMap, blockCtx: Int) -> Int {
    m.numContexts * kNonZeroBuckets + kZeroDensityContextCount * blockCtx
}

/// libjxl `ZeroDensityContext`.
private func zeroDensityContext(
    nonzerosLeft: Int, k: Int, coveredBlocks: Int, log2Covered: Int, prev: Int
) -> Int {
    let nz = (nonzerosLeft + coveredBlocks - 1) >> log2Covered
    let kk = k >> log2Covered
    return (kCoeffNumNonzeroContext[nz] + kCoeffFreqContext[kk]) * 2 + prev
}

/// libjxl `PredictFromTopAndLeft` (default 32).
private func predictFromTopAndLeft(
    nz: [Int32], w: Int, bx: Int, by: Int
) -> Int32 {
    let hasTop = by > 0
    if bx == 0 {
        return hasTop ? nz[(by - 1) * w + bx] : 32
    }
    let left = nz[by * w + (bx - 1)]
    if !hasTop { return left }
    return (nz[(by - 1) * w + bx] + left + 1) / 2
}

private func log2OfPow2(_ v: Int) -> Int { v.trailingZeroBitCount }

// MARK: - Group decode

/// Decodes all AC coefficients of a single-pass, 4:4:4 VarDCT frame.
public func decodeVarDCTCoefficients(from data: [UInt8]) throws -> VarDCTCoefficients {
    try FrameDecoder(data: data).varDCTCoefficients()
}

/// Stage implementation for `FrameDecoder.varDCTCoefficients()`: forces the
/// low-frequency and AC-global stages, then entropy-decodes every AC group.
func decodeVarDCTCoefficients(_ d: FrameDecoder) throws -> VarDCTCoefficients {
    let meta = try d.varDCTLowFrequency().metadata
    let acGlobal = try d.varDCTACGlobal()

    let bctx = try d.varDCTDCGlobal().info.blockContextMap
    // Context map padded by the "cheat" margin so out-of-range zero-density
    // contexts index validly (libjxl resize to num_contexts + limit - count).
    let numContexts = acGlobal.numHistograms * bctx.numACContexts
    var ctxMap = acGlobal.contextMaps[0]
    if ctxMap.count < numContexts + kZeroDensityContextLimit - kZeroDensityContextCount {
        ctxMap += [UInt8](
            repeating: 0,
            count: numContexts + kZeroDensityContextLimit - kZeroDensityContextCount - ctxMap.count)
    }
    let histoSelectorBits = ceilLog2Nonzero(UInt32(acGlobal.numHistograms))

    var blocks: [VarDCTBlock] = []
    var totalNonZeros = 0
    let dim = d.dim
    let bgDim = dim.groupDim >> 3  // group dimension in blocks

    // Each AC group is a pure function of its own section bytes plus the
    // immutable globals above, so this loop can become concurrent per group
    // (coalesced frames excepted: they share one sequential reader).
    for g in 0..<dim.numGroups {
        let gx = g % dim.xsizeGroups
        let gy = g / dim.xsizeGroups
        let bx0 = gx * bgDim
        let by0 = gy * bgDim
        let gw = min(bgDim, dim.xsizeBlocks - bx0)
        let gh = min(bgDim, dim.ysizeBlocks - by0)

        try decodeACGroup(
            d.acGroupReader(g), meta: meta, acGlobal: acGlobal, bctx: bctx, ctxMap: ctxMap,
            histoSelectorBits: histoSelectorBits, bx0: bx0, by0: by0, gw: gw, gh: gh,
            blockW: dim.xsizeBlocks, blocks: &blocks, totalNonZeros: &totalNonZeros)
    }

    return VarDCTCoefficients(blocks: blocks, totalNonZeros: totalNonZeros)
}

public func decodeVarDCTCoefficients(from data: Data) throws -> VarDCTCoefficients {
    try decodeVarDCTCoefficients(from: [UInt8](data))
}

private func decodeACGroup(
    _ br: BitReader, meta: VarDCTACMetadata, acGlobal: VarDCTACGlobal,
    bctx: VarDCTBlockContextMap, ctxMap: [UInt8], histoSelectorBits: Int,
    bx0: Int, by0: Int, gw: Int, gh: Int, blockW: Int,
    blocks: inout [VarDCTBlock], totalNonZeros: inout Int
) throws {
    var curHistogram = 0
    if histoSelectorBits != 0 { curHistogram = Int(br.read(histoSelectorBits)) }
    guard curHistogram < acGlobal.numHistograms else {
        throw JXLError.malformed("invalid histogram selector")
    }
    let ctxOffset = curHistogram * bctx.numACContexts
    let reader = ANSSymbolReader(code: acGlobal.codes[0], reader: br)

    // Group-local non-zero prediction planes (per channel).
    var nzeros = [[Int32]](repeating: [Int32](repeating: 0, count: gw * gh), count: 3)
    let orders = acGlobal.orders[0]

    for byl in 0..<gh {
        let by = by0 + byl
        for bxl in 0..<gw {
            let bx = bx0 + bxl
            let pos = by * blockW + bx
            if !meta.isFirstBlock[pos] { continue }
            let strategy = Int(meta.strategy[pos])
            let cx = kCoveredBlocksX[strategy]
            let cy = kCoveredBlocksY[strategy]
            let covered = cx * cy
            let log2Covered = log2OfPow2(covered)
            let size = covered * kDCTBlockSize
            let ord = kStrategyOrder[strategy]

            var coeff = [[Int32]](repeating: [Int32](repeating: 0, count: size), count: 3)
            let qf = meta.quantField[pos]
            // DC context index: quant_dc field; 0 when num_dc_ctxs == 1.
            let dcIdx = 0

            // Channels in Y, X, B order.
            for c in [1, 0, 2] {
                let blockCtx = blockCtxContext(bctx, dcIdx: dcIdx, qf: qf, ord: ord, c: c)
                let predicted = Int(predictFromTopAndLeft(nz: nzeros[c], w: gw, bx: bxl, by: byl))
                let nzeroCtx = blockCtxNonZeroContext(bctx, nonZeros: predicted, blockCtx: blockCtx)
                    + ctxOffset
                var nz = Int(reader.readHybridUintClustered(Int(ctxMap[nzeroCtx]), br))
                guard nz <= size - covered else {
                    throw JXLError.malformed("invalid AC: too many nonzeros")
                }
                let stored = Int32((nz + covered - 1) >> log2Covered)
                for y in 0..<cy {
                    for x in 0..<cx { nzeros[c][(byl + y) * gw + (bxl + x)] = stored }
                }
                totalNonZeros += nz

                let order = orders[ord * 3 + c]
                let histoOffset = ctxOffset + blockCtxZeroDensityOffset(bctx, blockCtx: blockCtx)
                var prev = nz > size / 16 ? 0 : 1
                var k = covered
                while k < size && nz != 0 {
                    let ctx = histoOffset
                        + zeroDensityContext(
                            nonzerosLeft: nz, k: k, coveredBlocks: covered,
                            log2Covered: log2Covered, prev: prev)
                    let u = reader.readHybridUintClustered(Int(ctxMap[ctx]), br)
                    // UnpackSigned without UB.
                    let magnitude = Int32(bitPattern: u >> 1)
                    let negSign = Int32(bitPattern: (~u) & 1)
                    let value = (magnitude ^ (negSign &- 1))
                    coeff[c][Int(order[k])] = coeff[c][Int(order[k])] &+ value
                    prev = u != 0 ? 1 : 0
                    nz -= prev
                    k += 1
                }
                guard nz == 0 else { throw JXLError.malformed("invalid AC: nonzeros remain") }
            }
            blocks.append(
                VarDCTBlock(bx: bx, by: by, strategy: UInt8(strategy), coveredX: cx, coveredY: cy, coeff: coeff))
        }
    }

    guard reader.checkANSFinalState() else {
        throw JXLError.malformed("AC group ANS checksum failure")
    }
}
