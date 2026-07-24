// RCTSearch.swift
//
// RCT-type selection for the lossless Modular encoder. The encoder previously
// hard-coded YCoCg (rct_type 6). This searches all 42 reversible color
// transforms (6 permutations x 7 mixings, incl. identity/permute-only,
// subtract-green, and YCoCg) for the one that decorrelates the three color
// channels best on THIS image, using the standard separable proxy: for each
// candidate, sum the three coded channels' gradient-residual token entropies.
//
// Correctness is independent of the estimate: forwardRCT is the exact
// bit-level inverse of the decoder's invRCT for every type 0..41, so ANY
// choice round-trips (the decoder implements all 42; djxl too). The estimate
// only steers density. The result is written into the GroupHeader's rct_type
// (ModularEncoder.writeLfGlobalModular).

import Foundation

/// In-place forward RCT for `type` (0..41) on the first three planes of
/// `channels`. The exact inverse of the decoder's `invRCT`: intermediates are
/// computed in `Int` (no overflow for Int32-range operands) and truncated to
/// Int32, matching invRCT's wrap points, so full-range float32 bit patterns
/// round-trip. Type 0 (permutation 0, custom 0) is the identity / no-op.
func forwardRCT(_ channels: inout [[Int32]], type: Int) {
    if type == 0 { return }
    let permutation = type / 7
    let custom = type % 7
    // Output channel positions after the permutation (mirror of invRCT): the
    // decoder writes r0/r1/r2 to o0/o1/o2, so the original samples we read from
    // those positions ARE r0/r1/r2, and we solve for the coded triple.
    let o0 = permutation % 3
    let o1 = (permutation + 1 + permutation / 3) % 3
    let o2 = (permutation + 2 - permutation / 3) % 3
    let second = custom >> 1
    let third = custom & 1
    var p0: [Int32] = []
    var p1: [Int32] = []
    var p2: [Int32] = []
    swap(&p0, &channels[0])
    swap(&p1, &channels[1])
    swap(&p2, &channels[2])
    let n = p0.count
    p0.withUnsafeMutableBufferPointer { b0 in
        p1.withUnsafeMutableBufferPointer { b1 in
            p2.withUnsafeMutableBufferPointer { b2 in
                let ptrs = [b0, b1, b2]
                // Read r0/r1/r2 from the (permuted) originals; write the coded
                // triple to positions 0/1/2. Reads precede writes each pixel,
                // so the aliasing between read and write pointers is safe.
                let a0 = ptrs[o0]
                let a1 = ptrs[o1]
                let a2 = ptrs[o2]
                // EXACT-INVERSE RULE (cost a real bug — see the note above
                // `forwardRCT`): every `>> 1` below must shift the value the
                // DECODER will shift, i.e. the *stored* Int32 coded value (or
                // an intermediate the decoder rebuilds identically from stored
                // values). Computing the whole chain in 64-bit and truncating
                // only at the end diverges once an intermediate leaves Int32
                // range: the decoder shifts the truncated value, so the two
                // results differ by 2^31. Plain +/- tolerate that (their
                // 2^32-multiple offsets vanish on the final truncation) but a
                // shift halves the offset and corrupts the sample. Full-range
                // Int32 inputs are reachable: float32 planes carry IEEE-754
                // bit patterns.
                for i in 0..<n {
                    let r0 = Int(a0[i])
                    let r1 = Int(a1[i])
                    let r2 = Int(a2[i])
                    var c0: Int32
                    var c1: Int32
                    var c2: Int32
                    if custom == 6 {  // YCoCg (in the permuted channel order)
                        // Decoder: tmp = Y-(Cg>>1); g = Cg+tmp; b = tmp-(Co>>1);
                        //          r0 = b+Co; r1 = g; r2 = b. Shifts apply to
                        //          the STORED Co/Cg, so store them first and
                        //          shift those.
                        c1 = Int32(truncatingIfNeeded: r0 - r2)  // Co
                        let tmp = r2 + (Int(c1) >> 1)
                        c2 = Int32(truncatingIfNeeded: r1 - tmp)  // Cg
                        c0 = Int32(truncatingIfNeeded: tmp + (Int(c2) >> 1))  // Y
                    } else if custom == 0 {  // permute only
                        c0 = Int32(truncatingIfNeeded: r0)
                        c1 = Int32(truncatingIfNeeded: r1)
                        c2 = Int32(truncatingIfNeeded: r2)
                    } else {
                        // Decoder: thd = c2 (+ first if third); sec = c1 +
                        //          (first | ((first+thd)>>1)); first = c0.
                        // Rebuild `thd` from the STORED c2/c0 exactly as the
                        // decoder does, then derive c1 from that same value.
                        c0 = Int32(truncatingIfNeeded: r0)
                        c2 = Int32(truncatingIfNeeded: r2 - (third == 1 ? Int(c0) : 0))
                        var thd = Int(c2)
                        if third == 1 { thd += Int(c0) }
                        let sub =
                            second == 1
                            ? Int(c0) : (second == 2 ? (Int(c0) + thd) >> 1 : 0)
                        c1 = Int32(truncatingIfNeeded: r1 - sub)
                    }
                    b0[i] = c0
                    b1[i] = c1
                    b2[i] = c2
                }
            }
        }
    }
    swap(&p0, &channels[0])
    swap(&p1, &channels[1])
    swap(&p2, &channels[2])
}

// MARK: - Cost estimate

/// Raw extra bits the (4,2,0) hybrid-uint config (encUintConfig) attaches to a
/// token — the same schedule TreeBuilder's `extraBitsForToken` uses, kept local
/// so the estimator has no cross-file coupling.
@inline(__always)
private func rctExtraBits(_ t: Int) -> Double { t < 16 ? 0 : Double(2 + ((t - 16) >> 2)) }

/// Shannon entropy of a token histogram plus the raw extra bits those tokens
/// carry (order-0 coded-size proxy). Blind to inter-context sharing, but the
/// same proxy for every candidate — only the ranking matters.
private func rctEntropyBits(_ hist: UnsafePointer<UInt32>, _ n: Int) -> Double {
    var total = 0.0
    var sum = 0.0
    var extra = 0.0
    for t in 0..<n {
        let ci = Double(hist[t])
        if ci > 0 {
            total += ci
            sum += ci * log2(ci)
            extra += ci * rctExtraBits(t)
        }
    }
    if total == 0 { return 0 }
    return total * log2(total) - sum + extra
}

/// Accumulates gradient-residual hybrid-uint tokens for stacked rows
/// [y0, y1) of `plane` into `hist` (128 bins). `y0` is treated as a top row
/// (no north), so each sampled band is scored as its own little image — bands
/// never borrow neighbours across their seam. Border semantics mirror the
/// tokenizer's `neighborhoodAt`.
private func rctAccumGradientHist(
    _ plane: UnsafeBufferPointer<Int32>, width: Int, y0: Int, y1: Int,
    hist: UnsafeMutablePointer<UInt32>
) {
    for y in y0..<y1 {
        let row = y * width
        let prev = row - width
        let topRow = (y == y0)
        for x in 0..<width {
            let left = x > 0 ? Int(plane[row + x - 1]) : (!topRow ? Int(plane[prev + x]) : 0)
            let top = topRow ? left : Int(plane[prev + x])
            let topleft = (x > 0 && !topRow) ? Int(plane[prev + x - 1]) : left
            let guess = clampedGradient(top, left, topleft)
            let d = Int32(truncatingIfNeeded: Int(plane[row + x]) - guess)
            let (token, _, _) = encUintConfig.encode(encPackSigned(Int(d)))
            hist[Int(token)] += 1
        }
    }
}

/// A locality-preserving subsample of the three color planes: full-width bands
/// of `bandRows` consecutive rows, spread evenly across the image and stacked.
/// Small images are returned whole (one band). Preserving contiguous rows lets
/// the gradient predictor see real neighbours; spreading bands keeps the sample
/// representative of the whole frame.
private func rctSample(
    _ planes: [[Int32]], width: Int, height: Int
) -> (planes: [[Int32]], bandRows: Int, numBands: Int) {
    let target = 160_000
    let bandRows = 8
    if width * height <= target || height < 2 * bandRows {
        return ([planes[0], planes[1], planes[2]], height, 1)
    }
    let numBands = max(4, min(target / (width * bandRows), height / bandRows))
    // Evenly spread band start rows across [0, height - bandRows].
    var starts = [Int](repeating: 0, count: numBands)
    for b in 0..<numBands {
        starts[b] = numBands == 1 ? 0 : (height - bandRows) * b / (numBands - 1)
    }
    let sh = numBands * bandRows
    var out: [[Int32]] = [[], [], []]
    for c in 0..<3 {
        var p = [Int32](repeating: 0, count: width * sh)
        planes[c].withUnsafeBufferPointer { src in
            p.withUnsafeMutableBufferPointer { dst in
                for b in 0..<numBands {
                    let s = starts[b] * width
                    let d = b * bandRows * width
                    for i in 0..<(bandRows * width) { dst[d + i] = src[s + i] }
                }
            }
        }
        out[c] = p
    }
    return (out, bandRows, numBands)
}

/// Chooses rct_type 0..41 minimizing the estimated coded size of the three
/// original color planes. Deterministic (fixed subsample + fixed math). Returns
/// 6 (YCoCg — the long-standing default) unless another type is estimated
/// MEANINGFULLY smaller, so a noisy estimate on a hard image never regresses
/// the default; genuine decorrelation wins (e.g. a shared-noise channel pair
/// that a difference cancels) are far above the margin.
func chooseRCT(_ planes: [[Int32]], width: Int, height: Int) -> Int {
    let (sample, bandRows, numBands) = rctSample(planes, width: width, height: height)
    let n = sample[0].count
    guard n >= 16 else { return 6 }

    let bufs: [UnsafeMutableBufferPointer<Int32>] = sample.map { p in
        let b = UnsafeMutableBufferPointer<Int32>.allocate(capacity: p.count)
        _ = b.initialize(from: p)
        return b
    }
    defer { for b in bufs { b.deallocate() } }
    let costs = UnsafeMutablePointer<Double>.allocate(capacity: 42)
    defer { costs.deallocate() }

    do {
        nonisolated(unsafe) let bufsL = bufs
        nonisolated(unsafe) let costsL = costs
        let wv = width
        let brv = bandRows
        let nbv = numBands
        // Candidates are independent; results land in fixed slots. Each worker
        // allocates only worker-local scratch (nothing refcounted is shared).
        DispatchQueue.concurrentPerform(iterations: 42) { t in
            var work: [[Int32]] = [
                Array(UnsafeBufferPointer(bufsL[0])),
                Array(UnsafeBufferPointer(bufsL[1])),
                Array(UnsafeBufferPointer(bufsL[2])),
            ]
            forwardRCT(&work, type: t)
            var total = 0.0
            var hist = [UInt32](repeating: 0, count: 128)
            for c in 0..<3 {
                for i in 0..<128 { hist[i] = 0 }
                work[c].withUnsafeBufferPointer { pl in
                    hist.withUnsafeMutableBufferPointer { h in
                        for b in 0..<nbv {
                            rctAccumGradientHist(
                                pl, width: wv, y0: b * brv, y1: (b + 1) * brv,
                                hist: h.baseAddress!)
                        }
                    }
                }
                total += hist.withUnsafeBufferPointer { rctEntropyBits($0.baseAddress!, 128) }
            }
            costsL[t] = total
        }
    }

    let ref = costs[6]
    var best = 6
    var bestCost = costs[6]
    for t in 0..<42 where costs[t] < bestCost {
        bestCost = costs[t]
        best = t
    }
    // Switch away from YCoCg only for a real (> 0.2%) estimated gain.
    if best != 6 && ref - bestCost < 0.002 * ref { return 6 }
    return best
}
