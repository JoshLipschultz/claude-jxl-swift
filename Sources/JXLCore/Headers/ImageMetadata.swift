// ImageMetadata.swift
//
// JPEG XL ImageMetadata / basic info (ISO/IEC 18181-1 §D.3). Field layout is a
// faithful port of libjxl v0.11.2 `ImageMetadata::VisitFields` (image_metadata.cc)
// and the nested bundles (BitDepth, ExtraChannelInfo, ColorEncoding,
// CustomTransferFunction, Customxy, ToneMapping, AnimationHeader, PreviewHeader).
// The whole structure is consumed bit-exactly so the reader ends precisely at
// the start of the frame data (required from M4 onward).

import Foundation

public struct JXLBitDepth: Equatable, Sendable {
    public let bitsPerSample: UInt32
    public let exponentBitsPerSample: UInt32

    public var isFloatingPoint: Bool { exponentBitsPerSample > 0 }
}

public enum JXLColorSpace: UInt32, Equatable, Sendable {
    case rgb = 0
    case grayscale = 1
    case xyb = 2
    case unknown = 3
}

/// A CIE xy chromaticity coordinate (signaled as signed micro-units).
public struct JXLChromaticity: Equatable, Sendable {
    public let x: Double
    public let y: Double
}

/// The serialized color encoding (everything signaled in the codestream's
/// ColorEncoding bundle). Enum-valued fields use the raw codestream values,
/// matching libjxl's public `JxlColorEncoding`.
public struct JXLColorEncoding: Equatable, Sendable {
    public let wantICC: Bool
    public let colorSpace: JXLColorSpace
    /// 1=D65, 2=Custom, 10=E, 11=DCI. 0 when not signaled (ICC or XYB).
    public let whitePoint: UInt32
    /// Signaled only when `whitePoint == 2` (Custom).
    public let customWhitePoint: JXLChromaticity?
    /// 1=sRGB, 2=Custom, 9=2100, 11=P3. 0 when not signaled (gray/XYB/ICC).
    public let primaries: UInt32
    /// Signaled only when `primaries == 2` (Custom): red, green, blue.
    public let customPrimaries: [JXLChromaticity]?
    public let hasGamma: Bool
    /// gamma × 1e7, valid only when `hasGamma`.
    public let gamma: UInt32
    /// 1=709, 2=Unknown, 8=Linear, 13=sRGB, 16=PQ, 17=DCI, 18=HLG. 0 when ICC.
    public let transferFunction: UInt32
    /// 0=Perceptual, 1=Relative, 2=Saturation, 3=Absolute. 0 when ICC.
    public let renderingIntent: UInt32
}

/// One extra channel's metadata (libjxl `ExtraChannelInfo`).
public struct JXLExtraChannelInfo: Equatable, Sendable {
    /// 0=Alpha, 1=Depth, 2=SpotColor, 3=SelectionMask, 4=Black, 5=CFA,
    /// 6=Thermal, 15=Unknown, 16=Optional.
    public let type: UInt32
    public let bitDepth: JXLBitDepth
    public let dimShift: UInt32
    /// Alpha only: samples are premultiplied.
    public let alphaAssociated: Bool
}

/// ToneMapping (libjxl image_metadata.h): the display characteristics the
/// samples were mastered for. `intensityTarget` is the luminance (cd/m²) of
/// the maximum sample value — 255 for SDR content, and the mastering peak
/// (commonly 1000-10000) for PQ/HLG content, where it scales the transfer.
public struct JXLToneMapping: Equatable, Sendable {
    public var intensityTarget: Float = 255
    public var minNits: Float = 0
    public var relativeToMaxDisplay = false
    public var linearBelow: Float = 0
}

/// AnimationHeader (libjxl headers): tick rate and loop count for animated
/// files. A frame's duration is in ticks; seconds = ticks × den / num.
public struct JXLAnimationInfo: Equatable, Sendable {
    public let tpsNumerator: UInt32
    public let tpsDenominator: UInt32
    /// 0 = loop forever.
    public let numLoops: UInt32
    public let haveTimecodes: Bool
}

public struct JXLImageMetadata: Equatable, Sendable {
    public let bitDepth: JXLBitDepth
    public let colorEncoding: JXLColorEncoding
    public let extraChannels: [JXLExtraChannelInfo]
    public let hasAlpha: Bool
    /// Present when the file is animated.
    public let animation: JXLAnimationInfo?
    /// Mastering display characteristics (defaults describe SDR).
    public let toneMapping: JXLToneMapping

    public var extraChannelCount: Int { extraChannels.count }
    public let orientation: UInt32
    public let hasAnimation: Bool
    /// Whether color channels are XYB-encoded (true for lossy/VarDCT defaults).
    public let xybEncoded: Bool

    public var colorSpace: JXLColorSpace { colorEncoding.colorSpace }
    public var colorChannelCount: Int { colorSpace == .grayscale ? 1 : 3 }

    public init(_ reader: BitReader) {
        let allDefault = reader.readBool()
        if allDefault {
            self.bitDepth = JXLBitDepth(bitsPerSample: 8, exponentBitsPerSample: 0)
            self.colorEncoding = ImageMetadataFields.defaultSRGB
            self.extraChannels = []
            self.hasAlpha = false
            self.animation = nil
            self.toneMapping = JXLToneMapping()
            self.orientation = 1
            self.hasAnimation = false
            self.xybEncoded = true
            return
        }

        let extraFields = reader.readBool()

        var parsedOrientation: UInt32 = 1
        var parsedHasAnimation = false
        var parsedAnimation: JXLAnimationInfo? = nil
        if extraFields {
            parsedOrientation = UInt32(reader.read(3)) + 1
            if reader.readBool() {  // have_intrinsic_size
                _ = SizeHeader(reader)
            }
            if reader.readBool() {  // have_preview
                ImageMetadataFields.skipPreviewHeader(reader)
            }
            if reader.readBool() {  // have_animation
                parsedHasAnimation = true
                parsedAnimation = ImageMetadataFields.readAnimationHeader(reader)
            }
        }

        let parsedBitDepth = ImageMetadataFields.readBitDepth(reader)
        _ = reader.readBool()  // modular_16bit_buffers

        let numExtraChannels = Int(
            reader.readU32(.value(0), .value(1), .bits(4, offset: 2), .bits(12, offset: 1)))

        var alpha = false
        var parsedExtra: [JXLExtraChannelInfo] = []
        for _ in 0..<numExtraChannels {
            let info = ImageMetadataFields.readExtraChannelInfo(reader)
            if info.type == 0 { alpha = true }  // kAlpha
            parsedExtra.append(info)
        }

        let parsedXybEncoded = reader.readBool()  // xyb_encoded
        let parsedColor = ImageMetadataFields.readColorEncoding(reader)

        var parsedToneMapping = JXLToneMapping()
        if extraFields {
            parsedToneMapping = ImageMetadataFields.readToneMapping(reader)
        }
        reader.skipExtensions()

        self.bitDepth = parsedBitDepth
        self.colorEncoding = parsedColor
        self.extraChannels = parsedExtra
        self.hasAlpha = alpha
        self.animation = parsedAnimation
        self.toneMapping = parsedToneMapping
        self.orientation = parsedOrientation
        self.hasAnimation = parsedHasAnimation
        self.xybEncoded = parsedXybEncoded
    }
}

private enum ImageMetadataFields {
    static let defaultSRGB = JXLColorEncoding(
        wantICC: false, colorSpace: .rgb, whitePoint: 1, customWhitePoint: nil,
        primaries: 1, customPrimaries: nil,
        hasGamma: false, gamma: 0, transferFunction: 13, renderingIntent: 1)

    // MARK: BitDepth

    static func readBitDepth(_ reader: BitReader) -> JXLBitDepth {
        let floatingPoint = reader.readBool()
        if !floatingPoint {
            let bits = reader.readU32(.value(8), .value(10), .value(12), .bits(6, offset: 1))
            return JXLBitDepth(bitsPerSample: bits, exponentBitsPerSample: 0)
        } else {
            let bits = reader.readU32(.value(32), .value(16), .value(24), .bits(6, offset: 1))
            // Encoded value is (exponent_bits - 1) in 4 bits; range [1, 8].
            let exponentBits = UInt32(reader.read(4)) + 1
            return JXLBitDepth(bitsPerSample: bits, exponentBitsPerSample: exponentBits)
        }
    }

    // MARK: ExtraChannelInfo (returns the channel type)

    static func readExtraChannelInfo(_ reader: BitReader) -> JXLExtraChannelInfo {
        if reader.readBool() {  // all_default
            return JXLExtraChannelInfo(
                type: 0,  // kAlpha
                bitDepth: JXLBitDepth(bitsPerSample: 8, exponentBitsPerSample: 0),
                dimShift: 0, alphaAssociated: false)
        }
        let type = reader.readEnum()
        let bitDepth = readBitDepth(reader)
        let dimShift = reader.readU32(.value(0), .value(3), .value(4), .bits(3, offset: 1))
        skipNameString(reader)

        var alphaAssociated = false
        if type == 0 {  // kAlpha
            alphaAssociated = reader.readBool()
        }
        if type == 2 {  // kSpotColor
            for _ in 0..<4 { _ = reader.readF16() }
        }
        if type == 5 {  // kCFA
            _ = reader.readU32(.value(1), .bits(2), .bits(4, offset: 3), .bits(8, offset: 19))
        }
        return JXLExtraChannelInfo(
            type: type, bitDepth: bitDepth, dimShift: dimShift,
            alphaAssociated: alphaAssociated)
    }

    /// Per libjxl `VisitNameString`: length = U32(Val(0), Bits(4),
    /// BitsOffset(5, 16), BitsOffset(10, 48)), then `length` bytes of u(8).
    static func skipNameString(_ reader: BitReader) {
        let length = Int(
            reader.readU32(.value(0), .bits(4), .bits(5, offset: 16), .bits(10, offset: 48)))
        for _ in 0..<length { _ = reader.read(8) }
    }

    // MARK: ColorEncoding

    static func readColorEncoding(_ reader: BitReader) -> JXLColorEncoding {
        if reader.readBool() {  // all_default
            return defaultSRGB
        }

        let wantICC = reader.readBool()
        let rawColorSpace = reader.readEnum()
        let colorSpace = JXLColorSpace(rawValue: rawColorSpace) ?? .unknown

        var whitePoint: UInt32 = 0
        var primaries: UInt32 = 0
        var hasGamma = false
        var gamma: UInt32 = 0
        var transferFunction: UInt32 = 0
        var renderingIntent: UInt32 = 0

        var customWhitePoint: JXLChromaticity? = nil
        var customPrimaries: [JXLChromaticity]? = nil

        if !wantICC {
            // White point — read unless the color space implies it (XYB).
            if colorSpace != .xyb {
                whitePoint = reader.readEnum()
                if whitePoint == 2 {  // kCustom
                    customWhitePoint = readCustomxy(reader)
                }
            }
            // Primaries — only when the color space has them (not gray, not XYB).
            if colorSpace != .grayscale && colorSpace != .xyb {
                primaries = reader.readEnum()
                if primaries == 2 {  // kCustom
                    customPrimaries = [
                        readCustomxy(reader),  // red
                        readCustomxy(reader),  // green
                        readCustomxy(reader),  // blue
                    ]
                }
            }
            // CustomTransferFunction — implicit (skipped) for XYB.
            if colorSpace != .xyb {
                hasGamma = reader.readBool()
                if hasGamma {
                    gamma = UInt32(reader.read(24))
                } else {
                    transferFunction = reader.readEnum()
                }
            }
            renderingIntent = reader.readEnum()
        }

        return JXLColorEncoding(
            wantICC: wantICC, colorSpace: colorSpace,
            whitePoint: whitePoint, customWhitePoint: customWhitePoint,
            primaries: primaries, customPrimaries: customPrimaries,
            hasGamma: hasGamma, gamma: gamma,
            transferFunction: transferFunction, renderingIntent: renderingIntent)
    }

    /// Customxy: two coordinates, each U32(Bits(19), BitsOffset(19, 524288),
    /// BitsOffset(20, 1048576), BitsOffset(21, 2097152)) holding a packed signed
    /// micro-unit value (x * 1e6, zig-zag coded).
    static func readCustomxy(_ reader: BitReader) -> JXLChromaticity {
        var coords = [Double](repeating: 0, count: 2)
        for i in 0..<2 {
            let packed = reader.readU32(
                .bits(19), .bits(19, offset: 524288), .bits(20, offset: 1_048_576),
                .bits(21, offset: 2_097_152))
            let signed = Int32(bitPattern: (packed >> 1) ^ (0 &- (packed & 1)))
            coords[i] = Double(signed) * 1e-6
        }
        return JXLChromaticity(x: coords[0], y: coords[1])
    }

    // MARK: Optional sub-headers (consumed, values not exposed yet)

    static func readToneMapping(_ reader: BitReader) -> JXLToneMapping {
        if reader.readBool() { return JXLToneMapping() }  // all_default
        let intensityTarget = reader.readF16()
        let minNits = reader.readF16()
        let relativeToMaxDisplay = reader.readBool()
        let linearBelow = reader.readF16()
        return JXLToneMapping(
            intensityTarget: intensityTarget, minNits: minNits,
            relativeToMaxDisplay: relativeToMaxDisplay, linearBelow: linearBelow)
    }

    static func readAnimationHeader(_ reader: BitReader) -> JXLAnimationInfo {
        let tpsNumerator = reader.readU32(
            .value(100), .value(1000), .bits(10, offset: 1), .bits(30, offset: 1))
        let tpsDenominator = reader.readU32(
            .value(1), .value(1001), .bits(8, offset: 1), .bits(10, offset: 1))
        let numLoops = reader.readU32(.value(0), .bits(3), .bits(16), .bits(32))
        let haveTimecodes = reader.readBool()
        return JXLAnimationInfo(
            tpsNumerator: tpsNumerator, tpsDenominator: tpsDenominator,
            numLoops: numLoops, haveTimecodes: haveTimecodes)
    }

    /// PreviewHeader (headers.cc) — its own size encoding, not a SizeHeader.
    static func skipPreviewHeader(_ reader: BitReader) {
        let div8 = reader.readBool()
        if div8 {
            _ = reader.readU32(.value(16), .value(32), .bits(5, offset: 1), .bits(9, offset: 33))
        } else {
            _ = reader.readU32(
                .bits(6, offset: 1), .bits(8, offset: 65), .bits(10, offset: 321),
                .bits(12, offset: 1345))
        }
        let ratio = reader.read(3)
        if ratio == 0 {
            if div8 {
                _ = reader.readU32(.value(16), .value(32), .bits(5, offset: 1), .bits(9, offset: 33))
            } else {
                _ = reader.readU32(
                    .bits(6, offset: 1), .bits(8, offset: 65), .bits(10, offset: 321),
                    .bits(12, offset: 1345))
            }
        }
    }
}
