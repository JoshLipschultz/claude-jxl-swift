// PrefixCode.swift
//
// Canonical prefix (Huffman) codes — one of JPEG XL's two entropy back-ends
// (the other is ANS). This is a faithful port of libjxl v0.11.2
// `BuildHuffmanTable` (huffman_table.cc) and `HuffmanDecodingData`
// (dec_huffman.cc): a two-level lookup table (an 8-bit root table plus
// sub-tables for longer codes), built from per-symbol code lengths. The code
// description in the bitstream comes in two forms — a "simple" code (1–4
// symbols) and a "complex" code whose lengths are themselves prefix-coded.

import Foundation

let kPrefixMaxBits = 15
let kHuffmanTableBits = 8

/// One entry of the decoding table. For root entries with `bits > 8`, `value`
/// is the offset to a second-level sub-table; otherwise `value` is the symbol.
struct HuffmanCode: Equatable {
    var bits: UInt8
    var value: UInt16
}

// MARK: - Table construction (huffman_table.cc)

/// reverse(reverse(key, len) + 1, len): advances the reversed prefix code.
@inline(__always)
private func getNextKey(_ key: Int, _ len: Int) -> Int {
    var step = 1 << (len - 1)
    while (key & step) != 0 { step >>= 1 }
    return (key & (step - 1)) + step
}

/// Stores `code` at table[end-step], table[end-2*step], … (end is a multiple of step).
@inline(__always)
private func replicateValue(_ table: inout [HuffmanCode], _ base: Int, step: Int, end: Int, _ code: HuffmanCode) {
    var e = end
    repeat {
        e -= step
        table[base + e] = code
    } while e > 0
}

/// Width of the next 2nd-level table given remaining bit-length histogram.
private func nextTableBitSize(_ count: [UInt16], _ length: Int, _ rootBits: Int) -> Int {
    var len = length
    var left = 1 << (len - rootBits)
    while len < kPrefixMaxBits {
        if left <= Int(count[len]) { break }
        left -= Int(count[len])
        len += 1
        left <<= 1
    }
    return len - rootBits
}

/// Builds the two-level lookup table from code lengths (in symbol order).
/// `count` is the histogram of lengths (mutated). Returns the populated size,
/// or 0 on error.
@discardableResult
func buildHuffmanTable(_ table: inout [HuffmanCode], rootBits: Int,
                       codeLengths: [UInt8], count: inout [UInt16]) -> Int {
    let codeLengthsSize = codeLengths.count
    if codeLengthsSize > (1 << kPrefixMaxBits) { return 0 }

    var offset = [Int](repeating: 0, count: kPrefixMaxBits + 1)
    var maxLength = 1

    var sum = 0
    for len in 1...kPrefixMaxBits {
        offset[len] = sum
        if count[len] != 0 {
            sum += Int(count[len])
            maxLength = len
        }
    }

    var sorted = [UInt16](repeating: 0, count: max(1, codeLengthsSize))
    for symbol in 0..<codeLengthsSize {
        let cl = Int(codeLengths[symbol])
        if cl != 0 {
            sorted[offset[cl]] = UInt16(symbol)
            offset[cl] += 1
        }
    }

    var tableOffset = 0
    var tableBits = rootBits
    var tableSize = 1 << tableBits
    let totalRootSize = tableSize
    var totalSize = tableSize

    // Special case: a code with a single symbol.
    if offset[kPrefixMaxBits] == 1 {
        let code = HuffmanCode(bits: 0, value: sorted[0])
        for key in 0..<totalSize { table[key] = code }
        return totalSize
    }

    // Fill the root table.
    if tableBits > maxLength {
        tableBits = maxLength
        tableSize = 1 << tableBits
    }
    var key = 0
    var symbol = 0
    var codeBits = 1
    var step = 2
    repeat {
        while count[codeBits] != 0 {
            let code = HuffmanCode(bits: UInt8(codeBits), value: sorted[symbol])
            symbol += 1
            replicateValue(&table, tableOffset + key, step: step, end: tableSize, code)
            key = getNextKey(key, codeBits)
            count[codeBits] -= 1
        }
        step <<= 1
        codeBits += 1
    } while codeBits <= tableBits

    // Replicate the partial root table up to the full root size.
    while totalSize != tableSize {
        for i in 0..<tableSize { table[tableSize + i] = table[i] }
        tableSize <<= 1
    }

    // Fill 2nd-level tables and link them from the root.
    let mask = totalRootSize - 1
    var low = -1
    var len = rootBits + 1
    step = 2
    while len <= maxLength {
        while count[len] != 0 {
            if (key & mask) != low {
                tableOffset += tableSize
                tableBits = nextTableBitSize(count, len, rootBits)
                tableSize = 1 << tableBits
                totalSize += tableSize
                low = key & mask
                table[low].bits = UInt8(tableBits + rootBits)
                table[low].value = UInt16(tableOffset - low)
            }
            let code = HuffmanCode(bits: UInt8(len - rootBits), value: sorted[symbol])
            symbol += 1
            replicateValue(&table, tableOffset + (key >> rootBits), step: step, end: tableSize, code)
            key = getNextKey(key, len)
            count[len] -= 1
        }
        len += 1
        step <<= 1
    }

    return totalSize
}

// MARK: - Bitstream reading (dec_huffman.cc)

private let kCodeLengthCodes = 18
private let kCodeLengthCodeOrder: [Int] = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
private let kDefaultCodeLength: UInt8 = 8
private let kCodeLengthRepeatCode = 16

/// Static prefix code for the code-length-code lengths (dec_huffman.cc `huff`).
private let kCodeLengthStaticTable: [HuffmanCode] = [
    HuffmanCode(bits: 2, value: 0), HuffmanCode(bits: 2, value: 4),
    HuffmanCode(bits: 2, value: 3), HuffmanCode(bits: 3, value: 2),
    HuffmanCode(bits: 2, value: 0), HuffmanCode(bits: 2, value: 4),
    HuffmanCode(bits: 2, value: 3), HuffmanCode(bits: 4, value: 1),
    HuffmanCode(bits: 2, value: 0), HuffmanCode(bits: 2, value: 4),
    HuffmanCode(bits: 2, value: 3), HuffmanCode(bits: 3, value: 2),
    HuffmanCode(bits: 2, value: 0), HuffmanCode(bits: 2, value: 4),
    HuffmanCode(bits: 2, value: 3), HuffmanCode(bits: 4, value: 5),
]

public struct PrefixCode {
    var table: [HuffmanCode]

    /// Wraps a pre-built decode table (used by tests and internal callers).
    init(table: [HuffmanCode]) {
        self.table = table
    }

    /// Reads a prefix-code description for `alphabetSize` symbols. Returns nil on
    /// an invalid description.
    public init?(reader: BitReader, alphabetSize: Int) {
        if alphabetSize > (1 << kPrefixMaxBits) { return nil }

        let simpleOrSkip = Int(reader.read(2))
        if simpleOrSkip == 1 {
            var t = [HuffmanCode](repeating: HuffmanCode(bits: 0, value: 0), count: 1 << kHuffmanTableBits)
            if !PrefixCode.readSimpleCode(alphabetSize: alphabetSize, reader: reader, table: &t) {
                return nil
            }
            self.table = t
            return
        }

        // Complex code: read code-length-code lengths, then the per-symbol lengths.
        var codeLengthCodeLengths = [UInt8](repeating: 0, count: kCodeLengthCodes)
        var space = 32
        var numCodes = 0
        var i = simpleOrSkip
        while i < kCodeLengthCodes && space > 0 {
            let idx = kCodeLengthCodeOrder[i]
            let p = Int(reader.peek(4))
            let entry = kCodeLengthStaticTable[p]
            reader.skip(Int(entry.bits))
            let v = UInt8(entry.value)
            codeLengthCodeLengths[idx] = v
            if v != 0 {
                space -= 32 >> Int(v)
                numCodes += 1
            }
            i += 1
        }

        var codeLengths = [UInt8](repeating: 0, count: alphabetSize)
        let ok =
            (numCodes == 1 || space == 0)
            && PrefixCode.readHuffmanCodeLengths(
                codeLengthCodeLengths, numSymbols: alphabetSize, codeLengths: &codeLengths,
                reader: reader)
        if !ok { return nil }

        var count = [UInt16](repeating: 0, count: 16)
        for c in codeLengths { count[Int(c)] += 1 }
        var t = [HuffmanCode](repeating: HuffmanCode(bits: 0, value: 0), count: alphabetSize + 376)
        let size = buildHuffmanTable(&t, rootBits: kHuffmanTableBits, codeLengths: codeLengths, count: &count)
        if size == 0 { return nil }
        t.removeLast(t.count - size)
        self.table = t
    }

    /// Decodes the next symbol from the stream.
    public func readSymbol(_ reader: BitReader) -> UInt16 {
        var pos = Int(reader.peek(kHuffmanTableBits))
        var nBits = Int(table[pos].bits)
        if nBits > kHuffmanTableBits {
            reader.skip(kHuffmanTableBits)
            nBits -= kHuffmanTableBits
            pos = pos + Int(table[pos].value) + Int(reader.peek(nBits))
        }
        reader.skip(Int(table[pos].bits))
        return table[pos].value
    }

    // MARK: Simple code (1–4 explicit symbols)

    private static func readSimpleCode(alphabetSize: Int, reader: BitReader, table: inout [HuffmanCode])
        -> Bool {
        let maxBits = alphabetSize > 1 ? floorLog2Nonzero(UInt32(alphabetSize - 1)) + 1 : 0
        var numSymbols = Int(reader.read(2)) + 1

        var symbols = [Int](repeating: 0, count: 4)
        for i in 0..<numSymbols {
            let s = Int(reader.read(maxBits))
            if s >= alphabetSize { return false }
            symbols[i] = s
        }
        for i in 0..<(numSymbols - 1) {
            for j in (i + 1)..<numSymbols where symbols[i] == symbols[j] { return false }
        }
        if numSymbols == 4 { numSymbols += Int(reader.read(1)) }

        func swap(_ i: Int, _ j: Int) { symbols.swapAt(i, j) }

        var tableSize = 1
        switch numSymbols {
        case 1:
            table[0] = HuffmanCode(bits: 0, value: UInt16(symbols[0]))
        case 2:
            if symbols[0] > symbols[1] { swap(0, 1) }
            table[0] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[1] = HuffmanCode(bits: 1, value: UInt16(symbols[1]))
            tableSize = 2
        case 3:
            if symbols[1] > symbols[2] { swap(1, 2) }
            table[0] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[2] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[1] = HuffmanCode(bits: 2, value: UInt16(symbols[1]))
            table[3] = HuffmanCode(bits: 2, value: UInt16(symbols[2]))
            tableSize = 4
        case 4:
            for i in 0..<3 {
                for j in (i + 1)..<4 where symbols[i] > symbols[j] { swap(i, j) }
            }
            table[0] = HuffmanCode(bits: 2, value: UInt16(symbols[0]))
            table[2] = HuffmanCode(bits: 2, value: UInt16(symbols[1]))
            table[1] = HuffmanCode(bits: 2, value: UInt16(symbols[2]))
            table[3] = HuffmanCode(bits: 2, value: UInt16(symbols[3]))
            tableSize = 4
        case 5:
            if symbols[2] > symbols[3] { swap(2, 3) }
            table[0] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[1] = HuffmanCode(bits: 2, value: UInt16(symbols[1]))
            table[2] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[3] = HuffmanCode(bits: 3, value: UInt16(symbols[2]))
            table[4] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[5] = HuffmanCode(bits: 2, value: UInt16(symbols[1]))
            table[6] = HuffmanCode(bits: 1, value: UInt16(symbols[0]))
            table[7] = HuffmanCode(bits: 3, value: UInt16(symbols[3]))
            tableSize = 8
        default:
            return false
        }

        let goalSize = 1 << kHuffmanTableBits
        while tableSize != goalSize {
            for i in 0..<tableSize { table[tableSize + i] = table[i] }
            tableSize <<= 1
        }
        return true
    }

    // MARK: Complex code lengths (with repeat codes)

    private static func readHuffmanCodeLengths(
        _ codeLengthCodeLengths: [UInt8], numSymbols: Int, codeLengths: inout [UInt8],
        reader: BitReader
    ) -> Bool {
        var symbol = 0
        var prevCodeLen = kDefaultCodeLength
        var repeatCount = 0
        var repeatCodeLen: UInt8 = 0
        var space = 32768

        var counts = [UInt16](repeating: 0, count: 16)
        for i in 0..<kCodeLengthCodes { counts[Int(codeLengthCodeLengths[i])] += 1 }
        var table = [HuffmanCode](repeating: HuffmanCode(bits: 0, value: 0), count: 32)
        if buildHuffmanTable(&table, rootBits: 5, codeLengths: codeLengthCodeLengths, count: &counts) == 0 {
            return false
        }

        while symbol < numSymbols && space > 0 {
            let p = Int(reader.peek(5))
            let entry = table[p]
            reader.skip(Int(entry.bits))
            let codeLen = UInt8(entry.value)
            if Int(codeLen) < kCodeLengthRepeatCode {
                repeatCount = 0
                codeLengths[symbol] = codeLen
                symbol += 1
                if codeLen != 0 {
                    prevCodeLen = codeLen
                    space -= 32768 >> Int(codeLen)
                }
            } else {
                let extraBits = Int(codeLen) - 14
                var newLen: UInt8 = 0
                if Int(codeLen) == kCodeLengthRepeatCode { newLen = prevCodeLen }
                if repeatCodeLen != newLen {
                    repeatCount = 0
                    repeatCodeLen = newLen
                }
                let oldRepeat = repeatCount
                if repeatCount > 0 {
                    repeatCount -= 2
                    repeatCount <<= extraBits
                }
                repeatCount += Int(reader.read(extraBits)) + 3
                let repeatDelta = repeatCount - oldRepeat
                if symbol + repeatDelta > numSymbols { return false }
                for k in 0..<repeatDelta { codeLengths[symbol + k] = repeatCodeLen }
                symbol += repeatDelta
                if repeatCodeLen != 0 {
                    space -= repeatDelta << (15 - Int(repeatCodeLen))
                }
            }
        }
        if space != 0 { return false }
        for k in symbol..<numSymbols { codeLengths[k] = 0 }
        return true
    }
}
