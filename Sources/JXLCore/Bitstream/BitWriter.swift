// BitWriter.swift
//
// Least-significant-bit-first bit writer — the exact dual of `BitReader`
// (ISO/IEC 18181-1 §C.1 / libjxl `BitWriter`). Bits fill each byte from the
// least-significant end; bytes are emitted in increasing address order.
//
// Field-encoding duals (`U32`, `U64`, `Enum`, `F16`) mirror Fields.swift; the
// write→read identity is pinned by exhaustive randomized tests in the suite.

import Foundation

public final class BitWriter {
    private var bytes: [UInt8] = []
    /// Bit accumulator: `bitCount` valid bits in the low end of `accumulator`.
    private var accumulator: UInt64 = 0
    private var accumulatorBits: Int = 0

    public init() {}

    /// Total bits written so far.
    public var bitPosition: Int { bytes.count * 8 + accumulatorBits }

    /// Writes the low `count` bits of `value`, LSB-first (dual of
    /// `BitReader.read`). Bits above `count` in `value` must be zero-extended
    /// by the caller's masking here.
    public func write(_ value: UInt64, _ count: Int) {
        precondition(count >= 0 && count <= 64, "write(\(count)) out of range")
        if count == 0 { return }
        let masked = count == 64 ? value : value & ((UInt64(1) << UInt64(count)) - 1)
        accumulator |= masked << UInt64(accumulatorBits)
        let total = accumulatorBits + count
        if total < 64 {
            accumulatorBits = total
            flushWholeBytes()
        } else {
            // Accumulator full or overflowing: emit its 64 bits, then stash
            // the remainder of `value`.
            for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(i * 8))) }
            let consumed = 64 - accumulatorBits
            accumulator = consumed < 64 ? masked >> UInt64(consumed) : 0
            accumulatorBits = total - 64
            flushWholeBytes()
        }
    }

    private func flushWholeBytes() {
        while accumulatorBits >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            accumulatorBits -= 8
        }
    }

    public func writeBool(_ value: Bool) { write(value ? 1 : 0, 1) }

    /// Pads with zero bits to the next byte boundary (dual of `alignToByte`;
    /// the JXL convention pads with zeros).
    public func alignToByte() {
        if accumulatorBits > 0 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator = 0
            accumulatorBits = 0
        }
    }

    /// Appends whole bytes (must be byte-aligned — sections are).
    public func append(bytes newBytes: [UInt8]) {
        precondition(accumulatorBits == 0, "append(bytes:) requires byte alignment")
        bytes.append(contentsOf: newBytes)
    }

    /// The finished stream. Flushes any partial byte (zero-padded), so call
    /// once at the end (or at known byte-aligned points).
    public func finalize() -> [UInt8] {
        alignToByte()
        return bytes
    }

    // MARK: - Field-encoding duals (ISO/IEC 18181-1 §C.2)

    /// `U32(c0, c1, c2, c3)`: picks the cheapest alternative that can
    /// represent `value` (fewest extra bits; ties → lowest selector, matching
    /// libjxl `U32Coder`), writes the 2-bit selector + extra bits.
    public func writeU32(
        _ value: UInt32, _ c0: U32Choice, _ c1: U32Choice, _ c2: U32Choice, _ c3: U32Choice
    ) {
        let choices = [c0, c1, c2, c3]
        var best = -1
        for (i, c) in choices.enumerated() {
            guard value >= c.offset else { continue }
            let extra = value - c.offset
            let maxExtra: UInt32 =
                c.bitCount >= 32 ? .max : (c.bitCount == 0 ? 0 : (1 << UInt32(c.bitCount)) - 1)
            guard extra <= maxExtra else { continue }
            if best == -1 || c.bitCount < choices[best].bitCount { best = i }
        }
        precondition(best >= 0, "U32 value \(value) not representable by any alternative")
        write(UInt64(best), 2)
        let choice = choices[best]
        if choice.bitCount > 0 {
            write(UInt64(value - choice.offset), choice.bitCount)
        }
    }

    /// `U64()` — dual of `readU64`.
    public func writeU64(_ value: UInt64) {
        if value == 0 {
            write(0, 2)
        } else if value <= 16 {
            write(1, 2)
            write(value - 1, 4)
        } else if value <= 272 {
            write(2, 2)
            write(value - 17, 8)
        } else {
            write(3, 2)
            write(value, 12)
            var remaining = value >> 12
            var shift = 12
            while remaining != 0 {
                writeBool(true)
                if shift == 60 {
                    write(remaining, 4)
                    return
                }
                write(remaining, 8)
                remaining >>= 8
                shift += 8
            }
            writeBool(false)
        }
    }

    /// `Enum()` — dual of `readEnum`.
    public func writeEnum(_ value: UInt32) {
        writeU32(value, .value(0), .value(1), .bits(4, offset: 2), .bits(6, offset: 18))
    }

    /// `F16()` — IEEE-754 binary16, little-endian (dual of `readF16`).
    public func writeF16(_ value: Float) {
        write(UInt64(Float16(value).bitPattern), 16)
    }
}
