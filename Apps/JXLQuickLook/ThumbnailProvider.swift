// ThumbnailProvider.swift
//
// Quick Look thumbnail provider for .jxl files. This is the M10 integration
// target: it lives in an Xcode-built appex (it is NOT compiled by the SwiftPM
// scripts, which have no QuickLookThumbnailing SDK packaging). See
// Apps/README.md for how to add it to an Xcode project.
//
// Today it draws a placeholder sized to the real image dimensions (which the
// decoder can already report). Once the decode pipeline reaches M5+, replace
// the placeholder draw with the decoded `CGImage`.

import CoreGraphics
import JXLCore
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let info = try JXL.readInfo(contentsOf: request.fileURL)
            let imageSize = CGSize(width: CGFloat(info.width), height: CGFloat(info.height))

            let reply = QLThumbnailReply(contextSize: request.maximumSize) {
                (cgContext: CGContext) -> Bool in
                // M5+: decode pixels and draw the real CGImage here, e.g.
                //   let image = try JXL.decodeCGImage(contentsOf: request.fileURL)
                //   cgContext.draw(image, in: CGRect(origin: .zero, size: request.maximumSize))
                Self.drawPlaceholder(in: cgContext, size: request.maximumSize, imageSize: imageSize)
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }

    private static func drawPlaceholder(in ctx: CGContext, size: CGSize, imageSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)

        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(bounds)

        let imageRect = aspectFitRect(for: imageSize, in: bounds).insetBy(dx: 1, dy: 1)
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(imageRect)
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
        ctx.setLineWidth(max(1, min(size.width, size.height) / 64))
        ctx.stroke(imageRect)
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
