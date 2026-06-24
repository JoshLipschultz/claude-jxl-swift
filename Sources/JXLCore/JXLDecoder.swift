// JXLDecoder.swift
//
// Top-level entry points. This is the orchestrator that will grow to drive the
// full decode pipeline (headers -> frames -> entropy -> Modular/VarDCT -> pixels).
//
// Current milestone (M1): container demux + image dimensions. Deeper metadata
// (bit depth, color, channels) and pixel decoding land in subsequent milestones.

import Foundation

/// Lightweight description of a JPEG XL file, available without decoding pixels.
public struct JXLImageInfo: Equatable {
    public let width: UInt32
    public let height: UInt32
    /// `true` if delivered inside an ISOBMFF container, `false` for a bare codestream.
    public let isContainer: Bool
    /// The container's box types in order (empty for a bare codestream).
    public let boxTypes: [String]
}

public enum JXL {
    /// Reads structural information (dimensions, container layout) from a JPEG XL file.
    public static func readInfo(from data: [UInt8]) throws -> JXLImageInfo {
        let parsed = try JXLContainer.parse(data)

        guard parsed.codestream.count >= 2,
              parsed.codestream[0] == 0xFF,
              parsed.codestream[1] == 0x0A else {
            throw JXLError.invalidSignature
        }

        let reader = BitReader(parsed.codestream)
        reader.skip(16) // consume the FF 0A signature
        let size = SizeHeader(reader)
        try reader.ensureInBounds("SizeHeader")

        return JXLImageInfo(
            width: size.width,
            height: size.height,
            isContainer: parsed.isContainer,
            boxTypes: parsed.boxes.map(\.type)
        )
    }

    /// Convenience overload reading from `Data`.
    public static func readInfo(from data: Data) throws -> JXLImageInfo {
        try readInfo(from: [UInt8](data))
    }

    /// Convenience overload reading a file from disk.
    public static func readInfo(contentsOf url: URL) throws -> JXLImageInfo {
        try readInfo(from: try Data(contentsOf: url))
    }
}
