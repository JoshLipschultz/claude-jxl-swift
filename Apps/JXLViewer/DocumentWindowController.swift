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

final class DocumentWindowController: NSWindowController, NSMenuItemValidation {

    private let canvas = ImageCanvasView()
    private let inspector = InspectorView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hoverLabel = NSTextField(labelWithString: "")
    private var inspectorPanel: NSPanel?
    private var decodeGeneration = 0

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
            self.statusLabel.stringValue = result.didDecode
                ? String(format: "%@ — %.0f ms", result.summary, ms)
                : result.summary
            self.inspector.setReport(result.report)
        }
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
        case #selector(nextImage), #selector(previousImage):
            guard let url = (document as? JXLDocument)?.fileURL else { return false }
            return folderSiblings(of: url).count > 1
        default:
            return true
        }
    }
}
