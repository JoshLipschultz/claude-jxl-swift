// EncodeOptions.swift
//
// The unified public encode entry point: `JXL.encode(image:options:)`. It adds
// the two things the older `encodeLossless` / `encodeLossy` wrappers cannot
// express — container output and non-pixel metadata (ICC / Exif / XMP) — while
// leaving those wrappers untouched, so every existing size golden is unmoved.
//
// Defaults are deliberately identical to `encodeLossless(image:)`: lossless,
// effort 2, no squeeze, BARE CODESTREAM. Container output is opt-in.

import Foundation

/// How the codestream is delivered.
public enum JXLOutputFormat: Sendable, Equatable {
    /// A bare codestream beginning with `FF 0A` (the default). Can carry an
    /// embedded ICC profile (which lives in the codestream), but no boxes.
    case bareCodestream
    /// An ISOBMFF container: signature box, `ftyp`, metadata boxes, `jxlc`.
    case container
}

/// Everything the encoder needs beyond the pixels.
public struct JXLEncodeOptions: Sendable {
    /// `nil` (default) encodes losslessly; `1...100` selects the lossy XYB
    /// VarDCT path at that quality.
    public var quality: Int?
    /// Encoder effort, honoured by BOTH paths. Lossless: 1 = fast (fixed
    /// gradient tree, RCT only), 2 = default (learned trees, WP, palette,
    /// multipliers). Lossy: 1 skips learning the global modular tree, which
    /// roughly halves encode time at 20-30% larger files on smooth content;
    /// 2 = default
    /// (learned trees, WP, palette, multipliers). Ignored when lossy.
    public var effort: Int
    /// Lossless responsive mode (squeeze). Ignored when lossy.
    public var squeeze: Bool
    /// Bare codestream (default) or ISOBMFF container.
    public var format: JXLOutputFormat

    /// ICC profile to embed in the codestream metadata as the image's color
    /// encoding. When `nil`, `image.iccProfile` is used if the image carries
    /// one, so a profile survives a decode → encode round trip by default.
    /// Set `dropICCProfile` to suppress that.
    ///
    /// Lossless only: the samples then ARE in the profile's space. The lossy
    /// path encodes XYB from sRGB-interpreted input, so embedding a profile
    /// there would mislabel the colors; it is rejected rather than approximated.
    public var iccProfile: Data?
    /// Ignore `image.iccProfile` (has no effect on an explicit `iccProfile`).
    public var dropICCProfile: Bool

    /// Exif metadata as the raw TIFF stream (starting `II*\0` or `MM\0*`). The
    /// container's 4-byte TIFF-header-offset prefix is added by the writer.
    /// Requires `format == .container`.
    public var exif: Data?
    /// XMP packet (UTF-8 XML), written verbatim to an `xml ` box. Requires
    /// `format == .container`.
    public var xmp: Data?

    public init(
        quality: Int? = nil, effort: Int = 2, squeeze: Bool = false,
        format: JXLOutputFormat = .bareCodestream, iccProfile: Data? = nil,
        dropICCProfile: Bool = false, exif: Data? = nil, xmp: Data? = nil
    ) {
        self.quality = quality
        self.effort = effort
        self.squeeze = squeeze
        self.format = format
        self.iccProfile = iccProfile
        self.dropICCProfile = dropICCProfile
        self.exif = exif
        self.xmp = xmp
    }

    /// Convenience: lossless, container output.
    public static func losslessContainer(
        effort: Int = 2, squeeze: Bool = false, iccProfile: Data? = nil,
        exif: Data? = nil, xmp: Data? = nil
    ) -> JXLEncodeOptions {
        JXLEncodeOptions(
            effort: effort, squeeze: squeeze, format: .container, iccProfile: iccProfile,
            exif: exif, xmp: xmp)
    }
}

extension JXL {
    /// Encodes `image` per `options`. With the default options this is exactly
    /// `encodeLossless(image:)` — same bytes, bare codestream.
    ///
    /// Metadata placement: the ICC profile goes in the CODESTREAM (so it works
    /// for bare output too); Exif and XMP are container boxes and therefore
    /// require `format == .container`. Nothing is ever silently dropped — an
    /// impossible combination throws.
    public static func encode(
        image: JXLDecodedImage, options: JXLEncodeOptions = JXLEncodeOptions()
    ) throws -> [UInt8] {
        let icc: [UInt8]? = {
            if let explicit = options.iccProfile { return [UInt8](explicit) }
            if options.dropICCProfile { return nil }
            return image.iccProfile.map { [UInt8]($0) }
        }()

        let codestream: [UInt8]
        if let q = options.quality {
            // Refuse rather than drop: the caller has to say explicitly that
            // losing the profile is acceptable.
            guard icc == nil else {
                throw JXLEncodeError(
                    reason: "lossy encoding cannot embed an ICC profile: XYB is derived from "
                        + "sRGB-interpreted samples, so the profile would mislabel the colors. "
                        + "Pass dropICCProfile: true to encode without it")
            }
            codestream = try VarDCTEncoder.encodeLossy(
                image, quality: q, effort: options.effort)
        } else {
            codestream = try ModularEncoder.encodeLossless(
                image, effort: options.effort, squeeze: options.squeeze, icc: icc)
        }

        guard options.format == .container else {
            guard options.exif == nil, options.xmp == nil else {
                throw JXLEncodeError(
                    reason: "Exif/XMP need container output (format: .container); a bare "
                        + "codestream has no boxes")
            }
            return codestream
        }

        var boxes: [ContainerBox] = []
        if let exif = options.exif {
            boxes.append(MetadataBoxes.exif([UInt8](exif)))
        }
        if let xmp = options.xmp {
            boxes.append(MetadataBoxes.xmp([UInt8](xmp)))
        }
        return try ContainerWriter.assemble(codestream: codestream, metadataBoxes: boxes)
    }
}
