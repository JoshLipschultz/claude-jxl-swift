// DocumentWindowController.swift
//
// Owns one document window, styled after Preview: the image canvas fills the
// window above a thin status bar, and the metadata report lives in a floating
// utility panel toggled with ⌘I. Decoding is two-stage for fast
// time-to-pixels: a 1/8-scale DC preview (VarDCT) appears as soon as the
// low-frequency pass lands, then the full image swaps in without any layout
// jump. Menu actions reach this controller through the responder chain.

import AppKit
import Foundation
import JXLCore

final class DocumentWindowController: NSWindowController, NSMenuItemValidation {

    private let canvas = ImageCanvasView()
    private let inspector = InspectorView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hoverLabel = NSTextField(labelWithString: "")
    private var inspectorPanel: NSPanel?
    private var decodeGeneration = 0

    // Re-encode preview (⌘R): a floating panel that runs the currently decoded
    // pixels back through the PUBLIC encoder and reports size + PSNR, with an
    // A/B switch that swaps the canvas to the re-encoded result.
    private let reencodePanelView = ReencodePanelView()
    private var reencodePanel: NSPanel?
    private var reencodeDecoded: JXLDecodedImage?
    private var reencodeOrientation: UInt32 = 1
    private var reencodeColorEncoding: JXLColorEncoding?
    private var reencodeIsHDR = false
    private var reencodeOriginalBytes = 0
    /// The re-encoded, re-decoded image backing the A/B switch (nil until a
    /// lossy run produces one).
    private var reencodeResultImage: CGImage?

    // Animation playback state (all main-actor). One-shot timers chained per
    // frame honor the file's variable per-frame durations.
    private var animationTimer: Timer?
    private var animationFrames: [CGImage] = []
    private var animationDurations: [TimeInterval] = []
    private var animationIndex = 0
    /// Full passes still to play; 0 stands for "forever" (file numLoops == 0).
    private var animationLoopsRemaining: UInt32 = 0
    private var animationLoopsForever = false
    /// The status text playback annotations append to ("… — frame 3/12").
    private var baseStatus = ""

    // No deinit invalidation needed: timers are one-shot with a weak self, so
    // after the controller goes away the single pending fire no-ops and the
    // chain ends.

    // MARK: - Construction

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.tabbingMode = .automatic
        window.minSize = NSSize(width: 360, height: 240)
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        shouldCascadeWindows = true
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        let statusHeight: CGFloat = 26

        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow

        for view in [canvas, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        hoverLabel.translatesAutoresizingMaskIntoConstraints = false
        for label in [statusLabel, hoverLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            bar.addSubview(label)
        }
        statusLabel.lineBreakMode = .byTruncatingMiddle
        hoverLabel.alignment = .right
        hoverLabel.lineBreakMode = .byTruncatingTail
        hoverLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: statusHeight),
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hoverLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            hoverLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            hoverLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        canvas.onDropFile = { url in
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true) { _, _, _ in }
        }
        canvas.onHover = { [weak self] text in
            self?.hoverLabel.stringValue = text ?? ""
        }

        reencodePanelView.onRun = { [weak self] mode in
            self?.runReencode(mode)
        }
        reencodePanelView.onToggleAB = { [weak self] showReencoded in
            guard let self else { return }
            self.canvas.setComparisonImage(showReencoded ? self.reencodeResultImage : nil)
        }

        // Resolve layout before the window animates on screen so the first
        // frame is drawn content, not an empty backing store.
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    // MARK: - Inspector panel (⌘I)

    private func makeInspectorPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = inspectorTitle()
        inspector.translatesAutoresizingMaskIntoConstraints = true
        inspector.frame = panel.contentView!.bounds
        inspector.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(inspector)
        return panel
    }

    private func inspectorTitle() -> String {
        let name = (document as? JXLDocument)?.fileURL?.lastPathComponent ?? "Metadata"
        return "Info — \(name)"
    }

    private var inspectorVisible: Bool { inspectorPanel?.isVisible ?? false }

    @objc func toggleInspector(_ sender: Any?) {
        if inspectorVisible {
            inspectorPanel?.orderOut(nil)
            return
        }
        let firstShow = inspectorPanel == nil
        let panel = inspectorPanel ?? makeInspectorPanel()
        inspectorPanel = panel
        panel.title = inspectorTitle()
        if firstShow, let windowFrame = window?.frame {
            // First show: hug the document window's top-right corner.
            panel.setFrameTopLeftPoint(
                NSPoint(x: windowFrame.maxX + 8, y: windowFrame.maxY))
        }
        panel.orderFront(nil)
    }

    // MARK: - Re-encode preview panel (⌘R)

    private func makeReencodePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Re-encode Preview"
        reencodePanelView.translatesAutoresizingMaskIntoConstraints = true
        reencodePanelView.frame = panel.contentView!.bounds
        reencodePanelView.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(reencodePanelView)
        return panel
    }

    private var reencodeVisible: Bool { reencodePanel?.isVisible ?? false }

    @objc func toggleReencodePreview(_ sender: Any?) {
        if reencodeVisible {
            reencodePanel?.orderOut(nil)
            return
        }
        let firstShow = reencodePanel == nil
        let panel = reencodePanel ?? makeReencodePanel()
        reencodePanel = panel
        if firstShow, let windowFrame = window?.frame {
            // First show: hug the document window's right edge, below the info
            // panel's usual spot.
            panel.setFrameTopLeftPoint(
                NSPoint(x: windowFrame.maxX + 8, y: windowFrame.maxY - 260))
        }
        panel.orderFront(nil)
    }

    /// Clears any re-encode result and A/B state (called when a new decode
    /// starts, so stale numbers/images never linger).
    private func resetReencodeState() {
        reencodeDecoded = nil
        reencodeResultImage = nil
        reencodePanelView.resetAB()
        reencodePanelView.clearResult()
        canvas.setComparisonImage(nil)
    }

    /// Points the re-encode panel at a freshly decoded image.
    private func configureReencode(from result: DecodeResult, originalBytes: Int) {
        reencodeResultImage = nil
        canvas.setComparisonImage(nil)
        guard let decoded = result.decoded else {
            reencodeDecoded = nil
            reencodePanelView.configure(
                lossyDisabledReason: "no decoded image", originalBytes: originalBytes)
            return
        }
        reencodeDecoded = decoded
        reencodeOrientation = result.orientation
        reencodeColorEncoding = result.colorEncoding
        reencodeIsHDR = result.isHDR
        reencodeOriginalBytes = originalBytes
        let reason = ReencodeEngine.lossyDisabledReason(for: decoded, isHDR: result.isHDR)
        reencodePanelView.configure(lossyDisabledReason: reason, originalBytes: originalBytes)
    }

    /// Runs the encoder off the main actor for `mode`, then shows size + PSNR.
    private func runReencode(_ mode: ReencodeMode) {
        guard let decoded = reencodeDecoded else {
            reencodePanelView.showError("No decoded image to re-encode.")
            return
        }
        let orientation = reencodeOrientation
        let colorEncoding = reencodeColorEncoding
        let isHDR = reencodeIsHDR
        let originalBytes = reencodeOriginalBytes
        let generation = decodeGeneration
        Task { [weak self] in
            let out: (outcome: ReencodeOutcome?, error: String?) =
                await Task.detached(priority: .userInitiated) {
                    () -> (outcome: ReencodeOutcome?, error: String?) in
                    do {
                        let o = try ReencodeEngine.run(
                            image: decoded, orientation: orientation,
                            colorEncoding: colorEncoding, isHDR: isHDR,
                            originalBytes: originalBytes, mode: mode)
                        return (outcome: o, error: nil)
                    } catch {
                        return (outcome: nil, error: ReencodeEngine.describe(error))
                    }
                }.value
            guard let self, generation == self.decodeGeneration else { return }
            if let outcome = out.outcome {
                self.reencodeResultImage = outcome.image
                self.reencodePanelView.showResult(outcome)
            } else {
                self.reencodeResultImage = nil
                self.reencodePanelView.showError(out.error ?? "unknown error")
            }
        }
    }

    // MARK: - Decoding

    /// Called by the document once this controller is attached. Two stages,
    /// both off the main actor: a DC-resolution preview for immediate pixels,
    /// then the full decode. The status bar reports both times — the metric
    /// being optimized is time-to-pixels-displayed.
    func startDecoding() {
        guard let doc = document as? JXLDocument, let data = doc.fileData else { return }
        let name = doc.fileURL?.lastPathComponent ?? "image"
        window?.title = name
        statusLabel.stringValue = "Decoding \(name)…"

        stopAnimation()
        resetReencodeState()
        decodeGeneration += 1
        let generation = decodeGeneration
        let start = DispatchTime.now().uptimeNanoseconds

        // Stage 1: preview (VarDCT DC). Cheap; lands in tens of milliseconds.
        Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                DecodePipeline.decodePreview(data)
            }.value
            guard let self, generation == self.decodeGeneration else { return }
            guard let preview else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            // Stored even if the full decode won: the canvas keeps the preview
            // around and substitutes it when zoomed out to ≤1/8 scale.
            let fullAlreadyShown = self.canvas.hasFullImage
            self.canvas.setPreviewImage(preview.image, fullSize: preview.fullSize)
            if !fullAlreadyShown {
                self.statusLabel.stringValue = String(format: "%@ — preview %.0f ms…", name, ms)
            }
        }

        // Stage 2: full decode; swaps in over the preview with no layout jump.
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DecodePipeline.decode(data, name: name)
            }.value
            guard let self, generation == self.decodeGeneration else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            self.canvas.setImage(result.image, sampler: result.sampler)
            self.baseStatus = result.didDecode
                ? String(format: "%@ — %.0f ms", result.summary, ms)
                : result.summary
            self.statusLabel.stringValue = self.baseStatus
            self.inspector.setReport(result.report)
            self.configureReencode(from: result, originalBytes: data.count)
            // Stage 3 (animated files only): decode all frames in the
            // background, then play. The still first frame above already
            // landed, so this never delays first pixels; for stills the stage
            // exits after a header read.
            if result.didDecode { self.startAnimationDecode(data, generation: generation) }
        }
    }

    // MARK: - Animation playback

    private func startAnimationDecode(_ data: Data, generation: Int) {
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                DecodePipeline.decodeAnimation(data)
            }.value
            guard let self, generation == self.decodeGeneration else { return }
            switch outcome {
            case .animation(let animation):
                self.startAnimation(animation, generation: generation)
            case .tooLarge:
                self.statusLabel.stringValue =
                    self.baseStatus + " — animation too large; showing first frame"
            case .notAnimated, .failed:
                break  // the still first frame stays; decode() already reported
            }
        }
    }

    private func startAnimation(_ animation: AnimationResult, generation: Int) {
        guard animation.frames.count > 1 else { return }
        animationFrames = animation.frames
        animationDurations = animation.durations
        animationIndex = 0
        animationLoopsForever = animation.numLoops == 0
        animationLoopsRemaining = animation.numLoops
        showCurrentAnimationFrame()
        scheduleNextAnimationFrame(generation: generation)
    }

    private func showCurrentAnimationFrame() {
        canvas.setAnimationFrame(animationFrames[animationIndex])
        statusLabel.stringValue =
            baseStatus + " — frame \(animationIndex + 1)/\(animationFrames.count)"
    }

    private func scheduleNextAnimationFrame(generation: Int) {
        // Clamp pathological zero/near-zero durations the way browsers do for
        // GIFs, so a malformed file can't spin the main run loop.
        let duration = max(animationDurations[animationIndex], 0.02)
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.advanceAnimation(generation: generation)
        }
        // .common keeps frames advancing during scroll and live zoom.
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func advanceAnimation(generation: Int) {
        guard generation == decodeGeneration, window != nil, !animationFrames.isEmpty else {
            stopAnimation()
            return
        }
        if animationIndex == animationFrames.count - 1 {
            // A full pass just finished. Finite loop counts tick down and end
            // by holding the last frame on screen.
            if !animationLoopsForever {
                animationLoopsRemaining -= 1
                if animationLoopsRemaining == 0 {
                    animationTimer = nil
                    statusLabel.stringValue = baseStatus + " — \(animationFrames.count) frames"
                    return
                }
            }
            animationIndex = 0
        } else {
            animationIndex += 1
        }
        showCurrentAnimationFrame()
        scheduleNextAnimationFrame(generation: generation)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrames = []
        animationDurations = []
        animationIndex = 0
    }

    // MARK: - Menu actions (reached via the responder chain)

    @objc func actualSize(_ sender: Any?) { canvas.zoomActual() }
    @objc func zoomImageIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomImageOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func zoomImageToFit(_ sender: Any?) { canvas.zoomToFit() }

    @objc func nextImage(_ sender: Any?) { openSibling(offset: 1) }
    @objc func previousImage(_ sender: Any?) { openSibling(offset: -1) }

    /// Opens the neighbouring .jxl file in the same folder as a document. If it's
    /// already open, its window simply comes forward.
    private func openSibling(offset: Int) {
        guard let current = (document as? JXLDocument)?.fileURL else { return }
        let siblings = folderSiblings(of: current)
        guard let index = siblings.firstIndex(of: current), siblings.count > 1 else { return }
        let target = siblings[(index + offset + siblings.count) % siblings.count]
        NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { _, _, _ in }
    }

    private func folderSiblings(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "jxl" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(actualSize), #selector(zoomImageIn), #selector(zoomImageOut),
            #selector(zoomImageToFit):
            return canvas.hasImage
        case #selector(toggleInspector):
            item.title = inspectorVisible ? "Hide Info" : "Show Info"
            return true
        case #selector(toggleReencodePreview):
            item.title = reencodeVisible ? "Hide Re-encode Preview" : "Re-encode Preview…"
            return canvas.hasImage
        case #selector(nextImage), #selector(previousImage):
            guard let url = (document as? JXLDocument)?.fileURL else { return false }
            return folderSiblings(of: url).count > 1
        default:
            return true
        }
    }
}
