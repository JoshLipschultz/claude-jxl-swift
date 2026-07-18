// Upsampling.swift
//
// The non-separable 2x/4x/8x upsampler (libjxl stage_upsampling.cc): each
// output subpixel is a 5x5 weighted sum of the input neighborhood, clamped to
// the neighborhood's min/max to avoid overshoot. The kernel bank is expanded
// from the triangular weight arrays (UpsamplingWeights.swift, or custom
// weights signaled in CustomTransformData) by the symmetries documented in
// libjxl image_metadata.cc. Runs after patches and before the color transform.

import Foundation

/// Expands the triangular weight array for `shift` (1→2x, 2→4x, 3→8x) into
/// the `[4][4][5][5]` kernel bank, flattened as `[(ky*4+kx)*25 + iy*5 + ix]`.
func buildUpsamplingKernel(shift: Int, weights: [Float]) -> [Float] {
    let n = 1 << (shift - 1)
    var kernel = [Float](repeating: 0, count: 4 * 4 * 5 * 5)
    for i in 0..<(5 * n) {
        for j in 0..<(5 * n) {
            let y = min(i, j)
            let x = max(i, j)
            // kernel_[j/5][i/5][j%5][i%5] = weights[5N*y − y(y−1)/2 + x − y]
            let w = weights[5 * n * y - y * (y - 1) / 2 + x - y]
            kernel[((j / 5) * 4 + (i / 5)) * 25 + (j % 5) * 5 + (i % 5)] = w
        }
    }
    return kernel
}

/// The kernel value for output subpixel (ox, oy) at input offset (ix, iy) in
/// [-2, 2] — libjxl `UpsamplingStage::Kernel<N>` with its parity mirroring.
@inline(__always)
private func kernelValue(
    _ kernel: UnsafePointer<Float>, n: Int, ox: Int, oy: Int, ix: Int, iy: Int
) -> Float {
    let jx = ix + 2
    let jy = iy + 2
    var ky = 0
    var kx = 0
    var ey = jy
    var ex = jx
    switch n {
    case 2:
        ey = oy % 2 == 1 ? 4 - jy : jy
        ex = ox % 2 == 1 ? 4 - jx : jx
    case 4:
        ky = oy % 4 < 2 ? oy % 2 : 1 - oy % 2
        kx = ox % 4 < 2 ? ox % 2 : 1 - ox % 2
        ey = oy % 4 < 2 ? jy : 4 - jy
        ex = ox % 4 < 2 ? jx : 4 - jx
    default:  // 8
        ky = oy % 8 < 4 ? oy % 4 : 3 - oy % 4
        kx = ox % 8 < 4 ? ox % 4 : 3 - ox % 4
        ey = oy % 8 < 4 ? jy : 4 - jy
        ex = ox % 8 < 4 ? jx : 4 - jx
    }
    return kernel[(ky * 4 + kx) * 25 + ey * 5 + ex]
}

/// Upsamples one plane by `n = 1 << shift`. The input is `w`×`h` valid pixels
/// on `stride`-wide rows; the border mirrors at the valid edges. The output is
/// tightly packed `(w*n)`×`(h*n)`.
func upsamplePlane(
    _ plane: [Float], w: Int, h: Int, stride: Int, shift: Int, weights: [Float]
) -> [Float] {
    let n = 1 << shift
    let kernelArr = buildUpsamplingKernel(shift: shift, weights: weights)
    // Per-subpixel 5x5 kernels, precomputed once: [oy][ox][iy*5+ix].
    var subKernels = [Float](repeating: 0, count: n * n * 25)
    kernelArr.withUnsafeBufferPointer { kbuf in
        let k = kbuf.baseAddress!
        for oy in 0..<n {
            for ox in 0..<n {
                for iy in -2...2 {
                    for ix in -2...2 {
                        subKernels[(oy * n + ox) * 25 + (iy + 2) * 5 + (ix + 2)] =
                            kernelValue(k, n: n, ox: ox, oy: oy, ix: ix, iy: iy)
                    }
                }
            }
        }
    }

    let outW = w * n
    var out = [Float](repeating: 0, count: outW * h * n)
    plane.withUnsafeBufferPointer { inBuf in
    subKernels.withUnsafeBufferPointer { skBuf in
    out.withUnsafeMutableBufferPointer { outBuf in
        nonisolated(unsafe) let src = inBuf.baseAddress!
        nonisolated(unsafe) let sk = skBuf.baseAddress!
        nonisolated(unsafe) let dst = outBuf.baseAddress!

        DispatchQueue.concurrentPerform(iterations: h) { y in
            @inline(__always) func mir(_ i: Int, _ count: Int) -> Int {
                var v = i
                if v < 0 { v = -v - 1 }
                if v >= count { v = 2 * count - 1 - v }
                return max(0, min(count - 1, v))
            }
            var window = [Float](repeating: 0, count: 25)
            for x in 0..<w {
                // Gather the 5x5 neighborhood (mirrored at the valid edges)
                // and its min/max for the overshoot clamp.
                var lo = src[y * stride + x]
                var hi = lo
                for iy in -2...2 {
                    let row = mir(y + iy, h) * stride
                    for ix in -2...2 {
                        let v = src[row + mir(x + ix, w)]
                        window[(iy + 2) * 5 + (ix + 2)] = v
                        lo = min(lo, v)
                        hi = max(hi, v)
                    }
                }
                for oy in 0..<n {
                    let dstRow = (y * n + oy) * outW + x * n
                    for ox in 0..<n {
                        let kBase = (oy * n + ox) * 25
                        var acc: Float = 0
                        for t in 0..<25 {
                            acc += sk[kBase + t] * window[t]
                        }
                        dst[dstRow + ox] = min(max(acc, lo), hi)
                    }
                }
            }
        }
    }
    }
    }
    return out
}
