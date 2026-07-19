// ICCOutput.swift
//
// Output-side color management for files whose color encoding is an embedded
// ICC profile (`want_icc`). Matrix + TRC display profiles (the shape cjxl
// embeds for tagged inputs: rXYZ/gXYZ/bXYZ colorants and per-channel tone
// curves, or a gray profile's kTRC) are converted exactly: linear sRGB from
// the XYB pipeline goes through Bradford D65→D50 into the profile's PCS,
// through the inverted colorant matrix into device-linear RGB, then through
// the inverted TRC. Profiles outside that shape (CLUT/A2B-only, CMYK) return
// nil and the decoder keeps its sRGB fallback.

import Foundation

/// One TRC curve in its *decode* direction (device-encoded -> linear), plus a
/// numeric inverse for output encoding. Curves are monotone non-decreasing.
final class ICCToneCurve: Sendable {
    private enum Shape: Sendable {
        case identity
        case gamma(Double)
        /// 'curv' sample table over encoded [0,1] -> linear values.
        case table([Double])
        /// 'para' parametric curve (ICC types 0-4), canonicalized to the
        /// seven-parameter form: Y = (aX+b)^g + e for X >= d, cX + f below.
        case parametric(g: Double, a: Double, b: Double, c: Double, d: Double, e: Double, f: Double)
    }

    private let shape: Shape

    private init(_ shape: Shape) { self.shape = shape }

    static let identity = ICCToneCurve(.identity)
    static func gamma(_ g: Double) -> ICCToneCurve { ICCToneCurve(.gamma(g)) }
    static func table(_ t: [Double]) -> ICCToneCurve { ICCToneCurve(.table(t)) }
    static func parametric(
        g: Double, a: Double, b: Double, c: Double, d: Double, e: Double, f: Double
    ) -> ICCToneCurve {
        ICCToneCurve(.parametric(g: g, a: a, b: b, c: c, d: d, e: e, f: f))
    }

    /// Decode: encoded [0,1] -> linear.
    func decode(_ s: Double) -> Double {
        let x = min(max(s, 0), 1)
        switch shape {
        case .identity:
            return x
        case .gamma(let g):
            return pow(x, g)
        case .table(let t):
            guard t.count >= 2 else { return t.first ?? x }
            let pos = x * Double(t.count - 1)
            let i = min(Int(pos), t.count - 2)
            let frac = pos - Double(i)
            return t[i] + (t[i + 1] - t[i]) * frac
        case .parametric(let g, let a, let b, let c, let d, let e, let f):
            return x >= d ? pow(a * x + b, g) + e : c * x + f
        }
    }

    /// Encode: linear -> encoded [0,1] (numeric inverse of `decode`).
    func encode(_ v: Double) -> Double {
        switch shape {
        case .identity:
            return min(max(v, 0), 1)
        case .gamma(let g):
            return pow(min(max(v, 0), 1), 1.0 / g)
        case .table(let t):
            guard t.count >= 2 else { return min(max(v, 0), 1) }
            if v <= t[0] { return 0 }
            if v >= t[t.count - 1] { return 1 }
            // Binary search for the segment containing v (monotone table;
            // plateaus resolve to the segment's left edge like lcms).
            var lo = 0
            var hi = t.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if t[mid] <= v { lo = mid } else { hi = mid }
            }
            let span = t[hi] - t[lo]
            let frac = span > 0 ? (v - t[lo]) / span : 0
            return (Double(lo) + frac) / Double(t.count - 1)
        case .parametric(let g, let a, let b, let c, let d, let e, let f):
            let x = min(max(v, 0), 1)
            // Value of the curve at the breakpoint decides which branch.
            let atBreak = c * d + f
            if x <= atBreak, c != 0 {
                return min(max((x - f) / c, 0), 1)
            }
            guard a != 0 else { return 0 }
            let base = x - e
            if base <= 0 { return min(max(d, 0), 1) }
            return min(max((pow(base, 1.0 / g) - b) / a, 0), 1)
        }
    }
}

/// A parsed matrix + TRC ICC profile, ready for output conversion.
struct ICCOutputProfile {
    let isGray: Bool
    /// linear sRGB (D65) -> device-linear RGB, row-major 3x3 (identity-like
    /// for gray profiles).
    let matrix: [Float]?
    /// Shared TRC (all channels equal — profiles with distinct per-channel
    /// curves fall back to sRGB output).
    let trc: ICCToneCurve
}

private let kD50 = JXLChromaticity(x: 0.34567, y: 0.35850)
private let kD65ICC = JXLChromaticity(x: 0.3127, y: 0.3290)
private let kSRGBPrimariesICC = [
    JXLChromaticity(x: 0.64, y: 0.33), JXLChromaticity(x: 0.30, y: 0.60),
    JXLChromaticity(x: 0.15, y: 0.06),
]

/// Parses `data` as a matrix+TRC (or gray+TRC) ICC profile. Returns nil for
/// any profile outside that shape.
func parseICCOutputProfile(_ data: [UInt8]) -> ICCOutputProfile? {
    guard data.count >= 132 else { return nil }
    func u32(_ o: Int) -> Int {
        Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3])
    }
    func sig(_ o: Int) -> String {
        String(bytes: data[o..<o + 4], encoding: .ascii) ?? ""
    }
    guard u32(0) == data.count || u32(0) <= data.count else { return nil }
    let colorSpace = sig(16)
    let pcs = sig(20)
    guard pcs == "XYZ " else { return nil }
    let isGray = colorSpace == "GRAY"
    guard isGray || colorSpace == "RGB " else { return nil }

    let tagCount = u32(128)
    guard tagCount > 0, tagCount < 1024, 132 + tagCount * 12 <= data.count else { return nil }
    var tags: [String: (offset: Int, size: Int)] = [:]
    for i in 0..<tagCount {
        let base = 132 + i * 12
        let name = sig(base)
        let off = u32(base + 4)
        let size = u32(base + 8)
        guard off >= 0, size >= 4, off + size <= data.count else { return nil }
        tags[name] = (off, size)
    }

    // s15Fixed16 XYZ triple from an 'XYZ ' tag.
    func xyzTag(_ name: String) -> (Double, Double, Double)? {
        guard let t = tags[name], t.size >= 20, sig(t.offset) == "XYZ " else { return nil }
        func s15(_ o: Int) -> Double {
            let raw = Int32(bitPattern: UInt32(u32(o)))
            return Double(raw) / 65536.0
        }
        return (s15(t.offset + 8), s15(t.offset + 12), s15(t.offset + 16))
    }

    func curveTag(_ name: String) -> ICCToneCurve? {
        guard let t = tags[name] else { return nil }
        let o = t.offset
        switch sig(o) {
        case "curv":
            let n = u32(o + 8)
            if n == 0 { return .identity }
            if n == 1 {
                // u8.8 fixed gamma.
                let g = Double(u32(o + 12) >> 16) / 256.0
                return g > 0 ? .gamma(g) : nil
            }
            guard t.size >= 12 + 2 * n, n <= 1 << 16 else { return nil }
            var table = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let v = Int(data[o + 12 + 2 * i]) << 8 | Int(data[o + 12 + 2 * i + 1])
                table[i] = Double(v) / 65535.0
            }
            return .table(table)
        case "para":
            let type = u32(o + 8) >> 16
            func s15(_ i: Int) -> Double {
                Double(Int32(bitPattern: UInt32(u32(o + 12 + 4 * i)))) / 65536.0
            }
            switch type {
            case 0: return .gamma(s15(0))
            case 1:
                // Y = (aX+b)^g for X >= -b/a, else 0.
                let g = s15(0), a = s15(1), b = s15(2)
                guard a != 0 else { return nil }
                return .parametric(g: g, a: a, b: b, c: 0, d: -b / a, e: 0, f: 0)
            case 2:
                let g = s15(0), a = s15(1), b = s15(2), c = s15(3)
                guard a != 0 else { return nil }
                return .parametric(g: g, a: a, b: b, c: 0, d: -b / a, e: c, f: c)
            case 3:
                // The sRGB shape: Y = (aX+b)^g for X >= d, cX below.
                return .parametric(g: s15(0), a: s15(1), b: s15(2), c: s15(3), d: s15(4), e: 0, f: 0)
            case 4:
                return .parametric(
                    g: s15(0), a: s15(1), b: s15(2), c: s15(3), d: s15(4), e: s15(5), f: s15(6))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    if isGray {
        guard let trc = curveTag("kTRC") else { return nil }
        return ICCOutputProfile(isGray: true, matrix: nil, trc: trc)
    }

    guard let r = xyzTag("rXYZ"), let g = xyzTag("gXYZ"), let b = xyzTag("bXYZ") else {
        return nil
    }
    // All three TRCs must exist; distinct curves are only accepted when their
    // tag data is shared (common) or equal — the output spec carries one curve.
    guard let rt = tags["rTRC"], let gt = tags["gTRC"], let bt = tags["bTRC"] else { return nil }
    let sharedOffsets = rt.offset == gt.offset && gt.offset == bt.offset
    if !sharedOffsets {
        let ra = Array(data[rt.offset..<rt.offset + rt.size])
        let ga = Array(data[gt.offset..<gt.offset + gt.size])
        let ba = Array(data[bt.offset..<bt.offset + bt.size])
        guard ra == ga, ga == ba else { return nil }
    }
    guard let trc = curveTag("rTRC") else { return nil }

    // Colorant matrix: device-linear -> PCS XYZ (already D50-adapted in v2/v4
    // display profiles). Column-major from the three colorant vectors.
    let colorants: [Double] = [
        r.0, g.0, b.0,
        r.1, g.1, b.1,
        r.2, g.2, b.2,
    ]
    let det =
        colorants[0] * (colorants[4] * colorants[8] - colorants[5] * colorants[7])
        - colorants[1] * (colorants[3] * colorants[8] - colorants[5] * colorants[6])
        + colorants[2] * (colorants[3] * colorants[7] - colorants[4] * colorants[6])
    guard abs(det) > 1e-9 else { return nil }

    // linear sRGB (D65) -> XYZ(D65) -> Bradford to D50 -> device linear.
    let srgbToXYZ = rgbToXYZMatrix(primaries: kSRGBPrimariesICC, white: kD65ICC)
    let adapt = bradfordAdaptation(from: kD65ICC, to: kD50)
    let m = mul3(inv3(colorants), mul3(adapt, srgbToXYZ))
    return ICCOutputProfile(isGray: false, matrix: m.map(Float.init), trc: trc)
}
