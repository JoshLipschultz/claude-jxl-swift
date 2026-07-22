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

/// Candidate predictors: every predictOne case. 6 (Weighted) is listed LAST:
/// leaf selection keeps the first predictor on cost ties, so WP — which
/// forces the decoder to run the expensive error-window state machine — only
/// wins when strictly better.
private let kCandidatePredictors: [Int] = [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 6]

/// Candidate split properties: 0 = channel, 2..14 = position + neighborhood,
/// 15 = WP error property. 1 (stream/group id) is excluded; >= 16 (reference
/// channels) are not collected.
private let kCandidateProperties: [Int] = [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

private let kNumProps = 16
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
    /// the decoder's per-group sub-images). `stride` subsamples which pixels
    /// are RECORDED — the WP state machine runs over every pixel regardless
    /// (its error window carries across the whole rect in scan order).
    /// Collection uses the generic (wrapping) property arithmetic — the
    /// fast-track clamp variants only exist once a tree is chosen, and only
    /// affect cost estimates here, never correctness.
    mutating func collect(
        plane px: UnsafeBufferPointer<Int32>, width: Int, x0: Int, y0: Int, gw: Int, gh: Int,
        chan: Int, stride: Int
    ) {
        let wp = WPState(header: WPHeader(), xsize: gw, ysize: gh)
        let wpProp = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { wpProp.deallocate() }
        do {
            var i = 0
            for y in 0..<gh {
                let row = (y0 + y) * width + x0
                let prev = row - width
                for x in 0..<gw {
                    defer { i += 1 }
                    let n = neighborhoodAt(
                        px, row: row, prev: prev, width: width, x: x, y: y, gw: gw)
                    let v = Int(px[row + x])
                    let wpPred = wp.predict(
                        x: x, y: y, xsize: gw, N: n.top, W: n.left, NE: n.topright,
                        NW: n.topleft, NN: n.toptop, computeProperties: true,
                        properties: wpProp, offset: 0)
                    defer { wp.updateErrors(v, x: x, y: y, xsize: gw) }
                    if i % stride != 0 { continue }
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
                    props.append(wpProp[0])
                    for p in kCandidatePredictors {
                        let guess = predictOne(
                            p, left: n.left, top: n.top, toptop: n.toptop,
                            topleft: n.topleft, topright: n.topright, leftleft: n.leftleft,
                            toprightright: n.toprightright, wpPred: wpPred)
                        // Residuals wrap to Int32 before packing (mod-2^32
                        // congruence is what the decoder reconstructs; matters
                        // for full-range float32 bit patterns).
                        let diff = Int32(truncatingIfNeeded: v - guess)
                        let (token, _, _) = encUintConfig.encode(encPackSigned(Int(diff)))
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

/// Process-lifetime x*log2(x) table: entry c holds exactly
/// `Double(c) * log2(Double(c))` — the same expression `entropyBits` would
/// otherwise evaluate — so replacing the computation with a load is
/// bit-identical. Raw pointer per the concurrentPerform rules (entropyBits
/// runs inside the parallel property search).
private let kXlogXSize = 1 << 16
nonisolated(unsafe) private let kXlogX: UnsafePointer<Double> = {
    let p = UnsafeMutablePointer<Double>.allocate(capacity: kXlogXSize)
    p[0] = 0
    for c in 1..<kXlogXSize { p[c] = Double(c) * log2(Double(c)) }
    return UnsafePointer(p)
}()

/// True coded cost of a token histogram: Shannon entropy of the tokens PLUS
/// the raw extra bits they carry. Entropy alone is blind to extra bits and
/// mis-ranks predictors (e.g. Zero on a constant plane: entropy 0 but 11
/// extra bits per pixel vs Gradient's genuinely free zero residual).
/// Accumulation order (bin-ascending, three separate accumulators) is the
/// original sequential order — the table only replaces `c * log2(c)` with a
/// precomputed copy of the identical double.
private func entropyBits(_ hist: UnsafePointer<UInt32>, _ n: Int) -> Double {
    var total = 0.0
    var sum = 0.0
    var extra = 0.0
    for t in 0..<n {
        let ci = Int(hist[t])
        if ci > 0 {
            let c = Double(ci)
            total += c
            sum += ci < kXlogXSize ? kXlogX[ci] : c * log2(c)
            extra += c * extraBitsForToken(t)
        }
    }
    if total == 0 { return 0 }
    let ti = Int(total)
    let tlog = (ti < kXlogXSize && Double(ti) == total) ? kXlogX[ti] : total * log2(total)
    return tlog - sum + extra
}

private let kMaxBoundaries = 24
/// Quantile subsample bound: qStride = max(1, n/4096) keeps ceil(n/qStride)
/// below 2*4096 for every n.
private let kMaxQuantSamples = 2 * 4096

/// Sample-chunk fanout for the bucketing pass on big nodes: per-chunk grids
/// are folded in fixed chunk order, and counts are integer sums, so any
/// chunking produces exactly the single-pass histograms.
private let kSplitChunks = 8

/// Per-property scratch for the split search — one instance per candidate
/// property so the property evaluations can run concurrently. All raw
/// allocations (nothing refcounted crosses into concurrentPerform).
private struct SplitScratch {
    let bucketHist: UnsafeMutablePointer<UInt32>  // kSplitChunks * (kMaxBoundaries+1) * numPred * bins
    let bucketCount: UnsafeMutablePointer<Int>  // kSplitChunks * (kMaxBoundaries + 1)
    let leftHist: UnsafeMutablePointer<UInt32>  // numPred * bins (running left)
    let rightHist: UnsafeMutablePointer<UInt32>  // numPred * bins (total - left)
    let quant: UnsafeMutablePointer<Int32>  // kMaxQuantSamples
    let boundaries: UnsafeMutablePointer<Int32>  // kMaxBoundaries

    init(numPred: Int) {
        bucketHist = .allocate(
            capacity: kSplitChunks * (kMaxBoundaries + 1) * numPred * kNumTokenBins)
        bucketCount = .allocate(capacity: kSplitChunks * (kMaxBoundaries + 1))
        leftHist = .allocate(capacity: numPred * kNumTokenBins)
        rightHist = .allocate(capacity: numPred * kNumTokenBins)
        quant = .allocate(capacity: kMaxQuantSamples)
        boundaries = .allocate(capacity: kMaxBoundaries)
    }

    func deallocate() {
        bucketHist.deallocate()
        bucketCount.deallocate()
        leftHist.deallocate()
        rightHist.deallocate()
        quant.deallocate()
        boundaries.deallocate()
    }
}

/// Phase A of one property's evaluation: quantile boundary selection into
/// `scratch.boundaries`. Returns the boundary count (0 = nothing to split).
/// `propRow` is the property-major row for this property (propsT + prop*n) —
/// the transposed copy exists purely so these passes stream 4 bytes per
/// sample instead of a 64-byte struct line; values are identical.
private func splitBoundaries(
    prop: Int, samples: UnsafePointer<Int32>, sampleCount: Int,
    propRow: UnsafePointer<Int32>, scratch: SplitScratch
) -> Int {
    let qStride = max(1, sampleCount / 4096)
    var quantCount = 0
    var qi = 0
    while qi < sampleCount {
        scratch.quant[quantCount] = propRow[Int(samples[qi])]
        quantCount += 1
        qi += qStride
    }
    var quantBuf = UnsafeMutableBufferPointer(start: scratch.quant, count: quantCount)
    quantBuf.sort()
    var nb = 0
    for q in 1..<(kMaxBoundaries + 1) {
        let v = scratch.quant[quantCount * q / (kMaxBoundaries + 1)]
        if v != scratch.quant[quantCount - 1] && (nb == 0 || v != scratch.boundaries[nb - 1]) {
            scratch.boundaries[nb] = v
            nb += 1
        }
    }
    return nb
}

/// Phase B: buckets samples[from..<to] by binary search over the boundaries,
/// accumulating per-bucket per-predictor token histograms + counts into the
/// given chunk's region of the scratch (zeroed here first).
/// Phase B: buckets samples[from..<to] by binary search over the boundaries,
/// accumulating per-bucket per-predictor token histograms + counts into the
/// given chunk's region of the scratch (zeroed here first).
private func bucketizeSplitChunk(
    prop: Int, samples: UnsafePointer<Int32>, from: Int, to: Int,
    propRow: UnsafePointer<Int32>, toks: UnsafePointer<UInt8>,
    numPred: Int, nb: Int, scratch: SplitScratch, chunk: Int
) {
    let boundaries = scratch.boundaries
    let bucketHist = scratch.bucketHist + chunk * (kMaxBoundaries + 1) * numPred * kNumTokenBins
    let bucketCount = scratch.bucketCount + chunk * (kMaxBoundaries + 1)
    bucketHist.update(repeating: 0, count: (nb + 1) * numPred * kNumTokenBins)
    bucketCount.update(repeating: 0, count: nb + 1)
    for si in from..<to {
        let s = samples[si]
        let v = propRow[Int(s)]
        var lo = 0
        var hi = nb
        while lo < hi {
            let mid = (lo + hi) / 2
            if boundaries[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        bucketCount[lo] += 1
        let dst = bucketHist + lo * numPred * kNumTokenBins
        let base = Int(s) * numPred
        for p in 0..<numPred {
            dst[p * kNumTokenBins + Int(toks[base + p])] += 1
        }
    }
}

/// Phase C: folds chunk grids 1..<numChunks into chunk 0 (fixed order,
/// integer adds — exact), then sweeps the boundaries high→low. The returned
/// (gain, split) is selected exactly as the sequential search would within
/// this property: j swept high→low, strictly-greater-than-best updates
/// starting from kSplitGainBits.
///
/// The right-side histograms are node totals − running left (exact UInt32
/// counts, so identical to the old per-boundary suffix rebuild, without the
/// O(nb²) inner loop).
private func sweepSplitProperty(
    prop: Int, sampleCount: Int, numPred: Int,
    totalHist: UnsafePointer<UInt32>, baseCost: Double,
    nb: Int, numChunks: Int, scratch: SplitScratch
) -> (gain: Double, split: Int32, found: Bool) {
    let gridSize = (kMaxBoundaries + 1) * numPred * kNumTokenBins
    let bucketHist = scratch.bucketHist
    let bucketCount = scratch.bucketCount
    for c in 1..<max(1, numChunks) {
        let srcH = bucketHist + c * gridSize
        for t in 0..<((nb + 1) * numPred * kNumTokenBins) { bucketHist[t] += srcH[t] }
        let srcC = bucketCount + c * (kMaxBoundaries + 1)
        for b in 0..<(nb + 1) { bucketCount[b] += srcC[b] }
    }

    // Sweep boundaries high→low: left(b_j) = buckets > j, right = total − left.
    let histSize = numPred * kNumTokenBins
    let leftHist = scratch.leftHist
    let rightHist = scratch.rightHist
    leftHist.update(repeating: 0, count: histSize)
    var nLeft = 0
    var bestGain = kSplitGainBits
    var bestSplit: Int32 = 0
    var found = false
    for j in stride(from: nb - 1, through: 0, by: -1) {
        // Fold bucket j+1 into the left accumulator.
        let src = bucketHist + (j + 1) * numPred * kNumTokenBins
        for t in 0..<histSize { leftHist[t] += src[t] }
        nLeft += bucketCount[j + 1]
        let nRight = sampleCount - nLeft
        if nLeft < kMinLeafSamples || nRight < kMinLeafSamples { continue }
        var leftBest = Double.infinity
        var rightBest = Double.infinity
        for p in 0..<numPred {
            let lh = leftHist + p * kNumTokenBins
            leftBest = min(leftBest, entropyBits(lh, kNumTokenBins))
            let rh = rightHist + p * kNumTokenBins
            let th = totalHist + p * kNumTokenBins
            for t in 0..<kNumTokenBins { rh[t] = th[t] - lh[t] }
            rightBest = min(rightBest, entropyBits(rh, kNumTokenBins))
        }
        let gain = baseCost - leftBest - rightBest
        if gain > bestGain {
            bestGain = gain
            bestSplit = scratch.boundaries[j]
            found = true
        }
    }
    return (bestGain, bestSplit, found)
}

/// Single-chunk evaluation of one candidate property (phases A→B→C in
/// sequence). Pure function of its inputs plus private scratch — safe to run
/// concurrently across properties.
private func evaluateSplitProperty(
    prop: Int, samples: UnsafePointer<Int32>, sampleCount: Int,
    propRow: UnsafePointer<Int32>, toks: UnsafePointer<UInt8>, numPred: Int,
    totalHist: UnsafePointer<UInt32>, baseCost: Double, scratch: SplitScratch
) -> (gain: Double, split: Int32, found: Bool) {
    let nb = splitBoundaries(
        prop: prop, samples: samples, sampleCount: sampleCount, propRow: propRow,
        scratch: scratch)
    if nb == 0 { return (kSplitGainBits, 0, false) }
    bucketizeSplitChunk(
        prop: prop, samples: samples, from: 0, to: sampleCount, propRow: propRow,
        toks: toks, numPred: numPred, nb: nb, scratch: scratch, chunk: 0)
    return sweepSplitProperty(
        prop: prop, sampleCount: sampleCount, numPred: numPred, totalHist: totalHist,
        baseCost: baseCost, nb: nb, numChunks: 1, scratch: scratch)
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

                // Property-major transpose of the training properties: the
                // split search's per-property passes then stream 4 bytes per
                // sample instead of one 64-byte sample record per read.
                // Values are copies — every comparison sees identical Int32s.
                let n = training.count
                let propsT = UnsafeMutablePointer<Int32>.allocate(capacity: kNumProps * n)
                defer { propsT.deallocate() }
                do {
                    nonisolated(unsafe) let src = props
                    nonisolated(unsafe) let dst = propsT
                    let chunks = min(16, max(1, n / 65536))
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        let from = n * c / chunks
                        let to = n * (c + 1) / chunks
                        for s in from..<to {
                            let base = s * kNumProps
                            for p in 0..<kNumProps { dst[p * n + s] = src[base + p] }
                        }
                    }
                }

                // Scratch: node-total histograms + one private block per
                // candidate property (the property search runs concurrently;
                // each worker touches only its own block).
                let histSize = numPred * kNumTokenBins
                let nodeHist = UnsafeMutablePointer<UInt32>.allocate(capacity: histSize)
                var scratches: [SplitScratch] = []
                for _ in kCandidateProperties { scratches.append(SplitScratch(numPred: numPred)) }
                defer {
                    nodeHist.deallocate()
                    for s in scratches { s.deallocate() }
                }
                // Raw copies for the parallel workers (nothing refcounted
                // crosses into concurrentPerform).
                let candProps = UnsafeMutablePointer<Int>.allocate(
                    capacity: kCandidateProperties.count)
                let scratchPtr = UnsafeMutablePointer<SplitScratch>.allocate(
                    capacity: scratches.count)
                for (i, p) in kCandidateProperties.enumerated() { candProps[i] = p }
                for (i, s) in scratches.enumerated() { scratchPtr[i] = s }
                let results = UnsafeMutablePointer<(gain: Double, split: Int32, found: Bool)>
                    .allocate(capacity: kCandidateProperties.count)
                defer {
                    candProps.deallocate()
                    scratchPtr.deallocate()
                    results.deallocate()
                }

                func leafCost(_ samples: [Int32]) -> (cost: Double, predictor: Int) {
                    nodeHist.update(repeating: 0, count: histSize)
                    samples.withUnsafeBufferPointer { buf in
                        let sampP = buf.baseAddress!
                        let count = buf.count
                        if count >= 65536 {
                            // Chunk-parallel into per-chunk grids (borrowing
                            // the per-property rightHist scratch — the sweeps
                            // that also use it run strictly later), folded in
                            // chunk order: exact integer sums.
                            let numChunks = min(kSplitChunks, count / 32768)
                            nonisolated(unsafe) let scrP = scratchPtr
                            nonisolated(unsafe) let sp = sampP
                            nonisolated(unsafe) let toksP = toks
                            DispatchQueue.concurrentPerform(iterations: numChunks) { c in
                                let g = scrP[c].rightHist
                                g.update(repeating: 0, count: histSize)
                                for si in (count * c / numChunks)..<(count * (c + 1) / numChunks) {
                                    let base = Int(sp[si]) * numPred
                                    for p in 0..<numPred {
                                        g[p * kNumTokenBins + Int(toksP[base + p])] += 1
                                    }
                                }
                            }
                            for c in 0..<numChunks {
                                let g = scratchPtr[c].rightHist
                                for t in 0..<histSize { nodeHist[t] += g[t] }
                            }
                        } else {
                            for si in 0..<count {
                                let base = Int(sampP[si]) * numPred
                                for p in 0..<numPred {
                                    nodeHist[p * kNumTokenBins + Int(toks[base + p])] += 1
                                }
                            }
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

                func split(_ node: BuildNode, _ samples: [Int32], depth: Int) {
                    let (baseCost, bestPred) = leafCost(samples)
                    node.predictor = bestPred
                    if depth >= 10 || leaves >= kMaxLeaves
                        || samples.count < 2 * kMinLeafSamples || baseCost < kSplitGainBits
                    {
                        return
                    }
                    // leafCost left the node-total histograms in nodeHist —
                    // the sweep's right side is total − left.

                    let numProps = kCandidateProperties.count
                    samples.withUnsafeBufferPointer { samplesBuf in
                        let samplesP = samplesBuf.baseAddress!
                        let sampleCount = samplesBuf.count
                        if sampleCount >= 65536 {
                            // Big nodes, three phases so the expensive
                            // bucketing pass fans out over properties AND
                            // sample chunks (per-chunk grids folded in fixed
                            // order — exact integer sums). Results land in
                            // fixed slots; the reduce below runs in
                            // kCandidateProperties order — the same winner
                            // and tie-breaks as the sequential loop.
                            nonisolated(unsafe) let resultsP = results
                            nonisolated(unsafe) let candP = candProps
                            nonisolated(unsafe) let scrP = scratchPtr
                            nonisolated(unsafe) let propsTP = propsT
                            nonisolated(unsafe) let toksP = toks
                            nonisolated(unsafe) let totalP = nodeHist
                            nonisolated(unsafe) let sampP = samplesP
                            // Grid-zeroing costs ~179KB per (property, chunk):
                            // keep chunks big enough that it stays noise.
                            let numChunks = min(kSplitChunks, max(1, sampleCount / 32768))
                            let nbs = UnsafeMutablePointer<Int>.allocate(capacity: numProps)
                            defer { nbs.deallocate() }
                            nonisolated(unsafe) let nbsP = nbs
                            DispatchQueue.concurrentPerform(iterations: numProps) { i in
                                nbsP[i] = splitBoundaries(
                                    prop: candP[i], samples: sampP, sampleCount: sampleCount,
                                    propRow: propsTP + candP[i] * n, scratch: scrP[i])
                            }
                            DispatchQueue.concurrentPerform(
                                iterations: numProps * numChunks
                            ) { k in
                                let i = k / numChunks
                                let c = k % numChunks
                                if nbsP[i] == 0 { return }
                                bucketizeSplitChunk(
                                    prop: candP[i], samples: sampP,
                                    from: sampleCount * c / numChunks,
                                    to: sampleCount * (c + 1) / numChunks,
                                    propRow: propsTP + candP[i] * n, toks: toksP,
                                    numPred: numPred,
                                    nb: nbsP[i], scratch: scrP[i], chunk: c)
                            }
                            DispatchQueue.concurrentPerform(iterations: numProps) { i in
                                if nbsP[i] == 0 {
                                    resultsP[i] = (kSplitGainBits, 0, false)
                                    return
                                }
                                resultsP[i] = sweepSplitProperty(
                                    prop: candP[i], sampleCount: sampleCount, numPred: numPred,
                                    totalHist: totalP, baseCost: baseCost,
                                    nb: nbsP[i], numChunks: numChunks, scratch: scrP[i])
                            }
                        } else if sampleCount >= 4096 {
                            // Parallel across properties: each evaluation is
                            // independent (private scratch), results land in
                            // fixed slots, and the reduce below runs in
                            // kCandidateProperties order — the same winner and
                            // tie-breaks as the sequential loop.
                            nonisolated(unsafe) let resultsP = results
                            nonisolated(unsafe) let candP = candProps
                            nonisolated(unsafe) let scrP = scratchPtr
                            nonisolated(unsafe) let propsTP = propsT
                            nonisolated(unsafe) let toksP = toks
                            nonisolated(unsafe) let totalP = nodeHist
                            nonisolated(unsafe) let sampP = samplesP
                            DispatchQueue.concurrentPerform(iterations: numProps) { i in
                                resultsP[i] = evaluateSplitProperty(
                                    prop: candP[i], samples: sampP, sampleCount: sampleCount,
                                    propRow: propsTP + candP[i] * n, toks: toksP,
                                    numPred: numPred,
                                    totalHist: totalP, baseCost: baseCost, scratch: scrP[i])
                            }
                        } else {
                            for i in 0..<numProps {
                                results[i] = evaluateSplitProperty(
                                    prop: candProps[i], samples: samplesP,
                                    sampleCount: sampleCount,
                                    propRow: propsT + candProps[i] * n, toks: toks,
                                    numPred: numPred,
                                    totalHist: nodeHist, baseCost: baseCost,
                                    scratch: scratchPtr[i])
                            }
                        }
                    }

                    var bestGain = kSplitGainBits
                    var bestProp = -1
                    var bestSplit: Int32 = 0
                    for i in 0..<numProps {
                        let r = results[i]
                        if r.found && r.gain > bestGain {
                            bestGain = r.gain
                            bestProp = kCandidateProperties[i]
                            bestSplit = r.split
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
                    leftSamples.reserveCapacity(samples.count)
                    rightSamples.reserveCapacity(samples.count)
                    let bestRow = propsT + bestProp * n
                    for s in samples {
                        if bestRow[Int(s)] > bestSplit {
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
            // multiplier = (mul_bits + 1) << mul_log (decodeMATree).
            let mulLog = UInt32(node.multiplier.trailingZeroBitCount)
            tokens.append(EncToken(ctx: 4, value: mulLog))
            tokens.append(EncToken(ctx: 5, value: (node.multiplier >> mulLog) - 1))
        } else {
            tokens.append(EncToken(ctx: 1, value: UInt32(node.property + 1)))
            tokens.append(EncToken(ctx: 0, value: encPackSigned(Int(node.splitVal))))
        }
    }
    return tokens
}

/// Leaf count == residual raw-context count ((tree.count + 1) / 2).
func treeNumLeaves(_ tree: [MATreeNode]) -> Int { (tree.count + 1) / 2 }

// MARK: - Leaf multipliers

/// Per-leaf residual GCDs over every stream's tokens. When a leaf's residuals
/// share a common factor g > 1 (e.g. 16-bit content that is a scaled ramp —
/// every sample a multiple of 100), the leaf multiplier divides them: the
/// decoder computes unpackSigned(v) * multiplier + guess, so the coded values
/// shrink by log2(g) bits each. Returns nil when no leaf benefits.
func treeWithLeafMultipliers(
    _ tree: [MATreeNode], streams: [[EncToken]]
) -> [MATreeNode]? {
    let numLeaves = treeNumLeaves(tree)
    var gcds = [Int64](repeating: 0, count: numLeaves)
    // Leaves whose gcd has reached 1 can never leave it (gcd(1, d) == 1), so
    // they are skipped; once EVERY leaf is at 1 the whole scan is settled
    // (the final guard below would return nil) and the remaining token walk
    // is pure waste — typical photographic content settles within a few
    // thousand tokens of an 18M-token stream set.
    var active = numLeaves
    outer: for stream in streams {
        for t in stream {
            let c = Int(t.ctx)
            let old = gcds[c]
            if old == 1 { continue }
            var d = unpackSigned(t.value)
            if d < 0 { d = -d }
            var a = old
            var b = d
            while b != 0 {
                (a, b) = (b, a % b)
            }
            gcds[c] = a
            if a == 1 {
                active -= 1
                if active == 0 { break outer }
            }
        }
    }
    // Multiplier fits the serialization guards for any g < 2^31; all-zero
    // leaves (gcd 0) stay at 1.
    guard gcds.contains(where: { $0 > 1 && $0 < (1 << 31) }) else { return nil }
    var out = tree
    for i in out.indices where out[i].isLeaf {
        let g = gcds[out[i].lchild]
        if g > 1 && g < (1 << 31) { out[i].multiplier = UInt32(g) }
    }
    return out
}

/// Divides every token's residual by its leaf's multiplier. Returns nil if
/// any residual is not divisible — possible when the multiplier tree routes a
/// pixel to a different leaf than the gcd pass did (the clamp fast-tracks
/// require multiplier-1 leaves, so adding multipliers can change kernels);
/// callers then fall back to the multiplier-free tree.
func divideByLeafMultipliers(
    _ tree: [MATreeNode], streams: [[EncToken]]
) -> [[EncToken]]? {
    var mults = [Int64](repeating: 1, count: treeNumLeaves(tree))
    for node in tree where node.isLeaf { mults[node.lchild] = Int64(node.multiplier) }
    var out = streams
    for s in out.indices {
        for i in out[s].indices {
            let m = mults[Int(out[s][i].ctx)]
            if m == 1 { continue }
            let d = unpackSigned(out[s][i].value)
            if d % m != 0 { return nil }
            let q = d / m
            out[s][i].value = encPackSigned(Int(q))
        }
    }
    return out
}

// MARK: - Tree-walking tokenization (decodeChannel's dual)

private let kEncPropRangeFast: Int64 = 512 << 4  // 8192

/// Tokenizes one channel rect with a learned tree, mirroring decodeChannel's
/// per-pixel property computation exactly: group-local borders, the
/// props[8] = W − previous-pixel-props[9] sequencing, Int32 wrapping — and
/// the gradientClamp fast-track arithmetic when the decoder would select that
/// kernel for this (tree, channel, stream) combination.
func tokenizeChannelWithTree(
    into tokens: inout [EncToken],
    plane px: UnsafeBufferPointer<Int32>, width: Int, x0: Int, y0: Int, gw: Int, gh: Int,
    chan: Int, streamID: Int, tree: [MATreeNode]
) {
    // Output slots are extended once and filled through a raw pointer — the
    // per-pixel `append` paid growth checks and exclusivity per token.
    let start = tokens.count
    tokens.append(
        contentsOf: repeatElement(EncToken(ctx: 0, value: 0), count: gw * gh))
    // Single-leaf shortcut (the whole of effort 1): no properties are ever
    // read, so the props vector, its per-pixel arithmetic, and the tree walk
    // all vanish — only the neighborhood, the leaf's predictor, and the pack
    // remain, which is exactly what the general loop would compute for this
    // tree. (A WP leaf still takes the general path for its state machine.)
    if tree.count == 1 && tree[0].predictor != 6 {
        let leaf = tree[0]
        let pred = leaf.predictor
        let off = Int(leaf.predictorOffset)
        let ctx = UInt32(leaf.lchild)
        tokens.withUnsafeMutableBufferPointer { outBuf in
            var w = start
            for y in 0..<gh {
                let row = (y0 + y) * width + x0
                let prev = row - width
                for x in 0..<gw {
                    let n = neighborhoodAt(
                        px, row: row, prev: prev, width: width, x: x, y: y, gw: gw)
                    let guess =
                        off
                        + predictOne(
                            pred, left: n.left, top: n.top, toptop: n.toptop,
                            topleft: n.topleft, topright: n.topright, leftleft: n.leftleft,
                            toprightright: n.toprightright, wpPred: 0)
                    let d = Int32(truncatingIfNeeded: Int(px[row + x]) - guess)
                    outBuf[w] = EncToken(ctx: ctx, value: encPackSigned(Int(d)))
                    w += 1
                }
            }
        }
        return
    }
    let fastTrack = channelFastTrack(
        tree: tree, chan: chan, groupID: streamID, usesLZ77: false, width: gw)
    // WP runs only when the tree can observe it — the decoder's
    // TreeToLookupTable use_wp gate; running it otherwise would be wasted
    // work AND props[15] must stay 0 to match.
    let treeUsesWP = tree.contains { node in
        node.property == -1 ? node.predictor == 6 : node.property == 15
    }
    let wpState = treeUsesWP ? WPState(header: WPHeader(), xsize: gw, ysize: gh) : nil
    // Stores for properties the tree never reads are dead — the walk below is
    // the only reader of props[2...14] (props[15] belongs to WP). props[9]
    // must keep its per-pixel chain whenever 8 OR 9 is read: props[8] is
    // W − previous-pixel-props[9].
    var needProp = [Bool](repeating: false, count: kNumProps)
    for node in tree where node.property >= 0 { needProp[node.property] = true }
    let need3 = needProp[3]
    let need4 = needProp[4]
    let need5 = needProp[5]
    let need6 = needProp[6]
    let need7 = needProp[7]
    let need8 = needProp[8]
    let need9 = needProp[9] || needProp[8]
    let need10 = needProp[10]
    let need11 = needProp[11]
    let need12 = needProp[12]
    let need13 = needProp[13]
    let need14 = needProp[14]
    let props = UnsafeMutablePointer<Int32>.allocate(capacity: kNumProps)
    defer { props.deallocate() }
    props.initialize(repeating: 0, count: kNumProps)
    props[0] = Int32(truncatingIfNeeded: chan)
    props[1] = Int32(truncatingIfNeeded: streamID)
    tokens.withUnsafeMutableBufferPointer { outBuf in
        var w = start
        tree.withUnsafeBufferPointer { treeBuf in
            let treeP = treeBuf.baseAddress!
            for y in 0..<gh {
                props[2] = Int32(truncatingIfNeeded: y)
                props[9] = 0
                let row = (y0 + y) * width + x0
                let prev = row - width
                for x in 0..<gw {
                    let n = neighborhoodAt(px, row: row, prev: prev, width: width, x: x, y: y, gw: gw)
                    if need3 { props[3] = Int32(truncatingIfNeeded: x) }
                    if need4 { props[4] = Int32(truncatingIfNeeded: abs(n.top)) }
                    if need5 { props[5] = Int32(truncatingIfNeeded: abs(n.left)) }
                    if need6 { props[6] = Int32(truncatingIfNeeded: n.top) }
                    if need7 { props[7] = Int32(truncatingIfNeeded: n.left) }
                    if need9 {
                        if need8 { props[8] = Int32(truncatingIfNeeded: n.left) &- props[9] }
                        if fastTrack == .gradientClamp {
                            let g = Int64(n.left) + Int64(n.top) - Int64(n.topleft)
                            props[9] = Int32(min(max(g, -kEncPropRangeFast), kEncPropRangeFast - 1))
                        } else {
                            props[9] = Int32(truncatingIfNeeded: n.left + n.top - n.topleft)
                        }
                    }
                    if need10 { props[10] = Int32(truncatingIfNeeded: n.left - n.topleft) }
                    if need11 { props[11] = Int32(truncatingIfNeeded: n.topleft - n.top) }
                    if need12 { props[12] = Int32(truncatingIfNeeded: n.top - n.topright) }
                    if need13 { props[13] = Int32(truncatingIfNeeded: n.top - n.toptop) }
                    if need14 { props[14] = Int32(truncatingIfNeeded: n.left - n.leftleft) }

                    var wpPred = wpState?.predict(
                        x: x, y: y, xsize: gw, N: n.top, W: n.left, NE: n.topright,
                        NW: n.topleft, NN: n.toptop, computeProperties: true,
                        properties: props, offset: 15) ?? 0
                    if fastTrack == .wpClamp {
                        // The decoder's WP fast track truncates the prediction
                        // to int32 and clamps the WP property to LUT range.
                        wpPred = Int(Int32(truncatingIfNeeded: wpPred))
                        props[15] = min(
                            max(props[15], Int32(-kEncPropRangeFast)),
                            Int32(kEncPropRangeFast - 1))
                    }

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
                            toprightright: n.toprightright, wpPred: wpPred)
                    // Truncate to Int32 BEFORE packing: the decoder computes
                    // Int32(truncatingIfNeeded: guess + unpackSigned(v)), so
                    // mod-2^32 congruence is the round-trip invariant.
                    // Full-range samples (float32 bit patterns) produce raw
                    // differences beyond ±2^31 where the untruncated pack
                    // breaks it (E3's find, ported to the tree tokenizer).
                    let d = Int32(truncatingIfNeeded: Int(px[row + x]) - guess)
                    outBuf[w] = EncToken(ctx: UInt32(leaf.lchild), value: encPackSigned(Int(d)))
                    w += 1
                    wpState?.updateErrors(Int(px[row + x]), x: x, y: y, xsize: gw)
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
