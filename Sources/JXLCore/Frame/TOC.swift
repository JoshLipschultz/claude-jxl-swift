// TOC.swift
//
// The frame Table of Contents (libjxl toc.cc): the byte size of each section,
// optionally preceded by an entropy-coded permutation (a Lehmer code decoded
// through the ANS/prefix machinery). This is the first place the M3 entropy
// decoder runs on real codestream data. `readGroupOffsets` turns the sizes into
// absolute offsets, applying any permutation.

import Foundation

private let kPermutationContexts = 8

@inline(__always)
private func valueOfLowest1Bit(_ x: UInt32) -> UInt32 { x & (0 &- x) }

/// Token bucket for a permutation value (coeff_order.cc `CoeffOrderContext`).
private func coeffOrderContext(_ val: UInt32) -> Int {
    let (token, _, _) = HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0).encode(val)
    return Int(min(token, UInt32(kPermutationContexts - 1)))
}

/// kTocDist (toc.h): the U32 distribution for section byte sizes.
@inline(__always)
private func readTocSize(_ br: BitReader) -> UInt32 {
    br.readU32(.bits(10), .bits(14, offset: 1024), .bits(22, offset: 17408), .bits(30, offset: 4_211_712))
}

/// Reconstructs a permutation from its Lehmer code (lehmer_code.h).
func decodeLehmerCode(_ code: [UInt32], size n: Int, into permutation: inout [Int]) {
    let log2n = ceilLog2Nonzero(UInt32(n))
    let paddedN = 1 << log2n
    var temp = [UInt32](repeating: 0, count: paddedN)
    for i in 0..<paddedN { temp[i] = valueOfLowest1Bit(UInt32(i + 1)) }

    for i in 0..<n {
        var rank = code[i] + 1
        var bit = paddedN
        var next = 0
        for _ in 0...log2n {
            let cand = next + bit
            bit >>= 1
            if temp[cand - 1] < rank {
                next = cand
                rank -= temp[cand - 1]
            }
        }
        permutation[i] = next
        next += 1
        while next <= paddedN {
            temp[next - 1] -= 1
            next += Int(valueOfLowest1Bit(UInt32(next)))
        }
    }
}

private func readPermutation(
    skip: Int, size: Int, order: inout [Int], br: BitReader, reader: ANSSymbolReader,
    contextMap: [UInt8]
) -> Bool {
    var lehmer = [UInt32](repeating: 0, count: size)
    let end = Int(reader.readHybridUint(coeffOrderContext(UInt32(size)), br, contextMap: contextMap)) + skip
    if end > size { return false }
    var last: UInt32 = 0
    for i in skip..<end {
        lehmer[i] = reader.readHybridUint(coeffOrderContext(last), br, contextMap: contextMap)
        last = lehmer[i]
        if Int(lehmer[i]) >= size - i { return false }
    }
    decodeLehmerCode(lehmer, size: size, into: &order)
    return true
}

private func decodePermutation(_ br: BitReader, skip: Int, size: Int, into order: inout [Int]) -> Bool {
    guard let (code, contextMap) = decodeHistograms(br, numContexts: kPermutationContexts, disallowLZ77: false)
    else { return false }
    let reader = ANSSymbolReader(code: code, reader: br)
    guard readPermutation(skip: skip, size: size, order: &order, br: br, reader: reader, contextMap: contextMap)
    else { return false }
    return reader.checkANSFinalState()
}

/// Reads the TOC (toc.cc `ReadToc`): optional permutation, then byte sizes.
func readToc(_ br: BitReader, tocEntries: Int) -> (sizes: [UInt32], permutation: [Int])? {
    if tocEntries > 65536 || tocEntries == 0 { return nil }
    var sizes = [UInt32](repeating: 0, count: tocEntries)
    var permutation = [Int]()
    if br.read(1) == 1 {
        permutation = [Int](repeating: 0, count: tocEntries)
        guard decodePermutation(br, skip: 0, size: tocEntries, into: &permutation) else { return nil }
    }
    br.alignToByte()
    for i in 0..<tocEntries { sizes[i] = readTocSize(br) }
    br.alignToByte()
    return (sizes, permutation)
}

/// Reads the TOC and turns sizes into absolute offsets (toc.cc `ReadGroupOffsets`).
func readGroupOffsets(_ br: BitReader, tocEntries: Int)
    -> (offsets: [Int], sizes: [UInt32], totalSize: Int)? {
    guard let (sizes0, permutation) = readToc(br, tocEntries: tocEntries) else { return nil }
    var sizes = sizes0
    var offsets = [Int](repeating: 0, count: tocEntries)
    var offset = 0
    for i in 0..<tocEntries {
        offsets[i] = offset
        offset += Int(sizes[i])
    }
    let total = offset
    if !permutation.isEmpty {
        var permutedOffsets = [Int]()
        var permutedSizes = [UInt32]()
        for index in permutation {
            permutedOffsets.append(offsets[index])
            permutedSizes.append(sizes[index])
        }
        offsets = permutedOffsets
        sizes = permutedSizes
    }
    return (offsets, sizes, total)
}
