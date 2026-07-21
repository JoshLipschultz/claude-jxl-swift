// ANSWriter.swift
//
// rANS entropy writing (E2 of docs/encoder-design.md). Duals of the decoder's
// ANS path: histogram normalization to the 4096 table, `readHistogram`
// serialization (simple / complex forms; shift = 13 so every count is stored
// exactly), alias-table slot inversion (the encoder needs (symbol, offset) →
// slot, the inverse of `aliasLookup`), and the reverse-order stream encoder —
// symbols are encoded last-to-first so the decoder's forward pass reproduces
// the exact renorm schedule, then the final state and the 16-bit renorm
// chunks are written forward, interleaved with each value's raw extra bits in
// decode order.

import Foundation

// MARK: - Histogram normalization + serialization

/// Scales `histogram` to sum exactly to 4096 with every used symbol ≥ 1.
func normalizeANSCounts(_ histogram: [Int]) -> [Int32] {
    let total = histogram.reduce(0, +)
    var counts = [Int32](repeating: 0, count: histogram.count)
    if total == 0 { return counts }
    var sum = 0
    var maxIdx = 0
    for (i, h) in histogram.enumerated() where h > 0 {
        let scaled = max(1, Int((Double(h) * Double(ansTabSize) / Double(total)).rounded()))
        counts[i] = Int32(scaled)
        sum += scaled
        if h > histogram[maxIdx] { maxIdx = i }
    }
    // Push the rounding error into the most frequent symbol; if that would
    // drive it below 1, walk the error off the largest remaining counts.
    var diff = ansTabSize - sum
    while diff != 0 {
        var idx = maxIdx
        if counts[idx] + Int32(diff) < 1 {
            var best = -1
            for (i, c) in counts.enumerated() where c > 1 && i != idx {
                if best < 0 || c > counts[best] { best = i }
            }
            idx = best  // total >= 4096 shrink always has a donor
            let take = min(Int(counts[idx] - 1), -diff)
            counts[idx] -= Int32(take)
            diff += take
        } else {
            counts[idx] += Int32(diff)
            diff = 0
        }
    }
    return counts
}

/// Dual of `decodeVarLenUint8`.
func writeVarLenUint8(_ w: BitWriter, _ v: Int) {
    if v == 0 {
        w.writeBool(false)
        return
    }
    w.writeBool(true)
    let n = 31 - Int(UInt32(v).leadingZeroBitCount)
    w.write(UInt64(n), 3)
    if n > 0 { w.write(UInt64(v) & ((1 << UInt64(n)) - 1), n) }
}

/// Writes a normalized (sum == 4096) distribution (dual of `readHistogram`).
/// Uses the simple form for ≤ 2 used symbols, else the complex form with
/// shift = 13 (full precision — every count round-trips exactly; the RLE
/// "same" code is never emitted).
func writeANSHistogram(_ w: BitWriter, counts: [Int32]) {
    let used = counts.indices.filter { counts[$0] > 0 }
    precondition(counts.reduce(0, +) == Int32(ansTabSize), "histogram must be normalized")
    if used.count <= 2 {
        w.writeBool(true)  // is_simple
        w.writeBool(used.count == 2)  // num_symbols - 1
        for s in used { writeVarLenUint8(w, s) }
        if used.count == 2 { w.write(UInt64(counts[used[0]]), ansLogTabSize) }
        return
    }
    w.writeBool(false)  // not simple
    w.writeBool(false)  // not flat
    // shift = 13: unary-ish prefix (log = 3 hits the upper bound, so no
    // terminating 0 bit), then shift+1 minus the leading power in 3 bits.
    w.write(0b111, 3)
    w.write(UInt64((13 + 1) - (1 << 3)), 3)
    let length = max(3, used.last! + 1)
    writeVarLenUint8(w, length - 3)

    var logcounts = [Int](repeating: 0, count: length)
    for i in 0..<length where counts[i] > 0 {
        logcounts[i] = floorLog2Nonzero(UInt32(counts[i])) + 1
    }
    // The decoder infers the omitted position as the first strict maximum.
    var omitPos = 0
    for i in 0..<length where logcounts[i] > logcounts[omitPos] { omitPos = i }

    for i in 0..<length {
        writeLogCountSymbol(w, logcounts[i])
    }
    for i in 0..<length {
        let code = logcounts[i]
        if i == omitPos || code <= 1 { continue }
        // getPopulationCountPrecision(code-1, 13) == code-1: full precision.
        w.write(UInt64(UInt32(counts[i]) & ((1 << UInt32(code - 1)) - 1)), code - 1)
    }
}

/// Static prefix code for log-count symbols, inverted from the decoder's
/// 7-bit lookup table (dec_ans.cc `huff`): symbol → (pattern, bits).
private let kLogCountEncode: [(pattern: UInt64, bits: Int)] = {
    // (bits, value) rows in table order; find each value's canonical pattern
    // (the lowest index decoding to it, masked to its bit count).
    let table: [(UInt8, UInt8)] = [
        (3, 10), (7, 12), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (6, 11), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (7, 13), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (6, 11), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    ]
    var enc = [(UInt64, Int)](repeating: (0, 0), count: 14)
    for (idx, e) in table.enumerated() {
        let (bits, value) = (Int(e.0), Int(e.1))
        if enc[value].1 == 0 {
            enc[value] = (UInt64(idx) & ((1 << UInt64(bits)) - 1), bits)
        }
    }
    return enc
}()

private func writeLogCountSymbol(_ w: BitWriter, _ symbol: Int) {
    let e = kLogCountEncode[symbol]
    w.write(e.pattern, e.bits)
}

// MARK: - ANS stream encoding

/// One cluster's ANS coding tables: normalized counts plus the inverted alias
/// table ((symbol, offset-within-frequency) → slot, the inverse of
/// `aliasLookup`).
private struct ANSClusterCode {
    let counts: [Int32]
    let slots: [[UInt16]]

    init(histogram: [Int], logAlphaSize: Int) {
        var h = histogram
        if h.reduce(0, +) == 0 { h = [1] }  // headers need a valid code
        var normalized = normalizeANSCounts(h)
        while let last = normalized.last, last == 0, normalized.count > 1 {
            normalized.removeLast()
        }
        counts = normalized

        let tableSize = 1 << logAlphaSize
        var table = [AliasEntry](repeating: AliasEntry(), count: tableSize)
        initAliasTable(distribution: counts, logAlphaSize: logAlphaSize, into: &table, base: 0)
        var s = counts.map { [UInt16](repeating: 0, count: Int($0)) }
        let logEntrySize = ansLogTabSize - logAlphaSize
        let entrySizeMinus1 = (1 << logEntrySize) - 1
        table.withUnsafeBufferPointer { tp in
            for v in 0..<ansTabSize {
                let sym = aliasLookup(
                    tp.baseAddress!, base: 0, value: v, logEntrySize: logEntrySize,
                    entrySizeMinus1: entrySizeMinus1)
                s[sym.value][sym.offset] = UInt16(v)
            }
        }
        slots = s
    }
}

/// Full entropy encoder on the ANS back-end: clustered per-context histograms
/// (shared `ClusteredHistograms` machinery), the header dual of
/// `decodeHistograms`, and per-section reverse-order stream encoding. Each
/// section (group stream) is a fresh ANS state — the decoder constructs one
/// `ANSSymbolReader` per section against the shared code.
struct ANSEntropyEncoder {
    let clustered: ClusteredHistograms
    let logAlphaSize: Int
    private let codes: [ANSClusterCode]

    init(numContexts: Int, streams: [[EncToken]]) {
        clustered = ClusteredHistograms(numContexts: numContexts, streams: streams)
        // log_alpha_size is shared across clusters (read once by the decoder);
        // it must cover the largest cluster's trimmed alphabet.
        var maxAlphabet = 1
        for h in clustered.histograms {
            var last = 0
            for (s, c) in h.enumerated() where c > 0 { last = s }
            maxAlphabet = max(maxAlphabet, last + 1)
        }
        let las = max(5, ceilLog2Nonzero(UInt32(maxAlphabet)))
        logAlphaSize = las
        codes = clustered.histograms.map { ANSClusterCode(histogram: $0, logAlphaSize: las) }
    }

    /// Writes the entropy header (mirrors `decodeHistograms`, ANS path).
    func writeHeader(_ w: BitWriter) {
        w.writeBool(false)  // lz77 enabled
        if clustered.numContexts > 1 { clustered.writeContextMap(w) }
        w.writeBool(false)  // use_prefix_code = false: ANS
        w.write(UInt64(logAlphaSize - 5), 2)
        for _ in codes {
            // Hybrid-uint config per histogram: split_exponent=4 in
            // ceil_log2(logAlphaSize+1) bits, msb=2 in 3 bits, lsb=0 in 2 bits.
            w.write(4, ceilLog2Nonzero(UInt32(logAlphaSize + 1)))
            w.write(2, 3)
            w.write(0, 2)
        }
        for code in codes { writeANSHistogram(w, counts: code.counts) }
    }

    /// Encodes one section's tokens: reverse rANS pass to compute the final
    /// state and renorm-chunk schedule, then the forward serialization the
    /// decoder consumes (32-bit state, then per value: its renorm chunk if the
    /// decoder pulls one there, then its raw extra bits).
    func encodeStream(_ w: BitWriter, _ tokens: [EncToken]) {
        let n = tokens.count
        var symbols = [UInt32](repeating: 0, count: n)
        var cluster = [UInt8](repeating: 0, count: n)
        var extraBits = [(UInt32, UInt32)](repeating: (0, 0), count: n)
        for (i, t) in tokens.enumerated() {
            let (token, nbits, bits) = encUintConfig.encode(t.value)
            symbols[i] = token
            cluster[i] = clustered.contextMap[Int(t.ctx)]
            extraBits[i] = (nbits, bits)
        }
        var chunk = [UInt16?](repeating: nil, count: n)
        var state: UInt32 = ansSignature << 16
        var i = n - 1
        while i >= 0 {
            let code = codes[Int(cluster[i])]
            let sym = Int(symbols[i])
            let f = UInt32(code.counts[sym])
            // 64-bit compare: f == 4096 (single-symbol code) makes f << 20
            // overflow UInt32; the emit threshold is then 2^32 = never.
            if UInt64(state) >= UInt64(f) << 20 {
                chunk[i] = UInt16(truncatingIfNeeded: state)
                state >>= 16
            }
            state =
                ((state / f) << UInt32(ansLogTabSize)) | UInt32(code.slots[sym][Int(state % f)])
            i -= 1
        }
        w.write(UInt64(state), 32)
        for j in 0..<n {
            if let c = chunk[j] { w.write(UInt64(c), 16) }
            if extraBits[j].0 > 0 { w.write(UInt64(extraBits[j].1), Int(extraBits[j].0)) }
        }
    }
}
