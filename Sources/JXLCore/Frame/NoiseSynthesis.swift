// NoiseSynthesis.swift
//
// Noise synthesis (ISO/IEC 18181-1 §C.4.3; libjxl dec_noise.{h,cc} +
// render_pipeline/stage_noise.cc): a frame whose header sets kNoise (flags
// bit 0) carries an 8-entry noise LUT in the LfGlobal section. Rendering
// generates three pseudo-random planes at the final (post-upsampling) frame
// resolution — seeded per 256x256 tile from the frame indices and tile
// origin, so output is bit-reproducible — convolves them with a 5x5
// Laplacian-like kernel, and adds intensity-modulated noise to the X and Y
// channels (with the cmap base correlations feeding X and B).

import Foundation

// MARK: - Parameters (libjxl NoiseParams / DecodeNoise)

struct NoiseParams {
    /// LUT over pixel intensity; 8 entries at kNoisePrecision = 1024.
    var lut: [Float] = [Float](repeating: 0, count: 8)

    var hasAny: Bool { lut.contains { abs($0) > 1e-3 } }
}

/// Reads the 8 noise LUT entries (10 fixed bits each / 1024).
func decodeNoiseParams(_ br: BitReader) -> NoiseParams {
    var params = NoiseParams()
    for i in 0..<8 {
        params.lut[i] = Float(br.read(10)) * (1.0 / 1024.0)
    }
    return params
}

// MARK: - RNG (libjxl xorshift128plus-inl.h, scalar; 8 independent generators)

struct Xorshift128Plus {
    static let n = 8
    var s0 = [UInt64](repeating: 0, count: 8)
    var s1 = [UInt64](repeating: 0, count: 8)

    @inline(__always)
    private static func splitMix64(_ z0: UInt64) -> UInt64 {
        var z = z0
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    init(seed1: UInt32, seed2: UInt32, seed3: UInt32, seed4: UInt32) {
        s0[0] = Self.splitMix64(
            ((UInt64(seed1) << 32) &+ UInt64(seed2)) &+ 0x9E37_79B9_7F4A_7C15)
        s1[0] = Self.splitMix64(
            ((UInt64(seed3) << 32) &+ UInt64(seed4)) &+ 0x9E37_79B9_7F4A_7C15)
        for i in 1..<Self.n {
            s0[i] = Self.splitMix64(s0[i - 1])
            s1[i] = Self.splitMix64(s1[i - 1])
        }
    }

    /// Fills `randomBits[0..<8]` with the next batch.
    @inline(__always)
    mutating func fill(_ randomBits: inout [UInt64]) {
        for i in 0..<Self.n {
            var s1v = s0[i]
            let s0v = s1[i]
            randomBits[i] = s1v &+ s0v
            s0[i] = s0v
            s1v ^= s1v << 23
            s1v ^= s0v ^ (s1v >> 18) ^ (s0v >> 5)
            s1[i] = s1v
        }
    }
}

/// Converts random bits to a float in [1, 2) (libjxl BitsToFloat). The
/// convolution kernel sums to zero, so the +1 offset cancels out.
@inline(__always)
private func noiseBitsToFloat(_ bits: UInt32) -> Float {
    Float(bitPattern: (bits >> 9) | 0x3F80_0000)
}

// MARK: - Random plane generation (libjxl RandomImage / Random3Planes)

/// Fills the tile rect `[x0, x0+w) x [y0, y0+h)` of `plane` (row stride
/// `planeW`) with random floats, consuming `rng` exactly as libjxl's
/// RandomImage does (batches of 16 floats per row; one extra batch fills any
/// remainder). Out-of-tile overshoot writes are dropped — in libjxl they land
/// in group-buffer padding, never in neighboring tiles.
private func randomImageTile(
    _ rng: inout Xorshift128Plus, plane: UnsafeMutablePointer<Float>, planeW: Int,
    x0: Int, y0: Int, w: Int, h: Int
) {
    let kFloatsPerBatch = Xorshift128Plus.n * 2  // 16
    var batch = [UInt64](repeating: 0, count: Xorshift128Plus.n)
    for y in 0..<h {
        let row = plane + (y0 + y) * planeW + x0
        var x = 0
        // Only entire batches.
        while x + kFloatsPerBatch < w {
            rng.fill(&batch)
            for i in 0..<kFloatsPerBatch {
                let u = batch[i >> 1]
                let bits = (i & 1) == 0 ? UInt32(truncatingIfNeeded: u) : UInt32(u >> 32)
                row[x + i] = noiseBitsToFloat(bits)
            }
            x += kFloatsPerBatch
        }
        // Any remaining pixels from one more batch (consumed even when w == 0).
        rng.fill(&batch)
        var i = 0
        while x < w {
            let u = batch[i >> 1]
            let bits = (i & 1) == 0 ? UInt32(truncatingIfNeeded: u) : UInt32(u >> 32)
            row[x] = noiseBitsToFloat(bits)
            i += 1
            x += 1
        }
    }
}

// MARK: - Application (libjxl ConvolveNoiseStage + AddNoiseStage)

/// Noise LUT interpolation (libjxl StrengthEvalLut, scalar path), clamped to
/// [0, 1] by the caller-side NoiseStrength semantics.
@inline(__always)
private func noiseStrength(_ lut: UnsafePointer<Float>, _ x: Float) -> Float {
    let kScale: Float = 6  // kNumNoisePoints - 2
    let scaled = max(0, x * kScale)
    var floorX = scaled.rounded(.down)
    var fracX = scaled - floorX
    if scaled >= kScale + 1 {
        floorX = kScale
        fracX = 1
    }
    let idx = Int(floorX)
    let low = lut[idx]
    let hi = lut[idx + 1]
    let value = (hi - low) * fracX + low
    // Clamp0ToMax(value, 1).
    let clamped = min(value, 1.0)
    return clamped < 0 ? 0 : clamped
}

@inline(__always)
private func noiseMirror(_ i: Int, _ n: Int) -> Int {
    var v = i
    while v < 0 || v >= n {
        if v < 0 {
            v = -v - 1
        } else {
            v = 2 * n - 1 - v
        }
    }
    return v
}

/// 5x5 zero-sum convolution: `4 * (identity - box)` (libjxl
/// ConvolveNoiseStage), with image-edge mirroring, matching the render
/// pipeline's border handling.
private func convolveNoisePlane(_ src: [Float], w: Int, h: Int) -> [Float] {
    var out = [Float](repeating: 0, count: w * h)
    src.withUnsafeBufferPointer { srcBuf in
        out.withUnsafeMutableBufferPointer { dstBuf in
            nonisolated(unsafe) let s = srcBuf.baseAddress!
            nonisolated(unsafe) let d = dstBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                // Row bases with vertical mirroring, matching libjxl's row
                // order (rows 0,1,3,4 then the center row's neighbors).
                let rm2 = noiseMirror(y - 2, h) * w
                let rm1 = noiseMirror(y - 1, h) * w
                let r0 = y * w
                let rp1 = noiseMirror(y + 1, h) * w
                let rp2 = noiseMirror(y + 2, h) * w
                for x in 0..<w {
                    let p00 = s[r0 + x]
                    var others: Float = 0
                    for i in -2...2 {
                        let xi = noiseMirror(x + i, w)
                        others += s[rm2 + xi]
                        others += s[rm1 + xi]
                        others += s[rp1 + xi]
                        others += s[rp2 + xi]
                    }
                    others += s[r0 + noiseMirror(x - 2, w)]
                    others += s[r0 + noiseMirror(x - 1, w)]
                    others += s[r0 + noiseMirror(x + 1, w)]
                    others += s[r0 + noiseMirror(x + 2, w)]
                    d[r0 + x] = others * 0.16 + p00 * -3.84
                }
            }
        }
    }
    return out
}

/// Generates, convolves, and adds synthetic noise onto the (post-upsampling)
/// XYB planes. `groupDim`/`xsizeGroups`/`ysizeGroups` describe the frame's
/// pre-upsampling group grid; the tile seeding follows libjxl
/// PrepareNoiseInput exactly.
func applyNoise(
    _ params: NoiseParams, into image: inout XYBImage,
    groupDim: Int, xsizeGroups: Int, ysizeGroups: Int, upsampling: Int,
    visibleFrameIndex: Int, nonvisibleFrameIndex: Int, yToX: Float, yToB: Float
) {
    let w = image.width
    let h = image.height

    // Three random planes at frame resolution, generated tile by tile.
    var planes = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
    for gy in 0..<ysizeGroups {
        for gx in 0..<xsizeGroups {
            // Group extent at output resolution.
            let groupX1 = min((gx + 1) * upsampling * groupDim, w)
            let groupY1 = min((gy + 1) * upsampling * groupDim, h)
            for iy in 0..<upsampling {
                for ix in 0..<upsampling {
                    let x0 = (gx * upsampling + ix) * groupDim
                    let y0 = (gy * upsampling + iy) * groupDim
                    let tw = max(0, min(groupDim, groupX1 - x0))
                    let th = max(0, min(groupDim, groupY1 - y0))
                    var rng = Xorshift128Plus(
                        seed1: UInt32(truncatingIfNeeded: visibleFrameIndex),
                        seed2: UInt32(truncatingIfNeeded: nonvisibleFrameIndex),
                        seed3: UInt32(truncatingIfNeeded: x0),
                        seed4: UInt32(truncatingIfNeeded: y0))
                    for c in 0..<3 {
                        planes[c].withUnsafeMutableBufferPointer { buf in
                            randomImageTile(
                                &rng, plane: buf.baseAddress!, planeW: w,
                                x0: x0, y0: y0, w: tw, h: th)
                        }
                    }
                }
            }
        }
    }

    // 5x5 zero-sum convolution of each plane.
    let convR = convolveNoisePlane(planes[0], w: w, h: h)
    let convG = convolveNoisePlane(planes[1], w: w, h: h)
    let convC = convolveNoisePlane(planes[2], w: w, h: h)

    // AddNoiseStage: intensity-modulated application to X/Y (B via ytob).
    let stride = image.stride
    let lut = params.lut
    let kRGCorr: Float = 0.9921875  // 127/128
    let kRGNCorr: Float = 0.0078125  // 1/128
    let normConst: Float = 0.22
    let half: Float = 0.5

    image.x.withUnsafeMutableBufferPointer { bx in
    image.y.withUnsafeMutableBufferPointer { by in
    image.b.withUnsafeMutableBufferPointer { bb in
    convR.withUnsafeBufferPointer { cr in
    convG.withUnsafeBufferPointer { cg in
    convC.withUnsafeBufferPointer { cc in
    lut.withUnsafeBufferPointer { lutBuf in
        nonisolated(unsafe) let px = bx.baseAddress!
        nonisolated(unsafe) let py = by.baseAddress!
        nonisolated(unsafe) let pb = bb.baseAddress!
        nonisolated(unsafe) let pr = cr.baseAddress!
        nonisolated(unsafe) let pg = cg.baseAddress!
        nonisolated(unsafe) let pc = cc.baseAddress!
        nonisolated(unsafe) let plut = lutBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let rowOut = y * stride
            let rowNoise = y * w
            for x in 0..<w {
                let vx = px[rowOut + x]
                let vy = py[rowOut + x]
                let inG = vy - vx
                let inR = vy + vx
                let strengthG = noiseStrength(plut, inG * half)
                let strengthR = noiseStrength(plut, inR * half)
                let rndR = pr[rowNoise + x] * normConst
                let rndG = pg[rowNoise + x] * normConst
                let rndCor = pc[rowNoise + x] * normConst
                let redNoise = strengthR * (kRGNCorr * rndR + kRGCorr * rndCor)
                let greenNoise = strengthG * (kRGNCorr * rndG + kRGCorr * rndCor)
                let rgNoise = redNoise + greenNoise
                px[rowOut + x] = yToX * rgNoise + (redNoise - greenNoise) + vx
                py[rowOut + x] = vy + rgNoise
                pb[rowOut + x] = yToB * rgNoise + pb[rowOut + x]
            }
        }
    }
    }
    }
    }
    }
    }
    }
}
