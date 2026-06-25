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

struct ModularTransform {
    var id: TransformId = .rct
    var beginC: UInt32 = 0
    var rctType: UInt32 = 6
    var numC: UInt32 = 3
    var nbColors: UInt32 = 256
    var nbDeltas: UInt32 = 0
    var predictor: UInt32 = 0
    var numSqueezes: UInt32 = 0
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
            t.numSqueezes = readU32(.value(0), .bits(4, offset: 1), .bits(6, offset: 9), .bits(8, offset: 41))
            for _ in 0..<t.numSqueezes {
                // SqueezeParams: horizontal(1) + in_place(1) + begin_c(U32) + num_c(U32)
                _ = read(1)
                _ = read(1)
                _ = readU32(.bits(3), .bits(6, offset: 8), .bits(10, offset: 72), .bits(13, offset: 1096))
                _ = readU32(.value(1), .value(2), .value(3), .bits(4, offset: 4))
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

/// Decodes one channel's samples (the general PredictTreeWP path).
private func decodeChannel(
    _ br: BitReader, _ reader: ANSSymbolReader, contextMap: [UInt8], tree: [MATreeNode],
    wpHeader: WPHeader, chan: Int, groupID: Int, image: ModularImage, propCount: Int
) {
    let w = image.channels[chan].w
    let h = image.channels[chan].h
    if w == 0 || h == 0 { return }

    let refCount = propCount - kNumNonrefProperties
    let references = refCount > 0 ? precomputeReferenceChannels(image: image, chan: chan, refCount: refCount) : []

    let wpState = WPState(header: wpHeader, xsize: w, ysize: h)
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
                props[9] = Int32(truncatingIfNeeded: left + top - topleft)
                props[10] = Int32(truncatingIfNeeded: left - topleft)
                props[11] = Int32(truncatingIfNeeded: topleft - top)
                props[12] = Int32(truncatingIfNeeded: top - topright)
                props[13] = Int32(truncatingIfNeeded: top - toptop)
                props[14] = Int32(truncatingIfNeeded: left - leftleft)

                let wpPred = wpState.predict(
                    x: x, y: y, xsize: w, N: top, W: left, NE: topright, NW: topleft, NN: toptop,
                    computeProperties: true, properties: &props, offset: 15)

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
                wpState.updateErrors(Int(px[rowBase + x]), x: x, y: y, xsize: w)
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
    while j >= 0 && offset + kExtraPropsPerChannel <= refCount {
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
                refs[offset + 1][base] = Int32(truncatingIfNeeded: v)
                refs[offset + 2][base] = Int32(truncatingIfNeeded: abs(v - grad))
                refs[offset + 3][base] = Int32(truncatingIfNeeded: v - grad)
            }
        }
        offset += kExtraPropsPerChannel
        j -= 1
    }
    return refs
}

enum ModularDecodeError: Error { case unsupportedTransform, badGroupHeader, badTree, finalState }

/// Decodes a Modular image stream into `image` (libjxl ModularDecode), using a
/// pre-decoded global tree/code when `header.use_global_tree` is set.
func modularDecode(
    _ br: BitReader, image: ModularImage, groupID: Int,
    globalTree: [MATreeNode]?, globalCode: ANSCode?, globalCtxMap: [UInt8]?
) throws {
    guard let header = readGroupHeader(br) else { throw ModularDecodeError.badGroupHeader }
    // RCT and an empty transform list keep the channel layout unchanged; other
    // transforms change it and aren't applied yet.
    for t in header.transforms where t.id != .rct {
        throw ModularDecodeError.unsupportedTransform
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

    let distanceMultiplier = image.channels.map { $0.w }.max() ?? 0
    let reader = ANSSymbolReader(code: code, reader: br, distanceMultiplier: distanceMultiplier)
    let propCount = numProps(for: tree)

    for c in 0..<image.channels.count {
        decodeChannel(
            br, reader, contextMap: ctxMap, tree: tree, wpHeader: header.wpHeader,
            chan: c, groupID: groupID, image: image, propCount: propCount)
        if !br.allReadsWithinBounds { throw ModularDecodeError.finalState }
    }

    if !reader.checkANSFinalState() { throw ModularDecodeError.finalState }
}
