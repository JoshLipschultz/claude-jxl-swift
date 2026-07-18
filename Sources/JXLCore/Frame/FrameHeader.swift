// FrameHeader.swift
//
// The per-frame header (ISO/IEC 18181-1 §E; libjxl frame_header.cc). Faithful
// port of `FrameHeader::VisitFields` and its nested bundles (Passes,
// BlendingInfo, AnimationFrame, LoopFilter, YCbCrChromaSubsampling). Parsing
// depends on a few ImageMetadata fields, passed in via `FrameContext`.

import Foundation

public enum FrameType: UInt32, Sendable { case regular = 0, dc = 1, referenceOnly = 2, skipProgressive = 3 }
public enum FrameEncoding: Sendable { case modular, varDCT }
public enum ColorTransform: UInt32, Sendable { case xyb = 0, none = 1, ycbcr = 2 }

private let kUseDcFrame: UInt64 = 32
private let kEpfSharpEntries = 8

/// ImageMetadata-derived context needed to parse a FrameHeader.
public struct FrameContext: Sendable {
    public let xybEncoded: Bool
    public let numExtraChannels: Int
    public let haveAnimation: Bool
    public let animationHaveTimecodes: Bool
    public let imageWidth: Int
    public let imageHeight: Int

    public init(metadata: JXLImageMetadata, width: UInt32, height: UInt32, animationHaveTimecodes: Bool = false) {
        self.xybEncoded = metadata.xybEncoded
        self.numExtraChannels = metadata.extraChannelCount
        self.haveAnimation = metadata.hasAnimation
        self.animationHaveTimecodes = animationHaveTimecodes
        self.imageWidth = Int(width)
        self.imageHeight = Int(height)
    }
}

public struct FrameHeader: Sendable {
    public var frameType: FrameType = .regular
    public var encoding: FrameEncoding = .varDCT
    public var flags: UInt64 = 0
    public var colorTransform: ColorTransform = .xyb
    public var upsampling: UInt32 = 1
    public var groupSizeShift: UInt32 = 1
    public var xQmScale: UInt32 = 2
    public var bQmScale: UInt32 = 2
    public var numPasses: UInt32 = 1
    public var dcLevel: UInt32 = 0
    public var customSizeOrOrigin = false
    public var frameWidth: UInt32 = 0
    public var frameHeight: UInt32 = 0
    public var frameX0: Int32 = 0
    public var frameY0: Int32 = 0
    public var isLast = true
    public var name = ""
    public var chromaChannelMode: [UInt32] = [0, 0, 0]

    // Loop filter (defaults per libjxl LoopFilter::VisitFields).
    public var loopFilterGab = true
    public var loopFilterEpfIters: UInt32 = 2
    public var gabXWeight1: Float = 1.1 * 0.104699568
    public var gabXWeight2: Float = 1.1 * 0.055680538
    public var gabYWeight1: Float = 1.1 * 0.104699568
    public var gabYWeight2: Float = 1.1 * 0.055680538
    public var gabBWeight1: Float = 1.1 * 0.104699568
    public var gabBWeight2: Float = 1.1 * 0.055680538

    public var isModular: Bool { encoding == .modular }

    private var chromaMaxHShift: Int {
        let hShift = [0, 1, 1, 0]
        return chromaChannelMode.map { hShift[Int($0)] }.max() ?? 0
    }
    private var chromaMaxVShift: Int {
        let vShift = [0, 1, 0, 1]
        return chromaChannelMode.map { vShift[Int($0)] }.max() ?? 0
    }

    /// Per-channel downsampling shifts (libjxl `YCbCrChromaSubsampling`:
    /// `HShift(c) = maxhs - kHShift[mode_c]`), zero for non-YCbCr frames.
    /// Channel order matches the plane order (0 = X/Cb, 1 = Y, 2 = B/Cr).
    public var channelShifts: (h: [Int], v: [Int]) {
        guard colorTransform == .ycbcr else { return ([0, 0, 0], [0, 0, 0]) }
        let kH = [0, 1, 1, 0]
        let kV = [0, 1, 0, 1]
        let hs = chromaChannelMode.map { kH[Int($0)] }
        let vs = chromaChannelMode.map { kV[Int($0)] }
        let mh = hs.max() ?? 0
        let mv = vs.max() ?? 0
        return (hs.map { mh - $0 }, vs.map { mv - $0 })
    }

    /// True when all three channels are full resolution.
    public var chromaIs444: Bool {
        let s = channelShifts
        return s.h == [0, 0, 0] && s.v == [0, 0, 0]
    }

    /// Computes the group/DC-group grid for this frame.
    public func frameDimensions(_ ctx: FrameContext) -> FrameDimensions {
        var xs = customSizeOrOrigin && frameWidth != 0 ? Int(frameWidth) : ctx.imageWidth
        var ys = customSizeOrOrigin && frameHeight != 0 ? Int(frameHeight) : ctx.imageHeight
        if dcLevel != 0 {
            xs = divCeil(xs, 1 << (3 * Int(dcLevel)))
            ys = divCeil(ys, 1 << (3 * Int(dcLevel)))
        }
        var dim = FrameDimensions()
        dim.set(
            xsize: xs, ysize: ys, groupSizeShift: Int(groupSizeShift),
            maxHShift: colorTransform == .ycbcr ? chromaMaxHShift : 0,
            maxVShift: colorTransform == .ycbcr ? chromaMaxVShift : 0,
            modular: isModular, upsampling: Int(upsampling))
        return dim
    }

    public init(reader r: BitReader, context ctx: FrameContext) {
        let allDefault = r.readBool()
        if allDefault { return }

        frameType = FrameType(rawValue: r.readU32(.value(0), .value(1), .value(2), .value(3))) ?? .regular

        encoding = r.readBool() ? .modular : .varDCT

        flags = r.readU64()

        if ctx.xybEncoded {
            colorTransform = .xyb
        } else {
            colorTransform = r.readBool() ? .ycbcr : .none
        }

        if colorTransform == .ycbcr && (flags & kUseDcFrame) == 0 {
            for i in 0..<3 { chromaChannelMode[i] = UInt32(r.read(2)) }
        }

        // Upsampling.
        if (flags & kUseDcFrame) == 0 {
            upsampling = r.readU32(.value(1), .value(2), .value(4), .value(8))
            for _ in 0..<ctx.numExtraChannels {
                _ = r.readU32(.value(1), .value(2), .value(4), .value(8))  // extra-channel upsampling
            }
        }

        if encoding == .modular {
            groupSizeShift = UInt32(r.read(2))
        }
        if encoding == .varDCT && colorTransform == .xyb {
            xQmScale = UInt32(r.read(3))
            bQmScale = UInt32(r.read(3))
        }

        if frameType != .referenceOnly {
            parsePasses(r)
        }

        if frameType == .dc {
            dcLevel = r.readU32(.value(1), .value(2), .value(3), .value(4))
        }

        var isPartialFrame = false
        if frameType != .dc {
            customSizeOrOrigin = r.readBool()
            if customSizeOrOrigin {
                let enc: (BitReader) -> UInt32 = { br in
                    br.readU32(.bits(8), .bits(11, offset: 256), .bits(14, offset: 2304), .bits(30, offset: 18688))
                }
                if frameType == .regular || frameType == .skipProgressive {
                    frameX0 = unpackSigned(enc(r))
                    frameY0 = unpackSigned(enc(r))
                }
                frameWidth = enc(r)
                frameHeight = enc(r)
                if frameType == .regular || frameType == .skipProgressive {
                    if frameX0 > 0 || frameY0 > 0 { isPartialFrame = true }
                    if Int(frameWidth) + Int(frameX0) < ctx.imageWidth { isPartialFrame = true }
                    if Int(frameHeight) + Int(frameY0) < ctx.imageHeight { isPartialFrame = true }
                }
            }
        }

        // Blending / animation / is_last.
        if frameType == .regular || frameType == .skipProgressive {
            parseBlendingInfo(r, numExtraChannels: ctx.numExtraChannels, isPartial: isPartialFrame)
            for _ in 0..<ctx.numExtraChannels {
                parseBlendingInfo(r, numExtraChannels: ctx.numExtraChannels, isPartial: isPartialFrame)
            }
            if ctx.haveAnimation {
                _ = r.readU32(.value(0), .value(1), .bits(8), .bits(32))  // duration
                if ctx.animationHaveTimecodes { _ = r.read(32) }  // timecode
            }
            isLast = r.readBool()
        } else {
            isLast = false
        }

        if frameType != .dc && !isLast {
            _ = r.readU32(.value(0), .value(1), .value(2), .value(3))  // save_as_reference
        }

        // save_before_color_transform (only in cases not reached by is_last frames).
        if frameType != .dc {
            let canBeReferenced = !isLast
            if canBeReferenced && lastBlendModeWasReplace && !isPartialFrame
                && (frameType == .regular || frameType == .skipProgressive) {
                _ = r.readBool()
            } else if frameType == .referenceOnly {
                _ = r.readBool()
            }
        }

        name = readNameString(r)

        parseLoopFilter(r, isModular: encoding == .modular)

        r.skipExtensions()
    }

    private var lastBlendModeWasReplace = true

    // MARK: Nested bundles

    private mutating func parsePasses(_ r: BitReader) {
        numPasses = r.readU32(.value(1), .value(2), .value(3), .bits(3, offset: 4))
        if numPasses != 1 {
            let numDownsample = r.readU32(.value(0), .value(1), .value(2), .bits(1, offset: 3))
            for _ in 0..<(numPasses - 1) { _ = r.read(2) }  // shift[i]
            for _ in 0..<numDownsample { _ = r.readU32(.value(1), .value(2), .value(4), .value(8)) }  // downsample
            for _ in 0..<numDownsample { _ = r.readU32(.value(0), .value(1), .value(2), .bits(3)) }  // last_pass
        }
    }

    private mutating func parseBlendingInfo(_ r: BitReader, numExtraChannels: Int, isPartial: Bool) {
        let mode = r.readU32(.value(0), .value(1), .value(2), .bits(2, offset: 3))  // BlendMode
        lastBlendModeWasReplace = lastBlendModeWasReplace && (mode == 0)
        let involvesAlpha = mode == 2 || mode == 3  // kBlend / kAlphaWeightedAdd
        if numExtraChannels > 0 && involvesAlpha {
            _ = r.readU32(.value(0), .value(1), .value(2), .bits(3, offset: 3))  // alpha_channel
        }
        if (numExtraChannels > 0 && involvesAlpha) || mode == 4 {  // ... or kMul
            _ = r.readBool()  // clamp
        }
        if mode != 0 || isPartial {
            _ = r.readU32(.value(0), .value(1), .value(2), .value(3))  // source
        }
    }

    private mutating func parseLoopFilter(_ r: BitReader, isModular: Bool) {
        if r.readBool() { return }  // all_default (keeps the defaults above)
        loopFilterGab = r.readBool()
        if loopFilterGab {
            if r.readBool() {  // gab_custom
                gabXWeight1 = r.readF16(); gabXWeight2 = r.readF16()
                gabYWeight1 = r.readF16(); gabYWeight2 = r.readF16()
                gabBWeight1 = r.readF16(); gabBWeight2 = r.readF16()
            }
        }
        loopFilterEpfIters = UInt32(r.read(2))
        if loopFilterEpfIters > 0 {
            if !isModular {
                if r.readBool() {  // epf_sharp_custom
                    for _ in 0..<kEpfSharpEntries { _ = r.readF16() }
                }
            }
            if r.readBool() {  // epf_weight_custom
                for _ in 0..<5 { _ = r.readF16() }
            }
            if r.readBool() {  // epf_sigma_custom
                if !isModular { _ = r.readF16() }  // epf_quant_mul
                for _ in 0..<3 { _ = r.readF16() }
            }
            if isModular { _ = r.readF16() }  // epf_sigma_for_modular
        }
        r.skipExtensions()
    }
}

@inline(__always)
private func unpackSigned(_ u: UInt32) -> Int32 {
    Int32(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
}

/// Reads a JPEG XL name string (libjxl `VisitNameString`).
func readNameString(_ r: BitReader) -> String {
    let length = Int(r.readU32(.value(0), .bits(4), .bits(5, offset: 16), .bits(10, offset: 48)))
    if length == 0 { return "" }
    var bytes = [UInt8]()
    bytes.reserveCapacity(length)
    for _ in 0..<length { bytes.append(UInt8(truncatingIfNeeded: r.read(8))) }
    return String(decoding: bytes, as: UTF8.self)
}
