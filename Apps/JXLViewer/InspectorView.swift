// InspectorView.swift
//
// A scrollable, read-only monospaced text panel that shows the metadata report
// for the document. Lives on the right of the document window; toggled with ⌘I.

import AppKit

final class InspectorView: NSView {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setReport(_ text: String) {
        textView.string = text
        textView.scroll(NSPoint(x: 0, y: 0))
    }
}
