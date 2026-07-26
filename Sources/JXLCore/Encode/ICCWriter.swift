// ICCWriter.swift
//
// Embedded ICC profile WRITING — the dual of Color/ICCCodec.swift. A profile is
// stored inside the CODESTREAM (not in a box): `ColorEncoding.want_icc = 1`
// promises a compressed profile right after `CustomTransformData`, encoded as
//
//     U64(encoded_size) | entropy header (41 contexts) | encoded_size symbols
//
// whose symbols are a PREDICTION RESIDUAL stream that the decoder's
// `unpredictICC` turns back into the profile. This writer emits that residual
// stream and entropy-codes it with the project's normal ANS back-end, so the
// bytes are read by `readICCProfile` (and by libjxl's ICCReader) unchanged.
//
// SUPPORTED SUBSET. `unpredictICC` accepts three kinds of instruction:
//
//   (a) the 128-byte header, always coded as a residual against a predicted
//       header (profile size, version, "mntr"/"RGB "/"XYZ "/"acsp", the
//       platform/creator refinements),
//   (b) an optional TAG-LIST command stream that reconstructs the profile's
//       tag table from shorthand codes (kCommandTagTRC expands to rTRC+gTRC+
//       bTRC, kCommandTagXYZ to rXYZ+gXYZ+bXYZ, tag names by index, implicit
//       offsets/sizes),
//   (c) main-content commands: insert-verbatim, 2/4-byte shuffle, order-0/1/2
//       linear prediction at a given stride/width, and type-name shorthands.
//
// We implement (a) in full, and of (c) the two that carry the compression:
// `kCommandInsert` and `kCommandPredict` (widths 1/2/4 × orders 0/1/2, stride
// == width), selected per 16-byte block by measured cost and merged into runs.
// We do NOT implement (b) — the tag table travels as ordinary inserted bytes,
// coded as "numtags = 0", which is the stream's own way of saying "no
// tag-list commands" — nor the shuffle/XYZ/type-name shorthands.
//
// This is a subset of the MODELLING, never of the FORMAT: every byte written
// is in the spec's command vocabulary, and the profile always round-trips
// BYTE-EXACTLY. What the missing pieces cost is size only. Codestream growth
// from embedding a profile, ours vs cjxl v0.12 on the same profile (measured
// as encoded-with-profile minus encoded-without, both encoders):
//
//     AdobeRGB      (544 B raw)    277 B  vs cjxl 166 B
//     Display P3    (536 B raw)    317 B  vs cjxl 212 B
//     Apple display (2924 B raw)   864 B  vs cjxl 554 B
//     sRGB Profile  (3144 B raw)  1072 B  vs cjxl 589 B
//
// (Before the kCommandPredict search the last two were 2454 B and 2619 B —
// each of those profiles is dominated by one 2060-byte 16-bit `curv` table,
// which order-1 prediction at width 2 flattens.) The residue is the tag table
// (b) plus libjxl's per-tag-type heuristics; adding them is a self-contained
// follow-up that changes nothing here.
//
// SAFETY NET: the optimized stream is decoded back through the decoder's own
// `unpredictICC` before it ships. If it does not reproduce the profile exactly
// it is discarded in favor of the plain header+insert form, which is also
// verified. A modelling bug can therefore cost size, never correctness.

import Foundation

/// LEB128 varint, the dual of `decodeVarInt` in ICCCodec.swift.
private func appendVarInt(_ value: UInt64, _ out: inout [UInt8]) {
    var v = value
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        out.append(byte)
    } while v != 0
}

/// One main-content instruction covering `count` output bytes.
private enum ICCSegment: Equatable {
    case insert
    /// `kCommandPredict` with stride == width (so no explicit-stride flag).
    case predict(width: Int, order: Int)
}

/// Candidate predictors, cheapest-flag-first. Only stride == width forms are
/// used: they need no varint stride and cover the layouts that matter (byte
/// runs, 16-bit curve tables, 32-bit fixed-point arrays).
private let kICCPredictModes: [ICCSegment] = [
    .predict(width: 1, order: 0), .predict(width: 1, order: 1), .predict(width: 1, order: 2),
    .predict(width: 2, order: 0), .predict(width: 2, order: 1), .predict(width: 2, order: 2),
    .predict(width: 4, order: 0), .predict(width: 4, order: 1), .predict(width: 4, order: 2),
]

/// Block size for the per-segment mode search. Segment starts stay 128 + 16k,
/// a multiple of every candidate width (1/2/4), so a merged run predicts each
/// byte exactly as its own block did — merging is cost-neutral by construction,
/// not an approximation.
private let kICCBlockSize = 16

/// Residual bytes a `predict` segment would produce for `icc[start..<start+n]`,
/// or `nil` when the decoder's stride guard would reject the command there.
/// Computed with the decoder's OWN `linearPredictICCValue` against the profile
/// itself: at every index that function reads only output below the current
/// position, which the decoder has already reconstructed identically.
private func iccPredictResidual(
    _ icc: [UInt8], start: Int, count: Int, width: Int, order: Int
) -> [UInt8]? {
    let stride = width
    // Decoder guard: `result.isEmpty || ((result.count - 1) >> 2) < stride`.
    guard start > 0, ((start - 1) >> 2) >= stride else { return nil }
    var residual = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        let predicted = linearPredictICCValue(
            icc, start: start, i: i, stride: stride, width: width, order: order)
        residual[i] = icc[start + i] &- predicted
    }
    // The decoder shuffles the bytes it reads before adding predictions, so the
    // stream carries the INVERSE shuffle of the residuals.
    if width > 1 { residual = iccUnshuffle(residual, width: width) }
    return residual
}

/// Inverse of `iccShuffle`: `iccShuffle(iccUnshuffle(x)) == x`. The shuffle
/// walks a source index `j` in steps of `height`, wrapping to the next column,
/// so inverting it is the same walk with the assignment reversed.
private func iccUnshuffle(_ data: [UInt8], width: Int) -> [UInt8] {
    let size = data.count
    let height = (size + width - 1) / width
    var out = [UInt8](repeating: 0, count: size)
    var s = 0
    var j = 0
    for i in 0..<size {
        out[j] = data[i]
        j += height
        if j >= size {
            s += 1
            j = s
        }
    }
    return out
}

/// Cost proxy for a residual block: a Laplace-ish bit count that rewards
/// residuals clustered on 0 / ±1 / ±2 the way the 41-context ANS coder does.
private func iccResidualCost(_ residual: [UInt8]) -> Double {
    var bits = 0.0
    for b in residual {
        let s = abs(Int(Int8(bitPattern: b)))
        bits += 1.0 + log2(Double(2 * s + 1))
    }
    return bits
}

/// Serializes one residual stream: varint(output size), varint(command bytes),
/// the command bytes, then the data stream.
private func buildICCResidualStream(_ icc: [UInt8], segments: [(ICCSegment, Int)]) -> [UInt8] {
    let osize = icc.count
    let headerBytes = min(kICCHeaderSize, osize)

    // Data part 1: the header, as residuals against the SAME rolling prediction
    // the decoder refines (`iccPredictHeader` sees only bytes it has already
    // reconstructed, which are exactly `icc[0..<i]`).
    var header = iccInitialHeaderPrediction(UInt32(osize))
    var data = [UInt8]()
    data.reserveCapacity(osize)
    for i in 0..<headerBytes {
        iccPredictHeader(icc, i, &header, i)
        data.append(icc[i] &- header[i])
    }

    // Commands + data part 2. A profile that is nothing but a header needs no
    // commands at all: the decoder's header loop returns as soon as the output
    // reaches the declared size, and then requires both the command and the
    // data stream to be exactly used up.
    var commands = [UInt8]()
    if osize > headerBytes {
        commands.append(0)  // numtags = 0: no tag-list command stream
        var pos = headerBytes
        for (segment, count) in segments {
            switch segment {
            case .insert:
                commands.append(kCommandInsert)
                appendVarInt(UInt64(count), &commands)
                data.append(contentsOf: icc[pos..<(pos + count)])
            case .predict(let width, let order):
                // flags: bits 0-1 = width - 1, bits 2-3 = order, bit 4 unset
                // (stride == width, no varint follows).
                commands.append(kCommandPredict)
                commands.append(UInt8((width - 1) | (order << 2)))
                appendVarInt(UInt64(count), &commands)
                data.append(
                    contentsOf: iccPredictResidual(
                        icc, start: pos, count: count, width: width, order: order)!)
            }
            pos += count
        }
    }

    var out = [UInt8]()
    out.reserveCapacity(osize + 32)
    appendVarInt(UInt64(osize), &out)
    appendVarInt(UInt64(commands.count), &out)
    out.append(contentsOf: commands)
    out.append(contentsOf: data)
    return out
}

/// Per-block mode search over the post-header region, with hysteresis so a
/// marginally better mode does not fragment a run into extra commands.
private func chooseICCSegments(_ icc: [UInt8]) -> [(ICCSegment, Int)] {
    let osize = icc.count
    var segments: [(ICCSegment, Int)] = []
    var pos = kICCHeaderSize
    var previous: ICCSegment = .insert
    while pos < osize {
        let n = min(kICCBlockSize, osize - pos)
        // `insert` codes the raw bytes; every predictor codes its residual.
        var bestMode = ICCSegment.insert
        var bestCost = iccResidualCost(Array(icc[pos..<(pos + n)]))
        for mode in kICCPredictModes {
            guard case .predict(let width, let order) = mode,
                let residual = iccPredictResidual(
                    icc, start: pos, count: n, width: width, order: order)
            else { continue }
            var cost = iccResidualCost(residual)
            // Command overhead (~3 bytes) plus a nudge toward continuing the
            // current run.
            if mode != previous { cost += 24 }
            if cost < bestCost {
                bestCost = cost
                bestMode = mode
            }
        }
        if let last = segments.last, last.0 == bestMode {
            segments[segments.count - 1].1 += n
        } else {
            segments.append((bestMode, n))
        }
        previous = bestMode
        pos += n
    }
    return segments
}

/// The candidate residual streams for `icc`, best first, each already verified
/// to reconstruct the profile through the decoder's own `unpredictICC`. The
/// plain header+insert form is always present and always last.
func iccResidualCandidates(_ icc: [UInt8]) throws -> [[UInt8]] {
    let osize = icc.count
    guard osize > 0 else { throw JXLEncodeError(reason: "empty ICC profile") }
    guard osize <= (1 << 28) else {
        throw JXLEncodeError(reason: "ICC profile too large (\(osize) bytes)")
    }

    let plainSegments: [(ICCSegment, Int)] =
        osize > kICCHeaderSize ? [(.insert, osize - kICCHeaderSize)] : []
    let plain = buildICCResidualStream(icc, segments: plainSegments)
    guard (try? unpredictICC(plain)) == icc else {
        throw JXLEncodeError(reason: "internal: ICC residual stream failed its own round trip")
    }

    var candidates: [[UInt8]] = []
    if osize > kICCHeaderSize {
        let optimized = buildICCResidualStream(icc, segments: chooseICCSegments(icc))
        // Discard silently on any mismatch: a modelling bug must cost size, not
        // correctness.
        if (try? unpredictICC(optimized)) == icc { candidates.append(optimized) }
    }
    candidates.append(plain)
    return candidates
}

/// Writes the codestream's embedded-ICC field: the encoded size, the entropy
/// header over 41 contexts, and the residual stream. Dual of `readICCProfile`.
/// Candidate residual streams are ranked by their ACTUAL coded size — the
/// commands change how compressible the stream is, not how long it is, so an
/// estimate on the residual bytes alone would rank them wrong.
func writeICCProfile(_ w: BitWriter, profile: [UInt8]) throws {
    let candidates = try iccResidualCandidates(profile)
    var best = candidates[0]
    var bestBits = Int.max
    for candidate in candidates {
        let trial = BitWriter()
        encodeICCResidual(trial, candidate)
        if trial.bitPosition < bestBits {
            bestBits = trial.bitPosition
            best = candidate
        }
    }
    encodeICCResidual(w, best)
}

private func encodeICCResidual(_ w: BitWriter, _ residual: [UInt8]) {
    w.writeU64(UInt64(residual.count))
    // Contexts key on the two PREVIOUS residual bytes (both zero at the
    // start), exactly as the reader recomputes them.
    var tokens = [EncToken]()
    tokens.reserveCapacity(residual.count)
    var b1: UInt8 = 0
    var b2: UInt8 = 0
    for (i, b) in residual.enumerated() {
        tokens.append(EncToken(ctx: UInt32(iccANSContext(i, b1, b2)), value: UInt32(b)))
        b2 = b1
        b1 = b
    }
    let coder = ANSEntropyEncoder(numContexts: kNumICCContexts, streams: [tokens])
    coder.writeHeader(w)
    coder.encodeStream(w, tokens)
}

// MARK: - Codestream headers carrying an ICC profile

/// The pre-frame header block for a native-space (Modular / `xyb_encoded = 0`)
/// codestream whose color encoding is an embedded ICC profile.
///
/// This duplicates the bit layout of `HeaderWriter.writeImageMetadata` because
/// that bundle's `writeBitDepth` / `writeExtraChannelInfo` / `writeColorEncoding`
/// helpers are file-private and HeaderWriter.swift is owned by another change in
/// flight. The right shape is an `iccProfile:` parameter on
/// `HeaderWriter.writeCodestreamHeaders`; see the hand-off note in the change
/// description.
enum ICCHeaderWriter {
    static func writeCodestreamHeaders(
        _ w: BitWriter, width: UInt32, height: UInt32, bitsPerSample: UInt32,
        grayscale: Bool, exponentBits: UInt32 = 0, alphaChannels: Int = 0,
        iccProfile: [UInt8]
    ) throws {
        w.write(0xFF, 8)
        w.write(0x0A, 8)
        HeaderWriter.writeSizeHeader(w, width: width, height: height)
        writeImageMetadataICC(
            w, bitsPerSample: bitsPerSample, grayscale: grayscale,
            exponentBits: exponentBits, alphaChannels: alphaChannels)
        HeaderWriter.writeCustomTransformData(w)
        // `want_icc` promises the compressed profile here, before the byte
        // alignment that precedes the frames (dual of FrameDecoder's init).
        try writeICCProfile(w, profile: iccProfile)
        w.alignToByte()
    }

    /// ImageMetadata with `ColorEncoding.want_icc = 1`. When `want_icc` is set,
    /// ColorEncoding carries NOTHING beyond the color space — no white point,
    /// primaries, transfer function or rendering intent (they come from the
    /// profile). The color space itself must still be right: the decoder takes
    /// its channel count from it.
    private static func writeImageMetadataICC(
        _ w: BitWriter, bitsPerSample: UInt32, grayscale: Bool,
        exponentBits: UInt32, alphaChannels: Int
    ) {
        w.writeBool(false)  // all_default
        w.writeBool(false)  // extra_fields
        writeBitDepth(w, bitsPerSample: bitsPerSample, exponentBits: exponentBits)
        w.writeBool(exponentBits == 0)  // modular_16bit_buffers
        w.writeU32(
            UInt32(alphaChannels), .value(0), .value(1), .bits(4, offset: 2),
            .bits(12, offset: 1))  // num_extra_channels
        for _ in 0..<alphaChannels {
            writeExtraChannelInfo(w, bitsPerSample: bitsPerSample, exponentBits: exponentBits)
        }
        w.writeBool(false)  // xyb_encoded: native-space samples
        w.writeBool(false)  // ColorEncoding all_default
        w.writeBool(true)  // want_icc
        w.writeEnum(grayscale ? 1 : 0)  // color_space: kGray / kRGB
        w.writeU64(0)  // extensions
    }

    private static func writeBitDepth(
        _ w: BitWriter, bitsPerSample: UInt32, exponentBits: UInt32
    ) {
        if exponentBits == 0 {
            w.writeBool(false)  // floating_point_sample
            w.writeU32(bitsPerSample, .value(8), .value(10), .value(12), .bits(6, offset: 1))
        } else {
            w.writeBool(true)
            w.writeU32(bitsPerSample, .value(32), .value(16), .value(24), .bits(6, offset: 1))
            w.write(UInt64(exponentBits - 1), 4)
        }
    }

    private static func writeExtraChannelInfo(
        _ w: BitWriter, bitsPerSample: UInt32, exponentBits: UInt32
    ) {
        if bitsPerSample == 8 && exponentBits == 0 {
            w.writeBool(true)  // all_default (= 8-bit unassociated alpha)
            return
        }
        w.writeBool(false)
        w.writeEnum(0)  // type: kAlpha
        writeBitDepth(w, bitsPerSample: bitsPerSample, exponentBits: exponentBits)
        w.writeU32(0, .value(0), .value(3), .value(4), .bits(3, offset: 1))  // dim_shift
        w.writeU32(0, .value(0), .bits(4), .bits(5, offset: 16), .bits(10, offset: 48))  // name
        w.writeBool(false)  // alpha_associated
    }
}
