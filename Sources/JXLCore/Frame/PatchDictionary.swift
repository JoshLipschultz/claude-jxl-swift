// PatchDictionary.swift
//
// The patch dictionary (ISO/IEC 18181-1 §C.4.5; libjxl dec_patch_dictionary):
// rectangular crops of previously stored reference frames, blended onto the
// presented frame at entropy-coded positions. Decoded from the head of the
// DC-global section when the frame header sets kPatches (flags bit 2), before
// DequantMatrices.DecodeDC. Rendering happens after the restoration filters
// and before the color transform, so patches operate in the frame's encoded
// color space (XYB for lossy files).

import Foundation

/// A reference frame decoded to pre-color-transform XYB planes (row-major,
/// width×height), the space patches blend in.
struct ReferenceXYBFrame {
    let width: Int
    let height: Int
    let x: [Float]
    let y: [Float]
    let b: [Float]
}

/// PatchBlendMode (dec_patch_dictionary.h). Alpha-driven modes fall back to
/// their alpha-free semantics when the image has no alpha channel (libjxl
/// PerformBlending `has_alpha == false`): kBlend* copies the patch, and
/// kAlphaWeightedAdd* adds it.
enum PatchBlendMode: UInt32 {
    case none = 0
    case replace = 1
    case add = 2
    case mul = 3
    case blendAbove = 4
    case blendBelow = 5
    case alphaWeightedAddAbove = 6
    case alphaWeightedAddBelow = 7

    static let count: UInt32 = 8

    var usesAlpha: Bool {
        self == .blendAbove || self == .blendBelow
            || self == .alphaWeightedAddAbove || self == .alphaWeightedAddBelow
    }
    var usesClamp: Bool { usesAlpha || self == .mul }
}

struct PatchBlending {
    var mode: PatchBlendMode
    var alphaChannel: UInt32
    var clamp: Bool
}

/// Position and size of a patch's source crop in its reference frame.
struct PatchReferencePosition {
    let ref: Int
    let x0: Int
    let y0: Int
    let xsize: Int
    let ysize: Int
}

/// One placement of a reference crop in the presented frame.
struct PatchPosition {
    let x: Int
    let y: Int
    let refPosIndex: Int
}

struct PatchDictionary {
    let refPositions: [PatchReferencePosition]
    let positions: [PatchPosition]
    /// `blendingsStride` entries per position: color first, then one per extra
    /// channel.
    let blendings: [PatchBlending]
    let blendingsStride: Int

    var isEmpty: Bool { positions.isEmpty }
}

// Context numbers (§C.4.5 Listing C.2; patch_dictionary_internal.h).
private let kNumRefPatchContext = 0
private let kReferenceFrameContext = 1
private let kPatchSizeContext = 2
private let kPatchReferencePositionContext = 3
private let kPatchPositionContext = 4
private let kPatchBlendModeContext = 5
private let kPatchOffsetContext = 6
private let kPatchCountContext = 7
private let kPatchAlphaChannelContext = 8
private let kPatchClampContext = 9
private let kNumPatchDictionaryContexts = 10

private let kMaxNumReferenceFrames = 4

/// Mirrors `PatchDictionary::Decode`. `xsize`/`ysize` are the padded frame
/// dimensions; `referenceSize` reports the stored dimensions of a reference
/// slot (nil when the slot is empty).
func decodePatchDictionary(
    _ br: BitReader, xsize: Int, ysize: Int, numExtraChannels: Int,
    referenceSize: (Int) -> (width: Int, height: Int)?
) throws -> PatchDictionary {
    let blendingsStride = numExtraChannels + 1
    guard
        let (code, contextMap) = decodeHistograms(
            br, numContexts: kNumPatchDictionaryContexts, disallowLZ77: false)
    else { throw JXLError.malformed("could not read patch dictionary histograms") }
    let decoder = ANSSymbolReader(code: code, reader: br)
    func readNum(_ context: Int) -> Int {
        Int(decoder.readHybridUint(context, br, contextMap: contextMap))
    }

    let numRefPatch = readNum(kNumRefPatchContext)
    // Limit max memory usage of patches to about 66 bytes per pixel.
    let numPixels = xsize * ysize
    let maxRefPatches = 1024 + numPixels / 4
    let maxPatches = maxRefPatches * 4
    let maxBlendingInfos = maxPatches * 4
    guard numRefPatch <= maxRefPatches else {
        throw JXLError.malformed("too many patches in dictionary")
    }

    var refPositions: [PatchReferencePosition] = []
    var positions: [PatchPosition] = []
    var blendings: [PatchBlending] = []
    var totalPatches = 0
    var nextSize = 1

    for _ in 0..<numRefPatch {
        let ref = readNum(kReferenceFrameContext)
        guard ref < kMaxNumReferenceFrames, let refDim = referenceSize(ref) else {
            throw JXLError.malformed("invalid patch reference frame ID")
        }
        let x0 = readNum(kPatchReferencePositionContext)
        let y0 = readNum(kPatchReferencePositionContext)
        let pxsize = readNum(kPatchSizeContext) + 1
        let pysize = readNum(kPatchSizeContext) + 1
        guard x0 + pxsize <= refDim.width, y0 + pysize <= refDim.height else {
            throw JXLError.malformed("invalid position specified in reference frame")
        }
        var idCount = readNum(kPatchCountContext)
        guard idCount <= maxPatches else {
            throw JXLError.malformed("too many patches in dictionary")
        }
        idCount += 1
        totalPatches += idCount
        guard totalPatches <= maxPatches else {
            throw JXLError.malformed("too many patches in dictionary")
        }
        if nextSize < totalPatches {
            nextSize = min(nextSize * 2, maxPatches)
        }
        guard nextSize * blendingsStride <= maxBlendingInfos else {
            throw JXLError.malformed("too many patches in dictionary")
        }
        positions.reserveCapacity(nextSize)
        blendings.reserveCapacity(nextSize * blendingsStride)

        let chooseAlpha = numExtraChannels > 1
        for i in 0..<idCount {
            var px: Int
            var py: Int
            if i == 0 {
                px = readNum(kPatchPositionContext)
                py = readNum(kPatchPositionContext)
            } else {
                let deltaX = unpackSignedPatch(readNum(kPatchOffsetContext))
                let deltaY = unpackSignedPatch(readNum(kPatchOffsetContext))
                px = positions[positions.count - 1].x + deltaX
                py = positions[positions.count - 1].y + deltaY
                guard px >= 0, py >= 0 else {
                    throw JXLError.malformed("invalid patch: negative coordinate")
                }
            }
            guard px + pxsize <= xsize, py + pysize <= ysize else {
                throw JXLError.malformed("invalid patch position \(px),\(py)")
            }
            for j in 0..<blendingsStride {
                let rawMode = readNum(kPatchBlendModeContext)
                guard rawMode < Int(PatchBlendMode.count),
                    let mode = PatchBlendMode(rawValue: UInt32(rawMode))
                else { throw JXLError.malformed("invalid patch blend mode") }
                if (mode.usesAlpha || (mode != .none && j > 0)) && numExtraChannels > 0 {
                    // Extra-channel-involving blends need the extra-channel
                    // planes, which the VarDCT pipeline does not carry yet.
                    throw JXLError.unsupported("patches touching extra channels")
                }
                var alphaChannel: UInt32 = 0
                if mode.usesAlpha && chooseAlpha {
                    alphaChannel = UInt32(readNum(kPatchAlphaChannelContext))
                    guard alphaChannel < UInt32(numExtraChannels) else {
                        throw JXLError.malformed("invalid alpha channel for blending")
                    }
                }
                var clamp = false
                if mode.usesClamp {
                    clamp = readNum(kPatchClampContext) != 0
                }
                blendings.append(
                    PatchBlending(mode: mode, alphaChannel: alphaChannel, clamp: clamp))
            }
            positions.append(PatchPosition(x: px, y: py, refPosIndex: refPositions.count))
        }
        refPositions.append(
            PatchReferencePosition(ref: ref, x0: x0, y0: y0, xsize: pxsize, ysize: pysize))
    }

    guard decoder.checkANSFinalState() else {
        throw JXLError.malformed("patch dictionary ANS checksum failure")
    }
    return PatchDictionary(
        refPositions: refPositions, positions: positions, blendings: blendings,
        blendingsStride: blendingsStride)
}

private func unpackSignedPatch(_ u: Int) -> Int {
    let v = UInt64(u)
    let magnitude = Int(v >> 1)
    return (v & 1) == 1 ? -magnitude - 1 : magnitude
}

// MARK: - Rendering

/// Blends every patch onto the reconstructed XYB image (libjxl stage_patches +
/// PerformBlending, color channels only — the dictionary decode rejects
/// patches that touch extra channels). Patches are applied in dictionary
/// order, which preserves the relative order of overlapping patches.
func renderPatches(
    _ dict: PatchDictionary, into image: inout XYBImage,
    reference: (Int) throws -> ReferenceXYBFrame
) throws {
    guard !dict.isEmpty else { return }

    // Decode each referenced frame once up front.
    var refs: [Int: ReferenceXYBFrame] = [:]
    for refPos in dict.refPositions where refs[refPos.ref] == nil {
        refs[refPos.ref] = try reference(refPos.ref)
    }

    let width = image.width
    let height = image.height
    let stride = image.stride

    image.x.withUnsafeMutableBufferPointer { bx in
        image.y.withUnsafeMutableBufferPointer { by in
            image.b.withUnsafeMutableBufferPointer { bb in
                let planes = [bx.baseAddress!, by.baseAddress!, bb.baseAddress!]
                for (index, pos) in dict.positions.enumerated() {
                    let refPos = dict.refPositions[pos.refPosIndex]
                    let ref = refs[refPos.ref]!
                    let blending = dict.blendings[index * dict.blendingsStride]
                    guard blending.mode != .none else { continue }
                    // Clip to the visible region (patches may reach into the
                    // block padding, which is never displayed).
                    let y1 = min(pos.y + refPos.ysize, height)
                    let x1 = min(pos.x + refPos.xsize, width)
                    guard pos.y < y1, pos.x < x1 else { continue }
                    let fgPlanes = [ref.x, ref.y, ref.b]
                    for c in 0..<3 {
                        let out = planes[c]
                        fgPlanes[c].withUnsafeBufferPointer { fgBuf in
                            let fg = fgBuf.baseAddress!
                            for y in pos.y..<y1 {
                                let outRow = y * stride
                                let fgRow = (refPos.y0 + y - pos.y) * ref.width + refPos.x0 - pos.x
                                blendPatchRow(
                                    out: out, fg: fg, outRow: outRow, fgRow: fgRow,
                                    x0: pos.x, x1: x1, mode: blending.mode,
                                    clamp: blending.clamp)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One row of color blending, alpha-free semantics (PerformBlending with
/// `has_alpha == false`).
private func blendPatchRow(
    out: UnsafeMutablePointer<Float>, fg: UnsafePointer<Float>,
    outRow: Int, fgRow: Int, x0: Int, x1: Int, mode: PatchBlendMode, clamp: Bool
) {
    switch mode {
    case .none:
        break
    case .replace, .blendAbove, .blendBelow:
        for x in x0..<x1 { out[outRow + x] = fg[fgRow + x] }
    case .add, .alphaWeightedAddAbove, .alphaWeightedAddBelow:
        for x in x0..<x1 { out[outRow + x] += fg[fgRow + x] }
    case .mul:
        if clamp {
            for x in x0..<x1 {
                out[outRow + x] *= min(max(fg[fgRow + x], 0), 1)
            }
        } else {
            for x in x0..<x1 { out[outRow + x] *= fg[fgRow + x] }
        }
    }
}
