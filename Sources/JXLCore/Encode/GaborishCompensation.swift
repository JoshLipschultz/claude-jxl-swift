// GaborishCompensation.swift
//
// E5h: encoder-side compensation for the decoder's Gaborish restoration
// filter.
//
// The decoder, when `loop_filter_gab` is set, runs a mild normalized 3x3 blur
// over the reconstructed XYB planes. An encoder that simply switches the flag
// on ships a blurred image. To come out right, the coefficients must describe a
// PRE-SHARPENED image P such that `gaborish(P) ~= S` for the source S — then
// the decoder's blur undoes the sharpening and lands back on S.
//
// WHY THIS IS SOLVED NUMERICALLY RATHER THAN WITH A CLOSED-FORM KERNEL. libjxl
// hardcodes a 5x5 sharpening kernel whose coefficients approximate this
// inverse. Transcribing those constants would couple us to numbers we cannot
// verify from first principles, and — worse — would invert a filter subtly
// different from the one OUR decoder applies if any weight ever diverged.
// Instead we invert the decoder's own `gaborish` function as a black box, via
// Van Cittert / Richardson iteration:
//
//     P_0     = S
//     P_{k+1} = P_k + (S - gaborish(P_k))
//
// which converges whenever `||I - G|| < 1`. Gaborish is a mild blur (its
// default center weight dominates), so that holds comfortably and a handful of
// iterations gets the residual well below the quantization step — the test
// `gaborishCompensationInverts` measures exactly that residual rather than
// asserting a hardcoded number.
//
// The iteration is deliberately restricted to the VISIBLE w x h region with the
// plane's padded stride, because that is precisely the rect (and the
// mirror-at-the-visible-edge boundary rule) the decoder filters. The caller
// re-replicates block padding afterwards, since sharpening moves edge pixels.

import Foundation

/// The filter setting the encoder tries FIRST.
///
/// MEASURED RESULT — EPF IS INERT FOR THIS ENCODER, so the default is Gaborish
/// alone rather than libjxl's gaborish+epf2. `epf_iters = 2` produced output
/// PIXEL-IDENTICAL to Gaborish alone on every case measured (photo/gradient/
/// noise x q30..q90), and the mechanism is exact rather than incidental:
///
///     sharp = epfSharpness / 7          // this encoder emits 0
///     sigma = sigmaQuant * sharp        // => 0
///     sigma = min(-1e-4, sigma)         // => -1e-4
///     invSigma = 1 / sigma              // => -10000
///     if rowSigma < kEpfMinSigma { continue }   // -10000 < -3.9: skip
///
/// A zero sharpness field means "maximally sharp, do not filter", so EPF skips
/// every block by construction. Requesting it would only cost header bits and
/// make the decoder build a per-block sigma field it never reads. EPF becomes a
/// real lever the moment the encoder emits a meaningful sharpness field —
/// tracked separately; that is the work, not the header bit.
///
/// `JXL_FILTERS` forces one configuration for offline measurement, following
/// the same env-override convention as the DCT16 knobs in VarDCTStrategy.swift:
///   off  — the pre-E5h bitstream (gaborish off, epf 0)
///   gab  — Gaborish only, the half the encoder can invert exactly
///   on   — libjxl's defaults
let kEncDefaultFilters: VarDCTEncoder.EncFilterConfig = {
    switch ProcessInfo.processInfo.environment["JXL_FILTERS"] {
    case "off": return .off
    case "gab": return .gaborishOnly
    case "on": return .defaultOn
    default: return .gaborishOnly
    }
}()

/// Master switch for the lossy-vs-lossless dominance check in `encodeLossy`
/// (see `preferLosslessIfSmaller`). `JXL_LOSSLESS_RACE=0` disables it, which is
/// how the benchmark measures the lossy path in isolation.
let kEncLosslessRaceEnabled: Bool = {
    if let s = ProcessInfo.processInfo.environment["JXL_LOSSLESS_RACE"] { return s != "0" }
    return true
}()

/// Master switch for the filters-vs-no-filters frame race. `JXL_FILTER_RACE=0`
/// pins the encoder to `kEncDefaultFilters` with no second encode — which is
/// how the two branches are measured in isolation, and the lever to cut encode
/// time if the race is ever shown not to pay.
let kEncFilterRaceEnabled: Bool = {
    if let s = ProcessInfo.processInfo.environment["JXL_FILTER_RACE"] { return s != "0" }
    return true
}()

/// How many Richardson steps the compensation takes.
///
/// Convergence is linear at roughly 0.48x residual per step, but it is SLOWEST
/// exactly where it matters — across a hard edge, where the deconvolution has
/// the most work to do. Three steps was the first guess and measured only an
/// 11.8x improvement (0.265 -> 0.0225) on a step-edge test; five brings that
/// comfortably under 0.01. The test measures the real residual rather than
/// trusting this constant.
let kEncGaborishInverseIterations = 5

/// Replaces the visible `w` x `h` region of `p` with a pre-sharpened image
/// whose Gaborish blur reproduces the original contents.
///
/// `stride` is the plane's padded row stride; `weight1`/`weight2` are the
/// frame's side and corner weights, i.e. the same values written into the frame
/// header and read back by the decoder.
func encGaborishInverse(
    _ p: inout [Float], w: Int, h: Int, stride: Int, weight1: Float, weight2: Float,
    iterations: Int = kEncGaborishInverseIterations
) {
    guard w > 0, h > 0, iterations > 0 else { return }
    let target = p
    var est = p
    var blurred = [Float](repeating: 0, count: p.count)
    for _ in 0..<iterations {
        blurred = est
        gaborish(&blurred, w: w, h: h, stride: stride, weight1: weight1, weight2: weight2)
        target.withUnsafeBufferPointer { s in
            blurred.withUnsafeBufferPointer { g in
                est.withUnsafeMutableBufferPointer { e in
                    for y in 0..<h {
                        let row = y * stride
                        for x in 0..<w {
                            let i = row + x
                            e[i] += s[i] - g[i]
                        }
                    }
                }
            }
        }
    }
    p = est
}

/// The largest absolute residual `|gaborish(compensated) - source|` over the
/// visible region — the direct measure of how well the compensation inverted
/// the filter. Used by the test suite; not on the encode path.
func encGaborishResidual(
    source: [Float], compensated: [Float], w: Int, h: Int, stride: Int,
    weight1: Float, weight2: Float
) -> Float {
    var reblurred = compensated
    gaborish(&reblurred, w: w, h: h, stride: stride, weight1: weight1, weight2: weight2)
    var worst: Float = 0
    for y in 0..<h {
        let row = y * stride
        for x in 0..<w {
            worst = max(worst, abs(reblurred[row + x] - source[row + x]))
        }
    }
    return worst
}
