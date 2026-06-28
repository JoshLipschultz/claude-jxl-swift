// VarDCTInfo.swift
//
// Lightweight VarDCT section preflight. This parses the global VarDCT metadata
// that precedes LF/DC and AC coefficient payloads, matching the libjxl v0.11.2
// read order closely enough to validate section boundaries and expose useful
// state for the future full VarDCT decoder.

import Foundation

private let kNumQuantTables = 17
private let kLog2NumQuantModes = 3
private let kCeilLog2NumPredefinedTables = 0
private let kNumPredefinedTables = 1
private let kColorFactorDist0 = U32Choice.bits(2, offset: 84)
private let kColorFactorDist1 = U32Choice.bits(3, offset: 88)
private let kColorFactorDist2 = U32Choice.bits(4, offset: 72)
private let kColorFactorDist3 = U32Choice.bits(6, offset: 0)
private let kOrderEnc0 = U32Choice.value(0)
private let kOrderEnc1 = U32Choice.bits(8, offset: 1)
private let kOrderEnc2 = U32Choice.bits(10, offset: 257)
private let kOrderEnc3 = U32Choice.bits(13, offset: 1281)
private let kDCThresholdDist0 = U32Choice.bits(4, offset: 0)
private let kDCThresholdDist1 = U32Choice.bits(8, offset: 16)
private let kDCThresholdDist2 = U32Choice.bits(16, offset: 272)
private let kDCThresholdDist3 = U32Choice.bits(32, offset: 65808)
private let kQFThresholdDist0 = U32Choice.bits(2, offset: 0)
private let kQFThresholdDist1 = U32Choice.bits(3, offset: 4)
private let kQFThresholdDist2 = U32Choice.bits(5, offset: 12)
private let kQFThresholdDist3 = U32Choice.bits(8, offset: 44)
private let kNumOrders = 13
private let kDefaultBlockContextMap: [UInt8] = [
    0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
]

public enum VarDCTQuantEncodingMode: UInt32, Equatable {
    case library = 0
    case identity = 1
    case dct2 = 2
    case dct4x8 = 3
    case dct4 = 4
    case afv = 5
    case dct = 6
    case raw = 7
}

public struct VarDCTQuantizerInfo: Equatable {
    public let globalScale: UInt32
    public let quantDC: UInt32
}

public struct VarDCTColorCorrelationInfo: Equatable {
    public let allDefault: Bool
    public let colorFactor: UInt32
    public let baseCorrelationX: Float
    public let baseCorrelationB: Float
    public let yToXDC: Int8
    public let yToBDC: Int8
}

public struct VarDCTBlockContextMap: Equatable {
    public let dcThresholds: [[Int32]]
    public let qfThresholds: [UInt32]
    public let contextMap: [UInt8]
    public let numContexts: Int
    public let numDCContexts: Int

    public var isDefault: Bool {
        dcThresholds.allSatisfy(\.isEmpty) && qfThresholds.isEmpty
            && contextMap == kDefaultBlockContextMap
    }

    public var numACContexts: Int { numContexts * (kNonZeroBuckets + kZeroDensityContextCount) }
}

public struct VarDCTDCGlobalInfo: Equatable {
    public let dcQuantIsDefault: Bool
    public let dcQuant: [Float]
    public let quantizer: VarDCTQuantizerInfo
    public let blockContextMap: VarDCTBlockContextMap
    public var blockContextMapIsDefault: Bool { blockContextMap.isDefault }
    public let colorCorrelation: VarDCTColorCorrelationInfo?
    public let modularGlobalHasTree: Bool?
    public let modularGlobalTreeNodeCount: Int?
}

public struct VarDCTACGlobalInfo: Equatable {
    public let dequantMatricesAreDefault: Bool
    public let quantEncodingModes: [VarDCTQuantEncodingMode]
    public let numHistograms: Int
    public let usedOrdersPerPass: [UInt32]
    public let histogramsParsed: Bool
}

public struct JXLVarDCTInfo {
    public let frame: JXLFrameInfo
    public let dcGlobal: VarDCTDCGlobalInfo
    public let acGlobal: VarDCTACGlobalInfo?
}

/// The parsed DC-global metadata together with the decoded global modular tree
/// and entropy code, which the DC-image decode needs to continue reading.
struct VarDCTDCGlobalDecoded {
    let info: VarDCTDCGlobalInfo
    let tree: [MATreeNode]?
    let code: ANSCode?
    let ctxMap: [UInt8]?
}

/// Reads `ProcessDCGlobal` for a VarDCT frame (flags == 0: no patches/splines/
/// noise), capturing the global modular tree/code so the DC groups can use it.
/// Mirrors `DequantMatrices::DecodeDC` + `DecodeGlobalDCInfo` +
/// `ModularFrameDecoder::DecodeGlobalInfo` (the empty-global-image path).
func readVarDCTDCGlobal(_ br: BitReader) throws -> VarDCTDCGlobalDecoded {
    let dcQuantIsDefault = br.read(1) == 1
    var dcQuant: [Float] = []
    if !dcQuantIsDefault {
        for _ in 0..<3 { dcQuant.append(br.readF16() * (1.0 / 128.0)) }
    }

    let quantizer = VarDCTQuantizerInfo(
        globalScale: br.readU32(
            .bits(11, offset: 1), .bits(11, offset: 2049), .bits(12, offset: 4097),
            .bits(16, offset: 8193)),
        quantDC: br.readU32(
            .value(16), .bits(5, offset: 1), .bits(8, offset: 1), .bits(16, offset: 1)))

    let blockContextMap = try readBlockContextMap(br)

    let colorCorrelation = readColorCorrelationDC(br)
    let modularGlobalHasTree = br.read(1) == 1
    var modularGlobalTreeNodeCount = 0
    var tree: [MATreeNode]? = nil
    var code: ANSCode? = nil
    var ctxMap: [UInt8]? = nil
    if modularGlobalHasTree {
        guard let t = decodeMATree(br, treeSizeLimit: 1 << 22),
            let (c, m) = decodeHistograms(
                br, numContexts: (t.count + 1) / 2, disallowLZ77: false)
        else { throw JXLError.malformed("could not read VarDCT global modular tree") }
        tree = t
        code = c
        ctxMap = m
        modularGlobalTreeNodeCount = t.count
    }
    // For a VarDCT frame with no extra channels the global modular image has
    // zero channels, so ModularDecode returns immediately and reads no group
    // header here (libjxl `if (image.channel.empty()) return true;`).

    try br.ensureInBounds("VarDCT DC global")
    let info = VarDCTDCGlobalInfo(
        dcQuantIsDefault: dcQuantIsDefault,
        dcQuant: dcQuant,
        quantizer: quantizer,
        blockContextMap: blockContextMap,
        colorCorrelation: colorCorrelation,
        modularGlobalHasTree: modularGlobalHasTree,
        modularGlobalTreeNodeCount: modularGlobalTreeNodeCount)
    return VarDCTDCGlobalDecoded(info: info, tree: tree, code: code, ctxMap: ctxMap)
}

func readVarDCTDCGlobalInfo(_ br: BitReader) throws -> VarDCTDCGlobalInfo {
    try readVarDCTDCGlobal(br).info
}

func readVarDCTACGlobalInfo(
    _ br: BitReader, frame: JXLFrameInfo, blockContextMap: VarDCTBlockContextMap
) throws -> VarDCTACGlobalInfo {
    let dequantDefault = br.read(1) == 1
    var modes: [VarDCTQuantEncodingMode] = []
    if !dequantDefault {
        for table in 0..<kNumQuantTables {
            modes.append(try readQuantEncodingHeader(br, tableIndex: table))
        }
    }

    let histoBits = ceilLog2Nonzero(UInt32(frame.numGroups))
    let numHistograms = Int(br.read(histoBits)) + 1
    var usedOrders: [UInt32] = []
    for _ in 0..<frame.numPasses {
        let used = br.readU32(kOrderEnc0, kOrderEnc1, kOrderEnc2, kOrderEnc3)
        usedOrders.append(used)
        if used != 0 {
            // Custom coefficient orders are serialized before this pass's AC
            // histograms. Preserve bitstream alignment by reporting partial
            // AC-global preflight metadata instead of consuming unknown bits.
            try br.ensureInBounds("VarDCT AC global")
            return VarDCTACGlobalInfo(
                dequantMatricesAreDefault: dequantDefault,
                quantEncodingModes: modes,
                numHistograms: numHistograms,
                usedOrdersPerPass: usedOrders,
                histogramsParsed: false)
        }
        let numContexts = numHistograms * blockContextMap.numACContexts
        guard decodeHistograms(br, numContexts: numContexts, disallowLZ77: false) != nil else {
            throw JXLError.malformed("could not read VarDCT AC histograms")
        }
    }

    try br.ensureInBounds("VarDCT AC global")
    return VarDCTACGlobalInfo(
        dequantMatricesAreDefault: dequantDefault,
        quantEncodingModes: modes,
        numHistograms: numHistograms,
        usedOrdersPerPass: usedOrders,
        histogramsParsed: true)
}

private let kNonZeroBuckets = 37
private let kZeroDensityContextCount = 458

private func readBlockContextMap(_ br: BitReader) throws -> VarDCTBlockContextMap {
    let isDefault = br.read(1) == 1
    if isDefault {
        return VarDCTBlockContextMap(
            dcThresholds: [[], [], []],
            qfThresholds: [],
            contextMap: kDefaultBlockContextMap,
            numContexts: 15,
            numDCContexts: 1)
    }

    var dcThresholds = [[Int32]](repeating: [], count: 3)
    var numDCContexts = 1
    for channel in 0..<3 {
        let count = Int(br.read(4))
        numDCContexts *= count + 1
        dcThresholds[channel].reserveCapacity(count)
        for _ in 0..<count {
            let packed = br.readU32(
                kDCThresholdDist0, kDCThresholdDist1, kDCThresholdDist2, kDCThresholdDist3)
            dcThresholds[channel].append(Int32(truncatingIfNeeded: unpackSigned(packed)))
        }
    }

    let qfCount = Int(br.read(4))
    var qfThresholds: [UInt32] = []
    qfThresholds.reserveCapacity(qfCount)
    for _ in 0..<qfCount {
        qfThresholds.append(
            br.readU32(kQFThresholdDist0, kQFThresholdDist1, kQFThresholdDist2, kQFThresholdDist3)
                + 1)
    }

    guard numDCContexts * (qfThresholds.count + 1) <= 64 else {
        throw JXLError.malformed("invalid VarDCT block context map: too big")
    }

    let contextMapSize = 3 * kNumOrders * numDCContexts * (qfThresholds.count + 1)
    guard let decoded = decodeContextMap(br, size: contextMapSize) else {
        throw JXLError.malformed("could not read VarDCT block context map")
    }
    guard decoded.numHistograms <= 16 else {
        throw JXLError.malformed("invalid VarDCT block context map: too many contexts")
    }

    return VarDCTBlockContextMap(
        dcThresholds: dcThresholds,
        qfThresholds: qfThresholds,
        contextMap: decoded.contextMap,
        numContexts: decoded.numHistograms,
        numDCContexts: numDCContexts)
}

private func readColorCorrelationDC(_ br: BitReader) -> VarDCTColorCorrelationInfo {
    let allDefault = br.read(1) == 1
    if allDefault {
        return VarDCTColorCorrelationInfo(
            allDefault: true, colorFactor: 84, baseCorrelationX: 0.0,
            baseCorrelationB: 1.0, yToXDC: 0, yToBDC: 0)
    }
    let colorFactor = br.readU32(
        kColorFactorDist0, kColorFactorDist1, kColorFactorDist2, kColorFactorDist3)
    let baseX = br.readF16()
    let baseB = br.readF16()
    let yToX = Int8(bitPattern: UInt8(truncatingIfNeeded: br.read(8)))
    let yToB = Int8(bitPattern: UInt8(truncatingIfNeeded: br.read(8)))
    return VarDCTColorCorrelationInfo(
        allDefault: false, colorFactor: colorFactor, baseCorrelationX: baseX,
        baseCorrelationB: baseB, yToXDC: yToX, yToBDC: yToB)
}

private func readQuantEncodingHeader(_ br: BitReader, tableIndex: Int) throws
    -> VarDCTQuantEncodingMode
{
    guard let mode = VarDCTQuantEncodingMode(rawValue: UInt32(br.read(kLog2NumQuantModes))) else {
        throw JXLError.malformed("invalid VarDCT quant encoding mode")
    }
    let requiredSize = requiredQuantSizeX[tableIndex] * requiredQuantSizeY[tableIndex]
    switch mode {
    case .library:
        let predefined =
            kCeilLog2NumPredefinedTables == 0 ? 0 : br.read(kCeilLog2NumPredefinedTables)
        if predefined >= kNumPredefinedTables {
            throw JXLError.malformed("invalid predefined VarDCT quant table")
        }
    case .identity:
        if requiredSize != 1 {
            throw JXLError.malformed("identity quant encoding for non-8x8 table")
        }
        for _ in 0..<(3 * 3) { _ = br.readF16() }
    case .dct2:
        if requiredSize != 1 { throw JXLError.malformed("DCT2 quant encoding for non-8x8 table") }
        for _ in 0..<(3 * 6) { _ = br.readF16() }
    case .dct4x8:
        if requiredSize != 1 { throw JXLError.malformed("DCT4x8 quant encoding for non-8x8 table") }
        for _ in 0..<3 { _ = br.readF16() }
        readDCTParams(br)
    case .dct4:
        if requiredSize != 1 { throw JXLError.malformed("DCT4 quant encoding for non-8x8 table") }
        for _ in 0..<(3 * 2) { _ = br.readF16() }
        readDCTParams(br)
    case .afv:
        if requiredSize != 1 { throw JXLError.malformed("AFV quant encoding for non-8x8 table") }
        for _ in 0..<(3 * 9) { _ = br.readF16() }
        readDCTParams(br)
        readDCTParams(br)
    case .dct:
        readDCTParams(br)
    case .raw:
        // RAW tables are modular-coded and need the full modular decoder plus
        // quant-table stream IDs. Preserve alignment by rejecting for now.
        throw JXLError.unsupported("RAW VarDCT quant tables")
    }
    return mode
}

private func readDCTParams(_ br: BitReader) {
    let numBands = br.read(3) + 1
    for _ in 0..<(3 * numBands) { _ = br.readF16() }
}

private let requiredQuantSizeX = [1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16]
private let requiredQuantSizeY = [1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32]
