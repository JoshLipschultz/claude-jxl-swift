// Fields.swift
//
// The JPEG XL field-encoding primitives layered on top of `BitReader`
// (ISO/IEC 18181-1 §C.2). These are the building blocks every header is
// expressed in: `u(n)`, `U32`, `U64`, signed values, and IEEE-754 half floats.

import Foundation

/// One of the four alternatives in a `U32` field. A 2-bit selector chooses
/// which alternative is in effect; the decoded value is `offset + read(bitCount)`.
///
/// `.value(c)` is the spec's `Val(c)` (zero extra bits); `.bits(n, offset:)` is
/// the spec's `BitsOffset(n, offset)` (and plain `Bits(n)` when `offset == 0`).
public struct U32Choice: Sendable {
    public let offset: UInt32
    public let bitCount: Int

    public static func value(_ constant: UInt32) -> U32Choice {
        U32Choice(offset: constant, bitCount: 0)
    }

    public static func bits(_ n: Int, offset: UInt32 = 0) -> U32Choice {
        U32Choice(offset: offset, bitCount: n)
    }
}

extension BitReader {
    /// `U32(c0, c1, c2, c3)` — a 2-bit selector picks an alternative.
    public func readU32(_ c0: U32Choice, _ c1: U32Choice, _ c2: U32Choice, _ c3: U32Choice)
        -> UInt32
    {
        let selector = Int(read(2))
        let choice: U32Choice
        switch selector {
        case 0: choice = c0
        case 1: choice = c1
        case 2: choice = c2
        default: choice = c3
        }
        let extra: UInt32 =
            choice.bitCount > 0 ? UInt32(truncatingIfNeeded: read(choice.bitCount)) : 0
        return choice.offset &+ extra
    }

    /// `U64()` — the variable-length 64-bit field (ISO/IEC 18181-1 §C.2.4).
    public func readU64() -> UInt64 {
        let selector = read(2)
        switch selector {
        case 0:
            return 0
        case 1:
            return read(4) + 1
        case 2:
            return read(8) + 17
        default:
            var value = read(12)
            var shift = 12
            while readBool() {
                if shift == 60 {
                    value |= read(4) << UInt64(shift)
                    break
                }
                value |= read(8) << UInt64(shift)
                shift += 8
            }
            return value
        }
    }

    /// `Enum()` — small enumerated value. Per libjxl `Visitor::Enum`
    /// (lib/jxl/fields.h) this is `U32(Val(0), Val(1), BitsOffset(4, 2),
    /// BitsOffset(6, 18))`: values 0, 1, 2...17, then 18...81.
    public func readEnum() -> UInt32 {
        readU32(.value(0), .value(1), .bits(4, offset: 2), .bits(6, offset: 18))
    }

    /// Reads and discards a JPEG XL extensions field: a `U64` bitmask followed
    /// by a `U64` size (in bits) for each set bit, then skips that many bits.
    public func skipExtensions() {
        let extensions = readU64()
        if extensions == 0 { return }
        var totalBits: UInt64 = 0
        for i in 0..<64 where (extensions & (UInt64(1) << UInt64(i))) != 0 {
            totalBits &+= readU64()
        }
        skip(Int(totalBits))
    }

    /// `F16()` — IEEE-754 binary16 stored little-endian in the bitstream,
    /// returned as a `Float` (ISO/IEC 18181-1 §C.2.6).
    public func readF16() -> Float {
        let bits = UInt16(truncatingIfNeeded: read(16))
        return Float(float16Bits: bits)
    }
}

extension Float {
    /// Reconstructs a `Float` from IEEE-754 binary16 bit pattern.
    init(float16Bits bits: UInt16) {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits & 0x7C00) >> 10
        let mantissa = UInt32(bits & 0x03FF)

        let result: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                // Signed zero.
                result = sign
            } else {
                // Subnormal half -> normalized single.
                var e: Int32 = -1
                var m = mantissa
                repeat {
                    e += 1
                    m <<= 1
                } while (m & 0x0400) == 0
                m &= 0x03FF
                let exp32 = UInt32(Int32(127 - 15 + 1) + e) << 23
                result = sign | exp32 | (m << 13)
            }
        } else if exponent == 0x1F {
            // Inf / NaN.
            result = sign | 0x7F80_0000 | (mantissa << 13)
        } else {
            let exp32 = (exponent + (127 - 15)) << 23
            result = sign | exp32 | (mantissa << 13)
        }
        self = Float(bitPattern: result)
    }
}
