// HybridUint.swift
//
// The "hybrid integer" coder (libjxl `HybridUintConfig`, dec_ans.h). Every
// entropy-coded value is split into a *token* (entropy-coded by ANS or a prefix
// code) plus some number of raw *extra bits*. A token below `split_token` is the
// value itself; larger tokens encode (number of bits) + a few MSBs + a few LSBs,
// with the remaining bits sent verbatim. Ported bit-for-bit from libjxl v0.11.2.

import Foundation

/// Floor(log2(x)) for x > 0.
@inline(__always)
func floorLog2Nonzero(_ x: UInt32) -> Int { 31 - Int(x.leadingZeroBitCount) }

/// Ceil(log2(x)) for x > 0.
@inline(__always)
func ceilLog2Nonzero(_ x: UInt32) -> Int {
    let f = floorLog2Nonzero(x)
    return (x & (x &- 1)) == 0 ? f : f + 1
}

public struct HybridUintConfig: Equatable, Sendable {
    public let splitExponent: UInt32
    public let splitToken: UInt32
    public let msbInToken: UInt32
    public let lsbInToken: UInt32

    public init(splitExponent: UInt32 = 4, msbInToken: UInt32 = 2, lsbInToken: UInt32 = 0) {
        self.splitExponent = splitExponent
        self.splitToken = 1 << splitExponent
        self.msbInToken = msbInToken
        self.lsbInToken = lsbInToken
    }

    /// Reconstructs a value from its `token`, consuming the extra bits from `reader`
    /// (libjxl `ReadHybridUintConfig`).
    public func decode(token: UInt32, reader: BitReader) -> UInt32 {
        if token < splitToken { return token }
        let m = msbInToken
        let l = lsbInToken
        var nbits = splitExponent &- (m &+ l) &+ ((token &- splitToken) >> (m &+ l))
        nbits &= 31
        let low = token & ((UInt32(1) << l) &- 1)
        let tok = token >> l
        let bits = UInt32(truncatingIfNeeded: reader.read(Int(nbits)))
        let msbPart = (UInt32(1) << m) | (tok & ((UInt32(1) << m) &- 1))
        let ret = (((msbPart << nbits) | bits) << l) | low
        return ret
    }

    /// Splits a value into `(token, nbits, bits)` (libjxl `HybridUintConfig::Encode`).
    /// Provided for round-trip testing and a future encoder.
    public func encode(_ value: UInt32) -> (token: UInt32, nbits: UInt32, bits: UInt32) {
        if value < splitToken { return (value, 0, 0) }
        let n = UInt32(floorLog2Nonzero(value))
        let m = value &- (UInt32(1) << n)
        let token =
            splitToken
            &+ ((n &- splitExponent) << (msbInToken &+ lsbInToken))
            &+ ((m >> (n &- msbInToken)) << lsbInToken)
            &+ (m & ((UInt32(1) << lsbInToken) &- 1))
        let nbits = n &- msbInToken &- lsbInToken
        let bits = (value >> lsbInToken) & ((UInt32(1) << nbits) &- 1)
        return (token, nbits, bits)
    }
}

extension BitReader {
    /// Reads one `HybridUintConfig` description (libjxl `DecodeUintConfig`).
    public func readHybridUintConfig(logAlphaSize: Int) -> HybridUintConfig {
        let splitExponent = UInt32(read(ceilLog2Nonzero(UInt32(logAlphaSize + 1))))
        var msb: UInt32 = 0
        var lsb: UInt32 = 0
        if Int(splitExponent) != logAlphaSize {
            let nbitsMSB = ceilLog2Nonzero(splitExponent + 1)
            msb = UInt32(read(nbitsMSB))
            let nbitsLSB = ceilLog2Nonzero(splitExponent &- msb &+ 1)
            lsb = UInt32(read(nbitsLSB))
        }
        return HybridUintConfig(splitExponent: splitExponent, msbInToken: msb, lsbInToken: lsb)
    }
}
