// JXLDocument.swift
//
// A read-only document wrapping one .jxl file. NSDocumentController gives us
// Open, Open Recent, one-window-per-file, window tabbing, and drag-to-open for
// free. Reading just stashes the bytes; the (potentially slow) decode is kicked
// off by the window controller so the UI can show progress.
//
// @objc(JXLDocument) pins a stable Objective-C runtime name so the Info.plist
// NSDocumentClass value works regardless of the Swift module name.

import AppKit
import Foundation

@objc(JXLDocument)
final class JXLDocument: NSDocument {

    /// Raw file bytes, set during reading and consumed by the window controller.
    private(set) var fileData: Data?

    override class var autosavesInPlace: Bool { false }

    // Read-only viewer: never editable, so Save stays disabled.
    override var isDocumentEdited: Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        self.fileData = data
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        controller.startDecoding()
    }

    // No writing — this is a viewer.
    override func data(ofType typeName: String) throws -> Data {
        throw NSError(
            domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
            userInfo: [NSLocalizedDescriptionKey: "JXL Viewer is read-only."])
    }
}
