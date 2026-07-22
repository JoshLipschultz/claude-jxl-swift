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
/// `ctx` bit 31 (`kEncLZLengthFlag`) marks an LZ77 match-length entry: the
/// value is `copyLength - minLength`, coded in the flagged context's cluster
/// as `minSymbol + lengthConfig.encode(value)`. A match's distance follows as
/// a plain token in the dedicated distance context (the last raw context).
struct EncToken {
    var ctx: UInt32
    var value: UInt32
}

let kEncLZLengthFlag: UInt32 = 0x8000_0000

let encUintConfig = HybridUintConfig(splitExponent: 4, msbInToken: 2, lsbInToken: 0)

// MARK: - Value statistics + per-cluster hybrid-uint config selection

/// Compact per-context value statistics from which the token histogram of ANY
/// candidate hybrid-uint config (split_exponent ≤ 6, msb ≤ 2, lsb ≤ 1) can be
/// derived EXACTLY: values < 64 are binned by value; larger values by
/// (floor(log2), top-2-bits-after-leader, bottom bit) — precisely the fields
/// those configs consume. 64 exact bins + 26 n-values × 4 msb × 2 lsb = 272.
let kStatExact = 64
let kStatBins = kStatExact + 26 * 8

@inline(__always)
func statBin(_ v: UInt32) -> Int {
    if v < UInt32(kStatExact) { return Int(v) }
    let n = floorLog2Nonzero(v)
    let msb2 = Int((v >> UInt32(n - 2)) & 3)
    return kStatExact + (n - 6) * 8 + msb2 * 2 + Int(v & 1)
}

/// The config search space: split 0..6 × msb 0..2 × lsb 0..1 under the spec's
/// validity constraints (msb ≤ split, msb + lsb ≤ split). (4,2,0) — the
/// long-standing default — is evaluated first so it wins all cost ties.
let kUintConfigCandidates: [HybridUintConfig] = {
    var out: [HybridUintConfig] = [encUintConfig]
    for e in 0...6 {
        for m in 0...min(2, e) {
            for l in 0...min(1, e - m) {
                let cfg = HybridUintConfig(
                    splitExponent: UInt32(e), msbInToken: UInt32(m), lsbInToken: UInt32(l))
                if cfg != encUintConfig { out.append(cfg) }
            }
        }
    }
    return out
}()

/// Exact token histogram + total raw extra bits of the values summarized by
/// `stat`, under `cfg`. Returns nil when any token would reach `tokenLimit`
/// (ANS alphabets cap at 256; LZ77 reserves tokens ≥ min_symbol).
func deriveTokenStats(
    _ stat: [Int], cfg: HybridUintConfig, tokenLimit: Int
) -> (hist: [Int], extraBits: Double)? {
    var hist = [Int](repeating: 0, count: 1)
    var extra = 0.0
    let e = Int(cfg.splitExponent)
    let m = Int(cfg.msbInToken)
    let l = Int(cfg.lsbInToken)
    for (bin, c) in stat.enumerated() where c > 0 {
        let token: Int
        let nbits: Int
        if bin < kStatExact {
            let (t, nb, _) = cfg.encode(UInt32(bin))
            token = Int(t)
            nbits = Int(nb)
        } else {
            let rel = bin - kStatExact
            let n = 6 + rel >> 3
            let msb2 = (rel >> 1) & 3
            token =
                Int(cfg.splitToken) + ((n - e) << (m + l)) + ((msb2 >> (2 - m)) << l)
                + (l > 0 ? rel & 1 : 0)
            nbits = n - m - l
        }
        if token >= tokenLimit { return nil }
        if token >= hist.count {
            hist.append(contentsOf: repeatElement(0, count: token + 1 - hist.count))
        }
        hist[token] += c
        extra += Double(c) * Double(nbits)
    }
    return (hist, extra)
}

/// Serialized cost (in bits) of one cluster coded with ANS: exact header
/// simulation + cross-entropy against the normalized distribution + raw bits.
func ansClusterCost(hist: [Int], extraBits: Double) -> Double {
    var h = hist
    while h.count > 1, h.last == 0 { h.removeLast() }
    if h.reduce(0, +) == 0 { return 0 }
    let norm = normalizeANSCounts(h)
    let w = BitWriter()
    writeANSHistogram(w, counts: norm)
    var bits = Double(w.bitPosition)
    for (s, c) in h.enumerated() where c > 0 {
        bits += Double(c) * (Double(ansLogTabSize) - log2(Double(norm[s])))
    }
    return bits + extraBits
}

/// Serialized cost (in bits) of one cluster coded with a prefix code: exact
/// description simulation + code lengths + raw bits.
func prefixClusterCost(hist: [Int], extraBits: Double) -> Double {
    if hist.reduce(0, +) == 0 { return 0 }
    let spec = PrefixCodeSpec(histogram: hist)
    let w = BitWriter()
    writeVarLenUint16(w, spec.alphabetSize - 1)
    spec.writeDescription(w)
    var bits = Double(w.bitPosition)
    if spec.singleSymbol == nil {
        for (s, c) in hist.enumerated() where c > 0 {
            bits += Double(c) * Double(spec.lengths[s])
        }
    }
    return bits + extraBits
}

/// Per-cluster config search: for each cluster's stat histogram, pick the
/// candidate config minimizing the backend's exact serialized cost, and
/// return the winning configs plus the clusters' token histograms under them.
/// `lengthHists` (LZ77) adds each cluster's fixed length-token histogram
/// (tokens ≥ min_symbol) on top of the config-dependent literal tokens.
func chooseClusterConfigs(
    stats: [[Int]], tokenLimit: Int, lengthHists: [[Int]]? = nil,
    cost: (_ hist: [Int], _ extraBits: Double) -> Double
) -> (configs: [HybridUintConfig], hists: [[Int]]) {
    var configs: [HybridUintConfig] = []
    var hists: [[Int]] = []
    for (ci, stat) in stats.enumerated() {
        func withLengths(_ h: [Int]) -> [Int] {
            guard let lh = lengthHists?[ci], !lh.isEmpty else { return h }
            var out = h
            if out.count < lh.count {
                out.append(contentsOf: repeatElement(0, count: lh.count - out.count))
            }
            for (t, c) in lh.enumerated() where c > 0 { out[t] += c }
            return out
        }
        var bestCfg = encUintConfig
        var bestHist: [Int] = withLengths([0])
        var bestCost = Double.infinity
        for cfg in kUintConfigCandidates {
            guard let d = deriveTokenStats(stat, cfg: cfg, tokenLimit: tokenLimit) else {
                continue
            }
            let h = withLengths(d.hist)
            let c = cost(h, d.extraBits)
            if c < bestCost {
                bestCost = c
                bestCfg = cfg
                bestHist = h
            }
        }
        configs.append(bestCfg)
        hists.append(bestHist)
    }
    return (configs, hists)
}

/// Writes one hybrid-uint config description (dual of `readHybridUintConfig`;
/// field widths depend on `logAlphaSize`, and msb/lsb are implied 0 when the
/// split exponent equals it).
func writeUintConfig(_ w: BitWriter, _ cfg: HybridUintConfig, logAlphaSize: Int) {
    w.write(UInt64(cfg.splitExponent), ceilLog2Nonzero(UInt32(logAlphaSize + 1)))
    if Int(cfg.splitExponent) != logAlphaSize {
        w.write(UInt64(cfg.msbInToken), ceilLog2Nonzero(cfg.splitExponent + 1))
        w.write(
            UInt64(cfg.lsbInToken),
            ceilLog2Nonzero(cfg.splitExponent - cfg.msbInToken + 1))
    }
}

// MARK: - LZ77 emission

/// Encoder-side LZ77 parameters (mirrors the decoder's `LZ77Params`): tokens
/// ≥ `minSymbol` in any literal context are match lengths, coded as
/// `minSymbol + lengthConfig.encode(copyLength - minLength)`; the distance
/// follows in the dedicated extra context (raw context numContexts - 1).
/// min_symbol = 224 keeps the length tokens inside the 256-token ANS alphabet
/// cap while leaving the full literal token range below them.
struct EncLZ77 {
    var minSymbol = 224
    var minLength = 3
    var lengthConfig: HybridUintConfig
}

/// Maximum length-token count with min_symbol 224 under the 256-entry ANS
/// alphabet: length tokens must stay < 32.
let kEncLZMaxLengthTokens = 32

/// Repetitiveness gate: runs the REAL matcher (with its cost model) over a
/// few contiguous sample blocks and asks what fraction of the sampled tokens
/// profitable matches would cover. Photographic residual streams score ~0 —
/// runs of small tokens repeat, but the cost model rejects them because the
/// entropy coder prices them below the match cost — while graphics content
/// (glyph rows, palette indexes, stripes) scores high. The full matcher +
/// double encode only run past this gate.
func lz77WorthTrying(streams: [[EncToken]], numContexts: Int) -> Bool {
    var total = 0
    for s in streams { total += s.count }
    if total < 64 { return false }
    let blockSize = 8192
    if total <= 4 * blockSize {
        // Small images: just run the matcher for real.
        return true
    }
    // Up to 12 blocks spread across the sections, biased like the sections
    // themselves (larger streams contribute more blocks).
    var sampled: [[EncToken]] = []
    var sampledTokens = 0
    for s in streams {
        let n = s.count
        guard n >= blockSize else { continue }
        let blocks = max(1, min(4, n / (total / 12 + 1)))
        for b in 0..<blocks {
            let start = (n - blockSize) * b / blocks
            sampled.append(Array(s[start..<(start + blockSize)]))
            sampledTokens += blockSize
            if sampledTokens >= 12 * blockSize { break }
        }
        if sampledTokens >= 12 * blockSize { break }
    }
    if sampled.isEmpty { return false }
    let avg = lz77AvgBitsPerContext(numContexts: numContexts, streams: sampled)
    var matched = 0
    for block in sampled {
        matched += lz77MatchStream(
            block, distanceMultiplier: 1, avgBits: avg, minLength: 3,
            distCtx: UInt32(numContexts)
        ).matchedTokens
    }
    return Double(matched) / Double(sampledTokens) > 0.08
}

/// Estimated bits per literal token per raw context ((4,2,0) token entropy +
/// raw extra bits, averaged) — the matcher's model of what a replaced literal
/// would have cost.
func lz77AvgBitsPerContext(numContexts: Int, streams: [[EncToken]]) -> [Double] {
    var hists = [[Int]](repeating: [Int](repeating: 0, count: 128), count: numContexts)
    var extras = [Double](repeating: 0, count: numContexts)
    var counts = [Int](repeating: 0, count: numContexts)
    for s in streams {
        for t in s {
            let c = Int(t.ctx)
            let (token, nbits, _) = encUintConfig.encode(t.value)
            hists[c][Int(token)] += 1
            extras[c] += Double(nbits)
            counts[c] += 1
        }
    }
    var avg = [Double](repeating: 8, count: numContexts)
    for c in 0..<numContexts where counts[c] > 0 {
        var bits = 0.0
        let total = Double(counts[c])
        for cnt in hists[c] where cnt > 0 {
            bits += Double(cnt) * -log2(Double(cnt) / total)
        }
        avg[c] = (bits + extras[c]) / total
    }
    return avg
}

/// Greedy LZ77 match finder over one section's token-value stream (the
/// decoder's window is per-section). Hash chains over 4-grams; matches are
/// emitted when the estimated literal bits they replace exceed the estimated
/// match cost. Returns the rewritten stream (length entries flagged with
/// `kEncLZLengthFlag`, each followed by its distance entry in `distCtx`),
/// the emitted length VALUES (copyLength - minLength; for the shared length
/// config choice), and how many literal tokens were replaced.
func lz77MatchStream(
    _ stream: [EncToken], distanceMultiplier: Int, avgBits: [Double],
    minLength: Int, distCtx: UInt32
) -> (out: [EncToken], lengthValues: [UInt32], matchedTokens: Int) {
    let n = stream.count
    guard n >= 8, distanceMultiplier > 0 else { return (stream, [], 0) }

    // Reverse special-distance map for this section's multiplier: decoded
    // distance -> smallest special index (decoded values < 120 hit the
    // special table; the general form is distance + 119).
    var special = [Int: Int]()
    for i in 0..<kNumSpecialDistances {
        let d = specialDistance(index: i, multiplier: distanceMultiplier)
        if special[d] == nil { special[d] = i }
    }

    let hashBits = 16
    let hashSize = 1 << hashBits
    var head = [Int32](repeating: -1, count: hashSize)
    var prev = [Int32](repeating: -1, count: n)
    let maxChain = 32
    let goodEnough = 512
    let window = 1 << 20

    var out: [EncToken] = []
    out.reserveCapacity(n)
    var lengthValues: [UInt32] = []
    var matched = 0

    stream.withUnsafeBufferPointer { buf in
        @inline(__always) func hash(_ i: Int) -> Int {
            let key =
                (UInt64(buf[i].value) | (UInt64(buf[i + 1].value) << 32))
                &* 0x9E37_79B9_7F4A_7C15
                ^ (UInt64(buf[i + 2].value) | (UInt64(buf[i + 3].value) << 32))
                &* 0xC2B2_AE3D_27D4_EB4F
            return Int(key >> UInt64(64 - hashBits))
        }
        @inline(__always) func insert(_ i: Int) {
            guard i + 4 <= n else { return }
            let h = hash(i)
            prev[i] = head[h]
            head[h] = Int32(i)
        }
        // Cost prefix over literal estimates: saved bits of a match covering
        // [i, i+len) = costPrefix[i+len] - costPrefix[i].
        var costPrefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            costPrefix[i + 1] = costPrefix[i] + avgBits[Int(buf[i].ctx)]
        }

        var i = 0
        // Backoff on unmatchable stretches: after 64 consecutive literals the
        // search runs only at every skip-th position (doubling up to 8);
        // skipped positions are still hashed. An accepted match resets it.
        var literalRun = 0
        while i < n {
            var bestLen = 0
            var bestJ = -1
            let searching = literalRun < 64 || (i & ((1 << min(3, (literalRun >> 6))) - 1)) == 0
            if i + 4 <= n, searching {
                // Fast path for runs: a repeat of the previous value extends
                // to the whole run at distance 1 — no chain walk needed, and
                // it is the optimal distance for that shape.
                if i > 0, buf[i].value == buf[i - 1].value {
                    var len = 1
                    while i + len < n, buf[i - 1 + len].value == buf[i + len].value {
                        len += 1
                    }
                    bestLen = len
                    bestJ = i - 1
                }
                if bestLen < goodEnough {
                    var j = Int(head[hash(i)])
                    var chain = 0
                    // Budget on rejected-candidate comparisons: repetitive
                    // content otherwise degenerates to maxChain × runLength
                    // work per position.
                    var budget = 512
                    while j >= 0, chain < maxChain, i - j <= window, budget > 0 {
                        if bestLen >= 128, chain >= 8 { break }
                        // A candidate must beat bestLen: check the extending
                        // position first, then verify the full run.
                        if bestLen == 0
                            || (i + bestLen < n
                                && buf[j + bestLen].value == buf[i + bestLen].value)
                        {
                            var len = 0
                            while i + len < n, buf[j + len].value == buf[i + len].value {
                                len += 1
                            }
                            budget -= len
                            if len > bestLen {
                                bestLen = len
                                bestJ = j
                                if len >= goodEnough { break }
                            }
                        }
                        j = Int(prev[j])
                        chain += 1
                    }
                }
            }
            var accepted = false
            if bestLen >= max(minLength, 4), bestJ >= 0 {
                let dist = i - bestJ
                let distValue = special[dist] ?? dist + kNumSpecialDistances - 1
                let lenValue = bestLen - minLength
                let saved = costPrefix[i + bestLen] - costPrefix[i]
                // Estimated match cost: ~7-bit length token + its raw bits,
                // ~7-bit distance token + its raw bits, + margin against
                // marginal matches fragmenting the literal histograms.
                let (_, lnb, _) = HybridUintConfig(
                    splitExponent: 0, msbInToken: 0, lsbInToken: 0
                ).encode(UInt32(lenValue))
                let (_, dnb, _) = encUintConfig.encode(UInt32(distValue))
                let cost = 14.0 + Double(lnb) + Double(dnb) + 8.0
                if saved > cost {
                    out.append(
                        EncToken(
                            ctx: buf[i].ctx | kEncLZLengthFlag, value: UInt32(lenValue)))
                    out.append(EncToken(ctx: distCtx, value: UInt32(distValue)))
                    lengthValues.append(UInt32(lenValue))
                    matched += bestLen
                    let end = min(i + bestLen, n - 4)
                    var k = i
                    while k < end {
                        insert(k)
                        k += 1
                    }
                    i += bestLen
                    accepted = true
                    literalRun = 0
                }
            }
            if !accepted {
                insert(i)
                out.append(buf[i])
                i += 1
                literalRun += 1
            }
        }
    }
    return (out, lengthValues, matched)
}

/// Chooses the shared LZ77 length config from every emitted length value:
/// smallest estimated coded size among the candidates whose tokens stay below
/// the 32-token budget (min_symbol 224 + 32 = the 256-entry alphabet cap).
func chooseLengthConfig(_ lengthValues: [UInt32]) -> HybridUintConfig {
    var stat = [Int](repeating: 0, count: kStatBins)
    for v in lengthValues { stat[statBin(v)] += 1 }
    var best = HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0)
    var bestCost = Double.infinity
    for cfg in kUintConfigCandidates {
        guard let d = deriveTokenStats(stat, cfg: cfg, tokenLimit: kEncLZMaxLengthTokens)
        else { continue }
        let c = ansClusterCost(hist: d.hist, extraBits: d.extraBits)
        if c < bestCost {
            bestCost = c
            best = cfg
        }
    }
    return best
}

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

/// Per-context accumulation now bins VALUES into the 272-bin stat grid (from
/// which any candidate config's token histogram derives exactly); the (4,2,0)
/// token histograms the clusterer consumes are derived from the same grid —
/// identical counts to the old direct token accumulation. With LZ77, each
/// context also accumulates its match-length TOKENS (fixed length config, so
/// they are config-independent) in 32 extra bins; they join the clustering
/// histograms at their absolute wire positions (min_symbol + token).
private func accumulatePerContext(
    numContexts: Int, streams: [[EncToken]], lz77: EncLZ77?
) -> (tokens: [[Int]], stats: [[Int]], lengths: [[Int]]) {
    // Flat stat grids accumulated per stream in parallel, then merged in
    // stream order. Counts are integer sums, so any accumulation grouping
    // produces the same totals as the sequential walk; the token arrays are
    // rebuilt with the exact lengths the sequential append-growth produced
    // (max token seen + 1, min 1 — contexts with no tokens stay [0]).
    let ctxBins = kStatBins + kEncLZMaxLengthTokens
    let gridSize = numContexts * ctxBins
    let nStreams = streams.count
    var perCtx = [[Int]](repeating: [0], count: numContexts)
    var statCtx = [[Int]](repeating: [Int](repeating: 0, count: kStatBins), count: numContexts)
    var lenCtx = [[Int]](repeating: [], count: numContexts)
    if nStreams == 0 { return (perCtx, statCtx, lenCtx) }
    let grids = UnsafeMutablePointer<UInt32>.allocate(capacity: nStreams * gridSize)
    grids.initialize(repeating: 0, count: nStreams * gridSize)
    defer { grids.deallocate() }
    do {
        nonisolated(unsafe) let gridsP = grids
        nonisolated(unsafe) let streamsL = streams
        nonisolated(unsafe) let lzL = lz77
        DispatchQueue.concurrentPerform(iterations: nStreams) { s in
            let g = gridsP + s * gridSize
            let stream = streamsL[s]
            stream.withUnsafeBufferPointer { buf in
                for t in buf {
                    if t.ctx & kEncLZLengthFlag != 0 {
                        let c = Int(t.ctx & ~kEncLZLengthFlag)
                        let (token, _, _) = lzL!.lengthConfig.encode(t.value)
                        g[c * ctxBins + kStatBins + Int(token)] += 1
                    } else {
                        g[Int(t.ctx) * ctxBins + statBin(t.value)] += 1
                    }
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
        let g = grids + c * ctxBins
        for b in 0..<kStatBins { statCtx[c][b] = Int(g[b]) }
        var hist: [Int] = [0]
        if let d = deriveTokenStats(statCtx[c], cfg: encUintConfig, tokenLimit: 1 << 15),
            d.hist.count > 1 || d.hist[0] > 0
        {
            hist = d.hist
        }
        if let lz = lz77 {
            var maxTok = -1
            for t in 0..<kEncLZMaxLengthTokens where g[kStatBins + t] > 0 { maxTok = t }
            if maxTok >= 0 {
                var lh = [Int](repeating: 0, count: lz.minSymbol + maxTok + 1)
                for t in 0...maxTok { lh[lz.minSymbol + t] = Int(g[kStatBins + t]) }
                lenCtx[c] = lh
                // Clustering sees length tokens at their wire positions.
                if hist.count < lh.count {
                    hist.append(contentsOf: repeatElement(0, count: lh.count - hist.count))
                }
                for t in 0...maxTok { hist[lz.minSymbol + t] += Int(g[kStatBins + t]) }
            }
        }
        perCtx[c] = hist
    }
    return (perCtx, statCtx, lenCtx)
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
    let histograms: [[Int]]  // per-cluster (4,2,0) token histograms
    let stats: [[Int]]  // per-cluster value stat histograms (kStatBins each)
    let lengthHists: [[Int]]  // per-cluster LZ77 length-token hists (wire-indexed)

    init(numContexts: Int, streams: [[EncToken]], maxClusters: Int = 8, lz77: EncLZ77? = nil) {
        self.numContexts = numContexts
        let (perCtx, statCtx, lenCtx) = accumulatePerContext(
            numContexts: numContexts, streams: streams, lz77: lz77)
        // Big streams may exceed the simple context map's 8-histogram cap
        // (the complex form takes over): the ~60-bit merge overhead model is
        // honest only when per-histogram header costs are noise relative to
        // the payload, so the raised cap is gated on stream volume.
        var total = 0
        for s in streams { total += s.count }
        let cap = total >= 1_000_000 ? max(maxClusters, 16) : maxClusters
        let (map, clusters) = greedyCluster(
            perCtx: perCtx, numContexts: numContexts, maxClusters: cap)
        contextMap = map
        histograms = clusters
        var merged = [[Int]](
            repeating: [Int](repeating: 0, count: kStatBins), count: clusters.count)
        var mergedLen = [[Int]](repeating: [], count: clusters.count)
        for c in 0..<numContexts {
            let cl = Int(map[c])
            for b in 0..<kStatBins { merged[cl][b] += statCtx[c][b] }
            let lh = lenCtx[c]
            if !lh.isEmpty {
                if mergedLen[cl].count < lh.count {
                    mergedLen[cl].append(
                        contentsOf: repeatElement(0, count: lh.count - mergedLen[cl].count))
                }
                for (t, cnt) in lh.enumerated() where cnt > 0 { mergedLen[cl][t] += cnt }
            }
        }
        stats = merged
        lengthHists = mergedLen
    }

    /// Writes the context-map field (dual of `decodeContextMap`). Up to 8
    /// histograms use the simple 3-bit-per-entry form; more use the complex
    /// form — an inverse-MTF'd, entropy-coded map (nested single-context
    /// prefix header, LZ77 off), with the cheaper of raw vs MTF chosen by
    /// actual serialized size.
    func writeContextMap(_ w: BitWriter) {
        if histograms.count <= 8 {
            w.writeBool(true)  // is_simple
            let bits = histograms.count > 1 ? ceilLog2Nonzero(UInt32(histograms.count)) : 0
            w.write(UInt64(bits), 2)
            if bits > 0 {
                for entry in contextMap { w.write(UInt64(entry), bits) }
            }
            return
        }
        // Forward MTF (dual of inverseMoveToFront): each entry becomes its
        // current rank; decoded ranks reproduce the original values.
        var mtf = (0..<256).map { UInt8($0) }
        var mtfd = [UInt8](repeating: 0, count: contextMap.count)
        for (i, v) in contextMap.enumerated() {
            let idx = mtf.firstIndex(of: v)!
            mtfd[i] = UInt8(idx)
            mtf.remove(at: idx)
            mtf.insert(v, at: 0)
        }
        func serialize(_ entries: [UInt8], useMTF: Bool, into s: BitWriter) {
            s.writeBool(false)  // not simple
            s.writeBool(useMTF)
            let tokens = entries.map { EncToken(ctx: 0, value: UInt32($0)) }
            let enc = PrefixEntropyEncoder(numContexts: 1, streams: [tokens])
            enc.writeHeader(s)
            enc.encodeStream(s, tokens)
        }
        let rawTrial = BitWriter()
        serialize(contextMap, useMTF: false, into: rawTrial)
        let mtfTrial = BitWriter()
        serialize(mtfd, useMTF: true, into: mtfTrial)
        if mtfTrial.bitPosition < rawTrial.bitPosition {
            serialize(mtfd, useMTF: true, into: w)
        } else {
            serialize(contextMap, useMTF: false, into: w)
        }
    }
}

/// Prefix-code entropy encoder for one entropy header: clustered per-context
/// histograms, the header dual of `decodeHistograms` (prefix path), and token
/// stream writing.
struct PrefixEntropyEncoder {
    let clustered: ClusteredHistograms
    let specs: [PrefixCodeSpec]
    let configs: [HybridUintConfig]
    let lz77: EncLZ77?

    /// `streams` are every token run that will be coded under this header.
    /// With `lz77`, `numContexts` INCLUDES the trailing distance context.
    init(numContexts: Int, streams: [[EncToken]], lz77: EncLZ77? = nil) {
        self.lz77 = lz77
        clustered = ClusteredHistograms(
            numContexts: numContexts, streams: streams, lz77: lz77)
        // With LZ77, literal tokens must stay below min_symbol in every
        // cluster (a bigger literal token would decode as a match length).
        let chosen = chooseClusterConfigs(
            stats: clustered.stats,
            tokenLimit: lz77.map { $0.minSymbol } ?? (1 << kPrefixMaxBits),
            lengthHists: clustered.lengthHists,
            cost: prefixClusterCost)
        configs = chosen.configs
        specs = chosen.hists.map { PrefixCodeSpec(histogram: $0) }
    }

    /// Writes the entropy header (mirrors `decodeHistograms`).
    func writeHeader(_ w: BitWriter) {
        writeLZ77Params(w, lz77)
        if clustered.numContexts > 1 { clustered.writeContextMap(w) }
        w.writeBool(true)  // use_prefix_code
        for cfg in configs {
            // Per-cluster hybrid-uint config (log_alpha_size 15 field widths).
            writeUintConfig(w, cfg, logAlphaSize: kPrefixMaxBits)
        }
        // All alphabet sizes first, then all code descriptions
        // (decodeANSCodes order).
        for spec in specs { writeVarLenUint16(w, spec.alphabetSize - 1) }
        for spec in specs { spec.writeDescription(w) }
    }

    func encodeStream(_ w: BitWriter, _ tokens: [EncToken]) {
        for t in tokens {
            let cluster = Int(clustered.contextMap[Int(t.ctx & ~kEncLZLengthFlag)])
            let spec = specs[cluster]
            let token: UInt32
            let nbits: UInt32
            let bits: UInt32
            if t.ctx & kEncLZLengthFlag != 0 {
                let e = lz77!.lengthConfig.encode(t.value)
                token = e.token + UInt32(lz77!.minSymbol)
                nbits = e.nbits
                bits = e.bits
            } else {
                (token, nbits, bits) = configs[cluster].encode(t.value)
            }
            spec.writeSymbol(w, Int(token))
            if nbits > 0 { w.write(UInt64(bits), Int(nbits)) }
        }
    }
}

/// Writes the LZ77Params bundle (dual of the `decodeHistograms` prologue).
func writeLZ77Params(_ w: BitWriter, _ lz77: EncLZ77?) {
    guard let lz = lz77 else {
        w.writeBool(false)  // lz77 enabled
        return
    }
    w.writeBool(true)
    precondition(lz.minSymbol == 224 && (lz.minLength == 3 || lz.minLength == 4))
    w.writeU32(
        UInt32(lz.minSymbol), .value(224), .value(512), .value(4096),
        .bits(15, offset: 8))
    w.writeU32(
        UInt32(lz.minLength), .value(3), .value(4), .bits(2, offset: 5),
        .bits(8, offset: 9))
    writeUintConfig(w, lz.lengthConfig, logAlphaSize: 8)
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
