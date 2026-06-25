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

/// Logical role of a TOC section in the frame payload.
public enum JXLFrameSectionRole: Equatable {
    /// Single-group, single-pass frames coalesce DC-global, DC-group,
    /// AC-global, and AC-group payloads into section 0.
    case singleSectionCoalesced
    case dcGlobal
    case dcGroup(Int)
    case acGlobal
    case acGroup(pass: Int, group: Int)
}

/// Byte range for a TOC section in the frame payload.
public struct JXLFrameSectionInfo: Equatable {
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
public struct JXLFrameInfo {
    public let isModular: Bool
    public let frameType: FrameType
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

private func sectionRole(
    logicalIndex: Int, numGroups: Int, numDCGroups: Int, numPasses: Int
) -> JXLFrameSectionRole {
    if numGroups == 1 && numPasses == 1 {
        return .singleSectionCoalesced
    }

    if logicalIndex == 0 { return .dcGlobal }

    let acGlobalIndex = numDCGroups + 1
    if logicalIndex < acGlobalIndex {
        return .dcGroup(logicalIndex - 1)
    }
    if logicalIndex == acGlobalIndex { return .acGlobal }

    let acIndex = logicalIndex - acGlobalIndex - 1
    return .acGroup(pass: acIndex / numGroups, group: acIndex % numGroups)
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
        CustomTransformData.skip(reader, xybEncoded: metadata.xybEncoded)
        if metadata.colorEncoding.wantICC {
            // A compressed ICC profile would follow here; not yet supported.
            throw JXLError.unsupported("embedded ICC profile")
        }
        // The codestream headers are followed by byte alignment before the frames
        // (libjxl JxlDecoderReadAllHeaders -> JumpToByteBoundary).
        reader.alignToByte()

        let ctx = FrameContext(metadata: metadata, width: size.width, height: size.height)
        let frameHeader = FrameHeader(reader: reader, context: ctx)
        let dim = frameHeader.frameDimensions(ctx)
        let entries = numTocEntries(
            numGroups: dim.numGroups, numDCGroups: dim.numDCGroups,
            numPasses: Int(frameHeader.numPasses))

        guard let toc = readGroupOffsets(reader, tocEntries: entries) else {
            throw JXLError.malformed("could not read TOC")
        }
        try reader.ensureInBounds("TOC")

        let dataStartByte = reader.bitPosition / 8
        let sections = toc.offsets.enumerated().map { index, offset in
            let size = Int(toc.sizes[index])
            let start = dataStartByte + offset
            return JXLFrameSectionInfo(
                index: index,
                role: sectionRole(
                    logicalIndex: index, numGroups: dim.numGroups,
                    numDCGroups: dim.numDCGroups, numPasses: Int(frameHeader.numPasses)),
                offset: offset,
                size: size,
                codestreamRange: start..<(start + size))
        }

        return JXLFrameInfo(
            isModular: frameHeader.isModular,
            frameType: frameHeader.frameType,
            isLast: frameHeader.isLast,
            numGroups: dim.numGroups,
            numDCGroups: dim.numDCGroups,
            numPasses: Int(frameHeader.numPasses),
            tocEntryCount: entries,
            sectionSizes: toc.sizes,
            sections: sections,
            totalSectionBytes: toc.totalSize,
            dataStartByte: dataStartByte,
            codestreamLength: parsed.codestream.count)
    }

    public static func readFrameInfo(from data: Data) throws -> JXLFrameInfo {
        try readFrameInfo(from: [UInt8](data))
    }

    public static func readFrameInfo(contentsOf url: URL) throws -> JXLFrameInfo {
        try readFrameInfo(from: try Data(contentsOf: url))
    }

    /// Returns the raw bytes for one logical frame section. The section range is
    /// resolved against the bare codestream, so this works for both raw and
    /// container-wrapped `.jxl` inputs.
    public static func readFrameSectionData(from data: [UInt8], sectionIndex: Int) throws -> Data {
        let parsed = try JXLContainer.parse(data)
        let info = try readFrameInfo(from: data)
        guard sectionIndex >= 0 && sectionIndex < info.sections.count else {
            throw JXLError.malformed("frame section index out of range")
        }
        let range = info.sections[sectionIndex].codestreamRange
        guard range.lowerBound >= 0 && range.upperBound <= parsed.codestream.count else {
            throw JXLError.malformed("frame section range outside codestream")
        }
        return Data(parsed.codestream[range])
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
        BitReader([UInt8](try readFrameSectionData(from: data, sectionIndex: sectionIndex)))
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

    /// Convenience overload reading a file from disk.
    public static func readInfo(contentsOf url: URL) throws -> JXLImageInfo {
        try readInfo(from: try Data(contentsOf: url))
    }
}
