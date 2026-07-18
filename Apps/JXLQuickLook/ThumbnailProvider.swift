// ThumbnailProvider.swift
//
// Quick Look thumbnail provider for .jxl files (M10). Decodes the image with
// JXLCore, bridges it to a `CGImage` via JXLKit (profile-aware, EXIF
// orientation applied), and draws it aspect-fit into the requested thumbnail
// context. Built as an appex embedded in JXLViewer.app; see project.yml.

import CoreGraphics
import JXLCore
import JXLKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let info = try JXL.readInfo(contentsOf: request.fileURL)
            let decoded = try JXL.decodeImage(contentsOf: request.fileURL)
            let image = try JXLImageConverter.makeCGImage(
                from: decoded, orientation: info.orientation)
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
            handler(nil, error)
        }
    }

    /// The largest size with `imageSize`'s aspect ratio fitting in `bounds`.
    private static func aspectFitSize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
