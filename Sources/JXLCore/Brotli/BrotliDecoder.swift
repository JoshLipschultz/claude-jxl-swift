// BrotliDecoder.swift
//
// A pure-Swift Brotli decompressor (RFC 7932), ported from the reference Java
// decoder (google/brotli v1.1.0, java/org/brotli/dec). Decoding is one-shot:
// the whole input is in memory and the output accumulates in a plain array, so
// the reference implementation's ring buffer and streaming state machine
// collapse into a straight decode loop (backward references index the output
// directly). Only the regular window (10-24 bits) is supported — the
// large-window extension and compound dictionaries are not emitted by any
// encoder we consume (JPEG XL jbrd boxes).
//
// Bit order is LSB-first, identical to the JPEG XL bitstream, so the JXL
// BitReader is reused; reads past the end yield zeros and are caught by the
// stream-health checks below (the format legitimately peeks up to one
// accumulator past the last byte).

import Foundation

enum BrotliError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case outputTooLarge

    var description: String {
        switch self {
        case .malformed(let what): return "Malformed Brotli stream: \(what)"
        case .unsupported(let what): return "Unsupported Brotli feature: \(what)"
        case .outputTooLarge: return "Brotli output exceeds the caller's limit"
        }
    }
}

@_spi(Stages) public enum Brotli {
    /// Decompresses `input`, refusing to produce more than `maxOutputSize`
    /// bytes (hostile-input guard).
    public static func decompress(_ input: [UInt8], maxOutputSize: Int) throws -> [UInt8] {
        let decoder = BrotliDecoder(input: input, maxOutputSize: maxOutputSize)
        return try decoder.decompress()
    }
}

// MARK: - Constants (Decode.java)

private let kCodeLengthCodes = 18
private let kCodeLengthCodeOrder: [Int] = [
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]
private let kNumLiteralCodes = 256
private let kNumCommandCodes = 704
private let kNumBlockLengthCodes = 26
private let kLiteralContextBits = 6
private let kDistanceContextBits = 2
private let kBrotliRootBits = 8
private let kBrotliRootMask = 0xFF
private let kMaxHuffmanTableSize: [Int] = [
    256, 402, 436, 468, 500, 534, 566, 598, 630, 662, 694, 726, 758, 790, 822,
    854, 886, 920, 952, 984, 1016, 1048, 1080,
]
private let kHuffmanTableSize26 = 396
private let kHuffmanTableSize258 = 632
private let kNumDistanceShortCodes = 16
private let kDistanceShortCodeIndexOffset: [Int] = [0, 3, 2, 1, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3]
private let kDistanceShortCodeValueOffset: [Int] = [0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3]
/// Static Huffman code for the code-length code lengths (bits<<16 | value).
private let kFixedTable: [Int32] = [
    0x02_0000, 0x02_0004, 0x02_0003, 0x03_0002, 0x02_0000, 0x02_0004, 0x02_0003, 0x04_0001,
    0x02_0000, 0x02_0004, 0x02_0003, 0x03_0002, 0x02_0000, 0x02_0004, 0x02_0003, 0x04_0005,
]
private let kBlockLengthOffset: [Int] = [
    1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497,
    753, 1265, 2289, 4337, 8433, 16625,
]
private let kBlockLengthNBits: [Int] = [
    2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24,
]
private let kInsertLengthNBits: [Int] = [
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
]
private let kCopyLengthNBits: [Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
]
private let kMaxTransformedWordLength = 5 + 24 + 8
private let kDefaultCodeLength = 8
private let kCodeLengthRepeatCode = 16

/// Each command code unpacks to (insert extra bits, copy extra bits, insert
/// offset, copy offset, distance context) — Decode.java CMD_LOOKUP.
private struct CommandLookup {
    var insertExtraBits: [Int8] = []
    var copyExtraBits: [Int8] = []
    var insertOffset: [Int32] = []
    var copyOffset: [Int32] = []
    var distanceContext: [Int8] = []

    init() {
        var insertLengthOffsets = [Int32](repeating: 0, count: 24)
        var copyLengthOffsets = [Int32](repeating: 0, count: 24)
        copyLengthOffsets[0] = 2
        for i in 0..<23 {
            insertLengthOffsets[i + 1] = insertLengthOffsets[i] + (1 << kInsertLengthNBits[i])
            copyLengthOffsets[i + 1] = copyLengthOffsets[i] + (1 << kCopyLengthNBits[i])
        }
        insertExtraBits.reserveCapacity(kNumCommandCodes)
        for cmdCode in 0..<kNumCommandCodes {
            var rangeIdx = cmdCode >> 6
            var distanceContextOffset = -4
            if rangeIdx >= 2 {
                rangeIdx -= 2
                distanceContextOffset = 0
            }
            let insertCode = (((0x29850 >> (rangeIdx * 2)) & 0x3) << 3) | ((cmdCode >> 3) & 7)
            let copyCode = (((0x26244 >> (rangeIdx * 2)) & 0x3) << 3) | (cmdCode & 7)
            let copyLengthOffset = copyLengthOffsets[copyCode]
            let context = distanceContextOffset + (copyLengthOffset > 4 ? 3 : Int(copyLengthOffset) - 2)
            insertExtraBits.append(Int8(kInsertLengthNBits[insertCode]))
            copyExtraBits.append(Int8(kCopyLengthNBits[copyCode]))
            insertOffset.append(insertLengthOffsets[insertCode])
            copyOffset.append(copyLengthOffsets[copyCode])
            distanceContext.append(Int8(context))
        }
    }
}

private let kCommandLookup = CommandLookup()

// MARK: - Context lookup (Context.java)

private let kContextLookup: [Int32] = {
    var lookup = [Int32](repeating: 0, count: 2048)
    let utfMap =
        "         !!  !                  \"#$##%#$&'##(#)#+++++++++"
        + "+((&*'##,---,---,-----,-----,-----&#'###.///.///./////./////./////&#'# "
    let utfRle = "A/*  ':  & : $  \u{81} @"
    // LSB6, MSB6, SIGNED
    for i in 0..<256 {
        lookup[i] = Int32(i & 0x3F)
        lookup[512 + i] = Int32(i >> 2)
        lookup[1792 + i] = Int32(2 + (i >> 6))
    }
    // UTF8
    let mapScalars = Array(utfMap.unicodeScalars)
    for i in 0..<128 {
        lookup[1024 + i] = Int32(4 * (Int(mapScalars[i].value) - 32))
    }
    for i in 0..<64 {
        lookup[1152 + i] = Int32(i & 1)
        lookup[1216 + i] = Int32(2 + (i & 1))
    }
    var offset = 1280
    let rleScalars = Array(utfRle.unicodeScalars)
    for k in 0..<19 {
        let value = Int32(k & 3)
        let rep = Int(rleScalars[k].value) - 32
        for _ in 0..<rep {
            lookup[offset] = value
            offset += 1
        }
    }
    // SIGNED
    for i in 0..<16 {
        lookup[1792 + i] = 1
        lookup[2032 + i] = 6
    }
    lookup[1792] = 0
    lookup[2047] = 7
    for i in 0..<256 {
        lookup[1536 + i] = lookup[1792 + i] << 3
    }
    return lookup
}()

// MARK: - Word transforms (Transform.java)

private struct BrotliTransforms {
    let numTransforms = 121
    var triplets: [Int] = []
    var prefixSuffixStorage: [UInt8] = []
    var prefixSuffixHeads: [Int] = []

    init() {
        let prefixSuffixSrc =
            "# #s #, #e #.# the #.com/#\u{C2}\u{A0}# of # and"
            + " # in # to #\"#\">#\n#]# for # a # that #. # with #'# from # by #. The # on # as # is #ing"
            + " #\n\t#:#ed #(# at #ly #=\"# of the #. This #,# not #er #al #='#ful #ive #less #est #ize #"
            + "ous #"
        let transformsSrc =
            "     !! ! ,  *!  &!  \" !  ) *   * -  ! # !  #!*!  "
            + "+  ,$ !  -  %  .  / #   0  1 .  \"   2  3!*   4%  ! # /   5  6  7  8 0  1 &   $   9 +   : "
            + " ;  < '  !=  >  ?! 4  @ 4  2  &   A *# (   B  C& ) %  ) !*# *-% A +! *.  D! %'  & E *6  F "
            + " G% ! *A *%  H! D  I!+!  J!+   K +- *4! A  L!*4  M  N +6  O!*% +.! K *G  P +%(  ! G *D +D "
            + " Q +# *K!*G!+D!+# +G +A +4!+% +K!+4!*D!+K!*K"
        prefixSuffixHeads = [Int](repeating: 0, count: 51)
        var index = 1
        for scalar in prefixSuffixSrc.unicodeScalars {
            if scalar.value == 35 {  // '#'
                prefixSuffixHeads[index] = prefixSuffixStorage.count
                index += 1
            } else {
                prefixSuffixStorage.append(UInt8(scalar.value & 0xFF))
            }
        }
        triplets = transformsSrc.unicodeScalars.map { Int($0.value) - 32 }
    }
}

private let kTransforms = BrotliTransforms()

private let kOmitFirstLastLimit = 9
private let kIdentityTransform = 0
private let kOmitLastBase = 0
private let kUppercaseFirst = 10
private let kUppercaseAll = 11
private let kOmitFirstBase = 11

/// Applies transform `transformIndex` to the dictionary word at
/// `dict[offset..<offset+len]`, appending the result to `out`. Returns the
/// number of bytes emitted (Transform.java transformDictionaryWord, minus the
/// SHIFT operators, which the 121 RFC transforms never use).
private func transformDictionaryWord(
    _ out: inout [UInt8], dict: [UInt8], offset: Int, len wordLen: Int, transformIndex: Int
) -> Int {
    let start = out.count
    let t = kTransforms.triplets
    let transformOffset = 3 * transformIndex
    let prefixIdx = t[transformOffset]
    let transformType = t[transformOffset + 1]
    let suffixIdx = t[transformOffset + 2]
    var len = wordLen

    var omitFirst = transformType - kOmitFirstBase
    var omitLast = transformType - kOmitLastBase
    if omitFirst < 1 || omitFirst > kOmitFirstLastLimit { omitFirst = 0 }
    if omitLast < 1 || omitLast > kOmitFirstLastLimit { omitLast = 0 }

    // Prefix.
    out.append(
        contentsOf: kTransforms.prefixSuffixStorage[
            kTransforms.prefixSuffixHeads[prefixIdx]..<kTransforms.prefixSuffixHeads[prefixIdx + 1]])

    // Trimmed word.
    var srcOffset = offset
    if omitFirst > len { omitFirst = len }
    srcOffset += omitFirst
    len -= omitFirst
    len -= omitLast
    if len > 0 {
        out.append(contentsOf: dict[srcOffset..<(srcOffset + len)])
    }

    // Ferment (uppercase).
    if transformType == kUppercaseFirst || transformType == kUppercaseAll {
        var uppercaseOffset = out.count - len
        var remaining = transformType == kUppercaseFirst ? min(1, len) : len
        while remaining > 0 {
            let c0 = Int(out[uppercaseOffset])
            if c0 < 0xC0 {
                if c0 >= 97 && c0 <= 122 { out[uppercaseOffset] ^= 32 }
                uppercaseOffset += 1
                remaining -= 1
            } else if c0 < 0xE0 {
                if uppercaseOffset + 1 < out.count { out[uppercaseOffset + 1] ^= 32 }
                uppercaseOffset += 2
                remaining -= 2
            } else {
                if uppercaseOffset + 2 < out.count { out[uppercaseOffset + 2] ^= 5 }
                uppercaseOffset += 3
                remaining -= 3
            }
        }
    }

    // Suffix.
    out.append(
        contentsOf: kTransforms.prefixSuffixStorage[
            kTransforms.prefixSuffixHeads[suffixIdx]..<kTransforms.prefixSuffixHeads[suffixIdx + 1]])

    return out.count - start
}

// MARK: - Huffman table construction (Huffman.java)

private let kMaxHuffmanCodeLength = 15

private func getNextKey(_ key: Int, _ len: Int) -> Int {
    var step = 1 << (len - 1)
    while (key & step) != 0 { step >>= 1 }
    return (key & (step - 1)) + step
}

private func replicateValue(_ table: inout [Int32], _ offset: Int, _ step: Int, _ end0: Int, _ item: Int32) {
    var end = end0
    repeat {
        end -= step
        table[offset + end] = item
    } while end > 0
}

private func nextTableBitSize(_ count: [Int], _ len0: Int, _ rootBits: Int) -> Int {
    var len = len0
    var left = 1 << (len - rootBits)
    while len < kMaxHuffmanCodeLength {
        left -= count[len]
        if left <= 0 { break }
        len += 1
        left <<= 1
    }
    return len - rootBits
}

/// Builds a two-level Huffman lookup table (entries pack bits<<16 | symbol);
/// returns the number of slots used.
private func buildHuffmanTable(
    _ tableGroup: inout [Int32], _ tableIdx: Int, _ rootBits: Int,
    _ codeLengths: [Int], _ codeLengthsSize: Int
) -> Int {
    let tableOffset = Int(tableGroup[tableIdx])
    var sorted = [Int](repeating: 0, count: codeLengthsSize)
    var count = [Int](repeating: 0, count: kMaxHuffmanCodeLength + 1)
    var offset = [Int](repeating: 0, count: kMaxHuffmanCodeLength + 1)

    for symbol in 0..<codeLengthsSize {
        count[codeLengths[symbol]] += 1
    }
    offset[1] = 0
    for len in 1..<kMaxHuffmanCodeLength {
        offset[len + 1] = offset[len] + count[len]
    }
    for symbol in 0..<codeLengthsSize {
        if codeLengths[symbol] != 0 {
            sorted[offset[codeLengths[symbol]]] = symbol
            offset[codeLengths[symbol]] += 1
        }
    }

    var tableBits = rootBits
    var tableSize = 1 << tableBits
    var totalSize = tableSize

    // Special case: code with only one value.
    if offset[kMaxHuffmanCodeLength] == 1 {
        for key in 0..<totalSize {
            tableGroup[tableOffset + key] = Int32(sorted[0])
        }
        return totalSize
    }

    // Root table.
    var key = 0
    var symbol = 0
    var step = 2
    for len in 1...rootBits {
        while count[len] > 0 {
            replicateValue(
                &tableGroup, tableOffset + key, step, tableSize, Int32(len << 16 | sorted[symbol]))
            symbol += 1
            key = getNextKey(key, len)
            count[len] -= 1
        }
        step <<= 1
    }

    // Second-level tables.
    let mask = totalSize - 1
    var low = -1
    var currentOffset = tableOffset
    step = 2
    for len in (rootBits + 1)...kMaxHuffmanCodeLength {
        while count[len] > 0 {
            if (key & mask) != low {
                currentOffset += tableSize
                tableBits = nextTableBitSize(count, len, rootBits)
                tableSize = 1 << tableBits
                totalSize += tableSize
                low = key & mask
                tableGroup[tableOffset + low] =
                    Int32((tableBits + rootBits) << 16 | (currentOffset - tableOffset - low))
            }
            replicateValue(
                &tableGroup, currentOffset + (key >> rootBits), step, tableSize,
                Int32((len - rootBits) << 16 | sorted[symbol]))
            symbol += 1
            key = getNextKey(key, len)
            count[len] -= 1
        }
        step <<= 1
    }
    return totalSize
}

// MARK: - Decoder

private final class BrotliDecoder {
    let br: BitReader
    let maxOutputSize: Int
    var out: [UInt8] = []

    // Distance ring buffer (4 entries) + block-type rings (2 per tree type).
    var rings: [Int] = [16, 15, 11, 4, 0, 0, 0, 0, 0, 0]
    var distRbIdx = 3

    var maxBackwardDistance = 0
    var maxDistance = 0

    // Metablock state.
    var metaBlockLength = 0
    var inputEnd = false
    var isUncompressed = false
    var isMetadata = false

    var numLiteralBlockTypes = 0
    var numCommandBlockTypes = 0
    var numDistanceBlockTypes = 0
    var literalBlockLength = 0
    var commandBlockLength = 0
    var distanceBlockLength = 0

    var blockTrees: [Int32]
    var literalTreeGroup: [Int32] = []
    var commandTreeGroup: [Int32] = []
    var distanceTreeGroup: [Int32] = []

    var contextModes: [UInt8] = []
    var contextMap: [UInt8] = []
    var distContextMap: [UInt8] = []
    var trivialLiteralContext = false
    var literalTreeIdx = 0
    var commandTreeIdx = 0
    var contextMapSlice = 0
    var distContextMapSlice = 0
    var contextLookupOffset1 = 0
    var contextLookupOffset2 = 0

    var distancePostfixBits = 0
    var numDirectDistanceCodes = 0
    var distExtraBits: [UInt8] = []
    var distOffset: [Int32] = []

    init(input: [UInt8], maxOutputSize: Int) {
        br = BitReader(input)
        self.maxOutputSize = maxOutputSize
        blockTrees = [Int32](
            repeating: 0, count: 7 + 3 * (kHuffmanTableSize258 + kHuffmanTableSize26))
        blockTrees[0] = 7
    }

    /// Reads should never march far past the input (peeks may overrun by one
    /// accumulator legitimately).
    private func checkHealth() throws {
        if br.bitPosition > br.bitCount + 64 {
            throw BrotliError.malformed("truncated stream")
        }
    }

    private func ensureCapacity(_ extra: Int) throws {
        if out.count + extra > maxOutputSize { throw BrotliError.outputTooLarge }
    }

    // MARK: Bit-level primitives

    private func readFewBits(_ n: Int) -> Int { Int(br.read(n)) }

    private func decodeVarLenUnsignedByte() -> Int {
        if br.readBool() {
            let n = readFewBits(3)
            if n == 0 { return 1 }
            return readFewBits(n) + (1 << n)
        }
        return 0
    }

    private func readSymbol(_ tableGroup: [Int32], _ tableIdx: Int) -> Int {
        var offset = Int(tableGroup[tableIdx])
        let val = Int(br.peek(kMaxHuffmanCodeLength))
        offset += val & kBrotliRootMask
        let bits = Int(tableGroup[offset]) >> 16
        let sym = Int(tableGroup[offset]) & 0xFFFF
        if bits <= kBrotliRootBits {
            br.skip(bits)
            return sym
        }
        offset += sym
        let mask = (1 << bits) - 1
        offset += (val & mask) >> kBrotliRootBits
        br.skip((Int(tableGroup[offset]) >> 16) + kBrotliRootBits)
        return Int(tableGroup[offset]) & 0xFFFF
    }

    private func readBlockLength(_ tableGroup: [Int32], _ tableIdx: Int) -> Int {
        let code = readSymbol(tableGroup, tableIdx)
        return kBlockLengthOffset[code] + readFewBits(kBlockLengthNBits[code])
    }

    // MARK: Huffman code reading (Decode.java)

    private func readHuffmanCodeLengths(
        _ codeLengthCodeLengths: [Int], _ numSymbols: Int, _ codeLengths: inout [Int]
    ) throws {
        var symbol = 0
        var prevCodeLen = kDefaultCodeLength
        var repeatCount = 0
        var repeatCodeLen = 0
        var space = 32768
        var table = [Int32](repeating: 0, count: 32 + 1)
        let tableIdx = table.count - 1
        table[tableIdx] = 0
        _ = buildHuffmanTable(&table, tableIdx, 5, codeLengthCodeLengths, kCodeLengthCodes)

        while symbol < numSymbols && space > 0 {
            try checkHealth()
            let p = Int(br.peek(5)) & 31
            br.skip(Int(table[p]) >> 16)
            let codeLen = Int(table[p]) & 0xFFFF
            if codeLen < kCodeLengthRepeatCode {
                repeatCount = 0
                codeLengths[symbol] = codeLen
                symbol += 1
                if codeLen != 0 {
                    prevCodeLen = codeLen
                    space -= 32768 >> codeLen
                }
            } else {
                let extraBits = codeLen - 14
                var newLen = 0
                if codeLen == kCodeLengthRepeatCode { newLen = prevCodeLen }
                if repeatCodeLen != newLen {
                    repeatCount = 0
                    repeatCodeLen = newLen
                }
                let oldRepeat = repeatCount
                if repeatCount > 0 {
                    repeatCount -= 2
                    repeatCount <<= extraBits
                }
                repeatCount += readFewBits(extraBits) + 3
                let repeatDelta = repeatCount - oldRepeat
                if symbol + repeatDelta > numSymbols {
                    throw BrotliError.malformed("code length repeat overflow")
                }
                for _ in 0..<repeatDelta {
                    codeLengths[symbol] = repeatCodeLen
                    symbol += 1
                }
                if repeatCodeLen != 0 {
                    space -= repeatDelta << (15 - repeatCodeLen)
                }
            }
        }
        if space != 0 { throw BrotliError.malformed("unused code length space") }
        while symbol < numSymbols {
            codeLengths[symbol] = 0
            symbol += 1
        }
    }

    private func readSimpleHuffmanCode(
        _ alphabetSizeMax: Int, _ alphabetSizeLimit: Int,
        _ tableGroup: inout [Int32], _ tableIdx: Int
    ) throws -> Int {
        var codeLengths = [Int](repeating: 0, count: alphabetSizeLimit)
        var symbols = [Int](repeating: 0, count: 4)
        let maxBits = 1 + log2floor(alphabetSizeMax - 1)
        let numSymbols = readFewBits(2) + 1
        for i in 0..<numSymbols {
            let symbol = readFewBits(maxBits)
            guard symbol < alphabetSizeLimit else {
                throw BrotliError.malformed("simple Huffman symbol out of range")
            }
            symbols[i] = symbol
        }
        for i in 0..<(numSymbols - 1) {
            for j in (i + 1)..<numSymbols where symbols[i] == symbols[j] {
                throw BrotliError.malformed("duplicate simple Huffman symbol")
            }
        }
        var histogramId = numSymbols
        if numSymbols == 4 { histogramId += readFewBits(1) }
        switch histogramId {
        case 1:
            codeLengths[symbols[0]] = 1
        case 2:
            codeLengths[symbols[0]] = 1
            codeLengths[symbols[1]] = 1
        case 3:
            codeLengths[symbols[0]] = 1
            codeLengths[symbols[1]] = 2
            codeLengths[symbols[2]] = 2
        case 4:
            for i in 0..<4 { codeLengths[symbols[i]] = 2 }
        case 5:
            codeLengths[symbols[0]] = 1
            codeLengths[symbols[1]] = 2
            codeLengths[symbols[2]] = 3
            codeLengths[symbols[3]] = 3
        default:
            break
        }
        return buildHuffmanTable(&tableGroup, tableIdx, kBrotliRootBits, codeLengths, alphabetSizeLimit)
    }

    private func readComplexHuffmanCode(
        _ alphabetSizeLimit: Int, _ skip: Int, _ tableGroup: inout [Int32], _ tableIdx: Int
    ) throws -> Int {
        var codeLengths = [Int](repeating: 0, count: alphabetSizeLimit)
        var codeLengthCodeLengths = [Int](repeating: 0, count: kCodeLengthCodes)
        var space = 32
        var numCodes = 0
        var i = skip
        while i < kCodeLengthCodes && space > 0 {
            let codeLenIdx = kCodeLengthCodeOrder[i]
            let p = Int(br.peek(4)) & 15
            br.skip(Int(kFixedTable[p]) >> 16)
            let v = Int(kFixedTable[p]) & 0xFFFF
            codeLengthCodeLengths[codeLenIdx] = v
            if v != 0 {
                space -= 32 >> v
                numCodes += 1
            }
            i += 1
        }
        if space != 0 && numCodes != 1 {
            throw BrotliError.malformed("corrupted Huffman code histogram")
        }
        try readHuffmanCodeLengths(codeLengthCodeLengths, alphabetSizeLimit, &codeLengths)
        return buildHuffmanTable(&tableGroup, tableIdx, kBrotliRootBits, codeLengths, alphabetSizeLimit)
    }

    private func readHuffmanCode(
        _ alphabetSizeMax: Int, _ alphabetSizeLimit: Int,
        _ tableGroup: inout [Int32], _ tableIdx: Int
    ) throws -> Int {
        try checkHealth()
        let simpleCodeOrSkip = readFewBits(2)
        if simpleCodeOrSkip == 1 {
            return try readSimpleHuffmanCode(alphabetSizeMax, alphabetSizeLimit, &tableGroup, tableIdx)
        }
        return try readComplexHuffmanCode(alphabetSizeLimit, simpleCodeOrSkip, &tableGroup, tableIdx)
    }

    private func decodeContextMap(_ contextMapSize: Int, _ contextMap: inout [UInt8]) throws -> Int {
        let numTrees = decodeVarLenUnsignedByte() + 1
        if numTrees == 1 {
            for i in 0..<contextMapSize { contextMap[i] = 0 }
            return numTrees
        }
        let useRleForZeros = readFewBits(1)
        var maxRunLengthPrefix = 0
        if useRleForZeros != 0 {
            maxRunLengthPrefix = readFewBits(4) + 1
        }
        let alphabetSize = numTrees + maxRunLengthPrefix
        let tableSize = kMaxHuffmanTableSize[(alphabetSize + 31) >> 5]
        var table = [Int32](repeating: 0, count: tableSize + 1)
        let tableIdx = table.count - 1
        table[tableIdx] = 0
        _ = try readHuffmanCode(alphabetSize, alphabetSize, &table, tableIdx)
        var i = 0
        while i < contextMapSize {
            try checkHealth()
            let code = readSymbol(table, tableIdx)
            if code == 0 {
                contextMap[i] = 0
                i += 1
            } else if code <= maxRunLengthPrefix {
                var reps = (1 << code) + readFewBits(code)
                while reps != 0 {
                    guard i < contextMapSize else {
                        throw BrotliError.malformed("corrupted context map")
                    }
                    contextMap[i] = 0
                    i += 1
                    reps -= 1
                }
            } else {
                contextMap[i] = UInt8(code - maxRunLengthPrefix)
                i += 1
            }
        }
        if readFewBits(1) == 1 {
            inverseMoveToFrontTransform(&contextMap, contextMapSize)
        }
        return numTrees
    }

    private func inverseMoveToFrontTransform(_ v: inout [UInt8], _ vLen: Int) {
        var mtf = [Int](0..<256)
        for i in 0..<vLen {
            let index = Int(v[i])
            v[i] = UInt8(mtf[index])
            if index != 0 {
                let value = mtf[index]
                var j = index
                while j > 0 {
                    mtf[j] = mtf[j - 1]
                    j -= 1
                }
                mtf[0] = value
            }
        }
    }

    // MARK: Metablock structure

    private func decodeMetaBlockLength() throws {
        inputEnd = br.readBool()
        metaBlockLength = 0
        isUncompressed = false
        isMetadata = false
        if inputEnd && br.readBool() { return }
        let sizeNibbles = readFewBits(2) + 4
        if sizeNibbles == 7 {
            isMetadata = true
            if br.readBool() { throw BrotliError.malformed("corrupted reserved bit") }
            let sizeBytes = readFewBits(2)
            if sizeBytes == 0 { return }
            for i in 0..<sizeBytes {
                let bits = readFewBits(8)
                if bits == 0 && i + 1 == sizeBytes && sizeBytes > 1 {
                    throw BrotliError.malformed("exuberant nibble")
                }
                metaBlockLength |= bits << (i * 8)
            }
        } else {
            for i in 0..<sizeNibbles {
                let bits = readFewBits(4)
                if bits == 0 && i + 1 == sizeNibbles && sizeNibbles > 4 {
                    throw BrotliError.malformed("exuberant nibble")
                }
                metaBlockLength |= bits << (i * 4)
            }
        }
        metaBlockLength += 1
        if !inputEnd {
            isUncompressed = readFewBits(1) != 0
        }
    }

    private func readMetablockPartition(_ treeType: Int, _ numBlockTypes: Int) throws -> Int {
        var offset = Int(blockTrees[2 * treeType])
        if numBlockTypes <= 1 {
            blockTrees[2 * treeType + 1] = Int32(offset)
            blockTrees[2 * treeType + 2] = Int32(offset)
            return 1 << 28
        }
        let blockTypeAlphabetSize = numBlockTypes + 2
        offset += try readHuffmanCode(
            blockTypeAlphabetSize, blockTypeAlphabetSize, &blockTrees, 2 * treeType)
        blockTrees[2 * treeType + 1] = Int32(offset)
        offset += try readHuffmanCode(
            kNumBlockLengthCodes, kNumBlockLengthCodes, &blockTrees, 2 * treeType + 1)
        blockTrees[2 * treeType + 2] = Int32(offset)
        return readBlockLength(blockTrees, 2 * treeType + 1)
    }

    private func decodeHuffmanTreeGroup(
        _ alphabetSizeMax: Int, _ alphabetSizeLimit: Int, _ n: Int
    ) throws -> [Int32] {
        let maxTableSize = kMaxHuffmanTableSize[(alphabetSizeLimit + 31) >> 5]
        var group = [Int32](repeating: 0, count: n + n * maxTableSize)
        var next = n
        for i in 0..<n {
            group[i] = Int32(next)
            next += try readHuffmanCode(alphabetSizeMax, alphabetSizeLimit, &group, i)
        }
        return group
    }

    private func calculateDistanceLut(_ alphabetSizeLimit: Int) {
        let npostfix = distancePostfixBits
        let ndirect = numDirectDistanceCodes
        let postfix = 1 << npostfix
        var bits = 1
        var half = 0
        var i = kNumDistanceShortCodes
        distExtraBits = [UInt8](repeating: 0, count: alphabetSizeLimit)
        distOffset = [Int32](repeating: 0, count: alphabetSizeLimit)
        for j in 0..<ndirect {
            guard i < alphabetSizeLimit else { return }
            distExtraBits[i] = 0
            distOffset[i] = Int32(j + 1)
            i += 1
        }
        while i < alphabetSizeLimit {
            let base = ndirect + ((((2 + half) << bits) - 4) << npostfix) + 1
            for j in 0..<postfix {
                guard i < alphabetSizeLimit else { break }
                distExtraBits[i] = UInt8(bits)
                distOffset[i] = Int32(base + j)
                i += 1
            }
            bits += half
            half ^= 1
        }
    }

    private func readMetablockHuffmanCodesAndContextMaps() throws {
        numLiteralBlockTypes = decodeVarLenUnsignedByte() + 1
        literalBlockLength = try readMetablockPartition(0, numLiteralBlockTypes)
        numCommandBlockTypes = decodeVarLenUnsignedByte() + 1
        commandBlockLength = try readMetablockPartition(1, numCommandBlockTypes)
        numDistanceBlockTypes = decodeVarLenUnsignedByte() + 1
        distanceBlockLength = try readMetablockPartition(2, numDistanceBlockTypes)

        try checkHealth()
        distancePostfixBits = readFewBits(2)
        numDirectDistanceCodes = readFewBits(4) << distancePostfixBits
        contextModes = [UInt8](repeating: 0, count: numLiteralBlockTypes)
        for i in 0..<numLiteralBlockTypes {
            contextModes[i] = UInt8(readFewBits(2))
        }

        contextMap = [UInt8](repeating: 0, count: numLiteralBlockTypes << kLiteralContextBits)
        let numLiteralTrees = try decodeContextMap(
            numLiteralBlockTypes << kLiteralContextBits, &contextMap)
        trivialLiteralContext = true
        for j in 0..<(numLiteralBlockTypes << kLiteralContextBits) {
            if Int(contextMap[j]) != j >> kLiteralContextBits {
                trivialLiteralContext = false
                break
            }
        }

        distContextMap = [UInt8](repeating: 0, count: numDistanceBlockTypes << kDistanceContextBits)
        let numDistTrees = try decodeContextMap(
            numDistanceBlockTypes << kDistanceContextBits, &distContextMap)

        literalTreeGroup = try decodeHuffmanTreeGroup(
            kNumLiteralCodes, kNumLiteralCodes, numLiteralTrees)
        commandTreeGroup = try decodeHuffmanTreeGroup(
            kNumCommandCodes, kNumCommandCodes, numCommandBlockTypes)
        // Regular window: 24 max distance bits.
        let distanceAlphabetSize =
            kNumDistanceShortCodes + numDirectDistanceCodes + 2 * (24 << distancePostfixBits)
        distanceTreeGroup = try decodeHuffmanTreeGroup(
            distanceAlphabetSize, distanceAlphabetSize, numDistTrees)
        calculateDistanceLut(distanceAlphabetSize)

        contextMapSlice = 0
        distContextMapSlice = 0
        contextLookupOffset1 = Int(contextModes[0]) << 9
        contextLookupOffset2 = contextLookupOffset1 + 256
        literalTreeIdx = 0
        commandTreeIdx = 0
        rings[4] = 1
        rings[5] = 0
        rings[6] = 1
        rings[7] = 0
        rings[8] = 1
        rings[9] = 0
    }

    private func decodeBlockTypeAndLength(_ treeType: Int, _ numBlockTypes: Int) -> Int {
        let offset = 4 + treeType * 2
        var blockType = readSymbol(blockTrees, 2 * treeType)
        let result = readBlockLength(blockTrees, 2 * treeType + 1)
        if blockType == 1 {
            blockType = rings[offset + 1] + 1
        } else if blockType == 0 {
            blockType = rings[offset]
        } else {
            blockType -= 2
        }
        if blockType >= numBlockTypes {
            blockType -= numBlockTypes
        }
        rings[offset] = rings[offset + 1]
        rings[offset + 1] = blockType
        return result
    }

    private func decodeLiteralBlockSwitch() {
        literalBlockLength = decodeBlockTypeAndLength(0, numLiteralBlockTypes)
        let literalBlockType = rings[5]
        contextMapSlice = literalBlockType << kLiteralContextBits
        literalTreeIdx = Int(contextMap[contextMapSlice])
        let contextMode = Int(contextModes[literalBlockType])
        contextLookupOffset1 = contextMode << 9
        contextLookupOffset2 = contextLookupOffset1 + 256
    }

    private func decodeCommandBlockSwitch() {
        commandBlockLength = decodeBlockTypeAndLength(1, numCommandBlockTypes)
        commandTreeIdx = rings[7]
    }

    private func decodeDistanceBlockSwitch() {
        distanceBlockLength = decodeBlockTypeAndLength(2, numDistanceBlockTypes)
        distContextMapSlice = rings[9] << kDistanceContextBits
    }

    // MARK: Dictionary references

    private func useDictionary(distance: Int, copyLength: Int) throws {
        let address = distance - maxDistance - 1
        guard address >= 0 else {
            throw BrotliError.unsupported("compound dictionary reference")
        }
        let wordLength = copyLength
        guard wordLength >= BrotliDictionary.minDictionaryWordLength,
            wordLength <= BrotliDictionary.maxDictionaryWordLength
        else { throw BrotliError.malformed("invalid dictionary word length") }
        let shift = BrotliDictionary.sizeBits[wordLength]
        guard shift != 0 else { throw BrotliError.malformed("invalid dictionary word length") }
        var offset = BrotliDictionary.offsetsByLength[wordLength]
        let mask = (1 << shift) - 1
        let wordIdx = address & mask
        let transformIdx = address >> shift
        offset += wordIdx * wordLength
        guard transformIdx < kTransforms.numTransforms else {
            throw BrotliError.malformed("invalid dictionary transform")
        }
        try ensureCapacity(kMaxTransformedWordLength)
        let len = transformDictionaryWord(
            &out, dict: BrotliDictionary.data, offset: offset, len: wordLength,
            transformIndex: transformIdx)
        metaBlockLength -= len
    }

    // MARK: Top level

    private func decodeWindowBits() throws -> Int {
        if readFewBits(1) == 0 { return 16 }
        var n = readFewBits(3)
        if n != 0 { return 17 + n }
        n = readFewBits(3)
        if n != 0 {
            if n == 1 {
                throw BrotliError.unsupported("large-window stream")
            }
            return 8 + n
        }
        return 17
    }

    func decompress() throws -> [UInt8] {
        let windowBits = try decodeWindowBits()
        maxBackwardDistance = (1 << windowBits) - 16
        maxDistance = 0

        while true {
            guard metaBlockLength == 0 else { throw BrotliError.malformed("metablock length") }
            try checkHealth()
            try decodeMetaBlockLength()
            if inputEnd && metaBlockLength == 0 && !isMetadata { break }

            if isMetadata {
                br.alignToByte()
                br.skip(metaBlockLength * 8)
                metaBlockLength = 0
                if inputEnd { break }
                continue
            }
            if metaBlockLength == 0 {
                if inputEnd { break }
                continue
            }

            if isUncompressed {
                br.alignToByte()
                try ensureCapacity(metaBlockLength)
                for _ in 0..<metaBlockLength {
                    out.append(UInt8(truncatingIfNeeded: br.read(8)))
                }
                try checkHealth()
                metaBlockLength = 0
                if inputEnd { break }
                continue
            }

            try readMetablockHuffmanCodesAndContextMaps()
            try decodeCompressedMetablock()
            if inputEnd { break }
        }

        br.alignToByte()
        try checkHealth()
        return out
    }

    private func decodeCompressedMetablock() throws {
        while metaBlockLength > 0 {
            try checkHealth()
            if commandBlockLength == 0 { decodeCommandBlockSwitch() }
            commandBlockLength -= 1
            let cmdCode = readSymbol(commandTreeGroup, commandTreeIdx)
            let insertLength =
                Int(kCommandLookup.insertOffset[cmdCode])
                + readFewBits(Int(kCommandLookup.insertExtraBits[cmdCode]))
            let copyLength =
                Int(kCommandLookup.copyOffset[cmdCode])
                + readFewBits(Int(kCommandLookup.copyExtraBits[cmdCode]))
            var distanceCode = Int(kCommandLookup.distanceContext[cmdCode])

            // Insert literals.
            try ensureCapacity(insertLength)
            if trivialLiteralContext {
                for _ in 0..<insertLength {
                    try checkHealth()
                    if literalBlockLength == 0 { decodeLiteralBlockSwitch() }
                    literalBlockLength -= 1
                    out.append(UInt8(readSymbol(literalTreeGroup, literalTreeIdx)))
                }
            } else {
                var prevByte1 = out.count >= 1 ? Int(out[out.count - 1]) : 0
                var prevByte2 = out.count >= 2 ? Int(out[out.count - 2]) : 0
                for _ in 0..<insertLength {
                    try checkHealth()
                    if literalBlockLength == 0 { decodeLiteralBlockSwitch() }
                    let literalContext =
                        Int(kContextLookup[contextLookupOffset1 + prevByte1])
                        | Int(kContextLookup[contextLookupOffset2 + prevByte2])
                    let treeIdx = Int(contextMap[contextMapSlice + literalContext])
                    literalBlockLength -= 1
                    prevByte2 = prevByte1
                    prevByte1 = readSymbol(literalTreeGroup, treeIdx)
                    out.append(UInt8(prevByte1))
                }
            }
            metaBlockLength -= insertLength
            if metaBlockLength <= 0 { continue }

            // Distance.
            var distance: Int
            if distanceCode < 0 {
                distance = rings[distRbIdx]
                distanceCode = -1  // untouched: no ring-buffer roll
            } else {
                if distanceBlockLength == 0 { decodeDistanceBlockSwitch() }
                distanceBlockLength -= 1
                let distTreeIdx = Int(distContextMap[distContextMapSlice + distanceCode])
                distanceCode = readSymbol(distanceTreeGroup, distTreeIdx)
                if distanceCode < kNumDistanceShortCodes {
                    let index = (distRbIdx + kDistanceShortCodeIndexOffset[distanceCode]) & 0x3
                    distance = rings[index] + kDistanceShortCodeValueOffset[distanceCode]
                    guard distance > 0 else {
                        throw BrotliError.malformed("non-positive distance")
                    }
                } else {
                    guard distanceCode < distExtraBits.count else {
                        throw BrotliError.malformed("distance code out of range")
                    }
                    let extraBits = Int(distExtraBits[distanceCode])
                    let bits = readFewBits(extraBits)
                    distance = Int(distOffset[distanceCode]) + (bits << distancePostfixBits)
                }
            }

            maxDistance = min(out.count, maxBackwardDistance)

            if distance > maxDistance {
                // Static dictionary reference.
                guard copyLength <= metaBlockLength + kMaxTransformedWordLength else {
                    throw BrotliError.malformed("dictionary copy too long")
                }
                try useDictionary(distance: distance, copyLength: copyLength)
                if metaBlockLength < 0 {
                    throw BrotliError.malformed("dictionary word overruns metablock")
                }
                continue
            }

            if distanceCode > 0 {
                distRbIdx = (distRbIdx + 1) & 0x3
                rings[distRbIdx] = distance
            }

            guard copyLength <= metaBlockLength else {
                throw BrotliError.malformed("invalid backward reference length")
            }
            try ensureCapacity(copyLength)
            var src = out.count - distance
            for _ in 0..<copyLength {
                out.append(out[src])
                src += 1
            }
            metaBlockLength -= copyLength
        }
    }
}

private func log2floor(_ i0: Int) -> Int {
    var i = i0
    var result = -1
    var step = 16
    while step > 0 {
        if (i >> step) != 0 {
            result += step
            i >>= step
        }
        step >>= 1
    }
    return result + i
}
