// ImageCanvasView.swift
//
// The image surface: draws the current CGImage aspect-fit inside its bounds over
// a checkerboard (so alpha is visible), and accepts .jxl files dropped onto it.

import AppKit

final class ImageCanvasView: NSView {

    /// Called when the user drops a file on the canvas.
    var onDropFile: ((URL) -> Void)?

    private var image: CGImage?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ image: CGImage?) {
        self.image = image
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        guard let image else { return }

        let imageSize = CGSize(width: image.width, height: image.height)
        let target = Self.aspectFit(imageSize, in: bounds)

        drawCheckerboard(in: ctx, rect: target)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: target)

        // Thin frame around the image so its extent is clear on any background.
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(target.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawCheckerboard(in ctx: CGContext, rect: CGRect) {
        let cell: CGFloat = 8
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(white: 0.68, alpha: 1).cgColor)
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : cell)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += 2 * cell
            }
            y += cell
            row += 1
        }
        ctx.restoreGState()
    }

    private static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        // Never upscale past a modest limit so tiny fixtures (1x1) stay visible
        // without exploding into a blurry wall of colour.
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let scale = min(fit, 64)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(from: sender) else { return false }
        onDropFile?(url)
        return true
    }

    private func droppedURL(from sender: NSDraggingInfo) -> URL? {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return nil }
        return urls.first { $0.pathExtension.lowercased() == "jxl" } ?? urls.first
    }
}
