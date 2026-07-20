// ANSReader.swift
//
// `ANSCode` (a decoded entropy-code header) and `ANSSymbolReader` (the running
// decoder). Mirrors libjxl v0.11.2 `ANSCode` / `ANSSymbolReader` in dec_ans.h.
// Handles both back-ends (ANS via alias table, or prefix codes), the hybrid-uint
// value reconstruction, and the LZ77 copy layer.

import Foundation

let kWindowSize = 1 << 20
let kWindowMask = kWindowSize - 1
let kNumSpecialDistances = 120

/// WebP-lossless special distance table (dec_ans.h `kSpecialDistances`).
private let kSpecialDistances: [(Int, Int)] = [
    (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2),
    (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3),
    (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0),
    (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4),
    (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
    (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2),
    (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
    (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2),
    (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
    (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
    (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2),
    (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
    (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6),
    (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
    (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7),
]

func specialDistance(index: Int, multiplier: Int) -> Int {
    let d = kSpecialDistances[index]
    let dist = d.0 + multiplier * d.1
    return dist > 1 ? dist : 1
}

struct LZ77Params {
    var enabled = false
    var minSymbol: UInt32 = 224
    var minLength: UInt32 = 3
    var lengthUintConfig = HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0)
    var nonserializedDistanceContext = 0
}

/// A fully-decoded entropy-code header: enough to construct an `ANSSymbolReader`.
public struct ANSCode: Sendable {
    var usePrefixCode = false
    var logAlphaSize = 0
    var aliasTables: [AliasEntry] = []  // flat: numHistograms * (1 << logAlphaSize)
    var huffmanData: [PrefixCode] = []
    var uintConfig: [HybridUintConfig] = []
    var lz77 = LZ77Params()
}

/// The running ANS/prefix symbol decoder over a `BitReader`.
public final class ANSSymbolReader {
    private let code: ANSCode
    private var state: UInt32
    private let usePrefixCode: Bool
    private let logAlphaSize: Int
    private let logEntrySize: Int
    private let entrySizeMinus1: Int

    // Hot-path tables as private allocations: the per-symbol loop cannot
    // afford array borrow/bounds machinery (see ARCHITECTURE.md "Decode
    // performance"). Copied from `code` at init; a reader decodes a whole
    // group stream, so the one-time copies are noise.
    private let aliasP: UnsafeMutablePointer<AliasEntry>?
    private let uintP: UnsafeMutablePointer<HybridUintConfig>

    // LZ77 state.
    private let lz77Enabled: Bool
    private let lz77Window: UnsafeMutablePointer<UInt32>?
    private let lz77Ctx: Int
    private let lz77LengthUint: HybridUintConfig
    private let lz77Threshold: UInt32
    private let lz77MinLength: UInt32
    private let numSpecialDistances: Int
    private let specialDistances: [Int]
    private var numToCopy = 0
    private var copyPos = 0
    private var numDecoded = 0

    init(code: ANSCode, reader br: BitReader, distanceMultiplier: Int = 0) {
        self.code = code
        usePrefixCode = code.usePrefixCode
        logAlphaSize = code.logAlphaSize
        if !usePrefixCode {
            state = UInt32(truncatingIfNeeded: br.read(32))
            logEntrySize = ansLogTabSize - code.logAlphaSize
            entrySizeMinus1 = (1 << logEntrySize) - 1
            let p = UnsafeMutablePointer<AliasEntry>.allocate(capacity: code.aliasTables.count)
            code.aliasTables.withUnsafeBufferPointer {
                p.initialize(from: $0.baseAddress!, count: $0.count)
            }
            aliasP = p
        } else {
            state = ansSignature << 16
            logEntrySize = 0
            entrySizeMinus1 = 0
            aliasP = nil
        }
        let up = UnsafeMutablePointer<HybridUintConfig>.allocate(capacity: code.uintConfig.count)
        code.uintConfig.withUnsafeBufferPointer {
            up.initialize(from: $0.baseAddress!, count: $0.count)
        }
        uintP = up

        lz77Enabled = code.lz77.enabled
        lz77Ctx = code.lz77.nonserializedDistanceContext
        lz77LengthUint = code.lz77.lengthUintConfig
        lz77Threshold = code.lz77.minSymbol
        lz77MinLength = code.lz77.minLength
        if code.lz77.enabled {
            let w = UnsafeMutablePointer<UInt32>.allocate(capacity: kWindowSize)
            w.initialize(repeating: 0, count: kWindowSize)
            lz77Window = w
            numSpecialDistances = distanceMultiplier == 0 ? 0 : kNumSpecialDistances
            specialDistances = (0..<numSpecialDistances).map {
                specialDistance(index: $0, multiplier: distanceMultiplier)
            }
        } else {
            lz77Window = nil
            numSpecialDistances = 0
            specialDistances = []
        }
    }

    deinit {
        aliasP?.deallocate()
        uintP.deallocate()
        lz77Window?.deallocate()
    }

    // MARK: Raw symbol (token) decode

    @inline(__always)
    private func readSymbolANS(_ histoIdx: Int, _ br: BitReader) -> Int {
        let res = Int(state) & ansTabMask
        let base = histoIdx << logAlphaSize
        let sym = aliasLookup(
            aliasP!, base: base, value: res, logEntrySize: logEntrySize,
            entrySizeMinus1: entrySizeMinus1)
        state =
            UInt32(truncatingIfNeeded: sym.freq) &* (state >> UInt32(ansLogTabSize))
            &+ UInt32(truncatingIfNeeded: sym.offset)
        if state < (1 << 16) {
            state = (state << 16) | UInt32(truncatingIfNeeded: br.read(16))
        }
        return sym.value
    }

    @inline(__always)
    private func readSymbol(_ histoIdx: Int, _ br: BitReader) -> Int {
        if usePrefixCode { return Int(code.huffmanData[histoIdx].readSymbol(br)) }
        return readSymbolANS(histoIdx, br)
    }

    public func checkANSFinalState() -> Bool {
        usePrefixCode || state == (ansSignature << 16)
    }

    // MARK: Hybrid-uint value (token -> value, with LZ77)

    /// Reads one value for an already-clustered context (mirrors
    /// `ReadHybridUintClustered`).
    func readHybridUintClustered(_ ctx: Int, _ br: BitReader) -> UInt32 {
        if lz77Enabled && numToCopy > 0 {
            let window = lz77Window!
            let ret = window[copyPos & kWindowMask]
            copyPos += 1
            numToCopy -= 1
            window[numDecoded & kWindowMask] = ret
            numDecoded += 1
            return ret
        }

        let token = readSymbol(ctx, br)
        if lz77Enabled && UInt32(token) >= lz77Threshold {
            let window = lz77Window!
            numToCopy =
                Int(lz77LengthUint.decode(token: UInt32(token) - lz77Threshold, reader: br))
                + Int(lz77MinLength)
            // Distance code.
            let distToken = readSymbol(lz77Ctx, br)
            var distance = Int(uintP[lz77Ctx].decode(token: UInt32(distToken), reader: br))
            if distance < numSpecialDistances {
                distance = specialDistances[distance]
            } else {
                distance = distance + 1 - numSpecialDistances
            }
            if distance > numDecoded { distance = numDecoded }
            if distance > kWindowSize { distance = kWindowSize }
            copyPos = numDecoded - distance
            if distance == 0 {
                let toFill = min(numToCopy, kWindowSize)
                for k in 0..<toFill { window[k] = 0 }
            }
            if numToCopy < Int(lz77MinLength) { return 0 }
            let ret = window[copyPos & kWindowMask]
            copyPos += 1
            numToCopy -= 1
            window[numDecoded & kWindowMask] = ret
            numDecoded += 1
            return ret
        }

        let ret = uintP[ctx].decode(token: UInt32(token), reader: br)
        if lz77Enabled {
            lz77Window![numDecoded & kWindowMask] = ret
            numDecoded += 1
        }
        return ret
    }

    /// Reads one value for a raw context, applying the context map.
    public func readHybridUint(_ ctx: Int, _ br: BitReader, contextMap: [UInt8]) -> UInt32 {
        readHybridUintClustered(Int(contextMap[ctx]), br)
    }
}
