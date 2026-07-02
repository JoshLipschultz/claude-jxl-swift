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

    // Pick up file path arguments (skip flags and the executable path itself);
    // each existing file opens in its own document window. Handy for driving the
    // app — and its multi-window behaviour — from the terminal or build script.
    delegate.pendingLaunchURLs = CommandLine.arguments.dropFirst()
        .filter { !$0.hasPrefix("-") }
        .map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

    app.delegate = delegate
    app.run()
}
