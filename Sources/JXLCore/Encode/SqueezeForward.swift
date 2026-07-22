// SqueezeForward.swift
//
// Forward Squeeze (the encoder dual of Transforms.swift's invSqueeze /
// libjxl modular/transform/enc_squeeze.cc). Each squeeze halves a channel in
// one direction into an average channel plus a residual channel such that the
// DECODER'S invHSqueeze/invVSqueeze reconstruction is an exact integer
// identity:
//
//   avg = (A + B + (A > B)) >> 1          (floor((A+B)/2), rounding up when
//                                          A > B — chosen so that
//                                          avg + trunc(diff/2) == A for every
//                                          (A, B): the decoder reconstructs
//                                          A = avg + diff/2 with Int64
//                                          truncating division and
//                                          B = A - diff)
//   residual = (A - B) - tendency
//
// where `tendency` is the decoder's own SmoothTendency estimate computed from
// the SAME values the decoder will see at that pixel: the previous pair's
// second sample (which reconstruction has already reproduced exactly, by
// induction), this pair's average, and the next average (the odd tail sample
// participates as the last average). The channel-layout bookkeeping (halved
// dims, shift increments, residual insertion position) mirrors the decoder's
// metaSqueeze exactly; ModularEncoder cross-checks the produced layout
// against a metaSqueeze run and refuses to encode on any divergence.
//
// Overflow note: all arithmetic is Int64 with Int32 truncation only at
// storage, like the decoder. For integer inputs (<= 16 bit, incl. post-RCT)
// no intermediate ever wraps. Full-range Int32 samples (float32 bit patterns)
// are NOT squeeze-safe — the decoder's per-level Int32 wrap feeds a division
// (diff/2), which is not congruence-preserving mod 2^32 — so the encoder
// rejects squeeze+float rather than approximating.

import Foundation

/// The squeeze residual predictor — a byte-for-byte mirror of the decoder's
/// private `smoothTendency` in Transforms.swift (libjxl SmoothTendency). Keep
/// in exact sync; the forward transform must subtract precisely what the
/// inverse will add back.
@inline(__always)
private func encSmoothTendency(_ B: Int64, _ a: Int64, _ n: Int64) -> Int64 {
    var diff: Int64 = 0
    if B >= a && a >= n {
        diff = (4 * B - 3 * n - a + 6) / 12
        if diff - (diff & 1) > 2 * (B - a) { diff = 2 * (B - a) + 1 }
        if diff + (diff & 1) > 2 * (a - n) { diff = 2 * (a - n) }
    } else if B <= a && a <= n {
        diff = (4 * B - 3 * n - a - 6) / 12
        if diff + (diff & 1) < 2 * (B - a) { diff = 2 * (B - a) - 1 }
        if diff - (diff & 1) < 2 * (a - n) { diff = 2 * (a - n) }
    }
    return diff
}

/// Rounding-average dual of the decoder's `A = a + diff/2` reconstruction.
@inline(__always)
private func squeezeAvg(_ A: Int64, _ B: Int64) -> Int64 {
    (A + B + (A > B ? 1 : 0)) >> 1
}

/// Forward horizontal squeeze of one channel: returns the averages channel
/// ((w+1)/2 wide, hshift+1) and the residuals channel (w/2 wide, same
/// shifts as the averages) whose invHSqueeze reconstruction is `chin`.
/// Layout mirrors metaSqueeze: odd widths copy the last column into the
/// averages; w == 1 degenerates to an empty residual (invHSqueeze then only
/// adjusts hshift, keeping the data).
func fwdHSqueeze(_ chin: ModularChannel) -> (avg: ModularChannel, res: ModularChannel) {
    let w = chin.w
    let h = chin.h
    let inW = (w + 1) / 2
    let resW = w - inW
    var avgC = ModularChannel(
        w: inW, h: h,
        hshift: chin.hshift >= 0 ? chin.hshift + 1 : chin.hshift, vshift: chin.vshift)
    var resC = ModularChannel(w: resW, h: h, hshift: avgC.hshift, vshift: avgC.vshift)
    if w == 0 || h == 0 { return (avgC, resC) }
    chin.pixels.withUnsafeBufferPointer { inBuf in
        avgC.pixels.withUnsafeMutableBufferPointer { avgBuf in
            resC.pixels.withUnsafeMutableBufferPointer { resBuf in
                let pIn0 = inBuf.baseAddress!
                let pAvg0 = avgBuf.baseAddress!
                for y in 0..<h {
                    let pIn = pIn0 + y * w
                    let pAvg = pAvg0 + y * inW
                    // Pass 1: averages (the odd tail column is itself the
                    // last average and participates in the tendency below,
                    // exactly as invHSqueeze's `x + 1 < inW` read does).
                    for x in 0..<resW {
                        let A = Int64(pIn[2 * x])
                        let B = Int64(pIn[2 * x + 1])
                        pAvg[x] = Int32(truncatingIfNeeded: squeezeAvg(A, B))
                    }
                    if w & 1 == 1 { pAvg[inW - 1] = pIn[w - 1] }
                    // Pass 2: residuals = diff - tendency, with the decoder's
                    // exact neighbor choices: left = previous pair's B (the
                    // reconstructed out[2x-1]), or the average itself at x=0.
                    guard resW > 0 else { continue }
                    let pRes = resBuf.baseAddress! + y * resW
                    for x in 0..<resW {
                        let A = Int64(pIn[2 * x])
                        let B = Int64(pIn[2 * x + 1])
                        let diff = A - B
                        let a = Int64(pAvg[x])
                        let nextAvg = x + 1 < inW ? Int64(pAvg[x + 1]) : a
                        let left = x > 0 ? Int64(pIn[2 * x - 1]) : a
                        let tendency = encSmoothTendency(left, a, nextAvg)
                        pRes[x] = Int32(truncatingIfNeeded: diff - tendency)
                    }
                }
            }
        }
    }
    return (avgC, resC)
}

/// Forward vertical squeeze; the column-direction mirror of fwdHSqueeze
/// (invVSqueeze's dual: top neighbor = previous pair's second row).
func fwdVSqueeze(_ chin: ModularChannel) -> (avg: ModularChannel, res: ModularChannel) {
    let w = chin.w
    let h = chin.h
    let inH = (h + 1) / 2
    let resH = h - inH
    var avgC = ModularChannel(
        w: w, h: inH,
        hshift: chin.hshift, vshift: chin.vshift >= 0 ? chin.vshift + 1 : chin.vshift)
    var resC = ModularChannel(w: w, h: resH, hshift: avgC.hshift, vshift: avgC.vshift)
    if w == 0 || h == 0 { return (avgC, resC) }
    chin.pixels.withUnsafeBufferPointer { inBuf in
        avgC.pixels.withUnsafeMutableBufferPointer { avgBuf in
            resC.pixels.withUnsafeMutableBufferPointer { resBuf in
                let pIn = inBuf.baseAddress!
                let pAvg = avgBuf.baseAddress!
                // Pass 1: averages (+ odd tail row copy).
                for y in 0..<resH {
                    let rowA = pIn + (2 * y) * w
                    let rowB = pIn + (2 * y + 1) * w
                    let out = pAvg + y * w
                    for x in 0..<w {
                        out[x] = Int32(
                            truncatingIfNeeded: squeezeAvg(Int64(rowA[x]), Int64(rowB[x])))
                    }
                }
                if h & 1 == 1 {
                    let src = pIn + (h - 1) * w
                    let dst = pAvg + (inH - 1) * w
                    for x in 0..<w { dst[x] = src[x] }
                }
                // Pass 2: residuals.
                if resH > 0 {
                    let pRes = resBuf.baseAddress!
                    for y in 0..<resH {
                        let rowA = pIn + (2 * y) * w
                        let rowB = pIn + (2 * y + 1) * w
                        let rowPrev = y > 0 ? pIn + (2 * y - 1) * w : nil
                        let rowAvg = pAvg + y * w
                        let rowNavg = y + 1 < inH ? pAvg + (y + 1) * w : rowAvg
                        let out = pRes + y * w  // residual rows stay w wide
                        for x in 0..<w {
                            let A = Int64(rowA[x])
                            let B = Int64(rowB[x])
                            let diff = A - B
                            let a = Int64(rowAvg[x])
                            let nextAvg = Int64(rowNavg[x])
                            let top = rowPrev.map { Int64($0[x]) } ?? a
                            let tendency = encSmoothTendency(top, a, nextAvg)
                            out[x] = Int32(truncatingIfNeeded: diff - tendency)
                        }
                    }
                }
            }
        }
    }
    return (avgC, resC)
}

/// Applies a resolved squeeze sequence forward over a channel list, mirroring
/// metaSqueeze's exact bookkeeping: per parameter, each channel in
/// [beginC, endC] is replaced by its averages and the residual is inserted at
/// `offset + (c - beginC)` where offset = endC+1 (in place) or the channel
/// count at the parameter's start (appended). The caller passes the params
/// list ALREADY resolved by the decoder's metaSqueeze (empty default lists
/// never reach here), so both sides run the identical concrete sequence.
func forwardSqueeze(_ channels: inout [ModularChannel], params: [SqueezeParams]) {
    for p in params {
        let beginC = Int(p.beginC)
        let endC = beginC + Int(p.numC) - 1
        let offset = p.inPlace ? endC + 1 : channels.count
        for c in beginC...endC {
            let (avg, res) = p.horizontal ? fwdHSqueeze(channels[c]) : fwdVSqueeze(channels[c])
            channels[c] = avg
            channels.insert(res, at: offset + (c - beginC))
        }
    }
}
