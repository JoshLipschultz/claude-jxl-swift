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

    /// The CGColorSpace describing samples rendered with `encoding`'s numeric
    /// color encoding, when a well-known one matches (ITU-R 2100 PQ/HLG for
    /// HDR, Display P3, ITU-R 2020, BT.709, sRGB). nil falls back to device
    /// RGB. Tagging matters even for SDR: untagged (device) content skips
    /// color management entirely — BT.709-transfer samples read as the
    /// display's own response shift every mid-tone.
    public static func displayColorSpace(for encoding: JXLColorEncoding?) -> CGColorSpace? {
        guard let encoding, !encoding.wantICC, !encoding.hasGamma else { return nil }
        switch (encoding.primaries, encoding.transferFunction) {
        case (9, 16): return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case (9, 18): return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case (9, _): return CGColorSpace(name: CGColorSpace.itur_2020)
        case (11, 13): return CGColorSpace(name: CGColorSpace.displayP3)
        // sRGB primaries (or unsignaled = sRGB): match the transfer. Custom
        // primaries (2) stay nil — their samples are in a space CG has no
        // name for.
        case (0, 1), (1, 1): return CGColorSpace(name: CGColorSpace.itur_709)
        case (0, 8), (1, 8): return CGColorSpace(name: CGColorSpace.linearSRGB)
        case (0, 0), (0, 2), (0, 13), (1, 0), (1, 2), (1, 13):
            return CGColorSpace(name: CGColorSpace.sRGB)
        default: return nil
        }
    }

    /// Builds a `CGImage` from a decoded image — RGBA8 normally, RGBA16 when
    /// the decode used `JXLSampleFormat.uint16` (HDR precision survives).
    /// `orientation` is the EXIF orientation (1...8) from the file metadata;
    /// `colorEncoding` (when given) tags the image with the matching display
    /// color space (ITU-R 2100 PQ/HLG for HDR files) so the system composites
    /// it correctly, including EDR.
    public static func makeCGImage(
        from image: JXLDecodedImage, orientation: UInt32 = 1,
        colorEncoding: JXLColorEncoding? = nil,
        alphaPremultiplied: Bool = false
    ) throws -> CGImage {
        guard image.width > 0, image.height > 0 else { throw ConversionError.emptyImage }
        guard image.colorChannels >= 1, image.planes.count >= image.colorChannels else {
            throw ConversionError.missingPlanes
        }
        if image.bitsPerSample == 16 && !image.isFloat {
            return try makeCGImage16(
                from: image, orientation: orientation, colorEncoding: colorEncoding,
                alphaPremultiplied: alphaPremultiplied)
        }

        let width = image.width
        let height = image.height
        let pixelCount = width * height

        let isGray = image.colorChannels == 1
        let r = image.planes[0]
        let g = isGray ? image.planes[0] : image.planes[1]
        let b = isGray ? image.planes[0] : image.planes[2]
        let alpha: [Int32]? = image.extraChannels > 0 ? image.planes[image.colorChannels] : nil

        // Per-sample normaliser to 0...255. Samples are SIGNED: lossy decode
        // legitimately produces values below 0 / above maxVal (libjxl clamps
        // at output). Reinterpreting as unsigned wraps −1 to opaque/full —
        // black fringes wherever a lossy alpha edge rings negative.
        let maxVal = image.bitsPerSample >= 31 ? 0 : (1 << image.bitsPerSample) - 1
        let inv = maxVal > 0 ? 255.0 / Double(maxVal) : 0
        @inline(__always) func norm(_ sample: Int32) -> UInt8 {
            if image.isFloat {
                let f = Float(bitPattern: UInt32(bitPattern: sample))
                let clamped = f.isNaN ? 0 : min(max(f, 0), 1)
                return UInt8(clamped * 255 + 0.5)
            }
            let v = Double(sample) * inv
            return UInt8(min(max(v, 0), 255) + 0.5)
        }

        // Premultiplied for display: scaling/filtering straight-alpha content
        // bleeds the (arbitrary) RGB of fully transparent pixels into visible
        // edges — dark halos around lossy alpha edges. Files with associated
        // alpha are already premultiplied; only the tag changes for them.
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            for i in 0..<pixelCount {
                let o = i * 4
                let a = alpha.map { norm($0[i]) } ?? 255
                if let _ = alpha, !alphaPremultiplied, a != 255 {
                    let ai = Int(a)
                    out[o + 0] = UInt8((Int(norm(r[i])) * ai + 127) / 255)
                    out[o + 1] = UInt8((Int(norm(g[i])) * ai + 127) / 255)
                    out[o + 2] = UInt8((Int(norm(b[i])) * ai + 127) / 255)
                } else {
                    out[o + 0] = norm(r[i])
                    out[o + 1] = norm(g[i])
                    out[o + 2] = norm(b[i])
                }
                out[o + 3] = a
            }
        }

        // Tag with the embedded ICC profile when the decoder attached one (its
        // samples are in that space), else a matching well-known display
        // space, else device RGB.
        let colorSpace = image.iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) }
            ?? displayColorSpace(for: colorEncoding)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: alpha != nil
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.last.rawValue)
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

    /// 16-bit RGBA path: preserves the full sample precision (needed for PQ/
    /// HLG, whose 8-bit quantization visibly bands) and tags the HDR color
    /// space so the window server applies the right tone mapping / EDR.
    private static func makeCGImage16(
        from image: JXLDecodedImage, orientation: UInt32, colorEncoding: JXLColorEncoding?,
        alphaPremultiplied: Bool = false
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        let pixelCount = width * height
        let isGray = image.colorChannels == 1
        let r = image.planes[0]
        let g = isGray ? image.planes[0] : image.planes[1]
        let b = isGray ? image.planes[0] : image.planes[2]
        let alpha: [Int32]? = image.extraChannels > 0 ? image.planes[image.colorChannels] : nil

        // Premultiplied for display (see the 8-bit path).
        var rgba = [UInt16](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            for i in 0..<pixelCount {
                let o = i * 4
                let a = alpha.map { UInt16(clamping: $0[i]) } ?? 65535
                if let _ = alpha, !alphaPremultiplied, a != 65535 {
                    let ai = Int(a)
                    out[o + 0] = UInt16((Int(UInt16(clamping: r[i])) * ai + 32767) / 65535)
                    out[o + 1] = UInt16((Int(UInt16(clamping: g[i])) * ai + 32767) / 65535)
                    out[o + 2] = UInt16((Int(UInt16(clamping: b[i])) * ai + 32767) / 65535)
                } else {
                    out[o + 0] = UInt16(clamping: r[i])
                    out[o + 1] = UInt16(clamping: g[i])
                    out[o + 2] = UInt16(clamping: b[i])
                }
                out[o + 3] = a
            }
        }
        let colorSpace = displayColorSpace(for: colorEncoding)
            ?? image.iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) }
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: (alpha != nil
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.last.rawValue)
                | CGBitmapInfo.byteOrder16Little.rawValue)
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard
            let provider = CGDataProvider(data: data as CFData),
            let cg = CGImage(
                width: width, height: height,
                bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                space: colorSpace, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw ConversionError.cgImageCreationFailed }
        // Orientation is baked via a 16-bit context to keep the precision.
        guard (2...8).contains(orientation) else { return cg }
        let swap = orientation >= 5
        guard
            let ctx = CGContext(
                data: nil, width: swap ? height : width, height: swap ? width : height,
                bitsPerComponent: 16, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return cg }
        ctx.concatenate(orientationTransform(orientation, width: width, height: height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? cg
    }

    /// The affine transform for an EXIF orientation (shared by both depths).
    private static func orientationTransform(
        _ orientation: UInt32, width w: Int, height h: Int
    ) -> CGAffineTransform {
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(w), ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h))
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: CGFloat(h), ty: CGFloat(w))
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w))
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)
        default: return .identity
        }
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
