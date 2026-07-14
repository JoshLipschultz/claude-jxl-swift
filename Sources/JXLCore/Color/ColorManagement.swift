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

// MARK: - Output transfer functions

/// The display transfer functions the decoder can synthesize (PQ and HLG are
/// not yet supported and are rejected when building the output spec).
enum OutputTransfer {
    case linear
    case srgb
    case bt709
    case dci  // gamma 2.6
    /// `encoded = linear ^ gamma` (the codestream's gamma convention).
    case gamma(Double)

    /// Encoded value for a clamped linear input (Float reference).
    func encode(_ d: Float) -> Float {
        let v = max(0, min(1, d))
        switch self {
        case .linear:
            return v
        case .srgb:
            return srgbEncode(v)
        case .bt709:
            return v < 0.018053968510807
                ? 4.5 * v
                : 1.099296826809442 * powf(v, 0.45) - 0.099296826809442
        case .dci:
            return powf(v, 1.0 / 2.6)
        case .gamma(let g):
            return powf(v, Float(g))
        }
    }

    /// Inverse transfer (encoded -> linear), in Double for table construction.
    func inverse(_ s: Double) -> Double {
        switch self {
        case .linear:
            return s
        case .srgb:
            return s <= 0.0031308 * 12.92 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        case .bt709:
            return s < 4.5 * 0.018053968510807
                ? s / 4.5
                : pow((s + 0.099296826809442) / 1.099296826809442, 1.0 / 0.45)
        case .dci:
            return pow(s, 2.6)
        case .gamma(let g):
            return pow(s, 1.0 / g)
        }
    }
}

// MARK: - Linear -> 8-bit quantizer

/// Linear -> 8-bit without the per-pixel `powf`: 255 decision thresholds (the
/// linear value at which the rounded 8-bit output steps to `k`, refined to the
/// transfer function's exact Float flip point), plus a coarse bucket table so
/// the per-pixel cost is one index + a couple of compares. `encode(v)` equals
/// `round(transfer.encode(clamp(v)) * 255)`; the sRGB instance is asserted
/// against a dense sweep in the test suite.
///
/// A class holding manually-managed tables: worker loops bind the raw pointers
/// once (`thresholds`/`coarse`), so per-pixel reads touch no refcount.
final class TransferQuantizer {
    /// `thresholds[k-1]` = smallest linear value mapping to output `k` (255 entries).
    let thresholds: UnsafePointer<Float>
    /// For bucket `b` of [0,1]/kQuantizerBuckets: the search start for the bucket.
    let coarse: UnsafePointer<UInt8>

    init(transfer: OutputTransfer) {
        func reference(_ v: Float) -> Int {
            Int(max(0, min(255, (transfer.encode(v) * 255).rounded())))
        }
        let t = UnsafeMutablePointer<Float>.allocate(capacity: 255)
        for k in 1...255 {
            let s = (Double(k) - 0.5) / 255.0
            // The analytic threshold can land a few ulps off the reference's
            // Float flip point; walk to the exact smallest Float mapping to k
            // so `encode` is bit-identical to the reference everywhere.
            var flip = Float(transfer.inverse(s))
            while reference(flip) < k { flip = flip.nextUp }
            while flip > 0 && reference(flip.nextDown) >= k { flip = flip.nextDown }
            t[k - 1] = flip
        }
        thresholds = UnsafePointer(t)
        let c = UnsafeMutablePointer<UInt8>.allocate(capacity: kQuantizerBuckets + 1)
        var k = 0
        for b in 0...kQuantizerBuckets {
            let start = Float(b) / Float(kQuantizerBuckets)
            while k < 255 && t[k] <= start { k += 1 }
            c[b] = UInt8(k)  // thresholds[k-1] <= start < thresholds[k]
        }
        coarse = UnsafePointer(c)
    }

    deinit {
        UnsafeMutablePointer(mutating: thresholds).deallocate()
        UnsafeMutablePointer(mutating: coarse).deallocate()
    }

    /// Convenience for non-hot callers (tests); hot loops use `encodeSample8`
    /// with the bound pointers instead.
    func encode(_ v: Float) -> UInt8 {
        encodeSample8(v, thresholds, coarse)
    }
}

let kQuantizerBuckets = 1024

@inline(__always)
func encodeSample8(
    _ v: Float, _ thresholds: UnsafePointer<Float>, _ coarse: UnsafePointer<UInt8>
) -> UInt8 {
    if !(v > 0) { return 0 }  // negatives and NaN clamp to 0
    if v >= 1 { return 255 }
    let bucket = Int(v * Float(kQuantizerBuckets))
    var k = Int(coarse[bucket])
    // A few steps at most: thresholds are densest near 0 for gamma-like
    // curves, still several per bucket at worst.
    while k < 255 && v >= thresholds[k] { k += 1 }
    return UInt8(truncatingIfNeeded: k)
}

nonisolated(unsafe) let srgb8Quantizer = TransferQuantizer(transfer: .srgb)

// MARK: - Output color spec (declared numeric encoding -> conversion recipe)

/// How to turn the inverse-opsin output (linear sRGB, D65) into the frame's
/// declared output encoding: an optional 3x3 primaries/white-point matrix and
/// the transfer-function quantizer.
struct OutputColorSpec {
    /// Row-major linear-sRGB -> target-RGB matrix; nil when the target has
    /// sRGB primaries and a D65 white point (identity).
    let matrix: [Float]?
    let quantizer: TransferQuantizer
}

private let kD65 = JXLChromaticity(x: 0.3127, y: 0.3290)
private let kSRGBPrimaries = [
    JXLChromaticity(x: 0.64, y: 0.33), JXLChromaticity(x: 0.30, y: 0.60),
    JXLChromaticity(x: 0.15, y: 0.06),
]

/// Builds the output conversion for a VarDCT frame's declared color encoding.
/// Throws `unsupported` for transfer functions we cannot synthesize yet.
func makeOutputColorSpec(_ enc: JXLColorEncoding) throws -> OutputColorSpec {
    // Transfer function.
    let transfer: OutputTransfer
    if enc.hasGamma {
        transfer = .gamma(Double(enc.gamma) * 1e-7)
    } else {
        switch enc.transferFunction {
        case 1: transfer = .bt709
        case 8: transfer = .linear
        case 17: transfer = .dci
        case 0, 2, 13: transfer = .srgb  // sRGB; Unknown renders as sRGB
        default:
            throw JXLError.unsupported("transfer function \(enc.transferFunction) (PQ/HLG)")
        }
    }

    // Primaries + white point -> matrix (nil for the sRGB/D65 identity).
    let white: JXLChromaticity
    switch enc.whitePoint {
    case 2: white = enc.customWhitePoint ?? kD65
    case 10: white = JXLChromaticity(x: 1.0 / 3.0, y: 1.0 / 3.0)
    case 11: white = JXLChromaticity(x: 0.314, y: 0.351)
    default: white = kD65  // D65 (or unsignaled)
    }
    let primaries: [JXLChromaticity]
    switch enc.primaries {
    case 2: primaries = enc.customPrimaries ?? kSRGBPrimaries
    case 9:
        primaries = [
            JXLChromaticity(x: 0.708, y: 0.292), JXLChromaticity(x: 0.170, y: 0.797),
            JXLChromaticity(x: 0.131, y: 0.046),
        ]
    case 11:
        primaries = [
            JXLChromaticity(x: 0.680, y: 0.320), JXLChromaticity(x: 0.265, y: 0.690),
            JXLChromaticity(x: 0.150, y: 0.060),
        ]
    default: primaries = kSRGBPrimaries  // sRGB (or grayscale/unsignaled)
    }

    let isIdentity = enc.primaries != 2 && enc.primaries != 9 && enc.primaries != 11
        && enc.whitePoint != 2 && enc.whitePoint != 10 && enc.whitePoint != 11
        || (primaries == kSRGBPrimaries && white == kD65)
    let matrix: [Float]? = isIdentity
        ? nil
        : linearSRGBToTargetMatrix(primaries: primaries, white: white).map(Float.init)

    let quantizer: TransferQuantizer
    if case .srgb = transfer {
        quantizer = srgb8Quantizer
    } else {
        quantizer = TransferQuantizer(transfer: transfer)
    }
    return OutputColorSpec(matrix: matrix, quantizer: quantizer)
}

// MARK: 3x3 color matrix math (Double)

private func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
    var r = [Double](repeating: 0, count: 9)
    for i in 0..<3 {
        for j in 0..<3 {
            r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
        }
    }
    return r
}

private func inv3(_ m: [Double]) -> [Double] {
    let a = m[0], b = m[1], c = m[2]
    let d = m[3], e = m[4], f = m[5]
    let g = m[6], h = m[7], i = m[8]
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    let s = 1.0 / det
    return [
        (e * i - f * h) * s, (c * h - b * i) * s, (b * f - c * e) * s,
        (f * g - d * i) * s, (a * i - c * g) * s, (c * d - a * f) * s,
        (d * h - e * g) * s, (b * g - a * h) * s, (a * e - b * d) * s,
    ]
}

private func xyToXYZ(_ c: JXLChromaticity) -> [Double] {
    [c.x / c.y, 1.0, (1.0 - c.x - c.y) / c.y]
}

/// RGB -> XYZ for the given primaries and white point.
private func rgbToXYZMatrix(primaries p: [JXLChromaticity], white: JXLChromaticity) -> [Double] {
    let r = xyToXYZ(p[0])
    let g = xyToXYZ(p[1])
    let b = xyToXYZ(p[2])
    let m: [Double] = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]]
    let w = xyToXYZ(white)
    let mi = inv3(m)
    let s = [
        mi[0] * w[0] + mi[1] * w[1] + mi[2] * w[2],
        mi[3] * w[0] + mi[4] * w[1] + mi[5] * w[2],
        mi[6] * w[0] + mi[7] * w[1] + mi[8] * w[2],
    ]
    return [
        m[0] * s[0], m[1] * s[1], m[2] * s[2],
        m[3] * s[0], m[4] * s[1], m[5] * s[2],
        m[6] * s[0], m[7] * s[1], m[8] * s[2],
    ]
}

private let kBradford: [Double] = [
    0.8951, 0.2664, -0.1614,
    -0.7502, 1.7135, 0.0367,
    0.0389, -0.0685, 1.0296,
]

/// Bradford chromatic adaptation from `src` to `dst` white point (XYZ space).
private func bradfordAdaptation(from src: JXLChromaticity, to dst: JXLChromaticity) -> [Double] {
    let ws = xyToXYZ(src)
    let wd = xyToXYZ(dst)
    func cone(_ w: [Double]) -> [Double] {
        [
            kBradford[0] * w[0] + kBradford[1] * w[1] + kBradford[2] * w[2],
            kBradford[3] * w[0] + kBradford[4] * w[1] + kBradford[5] * w[2],
            kBradford[6] * w[0] + kBradford[7] * w[1] + kBradford[8] * w[2],
        ]
    }
    let cs = cone(ws)
    let cd = cone(wd)
    let scale: [Double] = [
        cd[0] / cs[0], 0, 0,
        0, cd[1] / cs[1], 0,
        0, 0, cd[2] / cs[2],
    ]
    return mul3(inv3(kBradford), mul3(scale, kBradford))
}

/// Linear sRGB (D65) -> linear target RGB, including chromatic adaptation.
private func linearSRGBToTargetMatrix(
    primaries: [JXLChromaticity], white: JXLChromaticity
) -> [Double] {
    let srgbToXYZ = rgbToXYZMatrix(primaries: kSRGBPrimaries, white: kD65)
    let targetToXYZ = rgbToXYZMatrix(primaries: primaries, white: white)
    let adapt = bradfordAdaptation(from: kD65, to: white)
    return mul3(inv3(targetToXYZ), mul3(adapt, srgbToXYZ))
}

// MARK: - XYB -> output pixels

/// XYB -> linear sRGB (libjxl XybToRgb), the mode-independent first stage.
@inline(__always)
func xybToLinearSRGB(x: Float, y: Float, b: Float) -> (Float, Float, Float) {
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
    return (lr, lg, lb)
}

/// The pre-bound scalar/pointer state one conversion worker needs: matrix as
/// scalars, quantizer tables as raw pointers (no per-pixel closures, no
/// per-pixel refcounted accesses — see the decode-performance notes).
private struct ConvertState: @unchecked Sendable {
    let hasMatrix: Bool
    let m00, m01, m02, m10, m11, m12, m20, m21, m22: Float
    let th: UnsafePointer<Float>
    let co: UnsafePointer<UInt8>

    init(_ spec: OutputColorSpec) {
        hasMatrix = spec.matrix != nil
        let m = spec.matrix ?? [1, 0, 0, 0, 1, 0, 0, 0, 1]
        m00 = m[0]; m01 = m[1]; m02 = m[2]
        m10 = m[3]; m11 = m[4]; m12 = m[5]
        m20 = m[6]; m21 = m[7]; m22 = m[8]
        th = spec.quantizer.thresholds
        co = spec.quantizer.coarse
    }

    @inline(__always)
    func convert(_ x: Float, _ y: Float, _ b: Float) -> (UInt8, UInt8, UInt8) {
        var (lr, lg, lb) = xybToLinearSRGB(x: x, y: y, b: b)
        if hasMatrix {
            let tr = m00 * lr + m01 * lg + m02 * lb
            let tg = m10 * lr + m11 * lg + m12 * lb
            let tb = m20 * lr + m21 * lg + m22 * lb
            lr = tr
            lg = tg
            lb = tb
        }
        return (encodeSample8(lr, th, co), encodeSample8(lg, th, co), encodeSample8(lb, th, co))
    }
}

/// Converts XYB planes to interleaved 8-bit output (RGB, row-major, unpadded),
/// row-parallel.
func xybToRGB8Interleaved(_ img: XYBImage, spec: OutputColorSpec) -> [UInt8] {
    var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
    let width = img.width
    let stride = img.stride
    let state = ConvertState(spec)
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
                let (r, g, b) = state.convert(px[row + x], py[row + x], pb[row + x])
                out[dst] = r
                out[dst + 1] = g
                out[dst + 2] = b
                dst += 3
            }
        }
        withExtendedLifetime(spec.quantizer) {}
    }
    }
    }
    }
    return rgb
}

/// Converts XYB planes to three planar 8-bit channels in the
/// `JXLDecodedImage` sample representation, row-parallel.
func xybToRGB8Planes(_ img: XYBImage, spec: OutputColorSpec) -> [[Int32]] {
    let width = img.width
    let stride = img.stride
    var planeR = [Int32](repeating: 0, count: img.width * img.height)
    var planeG = planeR
    var planeB = planeR
    let state = ConvertState(spec)
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
                let (r, g, b) = state.convert(px[row + x], py[row + x], pb[row + x])
                pr[dstRow + x] = Int32(r)
                pg[dstRow + x] = Int32(g)
                pbOut[dstRow + x] = Int32(b)
            }
        }
        withExtendedLifetime(spec.quantizer) {}
    }
    }
    }
    }
    }
    }
    return [planeR, planeG, planeB]
}
