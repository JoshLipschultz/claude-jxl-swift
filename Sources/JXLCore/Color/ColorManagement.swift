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


// MARK: - libjxl fast-math ports (fast_math-inl.h, transfer_functions-inl.h)
//
// djxl's float output goes through these approximations, not exact powf; a
// conformant-to-the-reference decoder must reproduce them (the conformance
// references were produced by libjxl). Scalar ports with fmaf mirroring the
// SIMD MulAdd structure.

/// FastLog2f: 2,2 rational approximation of log2 after range reduction.
@inline(__always)
func fastLog2f(_ x: Float) -> Float {
    let xBits = Int32(bitPattern: x.bitPattern)
    let expBits = xBits &- 0x3f2a_aaab  // 2/3
    let expShifted = expBits >> 23
    let mantissa = Float(bitPattern: UInt32(bitPattern: xBits &- (expShifted << 23)))
    let expVal = Float(expShifted)
    let m = mantissa - 1.0
    var yp: Float = 7.4245873327820566e-01
    yp = fmaf(yp, m, 1.4287160470083755e+00)
    yp = fmaf(yp, m, -1.8503833400518310e-06)
    var yq: Float = 1.7409343003366853e-01
    yq = fmaf(yq, m, 1.0096718572241148e+00)
    yq = fmaf(yq, m, 9.9032814277590719e-01)
    return yp / yq + expVal
}

/// FastPow2f: max relative error ~3e-7.
@inline(__always)
func fastPow2f(_ x: Float) -> Float {
    let floorx = x.rounded(.down)
    let exp = Float(bitPattern: UInt32(bitPattern: (Int32(floorx) &+ 127) << 23))
    let frac = x - floorx
    var num = frac + 1.01749063e+01
    num = fmaf(num, frac, 4.88687798e+01)
    num = fmaf(num, frac, 9.85506591e+01)
    num *= exp
    var den = fmaf(frac, 2.10242958e-01, -2.22328856e-02)
    den = fmaf(den, frac, -1.94414990e+01)
    den = fmaf(den, frac, 9.85506633e+01)
    return num / den
}

/// FastPowf: max relative error ~3e-5.
@inline(__always)
func fastPowf(_ base: Float, _ exponent: Float) -> Float {
    fastPow2f(fastLog2f(base) * exponent)
}

/// TF_SRGB::EncodedFromDisplay — sign-mirrored rational polynomial in sqrt(x)
/// (error ~5e-7); negatives keep their sign, the branch tests |x|.
@inline(__always)
func srgbEncodedFromDisplay(_ x: Float) -> Float {
    let v = abs(x)
    let sq = v.squareRoot()
    var num: Float = 7.352629620e-01
    num = fmaf(num, sq, 1.474205315e+00)
    num = fmaf(num, sq, 3.903842876e-01)
    num = fmaf(num, sq, 5.287254571e-03)
    num = fmaf(num, sq, -5.135152395e-04)
    var den: Float = 2.424867759e-02
    den = fmaf(den, sq, 9.258482155e-01)
    den = fmaf(den, sq, 1.340816930e+00)
    den = fmaf(den, sq, 3.036675394e-01)
    den = fmaf(den, sq, 1.004519624e-02)
    let magnitude = v > 0.0031308 ? num / den : 12.92 * v
    return x < 0 ? -magnitude : magnitude
}

/// TF_709::EncodedFromDisplay — libjxl's rounded constants (1.099/0.099/0.018,
/// not the extended-precision variants) and FastPowf; the branch tests the raw
/// value, so negatives take the 4.5x linear extension.
@inline(__always)
func bt709EncodedFromDisplay(_ x: Float) -> Float {
    x <= 0.018 ? 4.5 * x : fmaf(1.099, fastPowf(x, 0.45), -0.099)
}

// MARK: - Output transfer functions

// SMPTE ST 2084 (PQ) constants (libjxl TF_PQ_Base).
private let kPQM1 = 2610.0 / 16384
private let kPQM2 = (2523.0 / 4096) * 128
private let kPQC1 = 3424.0 / 4096
private let kPQC2 = (2413.0 / 4096) * 32
private let kPQC3 = (2392.0 / 4096) * 32
// ARIB STD-B67 (HLG) OETF constants (libjxl TF_HLG_Base).
private let kHLGA = 0.17883277
private let kHLGB = 1.0 - 4.0 * kHLGA
private let kHLGC = 0.5 - kHLGA * log(4.0 * kHLGA)

/// The display transfer functions the decoder can synthesize. PQ carries the
/// file's mastering peak (`intensity_target`): display 1.0 maps to that many
/// nits on the absolute 10000-nit PQ scale. HLG here is the pure OETF — the
/// cross-channel inverse OOTF is a separate pre-pass (`OutputColorSpec.hlgOOTF`).
enum OutputTransfer {
    case linear
    case srgb
    case bt709
    case dci  // gamma 2.6
    /// `encoded = linear ^ gamma` (the codestream's gamma convention).
    case gamma(Double)
    /// SMPTE ST 2084, scaled by the mastering intensity target (nits).
    case pq(intensityTarget: Float)
    /// ARIB STD-B67 OETF (scene light -> encoded).
    case hlgOETF
    /// An embedded ICC profile's (inverted) tone curve, domain [0,1].
    case curve(ICCToneCurve)

    /// Largest meaningful display input: 1.0 for relative transfers, but
    /// 10000/target for PQ (an absolute curve — content may exceed the
    /// mastering peak, encoding above encode(1.0) up to 1.0 at 10000 nits).
    var domainMax: Float {
        if case .pq(let target) = self { return 10000.0 / target }
        return 1
    }

    /// Encoded value for a domain-clamped linear input (Float reference).
    func encode(_ d: Float) -> Float {
        let v = max(0, min(domainMax, d))
        switch self {
        case .linear:
            return v
        case .srgb:
            // Exact curve here: the quantizers need a monotone encode (the
            // libjxl rational approximation wobbles by an ulp); the float
            // path (encodeExtended) uses the approximations for djxl parity.
            return srgbEncode(v)
        case .bt709:
            return v < 0.018 ? 4.5 * v : 1.099 * powf(v, 0.45) - 0.099
        case .dci:
            return powf(v, 1.0 / 2.6)
        case .gamma(let g):
            return powf(v, Float(g))
        case .pq(let target):
            if v == 0 { return 0 }
            let xp = pow(Double(v) * Double(target) / 10000.0, kPQM1)
            return Float(pow((kPQC1 + xp * kPQC2) / (1.0 + xp * kPQC3), kPQM2))
        case .hlgOETF:
            if v == 0 { return 0 }
            let s = Double(v)
            return s <= 1.0 / 12
                ? Float((3.0 * s).squareRoot())
                : Float(kHLGA * log(12.0 * s - kHLGB) + kHLGC)
        case .curve(let c):
            return Float(c.encode(Double(v)))
        }
    }

    /// Unclamped encode for float32 output, matching libjxl's transfer
    /// implementations: the curve applies to |v| with the sign copied back
    /// (out-of-gamut samples stay out of gamut, as djxl emits them). The
    /// absolute curves (PQ/HLG) keep their domain clamp.
    func encodeExtended(_ d: Float) -> Float {
        switch self {
        case .linear:
            return d
        case .pq, .hlgOETF:
            return encode(d)
        case .srgb:
            return srgbEncodedFromDisplay(d)
        case .bt709:
            return bt709EncodedFromDisplay(d)
        case .dci:
            let e = powf(abs(d), 1.0 / 2.6)
            return d < 0 ? -e : e
        case .gamma(let g):
            let e = powf(abs(d), Float(g))
            return d < 0 ? -e : e
        case .curve:
            // Float output for embedded-ICC files is the *linear* device
            // space (djxl PFM convention); the TRC applies only to integer
            // outputs via the quantizer.
            return d
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
            return s < 0.081 ? s / 4.5 : pow((s + 0.099) / 1.099, 1.0 / 0.45)
        case .dci:
            return pow(s, 2.6)
        case .gamma(let g):
            return pow(s, 1.0 / g)
        case .pq(let target):
            if s == 0 { return 0 }
            let xp = pow(s, 1.0 / kPQM2)
            let num = max(xp - kPQC1, 0.0)
            let den = kPQC2 - kPQC3 * xp
            return pow(num / den, 1.0 / kPQM1) * (10000.0 / Double(target))
        case .hlgOETF:
            if s == 0 { return 0 }
            return s <= 0.5
                ? s * s / 3.0
                : (exp((s - kHLGC) / kHLGA) + kHLGB) / 12.0
        case .curve(let c):
            return c.decode(s)
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
    /// For bucket `b` of the transfer's domain / kQuantizerBuckets: the search
    /// start for the bucket.
    let coarse: UnsafePointer<UInt8>
    /// Maps a linear value to its coarse bucket: `kQuantizerBuckets / domainMax`.
    let bucketScale: Float

    init(transfer: OutputTransfer) {
        let domainMax = transfer.domainMax
        bucketScale = Float(kQuantizerBuckets) / domainMax
        func reference(_ v: Float) -> Int {
            Int(max(0, min(255, (transfer.encode(v) * 255).rounded())))
        }
        let t = UnsafeMutablePointer<Float>.allocate(capacity: 255)
        // Levels above encode(domainMax) are unreachable; +inf thresholds.
        let maxLevel = reference(transfer.domainMax)
        for k in 1...255 {
            if k > maxLevel {
                t[k - 1] = .infinity
                continue
            }
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
            let start = domainMax * Float(b) / Float(kQuantizerBuckets)
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
        encodeSample8(v, thresholds, coarse, bucketScale)
    }
}

let kQuantizerBuckets = 1024

@inline(__always)
func encodeSample8(
    _ v: Float, _ thresholds: UnsafePointer<Float>, _ coarse: UnsafePointer<UInt8>,
    _ bucketScale: Float
) -> UInt8 {
    if !(v > 0) { return 0 }  // negatives and NaN clamp to 0
    let bucket = min(Int(v * bucketScale), kQuantizerBuckets)
    var k = Int(coarse[bucket])
    // A few steps at most: thresholds are densest near 0 for gamma-like
    // curves, still several per bucket at worst.
    while k < 255 && v >= thresholds[k] { k += 1 }
    return UInt8(truncatingIfNeeded: k)
}

nonisolated(unsafe) let srgb8Quantizer = TransferQuantizer(transfer: .srgb)

/// Linear -> 16-bit quantizer: the same threshold-table technique as the
/// 8-bit `TransferQuantizer`, with 65535 thresholds. `encode(v)` equals
/// `round(transfer.encode(clamp(v)) * 65535)` exactly (thresholds refined to
/// the Float flip points).
final class TransferQuantizer16 {
    let thresholds: UnsafePointer<Float>
    /// Search start per bucket of the transfer's domain / kQuantizer16Buckets.
    let coarse: UnsafePointer<UInt16>
    let bucketScale: Float

    init(transfer: OutputTransfer) {
        let domainMax = transfer.domainMax
        bucketScale = Float(kQuantizer16Buckets) / domainMax
        func reference(_ v: Float) -> Int {
            Int(max(0, min(65535, (transfer.encode(v) * 65535).rounded())))
        }
        let t = UnsafeMutablePointer<Float>.allocate(capacity: 65535)
        // See TransferQuantizer: levels above encode(domainMax) are unreachable.
        let maxLevel = reference(transfer.domainMax)
        for k in 1...65535 {
            if k > maxLevel {
                t[k - 1] = .infinity
                continue
            }
            let s = (Double(k) - 0.5) / 65535.0
            var flip = Float(transfer.inverse(s))
            while reference(flip) < k { flip = flip.nextUp }
            while flip > 0 && reference(flip.nextDown) >= k { flip = flip.nextDown }
            t[k - 1] = flip
        }
        thresholds = UnsafePointer(t)
        let c = UnsafeMutablePointer<UInt16>.allocate(capacity: kQuantizer16Buckets + 1)
        var k = 0
        for b in 0...kQuantizer16Buckets {
            let start = domainMax * Float(b) / Float(kQuantizer16Buckets)
            while k < 65535 && t[k] <= start { k += 1 }
            c[b] = UInt16(k)
        }
        coarse = UnsafePointer(c)
    }

    deinit {
        UnsafeMutablePointer(mutating: thresholds).deallocate()
        UnsafeMutablePointer(mutating: coarse).deallocate()
    }

    func encode(_ v: Float) -> UInt16 {
        encodeSample16(v, thresholds, coarse, bucketScale)
    }
}

let kQuantizer16Buckets = 1 << 16

@inline(__always)
func encodeSample16(
    _ v: Float, _ thresholds: UnsafePointer<Float>, _ coarse: UnsafePointer<UInt16>,
    _ bucketScale: Float
) -> UInt16 {
    if !(v > 0) { return 0 }
    let bucket = min(Int(v * bucketScale), kQuantizer16Buckets)
    var k = Int(coarse[bucket])
    while k < 65535 && v >= thresholds[k] { k += 1 }
    return UInt16(truncatingIfNeeded: k)
}

// MARK: - Output color spec (declared numeric encoding -> conversion recipe)

/// How to turn the inverse-opsin output (linear sRGB, D65) into the frame's
/// declared output encoding: an optional 3x3 primaries/white-point matrix and
/// the transfer-function quantizer.
struct OutputColorSpec {
    /// Row-major linear-sRGB -> target-RGB matrix; nil when the target has
    /// sRGB primaries and a D65 white point (identity).
    let matrix: [Float]?
    let quantizer: TransferQuantizer
    /// The transfer used by the quantizer, kept for 16-bit/float encoding.
    let transfer: OutputTransfer
    /// HLG inverse OOTF (display -> scene light): each pixel scales by
    /// `luminance^exponent` before the OETF, with luminance the dot product of
    /// the target primaries' Y contributions. nil when not HLG or when the
    /// exponent is negligible (libjxl `apply_ootf_`).
    let hlgOOTF: (exponent: Float, lumR: Float, lumG: Float, lumB: Float)?

    /// Scale applied to the inverse-opsin linear output: libjxl inits the
    /// opsin matrix with `255 / intensity_target`, so linear 1.0 equals the
    /// mastering peak (identity for SDR's default 255).
    let opsinScale: Float

    /// Custom inverse-opsin matrix/biases (nil = spec defaults).
    let customOpsin: JXLOpsinInverseMatrix?

    init(
        matrix: [Float]?, quantizer: TransferQuantizer, transfer: OutputTransfer,
        hlgOOTF: (exponent: Float, lumR: Float, lumG: Float, lumB: Float)? = nil,
        opsinScale: Float = 1,
        customOpsin: JXLOpsinInverseMatrix? = nil
    ) {
        self.matrix = matrix
        self.quantizer = quantizer
        self.transfer = transfer
        self.hlgOOTF = hlgOOTF
        self.opsinScale = opsinScale
        self.customOpsin = customOpsin
    }
}

private let kD65 = JXLChromaticity(x: 0.3127, y: 0.3290)
private let kSRGBPrimaries = [
    JXLChromaticity(x: 0.64, y: 0.33), JXLChromaticity(x: 0.30, y: 0.60),
    JXLChromaticity(x: 0.15, y: 0.06),
]

/// Builds the output conversion for a VarDCT frame's declared color encoding.
/// `toneMapping` supplies the mastering intensity target that PQ and the HLG
/// OOTF scale by.
func makeOutputColorSpec(
    _ enc: JXLColorEncoding, toneMapping: JXLToneMapping = JXLToneMapping(),
    customOpsin: JXLOpsinInverseMatrix? = nil,
    icc: ICCOutputProfile? = nil
) throws -> OutputColorSpec {
    // Embedded-ICC output: matrix+TRC profiles convert exactly (the returned
    // samples are then IN the profile's space); other profile shapes keep the
    // sRGB fallback below.
    if let icc {
        let transfer = OutputTransfer.curve(icc.trc)
        return OutputColorSpec(
            matrix: icc.matrix, quantizer: TransferQuantizer(transfer: transfer),
            transfer: transfer,
            opsinScale: 255.0 / toneMapping.intensityTarget,
            customOpsin: customOpsin)
    }
    // Transfer function.
    let transfer: OutputTransfer
    if enc.hasGamma {
        transfer = .gamma(Double(enc.gamma) * 1e-7)
    } else {
        switch enc.transferFunction {
        case 1: transfer = .bt709
        case 8: transfer = .linear
        case 16: transfer = .pq(intensityTarget: toneMapping.intensityTarget)
        case 17: transfer = .dci
        case 18: transfer = .hlgOETF
        case 0, 2, 13: transfer = .srgb  // sRGB; Unknown renders as sRGB
        default:
            throw JXLError.unsupported("transfer function \(enc.transferFunction)")
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

    // HLG inverse OOTF (libjxl HlgOOTF::ToSceneLight): display -> scene light
    // with gamma (1/1.2) * 1.111^(-log2(target/1000)); per-pixel luminance
    // uses the target primaries' Y row. Skipped when |gamma - 1| <= 0.01.
    var hlgOOTF: (exponent: Float, lumR: Float, lumG: Float, lumB: Float)? = nil
    if case .hlgOETF = transfer {
        let gamma =
            (1.0 / 1.2)
            * powf(1.111, -log2(toneMapping.intensityTarget / 1000.0))
        let exponent = gamma - 1
        if exponent < -0.01 || exponent > 0.01 {
            let toXYZ = rgbToXYZMatrix(primaries: primaries, white: white)
            hlgOOTF = (
                exponent, Float(toXYZ[3]), Float(toXYZ[4]), Float(toXYZ[5])
            )
        }
    }
    return OutputColorSpec(
        matrix: matrix, quantizer: quantizer, transfer: transfer, hlgOOTF: hlgOOTF,
        opsinScale: 255.0 / toneMapping.intensityTarget,
        customOpsin: customOpsin)
}

// MARK: 3x3 color matrix math (Double)

func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
    var r = [Double](repeating: 0, count: 9)
    for i in 0..<3 {
        for j in 0..<3 {
            r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
        }
    }
    return r
}

func inv3(_ m: [Double]) -> [Double] {
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
func rgbToXYZMatrix(primaries p: [JXLChromaticity], white: JXLChromaticity) -> [Double] {
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
func bradfordAdaptation(from src: JXLChromaticity, to dst: JXLChromaticity) -> [Double] {
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

// XYB -> linear RGB (libjxl XybToRgb) lives in ConvertState.linear: recover
// cbrt(mixed) by adding each channel's bias cbrt (libjxl stores cbrt(-bias) =
// -cbrt(bias) and subtracts), cube, remove the bias, then apply the inverse
// opsin absorbance matrix — file overrides via OpsinInverseMatrix honored.

/// The pre-bound scalar/pointer state one conversion worker needs: matrix as
/// scalars, quantizer tables as raw pointers (no per-pixel closures, no
/// per-pixel refcounted accesses — see the decode-performance notes).
private struct ConvertState: @unchecked Sendable {
    let hasMatrix: Bool
    let m00, m01, m02, m10, m11, m12, m20, m21, m22: Float
    let th: UnsafePointer<Float>
    let co: UnsafePointer<UInt8>
    let thScale: Float
    let hasOOTF: Bool
    let ootfExp, lumR, lumG, lumB: Float
    let opsinScale: Float
    // Inverse-opsin constants (file overrides or spec defaults), as scalars
    // for the per-pixel hot path.
    let io00, io01, io02, io10, io11, io12, io20, io21, io22: Float
    let biasR, biasG, biasB, biasCbrtR, biasCbrtG, biasCbrtB: Float

    init(_ spec: OutputColorSpec) {
        opsinScale = spec.opsinScale
        if let custom = spec.customOpsin {
            let im = custom.inverseMatrix
            io00 = im[0]; io01 = im[1]; io02 = im[2]
            io10 = im[3]; io11 = im[4]; io12 = im[5]
            io20 = im[6]; io21 = im[7]; io22 = im[8]
            // Serialized biases are the *negative* absorbance biases
            // (kNegOpsinAbsorbanceBiasRGB); the formula below wants the
            // positive value and its cbrt.
            biasR = -custom.opsinBiases[0]
            biasG = -custom.opsinBiases[1]
            biasB = -custom.opsinBiases[2]
            biasCbrtR = cbrtf(biasR)
            biasCbrtG = cbrtf(biasG)
            biasCbrtB = cbrtf(biasB)
        } else {
            io00 = kInvOpsin00; io01 = kInvOpsin01; io02 = kInvOpsin02
            io10 = kInvOpsin10; io11 = kInvOpsin11; io12 = kInvOpsin12
            io20 = kInvOpsin20; io21 = kInvOpsin21; io22 = kInvOpsin22
            biasR = kOpsinBias; biasG = kOpsinBias; biasB = kOpsinBias
            biasCbrtR = kOpsinBiasCbrt; biasCbrtG = kOpsinBiasCbrt; biasCbrtB = kOpsinBiasCbrt
        }
        hasMatrix = spec.matrix != nil
        let m = spec.matrix ?? [1, 0, 0, 0, 1, 0, 0, 0, 1]
        m00 = m[0]; m01 = m[1]; m02 = m[2]
        m10 = m[3]; m11 = m[4]; m12 = m[5]
        m20 = m[6]; m21 = m[7]; m22 = m[8]
        th = spec.quantizer.thresholds
        co = spec.quantizer.coarse
        thScale = spec.quantizer.bucketScale
        hasOOTF = spec.hlgOOTF != nil
        let ootf = spec.hlgOOTF ?? (0, 0, 0, 0)
        ootfExp = ootf.exponent
        lumR = ootf.lumR
        lumG = ootf.lumG
        lumB = ootf.lumB
    }

    /// Linear target-space RGB for one XYB sample (opsin intensity scale +
    /// matrix + HLG OOTF applied).
    @inline(__always)
    func linear(_ x: Float, _ y: Float, _ b: Float) -> (Float, Float, Float) {
        let gr = (y + x) + biasCbrtR
        let gg = (y - x) + biasCbrtG
        let gb = b + biasCbrtB
        let mr = gr * gr * gr - biasR
        let mg = gg * gg * gg - biasG
        let mb = gb * gb * gb - biasB
        var lr = io00 * mr + io01 * mg + io02 * mb
        var lg = io10 * mr + io11 * mg + io12 * mb
        var lb = io20 * mr + io21 * mg + io22 * mb
        lr *= opsinScale
        lg *= opsinScale
        lb *= opsinScale
        if hasMatrix {
            let tr = m00 * lr + m01 * lg + m02 * lb
            let tg = m10 * lr + m11 * lg + m12 * lb
            let tb = m20 * lr + m21 * lg + m22 * lb
            lr = tr
            lg = tg
            lb = tb
        }
        if hasOOTF {
            let luminance = lumR * lr + lumG * lg + lumB * lb
            if luminance > 0 {
                let ratio = min(powf(luminance, ootfExp), 1e9)
                lr *= ratio
                lg *= ratio
                lb *= ratio
            }
        }
        return (lr, lg, lb)
    }

    @inline(__always)
    func convert(_ x: Float, _ y: Float, _ b: Float) -> (UInt8, UInt8, UInt8) {
        let (lr, lg, lb) = linear(x, y, b)
        return (
            encodeSample8(lr, th, co, thScale), encodeSample8(lg, th, co, thScale),
            encodeSample8(lb, th, co, thScale)
        )
    }
}

// MARK: - YCbCr output (JPEG transcodes; libjxl stage_ycbcr.cc)

/// Full-range BT.601 as defined by JFIF Clause 7. The planes hold Cb (x slot),
/// Y' (y slot), Cr (b slot); the result is already display-encoded (no
/// transfer function), so quantization is a plain round to 8 bits.
@inline(__always)
private func ycbcrPixel(_ cb: Float, _ y: Float, _ cr: Float) -> (UInt8, UInt8, UInt8) {
    let c128: Float = 128.0 / 255
    let yy = y + c128
    let r = yy + 1.402 * cr
    let g = yy + (-0.114 * 1.772 / 0.587) * cb + (-0.299 * 1.402 / 0.587) * cr
    let b = yy + 1.772 * cb
    @inline(__always) func to8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, (v * 255).rounded())))
    }
    return (to8(r), to8(g), to8(b))
}

/// Converts YCbCr planes to three planar 8-bit RGB channels, row-parallel.
func ycbcrToRGB8Planes(_ img: XYBImage) -> [[Int32]] {
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
        nonisolated(unsafe) let pcb = xBuf.baseAddress!
        nonisolated(unsafe) let py = yBuf.baseAddress!
        nonisolated(unsafe) let pcr = bSrcBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: img.height) { y in
            let row = y * stride
            let dstRow = y * width
            for x in 0..<width {
                let (r, g, b) = ycbcrPixel(pcb[row + x], py[row + x], pcr[row + x])
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

/// Converts YCbCr planes to interleaved 8-bit RGB, row-parallel.
func ycbcrToRGB8Interleaved(_ img: XYBImage) -> [UInt8] {
    var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
    let width = img.width
    let stride = img.stride
    img.x.withUnsafeBufferPointer { xBuf in
    img.y.withUnsafeBufferPointer { yBuf in
    img.b.withUnsafeBufferPointer { bBuf in
    rgb.withUnsafeMutableBufferPointer { outBuf in
        nonisolated(unsafe) let pcb = xBuf.baseAddress!
        nonisolated(unsafe) let py = yBuf.baseAddress!
        nonisolated(unsafe) let pcr = bBuf.baseAddress!
        nonisolated(unsafe) let out = outBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: img.height) { y in
            let row = y * stride
            var dst = y * width * 3
            for x in 0..<width {
                let (r, g, b) = ycbcrPixel(pcb[row + x], py[row + x], pcr[row + x])
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

/// Converts XYB planes to three planar 16-bit channels (values 0...65535 as
/// Int32), row-parallel. The 16-bit quantizer table is built per call
/// (~milliseconds) — negligible against the decode itself.
func xybToRGB16Planes(_ img: XYBImage, spec: OutputColorSpec) -> [[Int32]] {
    let width = img.width
    let stride = img.stride
    var planeR = [Int32](repeating: 0, count: img.width * img.height)
    var planeG = planeR
    var planeB = planeR
    let state = ConvertState(spec)
    let quantizer16 = TransferQuantizer16(transfer: spec.transfer)
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
        nonisolated(unsafe) let th = quantizer16.thresholds
        nonisolated(unsafe) let co = quantizer16.coarse
        let thScale = quantizer16.bucketScale
        DispatchQueue.concurrentPerform(iterations: img.height) { y in
            let row = y * stride
            let dstRow = y * width
            for x in 0..<width {
                let (lr, lg, lb) = state.linear(px[row + x], py[row + x], pb[row + x])
                pr[dstRow + x] = Int32(encodeSample16(lr, th, co, thScale))
                pg[dstRow + x] = Int32(encodeSample16(lg, th, co, thScale))
                pbOut[dstRow + x] = Int32(encodeSample16(lb, th, co, thScale))
            }
        }
        withExtendedLifetime(quantizer16) {}
    }
    }
    }
    }
    }
    }
    return [planeR, planeG, planeB]
}

/// Converts XYB planes to three planar 32-bit float channels holding the
/// transfer-encoded values (IEEE-754 bit patterns in Int32, matching the
/// Modular float convention), row-parallel. Unlike the integer paths, values
/// are NOT clamped to [0, 1] before the transfer — HDR headroom survives for
/// linear output; PQ/HLG/gamma curves clamp inherently.
func xybToRGBFloatPlanes(_ img: XYBImage, spec: OutputColorSpec) -> [[Int32]] {
    let width = img.width
    let stride = img.stride
    var planeR = [Int32](repeating: 0, count: img.width * img.height)
    var planeG = planeR
    var planeB = planeR
    let state = ConvertState(spec)
    let transfer = spec.transfer
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
            @inline(__always) func enc(_ v: Float) -> Int32 {
                Int32(bitPattern: transfer.encodeExtended(v).bitPattern)
            }
            for x in 0..<width {
                let (lr, lg, lb) = state.linear(px[row + x], py[row + x], pb[row + x])
                pr[dstRow + x] = enc(lr)
                pg[dstRow + x] = enc(lg)
                pbOut[dstRow + x] = enc(lb)
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
