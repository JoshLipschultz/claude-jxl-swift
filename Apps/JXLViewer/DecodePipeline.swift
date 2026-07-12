// DecodePipeline.swift
//
// Off-actor decoding plus the Sendable value types that carry the result back to
// the main actor for display. Keeping this separate from the AppKit classes lets
// the heavy work run on a background task with no reference to any UI object.

import CoreGraphics
import Foundation
import JXLCore

/// Everything a document window needs after a decode, all Sendable so it can
/// cross from the background task to the main actor. `@unchecked` is sound
/// because `CGImage` is immutable and read-only after creation.
struct DecodeResult: @unchecked Sendable {
    /// The rendered image, or `nil` if pixel decoding failed (metadata may still
    /// be available). Both lossless (Modular) and lossy (VarDCT) frames decode
    /// via `JXL.decodeImage`.
    let image: CGImage?
    /// Per-pixel sample access for the inspector, in native bit depth.
    let sampler: PixelSampler?
    /// One-line status summary (dimensions / channels) or an error message.
    let summary: String
    /// Multi-line metadata report for the inspector panel.
    let report: String
    /// True when pixels decoded successfully.
    var didDecode: Bool { image != nil }
}

/// Read-only view over the decoded planes so the inspector can report the native
/// sample values under the cursor. A value type, hence Sendable.
struct PixelSampler: Sendable {
    let width: Int
    let height: Int
    let colorChannels: Int
    let extraChannels: Int
    let bitsPerSample: Int
    let isFloat: Bool
    let orientation: UInt32
    let planes: [[Int32]]

    init(_ image: JXLDecodedImage, orientation: UInt32) {
        self.width = image.width
        self.height = image.height
        self.colorChannels = image.colorChannels
        self.extraChannels = image.extraChannels
        self.bitsPerSample = image.bitsPerSample
        self.isFloat = image.isFloat
        self.orientation = orientation
        self.planes = image.planes
    }

    /// Describes the pixel at displayed coordinate (x, y). Returns `nil` when out
    /// of range, or when a non-identity orientation means displayed coordinates
    /// no longer map straight onto the stored planes.
    func describe(x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        guard orientation == 1 else { return "px (\(x), \(y))" }
        let i = y * width + x

        func value(_ plane: Int) -> String {
            let s = planes[plane][i]
            if isFloat {
                return String(format: "%.4f", Float(bitPattern: UInt32(bitPattern: s)))
            }
            return String(UInt32(bitPattern: s))
        }

        var parts = ["px (\(x), \(y))"]
        if colorChannels == 1 {
            parts.append("V=\(value(0))")
        } else {
            parts.append("R=\(value(0))")
            parts.append("G=\(value(1))")
            parts.append("B=\(value(2))")
        }
        if extraChannels > 0 {
            parts.append("A=\(value(colorChannels))")
        }
        return parts.joined(separator: "  ")
    }
}

enum DecodePipeline {

    /// Decodes `data` for display. Never throws: metadata and pixels are each
    /// gathered best-effort so the window can still show a report (and a clear
    /// error) for files we can inspect but not yet fully decode.
    static func decode(_ data: Data, name: String) -> DecodeResult {
        let report = MetadataReport.build(from: data)

        do {
            let info = try JXL.readInfo(from: data)
            let decoded = try JXL.decodeImage(from: data)
            let cg = try JXLImageConverter.makeCGImage(from: decoded, orientation: info.orientation)
            return DecodeResult(
                image: cg,
                sampler: PixelSampler(decoded, orientation: info.orientation),
                summary: summarize(info: info, image: decoded),
                report: report)
        } catch {
            let reason = (error as? JXLError).map(String.init(describing:))
                ?? error.localizedDescription
            return DecodeResult(
                image: nil, sampler: nil,
                summary: "✗ \(name): \(reason)", report: report)
        }
    }

    private static func summarize(info: JXLImageInfo, image: JXLDecodedImage) -> String {
        let color = image.colorChannels == 1 ? "Gray" : "RGB"
        let alpha = image.extraChannels > 0 ? "+A" : ""
        let sample =
            image.isFloat ? "\(image.bitsPerSample)-bit float" : "\(image.bitsPerSample)-bit"
        let kind = info.isContainer ? "container" : "bare codestream"
        return "\(image.width)×\(image.height)  \(color)\(alpha)  \(sample)  (\(kind))"
    }
}
