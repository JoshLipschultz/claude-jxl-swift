// main.swift
//
// Entry point for the JXL Viewer macOS app. Wires up NSApplication with our
// delegate. A path given on the command line (`JXLViewer image.jxl`) is opened
// on launch, which makes the app convenient to drive from the build script or a
// terminal while testing the decoder.

import AppKit
import Foundation

// Program entry runs on the main thread; assert that to the concurrency model so
// this compiles both under Xcode (top-level main.swift is inferred @MainActor)
// and under bare `swiftc` (where it is nonisolated).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()

    // Pick up a file path argument (skip flags and the executable path itself).
    if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            delegate.pendingLaunchURL = url
        }
    }

    app.delegate = delegate
    app.run()
}
