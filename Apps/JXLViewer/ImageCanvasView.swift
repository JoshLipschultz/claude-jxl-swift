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
        // Center the document when it's smaller than the viewport (per axis),
        // like Preview.app. The clip view must be swapped in before the
        // document view is assigned so the document lands in the new clip view,
        // and before the background settings so they propagate to it.
        scrollView.contentView = CenteringClipView()
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

    /// Centers the scroll position when the image is larger than the viewport.
    /// (When it's smaller, CenteringClipView's constrainBoundsRect(_:) clamps
    /// whatever origin this computes to the centered one, so both paths agree.)
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

/// The scroll view's document view: sized to the image's pixel dimensions, with
/// the scroll view supplying zoom. Flipped so (0,0) is the top-left pixel, which
/// keeps the cursor→pixel mapping trivial.
///
/// The image is NOT drawn through `draw(_:)`: at 26 MP the view's backing store
/// would be hundreds of megabytes and every magnification change would re-render
/// it on the CPU, making pinch-zoom crawl. Instead the CGImage is assigned
/// directly as the backing layer's `contents` (`wantsUpdateLayer`), so Core
/// Animation scales the one uploaded texture on the GPU during live zoom with no
/// redraws at all — the same technique that makes Preview.app feel instant. The
/// checkerboard under transparent images is the layer's pattern background
/// color, also composited without any per-zoom CPU work.
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

    /// 8-point checkerboard tile (2×2 cells), tiled by the layer as a pattern
    /// background so transparency shows through the image contents above it.
    /// Layer-space tiling means the squares scale with zoom, exactly as the old
    /// view-coordinate drawing did.
    private static let checkerboard: CGColor = {
        let cell: CGFloat = 8
        let tile = NSImage(size: NSSize(width: cell * 2, height: cell * 2), flipped: false) { rect in
            NSColor(white: 0.82, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.68, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
            NSRect(x: cell, y: cell, width: cell, height: cell).fill()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Let PQ/HLG-tagged contents use the display's EDR headroom.
        if #available(macOS 14.0, *) {
            layer?.wantsExtendedDynamicRangeContent = true
        }
        // Only updateLayer() runs (draw(_:) never does), so no giant backing
        // store is allocated and nothing re-renders while the scroll view's
        // magnification scales the layer.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = displayed
        layer.contentsGravity = .resize  // preview (1/8-size) stretches to full frame
        layer.backgroundColor = displayed == nil ? nil : Self.checkerboard
        // Crisp pixels when zoomed in on the real image, smooth scaling for the
        // preview (only ever shown upscaled-while-waiting or far zoomed out).
        layer.magnificationFilter = displayed === fullImage ? .nearest : .linear
        layer.minificationFilter = .linear
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
        needsDisplay = true  // triggers updateLayer(), not draw(_:)
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

/// Clip view that centers the document whenever it's smaller than the viewport,
/// per axis independently (Preview.app behavior). AppKit funnels every scroll
/// origin — including the ones NSScrollView computes during live pinch
/// magnification, when zooming shrinks the document below the visible size —
/// through `constrainBoundsRect(_:)`, so overriding it keeps the image centered
/// at all times. Both rects here are in the clip view's (magnified) bounds
/// space, so the math is magnification-agnostic. Bounds-changed notifications
/// still post normally; ImageCanvasView depends on them for the preview/full
/// image switch.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let docFrame = doc.frame
        if rect.width > docFrame.width {
            rect.origin.x = docFrame.minX - (rect.width - docFrame.width) / 2
        }
        if rect.height > docFrame.height {
            rect.origin.y = docFrame.minY - (rect.height - docFrame.height) / 2
        }
        return rect
    }
}
