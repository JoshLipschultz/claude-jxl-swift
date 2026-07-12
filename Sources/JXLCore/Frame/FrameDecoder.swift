// FrameDecoder.swift
//
// Single-parse decoder state for one frame. The container, codestream headers,
// FrameHeader, and TOC are parsed exactly once at init; every decode stage
// (Modular pixels, or the VarDCT DC-global -> low-frequency -> AC-global ->
// coefficients chain) reads its TOC section from shared storage and caches its
// result, so no stage re-parses the file and no section bytes are copied.
//
// For a coalesced single-section frame all stages read sequentially from the
// shared section-0 reader, in bitstream order; the stage accessors enforce that
// order by forcing their predecessors. The public `JXL.*` entry points and the
// byte-taking VarDCT free functions are thin wrappers over this type.

import Foundation

/// Resource limits applied when decoding untrusted files. A malicious header
/// can claim enormous dimensions in a tiny file; pixel decoding refuses to
/// allocate past these bounds (`JXLError.limitExceeded`). Structural APIs
/// (`readInfo`, `readFrameInfo`) are not limited — they allocate O(1).
public struct JXLDecodeLimits: Equatable, Sendable {
    /// Maximum decoded samples (padded pixels x channels) across all planes.
    /// The default (2^30) admits a ~350-megapixel RGB image.
    public var maxTotalSamples: Int

    public init(maxTotalSamples: Int = 1 << 30) {
        self.maxTotalSamples = maxTotalSamples
    }

    public static let `default` = JXLDecodeLimits()
}

/// Logical role of a TOC section in the frame payload.
func sectionRole(
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

final class FrameDecoder {
    let parsed: ParsedFile
    let size: SizeHeader
    let metadata: JXLImageMetadata
    let frameHeader: FrameHeader
    let dim: FrameDimensions
    let tocOffsets: [Int]
    let tocSizes: [Int]
    let totalSectionBytes: Int
    /// Byte offset (within the codestream) where the first section's data begins.
    let dataStart: Int
    /// Single-group single-pass frames coalesce every payload into section 0.
    let coalesced: Bool
    let limits: JXLDecodeLimits

    var codestream: [UInt8] { parsed.codestream }

    // MARK: VarDCT staged results, decoded once in bitstream order.

    /// Section-0 reader. For a coalesced frame the VarDCT stages continue
    /// reading from it sequentially, so it is created once and shared.
    private(set) lazy var r0: BitReader = sectionReader(0)
    private var cachedDCGlobal: VarDCTDCGlobalDecoded?
    private var cachedDCDequant: DCDequant?
    private var cachedLowFrequency: VarDCTLowFrequency?
    private var cachedACGlobal: VarDCTACGlobal?
    private var cachedCoefficients: VarDCTCoefficients?

    init(data: [UInt8], limits: JXLDecodeLimits = .default) throws {
        self.limits = limits
        parsed = try JXLContainer.parse(data)
        guard parsed.codestream.count >= 2,
            parsed.codestream[0] == 0xFF, parsed.codestream[1] == 0x0A
        else { throw JXLError.invalidSignature }

        let reader = BitReader(parsed.codestream)
        reader.skip(16)
        size = SizeHeader(reader)
        metadata = JXLImageMetadata(reader)
        CustomTransformData.skip(reader, xybEncoded: metadata.xybEncoded)
        if metadata.colorEncoding.wantICC {
            // A compressed ICC profile would follow here; not yet supported.
            throw JXLError.unsupported("embedded ICC profile")
        }
        // The codestream headers are followed by byte alignment before the frames
        // (libjxl JxlDecoderReadAllHeaders -> JumpToByteBoundary).
        reader.alignToByte()

        let ctx = FrameContext(metadata: metadata, width: size.width, height: size.height)
        frameHeader = FrameHeader(reader: reader, context: ctx)
        dim = frameHeader.frameDimensions(ctx)
        coalesced = dim.numGroups == 1 && frameHeader.numPasses == 1

        let entries = numTocEntries(
            numGroups: dim.numGroups, numDCGroups: dim.numDCGroups,
            numPasses: Int(frameHeader.numPasses))
        guard let toc = readGroupOffsets(reader, tocEntries: entries) else {
            throw JXLError.malformed("could not read TOC")
        }
        try reader.ensureInBounds("TOC")
        tocOffsets = toc.offsets
        tocSizes = toc.sizes.map(Int.init)
        totalSectionBytes = toc.totalSize
        dataStart = reader.bitPosition / 8

        // Validate every section range against the codestream once, so section
        // readers never index out of bounds on a malformed TOC.
        for i in 0..<entries {
            let start = dataStart + tocOffsets[i]
            guard start >= 0, tocSizes[i] >= 0, start + tocSizes[i] <= parsed.codestream.count
            else { throw JXLError.malformed("TOC section \(i) outside codestream") }
        }
    }

    convenience init(data: Data, limits: JXLDecodeLimits = .default) throws {
        try self.init(data: [UInt8](data), limits: limits)
    }

    // MARK: Sections

    var sectionCount: Int { tocSizes.count }

    /// Byte range of logical section `i` within the codestream (bounds validated
    /// at init).
    func sectionRange(_ logicalIndex: Int) -> Range<Int> {
        let start = dataStart + tocOffsets[logicalIndex]
        return start..<(start + tocSizes[logicalIndex])
    }

    /// A fresh reader over logical section `i`, sharing codestream storage.
    func sectionReader(_ logicalIndex: Int) -> BitReader {
        BitReader(parsed.codestream, byteRange: sectionRange(logicalIndex))
    }

    /// Structural description of the frame (the `JXL.readFrameInfo` payload).
    func frameInfo() -> JXLFrameInfo {
        let sections = tocOffsets.indices.map { index in
            JXLFrameSectionInfo(
                index: index,
                role: sectionRole(
                    logicalIndex: index, numGroups: dim.numGroups,
                    numDCGroups: dim.numDCGroups, numPasses: Int(frameHeader.numPasses)),
                offset: tocOffsets[index],
                size: tocSizes[index],
                codestreamRange: sectionRange(index))
        }
        return JXLFrameInfo(
            isModular: frameHeader.isModular,
            frameType: frameHeader.frameType,
            flags: frameHeader.flags,
            isLast: frameHeader.isLast,
            numGroups: dim.numGroups,
            numDCGroups: dim.numDCGroups,
            numPasses: Int(frameHeader.numPasses),
            tocEntryCount: tocSizes.count,
            sectionSizes: tocSizes.map(UInt32.init),
            sections: sections,
            totalSectionBytes: totalSectionBytes,
            dataStartByte: dataStart,
            codestreamLength: parsed.codestream.count)
    }

    // MARK: Limits

    /// Refuses pixel decodes whose plane allocations would exceed `limits`.
    /// Checked against block-padded dimensions (VarDCT planes are padded).
    func checkPixelLimits(channels: Int) throws {
        let paddedW = divCeil(dim.xsize, 8) * 8
        let paddedH = divCeil(dim.ysize, 8) * 8
        let samples = UInt64(paddedW) * UInt64(paddedH) * UInt64(max(1, channels))
        if samples > UInt64(limits.maxTotalSamples) {
            throw JXLError.limitExceeded(
                "\(dim.xsize)x\(dim.ysize) x \(channels) channels")
        }
    }

    // MARK: Mode dispatch

    /// Decodes the frame to pixel planes: Modular frames in their native
    /// samples, VarDCT frames as three 8-bit sRGB planes.
    func decodeImage() throws -> JXLDecodedImage {
        if frameHeader.isModular {
            return try decodeModularImage()
        }
        let xyb = try reconstructXYB()
        return JXLDecodedImage(
            width: xyb.width, height: xyb.height, colorChannels: 3,
            extraChannels: 0, bitsPerSample: 8, isFloat: false,
            planes: xybToSRGB8Planes(xyb))
    }

    // MARK: Modular pixels

    /// Decodes a Modular (lossless) frame. Supports a single regular frame with
    /// RCT/Palette (or no) transforms; integer samples are returned as values,
    /// 32-bit float samples as their IEEE-754 bit patterns.
    func decodeModularImage() throws -> JXLDecodedImage {
        guard frameHeader.isModular else { throw JXLError.unsupported("VarDCT frame is not Modular") }
        guard frameHeader.frameType == .regular, frameHeader.flags == 0 else {
            throw JXLError.unsupported("non-regular or feature-flagged frames")
        }
        if metadata.bitDepth.isFloatingPoint && metadata.bitDepth.bitsPerSample != 32 {
            throw JXLError.unsupported("non-binary32 floating-point samples")
        }
        guard frameHeader.numPasses == 1 else {
            throw JXLError.unsupported("progressive (multi-pass) frames")
        }

        let isGray = metadata.colorSpace == .grayscale && frameHeader.colorTransform == .none
        let colorChannels = isGray ? 1 : 3
        let extra = metadata.extraChannelCount
        try checkPixelLimits(channels: colorChannels + extra)

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
            // Groups are independent: decode them concurrently into group-local
            // sub-images, then blit serially (the decode phase only reads the
            // full image's channel layout).
            let codestream = self.codestream
            let dim = self.dim
            let sectionRanges = (0..<dim.numGroups).map { g in
                sectionRange(acGroupIndex(
                    pass: 0, group: g, numGroups: dim.numGroups, numDCGroups: dim.numDCGroups))
            }
            typealias GroupResult = Result<ModularGroupResult?, Error>
            var results = [GroupResult?](repeating: nil, count: dim.numGroups)
            results.withUnsafeMutableBufferPointer { slots in
                // Each iteration writes only its own pre-allocated slot; the
                // full image is only read (channel layout) during this phase.
                nonisolated(unsafe) let out = slots
                nonisolated(unsafe) let full = fullImage
                let tree = globalTree
                let code = globalCode
                let ctxMap = globalCtxMap
                DispatchQueue.concurrentPerform(iterations: dim.numGroups) { g in
                    // ModularStreamId::ModularAC(g, pass 0).ID  (kNumQuantTables = 17)
                    let streamID = 1 + 3 * dim.numDCGroups + 17 + g
                    out[g] = GroupResult {
                        try decodeModularGroupImage(
                            BitReader(codestream, byteRange: sectionRanges[g]),
                            fullImage: full, group: g, dim: dim,
                            globalTree: tree, globalCode: code, globalCtxMap: ctxMap,
                            streamID: streamID)
                    }
                }
            }
            for result in results {
                if let groupResult = try result!.get() {
                    blitModularGroup(groupResult, into: fullImage)
                }
            }
        }

        try undoTransforms(fullImage, transforms: globalHeader.transforms)

        return JXLDecodedImage(
            width: dim.xsize, height: dim.ysize, colorChannels: colorChannels,
            extraChannels: extra, bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            isFloat: metadata.bitDepth.isFloatingPoint,
            planes: fullImage.channels.map { $0.pixels })
    }

    // MARK: VarDCT stages

    /// Guards shared by every VarDCT stage. Restrictions match the current
    /// pipeline: single pass, 4:4:4, no patches/splines/noise.
    func requireSupportedVarDCT() throws {
        guard !frameHeader.isModular else { throw JXLError.unsupported("Modular frame is not VarDCT") }
        guard frameHeader.frameType == .regular else {
            throw JXLError.unsupported("non-regular VarDCT frame")
        }
        guard frameHeader.numPasses == 1 else {
            throw JXLError.unsupported("progressive (multi-pass) VarDCT frames")
        }
        guard frameHeader.chromaChannelMode == [0, 0, 0] else {
            throw JXLError.unsupported("chroma-subsampled VarDCT frames")
        }
        // No patches/splines/noise: those precede DequantMatrices.DecodeDC and
        // are not yet parsed.
        guard frameHeader.flags == 0 else {
            throw JXLError.unsupported("VarDCT frame features (patches/splines/noise)")
        }
    }

    /// Stage 1 — `ProcessDCGlobal` (section 0 prefix): quantizer, block context
    /// map, DC color correlation, and the global modular tree/code.
    func varDCTDCGlobal() throws -> VarDCTDCGlobalDecoded {
        if let cached = cachedDCGlobal { return cached }
        try requireSupportedVarDCT()
        let dcGlobal = try readVarDCTDCGlobal(r0)
        cachedDCGlobal = dcGlobal
        cachedDCDequant = computeDCDequant(dcGlobal.info)
        return dcGlobal
    }

    func varDCTDCDequant() throws -> DCDequant {
        _ = try varDCTDCGlobal()
        return cachedDCDequant!
    }

    /// Stage 2 — the low-frequency layer: each DC group's `VarDCTDC` stream
    /// (dequantized into the XYB DC planes) and its `AcMetadata`, decoded in one
    /// pass per group. See `decodeVarDCTLowFrequency` (DCImage.swift).
    func varDCTLowFrequency() throws -> VarDCTLowFrequency {
        if let cached = cachedLowFrequency { return cached }
        try checkPixelLimits(channels: 3)
        let lf = try decodeVarDCTLowFrequency(self)
        cachedLowFrequency = lf
        return lf
    }

    /// Stage 3 — `ProcessACGlobal` (HfGlobal): coefficient orders + AC
    /// histograms. Continues in section 0 for a coalesced frame.
    func varDCTACGlobal() throws -> VarDCTACGlobal {
        if let cached = cachedACGlobal { return cached }
        let lf = try varDCTLowFrequency()
        let reader = coalesced ? r0 : sectionReader(dim.numDCGroups + 1)
        let acGlobal = try decodeVarDCTACGlobal(
            reader, dim: dim, numPasses: Int(frameHeader.numPasses),
            blockContextMap: try varDCTDCGlobal().info.blockContextMap,
            usedACs: lf.metadata.usedACs)
        cachedACGlobal = acGlobal
        return acGlobal
    }

    /// Stage 4 — per-group AC coefficient entropy decode. See
    /// `decodeVarDCTCoefficients(_:)` (PassGroup.swift).
    func varDCTCoefficients() throws -> VarDCTCoefficients {
        if let cached = cachedCoefficients { return cached }
        let coeffs = try decodeVarDCTCoefficients(self)
        cachedCoefficients = coeffs
        return coeffs
    }

    /// The reader for DC group `dcg`: the shared section-0 reader for a
    /// coalesced frame, else the DC group's own section.
    func dcGroupReader(_ dcg: Int) -> BitReader {
        coalesced ? r0 : sectionReader(1 + dcg)
    }

    /// The reader for AC group `g` (pass 0).
    func acGroupReader(_ g: Int) -> BitReader {
        if coalesced { return r0 }
        let section = acGroupIndex(
            pass: 0, group: g, numGroups: dim.numGroups, numDCGroups: dim.numDCGroups)
        return sectionReader(section)
    }

    /// DC group `dcg`'s rect in block units.
    func dcGroupRect(_ dcg: Int) -> (x0: Int, y0: Int, w: Int, h: Int) {
        let gx = dcg % dim.xsizeDCGroups
        let gy = dcg / dim.xsizeDCGroups
        let x0 = gx * dim.groupDim
        let y0 = gy * dim.groupDim
        return (x0, y0, min(dim.groupDim, dim.xsizeBlocks - x0),
            min(dim.groupDim, dim.ysizeBlocks - y0))
    }
}
