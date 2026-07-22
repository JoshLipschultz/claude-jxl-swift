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
/// dimensions (the palette meta-channel is nbColors x numC) and — once
/// squeezed — their own downsampling shifts, which drive the decoder's
/// global/DC-group/AC-group stream assignment and rect math.
struct EncChannel {
    var plane: [Int32]
    var w: Int
    var h: Int
    var hshift: Int = 0
    var vshift: Int = 0
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
        case squeeze
    }

    /// One coded stream: its decoder stream id and the (channel, rect) parts
    /// tokenized into it, in decode order. `buf` indexes the channel whose
    /// plane holds the samples; `chan` is the property-0 value the decoder
    /// computes for that part (the channel's index within THIS stream's own
    /// image — full-list index for the global stream, position in the group
    /// sub-image for per-group streams).
    private struct StreamPlan {
        var streamID: Int
        var parts: [(buf: Int, chan: Int, x0: Int, y0: Int, gw: Int, gh: Int)]
    }

    /// Encodes `image` as a bare-codestream lossless JXL. Integer samples up
    /// to 16 bits or binary32 floats, 1 or 3 color channels, any number of
    /// same-size alpha extra channels, any dimensions.
    /// Effort 1 = fast (fixed gradient tree, RCT only); effort 2 (default) =
    /// learned trees + WP + palette + leaf multipliers.
    /// `squeeze` applies the default squeeze sequence (responsive-mode
    /// hierarchical decomposition; integer samples only, palette skipped).
    static func encodeLossless(
        _ image: JXLDecodedImage, backend: EntropyBackend = .ans, effort: Int = 2,
        squeeze: Bool = false
    ) throws -> [UInt8] {
        if squeeze {
            // Squeeze skips palette this round (an index channel's discrete
            // codes don't average meaningfully), so no double-encode either.
            return try encodeLossless(
                image, backend: backend, effort: effort, allowPalette: false, squeeze: true
            ).bytes
        }
        let candidate = try encodeLossless(
            image, backend: backend, effort: effort, allowPalette: true, squeeze: false)
        if candidate.usedPalette {
            // Palette-eligible images (≤256 colors) are cheap to encode; the
            // RCT + multiplier path occasionally wins on small ones, so take
            // the actual smaller file rather than trusting the heuristic.
            let direct = try encodeLossless(
                image, backend: backend, effort: effort, allowPalette: false, squeeze: false)
            if direct.bytes.count < candidate.bytes.count { return direct.bytes }
        }
        return candidate.bytes
    }

    private static func encodeLossless(
        _ image: JXLDecodedImage, backend: EntropyBackend, effort: Int, allowPalette: Bool,
        squeeze: Bool
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
        if squeeze && image.isFloat {
            // Squeeze is not congruence-preserving mod 2^32: the decoder's
            // per-level Int32 wrap feeds `diff/2`, a division, so full-range
            // bit patterns cannot round-trip. Rejected, not approximated.
            throw JXLEncodeError(reason: "squeeze does not support float samples")
        }

        // ---- Transform selection: palette beats RCT when the image has few
        // distinct colors (detection aborts early, so photos pay ~nothing);
        // otherwise YCoCg for RGB. Palette collapses the color channels into
        // a meta palette channel (nbColors x numC, always in the global
        // stream) plus one index channel. Squeeze composes AFTER RCT (list
        // order = apply order; the decoder undoes in reverse).
        var channels: [EncChannel] = []
        var nbMetaChannels = 0
        var transforms: [EncTransform] = []
        var paletteApplied = false
        if squeeze {
            var mods: [ModularChannel] = []
            var planes = (0..<image.colorChannels).map { image.planes[$0] }
            if image.colorChannels == 3 {
                forwardYCoCg(&planes)
                transforms.append(.rct)
            }
            for p in planes {
                var mc = ModularChannel(w: image.width, h: image.height)
                mc.pixels = p
                mods.append(mc)
            }
            for e in 0..<image.extraChannels {
                var mc = ModularChannel(w: image.width, h: image.height)
                mc.pixels = image.planes[image.colorChannels + e]
                mods.append(mc)
            }
            transforms.append(.squeeze)
            // The bitstream carries numSqueezes = 0, so the decoder resolves
            // DefaultSqueezeParameters itself; the forward application must
            // use the SAME concrete sequence — obtained by running the
            // decoder's own metaSqueeze — and the forward layout is
            // cross-checked against metaSqueeze's channel bookkeeping (dims
            // + shifts); any divergence refuses to encode.
            let layout = ModularImage(
                w: image.width, h: image.height, bitdepth: image.bitsPerSample,
                channelCount: mods.count)
            var params: [SqueezeParams] = []
            do { try metaSqueeze(layout, params: &params) } catch {
                throw JXLEncodeError(reason: "squeeze parameter resolution failed")
            }
            forwardSqueeze(&mods, params: params)
            guard mods.count == layout.channels.count,
                zip(mods, layout.channels).allSatisfy({
                    $0.w == $1.w && $0.h == $1.h
                        && $0.hshift == $1.hshift && $0.vshift == $1.vshift
                })
            else {
                throw JXLEncodeError(
                    reason: "internal: forward squeeze layout diverged from metaSqueeze")
            }
            channels = mods.map {
                EncChannel(plane: $0.pixels, w: $0.w, h: $0.h, hshift: $0.hshift, vshift: $0.vshift)
            }
        } else if effort >= 2, allowPalette,
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
        if !squeeze {
            for e in 0..<image.extraChannels {
                channels.append(
                    EncChannel(
                        plane: image.planes[image.colorChannels + e],
                        w: image.width, h: image.height))
            }
        }

        var dim = FrameDimensions()
        dim.set(
            xsize: image.width, ysize: image.height, groupSizeShift: 1,
            maxHShift: 0, maxVShift: 0, modular: true, upsampling: 1)
        let coalesced = dim.numGroups == 1

        // ---- Stream plans, mirroring decodeModularChannels' split: the
        // global stream (id 0) carries every channel when coalesced;
        // otherwise the channels up to modularDecode's BREAK point (the
        // first non-meta channel with w or h > groupDim — ALL later channels
        // are per-group, even small squeeze residuals). Per-group streams
        // carry channel rects bracketed by squeeze shift: DC-group streams
        // (ModularStreamId::ModularDC, tile groupDim*8) take min shift >= 3,
        // AC groups (ModularStreamId::ModularAC) take shift 0...2.
        var plans: [StreamPlan] = []
        var global = StreamPlan(streamID: 0, parts: [])
        if coalesced {
            // modularDecode with maxChanSize = ∞: every nonempty channel
            // decodes globally with its full-list index as property 0 (empty
            // squeeze residuals are `continue`d without renumbering).
            for c in 0..<channels.count where channels[c].w > 0 && channels[c].h > 0 {
                global.parts.append((c, c, 0, 0, channels[c].w, channels[c].h))
            }
            plans.append(global)
        } else {
            var splitC = nbMetaChannels
            while splitC < channels.count {
                let ch = channels[splitC]
                if ch.w > dim.groupDim || ch.h > dim.groupDim { break }
                splitC += 1
            }
            for c in 0..<splitC where channels[c].w > 0 && channels[c].h > 0 {
                global.parts.append((c, c, 0, 0, channels[c].w, channels[c].h))
            }
            plans.append(global)

            // Per-group parts mirror decodeModularGroupImage exactly: rects
            // shifted by the channel's own hshift/vshift and clamped against
            // the channel's own (ceil-rounded) dims; skip-empty. Property 0
            // is the channel's position within the group's OWN sub-image
            // (`parts.count`, mirroring the decoder's gi.channels append
            // loop: local 0 = first included channel), NOT the full-list
            // index — the decoder's per-group modularDecode renumbers from
            // zero. The two coincide whenever no meta channels exist and
            // nothing is skipped; with palette meta channels they differ,
            // which desynced the bitstream whenever a learned tree split on
            // property 0 (encoder-fuzzer find, fixed here; the DC-group
            // squeeze streams need the same local numbering).
            func groupParts(rx0: Int, ry0: Int, tile: Int, minShift: Int, maxShift: Int)
                -> [(buf: Int, chan: Int, x0: Int, y0: Int, gw: Int, gh: Int)]
            {
                var parts: [(buf: Int, chan: Int, x0: Int, y0: Int, gw: Int, gh: Int)] = []
                for c in splitC..<channels.count {
                    let ch = channels[c]
                    guard ch.hshift >= 0, ch.vshift >= 0 else { continue }
                    let shift = min(ch.hshift, ch.vshift)
                    if shift > maxShift || shift < minShift { continue }
                    let rx = rx0 >> ch.hshift
                    let ry = ry0 >> ch.vshift
                    let rw = min(tile >> ch.hshift, ch.w - rx)
                    let rh = min(tile >> ch.vshift, ch.h - ry)
                    if rw <= 0 || rh <= 0 { continue }
                    parts.append((c, parts.count, rx, ry, rw, rh))
                }
                return parts
            }
            if squeeze {
                for dcg in 0..<dim.numDCGroups {
                    let tile = dim.groupDim * 8
                    let rx0 = (dcg % dim.xsizeDCGroups) * tile
                    let ry0 = (dcg / dim.xsizeDCGroups) * tile
                    plans.append(
                        StreamPlan(
                            streamID: 1 + dim.numDCGroups + dcg,
                            parts: groupParts(
                                rx0: rx0, ry0: ry0, tile: tile, minShift: 3, maxShift: 1000)))
                }
            }
            for g in 0..<dim.numGroups {
                let x0 = (g % dim.xsizeGroups) * dim.groupDim
                let y0 = (g / dim.xsizeGroups) * dim.groupDim
                plans.append(
                    StreamPlan(
                        streamID: 1 + 3 * dim.numDCGroups + 17 + g,
                        parts: groupParts(
                            rx0: x0, ry0: y0, tile: dim.groupDim, minShift: 0, maxShift: 2)))
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
            var allParts: [(buf: Int, chan: Int, x0: Int, y0: Int, gw: Int, gh: Int)] = []
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
                        plane: UnsafeBufferPointer(bufs[p.buf]), width: widths[p.buf],
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
                            into: &tokens, plane: UnsafeBufferPointer(bufs[p.buf]),
                            width: widths[p.buf],
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
        // DC-group sections carry only squeeze channels with min shift >= 3
        // (streamID = 1 + numDCGroups + dcg, tile = groupDim*8). Each
        // non-empty one is a full modular sub-stream with its own
        // GroupHeader, like an AC group; when no channel intersects, the
        // decoder never opens the section and it must stay zero bytes.
        for dcg in 0..<dim.numDCGroups {
            if squeeze, !plans[1 + dcg].parts.isEmpty {
                let s = BitWriter()
                s.writeBool(true)  // use_global_tree
                s.writeBool(true)  // wp_header: all_default
                s.write(0, 2)  // nb_transforms = 0
                residual.encodeStream(s, streams[1 + dcg])
                sections.append(s.finalize())
            } else {
                sections.append([])
            }
        }
        sections.append([])  // HfGlobal
        let groupBase = sections.count
        // AC plans follow the global (+ DC, in squeeze mode) plans.
        let acBase = squeeze ? 1 + dim.numDCGroups : 1
        sections.append(contentsOf: [[UInt8]?](repeating: nil, count: dim.numGroups))
        sections.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let outP = out
            nonisolated(unsafe) let res = residual
            nonisolated(unsafe) let streamsL = streams
            nonisolated(unsafe) let plansL = plans
            DispatchQueue.concurrentPerform(iterations: dim.numGroups) { g in
                // A group none of whose channels intersect writes nothing —
                // decodeModularGroupImage returns before reading a bit.
                if plansL[acBase + g].parts.isEmpty {
                    outP[groupBase + g] = []
                    return
                }
                let s = BitWriter()
                s.writeBool(true)  // use_global_tree
                s.writeBool(true)  // wp_header: all_default
                s.write(0, 2)  // nb_transforms = 0
                res.encodeStream(s, streamsL[acBase + g])
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
            case .squeeze:
                w.writeU32(2, .value(0), .value(1), .value(2), .value(3))  // id: Squeeze
                // num_squeezes = 0: the decoder resolves the default
                // sequence (DefaultSqueezeParameters), the same concrete
                // list the encoder applied via the decoder's own metaSqueeze.
                w.writeU32(
                    0, .value(0), .bits(4, offset: 1), .bits(6, offset: 9),
                    .bits(8, offset: 41))
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
    /// (learned trees, WP, palette, multipliers). `squeeze` applies the
    /// default responsive-mode squeeze decomposition (integer samples only;
    /// usually a small density cost on noisy content, occasionally a win on
    /// smooth content — and the file becomes progressively decodable).
    public static func encodeLossless(
        image: JXLDecodedImage, effort: Int = 2, squeeze: Bool = false
    ) throws -> [UInt8] {
        try ModularEncoder.encodeLossless(image, effort: effort, squeeze: squeeze)
    }
}
