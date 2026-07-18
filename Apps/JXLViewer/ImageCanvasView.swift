// ImageCanvasView.swift
//
// The image surface for a document window. An NSScrollView provides zoom
// (magnification) and pan; its document view draws the image 1:1 over a
// checkerboard and reports the pixel under the cursor. Files dropped here are
// opened as new documents by the window controller.

import AppKit

final class ImageCanvasView: NSView {

    /// Reports the pixel/sample description under the cursor (nil when outside).
    var onHover: ((String?) -> Void)?
    /// Called when a file is dropped onto the canvas.
    var onDropFile: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let documentImageView = DocumentImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 64
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.documentView = documentImageView
        addSubview(scrollView)

        documentImageView.onHover = { [weak self] in self?.onHover?($0) }
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var hasImage: Bool { documentImageView.hasImage }

    /// Shows `image` rendered at `displaySize` points (defaults to the image's
    /// own pixel size). A low-res preview passes the full image's size so the
    /// final image swaps in without any layout jump; `isPreview` selects smooth
    /// upscaling instead of crisp nearest-neighbour. Zoom-to-fit happens only
    /// on the first image, so the preview→full swap keeps the user's view.
    func setImage(
        _ image: CGImage?, sampler: PixelSampler?, displaySize: CGSize? = nil,
        isPreview: Bool = false
    ) {
        let hadImage = documentImageView.hasImage
        documentImageView.configure(
            image: image, sampler: sampler, displaySize: displaySize, isPreview: isPreview)
        if !hadImage { zoomToFit() }
    }

    // MARK: - Zoom

    private var clipSize: CGSize { scrollView.contentView.bounds.size }

    func zoomToFit() {
        guard documentImageView.hasImage else { return }
        let img = documentImageView.frame.size
        guard img.width > 0, img.height > 0, clipSize.width > 0, clipSize.height > 0 else { return }
        // Fit, but don't blow tiny fixtures up past a sane limit.
        let fit = min(clipSize.width / img.width, clipSize.height / img.height)
        setMagnification(min(fit, 64))
        centerImage()
    }

    func zoomActual() { setMagnification(1); centerImage() }
    func zoomIn() { setMagnification(scrollView.magnification * 1.5) }
    func zoomOut() { setMagnification(scrollView.magnification / 1.5) }

    private func setMagnification(_ value: CGFloat) {
        let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, value))
        scrollView.magnification = clamped
    }

    private func centerImage() {
        guard documentImageView.hasImage else { return }
        let doc = documentImageView.frame.size
        let visible = scrollView.contentView.bounds.size
        let origin = NSPoint(
            x: (doc.width - visible.width) / 2,
            y: (doc.height - visible.height) / 2)
        documentImageView.scroll(origin)
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

/// The scroll view's document view: sized to the image's pixel dimensions and
/// drawn at 1:1 (the scroll view supplies zoom). Flipped so (0,0) is the top-left
/// pixel, which keeps the cursor→pixel mapping trivial.
private final class DocumentImageView: NSView {

    var onHover: ((String?) -> Void)?

    private var image: CGImage?
    private var sampler: PixelSampler?
    private var isPreview = false

    override var isFlipped: Bool { true }
    var hasImage: Bool { image != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Crisp, blocky pixels when magnified rather than a blurry interpolation.
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(
        image: CGImage?, sampler: PixelSampler?, displaySize: CGSize?, isPreview: Bool
    ) {
        self.image = image
        self.sampler = sampler
        self.isPreview = isPreview
        // Crisp pixels for the real image, smooth scaling for previews.
        layer?.magnificationFilter = isPreview ? .linear : .nearest
        let size = displaySize
            ?? image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        if size != frame.size { setFrameSize(size) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        drawCheckerboard(in: ctx)
        // Draw the CGImage right-side-up inside this flipped view.
        ctx.saveGState()
        ctx.interpolationQuality = isPreview ? .medium : .none
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
    }

    private func drawCheckerboard(in ctx: CGContext) {
        let cell: CGFloat = 8
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(NSColor(white: 0.68, alpha: 1).cgColor)
        var y = bounds.minY
        var row = 0
        while y < bounds.maxY {
            var x = bounds.minX + (row.isMultiple(of: 2) ? 0 : cell)
            while x < bounds.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += 2 * cell
            }
            y += cell
            row += 1
        }
    }

    // MARK: - Cursor readout

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onHover?(sampler?.describe(x: Int(floor(p.x)), y: Int(floor(p.y))))
    }

    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}
