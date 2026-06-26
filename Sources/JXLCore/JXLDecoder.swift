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

/// A decoded raster image: one Int32 plane per channel (color channels first,
/// then extra channels such as alpha), each `width * height` row-major.
public struct JXLDecodedImage {
    public let width: Int
    public let height: Int
    public let colorChannels: Int  // 1 (grayscale) or 3 (RGB)
    public let extraChannels: Int
    public let bitsPerSample: Int
    /// When true, each Int32 sample is the IEEE-754 binary32 bit pattern of the
    /// pixel value (read via `Float(bitPattern: UInt32(bitPattern: sample))`).
    public let isFloat: Bool
    public let planes: [[Int32]]
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
            flags: frameHeader.flags,
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

    /// Decodes a JPEG XL image to pixel planes. Currently supports the lossless
    /// Modular subset: a single regular frame, one group, integer samples, and
    /// only RCT (or no) transforms. Throws `.unsupported` otherwise.
    public static func decodeImage(from data: [UInt8]) throws -> JXLDecodedImage {
        let parsed = try JXLContainer.parse(data)
        guard parsed.codestream.count >= 2,
            parsed.codestream[0] == 0xFF, parsed.codestream[1] == 0x0A
        else { throw JXLError.invalidSignature }

        let reader = BitReader(parsed.codestream)
        reader.skip(16)
        let size = SizeHeader(reader)
        let metadata = JXLImageMetadata(reader)
        CustomTransformData.skip(reader, xybEncoded: metadata.xybEncoded)
        if metadata.colorEncoding.wantICC { throw JXLError.unsupported("embedded ICC profile") }
        reader.alignToByte()

        let ctx = FrameContext(metadata: metadata, width: size.width, height: size.height)
        let frameHeader = FrameHeader(reader: reader, context: ctx)
        guard frameHeader.isModular else { throw JXLError.unsupported("VarDCT (lossy) frames") }
        guard frameHeader.frameType == .regular, frameHeader.flags == 0 else {
            throw JXLError.unsupported("non-regular or feature-flagged frames")
        }
        if metadata.bitDepth.isFloatingPoint { throw JXLError.unsupported("floating-point samples") }

        guard frameHeader.numPasses == 1 else {
            throw JXLError.unsupported("progressive (multi-pass) frames")
        }
        let dim = frameHeader.frameDimensions(ctx)

        let entries = numTocEntries(
            numGroups: dim.numGroups, numDCGroups: dim.numDCGroups, numPasses: Int(frameHeader.numPasses))
        guard let toc = readGroupOffsets(reader, tocEntries: entries) else {
            throw JXLError.malformed("could not read TOC")
        }
        let dataStart = reader.bitPosition / 8
        let cs = parsed.codestream
        func sectionReader(_ logicalIndex: Int) -> BitReader {
            let start = dataStart + toc.offsets[logicalIndex]
            return BitReader(Array(cs[start..<(start + Int(toc.sizes[logicalIndex]))]))
        }

        // Global modular (section 0 = LfGlobal): DequantMatrices.DecodeDC, then
        // has_tree / the global MA tree + code, then the global modular stream.
        let r0 = sectionReader(0)
        if r0.read(1) == 0 {
            for _ in 0..<3 { _ = r0.readF16() }
        }
        var globalTree: [MATreeNode]? = nil
        var globalCode: ANSCode? = nil
        var globalCtxMap: [UInt8]? = nil
        if r0.read(1) == 1 {  // has_tree
            guard let tree = decodeMATree(r0, treeSizeLimit: 1 << 22),
                let (code, ctxMap) = decodeHistograms(
                    r0, numContexts: (tree.count + 1) / 2, disallowLZ77: false)
            else { throw JXLError.malformed("could not read global modular tree") }
            globalTree = tree
            globalCode = code
            globalCtxMap = ctxMap
        }

        let isGray = metadata.colorSpace == .grayscale && frameHeader.colorTransform == .none
        let colorChannels = isGray ? 1 : 3
        let extra = metadata.extraChannelCount
        let fullImage = ModularImage(
            w: dim.xsize, h: dim.ysize, bitdepth: Int(metadata.bitDepth.bitsPerSample),
            channelCount: colorChannels + extra)

        // For a single group the global stream carries every channel; otherwise
        // large channels are decoded per AC group.
        let maxChan = dim.numGroups == 1 ? Int.max : dim.groupDim
        let globalHeader = try modularDecode(
            r0, image: fullImage, groupID: 0, globalTree: globalTree, globalCode: globalCode,
            globalCtxMap: globalCtxMap, maxChanSize: maxChan)

        if dim.numGroups > 1 {
            for g in 0..<dim.numGroups {
                let section = acGroupIndex(
                    pass: 0, group: g, numGroups: dim.numGroups, numDCGroups: dim.numDCGroups)
                // ModularStreamId::ModularAC(g, pass 0).ID  (kNumQuantTables = 17)
                let streamID = 1 + 3 * dim.numDCGroups + 17 + g
                try decodeModularGroup(
                    sectionReader(section), fullImage: fullImage, group: g, dim: dim,
                    globalTree: globalTree, globalCode: globalCode, globalCtxMap: globalCtxMap,
                    streamID: streamID)
            }
        }

        try undoTransforms(fullImage, transforms: globalHeader.transforms)

        return JXLDecodedImage(
            width: dim.xsize, height: dim.ysize, colorChannels: colorChannels,
            extraChannels: extra, bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            planes: fullImage.channels.map { $0.pixels })
    }

    public static func decodeImage(from data: Data) throws -> JXLDecodedImage {
        try decodeImage(from: [UInt8](data))
    }

    public static func decodeImage(contentsOf url: URL) throws -> JXLDecodedImage {
        try decodeImage(from: try Data(contentsOf: url))
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
