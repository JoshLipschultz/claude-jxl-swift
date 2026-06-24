// ThumbnailProvider.swift
//
// Quick Look thumbnail provider for .jxl files. This is the M10 integration
// target: it lives in an Xcode-built appex (it is NOT compiled by the SwiftPM
// scripts, which have no QuickLookThumbnailing SDK packaging). See
// Apps/JXLQuickLook/README.md for how to add it to an Xcode project.
//
// Today it draws a placeholder sized to the real image dimensions (which the
// decoder can already report). Once the decode pipeline reaches M5+, replace
// the placeholder draw with the decoded `CGImage`.

import QuickLookThumbnailing
import CoreGraphics
import JXLCore

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let info = try JXL.readInfo(contentsOf: request.fileURL)
            let imageSize = CGSize(width: CGFloat(info.width), height: CGFloat(info.height))

            let reply = QLThumbnailReply(contextSize: request.maximumSize) { (cgContext: CGContext) -> Bool in
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
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
        ctx.setLineWidth(max(1, size.width / 64))
        ctx.stroke(CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.1, dy: size.height * 0.1))
    }
}
