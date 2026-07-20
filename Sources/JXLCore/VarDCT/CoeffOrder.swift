// CoeffOrder.swift
//
// VarDCT `ProcessACGlobal` (libjxl dec_frame.cc) minus the dequant-weight
// computation: the per-pass coefficient orders and AC entropy histograms that
// the per-block coefficient decode consumes.
//
//   * coefficient orders — each AC strategy reads its quantized coefficients in
//     a frequency order. The order is the strategy's "natural" (zigzag-like)
//     order, optionally permuted by a Lehmer-coded permutation in the stream.
//   * AC histograms — one ANS code + context map per pass, sized by the block
//     context map.
//
// The coefficient-order ANS stream carries its own final-state check, so a
// clean `decodeVarDCTACGlobal` is a bit-exact validation of this layer.

import Foundation

let kNumCoeffOrders = 13  // coeff_order_fwd.h kNumOrders
private let kPermutationContexts = 8
private let kDCTBlockSize = 64

// AcStrategyType -> coefficient-order bucket (ac_strategy.cc kStrategyOrder).
let kStrategyOrder: [Int] = [
    0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1, 1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12,
]

/// Per-pass decoded AC-global state.
@_spi(Stages) public struct VarDCTACGlobal: Sendable {
    public let numHistograms: Int
    /// `orders[pass][bucket*3 + channel]` — the coefficient order for each used
    /// bucket/channel (empty for buckets no AC strategy uses).
    public let orders: [[[UInt32]]]
    public let codes: [ANSCode]
    public let contextMaps: [[UInt8]]
    /// RAW-encoded dequant tables by quant-table index (nil = library default).
    /// JPEG transcodes carry their original quant tables this way.
    public let customDequant: [[Float]?]
    /// The RAW tables' integer values + denominator, kept for JPEG
    /// reconstruction (index 0 / DCT8 holds the original JPEG quant values
    /// when `den == 1/(8*255)`).
    public let rawQuant: [(den: Float, qtable: [Int32])?]
}

/// Hybrid-uint token of `val` under config(0,0,0), clamped — libjxl
/// `CoeffOrderContext`.
private func coeffOrderContext(_ val: UInt32) -> Int {
    let token = Int(HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0).encode(val).token)
    return min(token, kPermutationContexts - 1)
}

/// libjxl `AcStrategy::ComputeNaturalCoeffOrder` (CoeffOrderAndLut, is_lut=false).
/// `cbx`/`cby` are the strategy's covered block counts.
func computeNaturalCoeffOrder(cbx: Int, cby: Int) -> [UInt32] {
    // CoefficientLayout: rows = min, columns = max.
    let cy = min(cbx, cby)
    let cx = max(cbx, cby)
    let size = kDCTBlockSize * cbx * cby
    var out = [UInt32](repeating: 0, count: size)
    let xs = cx / cy
    let xsm = xs - 1
    let xss = ceilLog2Nonzero(UInt32(xs))
    var cur = cx * cy
    // First half.
    for i in 0..<(cx * kBlockDim) {
        for j in 0...i {
            var x = j
            var y = i - j
            if i % 2 != 0 { swap(&x, &y) }
            if (y & xsm) != 0 { continue }
            y >>= xss
            let val: Int
            if x < cx && y < cy {
                val = y * cx + x
            } else {
                val = cur
                cur += 1
            }
            out[val] = UInt32(y * cx * kBlockDim + x)
        }
    }
    // Second half.
    var ip = cx * kBlockDim - 1
    while ip > 0 {
        let i = ip - 1
        for j in 0...i {
            var x = cx * kBlockDim - 1 - (i - j)
            var y = cx * kBlockDim - 1 - j
            if i % 2 != 0 { swap(&x, &y) }
            if (y & xsm) != 0 { continue }
            y >>= xss
            out[cur] = UInt32(y * cx * kBlockDim + x)
            cur += 1
        }
        ip -= 1
    }
    return out
}

/// libjxl `DecodeLehmerCode` (lehmer_code.h) — Fenwick-tree order statistics.
private func decodeLehmerCode(_ code: [UInt32], n: Int) -> [UInt32] {
    let log2n = ceilLog2Nonzero(UInt32(n))
    let paddedN = 1 << log2n
    var temp = [UInt32](repeating: 0, count: paddedN)
    for i in 0..<paddedN {
        let i1 = i + 1
        temp[i] = UInt32(i1 & (-i1))  // ValueOfLowest1Bit
    }
    var permutation = [UInt32](repeating: 0, count: n)
    for i in 0..<n {
        var rank = code[i] + 1
        var bit = paddedN
        var next = 0
        for _ in 0...log2n {
            let cand = next + bit
            bit >>= 1
            if temp[cand - 1] < rank {
                next = cand
                rank -= temp[cand - 1]
            }
        }
        permutation[i] = UInt32(next)
        next += 1
        while next <= paddedN {
            temp[next - 1] -= 1
            next += next & (-next)
        }
    }
    return permutation
}

/// libjxl `ReadPermutation`. Reads the Lehmer code; materializes the permutation
/// only when `materialize` (matching libjxl's `order == nullptr` skip path).
private func readPermutation(
    skip: Int, size: Int, br: BitReader, reader: ANSSymbolReader, ctxMap: [UInt8],
    materialize: Bool
) throws -> [UInt32]? {
    let end = Int(reader.readHybridUintClustered(Int(ctxMap[coeffOrderContext(UInt32(size))]), br)) + skip
    guard end <= size else { throw JXLError.malformed("invalid permutation size") }
    var lehmer = [UInt32](repeating: 0, count: size)
    var last: UInt32 = 0
    var i = skip
    while i < end {
        let v = reader.readHybridUintClustered(Int(ctxMap[coeffOrderContext(last)]), br)
        lehmer[i] = v
        last = v
        guard v < UInt32(size - i) else { throw JXLError.malformed("invalid lehmer code") }
        i += 1
    }
    guard materialize else { return nil }
    return decodeLehmerCode(lehmer, n: size)
}

/// libjxl `DecodeCoeffOrders` for one pass. Returns `bucket*3 + channel` orders.
private func decodeCoeffOrders(
    usedOrders: UInt32, usedACs: UInt32, br: BitReader
) throws -> [[UInt32]] {
    var result = [[UInt32]](repeating: [], count: 3 * kNumCoeffOrders)
    var reader: ANSSymbolReader? = nil
    var ctxMap: [UInt8] = []
    if usedOrders != 0 {
        guard let (code, cm) = decodeHistograms(br, numContexts: kPermutationContexts, disallowLZ77: false)
        else { throw JXLError.malformed("could not read coeff-order histograms") }
        reader = ANSSymbolReader(code: code, reader: br)
        ctxMap = cm
    }

    var acsMask: UInt32 = 0
    for o in 0..<kVarDCTNumStrategies where (usedACs & (UInt32(1) << UInt32(o))) != 0 {
        acsMask |= UInt32(1) << UInt32(kStrategyOrder[o])
    }

    var computed: UInt32 = 0
    for o in 0..<kVarDCTNumStrategies {
        let ord = kStrategyOrder[o]
        if (computed & (UInt32(1) << UInt32(ord))) != 0 { continue }
        computed |= UInt32(1) << UInt32(ord)
        let cbx = kCoveredBlocksX[o]
        let cby = kCoveredBlocksY[o]
        let llf = cbx * cby
        let size = kDCTBlockSize * llf
        let used = (acsMask & (UInt32(1) << UInt32(ord))) != 0
        let hasCustom = (usedOrders & (UInt32(1) << UInt32(ord))) != 0

        let natural = (used || hasCustom) ? computeNaturalCoeffOrder(cbx: cbx, cby: cby) : []
        if !hasCustom {
            if used {
                for c in 0..<3 { result[ord * 3 + c] = natural }
            }
        } else {
            guard let r = reader else { throw JXLError.malformed("coeff order reader missing") }
            for c in 0..<3 {
                let perm = try readPermutation(
                    skip: llf, size: size, br: br, reader: r, ctxMap: ctxMap, materialize: used)
                if used, let perm {
                    // order[k] = natural_order[perm[k]]
                    result[ord * 3 + c] = perm.map { natural[Int($0)] }
                }
            }
        }
    }
    if usedOrders != 0, let r = reader, !r.checkANSFinalState() {
        throw JXLError.malformed("invalid coeff-order ANS stream")
    }
    return result
}

// kOrderEnc = U32Enc(Val(0x5F), Val(0x13), Val(0), Bits(kNumOrders=13)).
private let kOrderEnc0 = U32Choice.value(0x5F)
private let kOrderEnc1 = U32Choice.value(0x13)
private let kOrderEnc2 = U32Choice.value(0)
private let kOrderEnc3 = U32Choice.bits(13)

/// libjxl `FrameDecoder::ProcessACGlobal`. `br` is positioned at the start of
/// the HfGlobal/AC-global section. `dcGlobal` supplies the global modular
/// tree, which RAW quant tables (JPEG transcodes) are coded with.
func decodeVarDCTACGlobal(
    _ br: BitReader, dim: FrameDimensions, numPasses: Int,
    blockContextMap: VarDCTBlockContextMap, usedACs: UInt32,
    dcGlobal: VarDCTDCGlobalDecoded
) throws -> VarDCTACGlobal {
    // DequantMatrices::Decode: default tables read just the "all default" bit;
    // otherwise all 17 table encodings follow. Library (mode 0) and RAW
    // (mode 7, modular-coded original quant tables) are supported.
    let dequantDefault = br.read(1) == 1
    var customDequant = [[Float]?](repeating: nil, count: kNumQuantTablesTotal)
    var rawQuant = [(den: Float, qtable: [Int32])?](repeating: nil, count: kNumQuantTablesTotal)
    if !dequantDefault {
        for idx in 0..<kNumQuantTablesTotal {
            let mode = br.read(3)
            switch mode {
            case 0:  // Library (kCeilLog2NumPredefinedTables == 0: no index bits)
                break
            case 7:  // RAW: F16 denominator + modular-coded 3-channel table
                let den = br.readF16()
                guard den > 1e-8 else { throw JXLError.malformed("invalid qtable_den") }
                let w = kRequiredQuantSizeX[idx] * 8
                let h = kRequiredQuantSizeY[idx] * 8
                let image = ModularImage(w: w, h: h, bitdepth: 8, channelCount: 3)
                // ModularStreamId::QuantTable(idx).ID
                let streamID = 1 + 3 * dim.numDCGroups + idx
                _ = try modularDecode(
                    br, image: image, groupID: streamID,
                    globalTree: dcGlobal.tree, globalCode: dcGlobal.code,
                    globalCtxMap: dcGlobal.ctxMap)
                // ComputeQuantTable RAW: inverse weights are 1/(den*qtable) and
                // the final dequant table inverts them, i.e. den * qtable, in
                // the same layout the coefficient storage uses.
                let num = w * h
                var weights = [Float](repeating: 0, count: 3 * num)
                for c in 0..<3 {
                    let q = image.channels[c].pixels
                    for i in 0..<num {
                        guard q[i] > 0 else { throw JXLError.malformed("invalid raw qtable") }
                        weights[c * num + i] = den * Float(q[i])
                    }
                }
                customDequant[idx] = weights
                rawQuant[idx] = (
                    den,
                    image.channels[0].pixels + image.channels[1].pixels
                        + image.channels[2].pixels
                )
            case 1, 2, 3, 4, 5, 6:
                // Parametric quant matrices (ID / DCT2 / DCT4 / DCT4X8 / AFV /
                // DCT): read the mode's params and compute the dequant table
                // through the same builders as the library defaults.
                guard let table = decodeCustomQuantTable(br, mode: Int(mode), idx: idx) else {
                    throw JXLError.malformed("invalid custom quant matrix (mode \(mode))")
                }
                customDequant[idx] = table
            default:
                throw JXLError.unsupported("custom VarDCT quant mode \(mode)")
            }
        }
    }

    let numHistograms = 1 + Int(br.read(ceilLog2Nonzero(UInt32(dim.numGroups))))

    var orders: [[[UInt32]]] = []
    var codes: [ANSCode] = []
    var ctxMaps: [[UInt8]] = []
    for _ in 0..<numPasses {
        let usedOrders = br.readU32(kOrderEnc0, kOrderEnc1, kOrderEnc2, kOrderEnc3)
        let passOrders = try decodeCoeffOrders(usedOrders: usedOrders, usedACs: usedACs, br: br)
        let numContexts = numHistograms * blockContextMap.numACContexts
        guard let (code, cm) = decodeHistograms(br, numContexts: numContexts, disallowLZ77: false)
        else { throw JXLError.malformed("could not read AC histograms") }
        orders.append(passOrders)
        codes.append(code)
        ctxMaps.append(cm)
    }
    try br.ensureInBounds("VarDCT AC global")
    return VarDCTACGlobal(
        numHistograms: numHistograms, orders: orders, codes: codes, contextMaps: ctxMaps,
        customDequant: customDequant, rawQuant: rawQuant)
}

/// Total quant tables in the codestream (libjxl kNumQuantTables), including
/// the DCT64+ kinds beyond the reconstruction's supported range.
let kNumQuantTablesTotal = 17
/// libjxl `DequantMatrices::required_size_x/y` (in 8x8 blocks) per table index.
let kRequiredQuantSizeX = [1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16]
let kRequiredQuantSizeY = [1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32]
