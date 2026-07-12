// Container.swift
//
// JPEG XL files come in two shapes (ISO/IEC 18181-2):
//
//   1. A bare codestream, beginning with the 2-byte signature `FF 0A`.
//   2. An ISOBMFF ("BMFF") container, beginning with a 12-byte signature box
//      of type "JXL " containing `0D 0A 87 0A`, followed by further boxes.
//
// In the container case the codestream lives in either a single `jxlc` box or
// a sequence of `jxlp` (partial) boxes that must be concatenated in order.
// Other boxes carry metadata: `ftyp`, `jbrd` (JPEG reconstruction), `Exif`,
// `xml ` (XMP), `jhgm`, `jumb`, etc.
//
// In *every* case the resulting codestream itself starts with `FF 0A`.

import Foundation

/// One ISOBMFF box. `payload` is the byte range of the box contents (excluding
/// the size/type header) within the original file.
public struct JXLBox: Equatable, Sendable {
    public let type: String
    public let payload: Range<Int>
    public let headerSize: Int

    public var totalSize: Int { headerSize + payload.count }
}

/// Result of splitting a file into its container structure and codestream.
public struct ParsedFile: Sendable {
    /// `true` if the file used the ISOBMFF container; `false` for a bare codestream.
    public let isContainer: Bool
    /// The boxes in the order they appear (empty for a bare codestream).
    public let boxes: [JXLBox]
    /// The reassembled codestream, beginning with the `FF 0A` signature.
    public let codestream: [UInt8]
}

public enum JXLContainer {
    /// Raw codestream signature.
    public static let codestreamSignature: [UInt8] = [0xFF, 0x0A]

    /// The 12-byte ISOBMFF signature box: size=12, type="JXL ", body `0D 0A 87 0A`.
    public static let containerSignature: [UInt8] =
        [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]

    /// Splits a JPEG XL file into its container structure (if any) and codestream.
    public static func parse(_ data: [UInt8]) throws -> ParsedFile {
        if data.starts(with: codestreamSignature) {
            return ParsedFile(isContainer: false, boxes: [], codestream: data)
        }
        guard data.starts(with: containerSignature) else {
            throw JXLError.invalidSignature
        }
        return try parseContainer(data)
    }

    private static func parseContainer(_ data: [UInt8]) throws -> ParsedFile {
        var boxes: [JXLBox] = []
        var offset = 0

        while offset + 8 <= data.count {
            let size32 = beUInt32(data, offset)
            let type = boxType(data, offset + 4)
            var headerSize = 8
            var boxLength: Int

            switch size32 {
            case 1:
                // 64-bit largesize follows the type.
                guard offset + 16 <= data.count else {
                    throw JXLError.truncated(context: "box largesize for '\(type)'")
                }
                let large = beUInt64(data, offset + 8)
                guard large <= UInt64(data.count) else {
                    throw JXLError.malformed("box '\(type)' largesize \(large) overruns file")
                }
                headerSize = 16
                boxLength = Int(large)
            case 0:
                // Box extends to the end of the file.
                boxLength = data.count - offset
            default:
                boxLength = Int(size32)
            }

            guard boxLength >= headerSize, offset + boxLength <= data.count else {
                throw JXLError.malformed("box '\(type)' length \(boxLength) overruns file")
            }

            let payloadStart = offset + headerSize
            let payloadEnd = offset + boxLength
            boxes.append(JXLBox(type: type, payload: payloadStart..<payloadEnd, headerSize: headerSize))
            offset = payloadEnd
        }

        let codestream = try reassembleCodestream(data, boxes: boxes)
        return ParsedFile(isContainer: true, boxes: boxes, codestream: codestream)
    }

    /// Extracts the codestream from `jxlc` (whole) or `jxlp` (partial) boxes.
    private static func reassembleCodestream(_ data: [UInt8], boxes: [JXLBox]) throws -> [UInt8] {
        // A single `jxlc` box carries the entire codestream verbatim.
        if let whole = boxes.first(where: { $0.type == "jxlc" }) {
            return Array(data[whole.payload])
        }

        // Otherwise concatenate `jxlp` partial boxes in order. Each begins with a
        // 4-byte big-endian index; the codestream bytes follow.
        var codestream: [UInt8] = []
        var sawPartial = false
        for box in boxes where box.type == "jxlp" {
            sawPartial = true
            guard box.payload.count >= 4 else {
                throw JXLError.malformed("jxlp box too small for index")
            }
            let chunk = box.payload.lowerBound + 4 ..< box.payload.upperBound
            codestream.append(contentsOf: data[chunk])
        }

        guard sawPartial else {
            throw JXLError.malformed("container has no jxlc or jxlp codestream box")
        }
        return codestream
    }

    // MARK: - Big-endian helpers

    private static func beUInt32(_ d: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
    }

    private static func beUInt64(_ d: [UInt8], _ i: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<8 { value = (value << 8) | UInt64(d[i + k]) }
        return value
    }

    private static func boxType(_ d: [UInt8], _ i: Int) -> String {
        let scalars = (0..<4).map { Character(UnicodeScalar(d[i + $0])) }
        return String(scalars)
    }
}
