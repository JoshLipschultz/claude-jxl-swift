// ImageMetadata.swift
//
// Basic JPEG XL image metadata parsing (ISO/IEC 18181-1 §D.3). This is the
// M2 structural layer: it reads enough of ImageMetadata to expose channel count,
// bit depth, floating-point samples, alpha, orientation, and animation presence.
// It intentionally stops before frame parsing.

import Foundation

public struct JXLBitDepth: Equatable {
    public let bitsPerSample: UInt32
    public let exponentBitsPerSample: UInt32

    public var isFloatingPoint: Bool { exponentBitsPerSample > 0 }
}

public enum JXLColorSpace: UInt32, Equatable {
    case rgb = 0
    case grayscale = 1
    case xyb = 2
    case unknown = 3
}

public struct JXLImageMetadata: Equatable {
    public let bitDepth: JXLBitDepth
    public let colorSpace: JXLColorSpace
    public let extraChannelCount: Int
    public let hasAlpha: Bool
    public let orientation: UInt32
    public let hasAnimation: Bool

    public var colorChannelCount: Int {
        colorSpace == .grayscale ? 1 : 3
    }

    public init(_ reader: BitReader) {
        let allDefault = reader.readBool()

        if allDefault {
            self.bitDepth = JXLBitDepth(bitsPerSample: 8, exponentBitsPerSample: 0)
            self.colorSpace = .rgb
            self.extraChannelCount = 0
            self.hasAlpha = false
            self.orientation = 1
            self.hasAnimation = false
            return
        }

        let extraFields = reader.readBool()

        let parsedOrientation: UInt32
        let parsedHasAnimation: Bool
        if extraFields {
            parsedOrientation = ImageMetadataFields.readOrientation(reader)

            if reader.readBool() {
                _ = SizeHeader(reader)  // intrinsic size
            }
            if reader.readBool() {
                ImageMetadataFields.skipPreviewHeader(reader)
            }
            if reader.readBool() {
                parsedHasAnimation = true
                ImageMetadataFields.skipAnimationHeader(reader)
            } else {
                parsedHasAnimation = false
            }
        } else {
            parsedOrientation = 1
            parsedHasAnimation = false
        }

        let parsedBitDepth = ImageMetadataFields.readBitDepth(reader)

        _ = reader.readBool()  // modular_16bit_buffers

        let numExtraChannels = Int(
            reader.readU32(
                .value(0),
                .value(1),
                .bits(4, offset: 2),
                .bits(12, offset: 18)
            ))

        var alpha = false
        for _ in 0..<numExtraChannels {
            let info = ImageMetadataFields.readExtraChannelInfo(reader, extraFields: extraFields)
            if info.type == 0 { alpha = true }
        }

        _ = reader.readBool()  // xyb_encoded
        let parsedColor = ImageMetadataFields.readColorEncoding(reader)

        // NOTE: We deliberately stop parsing here. `JXLImageMetadata` exposes only
        // fields that are fully determined at or before `color_space` (all of
        // which are validated against libjxl). The remainder of ColorEncoding
        // (white point, primaries, transfer function, rendering intent) and the
        // trailing ImageMetadata fields (tone mapping, extensions) require
        // bit-exact consumption that is not yet pinned down — see the comment on
        // `readColorEncoding`. They become necessary only when frame parsing
        // begins (M4), and will be nailed down then.

        self.bitDepth = parsedBitDepth
        self.colorSpace = parsedColor
        self.extraChannelCount = numExtraChannels
        self.hasAlpha = alpha
        self.orientation = parsedOrientation
        self.hasAnimation = parsedHasAnimation
    }
}

private enum ImageMetadataFields {
    struct ExtraChannelInfo {
        let type: UInt32
    }

    static func readBitDepth(_ reader: BitReader) -> JXLBitDepth {
        if reader.readBool() {
            let bits = reader.readU32(
                .value(32),
                .value(16),
                .bits(4, offset: 1),
                .bits(6, offset: 1)
            )
            let exponentBits = UInt32(reader.read(4)) + 1
            return JXLBitDepth(bitsPerSample: bits, exponentBitsPerSample: exponentBits)
        } else {
            let bits = reader.readU32(
                .value(8),
                .value(10),
                .value(12),
                .bits(6, offset: 1)
            )
            return JXLBitDepth(bitsPerSample: bits, exponentBitsPerSample: 0)
        }
    }

    static func readOrientation(_ reader: BitReader) -> UInt32 {
        reader.readU32(
            .value(1),
            .value(2),
            .value(3),
            .bits(3, offset: 4)
        )
    }

    static func readExtraChannelInfo(_ reader: BitReader, extraFields: Bool) -> ExtraChannelInfo {
        let allDefault = reader.readBool()
        if allDefault {
            return ExtraChannelInfo(type: 0)  // alpha
        }

        let type = reader.readEnum()
        _ = readBitDepth(reader)
        _ = reader.readU32(
            .value(0),
            .value(3),
            .bits(2, offset: 1),
            .bits(3, offset: 1)
        )  // dim_shift

        let nameLength = Int(
            reader.readU32(
                .value(0),
                .bits(4, offset: 1),
                .bits(5, offset: 17),
                .bits(10, offset: 49)
            ))
        if nameLength > 0 {
            reader.alignToByte()
            reader.skip(nameLength * 8)
        }

        if type == 0 {
            _ = reader.readBool()  // alpha_associated
        }

        if extraFields {
            if type == 2 {  // spot color
                _ = reader.readF16()
                _ = reader.readF16()
                _ = reader.readF16()
                _ = reader.readF16()
            }
            if type == 4 {  // CFA
                _ = reader.readU32(.bits(2), .bits(4), .bits(8), .bits(16))
            }
        }

        return ExtraChannelInfo(type: type)
    }

    /// Reads `ColorEncoding` (ISO/IEC 18181-1 §D.3.3) only as far as the color
    /// space, which is all this metadata layer exposes.
    ///
    /// The fields after `color_space` — white point, primaries, transfer
    /// function, rendering intent — are intentionally not consumed. In
    /// differential testing against libjxl, the encoded form of these for the
    /// default-grayscale case did not reproduce libjxl's reported values
    /// (transfer=sRGB/intent=Relative) at any plausible offset or Enum grammar,
    /// meaning our model of this tail is still incomplete. Rather than advance
    /// the bit reader by an unverified amount, we stop at `color_space`. This is
    /// safe because nothing downstream of `JXLImageMetadata.init` depends on the
    /// reader position. Full, bit-exact ColorEncoding consumption is required
    /// only once frame parsing begins (M4); it will be resolved against the
    /// libjxl source / spec text at that point.
    static func readColorEncoding(_ reader: BitReader) -> JXLColorSpace {
        let allDefault = reader.readBool()
        if allDefault {
            return .rgb  // default color encoding is sRGB
        }
        _ = reader.readBool()  // want_icc
        let rawColorSpace = reader.readEnum()
        return JXLColorSpace(rawValue: rawColorSpace) ?? .unknown
    }

    static func skipPreviewHeader(_ reader: BitReader) {
        _ = SizeHeader(reader)
    }

    static func skipAnimationHeader(_ reader: BitReader) {
        _ = reader.readU32(
            .bits(0, offset: 100), .bits(0, offset: 1000), .bits(10, offset: 1),
            .bits(30, offset: 1))
        _ = reader.readU32(
            .bits(0, offset: 1), .bits(0, offset: 1001), .bits(8, offset: 1), .bits(10, offset: 1))
        _ = reader.readBool()  // have_timecodes
        _ = reader.readU32(
            .value(0), .bits(3, offset: 1), .bits(16, offset: 1), .bits(32, offset: 1))
    }
}
