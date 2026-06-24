// SizeHeader.swift
//
// The first structure in the codestream after the `FF 0A` signature
// (ISO/IEC 18181-1 §D.2 "Image size"). Encodes the image dimensions, with a
// compact path for multiples of 8 and an aspect-ratio table that lets width be
// derived from height for common ratios.

import Foundation

public struct SizeHeader: Equatable {
    public let width: UInt32
    public let height: UInt32

    /// Aspect-ratio codes 1...7 derive width from height (code 0 = explicit width).
    /// Ratios: 1:1, 12:10, 4:3, 3:2, 16:9, 5:4, 2:1.
    static func width(forRatio ratio: Int, height h: UInt32) -> UInt32 {
        let h64 = UInt64(h)
        switch ratio {
        case 1: return h
        case 2: return UInt32(h64 * 12 / 10)
        case 3: return UInt32(h64 * 4 / 3)
        case 4: return UInt32(h64 * 3 / 2)
        case 5: return UInt32(h64 * 16 / 9)
        case 6: return UInt32(h64 * 5 / 4)
        case 7: return h * 2
        default: return h
        }
    }

    public init(_ reader: BitReader) {
        let div8 = reader.readBool()

        let h: UInt32
        if div8 {
            h = (UInt32(reader.read(5)) + 1) * 8
        } else {
            h = reader.readU32(.bits(9, offset: 1),
                               .bits(13, offset: 1),
                               .bits(18, offset: 1),
                               .bits(30, offset: 1))
        }

        let ratio = Int(reader.read(3))
        let w: UInt32
        if ratio == 0 {
            if div8 {
                w = (UInt32(reader.read(5)) + 1) * 8
            } else {
                w = reader.readU32(.bits(9, offset: 1),
                                   .bits(13, offset: 1),
                                   .bits(18, offset: 1),
                                   .bits(30, offset: 1))
            }
        } else {
            w = SizeHeader.width(forRatio: ratio, height: h)
        }

        self.width = w
        self.height = h
    }
}
