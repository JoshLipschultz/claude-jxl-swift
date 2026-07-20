// ModularEncoder.swift
//
// E1 of docs/encoder-design.md: the minimum honest lossless encoder — a
// single-group (coalesced) native-space Modular frame with a single-leaf
// gradient MA tree and *flat* prefix codes (power-of-two alphabet, all code
// lengths equal). Every stream this file writes is read back by the decoder's
// own parsers; validity against the spec is proven by djxl round-trips
// in-suite. Compression comes purely from prediction at this stage — real
// entropy coding is the next milestone, and sizes are recorded honestly.
//
// The load-bearing rule (see the design doc): prediction uses the *decoder's*
// `predictOne` with the decoder's exact border semantics, so encode/decode
// prediction divergence is structurally impossible.

import Foundation

public struct JXLEncodeError: Error, CustomStringConvertible, Sendable {
    public let reason: String
    public var description: String { reason }
}

// MARK: - Flat prefix-code entropy writer

/// Writes entropy-coded symbol streams the decoder's `decodeHistograms` +
/// prefix path accepts, using one shared *flat* histogram: alphabet padded to
/// 2^k, every symbol coded in exactly k bits. The flat shape needs no
/// code-length data at all: the code-length code declares a single symbol k
/// (`numCodes == 1`), whose 0-bit reads fill every length, and Kraft sums
/// exactly. Hybrid-uint config is the default (4, 2, 0).
struct FlatPrefixWriter {
    static let config = HybridUintConfig(splitExponent: 4, msbInToken: 2, lsbInToken: 0)

    let k: Int  // log2(alphabet size), >= 1

    /// The k for the smallest power-of-two alphabet covering `maxToken`.
    init(maxToken: UInt32) {
        var kk = 1
        while (1 << kk) <= Int(maxToken) { kk += 1 }
        k = kk
    }

    /// Writes the full entropy header for `numContexts` contexts, all mapped
    /// to this single flat histogram (mirrors `decodeHistograms`).
    func writeHeader(_ w: BitWriter, numContexts: Int) {
        w.writeBool(false)  // lz77 enabled
        if numContexts > 1 {
            // Simple context map, 0 bits/entry: every context -> histogram 0.
            w.writeBool(true)  // is_simple
            w.write(0, 2)  // bits per entry
        }
        w.writeBool(true)  // use_prefix_code
        // Hybrid-uint config (log_alpha_size = 15 for prefix codes):
        // split_exponent=4 in ceil_log2(16)=4 bits, msb=2 in ceil_log2(5)=3,
        // lsb=0 in ceil_log2(3)=2.
        w.write(4, 4)
        w.write(2, 3)
        w.write(0, 2)
        // Alphabet size (VarLenUint16 of size-1), then the prefix code.
        writeVarLenUint16(w, (1 << k) - 1)
        writeFlatPrefixCode(w)
    }

    /// The complex-form prefix code declaring a flat 2^k alphabet.
    private func writeFlatPrefixCode(_ w: BitWriter) {
        w.write(0, 2)  // simple_or_skip = 0 (complex, start at order index 0)
        // Code-length-code lengths in kCodeLengthCodeOrder =
        // [1,2,3,4,0,5,17,6,16,7,8,9,10,11,12,13,14,15]: only symbol k gets
        // length 1; everything else 0. Static CL patterns (LSB-first):
        // len 0 -> (0,2), 1 -> (7,4), 2 -> (3,3), 3 -> (2,2), 4 -> (1,2),
        // 5 -> (15,4).
        let order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        for idx in order {
            if idx == k {
                w.write(7, 4)  // length 1
            } else {
                w.write(0, 2)  // length 0
            }
        }
        // Per-symbol lengths: the single-symbol CL code reads 0 bits per
        // symbol, so nothing is written — all 2^k symbols get length k and
        // Kraft closes exactly.
    }

    /// Writes one hybrid-uint value: flat-code symbol (bit-reversed k bits)
    /// plus the config's extra bits.
    @inline(__always)
    func writeValue(_ w: BitWriter, _ value: UInt32) {
        let (token, nbits, bits) = Self.config.encode(value)
        // Canonical flat code: symbol s reads as the k bits of s in MSB-first
        // canonical order; the LSB-first stream stores the bit-reversed key.
        var rev: UInt64 = 0
        var s = UInt64(token)
        for _ in 0..<k {
            rev = (rev << 1) | (s & 1)
            s >>= 1
        }
        w.write(rev, k)
        if nbits > 0 { w.write(UInt64(bits), Int(nbits)) }
    }

    /// Max token for `value` under the shared config (for alphabet sizing).
    static func token(for value: UInt32) -> UInt32 {
        config.encode(value).token
    }
}

private func writeVarLenUint16(_ w: BitWriter, _ v: Int) {
    if v == 0 {
        w.writeBool(false)
        return
    }
    w.writeBool(true)
    let n = 31 - Int(UInt32(v).leadingZeroBitCount)  // floor(log2(v))
    w.write(UInt64(n), 4)
    if n > 0 { w.write(UInt64(v) & ((1 << UInt64(n)) - 1), n) }
}

@inline(__always)
private func packSigned(_ d: Int) -> UInt32 {
    d >= 0 ? UInt32(truncatingIfNeeded: 2 * d) : UInt32(truncatingIfNeeded: -2 * d - 1)
}

// MARK: - Frame + stream assembly

enum ModularEncoder {
    /// Encodes `image` as a bare-codestream lossless JXL (E1 subset: integer
    /// 8/16-bit samples, 1 or 3 color channels, no extra channels, single
    /// group — width and height ≤ 256).
    static func encodeLossless(_ image: JXLDecodedImage) throws -> [UInt8] {
        let gray = image.colorChannels == 1
        guard image.colorChannels == 1 || image.colorChannels == 3 else {
            throw JXLEncodeError(reason: "E1 encodes 1 or 3 color channels")
        }
        guard image.extraChannels == 0 else {
            throw JXLEncodeError(reason: "E1 does not encode extra channels")
        }
        guard !image.isFloat, image.bitsPerSample >= 1, image.bitsPerSample <= 16 else {
            throw JXLEncodeError(reason: "E1 encodes integer samples up to 16 bits")
        }
        guard image.width >= 1, image.height >= 1, image.width <= 256, image.height <= 256
        else {
            throw JXLEncodeError(reason: "E1 encodes single-group images (≤256×256)")
        }
        let maxVal = (1 << image.bitsPerSample) - 1
        for p in 0..<image.colorChannels {
            for v in image.planes[p] where v < 0 || v > Int32(maxVal) {
                throw JXLEncodeError(reason: "sample \(v) out of range for \(image.bitsPerSample)-bit")
            }
        }

        let w = BitWriter()
        HeaderWriter.writeCodestreamHeaders(
            w, width: UInt32(image.width), height: UInt32(image.height),
            bitsPerSample: UInt32(image.bitsPerSample), grayscale: gray)
        writeFrameHeader(w)

        let section = encodeGlobalSection(image)

        // TOC: 1 entry (coalesced), no permutation.
        w.writeBool(false)
        w.alignToByte()
        w.writeU32(
            UInt32(section.count), .bits(10), .bits(14, offset: 1024),
            .bits(22, offset: 17408), .bits(30, offset: 4_211_712))
        w.alignToByte()
        w.append(bytes: section)
        return w.finalize()
    }

    /// FrameHeader for the E1 shape: regular, modular, no flags, no color
    /// transform, no upsampling, single pass, full-canvas, last frame, no
    /// name, no restoration filters.
    private static func writeFrameHeader(_ w: BitWriter) {
        w.writeBool(false)  // all_default
        w.write(0, 2)  // frame_type: regular (U32 Val selector)
        w.writeBool(true)  // encoding: modular
        w.writeU64(0)  // flags
        w.writeBool(false)  // color transform: none (xyb_encoded is false)
        w.write(0, 2)  // upsampling = 1 (U32 Val selector)
        w.write(1, 2)  // group_size_shift = 1 (256px groups, the default)
        w.write(0, 2)  // num_passes = 1 (U32 Val selector)
        w.writeBool(false)  // custom_size_or_origin
        w.write(0, 2)  // blending mode: replace (U32 Val selector)
        w.writeBool(true)  // is_last
        // (is_last -> no save_as_reference; not referenced -> no save_before)
        w.write(0, 2)  // name length = 0 (U32 Val selector)
        // Loop filter: gaborish off, EPF off.
        w.writeBool(false)  // all_default
        w.writeBool(false)  // gab
        w.write(0, 2)  // epf_iters = 0
        w.writeU64(0)  // loop-filter extensions
        w.writeU64(0)  // frame-header extensions
    }

    /// The coalesced section-0 payload: LfGlobal's modular pieces (default
    /// dc-quant, global single-leaf gradient tree) followed by the global
    /// modular stream carrying every channel.
    private static func encodeGlobalSection(_ image: JXLDecodedImage) -> [UInt8] {
        let w = BitWriter()
        // (flags = 0: no patches/splines/noise payloads)
        w.writeBool(true)  // dc-quant factors: default
        w.writeBool(true)  // has_tree: global tree follows
        writeSingleLeafGradientTree(w)
        // The residual entropy header follows the tree immediately
        // (decodeModularChannels reads tree + histograms together, BEFORE the
        // group stream), so tokenize first to size the alphabet.
        let (tokens, maxToken) = tokenizeChannels(image)
        let writer = FlatPrefixWriter(maxToken: maxToken)
        writer.writeHeader(w, numContexts: 1)  // single-leaf tree -> 1 context
        // Global modular stream: GroupHeader, then the channel symbols coded
        // with the header above.
        w.writeBool(true)  // use_global_tree
        w.writeBool(true)  // wp_header: all_default
        w.write(0, 2)  // nb_transforms = 0 (U32 Val selector)
        for v in tokens { writer.writeValue(w, v) }
        return w.finalize()
    }

    /// Residual tokens for every channel in decode order, using the decoder's
    /// exact gradient prediction and border semantics (`decodeChannel`).
    private static func tokenizeChannels(_ image: JXLDecodedImage)
        -> (tokens: [UInt32], maxToken: UInt32)
    {
        let width = image.width
        let height = image.height
        var tokens: [UInt32] = []
        tokens.reserveCapacity(width * height * image.colorChannels)
        var maxToken: UInt32 = 0
        for c in 0..<image.colorChannels {
            image.planes[c].withUnsafeBufferPointer { px in
                for y in 0..<height {
                    let row = y * width
                    let prev = row - width
                    for x in 0..<width {
                        let left = x > 0 ? Int(px[row + x - 1]) : (y > 0 ? Int(px[prev + x]) : 0)
                        let top = y > 0 ? Int(px[prev + x]) : left
                        let topleft = (x > 0 && y > 0) ? Int(px[prev + x - 1]) : left
                        let guess = predictOne(
                            5, left: left, top: top, toptop: 0, topleft: topleft,
                            topright: 0, leftleft: 0, toprightright: 0, wpPred: 0)
                        let packed = packSigned(Int(px[row + x]) - guess)
                        let t = FlatPrefixWriter.token(for: packed)
                        if t > maxToken { maxToken = t }
                        tokens.append(packed)
                    }
                }
            }
        }
        return (tokens, maxToken)
    }

    /// The global MA tree: one leaf, Gradient predictor, offset 0,
    /// multiplier 1 — every sample lands in one context and prediction is
    /// W+N−NW (`predictOne` case 5). Tree tokens: property=0 (leaf),
    /// predictor=5, offset=0, mul_log=0, mul_bits=0, in tree contexts 1/2/3/
    /// 4/5, all mapped to one flat histogram.
    private static func writeSingleLeafGradientTree(_ w: BitWriter) {
        let writer = FlatPrefixWriter(maxToken: FlatPrefixWriter.token(for: 5))
        writer.writeHeader(w, numContexts: 6)  // kNumTreeContexts
        writer.writeValue(w, 0)  // property + 1 = 0 -> leaf
        writer.writeValue(w, 5)  // predictor: Gradient
        writer.writeValue(w, 0)  // packed predictor offset
        writer.writeValue(w, 0)  // multiplier log
        writer.writeValue(w, 0)  // multiplier bits
        // (prefix path: no ANS final state)
    }

}

extension JXL {
    /// Encodes pixel planes as a lossless bare-codestream JXL (E1 subset:
    /// integer 8/16-bit samples, 1 or 3 channels, ≤256×256). Round-trips
    /// byte-exactly under this decoder and djxl.
    public static func encodeLossless(image: JXLDecodedImage) throws -> [UInt8] {
        try ModularEncoder.encodeLossless(image)
    }
}
