// DecodePipeline.swift
//
// Off-actor decoding plus the Sendable value types that carry the result back to
// the main actor for display. Keeping this separate from the AppKit classes lets
// the heavy work run on a background task with no reference to any UI object.

import CoreGraphics
import Foundation
import JXLCore
import JXLKit

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

/// A fully decoded animation ready for playback. `@unchecked` for the same
/// reason as `DecodeResult`: `CGImage` is immutable.
struct AnimationResult: @unchecked Sendable {
    /// One CGImage per presented frame, in presentation order.
    let frames: [CGImage]
    /// Per-frame durations in seconds (parallel to `frames`).
    let durations: [TimeInterval]
    /// Number of times to play the sequence; 0 = loop forever.
    let numLoops: UInt32
}

/// What the third (animation) decode stage produced.
enum AnimationDecodeOutcome: @unchecked Sendable {
    /// Still image (or single presented frame) — nothing to play.
    case notAnimated
    /// All frames decoded; start playback.
    case animation(AnimationResult)
    /// The frames would exceed the decoded-frame memory cap; the still first
    /// frame stays up and the status bar notes why.
    case tooLarge
    /// Frame decoding failed (e.g. non-replace composition is unsupported);
    /// the still first frame stays up.
    case failed
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

    /// A fast 1/8-scale preview (VarDCT DC image) for immediate display while
    /// the full decode runs; `nil` when no cheap preview exists (Modular) or
    /// anything fails — callers just wait for the full image then.
    static func decodePreview(_ data: Data) -> (image: CGImage, fullSize: CGSize)? {
        guard let info = try? JXL.readInfo(from: data),
            let decoded = try? JXL.decodePreview(from: data),
            let cg = try? JXLImageConverter.makeCGImage(
                from: decoded, orientation: info.orientation,
                colorEncoding: info.colorEncoding)
        else { return nil }
        // Displayed size is the full image's (orientation-swapped when needed).
        let swapped = info.orientation >= 5
        let fullSize = CGSize(
            width: CGFloat(swapped ? info.height : info.width),
            height: CGFloat(swapped ? info.width : info.height))
        return (cg, fullSize)
    }

    /// Decodes `data` for display. Never throws: metadata and pixels are each
    /// gathered best-effort so the window can still show a report (and a clear
    /// error) for files we can inspect but not yet fully decode.
    static func decode(_ data: Data, name: String) -> DecodeResult {
        let report = MetadataReport.build(from: data)

        do {
            let info = try JXL.readInfo(from: data)
            // HDR files (PQ/HLG) decode at 16 bits so precision and EDR
            // headroom survive into the CGImage.
            let isHDR =
                info.colorEncoding.transferFunction == 16
                || info.colorEncoding.transferFunction == 18
            let decoded = try JXL.decodeImage(from: data, format: isHDR ? .uint16 : .uint8)
            let cg = try JXLImageConverter.makeCGImage(
                from: decoded, orientation: info.orientation,
                colorEncoding: info.colorEncoding)
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

    /// Cap on total retained CGImage frame memory for an animation (~512 MB).
    /// Beyond it we keep the still first frame rather than risk ballooning.
    private static let animationMemoryCap = 512 << 20

    /// Decodes every frame of an animated file into CGImages plus per-frame
    /// durations. Cheap for stills: a header read answers `.notAnimated`
    /// before any pixel work. Never throws — any failure means the caller
    /// keeps showing the still first frame it already has.
    static func decodeAnimation(_ data: Data) -> AnimationDecodeOutcome {
        guard let info = try? JXL.readInfo(from: data),
            info.hasAnimation, let anim = info.animation,
            anim.tpsNumerator > 0
        else { return .notAnimated }

        // Bound the number of frames we retain so total CGImage memory stays
        // under the cap (RGBA8 = 4 bytes/px; HDR frames convert at 16-bit).
        let isHDR =
            info.colorEncoding.transferFunction == 16
            || info.colorEncoding.transferFunction == 18
        let bytesPerFrame = max(1, Int(info.width) * Int(info.height) * (isHDR ? 8 : 4))
        let maxFrames = max(1, animationMemoryCap / bytesPerFrame)

        let frames: [JXL.Frame]
        do {
            frames = try JXL.decodeFrames(from: data, maxFrames: maxFrames)
        } catch {
            return .failed
        }
        guard frames.count > 1 else { return .notAnimated }
        // decodeFrames stopped at maxFrames before reaching the last frame:
        // the full sequence would blow the memory cap.
        guard frames.last?.isLast == true else { return .tooLarge }

        let secondsPerTick = Double(anim.tpsDenominator) / Double(anim.tpsNumerator)
        var images: [CGImage] = []
        var durations: [TimeInterval] = []
        images.reserveCapacity(frames.count)
        durations.reserveCapacity(frames.count)
        for frame in frames {
            guard
                let cg = try? JXLImageConverter.makeCGImage(
                    from: frame.image, orientation: info.orientation,
                    colorEncoding: info.colorEncoding)
            else { return .failed }
            images.append(cg)
            durations.append(Double(frame.durationTicks) * secondsPerTick)
        }
        return .animation(
            AnimationResult(frames: images, durations: durations, numLoops: anim.numLoops))
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
