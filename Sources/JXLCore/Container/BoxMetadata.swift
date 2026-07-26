// BoxMetadata.swift
//
// Reading metadata out of a container's boxes — the read side of what
// Encode/ContainerWriter.swift writes, and the public form of the private
// lookup the jbrd reconstruction path already uses. Brotli-compressed `brob`
// boxes are unwrapped transparently (their payload starts with the 4-byte type
// of the box they stand in for).

import Foundation

extension JXL {
    /// Raw payload of the first top-level box of `type`, or `nil` when the file
    /// has none (including a bare codestream). A `brob` box standing in for
    /// `type` is decompressed first, so callers see the same bytes either way.
    public static func readBoxPayload(from data: [UInt8], type: String) throws -> Data? {
        guard type.utf8.count == 4 else {
            throw JXLError.malformed("box type '\(type)' must be exactly 4 bytes")
        }
        let parsed = try JXLContainer.parse(data)
        guard parsed.isContainer else { return nil }
        for box in parsed.boxes {
            if box.type == type {
                return Data(data[box.payload])
            }
            if box.type == "brob", box.payload.count > 4 {
                let inner = String(
                    decoding: data[box.payload.lowerBound..<(box.payload.lowerBound + 4)],
                    as: UTF8.self)
                if inner == type {
                    let compressed = Array(
                        data[(box.payload.lowerBound + 4)..<box.payload.upperBound])
                    return Data(try Brotli.decompress(compressed, maxOutputSize: 64 << 20))
                }
            }
        }
        return nil
    }

    public static func readBoxPayload(from data: Data, type: String) throws -> Data? {
        try readBoxPayload(from: [UInt8](data), type: type)
    }

    public static func readBoxPayload(contentsOf url: URL, type: String) throws -> Data? {
        try readBoxPayload(from: try Data(contentsOf: url), type: type)
    }

    /// The Exif payload as a bare TIFF stream (starting `II*\0` / `MM\0*`).
    /// The `Exif` box payload begins with a 4-byte big-endian offset from the
    /// end of that field to the TIFF header; both the prefix and any skipped
    /// bytes are removed here, so this is the value `JXLEncodeOptions.exif`
    /// takes.
    public static func readExif(from data: [UInt8]) throws -> Data? {
        guard let payload = try readBoxPayload(from: data, type: "Exif") else { return nil }
        guard payload.count >= 4 else {
            throw JXLError.malformed("Exif box too small for its tiff-header offset")
        }
        let bytes = [UInt8](payload)
        let offset =
            (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard offset >= 0, 4 + offset <= bytes.count else {
            throw JXLError.malformed("Exif tiff-header offset \(offset) overruns the box")
        }
        return Data(bytes[(4 + offset)...])
    }

    public static func readExif(from data: Data) throws -> Data? {
        try readExif(from: [UInt8](data))
    }

    public static func readExif(contentsOf url: URL) throws -> Data? {
        try readExif(from: try Data(contentsOf: url))
    }

    /// The XMP packet from the `xml ` box, verbatim.
    public static func readXMP(from data: [UInt8]) throws -> Data? {
        try readBoxPayload(from: data, type: "xml ")
    }

    public static func readXMP(from data: Data) throws -> Data? {
        try readXMP(from: [UInt8](data))
    }

    public static func readXMP(contentsOf url: URL) throws -> Data? {
        try readXMP(from: try Data(contentsOf: url))
    }
}
