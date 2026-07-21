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

    init(histogram: [Int]) {
        var maxUsed = -1
        for (s, c) in histogram.enumerated() where c > 0 { maxUsed = s }
        alphabetSize = max(1, maxUsed + 1)
        var h = Array(histogram.prefix(alphabetSize))
        if maxUsed < 0 { h = [1] }  // degenerate: nothing to code
        lengths = limitedHuffmanLengths(histogram: h, maxBits: kPrefixMaxBits)
        codes = canonicalPrefixCodes(lengths: lengths)
    }

    var usedSymbols: [Int] { lengths.indices.filter { lengths[$0] > 0 } }

    @inline(__always)
    func writeSymbol(_ w: BitWriter, _ sym: Int) {
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

/// Prefix-code entropy encoder for one entropy header: builds a single shared
/// histogram over every stream's tokens (all contexts map to cluster 0 — the
/// clustering knob comes with E2), writes the header, then writes token
/// streams. Dual of `decodeHistograms` + `ANSSymbolReader` on the prefix path.
struct PrefixEntropyEncoder {
    static let uintConfig = HybridUintConfig(splitExponent: 4, msbInToken: 2, lsbInToken: 0)

    let numContexts: Int
    let spec: PrefixCodeSpec

    /// `streams` are every token run that will be coded under this header
    /// (their concatenation feeds the shared histogram).
    init(numContexts: Int, streams: [[EncToken]]) {
        self.numContexts = numContexts
        var histogram = [Int](repeating: 0, count: 1)
        for stream in streams {
            for t in stream {
                let (token, _, _) = Self.uintConfig.encode(t.value)
                if Int(token) >= histogram.count {
                    histogram.append(contentsOf: repeatElement(0, count: Int(token) + 1 - histogram.count))
                }
                histogram[Int(token)] += 1
            }
        }
        spec = PrefixCodeSpec(histogram: histogram)
    }

    /// Writes the entropy header (mirrors `decodeHistograms`).
    func writeHeader(_ w: BitWriter) {
        w.writeBool(false)  // lz77 enabled
        if numContexts > 1 {
            w.writeBool(true)  // context map: is_simple
            w.write(0, 2)  // 0 bits/entry: every context -> histogram 0
        }
        w.writeBool(true)  // use_prefix_code
        // Hybrid-uint config: split_exponent=4 (4 bits for log_alpha_size 15),
        // msb=2 (3 bits), lsb=0 (2 bits).
        w.write(4, 4)
        w.write(2, 3)
        w.write(0, 2)
        writeVarLenUint16(w, spec.alphabetSize - 1)
        spec.writeDescription(w)
    }

    @inline(__always)
    func writeValue(_ w: BitWriter, _ value: UInt32) {
        let (token, nbits, bits) = Self.uintConfig.encode(value)
        spec.writeSymbol(w, Int(token))
        if nbits > 0 { w.write(UInt64(bits), Int(nbits)) }
    }

    func encodeStream(_ w: BitWriter, _ tokens: [EncToken]) {
        for t in tokens { writeValue(w, t.value) }
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
