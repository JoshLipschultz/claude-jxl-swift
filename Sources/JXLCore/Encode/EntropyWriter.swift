// EntropyWriter.swift
//
// Real prefix-code entropy writing (E1 completion; replaces the flat-code
// stopgap). Builds length-limited canonical Huffman codes from token
// histograms via package-merge and serializes them in the bitstream's two
// forms — "simple" (1-4 explicit symbols) and "complex" (per-symbol lengths
// coded with the static code-length code, with Brotli-style repeat codes).
// Every writer here is the exact dual of the decoder's PrefixCode.swift /
// EntropyDecoder.swift readers; validity is proven by round-trips through
// those readers plus djxl in-suite.

import Foundation

// MARK: - Length-limited Huffman (package-merge)

/// Code lengths (0 = unused) for `histogram`, all lengths ≤ `maxBits`,
/// Kraft-exact (sum of 2^-len over used symbols == 1) whenever two or more
/// symbols are used. Boundary package-merge; optimal under the length limit.
func limitedHuffmanLengths(histogram: [Int], maxBits: Int) -> [UInt8] {
    let used = histogram.enumerated().filter { $0.element > 0 }.map { $0.offset }
    var lengths = [UInt8](repeating: 0, count: histogram.count)
    if used.isEmpty { return lengths }
    if used.count == 1 {
        // Not Kraft-exact — callers must use the simple form for one symbol.
        lengths[used[0]] = 1
        return lengths
    }
    // Package-merge over (weight, per-symbol counts). Alphabets here are tiny
    // (hybrid-uint tokens; ≤ a few dozen used symbols), so the quadratic
    // symbol-count merging is noise.
    struct Node {
        var weight: Int
        var counts: [Int]  // index into `used`
    }
    let n = used.count
    let leaves: [Node] = used.enumerated()
        .map { i, sym in
            var c = [Int](repeating: 0, count: n)
            c[i] = 1
            return Node(weight: histogram[sym], counts: c)
        }
        .sorted { $0.weight < $1.weight }
    var level: [Node] = []
    for _ in 0..<maxBits {
        // Package pairs from the previous level, then merge with the leaves.
        var packages: [Node] = []
        var i = 0
        while i + 1 < level.count {
            var merged = level[i]
            merged.weight += level[i + 1].weight
            for k in 0..<n { merged.counts[k] += level[i + 1].counts[k] }
            packages.append(merged)
            i += 2
        }
        var next: [Node] = []
        next.reserveCapacity(leaves.count + packages.count)
        var a = 0
        var b = 0
        while a < leaves.count || b < packages.count {
            if b >= packages.count || (a < leaves.count && leaves[a].weight <= packages[b].weight) {
                next.append(leaves[a])
                a += 1
            } else {
                next.append(packages[b])
                b += 1
            }
        }
        level = next
    }
    // The first 2n-2 nodes of the final level: each appearance of a symbol
    // adds one to its code length.
    for node in level.prefix(2 * n - 2) {
        for k in 0..<n where node.counts[k] > 0 {
            lengths[used[k]] += UInt8(node.counts[k])
        }
    }
    return lengths
}

/// Canonical prefix codes for `lengths`, pre-bit-reversed for the LSB-first
/// stream (the decoder's buildHuffmanTable assigns codes in (length, symbol)
/// order; writing the reversed canonical key reproduces its table exactly).
func canonicalPrefixCodes(lengths: [UInt8]) -> [UInt32] {
    var order: [Int] = lengths.indices.filter { lengths[$0] > 0 }
    order.sort { lengths[$0] != lengths[$1] ? lengths[$0] < lengths[$1] : $0 < $1 }
    var codes = [UInt32](repeating: 0, count: lengths.count)
    var code: UInt32 = 0
    var prevLen: UInt8 = 0
    for sym in order {
        let len = lengths[sym]
        code <<= (len - prevLen)
        var rev: UInt32 = 0
        var c = code
        for _ in 0..<len {
            rev = (rev << 1) | (c & 1)
            c >>= 1
        }
        codes[sym] = rev
        code += 1
        prevLen = len
    }
    return codes
}

// MARK: - Prefix-code serialization

/// One buildable, writable prefix code over an alphabet: lengths + canonical
/// (bit-reversed) codes + the bitstream description.
struct PrefixCodeSpec {
    let alphabetSize: Int  // trimmed: last used symbol + 1 (min 1)
    let lengths: [UInt8]
    let codes: [UInt32]
    /// Set when exactly one symbol is used: the decoder builds a 0-bit table
    /// (both via `alphabetSize == 1` and via the simple 1-symbol form), so
    /// writeSymbol must emit NOTHING — a phantom 1-bit code here desyncs any
    /// stream where tokens aren't the section's final field.
    let singleSymbol: Int?

    init(histogram: [Int]) {
        var maxUsed = -1
        for (s, c) in histogram.enumerated() where c > 0 { maxUsed = s }
        alphabetSize = max(1, maxUsed + 1)
        var h = Array(histogram.prefix(alphabetSize))
        if maxUsed < 0 { h = [1] }  // degenerate: nothing to code
        let l = limitedHuffmanLengths(histogram: h, maxBits: kPrefixMaxBits)
        lengths = l
        codes = canonicalPrefixCodes(lengths: l)
        let used = l.indices.filter { l[$0] > 0 }
        singleSymbol = used.count == 1 ? used[0] : nil
    }

    var usedSymbols: [Int] { lengths.indices.filter { lengths[$0] > 0 } }

    @inline(__always)
    func writeSymbol(_ w: BitWriter, _ sym: Int) {
        if singleSymbol != nil { return }  // 0-bit code
        w.write(UInt64(codes[sym]), Int(lengths[sym]))
    }

    /// Writes the code description (dual of `PrefixCode.init(reader:alphabetSize:)`).
    /// Callers write the alphabet size themselves (`decodeVarLenUint16` field);
    /// nothing at all is written when `alphabetSize == 1` (0-bit code).
    func writeDescription(_ w: BitWriter) {
        if alphabetSize <= 1 { return }
        let used = usedSymbols
        if used.count <= 4 {
            writeSimple(w, used: used)
        } else {
            writeComplex(w)
        }
    }

    // Simple form: 1-4 explicit symbols. Shapes must mirror readSimpleCode's
    // tables exactly (including the skewed 1/2/3/3 "case 5" variant).
    private func writeSimple(_ w: BitWriter, used: [Int]) {
        w.write(1, 2)  // simple_or_skip = 1
        let maxBits = alphabetSize > 1 ? Int(floorLog2Nonzero(UInt32(alphabetSize - 1))) + 1 : 0
        switch used.count {
        case 1:
            w.write(0, 2)  // num_symbols - 1
            w.write(UInt64(used[0]), maxBits)
        case 2:
            w.write(1, 2)
            for s in used { w.write(UInt64(s), maxBits) }
        case 3:
            // Lengths must be 1/2/2: the 1-bit symbol is written first (the
            // decoder keeps position 0 fixed and sorts only the last two).
            let sorted = used.sorted { lengths[$0] < lengths[$1] }
            w.write(2, 2)
            for s in sorted { w.write(UInt64(s), maxBits) }
        default:
            let skewed = lengths[used[0]] != lengths[used[1]]
                || lengths[used[1]] != lengths[used[2]]
                || lengths[used[2]] != lengths[used[3]]
            w.write(3, 2)
            if skewed {
                // 1/2/3/3: write in length order (decoder sorts only the two
                // 3-bit symbols).
                let sorted = used.sorted {
                    lengths[$0] != lengths[$1] ? lengths[$0] < lengths[$1] : $0 < $1
                }
                for s in sorted { w.write(UInt64(s), maxBits) }
                w.writeBool(true)
            } else {
                for s in used { w.write(UInt64(s), maxBits) }
                w.writeBool(false)
            }
        }
    }

    /// Simple-form codes are position-dependent (readSimpleCode's tables), so
    /// `codes`/`lengths` from the canonical builder must match its layout.
    /// `PrefixEntropyEncoder` guarantees this by construction: for ≤4 symbols
    /// package-merge produces exactly the shapes readSimpleCode builds
    /// (1×0-bit; 1/1; 1/2/2; 2/2/2/2 or 1/2/3/3) and canonical assignment in
    /// (length, symbol) order reproduces the decoder's table filling.

    // Complex form: code-length-code + per-symbol lengths with repeat codes.
    private func writeComplex(_ w: BitWriter) {
        // 1. Turn the length array into the CL-symbol sequence (with 16/17
        //    repeat chains), stopping after the last used symbol.
        var seq: [(sym: Int, extra: UInt32, extraBits: Int)] = []
        let lastUsed = usedSymbols.last!
        var i = 0
        while i <= lastUsed {
            let len = lengths[i]
            var run = 1
            while i + run <= lastUsed && lengths[i + run] == len { run += 1 }
            if len == 0 {
                if run < 3 {
                    for _ in 0..<run { seq.append((0, 0, 0)) }
                } else {
                    appendRepeatChain(&seq, symbol: 17, base: 8, extraBits: 3, total: run)
                }
            } else {
                seq.append((Int(len), 0, 0))
                let remaining = run - 1
                if remaining >= 3 {
                    appendRepeatChain(&seq, symbol: 16, base: 4, extraBits: 2, total: remaining)
                } else {
                    for _ in 0..<remaining { seq.append((Int(len), 0, 0)) }
                }
            }
            i += run
        }

        // 2. Build the code-length code (max length 5, per the static CL
        //    patterns) from the sequence's symbol histogram.
        var clHist = [Int](repeating: 0, count: 18)
        for e in seq { clHist[e.sym] += 1 }
        var clLengths = limitedHuffmanLengths(histogram: clHist, maxBits: 5)
        let clUsedCount = clLengths.filter { $0 > 0 }.count
        if clUsedCount == 1 {
            // numCodes == 1: legal only when the 0-bit CL reads imply the
            // whole length array (the flat power-of-two case). Guaranteed
            // here: a single distinct CL symbol means every emitted symbol is
            // the same literal length L filling the alphabet Kraft-exactly.
            let s = clLengths.firstIndex { $0 > 0 }!
            clLengths[s] = 1
        }
        let clCodes = canonicalPrefixCodes(lengths: clLengths)

        // 3. Serialize: skip=0, CL lengths in wire order (static patterns,
        //    stopping when the CL Kraft space closes), then the sequence.
        w.write(0, 2)  // simple_or_skip = 0
        let order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        // Static patterns (value, bits) per CL length 0...5.
        let pattern: [(UInt64, Int)] = [(0, 2), (7, 4), (3, 3), (2, 2), (1, 2), (15, 4)]
        var space = 32
        var numCodes = 0
        for idx in order {
            let l = Int(clLengths[idx])
            let p = pattern[l]
            w.write(p.0, p.1)
            if l != 0 {
                space -= 32 >> l
                numCodes += 1
            }
            if space <= 0 { break }  // decoder stops reading here
        }
        if clUsedCount > 1 {
            assert(space == 0, "code-length code must be Kraft-exact")
        }
        _ = numCodes
        if clUsedCount == 1 { return }  // 0-bit CL code: lengths are implied

        for e in seq {
            w.write(UInt64(clCodes[e.sym]), Int(clLengths[e.sym]))
            if e.extraBits > 0 { w.write(UInt64(e.extra), e.extraBits) }
        }
    }

    /// Emits a 16/17 repeat chain totalling `total` (≥ 3) repeats: the decoder
    /// accumulates consecutive same-symbol repeats as
    /// `count = (count - 2) * base + extra + 3`, so `total - 2` is written as
    /// bijective base-`base` digits (each digit d in 1...base → extra d-1).
    private func appendRepeatChain(
        _ seq: inout [(sym: Int, extra: UInt32, extraBits: Int)],
        symbol: Int, base: Int, extraBits: Int, total: Int
    ) {
        var digits: [Int] = []
        var m = total - 2
        while m > 0 {
            var d = m % base
            if d == 0 {
                d = base
                m = m / base - 1
            } else {
                m /= base
            }
            digits.append(d)
        }
        for d in digits.reversed() {
            seq.append((symbol, UInt32(d - 1), extraBits))
        }
    }
}

// MARK: - Full entropy-header + token writing

/// The (context, value) unit the encoder buffers before entropy writing.
struct EncToken {
    var ctx: UInt32
    var value: UInt32
}

let encUintConfig = HybridUintConfig(splitExponent: 4, msbInToken: 2, lsbInToken: 0)

// Free functions rather than locals inside ClusteredHistograms.init: the
// Swift 6.4 beta optimizer (LoopInvariantCodeMotion) crashes at -O on the
// nested-closure form of that init.
private func clusterEntropyBits(_ h: [Int]) -> Double {
    let total = h.reduce(0, +)
    if total == 0 { return 0 }
    var bits = 0.0
    for c in h where c > 0 {
        bits += Double(c) * -log2(Double(c) / Double(total))
    }
    return bits
}

private func clusterMerged(_ a: [Int], _ b: [Int]) -> [Int] {
    var m = a.count >= b.count ? a : b
    let s = a.count >= b.count ? b : a
    for i in 0..<s.count { m[i] += s[i] }
    return m
}

/// Hybrid-uint (4,2,0) tokens for any UInt32 stay < 128.
private let kAccumBins = 128

private func accumulatePerContext(numContexts: Int, streams: [[EncToken]]) -> [[Int]] {
    // Flat 128-bin grids accumulated per stream in parallel, then merged in
    // stream order. Counts are integer sums, so any accumulation grouping
    // produces the same totals as the sequential walk; the final arrays are
    // rebuilt with the exact lengths the sequential append-growth produced
    // (max token seen + 1, min 1 — contexts with no tokens stay [0]).
    let gridSize = numContexts * kAccumBins
    let nStreams = streams.count
    var perCtx = [[Int]](repeating: [0], count: numContexts)
    if nStreams == 0 { return perCtx }
    let grids = UnsafeMutablePointer<UInt32>.allocate(capacity: nStreams * gridSize)
    grids.initialize(repeating: 0, count: nStreams * gridSize)
    defer { grids.deallocate() }
    do {
        nonisolated(unsafe) let gridsP = grids
        nonisolated(unsafe) let streamsL = streams
        DispatchQueue.concurrentPerform(iterations: nStreams) { s in
            let g = gridsP + s * gridSize
            let stream = streamsL[s]
            stream.withUnsafeBufferPointer { buf in
                for t in buf {
                    let (token, _, _) = encUintConfig.encode(t.value)
                    g[Int(t.ctx) * kAccumBins + Int(token)] += 1
                }
            }
        }
    }
    // Merge into stream 0's grid (fixed order; integer adds).
    for s in 1..<nStreams {
        let src = grids + s * gridSize
        for i in 0..<gridSize { grids[i] += src[i] }
    }
    for c in 0..<numContexts {
        let g = grids + c * kAccumBins
        var maxTok = -1
        for t in 0..<kAccumBins where g[t] > 0 { maxTok = t }
        if maxTok < 0 { continue }
        var h = [Int](repeating: 0, count: maxTok + 1)
        for t in 0...maxTok { h[t] = Int(g[t]) }
        perCtx[c] = h
    }
    return perCtx
}

/// Merge cost of two clusters given their cached entropies. Identical doubles
/// to the original inline recomputation: same merged contents, same
/// left-associated `(Em − Ei) − Ej` expression.
private func clusterPairCost(_ a: [Int], _ b: [Int], _ ea: Double, _ eb: Double) -> Double {
    clusterEntropyBits(clusterMerged(a, b)) - ea - eb
}

// @_optimize(none): the Swift 6.4 beta optimizer's LoopInvariantCodeMotion
// pass crashes (signal 5) on this function's pairwise merge loop at -O. All
// heavy math lives in the -O free functions above; with the pair costs cached
// the driver's own work is O(clusters² ≤ 48²) double compares per merge —
// optimization is irrelevant here.
//
// The cache is exact, not approximate: cluster entropies and pair costs are
// pure functions of cluster contents, recomputed only when a cluster's
// contents change, so every comparison sees the same doubles the original
// recompute-everything loop saw, in the same (i asc, j asc, strict <) scan
// order — index shifts from `remove(at:)` preserve relative pair order.
@_optimize(none)
private func greedyCluster(
    perCtx: [[Int]], numContexts: Int, maxClusters: Int
) -> (map: [UInt8], clusters: [[Int]]) {
    // Start: one cluster per context (empty contexts merge free — they cost
    // nothing and any mapping is valid).
    var clusters: [[Int]] = perCtx
    var map = (0..<numContexts).map { $0 }
    // The serialized cost of an extra histogram (code description + uint
    // config); crude but only steers when gains are marginal anyway.
    let perHistogramOverhead = 60.0
    var ent = [Double]()
    for c in clusters { ent.append(clusterEntropyBits(c)) }
    var cost = [[Double]]()
    for i in 0..<clusters.count {
        var row = [Double](repeating: 0, count: clusters.count)
        for j in (i + 1)..<clusters.count {
            row[j] = clusterPairCost(clusters[i], clusters[j], ent[i], ent[j])
        }
        cost.append(row)
    }
    while clusters.count > 1 {
        var bestI = -1
        var bestJ = -1
        var bestCost = Double.infinity
        for i in 0..<clusters.count {
            for j in (i + 1)..<clusters.count {
                if cost[i][j] < bestCost {
                    bestCost = cost[i][j]
                    bestI = i
                    bestJ = j
                }
            }
        }
        if clusters.count <= maxClusters && bestCost > perHistogramOverhead { break }
        clusters[bestI] = clusterMerged(clusters[bestI], clusters[bestJ])
        clusters.remove(at: bestJ)
        ent[bestI] = clusterEntropyBits(clusters[bestI])
        ent.remove(at: bestJ)
        cost.remove(at: bestJ)
        for i in 0..<cost.count { cost[i].remove(at: bestJ) }
        for k in 0..<clusters.count where k != bestI {
            let lo = min(k, bestI)
            let hi = max(k, bestI)
            cost[lo][hi] = clusterPairCost(clusters[lo], clusters[hi], ent[lo], ent[hi])
        }
        for c in 0..<numContexts {
            if map[c] == bestJ { map[c] = bestI }
            if map[c] > bestJ { map[c] -= 1 }
        }
    }
    return (map.map { UInt8($0) }, clusters)
}

/// Per-context token histograms clustered down to at most `maxClusters`
/// histograms (the simple context-map form caps bits-per-entry at 3, i.e. 8
/// histograms). Greedy pairwise merging by entropy cost: merge while over the
/// cap, then keep merging while a merge costs less than the ~bits saved by
/// serializing one fewer histogram.
struct ClusteredHistograms {
    let numContexts: Int
    let contextMap: [UInt8]  // context -> cluster, every cluster index used
    let histograms: [[Int]]  // per-cluster token histograms

    init(numContexts: Int, streams: [[EncToken]], maxClusters: Int = 8) {
        self.numContexts = numContexts
        let perCtx = accumulatePerContext(numContexts: numContexts, streams: streams)
        let (map, clusters) = greedyCluster(
            perCtx: perCtx, numContexts: numContexts, maxClusters: maxClusters)
        contextMap = map
        histograms = clusters
    }

    /// Writes the context-map field (dual of `decodeContextMap`, simple form).
    /// Only valid for ≤ 8 histograms (bits_per_entry ≤ 3).
    func writeContextMap(_ w: BitWriter) {
        w.writeBool(true)  // is_simple
        let bits = histograms.count > 1 ? ceilLog2Nonzero(UInt32(histograms.count)) : 0
        w.write(UInt64(bits), 2)
        if bits > 0 {
            for entry in contextMap { w.write(UInt64(entry), bits) }
        }
    }
}

/// Prefix-code entropy encoder for one entropy header: clustered per-context
/// histograms, the header dual of `decodeHistograms` (prefix path), and token
/// stream writing.
struct PrefixEntropyEncoder {
    let clustered: ClusteredHistograms
    let specs: [PrefixCodeSpec]

    /// `streams` are every token run that will be coded under this header.
    init(numContexts: Int, streams: [[EncToken]]) {
        clustered = ClusteredHistograms(numContexts: numContexts, streams: streams)
        specs = clustered.histograms.map { PrefixCodeSpec(histogram: $0) }
    }

    /// Writes the entropy header (mirrors `decodeHistograms`).
    func writeHeader(_ w: BitWriter) {
        w.writeBool(false)  // lz77 enabled
        if clustered.numContexts > 1 { clustered.writeContextMap(w) }
        w.writeBool(true)  // use_prefix_code
        for _ in specs {
            // Hybrid-uint config per histogram: split_exponent=4 (4 bits for
            // log_alpha_size 15), msb=2 (3 bits), lsb=0 (2 bits).
            w.write(4, 4)
            w.write(2, 3)
            w.write(0, 2)
        }
        // All alphabet sizes first, then all code descriptions
        // (decodeANSCodes order).
        for spec in specs { writeVarLenUint16(w, spec.alphabetSize - 1) }
        for spec in specs { spec.writeDescription(w) }
    }

    func encodeStream(_ w: BitWriter, _ tokens: [EncToken]) {
        for t in tokens {
            let spec = specs[Int(clustered.contextMap[Int(t.ctx)])]
            let (token, nbits, bits) = encUintConfig.encode(t.value)
            spec.writeSymbol(w, Int(token))
            if nbits > 0 { w.write(UInt64(bits), Int(nbits)) }
        }
    }
}

/// The two entropy back-ends behind one writing interface: headers are
/// written once (LfGlobal), streams once per section.
protocol TokenEntropyEncoder {
    func writeHeader(_ w: BitWriter)
    func encodeStream(_ w: BitWriter, _ tokens: [EncToken])
}

extension PrefixEntropyEncoder: TokenEntropyEncoder {}
extension ANSEntropyEncoder: TokenEntropyEncoder {}

func writeVarLenUint16(_ w: BitWriter, _ v: Int) {
    if v == 0 {
        w.writeBool(false)
        return
    }
    w.writeBool(true)
    let n = 31 - Int(UInt32(v).leadingZeroBitCount)  // floor(log2(v))
    w.write(UInt64(n), 4)
    if n > 0 { w.write(UInt64(v) & ((1 << UInt64(n)) - 1), n) }
}
