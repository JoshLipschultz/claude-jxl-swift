// JPEGWriter.swift
//
// Serializes a reconstructed JPEGData back to the original JPEG bytes (libjxl
// jpeg/dec_jpeg_data_writer.cc). The marker sections are emitted in the exact
// order recorded by the jbrd box; entropy-coded scans re-encode the quantized
// DCT coefficients with the original Huffman tables, restart markers, recorded
// padding bits, extra zero runs, and progressive refinement passes, so the
// output is byte-identical to the source JPEG.

import Foundation

private let kJpegPrecision = 8
private let kJPEGNaturalOrderW: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
]

/// Assembled reconstruction input: the jbrd metadata with every
/// codestream-derived field (dimensions, sampling, quant values, coefficients)
/// filled in.
struct JPEGReconAssembled {
    var data: JPEGReconData
    var width = 0
    var height = 0
}

// MARK: - Bit writer (JpegBitWriter)

private struct JpegBitWriter {
    var out: [UInt8] = []
    var putBuffer: UInt64 = 0
    var putBits = 64
    var healthy = true

    /// Emits a byte with JPEG 0xFF stuffing.
    @inline(__always) mutating func emitByte(_ byte: Int) {
        out.append(UInt8(byte))
        if byte == 0xFF { out.append(0) }
    }

    @inline(__always) mutating func writeBits(_ nbits: Int, _ bits: UInt64) {
        guard nbits > 0 else { return }
        putBits -= nbits
        if putBits < 0 {
            if nbits > 64 {
                putBits += nbits
                healthy = false
                return
            }
            // Discharge: top up the buffer, flush 8 bytes, start a new buffer.
            putBuffer |= bits >> UInt64(-putBits)
            if hasZeroByte(~putBuffer) {
                emitByte(Int((putBuffer >> 56) & 0xFF))
                emitByte(Int((putBuffer >> 48) & 0xFF))
                emitByte(Int((putBuffer >> 40) & 0xFF))
                emitByte(Int((putBuffer >> 32) & 0xFF))
                emitByte(Int((putBuffer >> 24) & 0xFF))
                emitByte(Int((putBuffer >> 16) & 0xFF))
                emitByte(Int((putBuffer >> 8) & 0xFF))
                emitByte(Int(putBuffer & 0xFF))
            } else {
                withUnsafeBytes(of: putBuffer.bigEndian) { out.append(contentsOf: $0) }
            }
            putBits += 64
            putBuffer = putBits == 64 ? 0 : bits << UInt64(putBits)
        } else {
            putBuffer |= bits << UInt64(putBits)
        }
    }

    @inline(__always) private func hasZeroByte(_ x: UInt64) -> Bool {
        ((x &- 0x0101_0101_0101_0101) & ~x & 0x8080_8080_8080_8080) != 0
    }

    mutating func emitMarker(_ marker: Int) {
        out.append(0xFF)
        out.append(UInt8(marker))
    }

    /// Pads to a byte boundary using the recorded padding bits when present
    /// (else all-ones), mirroring JumpToByteBoundary.
    mutating func jumpToByteBoundary(_ padBits: inout ArraySlice<Bool>?) -> Bool {
        let nBits = putBits & 7
        var danglingBits = 0
        var padPattern = 0
        if padBits == nil {
            padPattern = (1 << nBits) - 1
        } else {
            var n = nBits
            while n > 0 {
                n -= 1
                padPattern <<= 1
                guard let bit = padBits!.first else { return false }
                padBits = padBits!.dropFirst()
                let b = bit ? 1 : 0
                danglingBits |= b
                padPattern |= b
            }
        }
        if (danglingBits & ~1) != 0 { return false }

        while putBits <= 56 {
            let c = Int((putBuffer >> 56) & 0xFF)
            emitByte(c)
            putBuffer <<= 8
            putBits += 8
        }
        if putBits < 64 {
            let padMask = 0xFF >> (64 - putBits)
            let c = (Int((putBuffer >> 56) & 0xFF) & ~padMask) | padPattern
            emitByte(c)
        }
        putBuffer = 0
        putBits = 64
        return true
    }
}

// MARK: - Huffman table (BuildHuffmanCodeTable)

private struct HuffmanCodeTable {
    /// Bit lengths, 127 sentinel for absent symbols (poisons the bit writer).
    var depth = [Int32](repeating: 127, count: 256)
    var code = [UInt64](repeating: 0, count: 256)
    var initialized = false
}

private func buildHuffmanCodeTable(_ huff: JPEGHuffmanCodeInfo) -> HuffmanCodeTable? {
    var table = HuffmanCodeTable()
    var huffSize = [Int](repeating: 0, count: 257)
    var huffCode = [Int](repeating: 0, count: 256)
    var p = 0
    for l in 1...16 {
        var i = Int(huff.counts[l])
        if p + i > 257 { return nil }
        while i > 0 {
            huffSize[p] = l
            p += 1
            i -= 1
        }
    }
    if p == 0 {
        table.initialized = true
        return table
    }
    let lastP = p - 1
    huffSize[lastP] = 0

    var codeVal = 0
    var si = huffSize[0]
    p = 0
    while huffSize[p] != 0 {
        while huffSize[p] == si {
            huffCode[p] = codeVal
            p += 1
            codeVal += 1
        }
        codeVal <<= 1
        si += 1
    }
    for q in 0..<lastP {
        let i = Int(huff.values[q])
        guard i < 256 else { return nil }
        table.depth[i] = Int32(huffSize[q])
        table.code[i] = UInt64(huffCode[q])
    }
    table.initialized = true
    return table
}

// MARK: - Progressive EOB-run / refinement buffering (DCTCodingState)

private struct DCTCodingState {
    var eobRun = 0
    var curACHuff = -1  // index into acTables
    var refinementBits: [UInt16] = []
    var refinementBitsCount = 0
}

// MARK: - Writer

/// Serializes to the original JPEG bytes.
func writeJPEG(_ assembled: JPEGReconAssembled) throws -> [UInt8] {
    let jpg = assembled.data
    guard !jpg.markerOrder.isEmpty else { throw JXLError.malformed("jbrd: no markers") }

    var bw = JpegBitWriter()
    var dcTables = [HuffmanCodeTable](repeating: HuffmanCodeTable(), count: 4)
    var acTables = [HuffmanCodeTable](repeating: HuffmanCodeTable(), count: 4)
    var padBits: ArraySlice<Bool>? = jpg.hasZeroPaddingBit ? jpg.paddingBits[...] : nil

    var dhtIndex = 0
    var dqtIndex = 0
    var appIndex = 0
    var comIndex = 0
    var dataIndex = 0
    var scanIndex = 0
    var isProgressive = false
    var seenDRI = false

    func writeSymbol(_ symbol: Int, _ table: HuffmanCodeTable) {
        bw.writeBits(Int(table.depth[symbol]), table.code[symbol])
    }

    func flush(_ s: inout DCTCodingState) {
        if s.eobRun > 0 {
            let nbits = 31 - UInt32(s.eobRun).leadingZeroBitCount
            let symbol = Int(nbits) << 4
            writeSymbol(symbol, acTables[s.curACHuff])
            if nbits > 0 {
                bw.writeBits(Int(nbits), UInt64(s.eobRun) & ((1 << UInt64(nbits)) - 1))
            }
            s.eobRun = 0
        }
        let numWords = s.refinementBitsCount >> 4
        for i in 0..<numWords {
            bw.writeBits(16, UInt64(s.refinementBits[i]))
        }
        let tail = s.refinementBitsCount & 0xF
        if tail != 0 {
            bw.writeBits(tail, UInt64(s.refinementBits.last!))
        }
        s.refinementBits.removeAll(keepingCapacity: true)
        s.refinementBitsCount = 0
    }

    func bufferEndOfBand(
        _ s: inout DCTCodingState, _ acHuffIdx: Int, _ newBits: [Int], _ newBitsCount0: Int
    ) {
        if s.eobRun == 0 { s.curACHuff = acHuffIdx }
        s.eobRun += 1
        var newBitsCount = newBitsCount0
        if newBitsCount > 0 {
            var packed: UInt64 = 0
            for i in 0..<newBitsCount {
                packed = (packed << 1) | UInt64(newBits[i])
            }
            let tail = s.refinementBitsCount & 0xF
            if tail != 0 {
                let stuffCount = min(16 - tail, newBitsCount)
                var stuff = UInt16(truncatingIfNeeded: packed >> UInt64(newBitsCount - stuffCount))
                stuff &= UInt16((1 << stuffCount) - 1)
                s.refinementBits[s.refinementBits.count - 1] =
                    (s.refinementBits.last! << UInt16(stuffCount)) | stuff
                newBitsCount -= stuffCount
                s.refinementBitsCount += stuffCount
            }
            while newBitsCount >= 16 {
                s.refinementBits.append(
                    UInt16(truncatingIfNeeded: packed >> UInt64(newBitsCount - 16)))
                newBitsCount -= 16
                s.refinementBitsCount += 16
            }
            if newBitsCount > 0 {
                s.refinementBits.append(UInt16(truncatingIfNeeded: packed) & UInt16((1 << newBitsCount) - 1))
                s.refinementBitsCount += newBitsCount
            }
        }
        if s.eobRun == 0x7FFF { flush(&s) }
    }

    // MARK: block encoders

    func encodeDCTBlockSequential(
        _ coeffs: ArraySlice<Int16>, _ dcHuff: HuffmanCodeTable, _ acHuff: HuffmanCodeTable,
        _ numZeroRuns: Int, _ lastDCCoeff: inout Int16
    ) -> Bool {
        let base = coeffs.startIndex
        var temp2 = Int(coeffs[base])
        var temp = temp2 - Int(lastDCCoeff)
        lastDCCoeff = Int16(truncatingIfNeeded: temp2)
        temp2 = temp >> (Int.bitWidth - 1)
        temp += temp2
        temp2 ^= temp

        let dcNBits = temp2 == 0 ? 0 : (31 - UInt32(truncatingIfNeeded: temp2).leadingZeroBitCount + 1)
        writeSymbol(Int(dcNBits), dcHuff)
        if dcNBits != 0 {
            bw.writeBits(Int(dcNBits), UInt64(truncatingIfNeeded: temp) & ((1 << UInt64(dcNBits)) - 1))
        }
        var r = 0
        var litmus = 0

        for i in 1..<64 {
            temp = Int(coeffs[base + kJPEGNaturalOrderW[i]])
            if temp == 0 {
                r += 1
            } else {
                temp2 = temp >> (Int.bitWidth - 1)
                temp += temp2
                temp2 ^= temp
                if r > 15 {
                    writeSymbol(0xF0, acHuff)
                    r -= 16
                    if r > 15 {
                        writeSymbol(0xF0, acHuff)
                        r -= 16
                    }
                    if r > 15 {
                        writeSymbol(0xF0, acHuff)
                        r -= 16
                    }
                }
                litmus |= temp2
                let acNBits = 31 - UInt32(UInt16(truncatingIfNeeded: temp2)).leadingZeroBitCount + 1
                let symbol = (r << 4) + Int(acNBits)
                // WriteSymbolBits: value bits below the Huffman code.
                bw.writeBits(
                    Int(acNBits) + Int(acHuff.depth[symbol]),
                    (UInt64(truncatingIfNeeded: temp) & ((1 << UInt64(acNBits)) - 1))
                        | (acHuff.code[symbol] << UInt64(acNBits)))
                r = 0
            }
        }
        for _ in 0..<numZeroRuns {
            writeSymbol(0xF0, acHuff)
            r -= 16
        }
        if r > 0 {
            writeSymbol(0, acHuff)
        }
        return litmus >= 0
    }

    func encodeDCTBlockProgressive(
        _ coeffs: ArraySlice<Int16>, _ dcHuff: HuffmanCodeTable, _ acHuffIdx: Int,
        _ ss0: Int, _ se: Int, _ al: Int, _ numZeroRuns: Int,
        _ codingState: inout DCTCodingState, _ lastDCCoeff: inout Int16
    ) -> Bool {
        let base = coeffs.startIndex
        let acHuff = acTables[acHuffIdx]
        let eobRunAllowed = ss0 > 0
        var ss = ss0
        var temp: Int
        var temp2: Int
        if ss == 0 {
            temp2 = Int(coeffs[base]) >> al
            temp = temp2 - Int(lastDCCoeff)
            lastDCCoeff = Int16(truncatingIfNeeded: temp2)
            temp2 = temp
            if temp < 0 {
                temp = -temp
                temp2 -= 1
            }
            let nbits = temp == 0 ? 0 : (31 - UInt32(truncatingIfNeeded: temp).leadingZeroBitCount + 1)
            writeSymbol(Int(nbits), dcHuff)
            if nbits != 0 {
                bw.writeBits(Int(nbits), UInt64(truncatingIfNeeded: temp2) & ((1 << UInt64(nbits)) - 1))
            }
            ss += 1
        }
        if ss > se { return true }
        var r = 0
        for k in ss...se {
            temp = Int(coeffs[base + kJPEGNaturalOrderW[k]])
            if temp == 0 {
                r += 1
                continue
            }
            if temp < 0 {
                temp = -temp
                temp >>= al
                temp2 = ~temp
            } else {
                temp >>= al
                temp2 = temp
            }
            if temp == 0 {
                r += 1
                continue
            }
            flush(&codingState)
            while r > 15 {
                writeSymbol(0xF0, acHuff)
                r -= 16
            }
            let nbits = 31 - UInt32(truncatingIfNeeded: temp).leadingZeroBitCount + 1
            let symbol = (r << 4) + Int(nbits)
            writeSymbol(symbol, acHuff)
            bw.writeBits(Int(nbits), UInt64(truncatingIfNeeded: temp2) & ((1 << UInt64(nbits)) - 1))
            r = 0
        }
        if numZeroRuns > 0 {
            flush(&codingState)
            for _ in 0..<numZeroRuns {
                writeSymbol(0xF0, acHuff)
                r -= 16
            }
        }
        if r > 0 {
            bufferEndOfBand(&codingState, acHuffIdx, [], 0)
            if !eobRunAllowed { flush(&codingState) }
        }
        return true
    }

    func encodeRefinementBits(
        _ coeffs: ArraySlice<Int16>, _ acHuffIdx: Int, _ ss0: Int, _ se: Int, _ al: Int,
        _ codingState: inout DCTCodingState
    ) -> Bool {
        let base = coeffs.startIndex
        let acHuff = acTables[acHuffIdx]
        let eobRunAllowed = ss0 > 0
        var ss = ss0
        if ss == 0 {
            bw.writeBits(1, UInt64((Int(coeffs[base]) >> al) & 1))
            ss += 1
        }
        if ss > se { return true }
        var absValues = [Int](repeating: 0, count: 64)
        var eob = 0
        for k in ss...se {
            let absVal = abs(Int(coeffs[base + kJPEGNaturalOrderW[k]]))
            absValues[k] = absVal >> al
            if absValues[k] == 1 { eob = k }
        }
        var r = 0
        var refinementBits = [Int]()
        for k in ss...se {
            if absValues[k] == 0 {
                r += 1
                continue
            }
            while r > 15 && k <= eob {
                flush(&codingState)
                writeSymbol(0xF0, acHuff)
                r -= 16
                for bit in refinementBits { bw.writeBits(1, UInt64(bit)) }
                refinementBits.removeAll(keepingCapacity: true)
            }
            if absValues[k] > 1 {
                refinementBits.append(absValues[k] & 1)
                continue
            }
            flush(&codingState)
            let symbol = (r << 4) + 1
            let newNonZeroBit = coeffs[base + kJPEGNaturalOrderW[k]] < 0 ? 0 : 1
            writeSymbol(symbol, acHuff)
            bw.writeBits(1, UInt64(newNonZeroBit))
            for bit in refinementBits { bw.writeBits(1, UInt64(bit)) }
            refinementBits.removeAll(keepingCapacity: true)
            r = 0
        }
        if r > 0 || !refinementBits.isEmpty {
            bufferEndOfBand(&codingState, acHuffIdx, refinementBits, refinementBits.count)
            if !eobRunAllowed { flush(&codingState) }
        }
        return true
    }

    // MARK: marker sections

    func encodeSOF(_ marker: UInt8) {
        if marker <= 0xC2 { isProgressive = marker == 0xC2 }
        let nComps = jpg.components.count
        let markerLen = 8 + 3 * nComps
        bw.out.append(contentsOf: [0xFF, marker, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF)])
        bw.out.append(UInt8(kJpegPrecision))
        bw.out.append(UInt8(assembled.height >> 8))
        bw.out.append(UInt8(assembled.height & 0xFF))
        bw.out.append(UInt8(assembled.width >> 8))
        bw.out.append(UInt8(assembled.width & 0xFF))
        bw.out.append(UInt8(nComps))
        for comp in jpg.components {
            bw.out.append(UInt8(comp.id))
            bw.out.append(UInt8((comp.hSampFactor << 4) | comp.vSampFactor))
            bw.out.append(UInt8(jpg.quant[Int(comp.quantIdx)].index))
        }
    }

    func encodeDHT() throws {
        var markerLen = 2
        var i = dhtIndex
        while i < jpg.huffmanCodes.count {
            let huff = jpg.huffmanCodes[i]
            markerLen += 16 + Int(huff.counts.reduce(0, +))
            if huff.isLast { break }
            i += 1
        }
        bw.out.append(contentsOf: [0xFF, 0xC4, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF)])
        while true {
            guard dhtIndex < jpg.huffmanCodes.count else {
                throw JXLError.malformed("jbrd: DHT index out of range")
            }
            let huff = jpg.huffmanCodes[dhtIndex]
            dhtIndex += 1
            var index = Int(huff.slotID)
            guard let table = buildHuffmanCodeTable(huff) else {
                throw JXLError.malformed("jbrd: bad Huffman code")
            }
            if index & 0x10 != 0 {
                index -= 0x10
                acTables[index] = table
            } else {
                dcTables[index] = table
            }
            var totalCount = 0
            var maxLength = 0
            for (l, count) in huff.counts.enumerated() {
                if count != 0 { maxLength = l }
                totalCount += Int(count)
            }
            totalCount -= 1
            bw.out.append(UInt8(huff.slotID))
            for l in 1...16 {
                let c = Int(huff.counts[l])
                bw.out.append(UInt8(l == maxLength ? c - 1 : c))
            }
            for v in 0..<totalCount {
                bw.out.append(UInt8(huff.values[v]))
            }
            if huff.isLast { break }
        }
    }

    func encodeDQT() throws {
        var markerLen = 2
        var i = dqtIndex
        while i < jpg.quant.count {
            let table = jpg.quant[i]
            markerLen += 1 + (table.precision != 0 ? 2 : 1) * 64
            if table.isLast { break }
            i += 1
        }
        bw.out.append(contentsOf: [0xFF, 0xDB, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF)])
        while true {
            guard dqtIndex < jpg.quant.count else {
                throw JXLError.malformed("jbrd: DQT index out of range")
            }
            let table = jpg.quant[dqtIndex]
            dqtIndex += 1
            bw.out.append(UInt8((table.precision << 4) + table.index))
            for i in 0..<64 {
                let val = Int(table.values[kJPEGNaturalOrderW[i]])
                if table.precision != 0 {
                    bw.out.append(UInt8((val >> 8) & 0xFF))
                }
                bw.out.append(UInt8(val & 0xFF))
            }
            if table.isLast { break }
        }
    }

    // MARK: scans

    func encodeScan() throws {
        guard scanIndex < jpg.scans.count else {
            throw JXLError.malformed("jbrd: scan index out of range")
        }
        let scanInfo = jpg.scans[scanIndex]
        scanIndex += 1

        // SOS header.
        let nScans = Int(scanInfo.numComponents)
        let markerLen = 6 + 2 * nScans
        bw.out.append(contentsOf: [0xFF, 0xDA, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF)])
        bw.out.append(UInt8(nScans))
        for i in 0..<nScans {
            let si = scanInfo.components[i]
            bw.out.append(UInt8(jpg.components[Int(si.compIdx)].id))
            bw.out.append(UInt8((si.dcTblIdx << 4) + si.acTblIdx))
        }
        bw.out.append(UInt8(scanInfo.ss))
        bw.out.append(UInt8(scanInfo.se))
        bw.out.append(UInt8((scanInfo.ah << 4) | scanInfo.al))

        let restartInterval = seenDRI ? Int(jpg.restartInterval) : 0
        var codingState = DCTCodingState()
        var restartsToGo = restartInterval
        var nextRestartMarker = 0
        var blockScanIndex = 0
        var extraZeroRunsPos = 0
        var nextResetPointPos = 0
        var lastDCCoeff = [Int16](repeating: 0, count: 4)

        let isInterleaved = scanInfo.numComponents > 1
        // CalculateMcuSize.
        let baseComponent = jpg.components[Int(scanInfo.components[0].compIdx)]
        let hGroup = isInterleaved ? 1 : baseComponent.hSampFactor
        let vGroup = isInterleaved ? 1 : baseComponent.vSampFactor
        var maxHSamp = 1
        var maxVSamp = 1
        for c in jpg.components {
            maxHSamp = max(maxHSamp, c.hSampFactor)
            maxVSamp = max(maxVSamp, c.vSampFactor)
        }
        let mcusPerRow = divCeil(assembled.width * hGroup, 8 * maxHSamp)
        let mcuRows = divCeil(assembled.height * vGroup, 8 * maxVSamp)

        let al = isProgressive ? Int(scanInfo.al) : 0
        let ss = isProgressive ? Int(scanInfo.ss) : 0
        let se = isProgressive ? Int(scanInfo.se) : 63
        let ah = isProgressive ? Int(scanInfo.ah) : 0
        // 0 = sequential, 1 = progressive first pass, 2 = refinement.
        let mode: Int
        if !isProgressive || (ah == 0 && al == 0 && ss == 0 && se == 63) {
            mode = 0
        } else if ah == 0 {
            mode = 1
        } else {
            mode = 2
        }
        let wantDC = ss == 0

        for mcuY in 0..<mcuRows {
            _ = mcuY
            for mcuX in 0..<mcusPerRow {
                _ = mcuX
                if restartInterval > 0 && restartsToGo == 0 {
                    flush(&codingState)
                    guard bw.jumpToByteBoundary(&padBits) else {
                        throw JXLError.malformed("jbrd: invalid padding bits")
                    }
                    bw.emitMarker(0xD0 + nextRestartMarker)
                    nextRestartMarker = (nextRestartMarker + 1) & 0x7
                    restartsToGo = restartInterval
                    lastDCCoeff = [0, 0, 0, 0]
                }
                for i in 0..<nScans {
                    let si = scanInfo.components[i]
                    let c = jpg.components[Int(si.compIdx)]
                    let dcHuff = dcTables[Int(si.dcTblIdx)]
                    let acHuffIdx = Int(si.acTblIdx)
                    if wantDC && !dcHuff.initialized {
                        throw JXLError.malformed("jbrd: DC table not initialized")
                    }
                    if (ss != 0 || se != 0) && !acTables[acHuffIdx].initialized {
                        throw JXLError.malformed("jbrd: AC table not initialized")
                    }
                    let nBlocksY = isInterleaved ? c.vSampFactor : 1
                    let nBlocksX = isInterleaved ? c.hSampFactor : 1
                    for iy in 0..<nBlocksY {
                        for ix in 0..<nBlocksX {
                            let blockY = mcuY * nBlocksY + iy
                            let blockX = mcuX * nBlocksX + ix
                            let blockIdx = blockY * c.widthInBlocks + blockX
                            if nextResetPointPos < scanInfo.resetPoints.count,
                                blockScanIndex == Int(scanInfo.resetPoints[nextResetPointPos]) {
                                flush(&codingState)
                                nextResetPointPos += 1
                            }
                            var numZeroRuns = 0
                            if extraZeroRunsPos < scanInfo.extraZeroRuns.count,
                                blockScanIndex
                                    == Int(scanInfo.extraZeroRuns[extraZeroRunsPos].blockIdx) {
                                numZeroRuns = Int(
                                    scanInfo.extraZeroRuns[extraZeroRunsPos].count)
                                extraZeroRunsPos += 1
                            }
                            guard (blockIdx + 1) << 6 <= c.coeffs.count else {
                                throw JXLError.malformed("jbrd: block index out of range")
                            }
                            let coeffs = c.coeffs[(blockIdx << 6)..<((blockIdx + 1) << 6)]
                            let ok: Bool
                            switch mode {
                            case 0:
                                ok = encodeDCTBlockSequential(
                                    coeffs, dcHuff, acTables[acHuffIdx], numZeroRuns,
                                    &lastDCCoeff[Int(si.compIdx)])
                            case 1:
                                ok = encodeDCTBlockProgressive(
                                    coeffs, dcHuff, acHuffIdx, ss, se, al, numZeroRuns,
                                    &codingState, &lastDCCoeff[Int(si.compIdx)])
                            default:
                                ok = encodeRefinementBits(
                                    coeffs, acHuffIdx, ss, se, al, &codingState)
                            }
                            guard ok else { throw JXLError.malformed("jbrd: scan encode failed") }
                            blockScanIndex += 1
                        }
                    }
                }
                restartsToGo -= 1
            }
        }
        flush(&codingState)
        guard bw.jumpToByteBoundary(&padBits) else {
            throw JXLError.malformed("jbrd: invalid padding bits")
        }
        guard bw.healthy else { throw JXLError.malformed("jbrd: unhealthy bit writer") }
    }

    // MARK: top level (marker walk)

    bw.out.append(contentsOf: [0xFF, 0xD8])  // SOI
    for marker in jpg.markerOrder {
        switch marker {
        case 0xC0, 0xC1, 0xC2, 0xC9, 0xCA:
            encodeSOF(marker)
        case 0xC4:
            try encodeDHT()
        case 0xD0...0xD7:
            bw.out.append(contentsOf: [0xFF, marker])
        case 0xD9:
            bw.out.append(contentsOf: [0xFF, 0xD9])  // EOI
            bw.out.append(contentsOf: jpg.tailData)
        case 0xDA:
            try encodeScan()
        case 0xDB:
            try encodeDQT()
        case 0xDD:
            seenDRI = true
            bw.out.append(contentsOf: [
                0xFF, 0xDD, 0, 4,
                UInt8((jpg.restartInterval >> 8) & 0xFF), UInt8(jpg.restartInterval & 0xFF),
            ])
        case 0xE0...0xEF:
            guard appIndex < jpg.appData.count else {
                throw JXLError.malformed("jbrd: APP index out of range")
            }
            bw.out.append(0xFF)
            bw.out.append(contentsOf: jpg.appData[appIndex])
            appIndex += 1
        case 0xFE:
            guard comIndex < jpg.comData.count else {
                throw JXLError.malformed("jbrd: COM index out of range")
            }
            bw.out.append(0xFF)
            bw.out.append(contentsOf: jpg.comData[comIndex])
            comIndex += 1
        case 0xFF:
            guard dataIndex < jpg.interMarkerData.count else {
                throw JXLError.malformed("jbrd: inter-marker index out of range")
            }
            bw.out.append(contentsOf: jpg.interMarkerData[dataIndex])
            dataIndex += 1
        default:
            throw JXLError.malformed("jbrd: unexpected marker \(marker)")
        }
    }
    if let remaining = padBits, !remaining.isEmpty {
        throw JXLError.malformed("jbrd: unused padding bits")
    }
    return bw.out
}
