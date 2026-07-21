// TreeBuilder.swift
//
// Learned MA trees (E4 of docs/encoder-design.md). Greedy top-down tree
// learning over the decoder's properties 0..14 (the non-WP set) with per-leaf
// predictor selection, producing trees directly in the DECODER'S
// [MATreeNode] representation — the per-pixel tokenizer then walks that
// exact structure with decodeChannel's property arithmetic (including the
// props[8]/props[9] previous-pixel sequencing and the gradientClamp
// fast-track variant), so encode/decode context and prediction divergence is
// structurally impossible.
//
// Cost model: the split criterion is the entropy of the hybrid-uint token
// histograms (what actually gets coded), not raw residual variance.

import Foundation

/// Candidate predictors: every stateless predictOne case (6 = Weighted needs
/// WP state and is deliberately excluded at this milestone).
private let kCandidatePredictors: [Int] = [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13]

/// Candidate split properties: 0 = channel, 2..14 = position + neighborhood.
/// 1 (stream/group id) and 15 (WP) are excluded; >= 16 (reference channels)
/// are not collected.
private let kCandidateProperties: [Int] = [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

private let kNumProps = 15
private let kMaxLeaves = 48
private let kMinLeafSamples = 256
/// Bits a split must save to be worth its serialization + histogram overhead.
private let kSplitGainBits = 250.0

// MARK: - Training sample collection

/// Struct-of-arrays training set: per sample, the 15 property values and the
/// hybrid-uint token each candidate predictor would produce.
struct TreeTrainingSet {
    var props: [Int32] = []  // count * kNumProps
    var tokens: [UInt8] = []  // count * kCandidatePredictors.count
    var count = 0

    /// Collects samples from one channel rect (group-local coordinates, like
    /// the decoder's per-group sub-images). `stride` subsamples pixels.
    /// Collection uses the generic (wrapping) property arithmetic — the
    /// fast-track clamp variant only exists once a tree is chosen, and only
    /// affects cost estimates here, never correctness.
    mutating func collect(
        plane: [Int32], width: Int, x0: Int, y0: Int, gw: Int, gh: Int,
        chan: Int, stride: Int
    ) {
        plane.withUnsafeBufferPointer { px in
            var i = 0
            for y in 0..<gh {
                let row = (y0 + y) * width + x0
                let prev = row - width
                for x in 0..<gw {
                    defer { i += 1 }
                    if i % stride != 0 { continue }
                    let n = neighborhoodAt(
                        px, row: row, prev: prev, width: width, x: x, y: y, gw: gw)
                    // Previous pixel's props[9] (0 at row start), generic wrap.
                    var prop9prev: Int32 = 0
                    if x > 0 {
                        let np = neighborhoodAt(
                            px, row: row, prev: prev, width: width, x: x - 1, y: y, gw: gw)
                        prop9prev = Int32(truncatingIfNeeded: np.left + np.top - np.topleft)
                    }
                    props.append(Int32(truncatingIfNeeded: chan))
                    props.append(0)  // property 1 (stream id): never split on
                    props.append(Int32(truncatingIfNeeded: y))
                    props.append(Int32(truncatingIfNeeded: x))
                    props.append(Int32(truncatingIfNeeded: abs(n.top)))
                    props.append(Int32(truncatingIfNeeded: abs(n.left)))
                    props.append(Int32(truncatingIfNeeded: n.top))
                    props.append(Int32(truncatingIfNeeded: n.left))
                    props.append(Int32(truncatingIfNeeded: n.left) &- prop9prev)
                    props.append(Int32(truncatingIfNeeded: n.left + n.top - n.topleft))
                    props.append(Int32(truncatingIfNeeded: n.left - n.topleft))
                    props.append(Int32(truncatingIfNeeded: n.topleft - n.top))
                    props.append(Int32(truncatingIfNeeded: n.top - n.topright))
                    props.append(Int32(truncatingIfNeeded: n.top - n.toptop))
                    props.append(Int32(truncatingIfNeeded: n.left - n.leftleft))
                    let v = Int(px[row + x])
                    for p in kCandidatePredictors {
                        let guess = predictOne(
                            p, left: n.left, top: n.top, toptop: n.toptop,
                            topleft: n.topleft, topright: n.topright, leftleft: n.leftleft,
                            toprightright: n.toprightright, wpPred: 0)
                        let (token, _, _) = encUintConfig.encode(encPackSigned(v - guess))
                        tokens.append(UInt8(truncatingIfNeeded: token))
                    }
                    count += 1
                }
            }
        }
    }
}

private struct Neighborhood {
    var left: Int
    var top: Int
    var topleft: Int
    var topright: Int
    var leftleft: Int
    var toptop: Int
    var toprightright: Int
}

@inline(__always)
func encPackSigned(_ d: Int) -> UInt32 {
    d >= 0 ? UInt32(truncatingIfNeeded: 2 * d) : UInt32(truncatingIfNeeded: -2 * d - 1)
}

// MARK: - Greedy tree learning

/// A learned tree in build form; converted to decoder layout afterwards.
private final class BuildNode {
    var property = -1  // -1 = leaf
    var splitVal: Int32 = 0
    var left: BuildNode? = nil
    var right: BuildNode? = nil
    var predictor = 5
}

// Hybrid-uint (4,2,0) tokens for any UInt32 stay < 128 (n=31 → 16+108+3).
private let kNumTokenBins = 128

/// Raw extra bits the (4,2,0) hybrid-uint config attaches to a token.
@inline(__always)
private func extraBitsForToken(_ t: Int) -> Double {
    t < 16 ? 0 : Double(2 + ((t - 16) >> 2))
}

/// True coded cost of a token histogram: Shannon entropy of the tokens PLUS
/// the raw extra bits they carry. Entropy alone is blind to extra bits and
/// mis-ranks predictors (e.g. Zero on a constant plane: entropy 0 but 11
/// extra bits per pixel vs Gradient's genuinely free zero residual).
private func entropyBits(_ hist: UnsafeMutablePointer<UInt32>, _ n: Int) -> Double {
    var total = 0.0
    var sum = 0.0
    var extra = 0.0
    for t in 0..<n {
        let c = Double(hist[t])
        if c > 0 {
            total += c
            sum += c * log2(c)
            extra += c * extraBitsForToken(t)
        }
    }
    if total == 0 { return 0 }
    return total * log2(total) - sum + extra
}

/// Learns a tree over the training set. Returns the tree in the DECODER'S
/// node layout (level-order, as decodeMATree builds it), ready for both
/// serialization and tokenization. A degenerate result is the single
/// Gradient leaf.
func learnTree(_ training: TreeTrainingSet) -> [MATreeNode] {
    let root = BuildNode()
    let numPred = kCandidatePredictors.count
    if training.count >= kMinLeafSamples * 2 {
        var leaves = 1
        training.props.withUnsafeBufferPointer { propsBuf in
            training.tokens.withUnsafeBufferPointer { tokBuf in
                let props = propsBuf.baseAddress!
                let toks = tokBuf.baseAddress!

                // Scratch histograms.
                let histSize = numPred * kNumTokenBins
                let nodeHist = UnsafeMutablePointer<UInt32>.allocate(capacity: histSize)
                let sideHist = UnsafeMutablePointer<UInt32>.allocate(capacity: histSize)
                defer {
                    nodeHist.deallocate()
                    sideHist.deallocate()
                }

                func leafCost(_ samples: [Int32]) -> (cost: Double, predictor: Int) {
                    nodeHist.update(repeating: 0, count: histSize)
                    for s in samples {
                        let base = Int(s) * numPred
                        for p in 0..<numPred {
                            nodeHist[p * kNumTokenBins + Int(toks[base + p])] += 1
                        }
                    }
                    var best = Double.infinity
                    var bestP = 5
                    for p in 0..<numPred {
                        let e = entropyBits(nodeHist + p * kNumTokenBins, kNumTokenBins)
                        if e < best {
                            best = e
                            bestP = kCandidatePredictors[p]
                        }
                    }
                    return (best, bestP)
                }

                // Bucketed split search: per property, ONE pass buckets every
                // sample by quantile boundary (binary search), accumulating
                // per-bucket per-predictor token histograms; suffix sums then
                // evaluate every boundary. Left = prop > boundary (decoder
                // branch rule).
                let kMaxBoundaries = 24
                let bucketHist = UnsafeMutablePointer<UInt32>.allocate(
                    capacity: (kMaxBoundaries + 1) * numPred * kNumTokenBins)
                let bucketCount = UnsafeMutablePointer<Int>.allocate(capacity: kMaxBoundaries + 1)
                defer {
                    bucketHist.deallocate()
                    bucketCount.deallocate()
                }

                func split(_ node: BuildNode, _ samples: [Int32], depth: Int) {
                    let (baseCost, bestPred) = leafCost(samples)
                    node.predictor = bestPred
                    if depth >= 10 || leaves >= kMaxLeaves
                        || samples.count < 2 * kMinLeafSamples || baseCost < kSplitGainBits
                    {
                        return
                    }

                    var bestGain = kSplitGainBits
                    var bestProp = -1
                    var bestSplit: Int32 = 0
                    for prop in kCandidateProperties {
                        // Boundary candidates: quantiles from a value subsample.
                        var quantSample: [Int32] = []
                        let qStride = max(1, samples.count / 4096)
                        var qi = 0
                        while qi < samples.count {
                            quantSample.append(props[Int(samples[qi]) * kNumProps + prop])
                            qi += qStride
                        }
                        quantSample.sort()
                        var boundaries: [Int32] = []
                        for q in 1..<(kMaxBoundaries + 1) {
                            let v = quantSample[quantSample.count * q / (kMaxBoundaries + 1)]
                            if v != quantSample[quantSample.count - 1]
                                && (boundaries.isEmpty || v != boundaries.last!)
                            {
                                boundaries.append(v)
                            }
                        }
                        if boundaries.isEmpty { continue }
                        let nb = boundaries.count

                        // Single pass: bucket(v) = #boundaries < v via binary
                        // search; accumulate histograms + counts per bucket.
                        bucketHist.update(repeating: 0, count: (nb + 1) * numPred * kNumTokenBins)
                        bucketCount.update(repeating: 0, count: nb + 1)
                        for s in samples {
                            let v = props[Int(s) * kNumProps + prop]
                            var lo = 0
                            var hi = nb
                            while lo < hi {
                                let mid = (lo + hi) / 2
                                if boundaries[mid] < v { lo = mid + 1 } else { hi = mid }
                            }
                            let bucket = lo
                            bucketCount[bucket] += 1
                            let dst = bucketHist + bucket * numPred * kNumTokenBins
                            let base = Int(s) * numPred
                            for p in 0..<numPred {
                                dst[p * kNumTokenBins + Int(toks[base + p])] += 1
                            }
                        }

                        // Sweep boundaries high→low: left(b_j) = buckets > j.
                        nodeHist.update(repeating: 0, count: histSize)  // running left
                        var nLeft = 0
                        for j in stride(from: nb - 1, through: 0, by: -1) {
                            // Fold bucket j+1 into the left accumulator.
                            let src = bucketHist + (j + 1) * numPred * kNumTokenBins
                            for t in 0..<histSize { nodeHist[t] += src[t] }
                            nLeft += bucketCount[j + 1]
                            let nRight = samples.count - nLeft
                            if nLeft < kMinLeafSamples || nRight < kMinLeafSamples { continue }
                            // Right histograms = node totals − left; node totals
                            // live in the leafCost scratch? Recompute via
                            // sideHist = total − left, built from bucket sums.
                            var leftBest = Double.infinity
                            var rightBest = Double.infinity
                            for p in 0..<numPred {
                                let lh = nodeHist + p * kNumTokenBins
                                leftBest = min(leftBest, entropyBits(lh, kNumTokenBins))
                                let rh = sideHist + p * kNumTokenBins
                                for t in 0..<kNumTokenBins { rh[t] = 0 }
                                for b in 0...j {
                                    let bh = bucketHist + (b * numPred + p) * kNumTokenBins
                                    for t in 0..<kNumTokenBins { rh[t] += bh[t] }
                                }
                                rightBest = min(rightBest, entropyBits(rh, kNumTokenBins))
                            }
                            let gain = baseCost - leftBest - rightBest
                            if gain > bestGain {
                                bestGain = gain
                                bestProp = prop
                                bestSplit = boundaries[j]
                            }
                        }
                    }
                    guard bestProp >= 0 else { return }

                    node.property = bestProp
                    node.splitVal = bestSplit
                    let l = BuildNode()
                    let r = BuildNode()
                    node.left = l
                    node.right = r
                    leaves += 1
                    var leftSamples: [Int32] = []
                    var rightSamples: [Int32] = []
                    for s in samples {
                        if props[Int(s) * kNumProps + bestProp] > bestSplit {
                            leftSamples.append(s)
                        } else {
                            rightSamples.append(s)
                        }
                    }
                    split(l, leftSamples, depth: depth + 1)
                    split(r, rightSamples, depth: depth + 1)
                }

                split(root, Array(0..<Int32(training.count)), depth: 0)
            }
        }
    }
    return flattenToDecoderLayout(root)
}

/// Flattens a build tree into the decoder's level-order [MATreeNode] layout —
/// the exact array decodeMATree would produce, so array order IS the token
/// serialization order and leaf ids follow decode order.
private func flattenToDecoderLayout(_ root: BuildNode) -> [MATreeNode] {
    var tree: [MATreeNode] = []
    var queue: [BuildNode] = [root]
    var leafID = 0
    var qi = 0
    while qi < queue.count {
        let node = queue[qi]
        qi += 1
        if node.property == -1 {
            tree.append(
                MATreeNode(
                    property: -1, splitVal: 0, lchild: leafID, rchild: 0,
                    predictor: node.predictor, predictorOffset: 0, multiplier: 1))
            leafID += 1
        } else {
            // Children land at the end of the current queue, which in
            // level-order is exactly tree.count + pending + 1/2 — the same
            // positions decodeMATree assigns.
            tree.append(
                MATreeNode(
                    property: node.property, splitVal: node.splitVal,
                    lchild: queue.count, rchild: queue.count + 1,
                    predictor: 0, predictorOffset: 0, multiplier: 1))
            queue.append(node.left!)
            queue.append(node.right!)
        }
    }
    return tree
}

// MARK: - Tree serialization

/// Tree token stream in decodeMATree's read order: iterate the level-order
/// array; splits emit (property+1, packSigned(splitVal)); leaves emit
/// (0, predictor, offset, mul_log, mul_bits). Contexts are the decoder's
/// MATreeContext indices.
func treeTokens(_ tree: [MATreeNode]) -> [EncToken] {
    var tokens: [EncToken] = []
    for node in tree {
        if node.isLeaf {
            tokens.append(EncToken(ctx: 1, value: 0))  // kPropertyContext: leaf
            tokens.append(EncToken(ctx: 2, value: UInt32(node.predictor)))
            tokens.append(EncToken(ctx: 3, value: encPackSigned(Int(node.predictorOffset))))
            tokens.append(EncToken(ctx: 4, value: 0))  // mul_log
            tokens.append(EncToken(ctx: 5, value: 0))  // mul_bits
        } else {
            tokens.append(EncToken(ctx: 1, value: UInt32(node.property + 1)))
            tokens.append(EncToken(ctx: 0, value: encPackSigned(Int(node.splitVal))))
        }
    }
    return tokens
}

/// Leaf count == residual raw-context count ((tree.count + 1) / 2).
func treeNumLeaves(_ tree: [MATreeNode]) -> Int { (tree.count + 1) / 2 }

// MARK: - Tree-walking tokenization (decodeChannel's dual)

private let kEncPropRangeFast: Int64 = 512 << 4  // 8192

/// Tokenizes one channel rect with a learned tree, mirroring decodeChannel's
/// per-pixel property computation exactly: group-local borders, the
/// props[8] = W − previous-pixel-props[9] sequencing, Int32 wrapping — and
/// the gradientClamp fast-track arithmetic when the decoder would select that
/// kernel for this (tree, channel, stream) combination.
func tokenizeChannelWithTree(
    into tokens: inout [EncToken],
    plane: [Int32], width: Int, x0: Int, y0: Int, gw: Int, gh: Int,
    chan: Int, streamID: Int, tree: [MATreeNode]
) {
    let fastTrack = channelFastTrack(
        tree: tree, chan: chan, groupID: streamID, usesLZ77: false, width: gw)
    var props = [Int32](repeating: 0, count: kNumProps + 1)  // slot 15 unused (no WP)
    props[0] = Int32(truncatingIfNeeded: chan)
    props[1] = Int32(truncatingIfNeeded: streamID)
    plane.withUnsafeBufferPointer { px in
        tree.withUnsafeBufferPointer { treeBuf in
            let treeP = treeBuf.baseAddress!
            for y in 0..<gh {
                props[2] = Int32(truncatingIfNeeded: y)
                props[9] = 0
                let row = (y0 + y) * width + x0
                let prev = row - width
                for x in 0..<gw {
                    let n = neighborhoodAt(px, row: row, prev: prev, width: width, x: x, y: y, gw: gw)
                    props[3] = Int32(truncatingIfNeeded: x)
                    props[4] = Int32(truncatingIfNeeded: abs(n.top))
                    props[5] = Int32(truncatingIfNeeded: abs(n.left))
                    props[6] = Int32(truncatingIfNeeded: n.top)
                    props[7] = Int32(truncatingIfNeeded: n.left)
                    props[8] = Int32(truncatingIfNeeded: n.left) &- props[9]
                    if fastTrack == .gradientClamp {
                        let g = Int64(n.left) + Int64(n.top) - Int64(n.topleft)
                        props[9] = Int32(min(max(g, -kEncPropRangeFast), kEncPropRangeFast - 1))
                    } else {
                        props[9] = Int32(truncatingIfNeeded: n.left + n.top - n.topleft)
                    }
                    props[10] = Int32(truncatingIfNeeded: n.left - n.topleft)
                    props[11] = Int32(truncatingIfNeeded: n.topleft - n.top)
                    props[12] = Int32(truncatingIfNeeded: n.top - n.topright)
                    props[13] = Int32(truncatingIfNeeded: n.top - n.toptop)
                    props[14] = Int32(truncatingIfNeeded: n.left - n.leftleft)

                    var pos = 0
                    while treeP[pos].property != -1 {
                        let node = treeP[pos]
                        pos = props[node.property] > node.splitVal ? node.lchild : node.rchild
                    }
                    let leaf = treeP[pos]
                    let guess =
                        Int(leaf.predictorOffset)
                        + predictOne(
                            leaf.predictor, left: n.left, top: n.top, toptop: n.toptop,
                            topleft: n.topleft, topright: n.topright, leftleft: n.leftleft,
                            toprightright: n.toprightright, wpPred: 0)
                    let d = Int(px[row + x]) - guess
                    tokens.append(EncToken(ctx: UInt32(leaf.lchild), value: encPackSigned(d)))
                }
            }
        }
    }
}

/// decodeChannel's border semantics against the full-width plane, with the
/// rect's group-local edges.
@inline(__always)
private func neighborhoodAt(
    _ px: UnsafeBufferPointer<Int32>, row: Int, prev: Int, width: Int, x: Int, y: Int, gw: Int
) -> Neighborhood {
    let left = x > 0 ? Int(px[row + x - 1]) : (y > 0 ? Int(px[prev + x]) : 0)
    let top = y > 0 ? Int(px[prev + x]) : left
    let topleft = (x > 0 && y > 0) ? Int(px[prev + x - 1]) : left
    let topright = (x + 1 < gw && y > 0) ? Int(px[prev + x + 1]) : top
    let leftleft = x > 1 ? Int(px[row + x - 2]) : left
    let toptop = y > 1 ? Int(px[prev - width + x]) : top
    let toprightright = (x + 2 < gw && y > 0) ? Int(px[prev + x + 2]) : topright
    return Neighborhood(
        left: left, top: top, topleft: topleft, topright: topright,
        leftleft: leftleft, toptop: toptop, toprightright: toprightright)
}
