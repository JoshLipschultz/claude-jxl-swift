// ModularEncoder.swift
//
// E1 of docs/encoder-design.md: the honest lossless encoder — native-space
// Modular frames with a single-leaf gradient MA tree and real canonical
// prefix codes (EntropyWriter.swift), forward YCoCg RCT for color images, and
// multi-group encoding for arbitrary dimensions. Every stream this file
// writes is read back by the decoder's own parsers; validity against the spec
// is proven by djxl round-trips in-suite.
//
// The load-bearing rule (see the design doc): prediction uses the *decoder's*
// `predictOne` with the decoder's exact border semantics (group-local at
// group boundaries), so encode/decode prediction divergence is structurally
// impossible.

import Foundation

public struct JXLEncodeError: Error, CustomStringConvertible, Sendable {
    public let reason: String
    public var description: String { reason }
}

@inline(__always)
private func packSigned(_ d: Int) -> UInt32 {
    d >= 0 ? UInt32(truncatingIfNeeded: 2 * d) : UInt32(truncatingIfNeeded: -2 * d - 1)
}

// MARK: - Frame + stream assembly

enum ModularEncoder {
    /// Residual entropy back-end. ANS (E2) is the default; prefix codes (E1)
    /// stay selectable so both duals remain exercised by the suite.
    enum EntropyBackend {
        case prefix
        case ans
    }

    /// Encodes `image` as a bare-codestream lossless JXL (E3 subset: integer
    /// samples up to 16 bits or binary32 floats, 1 or 3 color channels, any
    /// number of same-size alpha extra channels).
    static func encodeLossless(
        _ image: JXLDecodedImage, backend: EntropyBackend = .ans
    ) throws -> [UInt8] {
        let gray = image.colorChannels == 1
        guard image.colorChannels == 1 || image.colorChannels == 3 else {
            throw JXLEncodeError(reason: "E3 encodes 1 or 3 color channels")
        }
        guard image.extraChannels >= 0,
            image.planes.count == image.colorChannels + image.extraChannels
        else {
            throw JXLEncodeError(reason: "plane count must be colorChannels + extraChannels")
        }
        if image.isFloat {
            // binary32 only: the decoder's float path (and libjxl's
            // int_to_float at bits==32) is a bit-pattern identity, so modular
            // samples ARE the IEEE-754 bit patterns. Smaller float depths
            // need a real mantissa/exponent re-pack the decoder doesn't
            // model — rejected, not approximated.
            guard image.bitsPerSample == 32 else {
                throw JXLEncodeError(reason: "float encode supports binary32 (32-bit) only")
            }
        } else {
            guard image.bitsPerSample >= 1, image.bitsPerSample <= 16 else {
                throw JXLEncodeError(reason: "E3 encodes integer samples up to 16 bits")
            }
        }
        guard image.width >= 1, image.height >= 1 else {
            throw JXLEncodeError(reason: "empty image")
        }
        let planeSize = image.width * image.height
        guard image.planes.allSatisfy({ $0.count == planeSize }) else {
            throw JXLEncodeError(reason: "plane size must be width * height")
        }
        if !image.isFloat {
            let maxVal = (1 << image.bitsPerSample) - 1
            for p in 0..<image.planes.count {
                for v in image.planes[p] where v < 0 || v > Int32(maxVal) {
                    throw JXLEncodeError(
                        reason: "sample \(v) out of range for \(image.bitsPerSample)-bit")
                }
            }
        }
        // (float samples are arbitrary bit patterns; every pattern —
        // including NaN/Inf — round-trips exactly through the identity path.)

        // Channel planes in coded (RCT) space. YCoCg (rct_type 6) turns
        // correlated RGB into a luma + two difference channels; lossless and
        // exactly inverted by the decoder's invRCT. RCT applies to the color
        // channels only; extra channels are appended untransformed, in the
        // decoder's channel order (color first, then extras).
        var channels = image.planes
        let useRCT = image.colorChannels == 3
        if useRCT { forwardYCoCg(&channels) }

        var dim = FrameDimensions()
        dim.set(
            xsize: image.width, ysize: image.height, groupSizeShift: 1,
            maxHShift: 0, maxVShift: 0, modular: true, upsampling: 1)

        let w = BitWriter()
        HeaderWriter.writeCodestreamHeaders(
            w, width: UInt32(image.width), height: UInt32(image.height),
            bitsPerSample: UInt32(image.bitsPerSample), grayscale: gray,
            exponentBits: image.isFloat ? 8 : 0, alphaChannels: image.extraChannels)
        writeFrameHeader(w, numExtraChannels: image.extraChannels)

        // Learn the MA tree on a subsample of the (RCT-space) pixels, using
        // group-local rects so training statistics match what tokenization
        // will actually see at group borders.
        var training = TreeTrainingSet()
        let totalSamples = image.width * image.height * channels.count
        let stride = max(1, totalSamples / 400_000)
        for g in 0..<dim.numGroups {
            let x0 = (g % dim.xsizeGroups) * dim.groupDim
            let y0 = (g / dim.xsizeGroups) * dim.groupDim
            let gw = min(dim.groupDim, image.width - x0)
            let gh = min(dim.groupDim, image.height - y0)
            for (c, plane) in channels.enumerated() {
                training.collect(
                    plane: plane, width: image.width, x0: x0, y0: y0, gw: gw, gh: gh,
                    chan: c, stride: stride)
            }
        }
        var tree = learnTree(training)

        // One rect per coded stream: the whole image (stream id 0) when
        // coalesced, else per-group rects whose stream ids must match the
        // decoder's ModularStreamId::ModularAC (property 1 splits see them).
        let coalesced = dim.numGroups == 1
        var rects: [(x0: Int, y0: Int, gw: Int, gh: Int, streamID: Int)] = []
        if coalesced {
            rects.append((0, 0, image.width, image.height, 0))
        } else {
            for g in 0..<dim.numGroups {
                let x0 = (g % dim.xsizeGroups) * dim.groupDim
                let y0 = (g / dim.xsizeGroups) * dim.groupDim
                rects.append(
                    (x0, y0, min(dim.groupDim, image.width - x0),
                     min(dim.groupDim, image.height - y0),
                     1 + 3 * dim.numDCGroups + 17 + g))
            }
        }
        func buildStreams(_ t: [MATreeNode]) -> [[EncToken]] {
            rects.map { r in
                var tokens: [EncToken] = []
                for (c, plane) in channels.enumerated() {
                    tokenizeChannelWithTree(
                        into: &tokens, plane: plane, width: image.width,
                        x0: r.x0, y0: r.y0, gw: r.gw, gh: r.gh,
                        chan: c, streamID: r.streamID, tree: t)
                }
                return tokens
            }
        }
        var groupTokens = buildStreams(tree)

        // Leaf multipliers: when a leaf's residuals share a factor, divide
        // them (pass 2 re-tokenizes under the multiplier tree so fast-track
        // kernel selection stays symmetric with the decoder; divisibility is
        // re-checked because that reselection can reroute pixels).
        if let multTree = treeWithLeafMultipliers(tree, streams: groupTokens) {
            let retokenized = buildStreams(multTree)
            if let divided = divideByLeafMultipliers(multTree, streams: retokenized) {
                tree = multTree
                groupTokens = divided
            }
        }

        if coalesced {
            // Coalesced: one section carrying tree, histograms, and the global
            // stream with every channel.
            let residual = makeEncoder(
                backend, numContexts: treeNumLeaves(tree), streams: groupTokens)
            let s = BitWriter()
            writeLfGlobalModular(s, tree: tree, residual: residual, useRCT: useRCT)
            residual.encodeStream(s, groupTokens[0])
            let section = s.finalize()
            w.writeBool(false)  // TOC: no permutation
            w.alignToByte()
            writeTocSize(w, section.count)
            w.alignToByte()
            w.append(bytes: section)
            return w.finalize()
        }

        let residual = makeEncoder(
            backend, numContexts: treeNumLeaves(tree), streams: groupTokens)

        // Section 0 (LfGlobal): tree + shared histograms + the global stream's
        // GroupHeader. With one group dimension > group_dim, every color
        // channel is per-group, so the global stream carries no channel data.
        let s0 = BitWriter()
        writeLfGlobalModular(s0, tree: tree, residual: residual, useRCT: useRCT)
        var sections: [[UInt8]] = [s0.finalize()]
        // DC-group sections carry only squeeze channels with shift >= 3 — none
        // here, and the decoder reads nothing from them. Same for HfGlobal.
        for _ in 0..<dim.numDCGroups { sections.append([]) }
        sections.append([])  // HfGlobal
        for g in 0..<dim.numGroups {
            let s = BitWriter()
            s.writeBool(true)  // use_global_tree
            s.writeBool(true)  // wp_header: all_default
            s.write(0, 2)  // nb_transforms = 0
            residual.encodeStream(s, groupTokens[g])
            sections.append(s.finalize())
        }

        w.writeBool(false)  // TOC: no permutation
        w.alignToByte()
        for section in sections { writeTocSize(w, section.count) }
        w.alignToByte()
        for section in sections { w.append(bytes: section) }
        return w.finalize()
    }

    private static func makeEncoder(
        _ backend: EntropyBackend, numContexts: Int, streams: [[EncToken]]
    ) -> any TokenEntropyEncoder {
        switch backend {
        case .prefix: return PrefixEntropyEncoder(numContexts: numContexts, streams: streams)
        case .ans: return ANSEntropyEncoder(numContexts: numContexts, streams: streams)
        }
    }

    /// In-place forward YCoCg (rct_type 6, identity permutation): the exact
    /// inverse of the decoder's invRCT custom == 6 branch.
    private static func forwardYCoCg(_ channels: inout [[Int32]]) {
        // Detach the three planes so the nested mutable pointer scopes don't
        // overlap on `channels` (exclusivity); swaps avoid COW copies.
        var p0: [Int32] = []
        var p1: [Int32] = []
        var p2: [Int32] = []
        swap(&p0, &channels[0])
        swap(&p1, &channels[1])
        swap(&p2, &channels[2])
        let n = p0.count
        p0.withUnsafeMutableBufferPointer { c0 in
            p1.withUnsafeMutableBufferPointer { c1 in
                p2.withUnsafeMutableBufferPointer { c2 in
                    for i in 0..<n {
                        // Every step wraps to Int32 BEFORE the next shift:
                        // `>> 1` is not congruence-preserving mod 2^32, so
                        // the decoder's invRCT (which shifts the *stored*
                        // Int32 values) only inverts a forward built from the
                        // same wrapped intermediates. Full-range samples
                        // (float32 bit patterns) reach the wrapping cases.
                        let r = c0[i]
                        let g = c1[i]
                        let b = c2[i]
                        let co = r &- b
                        let tmp = b &+ (co >> 1)
                        let cg = g &- tmp
                        let y = tmp &+ (cg >> 1)
                        c0[i] = y
                        c1[i] = co
                        c2[i] = cg
                    }
                }
            }
        }
        swap(&p0, &channels[0])
        swap(&p1, &channels[1])
        swap(&p2, &channels[2])
    }

    /// FrameHeader for the E1 shape: regular, modular, no flags, no color
    /// transform, no upsampling, single pass, full-canvas, last frame, no
    /// name, no restoration filters.
    private static func writeFrameHeader(_ w: BitWriter, numExtraChannels: Int = 0) {
        w.writeBool(false)  // all_default
        w.write(0, 2)  // frame_type: regular (U32 Val selector)
        w.writeBool(true)  // encoding: modular
        w.writeU64(0)  // flags
        w.writeBool(false)  // color transform: none (xyb_encoded is false)
        w.write(0, 2)  // upsampling = 1 (U32 Val selector)
        for _ in 0..<numExtraChannels {
            w.write(0, 2)  // ec_upsampling = 1 (U32 Val selector)
        }
        w.write(1, 2)  // group_size_shift = 1 (256px groups, the default)
        w.write(0, 2)  // num_passes = 1 (U32 Val selector)
        w.writeBool(false)  // custom_size_or_origin
        w.write(0, 2)  // blending mode: replace (U32 Val selector)
        for _ in 0..<numExtraChannels {
            w.write(0, 2)  // ec blending mode: replace (U32 Val selector)
        }
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

    /// LfGlobal's modular pieces: default dc-quant, the global (learned) MA
    /// tree, the shared residual entropy header (decodeModularChannels reads
    /// tree + histograms together, before any group stream), then the global
    /// stream's GroupHeader carrying the transforms.
    private static func writeLfGlobalModular(
        _ w: BitWriter, tree: [MATreeNode], residual: any TokenEntropyEncoder, useRCT: Bool
    ) {
        // (flags = 0: no patches/splines/noise payloads)
        w.writeBool(true)  // dc-quant factors: default
        w.writeBool(true)  // has_tree: global tree follows
        let tokens = treeTokens(tree)
        let enc = PrefixEntropyEncoder(numContexts: 6, streams: [tokens])  // kNumTreeContexts
        enc.writeHeader(w)
        enc.encodeStream(w, tokens)
        // (prefix path: no ANS final state)
        residual.writeHeader(w)
        // Global modular stream: GroupHeader (with the RCT transform), then —
        // multi-group — nothing (all channels are per-group), or — coalesced —
        // the caller appends every channel's tokens.
        w.writeBool(true)  // use_global_tree
        w.writeBool(true)  // wp_header: all_default
        if useRCT {
            w.writeU32(1, .value(0), .value(1), .bits(4, offset: 2), .bits(8, offset: 18))
            w.writeU32(0, .value(0), .value(1), .value(2), .value(3))  // id: RCT
            w.writeU32(0, .bits(3), .bits(6, offset: 8), .bits(10, offset: 72), .bits(13, offset: 1096))
            w.writeU32(6, .value(6), .bits(2), .bits(4, offset: 2), .bits(6, offset: 10))  // YCoCg
        } else {
            w.writeU32(0, .value(0), .value(1), .bits(4, offset: 2), .bits(8, offset: 18))
        }
    }

    /// TOC entry size (toc.cc U32 distribution).
    private static func writeTocSize(_ w: BitWriter, _ size: Int) {
        w.writeU32(
            UInt32(size), .bits(10), .bits(14, offset: 1024),
            .bits(22, offset: 17408), .bits(30, offset: 4_211_712))
    }

}

extension JXL {
    /// Encodes pixel planes as a lossless bare-codestream JXL (E3 subset:
    /// integer samples up to 16 bits or binary32 floats — planes carrying
    /// IEEE-754 bit patterns as Int32 — 1 or 3 color channels plus any number
    /// of same-size alpha extra channels, any dimensions).
    /// Round-trips byte-exactly under this decoder and djxl.
    public static func encodeLossless(image: JXLDecodedImage) throws -> [UInt8] {
        try ModularEncoder.encodeLossless(image)
    }
}
