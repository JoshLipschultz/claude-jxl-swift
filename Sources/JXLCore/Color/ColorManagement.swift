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
private let kInverseOpsin: [Float] = [
    11.031566901960783, -9.866943921568629, -0.16462299647058826,
    -3.254147380392157, 4.418770392156863, -0.16462299647058826,
    -3.6588512862745097, 2.7129230470588235, 1.9459282392156863,
]

private func srgbEncode(_ d: Float) -> Float {
    let v = max(0, min(1, d))
    return v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1.0 / 2.4) - 0.055
}

/// XYB -> sRGB 8-bit, matching libjxl XybToRgb + the sRGB transfer function.
func xybToSRGB8(x: Float, y: Float, b: Float) -> (UInt8, UInt8, UInt8) {
    // libjxl opsin_biases_cbrt = cbrt(-bias) = -cbrt(bias), and XybToRgb
    // subtracts it — i.e. adds cbrt(bias) — to recover cbrt(mixed).
    let biasCbrt = cbrtf(kOpsinBias)
    let gr = (y + x) + biasCbrt
    let gg = (y - x) + biasCbrt
    let gb = b + biasCbrt
    let mr = gr * gr * gr - kOpsinBias
    let mg = gg * gg * gg - kOpsinBias
    let mb = gb * gb * gb - kOpsinBias
    let lr = kInverseOpsin[0] * mr + kInverseOpsin[1] * mg + kInverseOpsin[2] * mb
    let lg = kInverseOpsin[3] * mr + kInverseOpsin[4] * mg + kInverseOpsin[5] * mb
    let lb = kInverseOpsin[6] * mr + kInverseOpsin[7] * mg + kInverseOpsin[8] * mb
    func to8(_ l: Float) -> UInt8 { UInt8(max(0, min(255, (srgbEncode(l) * 255).rounded()))) }
    return (to8(lr), to8(lg), to8(lb))
}

/// Converts XYB planes to interleaved 8-bit sRGB (RGB, row-major, unpadded).
func xybToSRGB8Interleaved(_ img: XYBImage) -> [UInt8] {
    var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
    for y in 0..<img.height {
        for x in 0..<img.width {
            let src = y * img.stride + x
            let (r, g, b) = xybToSRGB8(x: img.x[src], y: img.y[src], b: img.b[src])
            let dst = (y * img.width + x) * 3
            rgb[dst] = r
            rgb[dst + 1] = g
            rgb[dst + 2] = b
        }
    }
    return rgb
}

/// Converts XYB planes to three planar 8-bit sRGB channels in the
/// `JXLDecodedImage` sample representation.
func xybToSRGB8Planes(_ img: XYBImage) -> [[Int32]] {
    var planes = [[Int32]](
        repeating: [Int32](repeating: 0, count: img.width * img.height), count: 3)
    for y in 0..<img.height {
        for x in 0..<img.width {
            let src = y * img.stride + x
            let (r, g, b) = xybToSRGB8(x: img.x[src], y: img.y[src], b: img.b[src])
            let dst = y * img.width + x
            planes[0][dst] = Int32(r)
            planes[1][dst] = Int32(g)
            planes[2][dst] = Int32(b)
        }
    }
    return planes
}
