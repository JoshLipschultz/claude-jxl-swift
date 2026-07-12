// ColorManagement.swift
//
// The color pipeline stage: XYB -> linear -> display. VarDCT reconstruction
// (Reconstruct.swift) stops at XYB float planes (`XYBImage`); the functions
// here convert those planes to output pixels. This is the seam where the M8
// work lands (ICC, other transfer functions, 16-bit/float output, alpha)
// without touching the transform pipeline above it.

import Foundation

/// Full-resolution XYB planes of a VarDCT frame, padded to whole 8px blocks —
/// the interstage currency between reconstruction, the restoration filters,
/// and the color pipeline. Rows are `stride` samples apart; the visible image
/// is the top-left `width x height` of the padded `stride x paddedHeight` grid.
struct XYBImage {
    let width: Int
    let height: Int
    let stride: Int
    let paddedHeight: Int
    var x: [Float]
    var y: [Float]
    var b: [Float]
}

// MARK: - XYB -> linear sRGB (libjxl opsin_params.h / XybToRgb)

private let kOpsinBias: Float = 0.0037930732552754493
// Inverse opsin matrix as scalars: an array here would be re-retained per
// pixel from every conversion worker thread.
private let kInvOpsin00: Float = 11.031566901960783
private let kInvOpsin01: Float = -9.866943921568629
private let kInvOpsin02: Float = -0.16462299647058826
private let kInvOpsin10: Float = -3.254147380392157
private let kInvOpsin11: Float = 4.418770392156863
private let kInvOpsin12: Float = -0.16462299647058826
private let kInvOpsin20: Float = -3.6588512862745097
private let kInvOpsin21: Float = 2.7129230470588235
private let kInvOpsin22: Float = 1.9459282392156863

func srgbEncode(_ d: Float) -> Float {
    let v = max(0, min(1, d))
    return v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1.0 / 2.4) - 0.055
}

private let kOpsinBiasCbrt = cbrtf(kOpsinBias)

/// Linear -> sRGB 8-bit without the per-pixel `powf`: 255 decision thresholds
/// (the linear value at which the rounded 8-bit output steps to `k`, i.e. the
/// inverse transfer function at `(k - 0.5) / 255`, computed in Double), plus a
/// coarse bucket table so the per-pixel cost is one index + a couple of
/// compares. `encode(v)` equals `round(srgbEncode(clamp(v)) * 255)`; the
/// equivalence is asserted over a dense sweep in the test suite.
///
/// The tables are manually-managed pointers (never freed; ~1.3 KB of process
/// lifetime data): the quantizer is read per pixel from every worker thread,
/// and array-backed storage would funnel all of them through one shared,
/// contended refcount.
struct SRGB8Quantizer {
    /// `thresholds[k-1]` = smallest linear value mapping to output `k` (255 entries).
    private let thresholds: UnsafePointer<Float>
    /// For bucket `b` of [0,1]/1024: the largest `k` whose threshold precedes
    /// the bucket start (the search start for values in the bucket).
    private let coarse: UnsafePointer<UInt8>
    private static let kBuckets = 1024

    init() {
        // Reference output the quantizer must reproduce exactly.
        func reference(_ v: Float) -> Int {
            Int(max(0, min(255, (srgbEncode(v) * 255).rounded())))
        }
        let t = UnsafeMutablePointer<Float>.allocate(capacity: 255)
        for k in 1...255 {
            let s = (Double(k) - 0.5) / 255.0
            let linear = s <= 0.0031308 * 12.92
                ? s / 12.92
                : pow((s + 0.055) / 1.055, 2.4)
            // The analytic threshold can land a few ulps off the reference's
            // Float flip point; walk to the exact smallest Float mapping to k
            // so `encode` is bit-identical to the reference everywhere.
            var flip = Float(linear)
            while reference(flip) < k { flip = flip.nextUp }
            while flip > 0 && reference(flip.nextDown) >= k { flip = flip.nextDown }
            t[k - 1] = flip
        }
        thresholds = UnsafePointer(t)
        let c = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.kBuckets + 1)
        var k = 0
        for b in 0...Self.kBuckets {
            let start = Float(b) / Float(Self.kBuckets)
            while k < 255 && t[k] <= start { k += 1 }
            c[b] = UInt8(k)  // thresholds[k-1] <= start < thresholds[k]
        }
        coarse = UnsafePointer(c)
    }

    @inline(__always)
    func encode(_ v: Float) -> UInt8 {
        if !(v > 0) { return 0 }  // negatives and NaN clamp to 0
        if v >= 1 { return 255 }
        let bucket = Int(v * Float(Self.kBuckets))
        var k = Int(coarse[bucket])
        // At most a few steps: thresholds are ~3e-4 apart at their densest
        // (near 0) versus a bucket width of ~9.8e-4.
        while k < 255 && v >= thresholds[k] { k += 1 }
        return UInt8(truncatingIfNeeded: k)
    }
}

nonisolated(unsafe) let srgb8Quantizer = SRGB8Quantizer()

/// XYB -> sRGB 8-bit, matching libjxl XybToRgb + the sRGB transfer function.
@inline(__always)
func xybToSRGB8(x: Float, y: Float, b: Float) -> (UInt8, UInt8, UInt8) {
    // libjxl opsin_biases_cbrt = cbrt(-bias) = -cbrt(bias), and XybToRgb
    // subtracts it — i.e. adds cbrt(bias) — to recover cbrt(mixed).
    let gr = (y + x) + kOpsinBiasCbrt
    let gg = (y - x) + kOpsinBiasCbrt
    let gb = b + kOpsinBiasCbrt
    let mr = gr * gr * gr - kOpsinBias
    let mg = gg * gg * gg - kOpsinBias
    let mb = gb * gb * gb - kOpsinBias
    let lr = kInvOpsin00 * mr + kInvOpsin01 * mg + kInvOpsin02 * mb
    let lg = kInvOpsin10 * mr + kInvOpsin11 * mg + kInvOpsin12 * mb
    let lb = kInvOpsin20 * mr + kInvOpsin21 * mg + kInvOpsin22 * mb
    let q = srgb8Quantizer
    return (q.encode(lr), q.encode(lg), q.encode(lb))
}

/// Converts XYB planes to interleaved 8-bit sRGB (RGB, row-major, unpadded),
/// row-parallel with a direct per-pixel loop (no per-pixel closure).
func xybToSRGB8Interleaved(_ img: XYBImage) -> [UInt8] {
    var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
    let width = img.width
    let stride = img.stride
    img.x.withUnsafeBufferPointer { xBuf in
    img.y.withUnsafeBufferPointer { yBuf in
    img.b.withUnsafeBufferPointer { bBuf in
    rgb.withUnsafeMutableBufferPointer { outBuf in
        nonisolated(unsafe) let px = xBuf.baseAddress!
        nonisolated(unsafe) let py = yBuf.baseAddress!
        nonisolated(unsafe) let pb = bBuf.baseAddress!
        nonisolated(unsafe) let out = outBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: img.height) { y in
            let row = y * stride
            var dst = y * width * 3
            for x in 0..<width {
                let (r, g, b) = xybToSRGB8(x: px[row + x], y: py[row + x], b: pb[row + x])
                out[dst] = r
                out[dst + 1] = g
                out[dst + 2] = b
                dst += 3
            }
        }
    }
    }
    }
    }
    return rgb
}

/// Converts XYB planes to three planar 8-bit sRGB channels in the
/// `JXLDecodedImage` sample representation, row-parallel.
func xybToSRGB8Planes(_ img: XYBImage) -> [[Int32]] {
    let width = img.width
    let stride = img.stride
    var planeR = [Int32](repeating: 0, count: img.width * img.height)
    var planeG = planeR
    var planeB = planeR
    planeR.withUnsafeMutableBufferPointer { rBuf in
    planeG.withUnsafeMutableBufferPointer { gBuf in
    planeB.withUnsafeMutableBufferPointer { bBuf in
    img.x.withUnsafeBufferPointer { xBuf in
    img.y.withUnsafeBufferPointer { yBuf in
    img.b.withUnsafeBufferPointer { bSrcBuf in
        nonisolated(unsafe) let pr = rBuf.baseAddress!
        nonisolated(unsafe) let pg = gBuf.baseAddress!
        nonisolated(unsafe) let pbOut = bBuf.baseAddress!
        nonisolated(unsafe) let px = xBuf.baseAddress!
        nonisolated(unsafe) let py = yBuf.baseAddress!
        nonisolated(unsafe) let pb = bSrcBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: img.height) { y in
            let row = y * stride
            let dstRow = y * width
            for x in 0..<width {
                let (r, g, b) = xybToSRGB8(x: px[row + x], y: py[row + x], b: pb[row + x])
                pr[dstRow + x] = Int32(r)
                pg[dstRow + x] = Int32(g)
                pbOut[dstRow + x] = Int32(b)
            }
        }
    }
    }
    }
    }
    }
    }
    return [planeR, planeG, planeB]
}
