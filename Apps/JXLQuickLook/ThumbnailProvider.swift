// ThumbnailProvider.swift
//
// Quick Look thumbnail provider for .jxl files (M10). Decodes the image with
// JXLCore, bridges it to a `CGImage` via JXLKit (profile-aware, EXIF
// orientation applied), and draws it aspect-fit into the requested thumbnail
// context. Built as an appex embedded in JXLViewer.app; see project.yml.
//
// The decode mirrors the viewer's DecodePipeline so thumbnails match what the
// app shows:
//   • HDR files (PQ/HLG transfer) decode at 16-bit and are tagged with their
//     ITU-R 2100 color space, so wide-gamut/HDR content isn't crushed to 8-bit
//     sRGB and mis-rendered.
//   • The decoded planes are always tagged with the file's color encoding
//     (BT.709 / Display P3 / 2020 / sRGB) so ColorSync composites correctly —
//     an untagged thumbnail reads as the display's own space and shifts every
//     mid-tone (the same lesson the viewer learned).
//   • Alpha is composited over the checkerboard-free thumbnail background with
//     the file's premultiplication state honored.
//
// For large lossy (VarDCT) images we render from the fast 1/8-scale DC preview
// whenever it still carries at least one sample per thumbnail pixel — a 26 MP
// hero shot then makes a 256 px thumbnail without a full-resolution decode.
// Anything unsupported degrades gracefully: the handler reports the error and
// Quick Look falls back to a generic document icon.

import CoreGraphics
import Foundation
import JXLCore
import JXLKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let image = try Self.thumbnailImage(for: request)
            let imageSize = CGSize(width: image.width, height: image.height)
            let contextSize = Self.aspectFitSize(for: imageSize, in: request.maximumSize)

            let reply = QLThumbnailReply(contextSize: contextSize) {
                (cgContext: CGContext) -> Bool in
                cgContext.interpolationQuality = .high
                cgContext.draw(image, in: CGRect(origin: .zero, size: contextSize))
                return true
            }
            handler(reply, nil)
        } catch {
            // Unsupported or corrupt file: let Quick Look show its generic icon
            // rather than a blank tile.
            handler(nil, error)
        }
    }

    /// Decodes `request.fileURL` to a display-ready `CGImage`, choosing the
    /// cheapest decode that still fills the requested thumbnail size.
    private static func thumbnailImage(for request: QLFileThumbnailRequest) throws -> CGImage {
        let data = try Data(contentsOf: request.fileURL)
        let info = try JXL.readInfo(from: data)

        // PQ (16) / HLG (18) transfers need 16-bit precision to avoid visible
        // banding and to tag the HDR color space; everything else is fine at
        // 8-bit for a thumbnail.
        let isHDR =
            info.colorEncoding.transferFunction == 16
            || info.colorEncoding.transferFunction == 18

        // Fast path: a large lossy image can be rendered from its 1/8-scale DC
        // preview when the preview still has a sample per target pixel. SDR
        // only — the preview path decodes at 8-bit, which is fine for the
        // downscaled thumbnail but not for HDR precision. (`try?` on the
        // throwing, optional-returning call yields a double optional; flatten
        // it with `?? nil`.)
        if !isHDR, let preview = (try? JXL.decodePreview(from: data)) ?? nil,
            previewSufficient(preview, for: request)
        {
            return try JXLImageConverter.makeCGImage(
                from: preview, orientation: info.orientation,
                colorEncoding: info.colorEncoding,
                alphaPremultiplied: info.alphaPremultiplied)
        }

        let decoded = try JXL.decodeImage(
            from: data, format: isHDR ? .uint16 : .uint8)
        return try JXLImageConverter.makeCGImage(
            from: decoded, orientation: info.orientation,
            colorEncoding: info.colorEncoding,
            alphaPremultiplied: info.alphaPremultiplied)
    }

    /// True when the DC preview carries at least one sample per pixel of the
    /// largest thumbnail we'd draw, so using it introduces no upscaling blur.
    private static func previewSufficient(
        _ preview: JXLDecodedImage, for request: QLFileThumbnailRequest
    ) -> Bool {
        guard preview.width > 0, preview.height > 0 else { return false }
        // The thumbnail is at most `maximumSize` points at `scale` device
        // pixels per point; require the preview to cover that on both axes.
        let targetPx = max(request.maximumSize.width, request.maximumSize.height)
            * max(request.scale, 1)
        return CGFloat(min(preview.width, preview.height)) >= targetPx
    }

    /// The largest size with `imageSize`'s aspect ratio fitting in `bounds`.
    private static func aspectFitSize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
