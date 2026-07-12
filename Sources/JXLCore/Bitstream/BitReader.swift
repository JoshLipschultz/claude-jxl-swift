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
    /// Backing bytes. May be shared with other readers: `baseByte`/`endByte`
    /// bound this reader's window, so sections of one codestream can each get a
    /// reader without copying (Swift arrays are copy-on-write; nobody mutates).
    private let data: [UInt8]
    private let baseByte: Int
    private let endByte: Int

    /// Position, in bits, from the start of this reader's window.
    public private(set) var bitPosition: Int = 0

    /// Set once a read crosses the end of the window. Headers should never trigger this.
    public private(set) var didOverread: Bool = false

    public init(_ data: [UInt8]) {
        self.data = data
        self.baseByte = 0
        self.endByte = data.count
    }

    /// A reader over `byteRange` of `data`, sharing the storage (no copy).
    /// `bitPosition` is relative to the start of the range. The range must lie
    /// within `data`; callers validate untrusted ranges before constructing.
    public init(_ data: [UInt8], byteRange: Range<Int>) {
        precondition(
            byteRange.lowerBound >= 0 && byteRange.upperBound <= data.count,
            "BitReader byteRange outside buffer")
        self.data = data
        self.baseByte = byteRange.lowerBound
        self.endByte = byteRange.upperBound
    }

    /// Total number of bits in the window.
    public var bitCount: Int { (endByte - baseByte) * 8 }

    /// Bits remaining before the end of the buffer.
    public var bitsRemaining: Int { max(0, bitCount - bitPosition) }

    /// Whether the reader has consumed (or passed) every bit.
    public var isAtEnd: Bool { bitPosition >= bitCount }

    /// True if every read so far stayed within the buffer (libjxl
    /// `AllReadsWithinBounds`).
    public var allReadsWithinBounds: Bool { !didOverread && bitPosition <= bitCount }

    /// Reads `count` bits (0...64), LSB-first, and returns them right-aligned.
    ///
    /// Fast path: while at least 8 bytes remain in the window, a single
    /// unaligned 64-bit load supplies up to 56 bits (after the ≤7-bit intra-byte
    /// shift) — this is the hot path under every entropy-coded stream. The
    /// byte-at-a-time loop remains as the tail/large-count fallback.
    @discardableResult
    public func read(_ count: Int) -> UInt64 {
        precondition(count >= 0 && count <= 64, "read(\(count)) out of range")
        let byteIndex = baseByte + (bitPosition >> 3)
        if count <= 56 && byteIndex + 8 <= endByte {
            let word = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: byteIndex, as: UInt64.self)
            }.littleEndian
            let value = (word >> UInt64(bitPosition & 7)) & ((UInt64(1) << UInt64(count)) - 1)
            bitPosition += count
            return value
        }
        return readSlow(count)
    }

    private func readSlow(_ count: Int) -> UInt64 {
        if count == 0 { return 0 }

        var result: UInt64 = 0
        var produced = 0
        while produced < count {
            let byteIndex = baseByte + (bitPosition >> 3)
            let bitOffset = bitPosition & 7
            let current: UInt64
            if byteIndex < endByte {
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

    /// Returns the next `count` bits without advancing the position
    /// (libjxl `PeekBits`). Pair with `skip` (libjxl `Consume`).
    public func peek(_ count: Int) -> UInt64 {
        let savedPosition = bitPosition
        let savedOverread = didOverread
        let value = read(count)
        bitPosition = savedPosition
        didOverread = savedOverread
        return value
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
