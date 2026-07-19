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
@_spi(Stages) public struct VarDCTBlock: Sendable {
    public let bx: Int
    public let by: Int
    public let strategy: UInt8
    public let coveredX: Int
    public let coveredY: Int
    /// `[channel][coveredX*coveredY*64]`, indexed in the block's coeff layout.
    public var coeff: [[Int32]]
}

/// All decoded varblocks of a frame plus a decode summary.
@_spi(Stages) public struct VarDCTCoefficients: Sendable {
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
@_spi(Stages) public func decodeVarDCTCoefficients(from data: [UInt8]) throws -> VarDCTCoefficients {
    try FrameDecoder(data: data).varDCTCoefficients()
}

/// Stage implementation for `FrameDecoder.varDCTCoefficients()`: forces the
/// low-frequency and AC-global stages, then entropy-decodes every AC group.
func decodeVarDCTCoefficients(_ d: FrameDecoder) throws -> VarDCTCoefficients {
    let meta = try d.varDCTLowFrequency().metadata
    let acGlobal = try d.varDCTACGlobal()

    let bctx = try d.varDCTDCGlobal().info.blockContextMap
    // Per-pass context maps padded by the "cheat" margin so out-of-range
    // zero-density contexts index validly (libjxl resize to num_contexts +
    // limit - count).
    let numContexts = acGlobal.numHistograms * bctx.numACContexts
    let numPasses = Int(d.frameHeader.numPasses)
    let passShifts = d.frameHeader.passShifts.map(Int.init)
    let ctxMaps: [[UInt8]] = (0..<numPasses).map { pass in
        var map = acGlobal.contextMaps[pass]
        if map.count < numContexts + kZeroDensityContextLimit - kZeroDensityContextCount {
            map += [UInt8](
                repeating: 0,
                count: numContexts + kZeroDensityContextLimit - kZeroDensityContextCount - map.count)
        }
        return map
    }
    let histoSelectorBits = ceilLog2Nonzero(UInt32(acGlobal.numHistograms))

    let dim = d.dim
    let bgDim = dim.groupDim >> 3  // group dimension in blocks
    let blockW = dim.xsizeBlocks
    let shifts = d.frameHeader.channelShifts

    let groupBounds: @Sendable (Int) -> (bx0: Int, by0: Int, gw: Int, gh: Int) = { g in
        let bx0 = (g % dim.xsizeGroups) * bgDim
        let by0 = (g / dim.xsizeGroups) * bgDim
        return (bx0, by0, min(bgDim, dim.xsizeBlocks - bx0), min(bgDim, dim.ysizeBlocks - by0))
    }

    // After a group's AC coefficients, the same section carries the group's
    // modular data — extra channels bigger than group_dim (libjxl
    // ModularStreamId::ModularAC). Nothing is read when there are none.
    let dcGlobal = try d.varDCTDCGlobal()
    let ecImage = d.ecImage
    let ecStreamID: @Sendable (Int) -> Int = { g in 1 + 3 * dim.numDCGroups + 17 + g }

    // A coalesced frame has a single group read sequentially from the shared
    // section-0 reader.
    if d.coalesced {
        let (bx0, by0, gw, gh) = groupBounds(0)
        let reader = d.acGroupReader(0)
        var blocks: [VarDCTBlock] = []
        let nz = try decodeACGroupPass(
            reader, meta: meta, acGlobal: acGlobal, bctx: bctx, ctxMap: ctxMaps[0],
            histoSelectorBits: histoSelectorBits, bx0: bx0, by0: by0, gw: gw, gh: gh,
            blockW: blockW, shifts: shifts, pass: 0, coeffShift: 0, blocks: &blocks)
        if let ecImage,
            let ecResult = try decodeModularGroupImage(
                reader, fullImage: ecImage, group: 0, dim: dim,
                globalTree: dcGlobal.tree, globalCode: dcGlobal.code,
                globalCtxMap: dcGlobal.ctxMap, streamID: ecStreamID(0)) {
            blitModularGroup(ecResult, into: ecImage)
        }
        return VarDCTCoefficients(blocks: blocks, totalNonZeros: nz)
    }

    // Each AC group is a pure function of its own section bytes plus the
    // immutable value-type globals above, so groups decode concurrently. Only
    // Sendable values are captured; each iteration owns its BitReader and
    // writes one distinct pre-allocated slot. The extra-channel image is only
    // read (channel layout) during the concurrent phase; blits are serial.
    typealias GroupResult = Result<
        (blocks: [VarDCTBlock], nonZeros: Int, ec: ModularGroupResult?), Error>
    let codestream = d.codestream
    // Row-major [group][pass] section ranges.
    let sectionRanges = (0..<dim.numGroups).map { g in
        (0..<numPasses).map { pass in
            d.sectionRange(acGroupIndex(
                pass: pass, group: g, numGroups: dim.numGroups, numDCGroups: dim.numDCGroups))
        }
    }
    var results = [GroupResult?](repeating: nil, count: dim.numGroups)
    results.withUnsafeMutableBufferPointer { slots in
        // Each iteration writes only its own pre-allocated slot, so handing the
        // buffer to concurrent code is race-free by construction.
        nonisolated(unsafe) let out = slots
        nonisolated(unsafe) let ec = ecImage
        let tree = dcGlobal.tree
        let code = dcGlobal.code
        let treeCtxMap = dcGlobal.ctxMap
        DispatchQueue.concurrentPerform(iterations: dim.numGroups) { g in
            let (bx0, by0, gw, gh) = groupBounds(g)
            out[g] = GroupResult {
                // Passes accumulate into the same block list, in pass order.
                var groupBlocks: [VarDCTBlock] = []
                var nonZeros = 0
                var lastReader: BitReader? = nil
                for pass in 0..<numPasses {
                    let reader = BitReader(codestream, byteRange: sectionRanges[g][pass])
                    nonZeros += try decodeACGroupPass(
                        reader,
                        meta: meta, acGlobal: acGlobal, bctx: bctx, ctxMap: ctxMaps[pass],
                        histoSelectorBits: histoSelectorBits, bx0: bx0, by0: by0, gw: gw, gh: gh,
                        blockW: blockW, shifts: shifts, pass: pass,
                        coeffShift: passShifts[pass], blocks: &groupBlocks)
                    lastReader = reader
                }
                let ecResult = try ec.flatMap {
                    try decodeModularGroupImage(
                        lastReader!, fullImage: $0, group: g, dim: dim,
                        globalTree: tree, globalCode: code, globalCtxMap: treeCtxMap,
                        streamID: ecStreamID(g))
                }
                return (groupBlocks, nonZeros, ecResult)
            }
        }
    }

    var blocks: [VarDCTBlock] = []
    var totalNonZeros = 0
    for result in results {
        let (groupBlocks, nz, ecResult) = try result!.get()
        blocks.append(contentsOf: groupBlocks)
        totalNonZeros += nz
        if let ecResult, let ecImage {
            blitModularGroup(ecResult, into: ecImage)
        }
    }
    return VarDCTCoefficients(blocks: blocks, totalNonZeros: totalNonZeros)
}

@_spi(Stages) public func decodeVarDCTCoefficients(from data: Data) throws -> VarDCTCoefficients {
    try decodeVarDCTCoefficients(from: [UInt8](data))
}

private func decodeACGroupPass(
    _ br: BitReader, meta: VarDCTACMetadata, acGlobal: VarDCTACGlobal,
    bctx: VarDCTBlockContextMap, ctxMap: [UInt8], histoSelectorBits: Int,
    bx0: Int, by0: Int, gw: Int, gh: Int, blockW: Int, shifts: (h: [Int], v: [Int]),
    pass: Int, coeffShift: Int, blocks: inout [VarDCTBlock]
) throws -> Int {
    let firstPass = pass == 0
    var blockIndex = 0
    var totalNonZeros = 0
    var curHistogram = 0
    if histoSelectorBits != 0 { curHistogram = Int(br.read(histoSelectorBits)) }
    guard curHistogram < acGlobal.numHistograms else {
        throw JXLError.malformed("invalid histogram selector")
    }
    let ctxOffset = curHistogram * bctx.numACContexts
    let reader = ANSSymbolReader(code: acGlobal.codes[pass], reader: br)

    // Group-local non-zero prediction planes, per channel at that channel's
    // subsampled resolution (libjxl num_nzeroes planes). Fresh per pass: each
    // pass codes its own non-zero counts.
    let is444 = shifts.h == [0, 0, 0] && shifts.v == [0, 0, 0]
    let nzW = (0..<3).map { divCeil(gw, 1 << shifts.h[$0]) }
    let nzH = (0..<3).map { divCeil(gh, 1 << shifts.v[$0]) }
    var nzeros = (0..<3).map { [Int32](repeating: 0, count: nzW[$0] * nzH[$0]) }
    let orders = acGlobal.orders[pass]

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

            var coeff: [[Int32]]
            if firstPass {
                coeff = [[], [], []]
            } else {
                // Later passes add into the block created by pass 0. Detach
                // the storage so the in-place accumulation below stays unique.
                coeff = blocks[blockIndex].coeff
                blocks[blockIndex].coeff = []
            }
            // DC context index (libjxl qdc_row[lbx], full-res position).
            let dcIdx = Int(meta.dcQuantContext[pos])

            // Channels in Y, X, B order; subsampled channels carry
            // coefficients only at aligned block positions.
            for c in [1, 0, 2] {
                let hs = shifts.h[c]
                let vs = shifts.v[c]
                let sbxl = bxl >> hs
                let sbyl = byl >> vs
                if (sbxl << hs) != bxl || (sbyl << vs) != byl { continue }
                if !is444 && (hs != 0 || vs != 0) && covered != 1 {
                    throw JXLError.unsupported("multi-block AC strategy on subsampled channel")
                }
                // The channel plane is detached into a local (fresh on the
                // first pass, moved out of the block afterwards) and written
                // through a bound buffer pointer: the conditional provenance
                // otherwise defeats uniqueness analysis and every write pays
                // a COW check.
                var chan: [Int32]
                if firstPass {
                    chan = [Int32](repeating: 0, count: size)
                } else {
                    chan = coeff[c]
                    coeff[c] = []
                    guard chan.count == size else {
                        throw JXLError.malformed("pass block size mismatch")
                    }
                }

                // Block context: libjxl's GetBlockFromBitstream reads the raw
                // quant field at (full-res row, rect.x0 + subsampled x).
                let qf = meta.quantField[by * blockW + bx0 + sbxl]
                let blockCtx = blockCtxContext(bctx, dcIdx: dcIdx, qf: qf, ord: ord, c: c)
                let predicted = Int(
                    predictFromTopAndLeft(nz: nzeros[c], w: nzW[c], bx: sbxl, by: sbyl))
                let nzeroCtx = blockCtxNonZeroContext(bctx, nonZeros: predicted, blockCtx: blockCtx)
                    + ctxOffset
                var nz = Int(reader.readHybridUintClustered(Int(ctxMap[nzeroCtx]), br))
                guard nz <= size - covered else {
                    throw JXLError.malformed("invalid AC: too many nonzeros")
                }
                let stored = Int32((nz + covered - 1) >> log2Covered)
                for y in 0..<cy {
                    for x in 0..<cx { nzeros[c][(sbyl + y) * nzW[c] + (sbxl + x)] = stored }
                }
                totalNonZeros += nz

                let order = orders[ord * 3 + c]
                let histoOffset = ctxOffset + blockCtxZeroDensityOffset(bctx, blockCtx: blockCtx)
                var prev = nz > size / 16 ? 0 : 1
                var k = covered
                chan.withUnsafeMutableBufferPointer { cbuf in
                    order.withUnsafeBufferPointer { obuf in
                        while k < size && nz != 0 {
                            let ctx = histoOffset
                                + zeroDensityContext(
                                    nonzerosLeft: nz, k: k, coveredBlocks: covered,
                                    log2Covered: log2Covered, prev: prev)
                            let u = reader.readHybridUintClustered(Int(ctxMap[ctx]), br)
                            // UnpackSigned without UB, then the pass's shift.
                            let magnitude = Int32(bitPattern: u >> 1)
                            let negSign = Int32(bitPattern: (~u) & 1)
                            let value = (magnitude ^ (negSign &- 1)) << coeffShift
                            let idx = Int(obuf[k])
                            cbuf[idx] = cbuf[idx] &+ value
                            prev = u != 0 ? 1 : 0
                            nz -= prev
                            k += 1
                        }
                    }
                }
                guard nz == 0 else { throw JXLError.malformed("invalid AC: nonzeros remain") }
                coeff[c] = chan
            }
            if firstPass {
                blocks.append(
                    VarDCTBlock(
                        bx: bx, by: by, strategy: UInt8(strategy), coveredX: cx, coveredY: cy,
                        coeff: coeff))
            } else {
                blocks[blockIndex].coeff = coeff
            }
            blockIndex += 1
        }
    }

    guard reader.checkANSFinalState() else {
        throw JXLError.malformed("AC group ANS checksum failure")
    }
    return totalNonZeros
}
