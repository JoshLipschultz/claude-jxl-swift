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

        // Magnification changes (including trackpad pinch) move the clip view's
        // bounds; track them so the document view can switch between the full
        // image and the DC preview as the effective scale crosses 1/8.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    var hasImage: Bool { documentImageView.hasImage }
    var hasFullImage: Bool { documentImageView.hasFullImage }

    /// Shows the 1/8-scale DC preview, rendered at the full image's size so the
    /// final image can swap in without any layout jump. The preview is kept
    /// after the full image arrives: it stands in whenever the view is zoomed
    /// out far enough that downsampling makes the two indistinguishable.
    func setPreviewImage(_ image: CGImage, fullSize: CGSize) {
        let hadImage = documentImageView.hasImage
        documentImageView.setPreview(image, displaySize: fullSize)
        pushEffectiveScale()
        if !hadImage { zoomToFit() }
    }

    /// Shows the fully decoded image (replacing the preview on screen, though
    /// the preview stays around for deep zoom-out). `nil` on decode failure
    /// leaves any preview visible.
    func setImage(_ image: CGImage?, sampler: PixelSampler?) {
        let hadImage = documentImageView.hasImage
        documentImageView.setFull(image, sampler: sampler)
        pushEffectiveScale()
        if !hadImage { zoomToFit() }
    }

    @objc private func clipBoundsChanged(_ note: Notification) { pushEffectiveScale() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pushEffectiveScale()
    }

    /// On-screen device pixels per image point: zoom × backing scale.
    private func pushEffectiveScale() {
        let backing = window?.backingScaleFactor ?? 2
        documentImageView.updateEffectiveScale(scrollView.magnification * backing)
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

    private var previewImage: CGImage?
    private var fullImage: CGImage?
    private var displayed: CGImage?
    private var sampler: PixelSampler?
    private var effectiveScale: CGFloat = 1

    override var isFlipped: Bool { true }
    var hasImage: Bool { fullImage != nil || previewImage != nil }
    var hasFullImage: Bool { fullImage != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setPreview(_ image: CGImage, displaySize: CGSize) {
        previewImage = image
        if displaySize != frame.size { setFrameSize(displaySize) }
        refreshDisplayedImage(force: true)
    }

    func setFull(_ image: CGImage?, sampler: PixelSampler?) {
        fullImage = image
        self.sampler = sampler
        if let image {
            let size = CGSize(width: image.width, height: image.height)
            if size != frame.size { setFrameSize(size) }
        }
        refreshDisplayedImage(force: true)
    }

    func updateEffectiveScale(_ scale: CGFloat) {
        guard scale != effectiveScale else { return }
        effectiveScale = scale
        refreshDisplayedImage(force: false)
    }

    /// Which image draws: the full decode when present, except that the DC
    /// preview substitutes whenever it still has at least one sample per
    /// on-screen device pixel — at ≤1/8 effective scale downsampling makes the
    /// two identical, and the preview is far cheaper to composite.
    private func chooseImage() -> CGImage? {
        guard let full = fullImage else { return previewImage }
        guard let preview = previewImage, bounds.width > 0,
            CGFloat(preview.width) >= bounds.width * effectiveScale
        else { return full }
        return preview
    }

    private func refreshDisplayedImage(force: Bool) {
        let choice = chooseImage()
        guard force || choice !== displayed else { return }
        displayed = choice
        // Crisp pixels for the real image, smooth scaling for the preview
        // (which is only ever shown upscaled-while-waiting or far zoomed out).
        layer?.magnificationFilter = choice === fullImage ? .nearest : .linear
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image = displayed else { return }
        drawCheckerboard(in: ctx)
        // Draw the CGImage right-side-up inside this flipped view.
        ctx.saveGState()
        ctx.interpolationQuality = image === fullImage ? .none : .medium
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
