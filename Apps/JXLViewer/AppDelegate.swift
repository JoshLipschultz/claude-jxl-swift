// AppDelegate.swift
//
// Application delegate for the document-based JXL Viewer. It builds the main menu
// and handles launch behaviour; opening files, per-file windows, Open Recent, and
// drag-to-open are all handled by NSDocumentController and the document machinery.

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// File paths passed on the command line, each opened once launching finishes.
    /// Handy for driving the app from the terminal or the build script.
    var pendingLaunchURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        if !pendingLaunchURLs.isEmpty {
            for url in pendingLaunchURLs {
                NSDocumentController.shared.openDocument(
                    withContentsOf: url, display: true) { _, _, _ in }
            }
            return
        }

        // If nothing was opened during launch (no file argument, no Finder open),
        // present the Open panel so the user has an obvious next step.
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    // Viewer has no concept of a blank document, so don't create one on launch.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(goMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "About JXL Viewer", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit JXL Viewer", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(
            withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)),
            keyEquivalent: "o")

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        // AppKit auto-populates a menu containing this action with recent files.
        recentMenu.addItem(
            withTitle: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    private func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(
            withTitle: "Show Info",
            action: #selector(DocumentWindowController.toggleInspector(_:)), keyEquivalent: "i")
        menu.addItem(
            withTitle: "Re-encode Preview…",
            action: #selector(DocumentWindowController.toggleReencodePreview(_:)), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Actual Size",
            action: #selector(DocumentWindowController.actualSize(_:)), keyEquivalent: "0")
        menu.addItem(
            withTitle: "Zoom In",
            action: #selector(DocumentWindowController.zoomImageIn(_:)), keyEquivalent: "+")
        menu.addItem(
            withTitle: "Zoom Out",
            action: #selector(DocumentWindowController.zoomImageOut(_:)), keyEquivalent: "-")
        menu.addItem(
            withTitle: "Zoom to Fit",
            action: #selector(DocumentWindowController.zoomImageToFit(_:)), keyEquivalent: "9")
        item.submenu = menu
        return item
    }

    private func goMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Go")
        let next = menu.addItem(
            withTitle: "Next Image",
            action: #selector(DocumentWindowController.nextImage(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        next.keyEquivalentModifierMask = .command
        let prev = menu.addItem(
            withTitle: "Previous Image",
            action: #selector(DocumentWindowController.previousImage(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prev.keyEquivalentModifierMask = .command
        item.submenu = menu
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "JXL Viewer"
        alert.informativeText =
            "A test harness for the pure-Swift JPEG XL decoder (JXLCore).\n"
            + "Lossless Modular images decode today; lossy (VarDCT) support is in progress."
        alert.runModal()
    }
}
