// JPEGTranscodeEncoder.swift
//
// E6: the JPEG-recompression ENCODER (jbrd = "JPEG bitstream reconstruction
// data"). Given a baseline (sequential, Huffman) JPEG, produces a JPEG XL
// container that is (a) smaller than the JPEG and (b) losslessly reversible:
// reconstructing the JPEG from the JXL yields the BYTE-IDENTICAL original.
//
// This is the exact dual of the DECODER's reconstruction path:
//   * jbrd box layout — inverse of parseJPEGReconData (JPEGReconData.swift):
//     the bit-packed JPEGData bundle followed by one Brotli stream carrying the
//     marker payloads the codestream doesn't encode.
//   * JPEG re-emission — the writer's requirements (JPEGWriter.swift) define
//     what a "correct" jbrd + coefficient set is: whatever makes writeJPEG
//     reproduce the original bytes.
//   * VarDCT frame — a non-XYB (colorTransform = YCbCr) VarDCT frame whose
//     coefficient streams carry the JPEG's already-quantized DCT coefficients
//     verbatim (DC via the modular DC image, AC via the AC token streams), with
//     the JPEG quant tables written as a RAW dequant matrix, chroma subsampling
//     from the JPEG sampling factors, kSkipAdaptiveDCSmoothing set, loop filters
//     off. Read back by decodeVarDCTDC / decodeAcMetadataGroup /
//     decodeVarDCTACGlobal (RAW path) / decodeACGroupPass.
//
// The AC entropy coder is reimplemented locally (mirroring the decoder, not the
// private lossy ACEntropyCoder) since the JPEG-transcode coding path differs:
// YCbCr not XYB, RAW quant tables, coefficients passed through verbatim, no
// CfL / adaptive-quant / RD.
//
// Scope: baseline sequential Huffman JPEGs, 3-component YCbCr (component ids
// 1,2,3), sampling factors in {1,2}, at most one DC group (image ≤ 2048px in
// each dimension). Progressive, arithmetic, CMYK, RGB, grayscale, and larger
// images are rejected with a clear JXLEncodeError.

import Foundation

// MARK: - Zig-zag order (JPEG natural scan → raster). Same table the writer uses.

private let kNaturalOrder: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
]

// MARK: - Parsed JPEG (everything reconstruction needs)

private struct JPEGComponentParse {
    var id: Int = 0
    var hSamp: Int = 1
    var vSamp: Int = 1
    var quantIdx: Int = 0
    var widthInBlocks: Int = 0
    var heightInBlocks: Int = 0
    /// Quantized DCT coefficients, block raster order × 64 natural (raster) order.
    var coeffs: [Int16] = []
}

private struct HuffTableParse {
    var slotID: Int = 0  // AC tables add 0x10
    var isLast: Bool = true
    var counts = [Int](repeating: 0, count: 17)  // counts[1...16]
    var values: [Int] = []  // symbol values (no synthetic 256)
}

private struct QuantTableParse {
    var precision: Int = 0
    var index: Int = 0
    var isLast: Bool = true
    var values = [Int32](repeating: 0, count: 64)  // natural raster order
}

private struct ScanComponentParse {
    var compIdx: Int = 0  // index into components[]
    var dcTbl: Int = 0
    var acTbl: Int = 0
}

private struct ScanParse {
    var ss = 0
    var se = 63
    var ah = 0
    var al = 0
    var components: [ScanComponentParse] = []
}

private struct AppMarkerParse {
    var type: JPEGAppMarkerType = .unknown
    var bytes: [UInt8] = []  // marker payload starting at the marker byte (0xEn), = FF-stripped
}

private struct ParsedJPEG {
    var width = 0
    var height = 0
    var precision = 8
    var isProgressive = false
    var components: [JPEGComponentParse] = []
    var quant: [QuantTableParse] = []
    var huffman: [HuffTableParse] = []
    var scans: [ScanParse] = []
    var restartInterval = 0

    // Marker structure for the jbrd box.
    var markerOrder: [UInt8] = []
    var appMarkers: [AppMarkerParse] = []
    var comMarkers: [[UInt8]] = []
    var interMarkerData: [[UInt8]] = []
    var tailData: [UInt8] = []
    var exifPayload: [UInt8]? = nil  // Exif box payload (TIFF-offset prefix + data)

    // Entropy-stream reproduction details.
    var paddingBits: [Bool] = []
    var hasZeroPaddingBit = false
    var extraZeroRuns: [[(blockIdx: Int, count: Int)]] = []  // per scan
}

// MARK: - JPEG parse

private let kExifTag: [UInt8] = Array("Exif".utf8) + [0, 0]
private let kJFIFTag: [UInt8] = Array("JFIF".utf8) + [0]
private let kICCTag: [UInt8] = Array("ICC_PROFILE".utf8) + [0]
private let kXMPTag: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]

private func be16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }

/// Parses a baseline sequential Huffman JPEG. Throws JXLEncodeError on anything
/// out of scope.
private func parseJPEG(_ data: [UInt8]) throws -> ParsedJPEG {
    var jp = ParsedJPEG()
    let n = data.count
    guard n >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
        throw JXLEncodeError(reason: "not a JPEG (missing SOI)")
    }
    var i = 2
    // Huffman table storage keyed by (slotID) for scan decode.
    var dcTables = [Int: BuiltHuffTable]()
    var acTables = [Int: BuiltHuffTable]()

    while i < n {
        guard data[i] == 0xFF else {
            throw JXLEncodeError(reason: "expected marker at byte \(i)")
        }
        // Skip fill bytes (0xFF FF ...).
        var mp = i + 1
        while mp < n && data[mp] == 0xFF { mp += 1 }
        guard mp < n else { throw JXLEncodeError(reason: "truncated marker") }
        let marker = data[mp]
        i = mp + 1

        switch marker {
        case 0xD9:  // EOI
            jp.markerOrder.append(0xD9)
            jp.tailData = Array(data[i...])
            return finalizeParse(&jp)
        case 0xC0:  // SOF0 baseline
            try parseSOF(data, i, &jp)
            jp.markerOrder.append(0xC0)
            let len = be16(data, i)
            i += len
        case 0xC1:
            throw JXLEncodeError(reason: "extended sequential JPEG not supported")
        case 0xC2:
            throw JXLEncodeError(reason: "progressive JPEG not supported")
        case 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
            throw JXLEncodeError(reason: "unsupported JPEG SOF marker \(String(format: "0x%02X", marker))")
        case 0xC8, 0xF7:
            throw JXLEncodeError(reason: "JPEG-LS / JPEG extensions not supported")
        case 0xCC:  // DAC (arithmetic)
            throw JXLEncodeError(reason: "arithmetic-coded JPEG not supported")
        case 0xC4:  // DHT
            let len = be16(data, i)
            try parseDHT(data, i + 2, i + len, &jp, dc: &dcTables, ac: &acTables)
            jp.markerOrder.append(0xC4)
            i += len
        case 0xDB:  // DQT
            let len = be16(data, i)
            try parseDQT(data, i + 2, i + len, &jp)
            jp.markerOrder.append(0xDB)
            i += len
        case 0xDD:  // DRI
            let len = be16(data, i)
            jp.restartInterval = be16(data, i + 2)
            jp.markerOrder.append(0xDD)
            i += len
        case 0xDA:  // SOS + entropy data
            let len = be16(data, i)
            let scan = try parseSOSHeader(data, i + 2, i + len, &jp)
            jp.markerOrder.append(0xDA)
            i += len
            // Decode the entropy-coded segment.
            let (next, restartMarkers) = try decodeScan(
                data, start: i, scan: scan, jp: &jp, dc: dcTables, ac: acTables)
            _ = restartMarkers
            jp.scans.append(scan)
            i = next
        case 0xE0...0xEF:  // APPn
            let len = be16(data, i)
            let seg = Array(data[i - 1 ..< i + len])  // starts at marker byte 0xEn
            try classifyAppMarker(marker, seg, &jp)
            jp.markerOrder.append(marker)
            i += len
        case 0xFE:  // COM
            let len = be16(data, i)
            jp.comMarkers.append(Array(data[i - 1 ..< i + len]))
            jp.markerOrder.append(0xFE)
            i += len
        case 0x01, 0xD0...0xD7:  // TEM / stray RSTn (no payload)
            // Not expected outside entropy data; treat as inter-marker.
            throw JXLEncodeError(reason: "unexpected standalone marker \(String(format: "0x%02X", marker))")
        default:
            // Unknown marker with a length payload — preserve as inter-marker
            // data is complex; reject for now.
            throw JXLEncodeError(reason: "unsupported JPEG marker \(String(format: "0x%02X", marker))")
        }
    }
    throw JXLEncodeError(reason: "JPEG ended without EOI")
}

private func finalizeParse(_ jp: inout ParsedJPEG) -> ParsedJPEG {
    return jp
}

private func parseSOF(_ data: [UInt8], _ off: Int, _ jp: inout ParsedJPEG) throws {
    let len = be16(data, off)
    guard len >= 8 else { throw JXLEncodeError(reason: "bad SOF length") }
    jp.precision = Int(data[off + 2])
    guard jp.precision == 8 else {
        throw JXLEncodeError(reason: "\(jp.precision)-bit JPEG not supported (8-bit only)")
    }
    jp.height = be16(data, off + 3)
    jp.width = be16(data, off + 5)
    let nc = Int(data[off + 7])
    guard nc == 3 else {
        throw JXLEncodeError(reason: "only 3-component YCbCr JPEGs supported (got \(nc))")
    }
    var o = off + 8
    for _ in 0..<nc {
        var c = JPEGComponentParse()
        c.id = Int(data[o])
        c.hSamp = Int(data[o + 1]) >> 4
        c.vSamp = Int(data[o + 1]) & 0xF
        c.quantIdx = Int(data[o + 2])
        guard c.hSamp == 1 || c.hSamp == 2, c.vSamp == 1 || c.vSamp == 2 else {
            throw JXLEncodeError(reason: "unsupported sampling factor \(c.hSamp)x\(c.vSamp)")
        }
        jp.components.append(c)
        o += 3
    }
    guard jp.components.map(\.id) == [1, 2, 3] else {
        throw JXLEncodeError(
            reason: "only standard YCbCr component ids 1,2,3 supported (got \(jp.components.map(\.id)))")
    }
}

private func parseDQT(_ data: [UInt8], _ start: Int, _ end: Int, _ jp: inout ParsedJPEG) throws {
    var o = start
    var tablesInMarker: [Int] = []
    while o < end {
        let pq = Int(data[o]) >> 4
        let tq = Int(data[o]) & 0xF
        o += 1
        guard tq < 4 else { throw JXLEncodeError(reason: "bad DQT index") }
        var q = QuantTableParse()
        q.precision = pq
        q.index = tq
        for k in 0..<64 {
            let v: Int
            if pq != 0 {
                v = be16(data, o); o += 2
            } else {
                v = Int(data[o]); o += 1
            }
            q.values[kNaturalOrder[k]] = Int32(v)
        }
        // Grow storage to hold index tq.
        while jp.quant.count <= tq { jp.quant.append(QuantTableParse()) }
        jp.quant[tq] = q
        tablesInMarker.append(tq)
    }
    // isLast handling is derived at serialization time from marker grouping,
    // but we also record which is the final table in this DQT marker.
    for (k, tq) in tablesInMarker.enumerated() {
        jp.quant[tq].isLast = (k == tablesInMarker.count - 1)
    }
}

private struct BuiltHuffTable {
    // Fast decode: maxcode/valptr/mincode per libjpeg, plus values.
    var minCode = [Int](repeating: 0, count: 17)
    var maxCode = [Int](repeating: -1, count: 18)
    var valPtr = [Int](repeating: 0, count: 17)
    var values: [Int] = []
}

private func buildHuffDecode(_ counts: [Int], _ values: [Int]) -> BuiltHuffTable {
    var t = BuiltHuffTable()
    t.values = values
    var code = 0
    var k = 0
    for l in 1...16 {
        t.valPtr[l] = k
        t.minCode[l] = code
        code += counts[l]
        t.maxCode[l] = counts[l] > 0 ? code - 1 : -1
        k += counts[l]
        code <<= 1
    }
    t.maxCode[17] = 0x7FFFFFFF
    return t
}

private func parseDHT(
    _ data: [UInt8], _ start: Int, _ end: Int, _ jp: inout ParsedJPEG,
    dc: inout [Int: BuiltHuffTable], ac: inout [Int: BuiltHuffTable]
) throws {
    var o = start
    var tablesInMarker: [Int] = []  // index into jp.huffman
    while o < end {
        let tc = Int(data[o]) >> 4  // 0 = DC, 1 = AC
        let th = Int(data[o]) & 0xF
        o += 1
        guard tc <= 1, th < 4 else { throw JXLEncodeError(reason: "bad DHT slot") }
        var ht = HuffTableParse()
        ht.slotID = (tc == 1 ? 0x10 : 0) | th
        var total = 0
        for l in 1...16 {
            ht.counts[l] = Int(data[o]); o += 1
            total += ht.counts[l]
        }
        guard o + total <= end else { throw JXLEncodeError(reason: "bad DHT (values overrun)") }
        ht.values = (0..<total).map { Int(data[o + $0]) }
        o += total
        jp.huffman.append(ht)
        tablesInMarker.append(jp.huffman.count - 1)
        let built = buildHuffDecode(ht.counts, ht.values)
        if tc == 0 { dc[th] = built } else { ac[th] = built }
    }
    for (k, idx) in tablesInMarker.enumerated() {
        jp.huffman[idx].isLast = (k == tablesInMarker.count - 1)
    }
}

private func parseSOSHeader(
    _ data: [UInt8], _ start: Int, _ end: Int, _ jp: inout ParsedJPEG
) throws -> ScanParse {
    var o = start
    let ns = Int(data[o]); o += 1
    var scan = ScanParse()
    for _ in 0..<ns {
        let cs = Int(data[o])
        let td = Int(data[o + 1])
        o += 2
        guard let compIdx = jp.components.firstIndex(where: { $0.id == cs }) else {
            throw JXLEncodeError(reason: "scan references unknown component \(cs)")
        }
        scan.components.append(
            ScanComponentParse(compIdx: compIdx, dcTbl: td >> 4, acTbl: td & 0xF))
    }
    scan.ss = Int(data[o])
    scan.se = Int(data[o + 1])
    scan.ah = Int(data[o + 2]) >> 4
    scan.al = Int(data[o + 2]) & 0xF
    guard scan.ss == 0, scan.se == 63, scan.ah == 0, scan.al == 0 else {
        throw JXLEncodeError(reason: "non-baseline scan (progressive spectral selection)")
    }
    guard scan.components.count == jp.components.count else {
        throw JXLEncodeError(reason: "non-interleaved baseline scan not supported")
    }
    return scan
}

// MARK: - Entropy-coded segment decode (baseline sequential, Huffman)

/// A JPEG entropy-stream bit reader: MSB-first, FF-stuffing aware, marker-aware.
private final class JPEGScanReader {
    let data: [UInt8]
    var pos: Int
    var curByte = 0
    var nbits = 0
    var marker: Int? = nil  // a non-stuff, non-RST marker (or RSTn) encountered

    init(_ data: [UInt8], _ start: Int) {
        self.data = data
        self.pos = start
    }

    private func loadByte() {
        if marker != nil { return }
        guard pos < data.count else { marker = 0xD9; return }
        let b = Int(data[pos])
        if b == 0xFF {
            var j = pos + 1
            while j < data.count && data[j] == 0xFF { j += 1 }
            let m = j < data.count ? Int(data[j]) : 0xD9
            if m == 0x00 {
                // Stuffed 0xFF (skip trailing 0x00; drop any fill 0xFF run).
                curByte = 0xFF
                nbits = 8
                pos = j + 1
            } else {
                marker = m  // pos stays at the first 0xFF of the run
                return
            }
        } else {
            curByte = b
            nbits = 8
            pos += 1
        }
    }

    func getBit() -> Int {
        if nbits == 0 {
            loadByte()
            if nbits == 0 { return 0 }  // marker reached: feed zeros
        }
        nbits -= 1
        return (curByte >> nbits) & 1
    }

    func receive(_ count: Int) -> Int {
        var r = 0
        for _ in 0..<count { r = (r << 1) | getBit() }
        return r
    }

    /// Byte-aligns, returning the remaining bits of the current partial byte
    /// (the entropy padding). After this the reader sits at a marker byte.
    func alignToByte() -> [Bool] {
        var padding: [Bool] = []
        while nbits > 0 {
            nbits -= 1
            padding.append((curByte >> nbits) & 1 == 1)
        }
        return padding
    }
}

@inline(__always)
private func huffExtend(_ v: Int, _ s: Int) -> Int {
    // JPEG EXTEND: values with MSB 0 are negative.
    v < (1 << (s - 1)) ? v - (1 << s) + 1 : v
}

private func decodeHuffSymbol(_ r: JPEGScanReader, _ t: BuiltHuffTable) throws -> Int {
    var code = r.getBit()
    var l = 1
    while code > t.maxCode[l] {
        code = (code << 1) | r.getBit()
        l += 1
        if l > 16 { throw JXLEncodeError(reason: "invalid Huffman code in scan") }
    }
    let idx = t.valPtr[l] + (code - t.minCode[l])
    guard idx >= 0, idx < t.values.count else {
        throw JXLEncodeError(reason: "Huffman symbol index out of range")
    }
    return t.values[idx]
}

/// Decodes the interleaved baseline scan, filling component coefficient arrays.
/// Returns the byte index just past the scan (at EOI or next marker) and the
/// number of restart markers consumed.
private func decodeScan(
    _ data: [UInt8], start: Int, scan: ScanParse, jp: inout ParsedJPEG,
    dc: [Int: BuiltHuffTable], ac: [Int: BuiltHuffTable]
) throws -> (next: Int, restarts: Int) {
    // Component block dimensions come from the JXL frame grid (which equals the
    // JPEG MCU-padded grid): xsizeBlocks = divCeil(w, 8<<maxHShift) << maxHShift.
    let maxH = jp.components.map(\.hSamp).max()!
    let maxV = jp.components.map(\.vSamp).max()!
    let maxHShift = maxH == 2 ? 1 : 0
    let maxVShift = maxV == 2 ? 1 : 0
    let xsizeBlocks = divCeil(jp.width, 8 << maxHShift) << maxHShift
    let ysizeBlocks = divCeil(jp.height, 8 << maxVShift) << maxVShift
    for k in 0..<jp.components.count {
        let hShift = jp.components[k].hSamp == maxH ? 0 : (maxHShift)
        let vShift = jp.components[k].vSamp == maxV ? 0 : (maxVShift)
        let wb = xsizeBlocks >> hShift
        let hb = ysizeBlocks >> vShift
        jp.components[k].widthInBlocks = wb
        jp.components[k].heightInBlocks = hb
        jp.components[k].coeffs = [Int16](repeating: 0, count: wb * hb * 64)
    }

    let mcusPerRow = divCeil(jp.width, 8 * maxH)
    let mcuRows = divCeil(jp.height, 8 * maxV)
    let totalMCU = mcusPerRow * mcuRows

    let reader = JPEGScanReader(data, start)
    var pred = [Int](repeating: 0, count: jp.components.count)
    var restarts = 0
    let ri = jp.restartInterval
    var extraZeroRuns: [(blockIdx: Int, count: Int)] = []
    // Per-scan block index counter (matches JPEGWriter blockScanIndex: it
    // increments once per decoded block in MCU/component/block order).
    var blockScanIndex = 0

    for mcu in 0..<totalMCU {
        if ri > 0 && mcu > 0 && mcu % ri == 0 {
            // Restart boundary: capture padding, consume RSTn, reset predictors.
            let padding = reader.alignToByte()
            jp.paddingBits.append(contentsOf: padding)
            guard reader.pos + 1 < data.count, data[reader.pos] == 0xFF,
                (0xD0...0xD7).contains(data[reader.pos + 1])
            else {
                throw JXLEncodeError(reason: "expected restart marker at MCU \(mcu)")
            }
            reader.pos += 2
            reader.marker = nil
            reader.nbits = 0
            for k in 0..<pred.count { pred[k] = 0 }
            restarts += 1
        }
        let mx = mcu % mcusPerRow
        let my = mcu / mcusPerRow
        for sc in scan.components {
            let compIdx = sc.compIdx
            let comp = jp.components[compIdx]
            guard let dcT = dc[sc.dcTbl], let acT = ac[sc.acTbl] else {
                throw JXLEncodeError(reason: "scan references undefined Huffman table")
            }
            for iy in 0..<comp.vSamp {
                for ix in 0..<comp.hSamp {
                    let bx = mx * comp.hSamp + ix
                    let by = my * comp.vSamp + iy
                    let blockIdx = by * comp.widthInBlocks + bx
                    let base = blockIdx * 64
                    // DC.
                    let s = try decodeHuffSymbol(reader, dcT)
                    guard s <= 15 else { throw JXLEncodeError(reason: "bad DC size \(s)") }
                    var diff = 0
                    if s > 0 { diff = huffExtend(reader.receive(s), s) }
                    pred[compIdx] += diff
                    jp.components[compIdx].coeffs[base] = Int16(clamping: pred[compIdx])
                    // AC.
                    var kk = 1
                    var pendingZRL = 0
                    while kk < 64 {
                        let rs = try decodeHuffSymbol(reader, acT)
                        let run = rs >> 4
                        let size = rs & 0xF
                        if size == 0 {
                            if run == 15 {
                                // ZRL: skip 16 zeros.
                                pendingZRL += 1
                                kk += 16
                                continue
                            } else {
                                // EOB.
                                break
                            }
                        }
                        kk += run
                        guard kk < 64 else { throw JXLEncodeError(reason: "AC run overflow") }
                        // Any ZRLs emitted since the last real coefficient were
                        // legitimate (needed to reach this coefficient).
                        pendingZRL = 0
                        let v = huffExtend(reader.receive(size), size)
                        jp.components[compIdx].coeffs[base + kNaturalOrder[kk]] = Int16(clamping: v)
                        kk += 1
                    }
                    // Redundant trailing ZRLs before EOB (writer re-emits them
                    // via extraZeroRuns). A standard encoder produces none.
                    if pendingZRL > 0 {
                        extraZeroRuns.append((blockIdx: blockScanIndex, count: pendingZRL))
                    }
                    blockScanIndex += 1
                }
            }
        }
    }

    // Final padding after the last MCU, then the reader sits at EOI (or the
    // next marker in the stream).
    let finalPadding = reader.alignToByte()
    jp.paddingBits.append(contentsOf: finalPadding)
    jp.extraZeroRuns.append(extraZeroRuns)

    // Determine hasZeroPaddingBit: standard JPEGs pad with 1-bits.
    if jp.paddingBits.contains(false) {
        jp.hasZeroPaddingBit = true
    } else {
        jp.hasZeroPaddingBit = false
        jp.paddingBits = []
    }

    // The reader is positioned at the marker byte after the entropy stream.
    return (reader.pos, restarts)
}

// MARK: - APP marker classification

private func classifyAppMarker(
    _ marker: UInt8, _ seg: [UInt8], _ jp: inout ParsedJPEG
) throws {
    // seg starts at the marker byte (0xEn); seg[1..2] = length; seg[3...] = tag/payload.
    var am = AppMarkerParse()
    am.bytes = seg
    let payload = Array(seg[3...])
    if marker == 0xE1 && payload.starts(with: kExifTag) {
        am.type = .exif
        // The Exif box payload is a 4-byte TIFF-header offset (0) + the Exif
        // data after the "Exif\0\0" tag (dec_jpeg_data.cc / SetExif).
        let exifData = Array(payload[kExifTag.count...])
        jp.exifPayload = [0, 0, 0, 0] + exifData
    } else if marker == 0xE1 && payload.starts(with: kXMPTag) {
        // XMP goes in an "xml " box; not yet supported — keep as unknown so its
        // bytes round-trip through the Brotli tail instead.
        am.type = .unknown
    } else if marker == 0xE2 && payload.starts(with: kICCTag) {
        // ICC requires the embedded-profile path; reject to stay honest.
        throw JXLEncodeError(reason: "ICC-profile JPEG (APP2) not yet supported")
    } else {
        am.type = .unknown
    }
    jp.appMarkers.append(am)
}

// MARK: - Color mapping helpers (mirror JPEGRecon)

// JXL plane order [X, Y, B] ↔ JPEG component index for YCbCr: plane X=Cb(comp1),
// Y=luma(comp0), B=Cr(comp2). jpegCMap[plane] = component index.
private let kJpegCMap = [1, 0, 2]

/// chromaChannelMode[jxlPlane] from a component's (hSamp,vSamp). Modes:
/// 0=(kH0,kV0), 1=(kH1,kV1), 2=(kH1,kV0), 3=(kH0,kV1); kH=[0,1,1,0], kV=[0,1,0,1].
private func chromaMode(h: Int, v: Int) -> UInt32 {
    let hb = h == 2 ? 1 : 0
    let vb = v == 2 ? 1 : 0
    switch (hb, vb) {
    case (0, 0): return 0
    case (1, 1): return 1
    case (1, 0): return 2
    default: return 3
    }
}

// MARK: - jbrd box serialization (inverse of parseJPEGReconData)

/// Serializes the `jbrd` box payload: the bit-packed JPEGData bundle followed
/// by one Brotli stream carrying the marker payloads the codestream doesn't
/// encode. Exact inverse of `parseJPEGReconData`.
private func serializeJBRD(_ jp: ParsedJPEG) throws -> [UInt8] {
    let w = BitWriter()
    let isGray = jp.components.count == 1
    w.writeBool(isGray)

    // Marker order: 6 bits per marker relative to 0xC0, terminated by EOI.
    for m in jp.markerOrder {
        w.write(UInt64(m &- 0xC0), 6)
    }

    // APP marker types + sizes.
    for am in jp.appMarkers {
        w.writeU32(am.type.rawValue, .value(0), .value(1), .bits(1, offset: 2), .bits(2, offset: 4))
        w.write(UInt64(am.bytes.count - 1), 16)  // size = count - 1
    }
    // COM sizes.
    for com in jp.comMarkers {
        w.write(UInt64(com.count - 1), 16)
    }

    // Quant table shells.
    let numQuant = jp.quant.count
    guard numQuant >= 1, numQuant <= 3 else {
        // The jbrd U32 encodes 1..4 but the decoder rejects 4; a 3-component
        // YCbCr JPEG references at most 3 tables anyway.
        throw JXLEncodeError(reason: "unsupported number of quant tables (\(numQuant))")
    }
    w.writeU32(UInt32(numQuant), .value(1), .value(2), .value(3), .value(4))
    for (i, q) in jp.quant.enumerated() {
        w.write(UInt64(q.precision), 1)
        w.write(UInt64(q.index), 2)
        w.writeBool(i == jp.quant.count - 1 ? true : q.isLast)
    }

    // Component type + ids.
    // 0=gray(1), 1=YCbCr(ids 1,2,3), 2=RGB(ids R,G,B), 3=custom.
    let ids = jp.components.map(\.id)
    let componentType: UInt32
    if jp.components.count == 1 && ids == [1] {
        componentType = 0
    } else if jp.components.count == 3 && ids == [1, 2, 3] {
        componentType = 1
    } else if jp.components.count == 3 && ids == [82, 71, 66] {
        componentType = 2
    } else {
        componentType = 3
    }
    w.write(UInt64(componentType), 2)
    if componentType == 3 {
        w.writeU32(UInt32(jp.components.count), .value(1), .value(2), .value(3), .value(4))
        for c in jp.components { w.write(UInt64(c.id), 8) }
    }
    for c in jp.components {
        w.write(UInt64(c.quantIdx), 2)
    }

    // Huffman codes.
    w.writeU32(
        UInt32(jp.huffman.count),
        .value(4), .bits(3, offset: 2), .bits(4, offset: 10), .bits(6, offset: 26))
    for ht in jp.huffman {
        let isAC = ht.slotID & 0x10 != 0
        let id = UInt32(ht.slotID & 0x3)
        w.writeBool(isAC)
        w.write(UInt64(id), 2)
        w.writeBool(ht.isLast)
        // jbrd counts include the synthetic 256 (EOI) sentinel at the max
        // length; values gets 256 appended at the end.
        var counts = [Int](repeating: 0, count: 17)
        for l in 1...16 { counts[l] = ht.counts[l] }
        var maxLen = 0
        for l in 1...16 where ht.counts[l] > 0 { maxLen = l }
        precondition(maxLen > 0, "empty Huffman table")
        counts[maxLen] += 1
        for i in 0...16 {
            w.writeU32(UInt32(counts[i]), .value(0), .value(1), .bits(3, offset: 2), .bits(8))
        }
        for v in ht.values {
            w.writeU32(
                UInt32(v), .bits(2), .bits(2, offset: 4), .bits(4, offset: 8), .bits(8, offset: 1))
        }
        // Synthetic EOI sentinel.
        w.writeU32(256, .bits(2), .bits(2, offset: 4), .bits(4, offset: 8), .bits(8, offset: 1))
    }

    // Scan scripts.
    for scan in jp.scans {
        w.writeU32(
            UInt32(scan.components.count), .value(1), .value(2), .value(3), .value(4))
        w.write(UInt64(scan.ss), 6)
        w.write(UInt64(scan.se), 6)
        w.write(UInt64(scan.al), 4)
        w.write(UInt64(scan.ah), 4)
        for sc in scan.components {
            w.write(UInt64(sc.compIdx), 2)
            w.write(UInt64(sc.acTbl), 2)
            w.write(UInt64(sc.dcTbl), 2)
        }
        // lastNeededPass = 0.
        w.writeU32(0, .value(0), .value(1), .value(2), .bits(3, offset: 3))
    }

    // Restart interval (only if a DRI marker is present).
    if jp.markerOrder.contains(0xDD) {
        w.write(UInt64(jp.restartInterval), 16)
    }

    // Per-scan reset points (none) + extra zero runs.
    for (s, scan) in jp.scans.enumerated() {
        _ = scan
        // numResetPoints = 0.
        w.writeU32(0, .value(0), .bits(2, offset: 1), .bits(4, offset: 4), .bits(16, offset: 20))
        let ezr = s < jp.extraZeroRuns.count ? jp.extraZeroRuns[s] : []
        w.writeU32(
            UInt32(ezr.count), .value(0), .bits(2, offset: 1), .bits(4, offset: 4),
            .bits(16, offset: 20))
        var last = -1
        for (blockIdx, count) in ezr {
            w.writeU32(
                UInt32(count), .value(1), .bits(2, offset: 2), .bits(4, offset: 5),
                .bits(8, offset: 20))
            let delta = blockIdx - last - 1
            w.writeU32(
                UInt32(delta), .value(0), .bits(3, offset: 1), .bits(5, offset: 9),
                .bits(28, offset: 41))
            last = blockIdx
        }
    }

    // Inter-marker sizes (none).
    // (numIntermarker == count of 0xFF fake markers in markerOrder == 0.)

    // Tail data length.
    w.writeU32(
        UInt32(jp.tailData.count), .value(0), .bits(8, offset: 1), .bits(16, offset: 257),
        .bits(22, offset: 65793))

    // Padding bits.
    w.writeBool(jp.hasZeroPaddingBit)
    if jp.hasZeroPaddingBit {
        w.write(UInt64(jp.paddingBits.count), 24)
        for b in jp.paddingBits { w.writeBool(b) }
    }

    w.alignToByte()

    // Brotli tail: unknown APP payloads, COM payloads, inter-marker data, tail.
    var tail: [UInt8] = []
    for am in jp.appMarkers where am.type == .unknown { tail.append(contentsOf: am.bytes) }
    for com in jp.comMarkers { tail.append(contentsOf: com) }
    tail.append(contentsOf: jp.tailData)

    var out = w.finalize()
    out.append(contentsOf: brotliStore(tail))
    return out
}

// (The uncompressed "store" Brotli serializer this box needs now lives in
// ContainerWriter.swift as `brotliStore`, shared with the container writer.)

// MARK: - AC block-context tables (mirror of the decoder; local dual)

private let kJBRDNumBlockCtxClusters = 15
private let kJBRDNonZeroBuckets = 37
private let kJBRDZeroDensityContextCount = 458
private let kJBRDNumACContexts =
    kJBRDNumBlockCtxClusters * (kJBRDNonZeroBuckets + kJBRDZeroDensityContextCount)

private let kJBRDDefaultBlockContextMap: [UInt8] = [
    0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
]
private let kJBRDNumCoeffOrders = 13
private let kJBRDCoeffFreqContext: [Int] = [
    0xBAD, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
]
private let kJBRDCoeffNumNonzeroContext: [Int] = [
    0xBAD, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123,
    152, 152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180, 180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
]

@inline(__always)
private func jbrdBlockContext(channel c: Int, order ord: Int) -> Int {
    var idx = c < 2 ? c ^ 1 : 2
    idx = idx * kJBRDNumCoeffOrders + ord
    return Int(kJBRDDefaultBlockContextMap[idx])
}

@inline(__always)
private func jbrdNonZeroContext(predicted: Int, blockCtx: Int) -> Int {
    var nz = predicted
    if nz >= 64 { nz = 64 }
    let ctx: Int = nz < 8 ? nz : 4 + nz / 2
    return ctx * kJBRDNumBlockCtxClusters + blockCtx
}

@inline(__always)
private func jbrdZeroDensityOffset(blockCtx: Int) -> Int {
    kJBRDNumBlockCtxClusters * kJBRDNonZeroBuckets + kJBRDZeroDensityContextCount * blockCtx
}

@inline(__always)
private func jbrdZeroDensityContext(nonzerosLeft nz: Int, k: Int, prev: Int) -> Int {
    (kJBRDCoeffNumNonzeroContext[nz] + kJBRDCoeffFreqContext[k]) * 2 + prev
}

@inline(__always)
private func jbrdPredictNonZeros(_ nz: [Int32], w: Int, bx: Int, by: Int) -> Int32 {
    let hasTop = by > 0
    if bx == 0 { return hasTop ? nz[(by - 1) * w + bx] : 32 }
    let left = nz[by * w + (bx - 1)]
    if !hasTop { return left }
    return (nz[(by - 1) * w + bx] + left + 1) / 2
}

// MARK: - AC entropy coder (local dual of decodeHistograms + ANSSymbolReader)
//
// Reimplemented here (not the private lossy ACEntropyCoder) because the JPEG
// transcode path is separate; it writes the same wire format with a FIXED
// context clustering (any surjective map is valid — the decoder reads whatever
// map is written).

private func jbrdACClusterMap(numContexts: Int) -> [UInt8] {
    let nzEnd = kJBRDNumBlockCtxClusters * kJBRDNonZeroBuckets
    var map = [UInt8](repeating: 0, count: numContexts)
    for ctx in 0..<numContexts {
        if ctx < nzEnd {
            map[ctx] = (ctx % kJBRDNumBlockCtxClusters) == 0 ? 0 : 1
        } else {
            let rel = ctx - nzEnd
            let blockCtx = rel / kJBRDZeroDensityContextCount
            let zd = rel % kJBRDZeroDensityContextCount
            let half = zd >> 1
            let band = half < 31 ? 0 : (half < 93 ? 1 : 2)
            map[ctx] = UInt8(2 + (blockCtx == 0 ? 0 : 3) + band)
        }
    }
    return map
}

private struct JBRDACCoder {
    let numContexts: Int
    let contextMap: [UInt8]
    let numClusters: Int
    let logAlphaSize: Int
    private let counts: [[Int32]]
    private let slots: [[[UInt16]]]

    init(numContexts: Int, streams: [[EncToken]]) {
        self.numContexts = numContexts
        var total = 0
        for s in streams { total += s.count }
        let map = total < 4096
            ? [UInt8](repeating: 0, count: numContexts)
            : jbrdACClusterMap(numContexts: numContexts)
        contextMap = map
        let nc = Int(map.max()!) + 1
        numClusters = nc

        var hist = [[Int]](repeating: [Int](repeating: 0, count: 128), count: nc)
        var maxToken = 0
        for s in streams {
            for t in s {
                let (tok, _, _) = encUintConfig.encode(t.value)
                hist[Int(map[Int(t.ctx)])][Int(tok)] += 1
                if Int(tok) > maxToken { maxToken = Int(tok) }
            }
        }
        logAlphaSize = max(5, ceilLog2Nonzero(UInt32(maxToken + 1)))

        var cnts: [[Int32]] = []
        var slts: [[[UInt16]]] = []
        let logEntrySize = ansLogTabSize - logAlphaSize
        let entrySizeMinus1 = (1 << logEntrySize) - 1
        for c in 0..<nc {
            var h = hist[c]
            if h.reduce(0, +) == 0 { h = [1] }
            var normalized = normalizeANSCounts(h)
            while let last = normalized.last, last == 0, normalized.count > 1 {
                normalized.removeLast()
            }
            var table = [AliasEntry](repeating: AliasEntry(), count: 1 << logAlphaSize)
            initAliasTable(
                distribution: normalized, logAlphaSize: logAlphaSize, into: &table, base: 0)
            var s = normalized.map { [UInt16](repeating: 0, count: Int($0)) }
            table.withUnsafeBufferPointer { tp in
                for v in 0..<ansTabSize {
                    let sym = aliasLookup(
                        tp.baseAddress!, base: 0, value: v, logEntrySize: logEntrySize,
                        entrySizeMinus1: entrySizeMinus1)
                    s[sym.value][sym.offset] = UInt16(v)
                }
            }
            cnts.append(normalized)
            slts.append(s)
        }
        counts = cnts
        slots = slts
    }

    func writeHeader(_ w: BitWriter) {
        w.writeBool(false)  // lz77 disabled
        w.writeBool(true)  // context map is_simple
        let bits = numClusters > 1 ? ceilLog2Nonzero(UInt32(numClusters)) : 0
        w.write(UInt64(bits), 2)
        if bits > 0 {
            for entry in contextMap { w.write(UInt64(entry), bits) }
        }
        w.writeBool(false)  // use_prefix_code = false: ANS
        w.write(UInt64(logAlphaSize - 5), 2)
        for _ in 0..<numClusters {
            w.write(4, ceilLog2Nonzero(UInt32(logAlphaSize + 1)))
            w.write(2, 3)
            w.write(0, 2)
        }
        for c in counts { writeANSHistogram(w, counts: c) }
    }

    func encodeStream(_ w: BitWriter, _ tokens: [EncToken]) {
        let n = tokens.count
        var symbols = [Int](repeating: 0, count: max(1, n))
        var cluster = [Int](repeating: 0, count: max(1, n))
        var exNBits = [UInt32](repeating: 0, count: max(1, n))
        var exBits = [UInt32](repeating: 0, count: max(1, n))
        var chunk = [UInt32](repeating: .max, count: max(1, n))
        for i in 0..<n {
            let t = tokens[i]
            let (tok, nbits, bits) = encUintConfig.encode(t.value)
            symbols[i] = Int(tok)
            cluster[i] = Int(contextMap[Int(t.ctx)])
            exNBits[i] = nbits
            exBits[i] = bits
        }
        var state: UInt32 = ansSignature << 16
        var i = n - 1
        while i >= 0 {
            let c = cluster[i]
            let sym = symbols[i]
            let f = UInt32(counts[c][sym])
            if UInt64(state) >= UInt64(f) << 20 {
                chunk[i] = state & 0xFFFF
                state >>= 16
            }
            let slot = slots[c][sym][Int(state % f)]
            state = ((state / f) << UInt32(ansLogTabSize)) | UInt32(slot)
            i -= 1
        }
        w.write(UInt64(state), 32)
        for j in 0..<n {
            if chunk[j] != UInt32.max { w.write(UInt64(chunk[j]), 16) }
            if exNBits[j] > 0 { w.write(UInt64(exBits[j]), Int(exNBits[j])) }
        }
    }
}

// MARK: - Codestream builder

private let kH_ForMode = [0, 1, 1, 0]
private let kV_ForMode = [0, 1, 0, 1]

/// The single-leaf gradient global MA tree used for every modular sub-stream.
private let jbrdTree: [MATreeNode] = [
    MATreeNode(
        property: -1, splitVal: 0, lchild: 0, rchild: 0,
        predictor: 5, predictorOffset: 0, multiplier: 1)
]

/// FrameHeader for the JPEG-transcode shape: regular VarDCT frame, YCbCr color
/// transform, chroma subsampling from the JPEG sampling factors,
/// kSkipAdaptiveDCSmoothing, single pass, loop filters off.
private func writeTranscodeFrameHeader(_ w: BitWriter, chromaChannelMode: [UInt32]) {
    w.writeBool(false)  // all_default
    w.write(0, 2)  // frame_type: regular
    w.writeBool(false)  // encoding: VarDCT
    w.writeU64(128)  // flags: kSkipAdaptiveDCSmoothing
    w.writeBool(true)  // color transform: YCbCr (xyb_encoded == false)
    for i in 0..<3 { w.write(UInt64(chromaChannelMode[i]), 2) }  // chroma subsampling
    w.write(0, 2)  // upsampling = 1
    // (VarDCT + non-XYB => no x/b qm scale)
    w.write(0, 2)  // num_passes = 1
    w.writeBool(false)  // custom_size_or_origin
    w.write(0, 2)  // blending mode: replace
    w.writeBool(true)  // is_last
    w.write(0, 2)  // name length = 0
    w.writeBool(false)  // loop filter: not all_default
    w.writeBool(false)  // gaborish off
    w.write(0, 2)  // epf_iters = 0
    w.writeU64(0)  // loop-filter extensions
    w.writeU64(0)  // frame-header extensions
}

private func writeTocSize(_ w: BitWriter, _ size: Int) {
    w.writeU32(
        UInt32(size), .bits(10), .bits(14, offset: 1024), .bits(22, offset: 17408),
        .bits(30, offset: 4_211_712))
}

private func buildTranscodeCodestream(_ jp: ParsedJPEG) throws -> [UInt8] {
    let w = jp.width
    let h = jp.height
    let maxH = jp.components.map(\.hSamp).max()!
    let maxV = jp.components.map(\.vSamp).max()!
    let maxHShift = maxH == 2 ? 1 : 0
    let maxVShift = maxV == 2 ? 1 : 0

    // Per-plane chroma channel mode (JXL plane order [X=Cb, Y, B=Cr]).
    var chromaChannelMode = [UInt32](repeating: 0, count: 3)
    for plane in 0..<3 {
        let comp = jp.components[kJpegCMap[plane]]
        chromaChannelMode[plane] = chromaMode(h: comp.hSamp, v: comp.vSamp)
    }
    let hsRaw = chromaChannelMode.map { kH_ForMode[Int($0)] }
    let vsRaw = chromaChannelMode.map { kV_ForMode[Int($0)] }
    let mh = hsRaw.max()!
    let mv = vsRaw.max()!
    let shiftsH = hsRaw.map { mh - $0 }
    let shiftsV = vsRaw.map { mv - $0 }

    var dim = FrameDimensions()
    dim.set(
        xsize: w, ysize: h, groupSizeShift: 1, maxHShift: maxHShift, maxVShift: maxVShift,
        modular: false, upsampling: 1)
    guard dim.numDCGroups == 1 else {
        throw JXLEncodeError(reason: "JPEG too large for transcode (multiple DC groups unsupported)")
    }
    let bw = dim.xsizeBlocks
    let bh = dim.ysizeBlocks

    // Quantizer values are irrelevant to reconstruction (which reads the raw
    // quantized coefficients directly), but must be valid.
    let globalScale: UInt32 = 8192
    let quantDC: UInt32 = 32

    // ---- DC planes per component (one quantized DC per block).
    var dcPlane = [[Int32]](repeating: [], count: 3)
    for comp in 0..<3 {
        let cw = jp.components[comp].widthInBlocks
        let ch = jp.components[comp].heightInBlocks
        var plane = [Int32](repeating: 0, count: cw * ch)
        let coeffs = jp.components[comp].coeffs
        for b in 0..<(cw * ch) { plane[b] = Int32(coeffs[b * 64]) }
        dcPlane[comp] = plane
    }

    // ---- AC token streams per group (mirror decodeACGroupPass).
    let bgDim = dim.groupDim >> 3  // 32 blocks per AC group
    let jxlToNatural = (0..<64).map { s in (s % 8) * 8 + (s / 8) }  // JXL storage -> JPEG raster
    let order = computeNaturalCoeffOrder(cbx: 1, cby: 1)
    let blockCtxOf: [Int] = (0..<3).map { jbrdBlockContext(channel: $0, order: kStrategyOrder[0]) }

    var acTokens: [[EncToken]] = []
    acTokens.reserveCapacity(dim.numGroups)
    for g in 0..<dim.numGroups {
        let bx0 = (g % dim.xsizeGroups) * bgDim
        let by0 = (g / dim.xsizeGroups) * bgDim
        let gw = min(bgDim, bw - bx0)
        let gh = min(bgDim, bh - by0)
        var tokens: [EncToken] = []
        let nzW = (0..<3).map { divCeil(gw, 1 << shiftsH[$0]) }
        let nzH = (0..<3).map { divCeil(gh, 1 << shiftsV[$0]) }
        var nzeros = (0..<3).map { [Int32](repeating: 0, count: nzW[$0] * nzH[$0]) }

        for byl in 0..<gh {
            let by = by0 + byl
            for bxl in 0..<gw {
                let bx = bx0 + bxl
                for c in [1, 0, 2] {
                    let hs = shiftsH[c]
                    let vs = shiftsV[c]
                    let sbxl = bxl >> hs
                    let sbyl = byl >> vs
                    if (sbxl << hs) != bxl || (sbyl << vs) != byl { continue }
                    let comp = kJpegCMap[c]
                    let compBx = bx >> hs
                    let compBy = by >> vs
                    let cw = jp.components[comp].widthInBlocks
                    let base = (compBy * cw + compBx) * 64
                    let J = jp.components[comp].coeffs
                    var nz = 0
                    for p in 1..<64 where J[base + p] != 0 { nz += 1 }
                    let blockCtx = blockCtxOf[c]
                    let predicted = Int(
                        jbrdPredictNonZeros(nzeros[c], w: nzW[c], bx: sbxl, by: sbyl))
                    let nzeroCtx = jbrdNonZeroContext(predicted: predicted, blockCtx: blockCtx)
                    tokens.append(EncToken(ctx: UInt32(nzeroCtx), value: UInt32(nz)))
                    nzeros[c][sbyl * nzW[c] + sbxl] = Int32(nz)

                    let histoOffset = jbrdZeroDensityOffset(blockCtx: blockCtx)
                    var prev = nz > 64 / 16 ? 0 : 1
                    var remaining = nz
                    var k = 1
                    while k < 64 && remaining != 0 {
                        let ctx = histoOffset
                            + jbrdZeroDensityContext(nonzerosLeft: remaining, k: k, prev: prev)
                        let value = Int(J[base + jxlToNatural[Int(order[k])]])
                        tokens.append(EncToken(ctx: UInt32(ctx), value: encPackSigned(value)))
                        prev = value != 0 ? 1 : 0
                        remaining -= prev
                        k += 1
                    }
                }
            }
        }
        acTokens.append(tokens)
    }

    // ---- Modular streams: DC image, AC metadata, RAW quant table.
    // Single DC group (guarded above): rect is the whole frame.
    let rw = bw
    let rh = bh

    // DC image tokens (modular channels [Y, X, B] == components [0, 1, 2]).
    var dcTok: [EncToken] = []
    let dcStreamID = 1  // ModularStreamId::VarDCTDC(0)
    for mc in 0..<3 {
        let cw = jp.components[mc].widthInBlocks
        let ch = jp.components[mc].heightInBlocks
        dcPlane[mc].withUnsafeBufferPointer { buf in
            tokenizeChannelWithTree(
                into: &dcTok, plane: buf, width: cw, x0: 0, y0: 0, gw: cw, gh: ch,
                chan: mc, streamID: dcStreamID, tree: jbrdTree)
        }
    }

    // AC metadata tokens (ytox/ytob = 0, strategy 0, quant coded 0, epf 0).
    let crW = divCeil(rw, kColorTileDimInBlocks)
    let crH = divCeil(rh, kColorTileDimInBlocks)
    let count = rw * rh
    let cmapX = [Int32](repeating: 0, count: crW * crH)
    let cmapB = [Int32](repeating: 0, count: crW * crH)
    let acsQF = [Int32](repeating: 0, count: count * 2)
    let epfZero = [Int32](repeating: 0, count: rw * rh)
    var metaTok: [EncToken] = []
    let metaStreamID = 1 + 2 * dim.numDCGroups  // ModularStreamId::ACMetadata(0)
    let metaChans: [(plane: [Int32], w: Int, h: Int)] = [
        (cmapX, crW, crH), (cmapB, crW, crH), (acsQF, count, 2), (epfZero, rw, rh),
    ]
    for (i, ch) in metaChans.enumerated() {
        ch.plane.withUnsafeBufferPointer { buf in
            tokenizeChannelWithTree(
                into: &metaTok, plane: buf, width: ch.w, x0: 0, y0: 0, gw: ch.w, gh: ch.h,
                chan: i, streamID: metaStreamID, tree: jbrdTree)
        }
    }

    // RAW quant table 0 (DCT8): 3 channels 8x8, each the transpose of the
    // corresponding JPEG plane's quant table.
    var quantChans = [[Int32]](repeating: [Int32](repeating: 0, count: 64), count: 3)
    for c in 0..<3 {
        let comp = jp.components[kJpegCMap[c]]
        let qv = jp.quant[comp.quantIdx].values
        for p in 0..<64 { quantChans[c][p] = qv[(p % 8) * 8 + (p / 8)] }
    }
    var quantTok: [EncToken] = []
    let quantStreamID = 1 + 3 * dim.numDCGroups  // ModularStreamId::QuantTable(0)
    for c in 0..<3 {
        quantChans[c].withUnsafeBufferPointer { buf in
            tokenizeChannelWithTree(
                into: &quantTok, plane: buf, width: 8, x0: 0, y0: 0, gw: 8, gh: 8,
                chan: c, streamID: quantStreamID, tree: jbrdTree)
        }
    }

    // ---- Entropy back-ends.
    let residual = ANSEntropyEncoder(
        numContexts: treeNumLeaves(jbrdTree), streams: [dcTok, metaTok, quantTok])
    let acCoder = JBRDACCoder(numContexts: kJBRDNumACContexts, streams: acTokens)

    // ---- Section writers.
    func writeLfGlobal(_ s: BitWriter) {
        s.writeBool(true)  // dc_quant all_default
        s.writeU32(
            globalScale, .bits(11, offset: 1), .bits(11, offset: 2049), .bits(12, offset: 4097),
            .bits(16, offset: 8193))
        s.writeU32(
            quantDC, .value(16), .bits(5, offset: 1), .bits(8, offset: 1), .bits(16, offset: 1))
        s.writeBool(true)  // block context map all_default
        // Color correlation: NOT all_default. The default has baseCorrelationB
        // = 1.0 (kYToBRatio), but JPEG reconstruction requires baseB == 0 (as
        // well as colorFactor 84, baseX 0, yToXDC/yToBDC 0). Write those.
        s.writeBool(false)  // color correlation not all_default
        s.writeU32(84, .value(84), .value(256), .bits(8, offset: 2), .bits(16, offset: 258))
        s.writeF16(0)  // base_correlation_x = 0
        s.writeF16(0)  // base_correlation_b = 0
        s.write(128, 8)  // ytox_dc = 128 - 128 = 0
        s.write(128, 8)  // ytob_dc = 128 - 128 = 0
        s.writeBool(true)  // has_tree
        let tTokens = treeTokens(jbrdTree)
        let tEnc = PrefixEntropyEncoder(numContexts: 6, streams: [tTokens])
        tEnc.writeHeader(s)
        tEnc.encodeStream(s, tTokens)
        residual.writeHeader(s)
    }
    func writeDCGroup(_ s: BitWriter) {
        s.write(0, 2)  // extra_precision = 0
        s.writeBool(true)  // use_global_tree
        s.writeBool(true)  // wp_header all_default
        s.write(0, 2)  // nb_transforms = 0
        residual.encodeStream(s, dcTok)
        // AC metadata.
        let upperBound = rw * rh
        let nbits = ceilLog2Nonzero(UInt32(upperBound))
        if nbits > 0 { s.write(UInt64(upperBound - 1), nbits) }  // count - 1
        s.writeBool(true)
        s.writeBool(true)
        s.write(0, 2)
        residual.encodeStream(s, metaTok)
    }
    func writeHfGlobal(_ s: BitWriter) {
        s.write(0, 1)  // dequant NOT all_default
        // Table 0 (DCT8): RAW.
        s.write(7, 3)
        s.writeF16(1.0 / (8 * 255))
        s.writeBool(true)  // use_global_tree
        s.writeBool(true)  // wp_header all_default
        s.write(0, 2)  // nb_transforms = 0
        residual.encodeStream(s, quantTok)
        // Tables 1..16: library defaults.
        for _ in 1..<kNumQuantTablesTotal { s.write(0, 3) }
        let histoBits = ceilLog2Nonzero(UInt32(dim.numGroups))
        if histoBits > 0 { s.write(0, histoBits) }  // num_histograms - 1 = 0
        s.writeU32(0, .value(0x5F), .value(0x13), .value(0), .bits(13))  // used_orders = 0
        acCoder.writeHeader(s)
    }
    func writeACGroup(_ s: BitWriter, _ g: Int) {
        acCoder.encodeStream(s, acTokens[g])
    }

    // ---- Assembly.
    let head = BitWriter()
    HeaderWriter.writeCodestreamHeaders(
        head, width: UInt32(w), height: UInt32(h), bitsPerSample: 8, grayscale: false)
    writeTranscodeFrameHeader(head, chromaChannelMode: chromaChannelMode)

    if dim.numGroups == 1 {
        let s = BitWriter()
        writeLfGlobal(s)
        writeDCGroup(s)
        writeHfGlobal(s)
        writeACGroup(s, 0)
        let section = s.finalize()
        head.writeBool(false)  // TOC: no permutation
        head.alignToByte()
        writeTocSize(head, section.count)
        head.alignToByte()
        head.append(bytes: section)
        return head.finalize()
    }

    var sections: [[UInt8]] = []
    let s0 = BitWriter()
    writeLfGlobal(s0)
    sections.append(s0.finalize())
    let sDC = BitWriter()
    writeDCGroup(sDC)
    sections.append(sDC.finalize())
    let sHf = BitWriter()
    writeHfGlobal(sHf)
    sections.append(sHf.finalize())
    for g in 0..<dim.numGroups {
        let s = BitWriter()
        writeACGroup(s, g)
        sections.append(s.finalize())
    }
    head.writeBool(false)  // TOC: no permutation
    head.alignToByte()
    for section in sections { writeTocSize(head, section.count) }
    head.alignToByte()
    for section in sections { head.append(bytes: section) }
    return head.finalize()
}

// MARK: - Public entry point

enum JPEGTranscodeEncoder {
    static func encode(_ jpeg: [UInt8]) throws -> [UInt8] {
        let jp = try parseJPEG(jpeg)
        let jbrd = try serializeJBRD(jp)
        let codestream = try buildTranscodeCodestream(jp)
        // Container layout (unchanged, byte-exact): signature, ftyp, jbrd,
        // Exif (when the JPEG carried one), jxlc. `jp.exifPayload` already
        // includes the Exif box's 4-byte TIFF-offset prefix.
        var boxes = [ContainerBox(type: "jbrd", payload: jbrd)]
        if let exif = jp.exifPayload {
            boxes.append(ContainerBox(type: "Exif", payload: exif))
        }
        return try ContainerWriter.assemble(codestream: codestream, metadataBoxes: boxes)
    }
}

extension JXL {
    /// Losslessly recompresses a baseline (sequential, Huffman) JPEG into a
    /// JPEG XL container. Reconstructing the JPEG from the result (via
    /// `JXL.reconstructJPEG` or `djxl`) yields the byte-identical original.
    /// Rejects progressive / arithmetic / non-YCbCr / >2048px JPEGs.
    public static func encodeJPEGTranscode(jpeg: [UInt8]) throws -> [UInt8] {
        try JPEGTranscodeEncoder.encode(jpeg)
    }
}
