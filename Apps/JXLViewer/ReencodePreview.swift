// ReencodePreview.swift
//
// A "re-encode preview" panel for the document window. It takes the currently
// open image's decoded pixels and runs them back through the codec's PUBLIC
// encoder — `JXL.encodeLossy(image:quality:)` or `JXL.encodeLossless(image:)` —
// then reports the resulting file size and, for lossy, the PSNR of the
// round-trip against the pixels on screen. An A/B switch swaps the canvas
// between the original decode and the re-encoded-then-decoded image so the
// artifacts introduced at a given quality are directly visible.
//
// This lives entirely in the app and only calls public core API; it never
// touches the decoder/encoder internals. The heavy encode+decode runs off the
// main actor; the panel just drives it and shows the numbers.

import AppKit
import CoreGraphics
import Foundation
import JXLCore
import JXLKit

// MARK: - Model

enum ReencodeMode: Equatable, Sendable {
    case lossy(quality: Int)
    case lossless
}

/// Result of one re-encode round-trip. `@unchecked Sendable` for the same
/// reason as `DecodeResult`: `CGImage` is immutable after creation.
struct ReencodeOutcome: @unchecked Sendable {
    let modeLabel: String
    let originalBytes: Int
    let encodedBytes: Int
    /// nil means the round-trip is bit-exact (lossless): report as ∞ dB.
    let psnr: Double?
    let elapsed: TimeInterval
    /// The re-encoded, re-decoded image for the A/B switch (lossy only).
    let image: CGImage?
    /// Caveats worth surfacing (alpha dropped, sRGB assumption, …).
    let note: String?
}

/// Runs the public encoder on decoded pixels and measures the round-trip.
enum ReencodeEngine {

    /// Whether the lossy encoder can take this image, and why not when it
    /// can't. (`encodeLossy` accepts 1/3-channel, 1…16-bit integer samples with
    /// no extra channels; alpha is stripped for the preview, HDR is refused
    /// because the lossy path assumes an sRGB transfer.)
    static func lossyDisabledReason(for image: JXLDecodedImage, isHDR: Bool) -> String? {
        if image.isFloat { return "float samples — lossless only" }
        if isHDR { return "HDR transfer — lossy path is sRGB only" }
        guard image.colorChannels == 1 || image.colorChannels == 3 else {
            return "\(image.colorChannels) color channels unsupported"
        }
        guard (1...16).contains(image.bitsPerSample) else {
            return "\(image.bitsPerSample)-bit samples unsupported"
        }
        return nil
    }

    /// Re-encodes `image` per `mode` and, for lossy, decodes the result back to
    /// measure PSNR and produce an A/B image. `orientation` matches the on-
    /// screen original so the A/B image lines up. Throws on encoder rejection.
    static func run(
        image: JXLDecodedImage, orientation: UInt32, colorEncoding: JXLColorEncoding?,
        isHDR: Bool, originalBytes: Int, mode: ReencodeMode
    ) throws -> ReencodeOutcome {
        let start = DispatchTime.now().uptimeNanoseconds

        switch mode {
        case .lossless:
            let encoded = try JXL.encodeLossless(image: image)
            let ms = elapsedSeconds(since: start)
            return ReencodeOutcome(
                modeLabel: "Lossless",
                originalBytes: originalBytes, encodedBytes: encoded.count,
                psnr: nil, elapsed: ms, image: nil,
                note: "bit-exact round-trip of the decoded pixels")

        case .lossy(let quality):
            if let reason = lossyDisabledReason(for: image, isHDR: isHDR) {
                throw ReencodeError.unsupported(reason)
            }
            // Build a color-only, range-clamped input: the lossy encoder rejects
            // extra channels and out-of-range samples (a lossy source can decode
            // to values just outside [0, maxVal]).
            let maxVal = Int32((1 << image.bitsPerSample) - 1)
            let color = min(image.colorChannels, 3)
            var planes: [[Int32]] = []
            planes.reserveCapacity(color)
            for c in 0..<color {
                planes.append(image.planes[c].map { Swift.min(Swift.max($0, 0), maxVal) })
            }
            let input = JXLDecodedImage(
                width: image.width, height: image.height,
                colorChannels: color, extraChannels: 0,
                bitsPerSample: image.bitsPerSample, isFloat: false, planes: planes)

            let encoded = try JXL.encodeLossy(image: input, quality: quality)
            // Decode the round-trip at 16-bit for a precise PSNR and a clean
            // A/B image (VarDCT output is sRGB in the stream).
            let redec = try JXL.decodeImage(from: Data(encoded), format: .uint16)
            let psnr = Self.psnr(
                original: planes, originalMax: Double(maxVal),
                roundTrip: redec.planes, roundTripMax: 65535,
                colorChannels: color)

            let cg = try? JXLImageConverter.makeCGImage(
                from: redec, orientation: orientation, colorEncoding: colorEncoding)

            var notes: [String] = []
            if image.extraChannels > 0 { notes.append("alpha not encoded (lossy)") }
            if !isPlainSRGB(colorEncoding) { notes.append("lossy assumes sRGB primaries") }

            let ms = elapsedSeconds(since: start)
            return ReencodeOutcome(
                modeLabel: "Lossy q\(quality)",
                originalBytes: originalBytes, encodedBytes: encoded.count,
                psnr: psnr, elapsed: ms, image: cg,
                note: notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
    }

    enum ReencodeError: Error, CustomStringConvertible {
        case unsupported(String)
        var description: String {
            switch self { case .unsupported(let r): return r }
        }
    }

    /// A human-readable message for any error the round-trip can throw. Safe to
    /// call off the main actor (used to hand a `Sendable` string back).
    static func describe(_ error: Error) -> String {
        if let r = error as? ReencodeError { return r.description }
        if let j = error as? JXLError { return String(describing: j) }
        return error.localizedDescription
    }

    // MARK: - Helpers

    private static func elapsedSeconds(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// PSNR (dB) between two integer plane sets, each normalized to [0, 1] by
    /// its own maximum so the measure is bit-depth agnostic. Compares the first
    /// `colorChannels` planes; returns nil for a perfect match.
    private static func psnr(
        original: [[Int32]], originalMax: Double,
        roundTrip: [[Int32]], roundTripMax: Double, colorChannels: Int
    ) -> Double? {
        guard originalMax > 0, roundTripMax > 0, colorChannels > 0 else { return nil }
        let n = min(original.first?.count ?? 0, roundTrip.first?.count ?? 0)
        guard n > 0 else { return nil }
        var sumSq = 0.0
        var count = 0
        for c in 0..<colorChannels {
            guard c < original.count, c < roundTrip.count else { break }
            let a = original[c]
            let b = roundTrip[c]
            let m = min(a.count, b.count, n)
            for i in 0..<m {
                let d = Double(a[i]) / originalMax - Double(b[i]) / roundTripMax
                sumSq += d * d
            }
            count += m
        }
        guard count > 0 else { return nil }
        let mse = sumSq / Double(count)
        if mse <= 0 { return nil }
        return -10.0 * log10(mse)  // MAX = 1 after normalization
    }

    /// True when the encoding is plain sRGB (primaries sRGB/unspecified, sRGB or
    /// unspecified transfer, no ICC/gamma) — the only case where the lossy
    /// encoder's sRGB assumption is exact.
    private static func isPlainSRGB(_ ce: JXLColorEncoding?) -> Bool {
        guard let ce, !ce.wantICC, !ce.hasGamma else { return false }
        let srgbPrimaries = ce.primaries == 0 || ce.primaries == 1
        let srgbTransfer = ce.transferFunction == 0 || ce.transferFunction == 2
            || ce.transferFunction == 13
        return srgbPrimaries && srgbTransfer
    }
}

// MARK: - Panel view

/// The re-encode controls + readout. Owned by the document window controller,
/// which supplies the decoded image and performs the A/B canvas swap.
final class ReencodePanelView: NSView {

    /// Fired when the user asks to run an encode with the chosen mode.
    var onRun: ((ReencodeMode) -> Void)?
    /// Fired when the A/B switch changes (true = show re-encoded).
    var onToggleAB: ((Bool) -> Void)?

    private let modeControl = NSSegmentedControl(
        labels: ["Lossy", "Lossless"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let qualitySlider = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality 90")
    private let runButton = NSButton(title: "Re-encode", target: nil, action: nil)
    private let abSwitch = NSButton(checkboxWithTitle: "Show re-encoded (A/B)", target: nil, action: nil)
    private let readout = NSTextField(wrappingLabelWithString: "")
    private let lossyNote = NSTextField(labelWithString: "")

    /// Whether the current image can be lossy-encoded; drives control state.
    private var lossyAvailable = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        setBusy(false)
        clearResult()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.numberOfTickMarks = 0
        qualityLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor

        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        runButton.target = self
        runButton.action = #selector(runTapped)

        abSwitch.target = self
        abSwitch.action = #selector(abToggled)

        readout.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .labelColor
        readout.isSelectable = true
        readout.lineBreakMode = .byWordWrapping
        readout.maximumNumberOfLines = 0

        lossyNote.font = .systemFont(ofSize: 10)
        lossyNote.textColor = .tertiaryLabelColor
        lossyNote.lineBreakMode = .byWordWrapping
        lossyNote.maximumNumberOfLines = 0

        let qualityRow = NSStackView(views: [qualityLabel, qualitySlider])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8
        qualitySlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [
            modeControl, qualityRow, runButton, abSwitch,
            separator(), readout, lossyNote,
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            qualityRow.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -28),
            readout.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -28),
            lossyNote.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -28),
        ])
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    // MARK: - Configuration from the controller

    /// Called when a new image is decoded: resets the panel and enables/disables
    /// the lossy mode based on what the encoder accepts.
    func configure(lossyDisabledReason: String?, originalBytes: Int) {
        lossyAvailable = lossyDisabledReason == nil
        modeControl.setEnabled(lossyAvailable, forSegment: 0)
        if !lossyAvailable && modeControl.selectedSegment == 0 {
            modeControl.selectedSegment = 1
        }
        lossyNote.stringValue = lossyDisabledReason.map { "Lossy unavailable: \($0)" } ?? ""
        abSwitch.state = .off
        abSwitch.isEnabled = false
        readout.stringValue = "Ready. Original file: \(Self.bytes(originalBytes))."
        syncModeControls()
    }

    /// Fills in the result of a completed encode.
    func showResult(_ outcome: ReencodeOutcome) {
        setBusy(false)
        let pct = outcome.originalBytes > 0
            ? Double(outcome.encodedBytes) / Double(outcome.originalBytes) * 100 : 0
        let psnrText = outcome.psnr.map { String(format: "%.2f dB", $0) } ?? "∞ (bit-exact)"
        var lines = [
            "\(outcome.modeLabel)",
            "Original   \(Self.bytes(outcome.originalBytes))",
            String(format: "Encoded    %@   (%.0f%% of original)",
                Self.bytes(outcome.encodedBytes), pct),
            "PSNR       \(psnrText)",
            String(format: "Time       %.0f ms", outcome.elapsed * 1000),
        ]
        if let note = outcome.note { lines.append("— \(note)") }
        readout.stringValue = lines.joined(separator: "\n")

        // A/B only makes sense when we have a distinct re-encoded image.
        if outcome.image != nil {
            abSwitch.isEnabled = true
        } else {
            abSwitch.isEnabled = false
            abSwitch.state = .off
        }
    }

    func showError(_ message: String) {
        setBusy(false)
        readout.stringValue = "Could not re-encode:\n\(message)"
        abSwitch.isEnabled = false
        abSwitch.state = .off
    }

    func clearResult() {
        readout.stringValue = "Ready."
        abSwitch.isEnabled = false
        abSwitch.state = .off
    }

    /// Current A/B state, so the controller can restore the original on reset.
    var isShowingReencoded: Bool { abSwitch.state == .on }

    /// Turns off A/B (e.g. when a fresh result arrives), notifying the canvas.
    func resetAB() {
        if abSwitch.state == .on {
            abSwitch.state = .off
            onToggleAB?(false)
        }
    }

    // MARK: - Actions

    private var currentMode: ReencodeMode {
        modeControl.selectedSegment == 0 && lossyAvailable
            ? .lossy(quality: Int(qualitySlider.doubleValue.rounded()))
            : .lossless
    }

    @objc private func modeChanged() {
        syncModeControls()
        resetAB()
    }

    private func syncModeControls() {
        let lossy = modeControl.selectedSegment == 0 && lossyAvailable
        qualitySlider.isEnabled = lossy
        qualityLabel.textColor = lossy ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func qualityChanged() {
        qualityLabel.stringValue = "Quality \(Int(qualitySlider.doubleValue.rounded()))"
    }

    @objc private func runTapped() {
        resetAB()
        setBusy(true)
        readout.stringValue = "Encoding…"
        onRun?(currentMode)
    }

    @objc private func abToggled() {
        onToggleAB?(abSwitch.state == .on)
    }

    private func setBusy(_ busy: Bool) {
        runButton.isEnabled = !busy
        runButton.title = busy ? "Encoding…" : "Re-encode"
        // Leave the mode control's per-segment enablement alone (segment 0 may
        // be disabled when lossy isn't available); only the slider follows busy.
        qualitySlider.isEnabled = !busy && modeControl.selectedSegment == 0 && lossyAvailable
    }

    private static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        // Include bytes so sub-KB sizes don't collapse to "0 KB".
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        f.countStyle = .file
        return "\(f.string(fromByteCount: Int64(n)))"
    }
}
