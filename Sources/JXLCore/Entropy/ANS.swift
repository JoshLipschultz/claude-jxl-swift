// ANS.swift
//
// The rANS (range Asymmetric Numeral System) entropy decoder — JPEG XL's second
// entropy back-end alongside prefix codes. Ported from libjxl v0.11.2
// (ans_common.cc, dec_ans.cc, dec_ans.h). Symbols are decoded from a 32-bit
// state through an *alias table*: the [0, 4096) range is partitioned into
// equal-size entries, each splitting between two symbols at a `cutoff`. The
// state is renormalized by pulling 16 bits whenever it drops below 2^16.

import Foundation

let ansLogTabSize = 12
let ansTabSize = 1 << ansLogTabSize  // 4096
let ansTabMask = ansTabSize - 1
let ansSignature: UInt32 = 0x13
let ansMaxAlphabetSize = 256

// MARK: - Flat histogram & precision (ans_common.cc / dec_ans.h)

/// Counts that are positive, differ by at most 1, sum to `totalCount`,
/// larger ones first.
func createFlatHistogram(length: Int, totalCount: Int) -> [Int32] {
    let count = totalCount / length
    var result = [Int32](repeating: Int32(count), count: length)
    let rem = totalCount % length
    for i in 0..<rem { result[i] += 1 }
    return result
}

/// Number of bits used to store a histogram count whose floor-log2 is `logcount`.
func getPopulationCountPrecision(_ logcount: UInt32, shift: UInt32) -> UInt32 {
    let r = min(Int(logcount), Int(shift) - Int((UInt32(ansLogTabSize) - logcount) >> 1))
    return r < 0 ? 0 : UInt32(r)
}

// MARK: - Alias table (ans_common.cc / ans_common.h)

struct AliasEntry {
    var cutoff: UInt16 = 0
    var rightValue: UInt16 = 0
    var freq0: UInt16 = 0
    var offsets1: UInt16 = 0
    var freq1XorFreq0: UInt16 = 0
}

struct AliasSymbol {
    var value: Int
    var offset: Int
    var freq: Int
}

/// Constant-time mapping of a slot in [0, 4096) to (symbol, within-symbol offset,
/// frequency). Mirrors `AliasTable::Lookup`.
@inline(__always)
func aliasLookup(
    _ table: UnsafePointer<AliasEntry>, base: Int, value: Int, logEntrySize: Int,
    entrySizeMinus1: Int
) -> AliasSymbol {
    let i = value >> logEntrySize
    let pos = value & entrySizeMinus1
    let e = table[base + i]
    let greater = pos >= Int(e.cutoff)
    let offsets1OrZero = greater ? Int(e.offsets1) : 0
    let freqXorOrZero = greater ? Int(e.freq1XorFreq0) : 0
    return AliasSymbol(
        value: greater ? Int(e.rightValue) : i,
        offset: offsets1OrZero + pos,
        freq: Int(e.freq0) ^ freqXorOrZero)
}

/// Builds the alias table for a frequency distribution (mirrors `InitAliasTable`).
/// `entries` is the (already-allocated) slice for this histogram.
func initAliasTable(distribution dist0: [Int32], logAlphaSize: Int, into table: inout [AliasEntry], base: Int) {
    let range = ansTabSize
    let tableSize = 1 << logAlphaSize
    var distribution = dist0
    while let last = distribution.last, last == 0 { distribution.removeLast() }
    if distribution.isEmpty { distribution.append(Int32(range)) }

    let entrySize = range >> logAlphaSize
    var singleSymbol = -1
    for (sym, v) in distribution.enumerated() where v == Int32(ansTabSize) { singleSymbol = sym }

    if singleSymbol != -1 {
        let sym = UInt16(singleSymbol)
        for i in 0..<tableSize {
            table[base + i] = AliasEntry(
                cutoff: 0, rightValue: sym, freq0: 0,
                offsets1: UInt16(entrySize * i), freq1XorFreq0: UInt16(ansTabSize))
        }
        return
    }

    var underfull: [Int] = []
    var overfull: [Int] = []
    var cutoffs = [Int](repeating: 0, count: tableSize)
    for i in 0..<distribution.count {
        cutoffs[i] = Int(distribution[i])
        if cutoffs[i] > entrySize { overfull.append(i) } else if cutoffs[i] < entrySize {
            underfull.append(i)
        }
    }
    for i in distribution.count..<tableSize {
        cutoffs[i] = 0
        underfull.append(i)
    }

    // Reassign over/underfull (the classic alias-method construction).
    var offsets1 = [Int](repeating: 0, count: tableSize)
    var rightValue = [Int](repeating: 0, count: tableSize)
    while let overfullI = overfull.popLast() {
        let underfullI = underfull.removeLast()
        let underfullBy = entrySize - cutoffs[underfullI]
        cutoffs[overfullI] -= underfullBy
        rightValue[underfullI] = overfullI
        offsets1[underfullI] = cutoffs[overfullI]
        if cutoffs[overfullI] < entrySize {
            underfull.append(overfullI)
        } else if cutoffs[overfullI] > entrySize {
            overfull.append(overfullI)
        }
    }

    for i in 0..<tableSize {
        var entry = AliasEntry()
        if cutoffs[i] == entrySize {
            entry.rightValue = UInt16(i)
            entry.offsets1 = 0
            entry.cutoff = 0
        } else {
            entry.rightValue = UInt16(rightValue[i])
            entry.offsets1 = UInt16(offsets1[i] - cutoffs[i])
            entry.cutoff = UInt16(cutoffs[i])
        }
        let freq0 = i < distribution.count ? Int(distribution[i]) : 0
        let i1 = Int(entry.rightValue)
        let freq1 = i1 < distribution.count ? Int(distribution[i1]) : 0
        entry.freq0 = UInt16(freq0)
        entry.freq1XorFreq0 = UInt16(freq1 ^ freq0)
        table[base + i] = entry
    }
}

// MARK: - Histogram bitstream (dec_ans.cc)

func decodeVarLenUint8(_ br: BitReader) -> Int {
    if br.read(1) == 1 {
        let nbits = Int(br.read(3))
        if nbits == 0 { return 1 }
        return Int(br.read(nbits)) + (1 << nbits)
    }
    return 0
}

func decodeVarLenUint16(_ br: BitReader) -> Int {
    if br.read(1) == 1 {
        let nbits = Int(br.read(4))
        if nbits == 0 { return 1 }
        return Int(br.read(nbits)) + (1 << nbits)
    }
    return 0
}

/// Static prefix code over the histogram log-count alphabet (dec_ans.cc `huff`).
private let kLogCountHuff: [(bits: UInt8, value: UInt8)] = {
    let base: [(UInt8, UInt8)] = [
        (3, 10), (7, 12), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (6, 11), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (7, 13), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (6, 11), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
        (3, 10), (5, 0), (3, 7), (4, 3), (3, 6), (3, 8), (3, 9), (4, 5),
        (3, 10), (4, 4), (3, 7), (4, 1), (3, 6), (3, 8), (3, 9), (4, 2),
    ]
    return base
}()

/// Decodes a symbol frequency distribution (mirrors `ReadHistogram`).
/// Returns nil on malformed input.
func readHistogram(precisionBits: Int, reader br: BitReader) -> [Int32]? {
    let range = 1 << precisionBits
    if br.read(1) == 1 {
        // Simple histogram: 1 or 2 symbols.
        var symbols = [0, 0]
        var maxSymbol = 0
        let numSymbols = Int(br.read(1)) + 1
        for i in 0..<numSymbols {
            symbols[i] = decodeVarLenUint8(br)
            if symbols[i] > maxSymbol { maxSymbol = symbols[i] }
        }
        var counts = [Int32](repeating: 0, count: maxSymbol + 1)
        if numSymbols == 1 {
            counts[symbols[0]] = Int32(range)
        } else {
            if symbols[0] == symbols[1] { return nil }
            counts[symbols[0]] = Int32(br.read(precisionBits))
            counts[symbols[1]] = Int32(range) - counts[symbols[0]]
        }
        return counts
    }

    if br.read(1) == 1 {
        // Flat histogram.
        let alphabetSize = decodeVarLenUint8(br) + 1
        if alphabetSize > range { return nil }
        return createFlatHistogram(length: alphabetSize, totalCount: range)
    }

    // Complex histogram.
    var shift: UInt32 = 0
    let upperBoundLog = floorLog2Nonzero(UInt32(ansLogTabSize + 1))
    var log = 0
    while log < upperBoundLog {
        if br.read(1) == 0 { break }
        log += 1
    }
    shift = (UInt32(br.read(log)) | (1 << log)) - 1
    if shift > UInt32(ansLogTabSize + 1) { return nil }

    let length = decodeVarLenUint8(br) + 3
    var counts = [Int32](repeating: 0, count: length)

    var logcounts = [Int](repeating: 0, count: length)
    var omitLog = -1
    var omitPos = -1
    var same = [Int](repeating: 0, count: length)
    var i = 0
    while i < length {
        let idx = Int(br.peek(7))
        let entry = kLogCountHuff[idx]
        br.skip(Int(entry.bits))
        logcounts[i] = Int(entry.value)
        if logcounts[i] == ansLogTabSize + 1 {
            let rleLength = decodeVarLenUint8(br)
            same[i] = rleLength + 5
            i += rleLength + 3
            i += 1
            continue
        }
        if logcounts[i] > omitLog {
            omitLog = logcounts[i]
            omitPos = i
        }
        i += 1
    }
    if omitPos < 0 { return nil }
    if omitPos + 1 < length && logcounts[omitPos + 1] == ansTabSize + 1 { return nil }

    var prev = 0
    var numsame = 0
    var totalCount = 0
    for j in 0..<length {
        if same[j] != 0 {
            numsame = same[j] - 1
            prev = j > 0 ? Int(counts[j - 1]) : 0
        }
        if numsame > 0 {
            counts[j] = Int32(prev)
            numsame -= 1
        } else {
            let code = UInt32(logcounts[j])
            if j == omitPos {
                totalCount += Int(counts[j])
                continue
            } else if code == 0 {
                continue
            } else if code == 1 {
                counts[j] = 1
            } else {
                let bitcount = getPopulationCountPrecision(code - 1, shift: shift)
                counts[j] =
                    Int32((1 << (code - 1)) | (UInt32(br.read(Int(bitcount))) << (code - 1 - bitcount)))
            }
        }
        totalCount += Int(counts[j])
    }
    counts[omitPos] = Int32(range - totalCount)
    if counts[omitPos] <= 0 { return nil }
    return counts
}
