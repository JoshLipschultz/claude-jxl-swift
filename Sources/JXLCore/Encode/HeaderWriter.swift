// HeaderWriter.swift
//
// Codestream header writing (E0 of docs/encoder-design.md): the duals of
// SizeHeader / ImageMetadata / CustomTransformData for the encoder's initial
// subset — integer bit depths, RGB or grayscale, no extra channels, no
// animation, enumerated sRGB, xyb_encoded=false (native-space lossless
// Modular). Every field written here is read back by the decoder's own
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
    /// all-default sRGB encoding.
    static func writeImageMetadata(
        _ w: BitWriter, bitsPerSample: UInt32, grayscale: Bool
    ) {
        w.writeBool(false)  // all_default (false: we need xyb_encoded=0)
        w.writeBool(false)  // extra_fields (no orientation/preview/animation)
        // BitDepth: integer samples.
        w.writeBool(false)  // floating_point_sample
        w.writeU32(bitsPerSample, .value(8), .value(10), .value(12), .bits(6, offset: 1))
        w.writeBool(true)  // modular_16bit_buffers (default; decoder ignores)
        w.writeU32(0, .value(0), .value(1), .bits(4, offset: 2), .bits(12, offset: 1))  // num_extra
        w.writeBool(false)  // xyb_encoded: native-space samples (lossless)
        writeColorEncoding(w, grayscale: grayscale)
        // (no tone_mapping: only present when extra_fields)
        w.writeU64(0)  // extensions
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

    /// The complete pre-frame header block of a bare codestream: signature,
    /// size, metadata, transform data, byte alignment (the decoder's
    /// `JumpToByteBoundary` before frames).
    static func writeCodestreamHeaders(
        _ w: BitWriter, width: UInt32, height: UInt32, bitsPerSample: UInt32,
        grayscale: Bool
    ) {
        w.write(0xFF, 8)
        w.write(0x0A, 8)
        writeSizeHeader(w, width: width, height: height)
        writeImageMetadata(w, bitsPerSample: bitsPerSample, grayscale: grayscale)
        writeCustomTransformData(w)
        w.alignToByte()
    }
}
