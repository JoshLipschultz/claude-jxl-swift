// JXLDecoder.swift
//
// Top-level entry points. This is the orchestrator that will grow to drive the
// full decode pipeline (headers -> frames -> entropy -> Modular/VarDCT -> pixels).
//
// Current milestone (M2 partial): container demux + dimensions + basic image
// metadata. Frame, entropy, Modular/VarDCT, and pixel decoding land next.

import Foundation

/// Lightweight description of a JPEG XL file, available without decoding pixels.
public struct JXLImageInfo: Equatable {
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
    /// `true` if delivered inside an ISOBMFF container, `false` for a bare codestream.
    public let isContainer: Bool
    /// The container's box types in order (empty for a bare codestream).
    public let boxTypes: [String]
}

/// Structural description of a frame and its TOC.
public struct JXLFrameInfo {
    public let isModular: Bool
    public let frameType: FrameType
    public let isLast: Bool
    public let numGroups: Int
    public let numDCGroups: Int
    public let numPasses: Int
    public let tocEntryCount: Int
    public let sectionSizes: [UInt32]
    public let totalSectionBytes: Int
    /// Byte offset (within the codestream) where the first section's data begins.
    public let dataStartByte: Int
    public let codestreamLength: Int
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
            isContainer: parsed.isContainer,
            boxTypes: parsed.boxes.map(\.type)
        )
    }

    /// Convenience overload reading from `Data`.
    public static func readInfo(from data: Data) throws -> JXLImageInfo {
        try readInfo(from: [UInt8](data))
    }

    /// Structural information about the first frame: encoding, group grid, and
    /// the TOC section layout. Available without decoding pixels.
    public static func readFrameInfo(from data: [UInt8]) throws -> JXLFrameInfo {
        let parsed = try JXLContainer.parse(data)
        guard parsed.codestream.count >= 2,
            parsed.codestream[0] == 0xFF, parsed.codestream[1] == 0x0A
        else { throw JXLError.invalidSignature }

        let reader = BitReader(parsed.codestream)
        reader.skip(16)
        let size = SizeHeader(reader)
        let metadata = JXLImageMetadata(reader)
        if metadata.colorEncoding.wantICC {
            // A compressed ICC profile would follow here; not yet supported.
            throw JXLError.unsupported("embedded ICC profile")
        }
        // The image header is followed by byte alignment before the frames
        // (libjxl JxlDecoderReadAllHeaders -> JumpToByteBoundary).
        reader.alignToByte()

        let ctx = FrameContext(metadata: metadata, width: size.width, height: size.height)
        let frameHeader = FrameHeader(reader: reader, context: ctx)
        let dim = frameHeader.frameDimensions(ctx)
        let entries = numTocEntries(
            numGroups: dim.numGroups, numDCGroups: dim.numDCGroups, numPasses: Int(frameHeader.numPasses))

        if parsed.codestream.count == 54 {
            FileHandle.standardError.write(Data("DEBUG 1x1_lossy: bitPosBeforeTOC=\(reader.bitPosition) modular=\(frameHeader.isModular) numPasses=\(frameHeader.numPasses) numGroups=\(dim.numGroups) numDCGroups=\(dim.numDCGroups) entries=\(entries)\n".utf8))
        }
        guard let toc = readGroupOffsets(reader, tocEntries: entries) else {
            throw JXLError.malformed("could not read TOC")
        }
        if parsed.codestream.count == 54 {
            FileHandle.standardError.write(Data("DEBUG 1x1_lossy: sizes=\(toc.sizes) total=\(toc.totalSize) dataStart=\(reader.bitPosition / 8)\n".utf8))
        }
        try reader.ensureInBounds("TOC")

        return JXLFrameInfo(
            isModular: frameHeader.isModular,
            frameType: frameHeader.frameType,
            isLast: frameHeader.isLast,
            numGroups: dim.numGroups,
            numDCGroups: dim.numDCGroups,
            numPasses: Int(frameHeader.numPasses),
            tocEntryCount: entries,
            sectionSizes: toc.sizes,
            totalSectionBytes: toc.totalSize,
            dataStartByte: reader.bitPosition / 8,
            codestreamLength: parsed.codestream.count)
    }

    public static func readFrameInfo(from data: Data) throws -> JXLFrameInfo {
        try readFrameInfo(from: [UInt8](data))
    }

    public static func readFrameInfo(contentsOf url: URL) throws -> JXLFrameInfo {
        try readFrameInfo(from: try Data(contentsOf: url))
    }

    /// Convenience overload reading a file from disk.
    public static func readInfo(contentsOf url: URL) throws -> JXLImageInfo {
        try readInfo(from: try Data(contentsOf: url))
    }
}
