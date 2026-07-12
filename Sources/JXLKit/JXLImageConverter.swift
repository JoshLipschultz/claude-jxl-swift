// JXLImageConverter.swift
//
// Bridges the decoder's `JXLDecodedImage` (one Int32 plane per channel) to a
// displayable `CGImage`. This is the only place that knows the plane layout:
// color channels first (1 = grayscale, 3 = RGB), then extra channels, with the
// first extra channel treated as alpha. Shared by the viewer app, the Quick
// Look extension, and any other CoreGraphics consumer — JXLCore itself stays
// Foundation-only.
//
// Output is always 8-bit straight-alpha RGBA in device RGB, which is plenty for
// on-screen inspection. 16-bit and 32-bit-float sources are tone-mapped down to
// 8 bits (float is clamped to [0, 1], matching the CLI's PNM/PFM behaviour).

import CoreGraphics
import Foundation
import JXLCore

public enum JXLImageConverter {

    public enum ConversionError: Error, CustomStringConvertible, Sendable {
        case emptyImage
        case missingPlanes
        case cgImageCreationFailed

        public var description: String {
            switch self {
            case .emptyImage: return "image has zero width or height"
            case .missingPlanes: return "decoded image is missing colour planes"
            case .cgImageCreationFailed: return "could not build a CGImage from the pixels"
            }
        }
    }

    /// Builds an RGBA8 `CGImage` from a decoded image. `orientation` is the EXIF
    /// orientation (1...8) from the file metadata; it is applied here so callers
    /// show pixels the right way up.
    public static func makeCGImage(from image: JXLDecodedImage, orientation: UInt32 = 1) throws -> CGImage {
        guard image.width > 0, image.height > 0 else { throw ConversionError.emptyImage }
        guard image.colorChannels >= 1, image.planes.count >= image.colorChannels else {
            throw ConversionError.missingPlanes
        }

        let width = image.width
        let height = image.height
        let pixelCount = width * height

        let isGray = image.colorChannels == 1
        let r = image.planes[0]
        let g = isGray ? image.planes[0] : image.planes[1]
        let b = isGray ? image.planes[0] : image.planes[2]
        let alpha: [Int32]? = image.extraChannels > 0 ? image.planes[image.colorChannels] : nil

        // Per-sample normaliser to 0...255.
        let maxVal = image.bitsPerSample >= 31 ? 0 : (1 << image.bitsPerSample) - 1
        let inv = maxVal > 0 ? 255.0 / Double(maxVal) : 0
        @inline(__always) func norm(_ sample: Int32) -> UInt8 {
            if image.isFloat {
                let f = Float(bitPattern: UInt32(bitPattern: sample))
                let clamped = f.isNaN ? 0 : min(max(f, 0), 1)
                return UInt8(clamped * 255 + 0.5)
            }
            let v = Double(UInt32(bitPattern: sample)) * inv
            return UInt8(min(max(v, 0), 255) + 0.5)
        }

        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            for i in 0..<pixelCount {
                let o = i * 4
                out[o + 0] = norm(r[i])
                out[o + 1] = norm(g[i])
                out[o + 2] = norm(b[i])
                out[o + 3] = alpha.map { norm($0[i]) } ?? 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let cg = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw ConversionError.cgImageCreationFailed }

        return applyOrientation(orientation, to: cg)
    }

    /// Re-renders `image` with the given EXIF orientation baked in. Orientation 1
    /// (or anything unrecognised) returns the image unchanged.
    private static func applyOrientation(_ orientation: UInt32, to image: CGImage) -> CGImage {
        guard (2...8).contains(orientation) else { return image }

        let w = image.width
        let h = image.height
        // Orientations 5...8 swap the axes.
        let swap = orientation >= 5
        let outW = swap ? h : w
        let outH = swap ? w : h

        guard
            let ctx = CGContext(
                data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        // Build the transform that maps the source rect into the output rect.
        // CGContext is y-up, so this mirrors the standard CGImagePropertyOrientation table.
        var t = CGAffineTransform.identity
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(w), ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h))
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: CGFloat(h), ty: CGFloat(w))
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w))
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)
        default: break
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
