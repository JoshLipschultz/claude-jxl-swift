// AppDelegate.swift
//
// Owns the window, the menu, and the open -> decode -> display flow. Decoding
// runs off the main thread so the UI stays responsive on large images; the
// resulting CGImage and a metadata summary are handed back to the main thread.

import AppKit
import Foundation
import JXLCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var canvas: ImageCanvasView!
    private var statusLabel: NSTextField!
    private var decodeGeneration = 0

    /// A file passed on the command line, opened once the app finishes launching.
    var pendingLaunchURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        if let url = pendingLaunchURL {
            open(url)
        } else {
            setStatus("Open a .jxl file  (⌘O)  or drop one here")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Finder "Open With" / double-click routing.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    // MARK: - UI construction

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "JXL Viewer"
        window.center()
        window.setFrameAutosaveName("JXLViewerMainWindow")

        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]

        canvas = ImageCanvasView(frame: NSRect(x: 0, y: 28, width: frame.width, height: frame.height - 28))
        canvas.autoresizingMask = [.width, .height]
        canvas.onDropFile = { [weak self] url in self?.open(url) }
        container.addSubview(canvas)

        let statusBar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 28))
        statusBar.autoresizingMask = [.width]
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 10, y: 4, width: frame.width - 20, height: 18)
        statusLabel.autoresizingMask = [.width]
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusBar.addSubview(statusLabel)
        container.addSubview(statusBar)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About JXL Viewer", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit JXL Viewer", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let jxlType = UTType(filenameExtension: "jxl") {
            panel.allowedContentTypes = [jxlType]
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url)
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "JXL Viewer"
        alert.informativeText =
            "A test harness for the pure-Swift JPEG XL decoder (JXLCore).\n"
            + "Lossless Modular images decode today; lossy (VarDCT) support is in progress."
        alert.runModal()
    }

    // MARK: - Decode pipeline

    private func open(_ url: URL) {
        decodeGeneration += 1
        let generation = decodeGeneration
        window.title = "JXL Viewer — \(url.lastPathComponent)"
        setStatus("Decoding \(url.lastPathComponent)…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.decode(url)
            DispatchQueue.main.async {
                guard let self, generation == self.decodeGeneration else { return }
                switch result {
                case .success(let (cg, summary)):
                    self.canvas.setImage(cg)
                    self.setStatus(summary)
                case .failure(let error):
                    self.canvas.setImage(nil)
                    self.setStatus("✗ \(url.lastPathComponent): \(error)")
                }
            }
        }
    }

    private static func decode(_ url: URL) -> Result<(CGImage, String), DecodeFailure> {
        do {
            let data = try Data(contentsOf: url)
            let info = try JXL.readInfo(from: data)
            let decoded = try JXL.decodeImage(from: data)
            let cg = try JXLImageConverter.makeCGImage(from: decoded, orientation: info.orientation)
            return .success((cg, summary(url: url, info: info, image: decoded)))
        } catch {
            return .failure(DecodeFailure(underlying: error))
        }
    }

    private static func summary(url: URL, info: JXLImageInfo, image: JXLDecodedImage) -> String {
        let color = image.colorChannels == 1 ? "Gray" : "RGB"
        let alpha = image.extraChannels > 0 ? "+A" : ""
        let sample =
            image.isFloat ? "\(image.bitsPerSample)-bit float" : "\(image.bitsPerSample)-bit"
        let kind = info.isContainer ? "container" : "bare codestream"
        return "\(image.width)×\(image.height)  \(color)\(alpha)  \(sample)  (\(kind))"
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}

/// Wraps a decode error so we can pretty-print it in the status bar.
struct DecodeFailure: Error, CustomStringConvertible {
    let underlying: Error
    var description: String {
        if let jxl = underlying as? JXLError { return String(describing: jxl) }
        return underlying.localizedDescription
    }
}
