// JXLDecoder.swift
//
// Top-level entry points. Every pixel- and frame-level API is a thin wrapper
// over `FrameDecoder` (Frame/FrameDecoder.swift), which parses the container,
// codestream headers, FrameHeader, and TOC exactly once and caches each decode
// stage. `readInfo` stays standalone: it reads only through ImageMetadata and
// must work even for frames the frame parser cannot yet handle.

import Foundation

/// Lightweight description of a JPEG XL file, available without decoding pixels.
public struct JXLImageInfo: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let bitDepth: JXLBitDepth
    public let colorSpace: JXLColorSpace
    public let colorEncoding: JXLColorEncoding
    public let colorChannelCount: Int
    public let extraChannelCount: Int
    public let hasAlpha: Bool
    public let orientation: UInt32
    public let hasAnimation: Bool
    /// Tick rate and loop count when `hasAnimation`.
    public let animation: JXLAnimationInfo?
    /// `true` if delivered inside an ISOBMFF container, `false` for a bare codestream.
    public let isContainer: Bool
    /// The container's box types in order (empty for a bare codestream).
    public let boxTypes: [String]
}

/// Logical role of a TOC section in the frame payload.
public enum JXLFrameSectionRole: Equatable, Sendable {
    /// Single-group, single-pass frames coalesce DC-global, DC-group,
    /// AC-global, and AC-group payloads into section 0.
    case singleSectionCoalesced
    case dcGlobal
    case dcGroup(Int)
    case acGlobal
    case acGroup(pass: Int, group: Int)
}

/// Byte range for a TOC section in the frame payload.
public struct JXLFrameSectionInfo: Equatable, Sendable {
    /// Logical section id, after applying any TOC permutation.
    public let index: Int
    public let role: JXLFrameSectionRole
    /// Byte offset relative to `JXLFrameInfo.dataStartByte`.
    public let offset: Int
    public let size: Int
    /// Byte range within the bare codestream, not the outer container file.
    public let codestreamRange: Range<Int>
}

/// Structural description of a frame and its TOC.
public struct JXLFrameInfo: Sendable {
    public let isModular: Bool
    public let frameType: FrameType
    public let flags: UInt64
    public let isLast: Bool
    public let numGroups: Int
    public let numDCGroups: Int
    public let numPasses: Int
    public let tocEntryCount: Int
    public let sectionSizes: [UInt32]
    public let sections: [JXLFrameSectionInfo]
    public let totalSectionBytes: Int
    /// Byte offset (within the codestream) where the first section's data begins.
    public let dataStartByte: Int
    public let codestreamLength: Int
}

/// A decoded raster image: one Int32 plane per channel (color channels first,
/// then extra channels such as alpha), each `width * height` row-major.
public struct JXLDecodedImage: Sendable {
    public let width: Int
    public let height: Int
    public let colorChannels: Int  // 1 (grayscale) or 3 (RGB)
    public let extraChannels: Int
    public let bitsPerSample: Int
    /// When true, each Int32 sample is the IEEE-754 binary32 bit pattern of the
    /// pixel value (read via `Float(bitPattern: UInt32(bitPattern: sample))`).
    public let isFloat: Bool
    public let planes: [[Int32]]
    /// The embedded ICC profile describing the returned samples, when the file
    /// carries one AND the samples are in that profile's space (Modular frames).
    /// `nil` for VarDCT frames, whose planes are always converted to sRGB —
    /// use `JXL.readICCProfile` to obtain the raw embedded profile regardless.
    public let iccProfile: Data?
}

public enum JXL {
    /// Reads structural information (dimensions, container layout) from a JPEG XL file.
    public static func readInfo(from data: [UInt8]) throws -> JXLImageInfo {
        let parsed = try JXLContainer.parse(data)

        guard parsed.codestream.count >= 2,
            parsed.codestream[0] == 0xFF,
            parsed.codestream[1] == 0x0A
        else {
            throw JXLError.invalidSignature
        }

        let reader = BitReader(parsed.codestream)
        reader.skip(16)  // consume the FF 0A signature
        let size = SizeHeader(reader)
        let metadata = JXLImageMetadata(reader)
        try reader.ensureInBounds("ImageMetadata")

        return JXLImageInfo(
            width: size.width,
            height: size.height,
            bitDepth: metadata.bitDepth,
            colorSpace: metadata.colorSpace,
            colorEncoding: metadata.colorEncoding,
            colorChannelCount: metadata.colorChannelCount,
            extraChannelCount: metadata.extraChannelCount,
            hasAlpha: metadata.hasAlpha,
            orientation: metadata.orientation,
            hasAnimation: metadata.hasAnimation,
            animation: metadata.animation,
            isContainer: parsed.isContainer,
            boxTypes: parsed.boxes.map(\.type)
        )
    }

    /// Convenience overload reading from `Data`.
    public static func readInfo(from data: Data) throws -> JXLImageInfo {
        try readInfo(from: [UInt8](data))
    }

    /// Convenience overload reading a file from disk.
    public static func readInfo(contentsOf url: URL) throws -> JXLImageInfo {
        try readInfo(from: try Data(contentsOf: url))
    }

    /// Structural information about the first frame: encoding, group grid, and
    /// the TOC section layout. Available without decoding pixels.
    public static func readFrameInfo(from data: [UInt8]) throws -> JXLFrameInfo {
        try FrameDecoder(data: data).frameInfo()
    }

    public static func readFrameInfo(from data: Data) throws -> JXLFrameInfo {
        try readFrameInfo(from: [UInt8](data))
    }

    public static func readFrameInfo(contentsOf url: URL) throws -> JXLFrameInfo {
        try readFrameInfo(from: try Data(contentsOf: url))
    }

    /// Decodes a JPEG XL image to pixel planes. Modular (lossless) frames return
    /// their native samples (integers as values, 32-bit float as IEEE-754 bit
    /// patterns); VarDCT (lossy) frames reconstruct to three 8-bit sRGB planes.
    /// A single regular frame is supported. `limits` bounds the allocations a
    /// (possibly hostile) header can demand.
    public static func decodeImage(
        from data: [UInt8], limits: JXLDecodeLimits = .default
    ) throws -> JXLDecodedImage {
        try FrameDecoder(data: data, limits: limits).decodeImage()
    }

    public static func decodeImage(
        from data: Data, limits: JXLDecodeLimits = .default
    ) throws -> JXLDecodedImage {
        try decodeImage(from: [UInt8](data), limits: limits)
    }

    public static func decodeImage(
        contentsOf url: URL, limits: JXLDecodeLimits = .default
    ) throws -> JXLDecodedImage {
        try decodeImage(from: try Data(contentsOf: url), limits: limits)
    }

    /// Returns the raw bytes for one logical frame section. The section range is
    /// resolved against the bare codestream, so this works for both raw and
    /// container-wrapped `.jxl` inputs.
    public static func readFrameSectionData(from data: [UInt8], sectionIndex: Int) throws -> Data {
        let decoder = try FrameDecoder(data: data)
        guard sectionIndex >= 0 && sectionIndex < decoder.sectionCount else {
            throw JXLError.malformed("frame section index out of range")
        }
        return Data(decoder.codestream[decoder.sectionRange(sectionIndex)])
    }

    public static func readFrameSectionData(from data: Data, sectionIndex: Int) throws -> Data {
        try readFrameSectionData(from: [UInt8](data), sectionIndex: sectionIndex)
    }

    public static func readFrameSectionData(contentsOf url: URL, sectionIndex: Int) throws -> Data {
        try readFrameSectionData(from: try Data(contentsOf: url), sectionIndex: sectionIndex)
    }

    /// Returns a bit reader positioned at the start of one logical frame section.
    public static func readFrameSectionReader(from data: [UInt8], sectionIndex: Int) throws
        -> BitReader
    {
        let decoder = try FrameDecoder(data: data)
        guard sectionIndex >= 0 && sectionIndex < decoder.sectionCount else {
            throw JXLError.malformed("frame section index out of range")
        }
        return decoder.sectionReader(sectionIndex)
    }

    public static func readFrameSectionReader(from data: Data, sectionIndex: Int) throws
        -> BitReader
    {
        try readFrameSectionReader(from: [UInt8](data), sectionIndex: sectionIndex)
    }

    public static func readFrameSectionReader(contentsOf url: URL, sectionIndex: Int) throws
        -> BitReader
    {
        try readFrameSectionReader(from: try Data(contentsOf: url), sectionIndex: sectionIndex)
    }

    /// One decoded animation frame.
    public struct Frame: Sendable {
        public let image: JXLDecodedImage
        /// Duration in animation ticks (seconds = ticks × tpsDenominator /
        /// tpsNumerator); 0 for stills.
        public let durationTicks: UInt32
        public let isLast: Bool
    }

    /// Decodes every presented frame of an animated file (a still yields one
    /// frame). Frames whose composition is anything other than a full-frame
    /// replace are not yet supported.
    public static func decodeFrames(
        from data: [UInt8], limits: JXLDecodeLimits = .default, maxFrames: Int = 4096
    ) throws -> [Frame] {
        var frames: [Frame] = []
        for index in 0..<maxFrames {
            let decoder = try FrameDecoder(data: data, limits: limits, skipPresentedFrames: index)
            let header = decoder.frameHeader
            frames.append(
                Frame(
                    image: try decoder.decodeImage(),
                    durationTicks: header.duration, isLast: header.isLast))
            if header.isLast { break }
        }
        return frames
    }

    public static func decodeFrames(
        from data: Data, limits: JXLDecodeLimits = .default, maxFrames: Int = 4096
    ) throws -> [Frame] {
        try decodeFrames(from: [UInt8](data), limits: limits, maxFrames: maxFrames)
    }

    /// Decodes a fast 1/8-scale preview of a VarDCT (lossy) frame — the
    /// dequantized DC image through the normal color path, available in a
    /// small fraction of full decode time. Returns `nil` for Modular frames.
    public static func decodePreview(
        from data: [UInt8], limits: JXLDecodeLimits = .default
    ) throws -> JXLDecodedImage? {
        try FrameDecoder(data: data, limits: limits).decodePreviewImage()
    }

    public static func decodePreview(
        from data: Data, limits: JXLDecodeLimits = .default
    ) throws -> JXLDecodedImage? {
        try decodePreview(from: [UInt8](data), limits: limits)
    }

    /// Returns the embedded ICC profile, decoded from its compressed form, or
    /// `nil` when the file's color encoding does not carry one (`want_icc`
    /// unset). This is the profile as embedded — for XYB-encoded (lossy) files
    /// it describes the *original* color space, not the sRGB planes
    /// `decodeImage` currently produces.
    public static func readICCProfile(from data: [UInt8]) throws -> Data? {
        try FrameDecoder(data: data).iccProfile.map { Data($0) }
    }

    public static func readICCProfile(from data: Data) throws -> Data? {
        try readICCProfile(from: [UInt8](data))
    }

    public static func readICCProfile(contentsOf url: URL) throws -> Data? {
        try readICCProfile(from: try Data(contentsOf: url))
    }

    /// Parses the currently implemented VarDCT global metadata without decoding
    /// pixels. This is an incremental preflight API for the lossy path: DC-global
    /// metadata is parsed from section 0, and AC-global metadata is parsed when it
    /// is in a distinct TOC section. Single-section VarDCT frames return `nil` for
    /// `acGlobal` because DC groups precede AC-global inside the same section.
    public static func readVarDCTInfo(from data: [UInt8]) throws -> JXLVarDCTInfo {
        let decoder = try FrameDecoder(data: data)
        let frame = decoder.frameInfo()
        guard !frame.isModular else { throw JXLError.unsupported("Modular frame is not VarDCT") }

        // Preflight reads use their own section readers (not the staged decode
        // path), so they work on frames the strict pipeline still rejects.
        let r0 = decoder.sectionReader(0)
        if frame.flags & 2 != 0 {
            // The patch dictionary precedes the DC-global payload.
            _ = try decoder.parsePatchDictionary(r0)
        }
        let dcGlobal = try readVarDCTDCGlobalInfo(r0)
        let acGlobalIndex =
            frame.numGroups == 1 && frame.numPasses == 1 ? nil : frame.numDCGroups + 1
        let acGlobal: VarDCTACGlobalInfo?
        if let acGlobalIndex {
            acGlobal = try readVarDCTACGlobalInfo(
                decoder.sectionReader(acGlobalIndex),
                frame: frame,
                blockContextMap: dcGlobal.blockContextMap)
        } else {
            acGlobal = nil
        }
        return JXLVarDCTInfo(frame: frame, dcGlobal: dcGlobal, acGlobal: acGlobal)
    }

    public static func readVarDCTInfo(from data: Data) throws -> JXLVarDCTInfo {
        try readVarDCTInfo(from: [UInt8](data))
    }

    public static func readVarDCTInfo(contentsOf url: URL) throws -> JXLVarDCTInfo {
        try readVarDCTInfo(from: try Data(contentsOf: url))
    }
}
