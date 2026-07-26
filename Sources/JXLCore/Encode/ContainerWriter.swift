// ContainerWriter.swift
//
// ISOBMFF container WRITING (ISO/IEC 18181-2) — the dual of
// Container/Container.swift's parser. Produces:
//
//   * the 12-byte signature box (`JXL ` / 0D 0A 87 0A),
//   * `ftyp` (major brand "jxl ", minor version 0, compatible brand "jxl "),
//   * any metadata boxes, in the order given,
//   * the codestream in a single `jxlc` box.
//
// WHY `jxlc` AND NOT `jxlp`: the two forms are equivalent for a complete file.
// `jxlp` exists so a writer that does not yet have the whole codestream can
// emit the header portion, then metadata boxes, then the remainder — which is
// what libjxl's own encoder does when it streams. We always hold the finished
// codestream in memory, and we place every metadata box AHEAD of the
// codestream box, so a streaming reader already sees Exif/XMP/jbrd before any
// pixel data. `jxlc` buys that same ordering with no partial-index bookkeeping
// and no risk of an inconsistent "last part" flag, and it is what the existing
// (djxl-verified) jbrd path already emits. The only thing `jxlp` would add is
// splitting a >4 GiB codestream across 32-bit box sizes; we reject that case
// explicitly instead of writing an untestable path.
//
// Metadata boxes are written UNCOMPRESSED (`Exif`, `xml `) rather than as
// Brotli-compressed `brob` boxes. `brob` is only a win with a real Brotli
// compressor; our serializer is store-only (`brotliStore`, needed by the jbrd
// path), so a `brob` box would be strictly LARGER than the raw box while also
// forcing every reader through a decompressor. Both forms are spec-legal and
// libjxl reads either.

import Foundation

/// One metadata box to place in the container, ahead of the codestream.
struct ContainerBox {
    let type: String
    let payload: [UInt8]
}

enum ContainerWriter {
    /// Largest payload a 32-bit-size box can carry.
    static let maxBoxPayload = Int(UInt32.max) - 8

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    /// One ISOBMFF box: 4-byte big-endian total size, 4-byte type, payload.
    static func box(_ type: String, _ payload: [UInt8]) throws -> [UInt8] {
        let typeBytes = Array(type.utf8)
        guard typeBytes.count == 4 else {
            throw JXLEncodeError(reason: "box type '\(type)' must be exactly 4 bytes")
        }
        guard payload.count <= maxBoxPayload else {
            throw JXLEncodeError(
                reason: "box '\(type)' payload \(payload.count) bytes exceeds the 32-bit box size")
        }
        var b = be32(UInt32(8 + payload.count))
        b.append(contentsOf: typeBytes)
        b.append(contentsOf: payload)
        return b
    }

    /// `ftyp` payload: major brand "jxl ", minor version 0, one compatible
    /// brand "jxl " (libjxl writes minor version 0 for in-order files).
    static let ftypPayload: [UInt8] = {
        let brand = Array("jxl ".utf8)
        return brand + [0, 0, 0, 0] + brand
    }()

    /// Assembles a complete container file: signature box, `ftyp`, the given
    /// metadata boxes in order, then the codestream in a single `jxlc`.
    static func assemble(codestream: [UInt8], metadataBoxes: [ContainerBox] = []) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(codestream.count + 64)
        out.append(contentsOf: JXLContainer.containerSignature)
        out.append(contentsOf: try box("ftyp", ContainerWriter.ftypPayload))
        for b in metadataBoxes {
            out.append(contentsOf: try box(b.type, b.payload))
        }
        out.append(contentsOf: try box("jxlc", codestream))
        return out
    }
}

// MARK: - Uncompressed ("store") Brotli stream

/// Emits a valid Brotli stream that decompresses to exactly `payload` (RFC 7932
/// uncompressed meta-block, then a final empty last meta-block). Brotli and the
/// JXL BitWriter are both LSB-first, so the same writer serializes it.
///
/// Used by the jbrd path (whose marker tail is a mandatory Brotli stream) and
/// available for `brob` boxes; see the file header for why metadata boxes do
/// not use it.
func brotliStore(_ payload: [UInt8]) -> [UInt8] {
    let w = BitWriter()
    w.write(0, 1)  // WBITS selector 0 -> window 16
    if payload.isEmpty {
        w.write(1, 1)  // ISLAST = 1
        w.write(1, 1)  // ISLASTEMPTY = 1
        return w.finalize()
    }
    // Uncompressed meta-block (non-last).
    w.write(0, 1)  // ISLAST = 0
    let mlen = payload.count
    let stored = UInt64(mlen - 1)
    let nibbles: Int
    if mlen <= (1 << 16) { nibbles = 4 } else if mlen <= (1 << 20) { nibbles = 5 } else { nibbles = 6 }
    w.write(UInt64(nibbles - 4), 2)  // MNIBBLES
    for i in 0..<nibbles { w.write((stored >> UInt64(4 * i)) & 0xF, 4) }
    w.write(1, 1)  // ISUNCOMPRESSED = 1
    w.alignToByte()
    w.append(bytes: payload)
    // Final empty last meta-block.
    w.write(1, 1)  // ISLAST = 1
    w.write(1, 1)  // ISLASTEMPTY = 1
    return w.finalize()
}

// MARK: - Metadata box payload shapes

enum MetadataBoxes {
    /// `Exif` box payload: a 4-byte big-endian offset to the TIFF header
    /// followed by the Exif payload. We always write offset 0, so the TIFF
    /// stream ("II*\0" / "MM\0*") starts immediately after the prefix — the
    /// same shape the jbrd path writes and `JXL.readExif` reads back.
    static func exif(_ tiffStream: [UInt8]) -> ContainerBox {
        ContainerBox(type: "Exif", payload: [0, 0, 0, 0] + tiffStream)
    }

    /// `xml ` box payload: the XMP packet verbatim (no prefix).
    static func xmp(_ packet: [UInt8]) -> ContainerBox {
        ContainerBox(type: "xml ", payload: packet)
    }
}
