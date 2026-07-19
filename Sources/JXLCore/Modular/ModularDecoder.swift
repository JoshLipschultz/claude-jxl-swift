// ModularDecoder.swift
//
// Drives the Modular-mode channel decode (libjxl modular/encoding/encoding.cc
// ModularDecode + DecodeModularChannelMAANS). For each channel and pixel it
// computes the MA-tree properties, traverses the tree to a clustered context,
// reads a residual through the ANS/prefix reader, and reconstructs the sample
// as `UnpackSigned(residual) * multiplier + offset + predicted`.
//
// The reversible transforms (RCT/Palette/Squeeze) are parsed here; their inverse
// (undo) is a later step. RCT and an empty transform list need no channel-layout
// change, which is the common single-frame lossless case.

import Foundation

private let kNumStaticProperties = 2
private let kNumNonrefProperties = 16  // 2 static + 13 + 1 WP
private let kExtraPropsPerChannel = 4

enum TransformId: UInt32 { case rct = 0, palette = 1, squeeze = 2, invalid = 3 }

struct SqueezeParams {
    var horizontal: Bool
    var inPlace: Bool
    var beginC: UInt32
    var numC: UInt32
}

struct ModularTransform {
    var id: TransformId = .rct
    var beginC: UInt32 = 0
    var rctType: UInt32 = 6
    var numC: UInt32 = 3
    var nbColors: UInt32 = 256
    var nbDeltas: UInt32 = 0
    var predictor: UInt32 = 0
    /// Squeeze only. Empty means "use the default sequence", which MetaApply
    /// resolves against the image dimensions (DefaultSqueezeParameters) so the
    /// inverse sees the concrete list.
    var squeezes: [SqueezeParams] = []
}

extension BitReader {
    /// Reads a Transform descriptor (libjxl Transform::VisitFields).
    func readTransform() -> ModularTransform? {
        var t = ModularTransform()
        let rawId = readU32(.value(0), .value(1), .value(2), .value(3))
        guard let id = TransformId(rawValue: rawId), id != .invalid else { return nil }
        t.id = id
        if id == .rct || id == .palette {
            t.beginC = readU32(.bits(3), .bits(6, offset: 8), .bits(10, offset: 72), .bits(13, offset: 1096))
        }
        if id == .rct {
            t.rctType = readU32(.value(6), .bits(2), .bits(4, offset: 2), .bits(6, offset: 10))
            if t.rctType >= 42 { return nil }
        }
        if id == .palette {
            t.numC = readU32(.value(1), .value(3), .value(4), .bits(13, offset: 1))
            t.nbColors = readU32(.bits(8), .bits(10, offset: 256), .bits(12, offset: 1280), .bits(16, offset: 5376))
            t.nbDeltas = readU32(.value(0), .bits(8, offset: 1), .bits(10, offset: 257), .bits(16, offset: 1281))
            t.predictor = UInt32(read(4))
            if t.predictor >= 14 { return nil }
        }
        if id == .squeeze {
            let numSqueezes = readU32(.value(0), .bits(4, offset: 1), .bits(6, offset: 9), .bits(8, offset: 41))
            for _ in 0..<numSqueezes {
                let horizontal = read(1) == 1
                let inPlace = read(1) == 1
                let beginC = readU32(.bits(3), .bits(6, offset: 8), .bits(10, offset: 72), .bits(13, offset: 1096))
                let numC = readU32(.value(1), .value(2), .value(3), .bits(4, offset: 4))
                t.squeezes.append(
                    SqueezeParams(horizontal: horizontal, inPlace: inPlace, beginC: beginC, numC: numC))
            }
        }
        return t
    }
}

struct GroupHeader {
    var useGlobalTree = false
    var wpHeader = WPHeader()
    var transforms: [ModularTransform] = []
}

func readGroupHeader(_ br: BitReader) -> GroupHeader? {
    var h = GroupHeader()
    h.useGlobalTree = br.readBool()
    h.wpHeader = br.readWPHeader()
    let numTransforms = Int(br.readU32(.value(0), .value(1), .bits(4, offset: 2), .bits(8, offset: 18)))
    for _ in 0..<numTransforms {
        guard let t = br.readTransform() else { return nil }
        h.transforms.append(t)
    }
    return h
}

/// Max MA-tree property index referenced (+1), clamped to at least the
/// non-reference property count.
private func numProps(for tree: [MATreeNode]) -> Int {
    var maxProp = 0
    for node in tree where !node.isLeaf {
        maxProp = max(maxProp, node.property + 1)
    }
    return max(kNumNonrefProperties, maxProp)
}

/// libjxl decodes certain simple trees through specialized "fast track"
/// kernels whose property arithmetic differs from the generic path at the
/// extremes of the 32-bit sample range (reachable with float bit patterns):
/// the gradient track clamps the *64-bit* local gradient to
/// ±kPropRangeFast where the generic path wraps it to int32, and the WP
/// track truncates the weighted prediction itself to int32. cjxl encodes
/// with the same kernel selection, so bit-exact decoding requires
/// reproducing both the selection rules and the divergent arithmetic
/// (encoding.cc DecodeModularChannelMAANS, FilterTree, TreeToLookupTable).
enum ChannelFastTrack {
    case none
    /// Tree splits only on static props / property 9, all reachable leaves
    /// are Gradient with multiplier 1 / offset 0, splitvals in LUT range.
    case gradientClamp
    /// Same shape but property 15 / Weighted leaves; libjxl additionally
    /// requires no LZ77 and width > 8.
    case wpClamp
}

private let kPropRangeFast: Int64 = 512 << 4  // 8192, encoding.h

func channelFastTrack(
    tree: [MATreeNode], chan: Int, groupID: Int, usesLZ77: Bool, width: Int
) -> ChannelFastTrack {
    if tree.count == 1 { return .none }  // single-leaf tracks match generic semantics
    let statics: [Int32] = [
        Int32(truncatingIfNeeded: chan), Int32(truncatingIfNeeded: groupID),
    ]
    var stack = [0]
    var dynamicProps = Set<Int>()
    var allGradient = true
    var allWeighted = true
    var simpleLeaves = true
    var splitvalsInRange = true
    var sawLeaf = false
    while let pos = stack.popLast() {
        let node = tree[pos]
        if node.isLeaf {
            sawLeaf = true
            if node.predictor != 5 { allGradient = false }
            if node.predictor != 6 { allWeighted = false }
            if node.multiplier != 1 || node.predictorOffset != 0 { simpleLeaves = false }
            continue
        }
        if node.property < kNumStaticProperties {
            // Static property: the branch is decided by chan/group alone, so
            // only one side is reachable (libjxl FilterTree).
            stack.append(statics[node.property] > node.splitVal ? node.lchild : node.rchild)
            continue
        }
        dynamicProps.insert(node.property)
        if node.splitVal < Int32(-kPropRangeFast - 1) || node.splitVal > Int32(kPropRangeFast - 2) {
            splitvalsInRange = false
        }
        stack.append(node.lchild)
        stack.append(node.rchild)
    }
    guard sawLeaf, simpleLeaves, splitvalsInRange else { return .none }
    if dynamicProps.isSubset(of: [9]) && allGradient { return .gradientClamp }
    if dynamicProps.isSubset(of: [15]) && allWeighted && !usesLZ77 && width > 8 {
        return .wpClamp
    }
    return .none
}

/// Decodes one channel's samples (the general PredictTreeWP path).
private func decodeChannel(
    _ br: BitReader, _ reader: ANSSymbolReader, contextMap: [UInt8], tree: [MATreeNode],
    wpHeader: WPHeader, chan: Int, groupID: Int, image: ModularImage, propCount: Int,
    usesLZ77: Bool
) {
    let w = image.channels[chan].w
    let h = image.channels[chan].h
    if w == 0 || h == 0 { return }
    let fastTrack = channelFastTrack(
        tree: tree, chan: chan, groupID: groupID, usesLZ77: usesLZ77, width: w)

    let refCount = propCount - kNumNonrefProperties
    let references = refCount > 0 ? precomputeReferenceChannels(image: image, chan: chan, refCount: refCount) : []

    // The weighted predictor's error window costs more per pixel than the rest
    // of the decode combined; run it only when the tree can observe it — via
    // the WP property (15) at a split or the Weighted predictor (6) at a leaf
    // (libjxl `TreeToLookupTable` use_wp gating).
    let treeUsesWP = tree.contains { node in
        node.property == -1 ? node.predictor == 6 : node.property == 15
    }
    let wpState = treeUsesWP ? WPState(header: wpHeader, xsize: w, ysize: h) : nil
    var props = [Int32](repeating: 0, count: propCount)
    props[0] = Int32(truncatingIfNeeded: chan)
    props[1] = Int32(truncatingIfNeeded: groupID)

    image.channels[chan].pixels.withUnsafeMutableBufferPointer { px in
        for y in 0..<h {
            props[2] = Int32(truncatingIfNeeded: y)
            props[9] = 0
            let rowBase = y * w
            let prevBase = (y - 1) * w
            let prevPrevBase = (y - 2) * w
            for x in 0..<w {
                let left = x > 0 ? Int(px[rowBase + x - 1]) : (y > 0 ? Int(px[prevBase + x]) : 0)
                let top = y > 0 ? Int(px[prevBase + x]) : left
                let topleft = (x > 0 && y > 0) ? Int(px[prevBase + x - 1]) : left
                let topright = (x + 1 < w && y > 0) ? Int(px[prevBase + x + 1]) : top
                let leftleft = x > 1 ? Int(px[rowBase + x - 2]) : left
                let toptop = y > 1 ? Int(px[prevPrevBase + x]) : top
                let toprightright = (x + 2 < w && y > 0) ? Int(px[prevBase + x + 2]) : topright

                props[3] = Int32(truncatingIfNeeded: x)
                props[4] = Int32(truncatingIfNeeded: abs(top))
                props[5] = Int32(truncatingIfNeeded: abs(left))
                props[6] = Int32(truncatingIfNeeded: top)
                props[7] = Int32(truncatingIfNeeded: left)
                props[8] = Int32(truncatingIfNeeded: left - Int(props[9]))
                if fastTrack == .gradientClamp {
                    // libjxl's gradient fast track clamps the 64-bit local
                    // gradient to the LUT range instead of wrapping to int32.
                    let g = Int64(left) + Int64(top) - Int64(topleft)
                    props[9] = Int32(min(max(g, -kPropRangeFast), kPropRangeFast - 1))
                } else {
                    props[9] = Int32(truncatingIfNeeded: left + top - topleft)
                }
                props[10] = Int32(truncatingIfNeeded: left - topleft)
                props[11] = Int32(truncatingIfNeeded: topleft - top)
                props[12] = Int32(truncatingIfNeeded: top - topright)
                props[13] = Int32(truncatingIfNeeded: top - toptop)
                props[14] = Int32(truncatingIfNeeded: left - leftleft)

                var wpPred = wpState?.predict(
                    x: x, y: y, xsize: w, N: top, W: left, NE: topright, NW: topleft, NN: toptop,
                    computeProperties: true, properties: &props, offset: 15) ?? 0
                if fastTrack == .wpClamp {
                    // libjxl's WP fast track truncates the prediction to int32
                    // and clamps the WP property to the LUT range.
                    wpPred = Int(Int32(truncatingIfNeeded: wpPred))
                    props[15] = min(max(props[15], Int32(-kPropRangeFast)), Int32(kPropRangeFast - 1))
                }

                for i in 0..<refCount { props[16 + i] = references[i][rowBase + x] }

                // Tree traversal -> clustered context + predictor.
                var pos = 0
                while tree[pos].property != -1 {
                    pos = props[tree[pos].property] > tree[pos].splitVal ? tree[pos].lchild : tree[pos].rchild
                }
                let leaf = tree[pos]
                let context = Int(contextMap[leaf.lchild])
                let predicted = predictOne(
                    leaf.predictor, left: left, top: top, toptop: toptop, topleft: topleft,
                    topright: topright, leftleft: leftleft, toprightright: toprightright, wpPred: wpPred)
                let guess = Int(leaf.predictorOffset) + predicted

                let v = reader.readHybridUintClustered(context, br)
                let value = Int(unpackSigned(v)) * Int(leaf.multiplier) + guess
                px[rowBase + x] = Int32(truncatingIfNeeded: value)
                wpState?.updateErrors(Int(px[rowBase + x]), x: x, y: y, xsize: w)
            }
        }
    }
}

/// Builds the per-pixel reference properties from earlier same-shape channels
/// (libjxl PrecomputeReferences), as `refCount` full-image planes.
private func precomputeReferenceChannels(image: ModularImage, chan: Int, refCount: Int) -> [[Int32]] {
    let w = image.channels[chan].w
    let h = image.channels[chan].h
    var refs = [[Int32]](repeating: [Int32](repeating: 0, count: w * h), count: refCount)
    var offset = 0
    var j = chan - 1
    // libjxl PrecomputeReferences loops while `offset < num_extra_props`, so
    // when refCount is not a multiple of 4 the last matching channel fills a
    // partial block (its remaining slots are simply cut off).
    while j >= 0 && offset < refCount {
        let cj = image.channels[j]
        if cj.w != w || cj.h != h || cj.hshift != image.channels[chan].hshift
            || cj.vshift != image.channels[chan].vshift {
            j -= 1
            continue
        }
        for y in 0..<h {
            for x in 0..<w {
                let v = Int(cj.at(x, y))
                let vleft = x > 0 ? Int(cj.at(x - 1, y)) : 0
                let vtop = y > 0 ? Int(cj.at(x, y - 1)) : vleft
                let vtopleft = (x > 0 && y > 0) ? Int(cj.at(x - 1, y - 1)) : vleft
                let grad = clampedGradient(vleft, vtop, vtopleft)
                let base = y * w + x
                refs[offset + 0][base] = Int32(truncatingIfNeeded: abs(v))
                if offset + 1 < refCount { refs[offset + 1][base] = Int32(truncatingIfNeeded: v) }
                if offset + 2 < refCount { refs[offset + 2][base] = Int32(truncatingIfNeeded: abs(v - grad)) }
                if offset + 3 < refCount { refs[offset + 3][base] = Int32(truncatingIfNeeded: v - grad) }
            }
        }
        offset += kExtraPropsPerChannel
        j -= 1
    }
    return refs
}

enum ModularDecodeError: Error {
    case unsupportedTransform, badGroupHeader, badTree, finalState
    /// A transform whose parameters are structurally invalid for the current
    /// channel layout (out-of-range channels, mismatched sizes, bad RCT type).
    case invalidTransform
}

/// Decodes a Modular image stream into `image` (libjxl ModularDecode), using a
/// pre-decoded global tree/code when `header.use_global_tree` is set.
@discardableResult
func modularDecode(
    _ br: BitReader, image: ModularImage, groupID: Int,
    globalTree: [MATreeNode]?, globalCode: ANSCode?, globalCtxMap: [UInt8]?,
    maxChanSize: Int = Int.max
) throws -> GroupHeader {
    guard var header = readGroupHeader(br) else { throw ModularDecodeError.badGroupHeader }
    // MetaApply: Palette and Squeeze change the channel layout before decoding.
    // Squeeze also resolves an empty parameter list to the default sequence,
    // which the inverse (undoTransforms) needs — hence the in-place mutation.
    for i in header.transforms.indices {
        try metaApplyTransform(image, transform: &header.transforms[i])
    }

    let tree: [MATreeNode]
    let code: ANSCode
    let ctxMap: [UInt8]
    if header.useGlobalTree {
        guard let gt = globalTree, let gc = globalCode, let gm = globalCtxMap, !gt.isEmpty else {
            throw ModularDecodeError.badTree
        }
        tree = gt
        code = gc
        ctxMap = gm
    } else {
        guard let localTree = decodeMATree(br, treeSizeLimit: 1 << 22),
            let (lc, lm) = decodeHistograms(br, numContexts: (localTree.count + 1) / 2, disallowLZ77: false)
        else { throw ModularDecodeError.badTree }
        tree = localTree
        code = lc
        ctxMap = lm
    }

    // Count decodable channels. Channels larger than `maxChanSize` (and not
    // meta channels) are left for per-group decoding.
    func isSkippedLargeChannel(_ index: Int) -> Bool {
        let ch = image.channels[index]
        return index >= image.nbMetaChannels && (ch.w > maxChanSize || ch.h > maxChanSize)
    }
    var numChans = 0
    var distanceMultiplier = 0
    for c in 0..<image.channels.count {
        let ch = image.channels[c]
        if ch.w == 0 || ch.h == 0 { continue }
        if isSkippedLargeChannel(c) { break }
        distanceMultiplier = max(distanceMultiplier, ch.w)
        numChans += 1
    }
    if numChans == 0 { return header }

    let reader = ANSSymbolReader(code: code, reader: br, distanceMultiplier: distanceMultiplier)
    let propCount = numProps(for: tree)

    for c in 0..<image.channels.count {
        let ch = image.channels[c]
        if ch.w == 0 || ch.h == 0 { continue }
        if isSkippedLargeChannel(c) { break }
        decodeChannel(
            br, reader, contextMap: ctxMap, tree: tree, wpHeader: header.wpHeader,
            chan: c, groupID: groupID, image: image, propCount: propCount,
            usesLZ77: code.lz77.enabled)
        if !br.allReadsWithinBounds { throw ModularDecodeError.finalState }
    }

    if !reader.checkANSFinalState() { throw ModularDecodeError.finalState }
    return header
}

/// Decodes one AC group's large channels into `fullImage` at the group's rect
/// (libjxl ModularFrameDecoder::DecodeGroup, the use_full_image path). Single
/// pass => shift bracket [0, 2].
/// A decoded AC group's sub-image plus where each of its channels lands in the
/// full image. Produced by `decodeModularGroupImage` (safe to run concurrently
/// across groups), consumed by `blitModularGroup` (serial).
struct ModularGroupResult {
    let gi: ModularImage
    let mapping: [(fullC: Int, x: Int, y: Int, w: Int, h: Int)]
}

/// Decodes one AC group's large channels into a group-local sub-image (libjxl
/// ModularFrameDecoder::DecodeGroup, the use_full_image path). Single pass =>
/// shift bracket [0, 2]. Reads `fullImage` only for the channel layout, so
/// groups can decode concurrently; the writes happen in `blitModularGroup`.
func decodeModularGroupImage(
    _ br: BitReader, fullImage: ModularImage, group g: Int, dim: FrameDimensions,
    globalTree: [MATreeNode]?, globalCode: ANSCode?, globalCtxMap: [UInt8]?, streamID: Int,
    minShift: Int = 0, maxShift: Int = 2, dcGroup: Bool = false
) throws -> ModularGroupResult? {
    let groupDim = dim.groupDim
    // AC groups tile at group_dim; DC groups (shift >= 3 channels) at 8x that.
    let tile = dcGroup ? groupDim * 8 : groupDim
    let perRow = dcGroup ? dim.xsizeDCGroups : dim.xsizeGroups
    let rx0 = (g % perRow) * tile
    let ry0 = (g / perRow) * tile
    // The rect is NOT clamped to the image here: libjxl clamps per channel
    // against the channel's own (ceil-rounded, shifted) dimensions, which
    // differs from shifting an image-clamped rect for squeezed channels.
    let rectW = min(tile, dim.xsize - rx0)
    let rectH = min(tile, dim.ysize - ry0)

    // Skip meta + small (<= group_dim) channels, which were decoded globally.
    var beginC = fullImage.nbMetaChannels
    while beginC < fullImage.channels.count {
        let fc = fullImage.channels[beginC]
        if fc.w > groupDim || fc.h > groupDim { break }
        beginC += 1
    }

    let gi = ModularImage(w: rectW, h: rectH, bitdepth: fullImage.bitdepth, channelCount: 0)
    gi.channels = []
    var mapping: [(fullC: Int, x: Int, y: Int, w: Int, h: Int)] = []
    for c in beginC..<fullImage.channels.count {
        let fc = fullImage.channels[c]
        guard fc.hshift >= 0, fc.vshift >= 0 else { continue }
        let shift = min(fc.hshift, fc.vshift)
        if shift > maxShift || shift < minShift { continue }
        let rx = rx0 >> fc.hshift
        let ry = ry0 >> fc.vshift
        let rw = min(tile >> fc.hshift, fc.w - rx)
        let rh = min(tile >> fc.vshift, fc.h - ry)
        if rw <= 0 || rh <= 0 { continue }
        gi.channels.append(ModularChannel(w: rw, h: rh, hshift: fc.hshift, vshift: fc.vshift))
        mapping.append((c, rx, ry, rw, rh))
    }
    if gi.channels.isEmpty { return nil }

    let header = try modularDecode(
        br, image: gi, groupID: streamID, globalTree: globalTree, globalCode: globalCode,
        globalCtxMap: globalCtxMap)
    try undoTransforms(gi, transforms: header.transforms, wpHeader: header.wpHeader)
    return ModularGroupResult(gi: gi, mapping: mapping)
}

/// Copies a decoded group sub-image into the full image at its rects. Mutates
/// the destination plane in place (no COW copy of the full-size channel).
func blitModularGroup(_ result: ModularGroupResult, into fullImage: ModularImage) {
    for (gic, m) in result.mapping.enumerated() {
        let srcW = result.gi.channels[gic].w
        let dstW = fullImage.channels[m.fullC].w
        result.gi.channels[gic].pixels.withUnsafeBufferPointer { s in
            fullImage.channels[m.fullC].pixels.withUnsafeMutableBufferPointer { d in
                for yy in 0..<m.h {
                    let dstBase = (m.y + yy) * dstW + m.x
                    let srcBase = yy * srcW
                    for xx in 0..<m.w { d[dstBase + xx] = s[srcBase + xx] }
                }
            }
        }
    }
}
