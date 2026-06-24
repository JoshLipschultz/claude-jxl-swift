// BitReader.swift
//
// Least-significant-bit-first bit reader, matching the JPEG XL convention
// (ISO/IEC 18181-1 §C.1 / libjxl `BitReader`).
//
// Bits are consumed from the least-significant end of each byte, and bytes
// are consumed in increasing address order. Reading past the end of the
// buffer yields zero bits and latches `didOverread` (libjxl behaves the same
// way; conformance is validated separately via a final bounds check).

import Foundation

public final class BitReader {
    /// Backing bytes (the raw codestream, signature already consumed by the caller
    /// or skipped via `skip`).
    private let data: [UInt8]

    /// Absolute position, in bits, from the start of `data`.
    public private(set) var bitPosition: Int = 0

    /// Set once a read crosses the end of `data`. Headers should never trigger this.
    public private(set) var didOverread: Bool = false

    public init(_ data: [UInt8]) {
        self.data = data
    }

    /// Total number of bits in the buffer.
    public var bitCount: Int { data.count * 8 }

    /// Bits remaining before the end of the buffer.
    public var bitsRemaining: Int { max(0, bitCount - bitPosition) }

    /// Whether the reader has consumed (or passed) every bit.
    public var isAtEnd: Bool { bitPosition >= bitCount }

    /// Reads `count` bits (0...64), LSB-first, and returns them right-aligned.
    @discardableResult
    public func read(_ count: Int) -> UInt64 {
        precondition(count >= 0 && count <= 64, "read(\(count)) out of range")
        if count == 0 { return 0 }

        var result: UInt64 = 0
        var produced = 0
        while produced < count {
            let byteIndex = bitPosition >> 3
            let bitOffset = bitPosition & 7
            let current: UInt64
            if byteIndex < data.count {
                current = UInt64(data[byteIndex])
            } else {
                current = 0
                didOverread = true
            }
            let available = 8 - bitOffset
            let take = min(available, count - produced)
            let mask = (UInt64(1) << take) - 1
            let bits = (current >> UInt64(bitOffset)) & mask
            result |= bits << UInt64(produced)
            produced += take
            bitPosition += take
        }
        return result
    }

    /// Reads a single bit as a Bool.
    public func readBool() -> Bool {
        read(1) == 1
    }

    /// Advances by `count` bits without returning a value.
    public func skip(_ count: Int) {
        precondition(count >= 0)
        bitPosition += count
        if bitPosition > bitCount { didOverread = true }
    }

    /// Advances to the next byte boundary (no-op if already aligned).
    public func alignToByte() {
        let rem = bitPosition & 7
        if rem != 0 { bitPosition += 8 - rem }
    }

    /// Throws if the reader has read past the end of the buffer.
    public func ensureInBounds(_ context: String) throws {
        if didOverread || bitPosition > bitCount {
            throw JXLError.truncated(context: context)
        }
    }
}
