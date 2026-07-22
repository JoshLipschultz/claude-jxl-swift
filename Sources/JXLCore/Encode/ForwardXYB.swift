// ForwardXYB.swift
//
// Forward color + transform math for the lossy (VarDCT) encoder — the exact
// numeric inverses of the decoder's own output pipeline:
//
//   * Forward opsin (linear sRGB -> XYB): inverts `ConvertState.linear`
//     (Color/ColorManagement.swift). The 3x3 forward absorbance matrix is the
//     numeric inverse of the decoder's inverse-opsin matrix, computed once
//     from the decoder's own `ConvertState` scalars (so a file-default encode
//     inverts exactly what the decoder will apply — the load-bearing rule).
//     Sequence: mixed = M_fwd * linear; g = cbrt(mixed + bias); then
//     X = (gR − gG)/2, Y = (gR + gG)/2 − cbrt(bias), B = gB − cbrt(bias),
//     because the decoder computes gR = (Y+X) + cbrt(bias),
//     mixedR = gR³ − bias, linear = M_inv * mixed.
//
//   * The sRGB EOTF (encoded -> linear), mirroring the decoder's
//     `OutputTransfer.srgb.inverse` code exactly (same constants/branch).
//
//   * Forward scaled DCT8 producing coefficients in the decoder's storage
//     convention for square blocks (`scaledIDCT` with h = w = 8: transposed
//     storage S[u*8+v] = F[v][u], self-normalizing basis w(0)=1, w(k>0)=√2,
//     forward scale 1/N per axis so DC == block mean). The suite pins
//     forward -> decoder-inverse == identity.

import Foundation

/// The forward opsin parameters, derived from the decoder's `ConvertState`
/// for the default (spec) opsin so encode is the numeric inverse of decode.
struct ForwardOpsin {
    /// Row-major linear-RGB -> mixed absorbance matrix (inverse of the
    /// decoder's inverse-opsin matrix).
    let m: [Double]
    let bias: Double
    let biasCbrt: Double

    init() {
        let spec = OutputColorSpec(
            matrix: nil, quantizer: srgb8Quantizer, transfer: .srgb,
            hlgOOTF: nil, opsinScale: 1, customOpsin: nil)
        let s = ConvertState(spec)
        let inv: [Double] = [
            Double(s.io00), Double(s.io01), Double(s.io02),
            Double(s.io10), Double(s.io11), Double(s.io12),
            Double(s.io20), Double(s.io21), Double(s.io22),
        ]
        m = ForwardOpsin.invert3x3(inv)
        // Default opsin: the three channel biases are identical.
        bias = Double(s.biasR)
        biasCbrt = Double(s.biasCbrtR)
    }

    /// Exact 3x3 inverse via the adjugate (Double).
    static func invert3x3(_ a: [Double]) -> [Double] {
        let det =
            a[0] * (a[4] * a[8] - a[5] * a[7])
            - a[1] * (a[3] * a[8] - a[5] * a[6])
            + a[2] * (a[3] * a[7] - a[4] * a[6])
        precondition(abs(det) > 1e-12, "singular opsin matrix")
        let d = 1.0 / det
        return [
            (a[4] * a[8] - a[5] * a[7]) * d,
            (a[2] * a[7] - a[1] * a[8]) * d,
            (a[1] * a[5] - a[2] * a[4]) * d,
            (a[5] * a[6] - a[3] * a[8]) * d,
            (a[0] * a[8] - a[2] * a[6]) * d,
            (a[2] * a[3] - a[0] * a[5]) * d,
            (a[3] * a[7] - a[4] * a[6]) * d,
            (a[1] * a[6] - a[0] * a[7]) * d,
            (a[0] * a[4] - a[1] * a[3]) * d,
        ]
    }

    /// Linear RGB (0…1) -> XYB, the exact inverse of `ConvertState.linear`
    /// with opsinScale 1 (SDR default intensity target).
    @inline(__always)
    func xyb(_ r: Double, _ g: Double, _ b: Double) -> (x: Double, y: Double, b: Double) {
        let tr = m[0] * r + m[1] * g + m[2] * b
        let tg = m[3] * r + m[4] * g + m[5] * b
        let tb = m[6] * r + m[7] * g + m[8] * b
        let gr = cbrt(max(tr + bias, 0))
        let gg = cbrt(max(tg + bias, 0))
        let gb = cbrt(max(tb + bias, 0))
        return ((gr - gg) * 0.5, (gr + gg) * 0.5 - biasCbrt, gb - biasCbrt)
    }
}

/// sRGB EOTF (encoded -> linear), the decoder's `OutputTransfer.srgb.inverse`.
@inline(__always)
func srgbToLinear(_ s: Double) -> Double {
    s <= 0.0031308 * 12.92 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
}

// MARK: - Forward DCT8

/// Forward basis rows: `fdct8Basis[k*8 + t] = w(k)/8 * cos((2t+1) k π / 16)`
/// with w(0)=1, w(k>0)=√2 — the exact inverse weighting of `makeIDCTBasis(8)`
/// in DCTTransforms.swift (the 1D basis has squared norm 8 per frequency, so
/// dividing by 8 makes forward∘inverse the identity).
private let fdct8Basis: [Double] = {
    var b = [Double](repeating: 0, count: 64)
    for k in 0..<8 {
        let w: Double = k == 0 ? 1.0 : 2.0.squareRoot()
        for t in 0..<8 {
            b[k * 8 + t] = w / 8.0 * cos(Double(2 * t + 1) * Double(k) * Double.pi / 16.0)
        }
    }
    return b
}()

/// Forward scaled DCT of one 8x8 pixel block into the decoder's coefficient
/// storage for square blocks: `out[u*8 + v] = F[v][u]` (v = vertical
/// frequency, u = horizontal), the layout `scaledIDCT(h:8, w:8)` consumes.
/// `pixels` is row-major with `stride` floats per row; `out` gets 64 values.
/// out[0] is the DC coefficient (== the block mean).
func forwardDCT8(
    pixels: UnsafePointer<Float>, stride: Int, out: UnsafeMutablePointer<Float>
) {
    // Pass 1 (horizontal): t1[u*8 + y] = Σ_x basis[u][x] * p[y][x].
    var t1 = [Double](repeating: 0, count: 64)
    fdct8Basis.withUnsafeBufferPointer { fb in
        t1.withUnsafeMutableBufferPointer { t1b in
            for y in 0..<8 {
                let row = pixels + y * stride
                for u in 0..<8 {
                    var s = 0.0
                    let basisRow = u * 8
                    for x in 0..<8 { s += fb[basisRow + x] * Double(row[x]) }
                    t1b[u * 8 + y] = s
                }
            }
            // Pass 2 (vertical): out[u*8 + v] = Σ_y basis[v][y] * t1[u*8 + y].
            for u in 0..<8 {
                for v in 0..<8 {
                    var s = 0.0
                    let basisRow = v * 8
                    for y in 0..<8 { s += fb[basisRow + y] * t1b[u * 8 + y] }
                    out[u * 8 + v] = Float(s)
                }
            }
        }
    }
}
