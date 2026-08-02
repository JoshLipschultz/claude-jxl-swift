// HeaderWriter.swift
//
// Codestream header writing (E0 of docs/encoder-design.md): the duals of
// SizeHeader / ImageMetadata / CustomTransformData for the encoder's initial
// subset — integer bit depths, RGB or grayscale, alpha extra channels, no
// animation, enumerated sRGB, and either xyb_encoded=false (native-space
// lossless Modular) or xyb_encoded=true (the lossy VarDCT path). Every field written here is read back by the decoder's own
// parsers in-suite (write→read identity), which are themselves
// oracle-validated against libjxl.

import Foundation

enum HeaderWriter {
    /// SizeHeader (§D.2), general path: explicit height and width (no div8
    /// compaction, ratio 0). Valid for all supported dimensions; a few bits
    /// larger than cjxl's compact forms.
    static func writeSizeHeader(_ w: BitWriter, width: UInt32, height: UInt32) {
        precondition(width >= 1 && height >= 1, "empty image")
        w.writeBool(false)  // small (div8)
        w.writeU32(
            height, .bits(9, offset: 1), .bits(13, offset: 1), .bits(18, offset: 1),
            .bits(30, offset: 1))
        w.write(0, 3)  // ratio = 0 (explicit width)
        w.writeU32(
            width, .bits(9, offset: 1), .bits(13, offset: 1), .bits(18, offset: 1),
            .bits(30, offset: 1))
    }

    /// ImageMetadata (§D.3) for the encoder subset. `grayscale` selects a
    /// full ColorEncoding write (gray D65 sRGB-transfer); RGB uses the
    /// all-default sRGB encoding. `exponentBits > 0` selects floating-point
    /// samples (binary32 = 32/8). `alphaChannels` alpha extra channels share
    /// the color bit depth (dim_shift 0, unassociated, unnamed).
    static func writeImageMetadata(
        _ w: BitWriter, bitsPerSample: UInt32, grayscale: Bool,
        exponentBits: UInt32 = 0, alphaChannels: Int = 0,
        extraChannelInfo: [JXLExtraChannelInfo]? = nil
    ) {
        w.writeBool(false)  // all_default (false: we need xyb_encoded=0)
        w.writeBool(false)  // extra_fields (no orientation/preview/animation)
        writeBitDepth(w, bitsPerSample: bitsPerSample, exponentBits: exponentBits)
        // modular_16bit_buffers: false whenever samples can exceed int16
        // buffers (float32 bit patterns span the full int32 range — libjxl
        // trusts this flag and would decode through 16-bit buffers).
        w.writeBool(exponentBits == 0)
        w.writeU32(
            UInt32(alphaChannels), .value(0), .value(1), .bits(4, offset: 2),
            .bits(12, offset: 1))  // num_extra_channels
        for i in 0..<alphaChannels {
            writeExtraChannelInfo(
                w, bitsPerSample: bitsPerSample, exponentBits: exponentBits,
                info: extraChannelInfo.flatMap { i < $0.count ? $0[i] : nil })
        }
        w.writeBool(false)  // xyb_encoded: native-space samples (lossless)
        writeColorEncoding(w, grayscale: grayscale)
        // (no tone_mapping: only present when extra_fields)
        w.writeU64(0)  // extensions
    }

    /// BitDepth bundle — dual of `ImageMetadataFields.readBitDepth`.
    /// Internal rather than private so ICCWriter's header path shares this
    /// exact bit layout instead of duplicating it — the duplicate drifted out
    /// of sight once and is not worth a second chance.
    static func writeBitDepth(
        _ w: BitWriter, bitsPerSample: UInt32, exponentBits: UInt32
    ) {
        if exponentBits == 0 {
            w.writeBool(false)  // floating_point_sample
            w.writeU32(bitsPerSample, .value(8), .value(10), .value(12), .bits(6, offset: 1))
        } else {
            w.writeBool(true)  // floating_point_sample
            w.writeU32(bitsPerSample, .value(32), .value(16), .value(24), .bits(6, offset: 1))
            w.write(UInt64(exponentBits - 1), 4)  // exp_bits − 1
        }
    }

    /// One alpha ExtraChannelInfo — dual of
    /// `ImageMetadataFields.readExtraChannelInfo`. 8-bit integer alpha is
    /// exactly the bundle's all-default shape (one bit); anything else is
    /// written explicitly: type Alpha, the color bit depth, dim_shift 0,
    /// empty name, alpha_associated=false.
    /// Internal for the same reason as `writeBitDepth`.
    ///
    /// `info` describes the channel; nil means the historical assumption of
    /// unassociated alpha. The all_default shortcut is only legal when the
    /// channel actually IS 8-bit unassociated alpha — taking it for a depth
    /// channel or premultiplied alpha would encode a lie that decodes cleanly,
    /// which is the worst kind of bug to find later.
    static func writeExtraChannelInfo(
        _ w: BitWriter, bitsPerSample: UInt32, exponentBits: UInt32,
        info: JXLExtraChannelInfo? = nil
    ) {
        let type = info?.type ?? 0  // kAlpha
        let associated = info?.alphaAssociated ?? false
        if bitsPerSample == 8 && exponentBits == 0 && type == 0 && !associated {
            w.writeBool(true)  // all_default (= 8-bit unassociated alpha)
            return
        }
        w.writeBool(false)  // all_default
        w.writeEnum(UInt32(type))
        writeBitDepth(w, bitsPerSample: bitsPerSample, exponentBits: exponentBits)
        w.writeU32(0, .value(0), .value(3), .value(4), .bits(3, offset: 1))  // dim_shift
        w.writeU32(0, .value(0), .bits(4), .bits(5, offset: 16), .bits(10, offset: 48))  // name len
        // alpha_associated is only serialized for kAlpha; other types carry
        // their own trailing fields, which this encoder does not yet emit (see
        // the validation in encValidateExtraChannelInfo).
        if type == 0 { w.writeBool(associated) }
    }

    /// Rejects extra-channel descriptors this encoder cannot faithfully write.
    /// Refusing is the point: silently encoding a spot-colour channel without
    /// its colour, or a shifted channel at full resolution, produces a file
    /// that decodes without complaint and means something different.
    static func encValidateExtraChannelInfo(_ infos: [JXLExtraChannelInfo]?, count: Int) throws {
        guard let infos else { return }
        guard infos.count == count else {
            throw JXLEncodeError(
                reason: "extraChannelInfo count \(infos.count) != extraChannels \(count)")
        }
        for (i, info) in infos.enumerated() {
            guard info.dimShift == 0 else {
                throw JXLEncodeError(
                    reason: "extra channel \(i): dim_shift \(info.dimShift) unsupported")
            }
            // kSpotColor (2) needs its RGBA blend written; kCFA (5) needs a
            // pattern index. Neither is emitted yet.
            guard info.type != 2, info.type != 5 else {
                throw JXLEncodeError(
                    reason: "extra channel \(i): type \(info.type) unsupported by the encoder")
            }
        }
    }

    /// ColorEncoding (§D.3.5): all-default (= sRGB) for RGB; explicit
    /// grayscale + D65 + sRGB transfer + relative intent for gray.
    private static func writeColorEncoding(_ w: BitWriter, grayscale: Bool) {
        if !grayscale {
            w.writeBool(true)  // all_default = sRGB
            return
        }
        w.writeBool(false)  // all_default
        w.writeBool(false)  // want_icc
        w.writeEnum(1)  // color_space: kGray
        w.writeEnum(1)  // white_point: D65 (no custom xy follows)
        // (primaries not signaled for grayscale)
        w.writeBool(false)  // have_gamma → transfer function enum follows
        w.writeEnum(13)  // transfer: sRGB
        w.writeEnum(1)  // rendering intent: relative
    }

    /// CustomTransformData (§D.4): all defaults.
    static func writeCustomTransformData(_ w: BitWriter) {
        w.writeBool(true)  // all_default
    }

    /// ImageMetadata for the lossy (VarDCT) path: integer samples,
    /// `xyb_encoded = true`, sRGB color encoding, and `alphaChannels` alpha
    /// extra channels. 8-bit with no ECs is exactly the bundle's all-default
    /// shape (one bit); anything else is
    /// written explicitly — dual of `JXLImageMetadata.init(_:)`, whose
    /// all-default branch sets `xybEncoded = true`.
    static func writeImageMetadataXYB(
        _ w: BitWriter, bitsPerSample: UInt32, alphaChannels: Int = 0,
        extraChannelInfo: [JXLExtraChannelInfo]? = nil
    ) {
        if bitsPerSample == 8 && alphaChannels == 0 {
            w.writeBool(true)  // all_default: 8-bit sRGB, xyb_encoded, no ECs
            return
        }
        w.writeBool(false)  // all_default
        w.writeBool(false)  // extra_fields (no orientation/preview/animation)
        writeBitDepth(w, bitsPerSample: bitsPerSample, exponentBits: 0)
        w.writeBool(true)  // modular_16bit_buffers (integer samples)
        w.writeU32(
            UInt32(alphaChannels), .value(0), .value(1), .bits(4, offset: 2),
            .bits(12, offset: 1))  // num_extra_channels
        // Alpha ECs at the color bit depth. In a VarDCT frame these are
        // modular-coded, so alpha stays LOSSLESS while color is lossy.
        for i in 0..<alphaChannels {
            writeExtraChannelInfo(
                w, bitsPerSample: bitsPerSample, exponentBits: 0,
                info: extraChannelInfo.flatMap { i < $0.count ? $0[i] : nil })
        }
        w.writeBool(true)  // xyb_encoded
        w.writeBool(true)  // ColorEncoding all_default = sRGB
        // (no tone_mapping: only present when extra_fields)
        w.writeU64(0)  // extensions
    }

    /// The complete pre-frame header block for a lossy (XYB VarDCT) bare
    /// codestream: signature, size, xyb metadata, default transform data
    /// (default opsin — the all-default branch skips the OpsinInverseMatrix
    /// bundle entirely), byte alignment.
    static func writeCodestreamHeadersXYB(
        _ w: BitWriter, width: UInt32, height: UInt32, bitsPerSample: UInt32,
        alphaChannels: Int = 0, extraChannelInfo: [JXLExtraChannelInfo]? = nil
    ) {
        w.write(0xFF, 8)
        w.write(0x0A, 8)
        writeSizeHeader(w, width: width, height: height)
        writeImageMetadataXYB(
            w, bitsPerSample: bitsPerSample, alphaChannels: alphaChannels,
            extraChannelInfo: extraChannelInfo)
        writeCustomTransformData(w)
        w.alignToByte()
    }

    /// The complete pre-frame header block of a bare codestream: signature,
    /// size, metadata, transform data, byte alignment (the decoder's
    /// `JumpToByteBoundary` before frames).
    static func writeCodestreamHeaders(
        _ w: BitWriter, width: UInt32, height: UInt32, bitsPerSample: UInt32,
        grayscale: Bool, exponentBits: UInt32 = 0, alphaChannels: Int = 0,
        extraChannelInfo: [JXLExtraChannelInfo]? = nil
    ) {
        w.write(0xFF, 8)
        w.write(0x0A, 8)
        writeSizeHeader(w, width: width, height: height)
        writeImageMetadata(
            w, bitsPerSample: bitsPerSample, grayscale: grayscale,
            exponentBits: exponentBits, alphaChannels: alphaChannels,
            extraChannelInfo: extraChannelInfo)
        writeCustomTransformData(w)
        w.alignToByte()
    }
}
