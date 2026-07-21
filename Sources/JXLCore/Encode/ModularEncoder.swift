// ModularEncoder.swift
//
// The lossless Modular encoder (E1-E4 of docs/encoder-design.md): native-
// space frames with learned MA trees (TreeBuilder.swift), real entropy
// (EntropyWriter/ANSWriter), forward YCoCg RCT or global palette, per-leaf
// multipliers, multi-group encoding, and effort levels. Every stream this
// file writes is read back by the decoder's own parsers; validity against
// the spec is proven by djxl round-trips in-suite.
//
// The load-bearing rule (see the design doc): prediction uses the *decoder's*
// `predictOne`/`WPState` with the decoder's exact border semantics
// (group-local at group boundaries), so encode/decode prediction divergence
// is structurally impossible.

import Foundation

public struct JXLEncodeError: Error, CustomStringConvertible, Sendable {
    public let reason: String
    public var description: String { reason }
}

/// A channel in coded space: after transforms, channels have their own
/// dimensions (the palette meta-channel is nbColors x numC).
struct EncChannel {
    var plane: [Int32]
    var w: Int
    var h: Int
}

// MARK: - Frame + stream assembly

enum ModularEncoder {
    /// Residual entropy back-end. ANS (E2) is the default; prefix codes (E1)
    /// stay selectable so both duals remain exercised by the suite.
    enum EntropyBackend {
        case prefix
        case ans
    }

    private enum EncTransform {
        case rct
        case palette(numC: Int, nbColors: Int)
    }

    /// One coded stream: its decoder stream id and the (channel, rect) parts
    /// tokenized into it, in decode order.
    private struct StreamPlan {
        var streamID: Int
        var parts: [(chan: Int, x0: Int, y0: Int, gw: Int, gh: Int)]
    }

    /// Encodes `image` as a bare-codestream lossless JXL. Integer samples up
    /// to 16 bits or binary32 floats, 1 or 3 color channels, any number of
    /// same-size alpha extra channels, any dimensions.
    /// Effort 1 = fast (fixed gradient tree, RCT only); effort 2 (default) =
    /// learned trees + WP + palette + leaf multipliers.
    static func encodeLossless(
        _ image: JXLDecodedImage, backend: EntropyBackend = .ans, effort: Int = 2
    ) throws -> [UInt8] {
        let candidate = try encodeLossless(image, backend: backend, effort: effort, allowPalette: true)
        if candidate.usedPalette {
            // Palette-eligible images (≤256 colors) are cheap to encode; the
            // RCT + multiplier path occasionally wins on small ones, so take
            // the actual smaller file rather than trusting the heuristic.
            let direct = try encodeLossless(
                image, backend: backend, effort: effort, allowPalette: false)
            if direct.bytes.count < candidate.bytes.count { return direct.bytes }
        }
        return candidate.bytes
    }

    private static func encodeLossless(
        _ image: JXLDecodedImage, backend: EntropyBackend, effort: Int, allowPalette: Bool
    ) throws -> (bytes: [UInt8], usedPalette: Bool) {
        let gray = image.colorChannels == 1
        guard image.colorChannels == 1 || image.colorChannels == 3 else {
            throw JXLEncodeError(reason: "encoder supports 1 or 3 color channels")
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
                throw JXLEncodeError(reason: "integer samples up to 16 bits")
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
        guard effort == 1 || effort == 2 else {
            throw JXLEncodeError(reason: "effort must be 1 or 2")
        }

        // ---- Transform selection: palette beats RCT when the image has few
        // distinct colors (detection aborts early, so photos pay ~nothing);
        // otherwise YCoCg for RGB. Palette collapses the color channels into
        // a meta palette channel (nbColors x numC, always in the global
        // stream) plus one index channel.
        var channels: [EncChannel] = []
        var nbMetaChannels = 0
        var transforms: [EncTransform] = []
        var paletteApplied = false
        if effort >= 2, allowPalette,
            let (palette, index, nbColors) = detectPalette(
                planes: image.planes, colorChannels: image.colorChannels,
                width: image.width, height: image.height,
                worthIt: image.colorChannels > 1 || image.bitsPerSample > 8)
        {
            channels.append(EncChannel(plane: palette, w: nbColors, h: image.colorChannels))
            channels.append(EncChannel(plane: index, w: image.width, h: image.height))
            nbMetaChannels = 1
            transforms = [.palette(numC: image.colorChannels, nbColors: nbColors)]
            paletteApplied = true
        } else {
            var planes = (0..<image.colorChannels).map { image.planes[$0] }
            if image.colorChannels == 3 {
                forwardYCoCg(&planes)
                transforms = [.rct]
            }
            channels = planes.map {
                EncChannel(plane: $0, w: image.width, h: image.height)
            }
        }
        for e in 0..<image.extraChannels {
            channels.append(
                EncChannel(
                    plane: image.planes[image.colorChannels + e],
                    w: image.width, h: image.height))
        }

        var dim = FrameDimensions()
        dim.set(
            xsize: image.width, ysize: image.height, groupSizeShift: 1,
            maxHShift: 0, maxVShift: 0, modular: true, upsampling: 1)
        let coalesced = dim.numGroups == 1

        // ---- Stream plans, mirroring decodeModularChannels' split: the
        // global stream (id 0) carries the meta channels always, plus every
        // channel when coalesced; per-group streams carry the non-meta
        // channels' rects with ModularStreamId::ModularAC ids.
        var plans: [StreamPlan] = []
        var global = StreamPlan(streamID: 0, parts: [])
        for c in 0..<(coalesced ? channels.count : nbMetaChannels) {
            global.parts.append((c, 0, 0, channels[c].w, channels[c].h))
        }
        plans.append(global)
        if !coalesced {
            for g in 0..<dim.numGroups {
                let x0 = (g % dim.xsizeGroups) * dim.groupDim
                let y0 = (g / dim.xsizeGroups) * dim.groupDim
                var plan = StreamPlan(streamID: 1 + 3 * dim.numDCGroups + 17 + g, parts: [])
                for c in nbMetaChannels..<channels.count {
                    let ch = channels[c]
                    let gw = min(dim.groupDim, ch.w - x0)
                    let gh = min(dim.groupDim, ch.h - y0)
                    if gw > 0 && gh > 0 { plan.parts.append((c, x0, y0, gw, gh)) }
                }
                plans.append(plan)
            }
        }

        // Channel planes as raw buffers so the parallel workers below capture
        // nothing refcounted (the decoder's concurrentPerform rule).
        let chanBufs: [UnsafeMutableBufferPointer<Int32>] = channels.map { ch in
            let b = UnsafeMutableBufferPointer<Int32>.allocate(capacity: ch.plane.count)
            _ = b.initialize(from: ch.plane)
            return b
        }
        defer { for b in chanBufs { b.deallocate() } }
        let chanWidths = channels.map { $0.w }

        // ---- Tree: effort 1 uses the fixed single Gradient leaf; effort 2
        // learns on a subsample (parallel across stream parts).
        var tree: [MATreeNode]
        if effort == 1 {
            tree = [
                MATreeNode(
                    property: -1, splitVal: 0, lchild: 0, rchild: 0,
                    predictor: 5, predictorOffset: 0, multiplier: 1)
            ]
        } else {
            let totalSamples = channels.reduce(0) { $0 + $1.plane.count }
            let stride = max(1, totalSamples / 400_000)
            var allParts: [(chan: Int, x0: Int, y0: Int, gw: Int, gh: Int)] = []
            for plan in plans { allParts.append(contentsOf: plan.parts) }
            var partSets = [TreeTrainingSet?](repeating: nil, count: allParts.count)
            partSets.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let outP = out
                nonisolated(unsafe) let bufs = chanBufs
                nonisolated(unsafe) let parts = allParts
                nonisolated(unsafe) let widths = chanWidths
                DispatchQueue.concurrentPerform(iterations: parts.count) { i in
                    let p = parts[i]
                    var set = TreeTrainingSet()
                    set.collect(
                        plane: UnsafeBufferPointer(bufs[p.chan]), width: widths[p.chan],
                        x0: p.x0, y0: p.y0, gw: p.gw, gh: p.gh,
                        chan: p.chan, stride: stride)
                    outP[i] = set
                }
            }
            var training = TreeTrainingSet()
            for s in partSets {
                let s = s!
                training.props.append(contentsOf: s.props)
                training.tokens.append(contentsOf: s.tokens)
                training.count += s.count
            }
            tree = learnTree(training)
        }

        // ---- Tokenization (parallel across streams; each plan writes its
        // own slot).
        func buildStreams(_ t: [MATreeNode]) -> [[EncToken]] {
            var result = [[EncToken]?](repeating: nil, count: plans.count)
            result.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let outP = out
                nonisolated(unsafe) let bufs = chanBufs
                nonisolated(unsafe) let plansL = plans
                nonisolated(unsafe) let widths = chanWidths
                nonisolated(unsafe) let treeL = t
                DispatchQueue.concurrentPerform(iterations: plansL.count) { s in
                    var tokens: [EncToken] = []
                    for p in plansL[s].parts {
                        tokenizeChannelWithTree(
                            into: &tokens, plane: UnsafeBufferPointer(bufs[p.chan]),
                            width: widths[p.chan],
                            x0: p.x0, y0: p.y0, gw: p.gw, gh: p.gh,
                            chan: p.chan, streamID: plansL[s].streamID, tree: treeL)
                    }
                    outP[s] = tokens
                }
            }
            return result.map { $0! }
        }
        var streams = buildStreams(tree)

        // Leaf multipliers (effort 2): when a leaf's residuals share a
        // factor, divide them (pass 2 re-tokenizes under the multiplier tree
        // so fast-track kernel selection stays symmetric with the decoder;
        // divisibility is re-checked because that reselection can reroute
        // pixels).
        if effort >= 2, let multTree = treeWithLeafMultipliers(tree, streams: streams) {
            let retokenized = buildStreams(multTree)
            if let divided = divideByLeafMultipliers(multTree, streams: retokenized) {
                tree = multTree
                streams = divided
            }
        }

        // ---- Header + sections.
        let w = BitWriter()
        HeaderWriter.writeCodestreamHeaders(
            w, width: UInt32(image.width), height: UInt32(image.height),
            bitsPerSample: UInt32(image.bitsPerSample), grayscale: gray,
            exponentBits: image.isFloat ? 8 : 0, alphaChannels: image.extraChannels)
        writeFrameHeader(w, numExtraChannels: image.extraChannels)

        let residual = makeEncoder(
            backend, numContexts: treeNumLeaves(tree), streams: streams)

        let s0 = BitWriter()
        writeLfGlobalModular(s0, tree: tree, residual: residual, transforms: transforms)
        // The decoder creates the global stream's symbol reader only when at
        // least one channel decodes globally (numChans > 0 in modularDecode);
        // an empty global plan must write NO stream data (an ANS state there
        // would be unread waste).
        if !plans[0].parts.isEmpty {
            residual.encodeStream(s0, streams[0])
        }

        if coalesced {
            let section = s0.finalize()
            w.writeBool(false)  // TOC: no permutation
            w.alignToByte()
            writeTocSize(w, section.count)
            w.alignToByte()
            w.append(bytes: section)
            return (w.finalize(), paletteApplied)
        }

        var sections: [[UInt8]?] = [s0.finalize()]
        // DC-group sections carry only squeeze channels with shift >= 3 — none
        // here, and the decoder reads nothing from them. Same for HfGlobal.
        for _ in 0..<dim.numDCGroups { sections.append([]) }
        sections.append([])  // HfGlobal
        let groupBase = sections.count
        sections.append(contentsOf: [[UInt8]?](repeating: nil, count: dim.numGroups))
        sections.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let outP = out
            nonisolated(unsafe) let res = residual
            nonisolated(unsafe) let streamsL = streams
            DispatchQueue.concurrentPerform(iterations: dim.numGroups) { g in
                let s = BitWriter()
                s.writeBool(true)  // use_global_tree
                s.writeBool(true)  // wp_header: all_default
                s.write(0, 2)  // nb_transforms = 0
                res.encodeStream(s, streamsL[1 + g])
                outP[groupBase + g] = s.finalize()
            }
        }

        w.writeBool(false)  // TOC: no permutation
        w.alignToByte()
        for section in sections { writeTocSize(w, section!.count) }
        w.alignToByte()
        for section in sections { w.append(bytes: section!) }
        return (w.finalize(), paletteApplied)
    }

    private static func makeEncoder(
        _ backend: EntropyBackend, numContexts: Int, streams: [[EncToken]]
    ) -> any TokenEntropyEncoder {
        switch backend {
        case .prefix: return PrefixEntropyEncoder(numContexts: numContexts, streams: streams)
        case .ans: return ANSEntropyEncoder(numContexts: numContexts, streams: streams)
        }
    }

    /// Detects a global palette: at most 256 distinct colors across the color
    /// channels. Returns the palette meta-channel plane (numC rows of
    /// nbColors, the decoder's `palette[c * onerow + index]` layout), the
    /// index plane, and nbColors. The scan aborts as soon as a 257th color
    /// appears. `worthIt` gates cases where an index stream cannot beat the
    /// samples themselves (single-channel 8-bit).
    private static func detectPalette(
        planes: [[Int32]], colorChannels: Int, width: Int, height: Int, worthIt: Bool
    ) -> (palette: [Int32], index: [Int32], nbColors: Int)? {
        guard worthIt else { return nil }
        let n = width * height
        guard n >= 64 else { return nil }
        let maxColors = 256
        var seen = Set<SIMD4<Int32>>()
        seen.reserveCapacity(maxColors + 1)
        for i in 0..<n {
            let key = SIMD4<Int32>(
                planes[0][i],
                colorChannels > 1 ? planes[1][i] : 0,
                colorChannels > 2 ? planes[2][i] : 0, 0)
            seen.insert(key)
            if seen.count > maxColors { return nil }
        }
        let nbColors = seen.count
        guard nbColors * 2 <= n else { return nil }
        // Lexicographic order (any order decodes; sorted compresses the
        // palette channel itself well).
        let colors = seen.sorted { a, b in
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.z < b.z
        }
        var lookup = [SIMD4<Int32>: Int32]()
        lookup.reserveCapacity(nbColors)
        for (i, c) in colors.enumerated() { lookup[c] = Int32(i) }
        var palette = [Int32](repeating: 0, count: nbColors * colorChannels)
        for (i, c) in colors.enumerated() {
            palette[i] = c.x
            if colorChannels > 1 { palette[nbColors + i] = c.y }
            if colorChannels > 2 { palette[2 * nbColors + i] = c.z }
        }
        var index = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let key = SIMD4<Int32>(
                planes[0][i],
                colorChannels > 1 ? planes[1][i] : 0,
                colorChannels > 2 ? planes[2][i] : 0, 0)
            index[i] = lookup[key]!
        }
        return (palette, index, nbColors)
    }

    /// In-place forward YCoCg (rct_type 6, identity permutation): the exact
    /// inverse of the decoder's invRCT custom == 6 branch. Every intermediate
    /// wraps to Int32 (>> 1 is not congruence-preserving, so the wrap points
    /// must match invRCT exactly — full-range float bit patterns reach them).
    private static func forwardYCoCg(_ channels: inout [[Int32]]) {
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

    /// FrameHeader for the lossless shape: regular, modular, no flags, no
    /// color transform, no upsampling (incl. per-EC), single pass,
    /// full-canvas, replace blending (incl. per-EC), last frame, no name, no
    /// restoration filters.
    private static func writeFrameHeader(_ w: BitWriter, numExtraChannels: Int) {
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
            w.write(0, 2)  // EC blending mode: replace (U32 Val selector)
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
    /// stream's GroupHeader carrying the transforms. The caller appends the
    /// global stream's tokens.
    private static func writeLfGlobalModular(
        _ w: BitWriter, tree: [MATreeNode], residual: any TokenEntropyEncoder,
        transforms: [EncTransform]
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
        // Global modular stream: GroupHeader (transforms), then the caller's
        // global-channel tokens.
        w.writeBool(true)  // use_global_tree
        w.writeBool(true)  // wp_header: all_default
        w.writeU32(
            UInt32(transforms.count), .value(0), .value(1), .bits(4, offset: 2),
            .bits(8, offset: 18))
        for t in transforms {
            switch t {
            case .rct:
                w.writeU32(0, .value(0), .value(1), .value(2), .value(3))  // id: RCT
                w.writeU32(
                    0, .bits(3), .bits(6, offset: 8), .bits(10, offset: 72),
                    .bits(13, offset: 1096))  // begin_c
                w.writeU32(6, .value(6), .bits(2), .bits(4, offset: 2), .bits(6, offset: 10))  // YCoCg
            case .palette(let numC, let nbColors):
                w.writeU32(1, .value(0), .value(1), .value(2), .value(3))  // id: Palette
                w.writeU32(
                    0, .bits(3), .bits(6, offset: 8), .bits(10, offset: 72),
                    .bits(13, offset: 1096))  // begin_c
                w.writeU32(UInt32(numC), .value(1), .value(3), .value(4), .bits(13, offset: 1))
                w.writeU32(
                    UInt32(nbColors), .bits(8), .bits(10, offset: 256),
                    .bits(12, offset: 1280), .bits(16, offset: 5376))
                w.writeU32(0, .value(0), .bits(8, offset: 1), .bits(10, offset: 257), .bits(16, offset: 1281))  // nb_deltas
                w.write(0, 4)  // predictor: Zero
            }
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
    /// Encodes pixel planes as a lossless bare-codestream JXL: integer
    /// samples up to 16 bits or binary32 floats (planes carrying IEEE-754 bit
    /// patterns as Int32), 1 or 3 color channels plus any number of same-size
    /// alpha extra channels, any dimensions. Round-trips byte-exactly under
    /// this decoder and djxl. `effort`: 1 = fast (fixed tree), 2 = default
    /// (learned trees, WP, palette, multipliers).
    public static func encodeLossless(image: JXLDecodedImage, effort: Int = 2) throws -> [UInt8] {
        try ModularEncoder.encodeLossless(image, effort: effort)
    }
}
