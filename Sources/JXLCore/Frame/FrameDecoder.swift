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

/// One parsed frame: header + TOC layout. The presented (displayed) frame's
/// slot doubles as the FrameDecoder's own state; frames preceding it in the
/// codestream (patch reference frames) keep their own slots.
struct FrameSlot {
    let header: FrameHeader
    let dim: FrameDimensions
    let tocOffsets: [Int]
    let tocSizes: [Int]
    let totalSectionBytes: Int
    /// Byte offset (within the codestream) where the first section's data begins.
    let dataStart: Int

    var coalesced: Bool { dim.numGroups == 1 && header.numPasses == 1 }

    func sectionRange(_ logicalIndex: Int) -> Range<Int> {
        let start = dataStart + tocOffsets[logicalIndex]
        return start..<(start + tocSizes[logicalIndex])
    }
}

final class FrameDecoder {
    let parsed: ParsedFile
    let size: SizeHeader
    let metadata: JXLImageMetadata
    /// The presented frame (first regular frame), preceded by `referenceSlots`.
    let slot: FrameSlot
    /// Frames stored for later reference (`frameType == .referenceOnly`), in
    /// codestream order. Decoded lazily when the patch dictionary needs them.
    let referenceSlots: [FrameSlot]
    let limits: JXLDecodeLimits
    /// Decoded embedded ICC profile bytes (present when `want_icc` is set).
    let iccProfile: [UInt8]?
    /// Custom upsampling kernels from CustomTransformData (defaults otherwise).
    let upsamplingWeights: UpsamplingCustomWeights
    /// Custom XYB inverse-opsin matrix/biases (nil = spec defaults).
    let customOpsin: JXLOpsinInverseMatrix?
    /// The original file bytes (container box payload ranges index into this).
    let fileData: [UInt8]

    var frameHeader: FrameHeader { slot.header }
    var dim: FrameDimensions { slot.dim }
    var tocOffsets: [Int] { slot.tocOffsets }
    var tocSizes: [Int] { slot.tocSizes }
    var totalSectionBytes: Int { slot.totalSectionBytes }
    /// Byte offset (within the codestream) where the first section's data begins.
    var dataStart: Int { slot.dataStart }
    /// Single-group single-pass frames coalesce every payload into section 0.
    var coalesced: Bool { slot.coalesced }

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
    /// Set by the compositing path (`decodeFrames`) so the per-frame pixel
    /// decode proceeds even when the frame blends onto a canvas.
    var allowBlendingDecode = false

    /// `skipPresentedFrames` selects a later animation frame: that many
    /// presentable frames are skipped (reference-only frames are recorded as
    /// usual along the way) and the next one becomes this decoder's frame.
    init(data: [UInt8], limits: JXLDecodeLimits = .default, skipPresentedFrames: Int = 0) throws {
        self.limits = limits
        fileData = data
        parsed = try JXLContainer.parse(data)
        guard parsed.codestream.count >= 2,
            parsed.codestream[0] == 0xFF, parsed.codestream[1] == 0x0A
        else { throw JXLError.invalidSignature }

        let reader = BitReader(parsed.codestream)
        reader.skip(16)
        size = SizeHeader(reader)
        metadata = JXLImageMetadata(reader)
        let transformData = CustomTransformData.parse(reader, xybEncoded: metadata.xybEncoded)
        upsamplingWeights = transformData.weights
        customOpsin = transformData.opsin
        if metadata.colorEncoding.wantICC {
            // A compressed ICC profile follows the transform data.
            iccProfile = try readICCProfile(reader)
        } else {
            iccProfile = nil
        }
        // The codestream headers are followed by byte alignment before the frames
        // (libjxl JxlDecoderReadAllHeaders -> JumpToByteBoundary).
        reader.alignToByte()

        let ctx = FrameContext(metadata: metadata, width: size.width, height: size.height)

        // Walk the frame sequence: reference-only frames (patch dictionaries
        // draw from them) are recorded and skipped; the first frame of any
        // other type is the presented one.
        var preceding: [FrameSlot] = []
        var toSkip = skipPresentedFrames
        var current = try FrameDecoder.parseFrameSlot(
            reader, context: ctx, codestreamCount: parsed.codestream.count)
        while true {
            if current.header.frameType == .referenceOnly {
                preceding.append(current)
                guard preceding.count <= 8 else {
                    throw JXLError.malformed("too many reference frames")
                }
            } else if toSkip > 0 {
                guard !current.header.isLast else {
                    throw JXLError.malformed("frame index past the last frame")
                }
                toSkip -= 1
            } else {
                break
            }
            // The TOC leaves the reader at the frame's data start; the next
            // frame header begins right after its sections, byte-aligned.
            reader.skip(current.totalSectionBytes * 8)
            current = try FrameDecoder.parseFrameSlot(
                reader, context: ctx, codestreamCount: parsed.codestream.count)
        }
        slot = current
        referenceSlots = preceding
    }

    /// Parses one frame header + TOC from `reader` and validates every section
    /// range against the codestream, so section readers never index out of
    /// bounds on a malformed TOC.
    private static func parseFrameSlot(
        _ reader: BitReader, context ctx: FrameContext, codestreamCount: Int
    ) throws -> FrameSlot {
        let header = FrameHeader(reader: reader, context: ctx)
        let dim = header.frameDimensions(ctx)

        let entries = numTocEntries(
            numGroups: dim.numGroups, numDCGroups: dim.numDCGroups,
            numPasses: Int(header.numPasses))
        guard let toc = readGroupOffsets(reader, tocEntries: entries) else {
            throw JXLError.malformed("could not read TOC")
        }
        try reader.ensureInBounds("TOC")
        let dataStart = reader.bitPosition / 8

        for i in 0..<entries {
            let start = dataStart + toc.offsets[i]
            guard start >= 0, toc.sizes[i] >= 0, start + Int(toc.sizes[i]) <= codestreamCount
            else { throw JXLError.malformed("TOC section \(i) outside codestream") }
        }
        return FrameSlot(
            header: header, dim: dim, tocOffsets: toc.offsets,
            tocSizes: toc.sizes.map(Int.init), totalSectionBytes: toc.totalSize,
            dataStart: dataStart)
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
    /// samples, VarDCT frames rendered to `format` (8-bit is the default; 16
    /// bits or transfer-encoded float preserve HDR precision).
    func decodeImage(format: JXLSampleFormat = .uint8) throws -> JXLDecodedImage {
        if frameHeader.isModular {
            return try decodeModularImage(format: format)
        }
        var xyb = try reconstructXYB()
        // Patches blend in after the restoration filters, before the color
        // transform (libjxl render pipeline order), in the frame's XYB space.
        if let patches = patchDictionary, !patches.isEmpty {
            try renderPatches(patches, into: &xyb) { try self.referenceXYBFrame($0) }
        }
        // Upsampling (2x/4x/8x) follows patches and precedes the color
        // transform (libjxl render pipeline order).
        if frameHeader.upsampling > 1 {
            xyb = try upsampleXYB(xyb)
        }
        // Extra channels ride the frame's modular sub-streams (8-bit native);
        // they are rescaled to match wider color formats.
        let ecPlanes = try finalizeExtraChannels().map { scaleECPlane($0, to: format) }
        if frameHeader.colorTransform == .ycbcr {
            // JPEG transcode: the YCbCr planes are inherently 8-bit and
            // convert to the file's *native* encoded RGB (no color management
            // applied), so the embedded profile — when present — describes
            // the returned samples.
            guard format == .uint8 else {
                throw JXLError.unsupported("wide output for YCbCr (JPEG transcode) frames")
            }
            return JXLDecodedImage(
                width: xyb.width, height: xyb.height, colorChannels: 3,
                extraChannels: ecPlanes.count, bitsPerSample: 8, isFloat: false,
                planes: ycbcrToRGB8Planes(xyb) + ecPlanes,
                iccProfile: iccProfile.map { Data($0) })
        }
        // XYB: converted to the frame's declared numeric encoding (primaries/
        // white point/transfer, incl. PQ/HLG); files whose encoding is an ICC
        // profile fall back to sRGB output, so the profile (which describes
        // the original space) is deliberately not attached.
        let spec = try makeOutputColorSpec(
            metadata.colorEncoding, toneMapping: metadata.toneMapping, customOpsin: customOpsin)
        let colorPlanes: [[Int32]]
        let bits: Int
        let isFloat: Bool
        switch format {
        case .uint8:
            colorPlanes = xybToRGB8Planes(xyb, spec: spec)
            bits = 8
            isFloat = false
        case .uint16:
            colorPlanes = xybToRGB16Planes(xyb, spec: spec)
            bits = 16
            isFloat = false
        case .float32:
            colorPlanes = xybToRGBFloatPlanes(xyb, spec: spec)
            bits = 32
            isFloat = true
        }
        return JXLDecodedImage(
            width: xyb.width, height: xyb.height, colorChannels: 3,
            extraChannels: ecPlanes.count, bitsPerSample: bits, isFloat: isFloat,
            planes: colorPlanes + ecPlanes, iccProfile: nil)
    }

    /// Decodes this frame's own pixels as float planes in the output encoded
    /// space (3 color planes — grayscale replicated — plus normalized extra
    /// channels), sized to the frame's crop. This is the compositing currency:
    /// frame blending runs after the color transform on encoded samples.
    func decodeFrameFloat() throws -> FloatFrame {
        allowBlendingDecode = true
        let extra = metadata.extraChannelCount

        if frameHeader.isModular {
            if frameHeader.colorTransform == .xyb {
                let img = try decodeModularImage(format: .float32)
                let planes = img.planes.map { plane in
                    plane.map { Float(bitPattern: UInt32(bitPattern: $0)) }
                }
                return FloatFrame(width: img.width, height: img.height, planes: planes)
            }
            // Native modular: normalize integers by each channel's bit depth
            // (color by the image depth, extras by their own).
            let img = try decodeModularImage()
            guard !img.isFloat else {
                throw JXLError.unsupported("float Modular frames in composited animations")
            }
            let colorMax = Float((1 << img.bitsPerSample) - 1)
            var planes: [[Float]] = []
            for c in 0..<img.colorChannels {
                planes.append(img.planes[c].map { Float($0) / colorMax })
            }
            while planes.count < 3 { planes.append(planes[0]) }  // grayscale
            for e in 0..<extra {
                let bits = Int(metadata.extraChannels[e].bitDepth.bitsPerSample)
                let ecMax = Float((1 << bits) - 1)
                planes.append(img.planes[img.colorChannels + e].map { Float($0) / ecMax })
            }
            return FloatFrame(width: img.width, height: img.height, planes: planes)
        }

        guard frameHeader.colorTransform == .xyb else {
            throw JXLError.unsupported("composited YCbCr frames")
        }
        var xyb = try reconstructXYB()
        if let patches = patchDictionary, !patches.isEmpty {
            try renderPatches(patches, into: &xyb) { try self.referenceXYBFrame($0) }
        }
        if frameHeader.upsampling > 1 {
            xyb = try upsampleXYB(xyb)
        }
        let spec = try makeOutputColorSpec(
            metadata.colorEncoding, toneMapping: metadata.toneMapping, customOpsin: customOpsin)
        var planes = xybToRGBFloatPlanes(xyb, spec: spec).map { plane in
            plane.map { Float(bitPattern: UInt32(bitPattern: $0)) }
        }
        for plane in try finalizeExtraChannels() {
            planes.append(plane.map { Float($0) / 255 })
        }
        return FloatFrame(width: xyb.width, height: xyb.height, planes: planes)
    }

    /// Rescales an 8-bit extra-channel plane to the requested color format so
    /// every plane of the result shares one sample representation.
    private func scaleECPlane(_ plane: [Int32], to format: JXLSampleFormat) -> [Int32] {
        switch format {
        case .uint8:
            return plane
        case .uint16:
            return plane.map { $0 * 257 }  // 0...255 -> 0...65535
        case .float32:
            return plane.map { Int32(bitPattern: (Float($0) / 255).bitPattern) }
        }
    }

    /// A fast 1/8-scale preview: for VarDCT frames, the dequantized DC image
    /// converted through the same output path as the full decode. Available
    /// after only the low-frequency pass — a small fraction of full decode
    /// time — so callers can put pixels on screen immediately and swap in the
    /// full image when it lands. Returns `nil` for Modular frames, which have
    /// no cheap intermediate.
    func decodePreviewImage() throws -> JXLDecodedImage? {
        guard !frameHeader.isModular else { return nil }
        let lf = try varDCTLowFrequency()
        let dc = lf.dc
        let bw = dc.widthBlocks
        let bh = dc.heightBlocks
        let pw = divCeil(dim.xsize, 8)
        let ph = divCeil(dim.ysize, 8)

        if frameHeader.colorTransform == .ycbcr {
            // Chroma DC lives packed at subsampled resolution; expand nearest.
            let shifts = channelShifts
            func expand(_ p: [Float], _ h: Int, _ v: Int) -> [Float] {
                if h == 0 && v == 0 { return p }
                var out = [Float](repeating: 0, count: bw * bh)
                for y in 0..<bh {
                    let src = (y >> v) * bw
                    let dst = y * bw
                    for x in 0..<bw { out[dst + x] = p[src + (x >> h)] }
                }
                return out
            }
            let img = XYBImage(
                width: pw, height: ph, stride: bw, paddedHeight: bh,
                x: expand(dc.x, shifts.h[0], shifts.v[0]), y: dc.y,
                b: expand(dc.b, shifts.h[2], shifts.v[2]))
            return JXLDecodedImage(
                width: pw, height: ph, colorChannels: 3, extraChannels: 0,
                bitsPerSample: 8, isFloat: false, planes: ycbcrToRGB8Planes(img),
                iccProfile: iccProfile.map { Data($0) })
        }

        let spec = try makeOutputColorSpec(
            metadata.colorEncoding, toneMapping: metadata.toneMapping, customOpsin: customOpsin)
        let img = XYBImage(
            width: pw, height: ph, stride: bw, paddedHeight: bh, x: dc.x, y: dc.y, b: dc.b)
        return JXLDecodedImage(
            width: pw, height: ph, colorChannels: 3, extraChannels: 0,
            bitsPerSample: 8, isFloat: false, planes: xybToRGB8Planes(img, spec: spec),
            iccProfile: nil)
    }

    private var channelShifts: (h: [Int], v: [Int]) { frameHeader.channelShifts }

    /// Upsamples the reconstructed planes by the frame's upsampling factor and
    /// crops to the image dimensions.
    private func upsampleXYB(_ xyb: XYBImage) throws -> XYBImage {
        let shift = Int(frameHeader.upsampling).trailingZeroBitCount  // 2→1, 4→2, 8→3
        let weights: [Float]
        switch shift {
        case 1: weights = upsamplingWeights.up2 ?? kUpsampling2Weights
        case 2: weights = upsamplingWeights.up4 ?? kUpsampling4Weights
        default: weights = upsamplingWeights.up8 ?? kUpsampling8Weights
        }
        let n = 1 << shift
        let w = dim.xsize
        let h = dim.ysize
        let samples = UInt64(w * n) * UInt64(h * n) * 3
        if samples > UInt64(limits.maxTotalSamples) {
            throw JXLError.limitExceeded("upsampled \(w * n)x\(h * n)")
        }
        let ux = upsamplePlane(xyb.x, w: w, h: h, stride: xyb.stride, shift: shift, weights: weights)
        let uy = upsamplePlane(xyb.y, w: w, h: h, stride: xyb.stride, shift: shift, weights: weights)
        let ub = upsamplePlane(xyb.b, w: w, h: h, stride: xyb.stride, shift: shift, weights: weights)
        return XYBImage(
            width: min(w * n, Int(size.width)), height: min(h * n, Int(size.height)),
            stride: w * n, paddedHeight: h * n, x: ux, y: uy, b: ub)
    }

    // MARK: Modular pixels

    /// Decodes a Modular (lossless) frame. Native-space frames return their
    /// native samples regardless of `format` (integers as values, 32-bit float
    /// as IEEE-754 bit patterns); Modular-XYB (lossy modular) frames render
    /// through the color pipeline at the requested format.
    func decodeModularImage(format: JXLSampleFormat = .uint8) throws -> JXLDecodedImage {
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
        guard frameHeader.upsampling == 1 else {
            throw JXLError.unsupported("upsampled Modular frames")
        }
        guard !frameHeader.needsBlending || allowBlendingDecode else {
            throw JXLError.unsupported(
                "frame blending other than full-frame replace (use decodeFrames)")
        }

        let isGray = metadata.colorSpace == .grayscale && frameHeader.colorTransform == .none
        let colorChannels = isGray ? 1 : 3
        let extra = metadata.extraChannelCount
        try checkPixelLimits(channels: colorChannels + extra)

        let (fullImage, dcQuant) = try decodeModularChannels(
            in: slot, channelCount: colorChannels + extra)

        if frameHeader.colorTransform == .xyb {
            // Modular-XYB (lossy modular / squeeze): channels arrive as Y, X,
            // B−Y scaled by the DC-quant factors (dec_modular kXYB
            // finalization); convert through the shared XYB output path.
            let w = dim.xsize
            let h = dim.ysize
            guard fullImage.channels.count >= 3,
                fullImage.channels[0].pixels.count >= w * h,
                fullImage.channels[1].pixels.count >= w * h,
                fullImage.channels[2].pixels.count >= w * h
            else { throw JXLError.malformed("Modular XYB channel layout") }
            var x = [Float](repeating: 0, count: w * h)
            var y = [Float](repeating: 0, count: w * h)
            var b = [Float](repeating: 0, count: w * h)
            let cY = fullImage.channels[0].pixels
            let cX = fullImage.channels[1].pixels
            let cB = fullImage.channels[2].pixels
            for i in 0..<(w * h) {
                x[i] = Float(cX[i]) * dcQuant[0]
                y[i] = Float(cY[i]) * dcQuant[1]
                b[i] = Float(cB[i] &+ cY[i]) * dcQuant[2]
            }
            let xyb = XYBImage(width: w, height: h, stride: w, paddedHeight: h, x: x, y: y, b: b)
            let spec = try makeOutputColorSpec(
                metadata.colorEncoding, toneMapping: metadata.toneMapping, customOpsin: customOpsin)
            let ecPlanes = fullImage.channels.dropFirst(3).map {
                scaleECPlane($0.pixels, to: format)
            }
            let colorPlanes: [[Int32]]
            let bits: Int
            let isFloat: Bool
            switch format {
            case .uint8:
                colorPlanes = xybToRGB8Planes(xyb, spec: spec)
                bits = 8
                isFloat = false
            case .uint16:
                colorPlanes = xybToRGB16Planes(xyb, spec: spec)
                bits = 16
                isFloat = false
            case .float32:
                colorPlanes = xybToRGBFloatPlanes(xyb, spec: spec)
                bits = 32
                isFloat = true
            }
            return JXLDecodedImage(
                width: w, height: h, colorChannels: 3,
                extraChannels: ecPlanes.count, bitsPerSample: bits, isFloat: isFloat,
                planes: colorPlanes + ecPlanes, iccProfile: nil)
        }

        // Modular samples are native (no color transform applied here), so the
        // embedded profile — when present — describes them directly.
        return JXLDecodedImage(
            width: dim.xsize, height: dim.ysize, colorChannels: colorChannels,
            extraChannels: extra, bitsPerSample: Int(metadata.bitDepth.bitsPerSample),
            isFloat: metadata.bitDepth.isFloatingPoint,
            planes: fullImage.channels.map { $0.pixels },
            iccProfile: iccProfile.map { Data($0) })
    }

    /// The core Modular pipeline for one frame slot: global tree + global
    /// stream, then the per-group streams, then inverse transforms. Returns the
    /// decoded channels and the DC-quant factors read from the slot's global
    /// section (they double as the XYB multipliers of Modular-XYB frames).
    private func decodeModularChannels(
        in slot: FrameSlot, channelCount: Int
    ) throws -> (image: ModularImage, dcQuant: [Float]) {
        let dim = slot.dim

        // Global modular (section 0 = LfGlobal): DequantMatrices.DecodeDC, then
        // has_tree / the global MA tree + code, then the global modular stream.
        let r0 = BitReader(parsed.codestream, byteRange: slot.sectionRange(0))
        var dcQuant: [Float] = [1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0]
        if r0.read(1) == 0 {
            for c in 0..<3 { dcQuant[c] = r0.readF16() * (1.0 / 128.0) }
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
            channelCount: channelCount)

        // For a single group the global stream carries every channel; otherwise
        // large channels are decoded per AC group.
        let maxChan = dim.numGroups == 1 ? Int.max : dim.groupDim
        let globalHeader = try modularDecode(
            r0, image: fullImage, groupID: 0, globalTree: globalTree, globalCode: globalCode,
            globalCtxMap: globalCtxMap, maxChanSize: maxChan)

        if dim.numGroups > 1 {
            // DC-group sections carry the channels whose squeeze shift is >= 3
            // (libjxl ModularStreamId::ModularDC, shift bracket [3, 1000]).
            // Nothing is read from them when no such channel exists.
            for dcg in 0..<dim.numDCGroups {
                if let dcResult = try decodeModularGroupImage(
                    BitReader(parsed.codestream, byteRange: slot.sectionRange(1 + dcg)),
                    fullImage: fullImage, group: dcg, dim: dim,
                    globalTree: globalTree, globalCode: globalCode, globalCtxMap: globalCtxMap,
                    streamID: 1 + dim.numDCGroups + dcg,
                    minShift: 3, maxShift: 1000, dcGroup: true) {
                    blitModularGroup(dcResult, into: fullImage)
                }
            }
            // Groups are independent: decode them concurrently into group-local
            // sub-images, then blit serially (the decode phase only reads the
            // full image's channel layout).
            let codestream = self.codestream
            let sectionRanges = (0..<dim.numGroups).map { g in
                slot.sectionRange(acGroupIndex(
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
        return (fullImage, dcQuant)
    }

    // MARK: Reference frames (patch sources)

    private var cachedReferences: [Int: ReferenceXYBFrame] = [:]

    /// Dimensions of the reference frame stored in `index` (0-3), or nil when
    /// no preceding frame fills that slot. Used to validate the patch
    /// dictionary before any reference pixels are decoded.
    func referenceFrameSize(_ index: Int) -> (width: Int, height: Int)? {
        guard let frame = latestReferenceSlot(index) else { return nil }
        return (frame.dim.xsize, frame.dim.ysize)
    }

    private func latestReferenceSlot(_ index: Int) -> FrameSlot? {
        referenceSlots.last {
            $0.header.frameType == .referenceOnly && Int($0.header.saveAsReference) == index
        }
    }

    /// Decodes (and caches) the reference frame in slot `index` as XYB float
    /// planes. Patch reference frames are Modular-encoded XYB images stored
    /// before the color transform: channels arrive as Y, X, (B−Y) and scale by
    /// the frame's DC-quant factors (libjxl dec_modular `kXYB` finalization).
    func referenceXYBFrame(_ index: Int) throws -> ReferenceXYBFrame {
        if let cached = cachedReferences[index] { return cached }
        guard let frame = latestReferenceSlot(index) else {
            throw JXLError.malformed("patch reference frame \(index) not present")
        }
        let h = frame.header
        guard h.saveBeforeColorTransform else {
            throw JXLError.malformed("patches cannot use frames saved post color transform")
        }
        guard h.isModular, h.colorTransform == .xyb else {
            throw JXLError.unsupported("non-Modular-XYB patch reference frame")
        }
        guard h.flags == 0, h.numPasses == 1 else {
            throw JXLError.unsupported("feature-flagged patch reference frame")
        }
        let w = frame.dim.xsize
        let ht = frame.dim.ysize
        let samples = UInt64(w) * UInt64(ht) * UInt64(3 + metadata.extraChannelCount)
        if samples > UInt64(limits.maxTotalSamples) {
            throw JXLError.limitExceeded("reference frame \(w)x\(ht)")
        }

        let (image, dcQuant) = try decodeModularChannels(
            in: frame, channelCount: 3 + metadata.extraChannelCount)
        guard image.channels.count >= 3,
            image.channels[0].pixels.count >= w * ht,
            image.channels[1].pixels.count >= w * ht,
            image.channels[2].pixels.count >= w * ht
        else { throw JXLError.malformed("reference frame channel layout") }

        var x = [Float](repeating: 0, count: w * ht)
        var y = [Float](repeating: 0, count: w * ht)
        var b = [Float](repeating: 0, count: w * ht)
        let cY = image.channels[0].pixels
        let cX = image.channels[1].pixels
        let cB = image.channels[2].pixels
        for i in 0..<(w * ht) {
            x[i] = Float(cX[i]) * dcQuant[0]
            y[i] = Float(cY[i]) * dcQuant[1]
            b[i] = Float(cB[i] &+ cY[i]) * dcQuant[2]
        }
        let ref = ReferenceXYBFrame(width: w, height: ht, x: x, y: y, b: b)
        cachedReferences[index] = ref
        return ref
    }

    // MARK: VarDCT stages

    /// Guards shared by every VarDCT stage. Restrictions match the current
    /// pipeline: single pass, no patches/splines/noise. Chroma subsampling is
    /// supported for YCbCr frames (JPEG transcodes) without restoration filters.
    func requireSupportedVarDCT() throws {
        guard !frameHeader.isModular else { throw JXLError.unsupported("Modular frame is not VarDCT") }
        guard frameHeader.frameType == .regular else {
            throw JXLError.unsupported("non-regular VarDCT frame")
        }
        guard frameHeader.numPasses == 1 else {
            throw JXLError.unsupported("progressive (multi-pass) VarDCT frames")
        }
        guard !frameHeader.needsBlending || allowBlendingDecode else {
            throw JXLError.unsupported(
                "frame blending other than full-frame replace (use decodeFrames)")
        }
        if !frameHeader.chromaIs444 {
            // Subsampled reconstruction is implemented for the JPEG-transcode
            // shape: no Gaborish/EPF (their windows assume full-res planes).
            guard !frameHeader.loopFilterGab && frameHeader.loopFilterEpfIters == 0 else {
                throw JXLError.unsupported("restoration filters with chroma subsampling")
            }
        }
        // kPatches (2) is decoded from the DC-global head; splines (16) and
        // noise (1) are not yet parsed and would desynchronize the stream.
        // kSkipAdaptiveDCSmoothing (128) is honored.
        guard frameHeader.flags & ~UInt64(128 | 2) == 0 else {
            throw JXLError.unsupported("VarDCT frame features (splines/noise)")
        }
    }

    /// The patch dictionary, populated by `varDCTDCGlobal` when the frame sets
    /// kPatches; nil otherwise (and before DC-global runs).
    private(set) var patchDictionary: PatchDictionary?

    /// Decodes the patch dictionary from the head of the DC-global section
    /// (before DequantMatrices.DecodeDC). Positions are validated against the
    /// padded frame and the stored reference-frame dimensions.
    func parsePatchDictionary(_ r: BitReader) throws -> PatchDictionary {
        try decodePatchDictionary(
            r, xsize: divCeil(dim.xsize, 8) * 8, ysize: divCeil(dim.ysize, 8) * 8,
            numExtraChannels: metadata.extraChannelCount,
            referenceSize: { self.referenceFrameSize($0) })
    }

    /// Stage 1 — `ProcessDCGlobal` (section 0 prefix): quantizer, block context
    /// map, DC color correlation, and the global modular tree/code.
    func varDCTDCGlobal() throws -> VarDCTDCGlobalDecoded {
        if let cached = cachedDCGlobal { return cached }
        try requireSupportedVarDCT()
        if frameHeader.flags & 2 != 0 {
            patchDictionary = try parsePatchDictionary(r0)
        }
        let dcGlobal = try readVarDCTDCGlobal(r0)
        // The DC-global section ends with the global modular stream. For a
        // frame with extra channels it carries them (color is VarDCT-coded, so
        // the modular image holds only the ECs); channels no larger than
        // group_dim decode entirely here, bigger ones per AC group.
        if metadata.extraChannelCount > 0 {
            try decodeExtraChannelGlobal(dcGlobal)
        }
        cachedDCGlobal = dcGlobal
        cachedDCDequant = computeDCDequant(dcGlobal.info)
        return dcGlobal
    }

    // MARK: VarDCT extra channels (modular sub-streams)

    /// The frame's extra channels as a modular image (full frame resolution),
    /// plus the global transforms to undo once every group has landed.
    private(set) var ecImage: ModularImage?
    private var ecTransforms: [ModularTransform] = []
    private var ecFinalized = false

    private func decodeExtraChannelGlobal(_ dcGlobal: VarDCTDCGlobalDecoded) throws {
        // Mirrors ModularFrameDecoder::DecodeGlobalInfo channel geometry:
        // DivCeil(xsize_upsampled, ecups) with shift log2(ecups)−log2(upsampling).
        // Only the unshifted full-resolution shape is implemented.
        guard frameHeader.upsampling == 1,
            frameHeader.ecUpsampling.allSatisfy({ $0 == 1 }),
            metadata.extraChannels.allSatisfy({ $0.dimShift == 0 })
        else { throw JXLError.unsupported("upsampled/shifted extra channels in VarDCT") }
        // Output planes advertise the color depth (8-bit), so only plain 8-bit
        // integer extra channels are attached for now.
        guard metadata.extraChannels.allSatisfy({
            $0.bitDepth.bitsPerSample == 8 && !$0.bitDepth.isFloatingPoint
        }) else { throw JXLError.unsupported("non-8-bit extra channels in VarDCT") }
        try checkPixelLimits(channels: 3 + metadata.extraChannelCount)

        let image = ModularImage(
            w: dim.xsize, h: dim.ysize, bitdepth: Int(metadata.bitDepth.bitsPerSample),
            channelCount: metadata.extraChannelCount)
        let header = try modularDecode(
            r0, image: image, groupID: 0, globalTree: dcGlobal.tree,
            globalCode: dcGlobal.code, globalCtxMap: dcGlobal.ctxMap,
            maxChanSize: dim.groupDim)
        ecImage = image
        ecTransforms = header.transforms
    }

    /// Applies the pending inverse transforms once every group's extra-channel
    /// data has been decoded, and returns the finished planes.
    func finalizeExtraChannels() throws -> [[Int32]] {
        guard let image = ecImage else { return [] }
        if !ecFinalized {
            try undoTransforms(image, transforms: ecTransforms)
            ecFinalized = true
        }
        return image.channels.map { $0.pixels }
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
        let dcGlobal = try varDCTDCGlobal()
        let acGlobal = try decodeVarDCTACGlobal(
            reader, dim: dim, numPasses: Int(frameHeader.numPasses),
            blockContextMap: dcGlobal.info.blockContextMap,
            usedACs: lf.metadata.usedACs, dcGlobal: dcGlobal)
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
