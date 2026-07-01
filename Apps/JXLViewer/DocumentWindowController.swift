// DocumentWindowController.swift
//
// Owns one document window: an image canvas (zoom + pixel readout) beside a
// toggleable metadata inspector, with a status bar underneath. Builds its window
// programmatically (no nib) and implements the View/Go menu actions, which reach
// it through the responder chain when its window is key.

import AppKit
import Foundation

final class DocumentWindowController: NSWindowController, NSMenuItemValidation {

    private let canvas = ImageCanvasView()
    private let inspector = InspectorView()
    private let splitView = NSSplitView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hoverLabel = NSTextField(labelWithString: "")

    private var inspectorVisible = true
    private var savedInspectorWidth: CGFloat = 300
    private var decodeGeneration = 0

    // MARK: - Construction

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        shouldCascadeWindows = true
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        let statusHeight: CGFloat = 28

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.frame = NSRect(
            x: 0, y: statusHeight,
            width: content.bounds.width, height: content.bounds.height - statusHeight)
        splitView.autoresizingMask = [.width, .height]

        canvas.onDropFile = { url in
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true) { _, _, _ in }
        }
        canvas.onHover = { [weak self] text in
            self?.hoverLabel.stringValue = text ?? ""
        }

        splitView.addArrangedSubview(canvas)
        splitView.addArrangedSubview(inspector)
        content.addSubview(splitView)

        buildStatusBar(in: content, height: statusHeight)

        // Give the inspector its initial width.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.splitView.setPosition(
                window.contentView!.bounds.width - self.savedInspectorWidth, ofDividerAt: 0)
        }
    }

    private func buildStatusBar(in content: NSView, height: CGFloat) {
        let bar = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: height))
        bar.autoresizingMask = [.width]
        bar.material = .titlebar
        bar.blendingMode = .withinWindow

        statusLabel.frame = NSRect(x: 10, y: 5, width: content.bounds.width * 0.5 - 14, height: 18)
        statusLabel.autoresizingMask = [.width]
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        bar.addSubview(statusLabel)

        hoverLabel.frame = NSRect(
            x: content.bounds.width * 0.5, y: 5, width: content.bounds.width * 0.5 - 10, height: 18)
        hoverLabel.autoresizingMask = [.width, .minXMargin]
        hoverLabel.alignment = .right
        hoverLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hoverLabel.textColor = .secondaryLabelColor
        hoverLabel.lineBreakMode = .byTruncatingTail
        bar.addSubview(hoverLabel)

        content.addSubview(bar)
    }

    // MARK: - Decoding

    /// Called by the document once this controller is attached. Decodes off the
    /// main actor and updates the UI when done.
    func startDecoding() {
        guard let doc = document as? JXLDocument, let data = doc.fileData else { return }
        let name = doc.fileURL?.lastPathComponent ?? "image"
        window?.title = name
        statusLabel.stringValue = "Decoding \(name)…"

        decodeGeneration += 1
        let generation = decodeGeneration
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DecodePipeline.decode(data, name: name)
            }.value
            guard let self, generation == self.decodeGeneration else { return }
            self.canvas.setImage(result.image, sampler: result.sampler)
            self.statusLabel.stringValue = result.summary
            self.inspector.setReport(result.report)
        }
    }

    // MARK: - Menu actions (reached via the responder chain)

    @objc func actualSize(_ sender: Any?) { canvas.zoomActual() }
    @objc func zoomImageIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomImageOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func zoomImageToFit(_ sender: Any?) { canvas.zoomToFit() }

    @objc func toggleInspector(_ sender: Any?) {
        guard let window, let content = window.contentView else { return }
        inspectorVisible.toggle()
        if inspectorVisible {
            inspector.isHidden = false
            splitView.setPosition(content.bounds.width - savedInspectorWidth, ofDividerAt: 0)
        } else {
            savedInspectorWidth = max(180, inspector.frame.width)
            splitView.setPosition(content.bounds.width, ofDividerAt: 0)
            inspector.isHidden = true
        }
    }

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
            item.title = inspectorVisible ? "Hide Metadata Inspector" : "Show Metadata Inspector"
            return true
        case #selector(nextImage), #selector(previousImage):
            guard let url = (document as? JXLDocument)?.fileURL else { return false }
            return folderSiblings(of: url).count > 1
        default:
            return true
        }
    }
}
