// JPEGReconData.swift
//
// The `jbrd` (JPEG reconstruction) box payload: a bit-packed JPEGData bundle
// (libjxl jpeg_data.cc JPEGData::VisitFields, reading path) followed by one
// Brotli stream carrying the marker payloads the codestream doesn't encode
// (unknown APP markers, COM, inter-marker data, tail data). Everything else
// needed to rebuild the original JPEG bytes — quant values, DCT coefficients,
// ICC — comes from the codestream and is filled in by the reconstruction
// step, not here.

import Foundation

struct JPEGQuantTableInfo {
    var precision: UInt32 = 0
    var index: UInt32 = 0
    var isLast = true
    /// Filled from the codestream's RAW quant tables during reconstruction.
    var values = [Int32](repeating: 0, count: 64)
}

struct JPEGHuffmanCodeInfo {
    /// Bit-length histogram, counts[1...16].
    var counts = [UInt32](repeating: 0, count: 17)
    /// Symbol values sorted by increasing bit length; the last is the
    /// synthetic 256 (EOI sentinel, not written to DHT).
    var values = [UInt32](repeating: 0, count: 257)
    var numSymbols = 0
    /// DHT slot: AC codes have 0x10 added.
    var slotID: UInt32 = 0
    var isLast = true
}

struct JPEGScanComponentInfo {
    var compIdx: UInt32 = 0
    var dcTblIdx: UInt32 = 0
    var acTblIdx: UInt32 = 0
}

struct JPEGScanInfo {
    var ss: UInt32 = 0
    var se: UInt32 = 63
    var ah: UInt32 = 0
    var al: UInt32 = 0
    var numComponents: UInt32 = 0
    var components = [JPEGScanComponentInfo](repeating: JPEGScanComponentInfo(), count: 4)
    var lastNeededPass: UInt32 = 0
    /// Block indices where the encoder flushed EOB runs / refinement bits.
    var resetPoints: [UInt32] = []
    /// (blockIdx, count) pairs of redundant 0xF0 zero-run symbols.
    var extraZeroRuns: [(blockIdx: UInt32, count: UInt32)] = []
}

enum JPEGAppMarkerType: UInt32 {
    case unknown = 0
    case icc = 1
    case exif = 2
    case xmp = 3
}

struct JPEGComponentInfo {
    var id: UInt32 = 0
    var quantIdx: UInt32 = 0
    /// Filled from the codestream (frame dimensions + chroma subsampling).
    var hSampFactor = 1
    var vSampFactor = 1
    var widthInBlocks = 0
    var heightInBlocks = 0
    /// Quantized DCT coefficients, block raster order × 64 natural order.
    var coeffs: [Int16] = []
}

/// Parsed jbrd payload (metadata only; coefficient/quant plumbing is separate).
struct JPEGReconData {
    var isGray = false
    var markerOrder: [UInt8] = []
    var appData: [[UInt8]] = []
    var appMarkerType: [JPEGAppMarkerType] = []
    var comData: [[UInt8]] = []
    var quant: [JPEGQuantTableInfo] = []
    var components: [JPEGComponentInfo] = []
    var huffmanCodes: [JPEGHuffmanCodeInfo] = []
    var scans: [JPEGScanInfo] = []
    var restartInterval: UInt32 = 0
    var interMarkerData: [[UInt8]] = []
    var tailData: [UInt8] = []
    var hasZeroPaddingBit = false
    var paddingBits: [Bool] = []
}

private let kMaxNumPasses = 11  // libjxl common.h

/// Diagnostic summary of a file's jbrd box (SPI: exercised by the `jxl jbrd`
/// CLI command while the reconstruction pipeline is under construction).
@_spi(Stages) public func describeJBRD(from data: [UInt8]) throws -> String {
    let parsed = try JXLContainer.parse(data)
    guard let box = parsed.boxes.first(where: { $0.type == "jbrd" }) else {
        throw JXLError.unsupported("no jbrd box (not a JPEG transcode)")
    }
    let d = try parseJPEGReconData(Array(data[box.payload]))
    var lines: [String] = []
    let markers = d.markerOrder.map { String(format: "%02X", $0) }.joined(separator: " ")
    lines.append("markers: \(markers)")
    lines.append(
        "app markers: \(d.appData.count) \(d.appMarkerType.map { "\($0)" }.joined(separator: ","))"
    )
    lines.append("com markers: \(d.comData.count)")
    lines.append("quant tables: \(d.quant.count)")
    lines.append(
        "components: \(d.components.count) ids=\(d.components.map(\.id)) quantIdx=\(d.components.map(\.quantIdx))"
    )
    lines.append("huffman codes: \(d.huffmanCodes.count)")
    for scan in d.scans {
        lines.append(
            "scan: comps=\(scan.numComponents) Ss=\(scan.ss) Se=\(scan.se) Ah=\(scan.ah) Al=\(scan.al) resets=\(scan.resetPoints.count) extraZeroRuns=\(scan.extraZeroRuns.count)"
        )
    }
    lines.append("restart interval: \(d.restartInterval)")
    lines.append(
        "inter-marker: \(d.interMarkerData.count), tail: \(d.tailData.count) B, padding bits: \(d.paddingBits.count)"
    )
    return lines.joined(separator: "\n")
}

/// Parses a jbrd box payload. Mirrors `JPEGData::VisitFields` (reading path)
/// followed by dec_jpeg_data.cc's Brotli fill of the marker payloads.
func parseJPEGReconData(_ payload: [UInt8]) throws -> JPEGReconData {
    let br = BitReader(payload)
    var d = JPEGReconData()

    d.isGray = br.readBool()

    // Marker order, 6 bits per marker relative to 0xC0, terminated by EOI.
    var numApp = 0
    var numCom = 0
    var numScans = 0
    var numIntermarker = 0
    var hasDri = false
    while true {
        let marker = UInt8(truncatingIfNeeded: br.read(6)) &+ 0xC0
        d.markerOrder.append(marker)
        if (marker & 0xF0) == 0xE0 { numApp += 1 }
        if marker == 0xFE { numCom += 1 }
        if marker == 0xDA { numScans += 1 }
        if marker == 0xFF { numIntermarker += 1 }  // fake marker: inter-marker data
        if marker == 0xDD { hasDri = true }
        if marker == 0xD9 { break }
        guard d.markerOrder.count <= 16384 else {
            throw JXLError.malformed("jbrd: too many markers")
        }
        try br.ensureInBounds("jbrd marker order")
    }

    // APP marker types and sizes (payloads come from the Brotli tail or the
    // codestream, depending on type).
    for _ in 0..<numApp {
        let rawType = br.readU32(.value(0), .value(1), .bits(1, offset: 2), .bits(2, offset: 4))
        guard let type = JPEGAppMarkerType(rawValue: rawType) else {
            throw JXLError.malformed("jbrd: unknown app marker type \(rawType)")
        }
        d.appMarkerType.append(type)
        let len = Int(br.read(16))
        guard len + 1 >= 3 else { throw JXLError.malformed("jbrd: invalid app marker size") }
        d.appData.append([UInt8](repeating: 0, count: len + 1))
    }
    for _ in 0..<numCom {
        let len = Int(br.read(16))
        guard len + 1 >= 3 else { throw JXLError.malformed("jbrd: invalid COM marker size") }
        d.comData.append([UInt8](repeating: 0, count: len + 1))
    }

    // Quant table shells (values arrive from the codestream).
    let numQuantTables = br.readU32(.value(1), .value(2), .value(3), .value(4))
    guard numQuantTables != 4 else { throw JXLError.malformed("jbrd: invalid quant table count") }
    for _ in 0..<Int(numQuantTables) {
        var q = JPEGQuantTableInfo()
        q.precision = UInt32(br.read(1))
        q.index = UInt32(br.read(2))
        q.isLast = br.readBool()
        d.quant.append(q)
    }

    // Component ids.
    let componentType = UInt32(br.read(2))  // kGray/kYCbCr/kRGB/kCustom
    var numComponents: Int
    switch componentType {
    case 0: numComponents = 1
    case 1, 2: numComponents = 3
    default:
        let n = br.readU32(.value(1), .value(2), .value(3), .value(4))
        guard n == 1 || n == 3 else {
            throw JXLError.malformed("jbrd: invalid component count")
        }
        numComponents = Int(n)
    }
    d.components = (0..<numComponents).map { _ in JPEGComponentInfo() }
    switch componentType {
    case 0:
        d.components[0].id = 1
    case 1:
        for (i, id) in [1, 2, 3].enumerated() { d.components[i].id = UInt32(id) }
    case 2:
        for (i, id) in ["R", "G", "B"].enumerated() {
            d.components[i].id = UInt32(id.unicodeScalars.first!.value)
        }
    default:
        for i in 0..<numComponents { d.components[i].id = UInt32(br.read(8)) }
    }
    for i in 0..<numComponents {
        d.components[i].quantIdx = UInt32(br.read(2))
        guard d.components[i].quantIdx < numQuantTables else {
            throw JXLError.malformed("jbrd: invalid component quant table")
        }
    }

    // Huffman codes.
    let numHuff = br.readU32(
        .value(4), .bits(3, offset: 2), .bits(4, offset: 10), .bits(6, offset: 26))
    guard numHuff <= 512 else { throw JXLError.malformed("jbrd: too many Huffman codes") }
    for _ in 0..<numHuff {
        var hc = JPEGHuffmanCodeInfo()
        let isAC = br.readBool()
        let id = UInt32(br.read(2))
        hc.slotID = (isAC ? 0x10 : 0) | id
        hc.isLast = br.readBool()
        var numSymbols = 0
        for i in 0...16 {
            hc.counts[i] = br.readU32(.value(0), .value(1), .bits(3, offset: 2), .bits(8))
            numSymbols += Int(hc.counts[i])
        }
        guard numSymbols >= 1, numSymbols <= 257 else {
            throw JXLError.malformed("jbrd: bad Huffman symbol count")
        }
        hc.numSymbols = numSymbols
        var valueSlots = [UInt64](repeating: 0, count: 5)
        for i in 0..<numSymbols {
            hc.values[i] = br.readU32(
                .bits(2), .bits(2, offset: 4), .bits(4, offset: 8), .bits(8, offset: 1))
            valueSlots[Int(hc.values[i]) >> 6] |= UInt64(1) << (UInt64(hc.values[i]) & 0x3F)
        }
        guard hc.values[numSymbols - 1] == 256 else {
            throw JXLError.malformed("jbrd: missing EOI symbol")
        }
        var numValues = 1
        for i in 0..<4 { numValues += valueSlots[i].nonzeroBitCount }
        guard numValues == numSymbols else {
            throw JXLError.malformed("jbrd: duplicate Huffman symbols")
        }
        if !isAC {
            let onlyDC =
                ((valueSlots[0] >> 12) | valueSlots[1] | valueSlots[2] | valueSlots[3]) == 0
            guard onlyDC else { throw JXLError.malformed("jbrd: DC symbols out of range") }
        }
        d.huffmanCodes.append(hc)
    }

    // Scan scripts.
    for _ in 0..<numScans {
        var scan = JPEGScanInfo()
        scan.numComponents = br.readU32(.value(1), .value(2), .value(3), .value(4))
        guard scan.numComponents < 4 else {
            throw JXLError.malformed("jbrd: invalid scan component count")
        }
        scan.ss = UInt32(br.read(6))
        scan.se = UInt32(br.read(6))
        scan.al = UInt32(br.read(4))
        scan.ah = UInt32(br.read(4))
        for i in 0..<Int(scan.numComponents) {
            scan.components[i].compIdx = UInt32(br.read(2))
            guard scan.components[i].compIdx < UInt32(numComponents) else {
                throw JXLError.malformed("jbrd: invalid scan component index")
            }
            scan.components[i].acTblIdx = UInt32(br.read(2))
            scan.components[i].dcTblIdx = UInt32(br.read(2))
        }
        scan.lastNeededPass = br.readU32(.value(0), .value(1), .value(2), .bits(3, offset: 3))
        d.scans.append(scan)
    }

    if hasDri {
        d.restartInterval = UInt32(br.read(16))
    }

    for scanIdx in 0..<d.scans.count {
        let numResetPoints = br.readU32(
            .value(0), .bits(2, offset: 1), .bits(4, offset: 4), .bits(16, offset: 20))
        var lastBlockIdx = -1
        for _ in 0..<numResetPoints {
            let delta = br.readU32(
                .value(0), .bits(3, offset: 1), .bits(5, offset: 9), .bits(28, offset: 41))
            let blockIdx = Int(delta) + lastBlockIdx + 1
            guard blockIdx < (3 << 26) else { throw JXLError.malformed("jbrd: invalid block ID") }
            d.scans[scanIdx].resetPoints.append(UInt32(blockIdx))
            lastBlockIdx = blockIdx
        }
        let numExtraZeroRuns = br.readU32(
            .value(0), .bits(2, offset: 1), .bits(4, offset: 4), .bits(16, offset: 20))
        lastBlockIdx = -1
        for _ in 0..<numExtraZeroRuns {
            let count = br.readU32(
                .value(1), .bits(2, offset: 2), .bits(4, offset: 5), .bits(8, offset: 20))
            let delta = br.readU32(
                .value(0), .bits(3, offset: 1), .bits(5, offset: 9), .bits(28, offset: 41))
            let blockIdx = Int(delta) + lastBlockIdx + 1
            guard blockIdx <= (3 << 26) else { throw JXLError.malformed("jbrd: invalid block ID") }
            d.scans[scanIdx].extraZeroRuns.append((UInt32(blockIdx), count))
            lastBlockIdx = blockIdx
        }
        try br.ensureInBounds("jbrd scan aux")
    }

    var interMarkerSizes: [Int] = []
    for _ in 0..<numIntermarker {
        interMarkerSizes.append(Int(br.read(16)))
    }
    let tailDataLen = Int(
        br.readU32(.value(0), .bits(8, offset: 1), .bits(16, offset: 257), .bits(22, offset: 65793)))

    d.hasZeroPaddingBit = br.readBool()
    if d.hasZeroPaddingBit {
        let nbit = Int(br.read(24))
        // CheckHasEnoughBits equivalent: each padding bit is one coded bit.
        guard nbit <= br.bitsRemaining else {
            throw JXLError.malformed("jbrd: padding bits beyond payload")
        }
        d.paddingBits.reserveCapacity(nbit)
        for _ in 0..<nbit {
            d.paddingBits.append(br.readBool())
        }
    }
    try br.ensureInBounds("jbrd bundle")

    // Huffman-table-defined-before-use validation (jpeg_data.cc tail).
    var dhtIndex = 0
    var scanIndex = 0
    var isProgressive = false
    var acOK = [Bool](repeating: false, count: 4)
    var dcOK = [Bool](repeating: false, count: 4)
    for marker in d.markerOrder {
        if marker == 0xC2 {
            isProgressive = true
        } else if marker == 0xC4 {
            while dhtIndex < d.huffmanCodes.count {
                let huff = d.huffmanCodes[dhtIndex]
                dhtIndex += 1
                var index = Int(huff.slotID)
                if index & 0x10 != 0 {
                    index -= 0x10
                    guard index < 4 else { throw JXLError.malformed("jbrd: bad slot") }
                    acOK[index] = true
                } else {
                    guard index < 4 else { throw JXLError.malformed("jbrd: bad slot") }
                    dcOK[index] = true
                }
                if huff.isLast { break }
            }
        } else if marker == 0xDA {
            guard scanIndex < d.scans.count else {
                throw JXLError.malformed("jbrd: scan count mismatch")
            }
            let si = d.scans[scanIndex]
            scanIndex += 1
            for i in 0..<Int(si.numComponents) {
                let csi = si.components[i]
                let wantDC = !isProgressive || si.ss == 0
                if wantDC && !dcOK[Int(csi.dcTblIdx)] {
                    throw JXLError.malformed("jbrd: DC Huffman table used before defined")
                }
                let wantAC = !isProgressive || si.ss != 0 || si.se != 0
                if wantAC && !acOK[Int(csi.acTblIdx)] {
                    throw JXLError.malformed("jbrd: AC Huffman table used before defined")
                }
            }
        }
    }

    // The Brotli stream starts at the next byte boundary and supplies, in
    // order: unknown APP marker payloads, COM payloads, inter-marker data,
    // tail data (dec_jpeg_data.cc).
    br.alignToByte()
    let brotliStart = br.bitPosition / 8
    guard brotliStart <= payload.count else { throw JXLError.malformed("jbrd: truncated") }
    var needed = tailDataLen + interMarkerSizes.reduce(0, +)
    for (i, app) in d.appData.enumerated() where d.appMarkerType[i] == .unknown {
        needed += app.count
    }
    for com in d.comData { needed += com.count }
    let decompressed = try Brotli.decompress(
        Array(payload[brotliStart...]), maxOutputSize: max(needed, 1))
    guard decompressed.count == needed else {
        throw JXLError.malformed(
            "jbrd: Brotli payload size \(decompressed.count) != expected \(needed)")
    }
    var cursor = 0
    func take(_ n: Int) -> [UInt8] {
        defer { cursor += n }
        return Array(decompressed[cursor..<(cursor + n)])
    }
    for i in 0..<d.appData.count where d.appMarkerType[i] == .unknown {
        let marker = take(d.appData[i].count)
        guard Int(marker[1]) * 256 + Int(marker[2]) + 1 == marker.count else {
            throw JXLError.malformed("jbrd: incorrect APP marker size")
        }
        d.appData[i] = marker
    }
    for i in 0..<d.comData.count {
        let marker = take(d.comData[i].count)
        guard Int(marker[1]) * 256 + Int(marker[2]) + 1 == marker.count else {
            throw JXLError.malformed("jbrd: incorrect COM marker size")
        }
        d.comData[i] = marker
    }
    d.interMarkerData = interMarkerSizes.map { take($0) }
    d.tailData = take(tailDataLen)

    return d
}
