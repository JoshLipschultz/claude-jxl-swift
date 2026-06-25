// TestRunner.swift
//
// A dependency-free test runner compiled *together* with the JXLCore sources
// (single module), so it can exercise internal API without XCTest. This is the
// suite we can actually run while the CLT SwiftPM build service is broken; the
// XCTest mirror under Tests/JXLCoreTests is for `swift test` once Xcode exists.
//
// Build/run via Scripts/run-tests.sh.

import Foundation

@main
struct TestRunner {
    static var passed = 0
    static var failed = 0

    static func check(
        _ condition: @autoclosure () -> Bool, _ label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            FileHandle.standardError.write(Data("  ✗ \(label)  (\(file):\(line))\n".utf8))
        }
    }

    static func eq<T: Equatable>(
        _ a: T, _ b: T, _ label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        if a == b {
            passed += 1
        } else {
            failed += 1
            FileHandle.standardError.write(
                Data("  ✗ \(label): \(a) != \(b)  (\(file):\(line))\n".utf8))
        }
    }

    static func fixturesDir() -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1])
        }
        // Derive from this source file's compile-time path: <root>/Tests/Standalone/TestRunner.swift
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent()  // Standalone
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("JXLCoreTests/Fixtures")
    }

    static func main() {
        print("Running JXLCore standalone tests...")
        bitstream()
        headers()
        metadata()
        container()
        entropy()
        frame()

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - Bitstream

    static func bitstream() {
        // LSB-first read of 0xB2 = 0b1011_0010
        let r = BitReader([0xB2])
        eq(r.read(1), 0, "B2 bit0")
        eq(r.read(1), 1, "B2 bit1")
        eq(r.read(2), 0, "B2 bits2-3")
        eq(r.read(4), 0b1011, "B2 bits4-7")
        check(r.isAtEnd, "B2 at end")

        eq(BitReader([0xFF, 0x0A]).read(16), 0x0AFF, "FF0A as 16 bits")

        let over = BitReader([0xFF])
        eq(over.read(8), 0xFF, "overread first byte")
        eq(over.read(8), 0, "overread past end -> 0")
        check(over.didOverread, "overread latched")

        // U64 vectors
        eq(BitReader([0b0000_0000]).readU64(), 0, "U64 selector0 = 0")
        eq(BitReader([0b0001_0101]).readU64(), 6, "U64 selector1 = 6")

        // U32: selector 2 -> bits(4, offset:2); byte 0b0000_1110 -> 5
        let u = BitReader([0b0000_1110])
        eq(u.readU32(.value(0), .value(1), .bits(4, offset: 2), .bits(8)), 5, "U32 sel2 offset")

        // F16
        eq(Float(float16Bits: 0x3C00), 1.0, "F16 1.0")
        eq(Float(float16Bits: 0xC000), -2.0, "F16 -2.0")
        check(abs(Float(float16Bits: 0x3555) - 0.333251953125) < 1e-6, "F16 0.3333")
    }

    // MARK: - Headers (dimensions across all fixtures)

    static let sizes: [(UInt32, UInt32)] = [
        (1, 1), (3, 5), (17, 1), (64, 48), (100, 100), (640, 480), (513, 257),
    ]
    static let variants = ["lossless", "lossy", "container"]

    static func headers() {
        // Aspect-ratio math
        eq(SizeHeader.width(forRatio: 3, height: 48), 64, "ratio 4:3")
        eq(SizeHeader.width(forRatio: 1, height: 100), 100, "ratio 1:1")
        eq(SizeHeader.width(forRatio: 7, height: 50), 100, "ratio 2:1")

        let dir = fixturesDir()
        for (w, h) in sizes {
            for variant in variants {
                let name = "\(w)x\(h)_\(variant).jxl"
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else {
                    check(false, "missing fixture \(name)")
                    continue
                }
                do {
                    let info = try JXL.readInfo(from: data)
                    eq(info.width, w, "\(name) width")
                    eq(info.height, h, "\(name) height")
                } catch {
                    check(false, "\(name) decode threw \(error)")
                }
            }
        }
    }

    // MARK: - Metadata

    static func metadata() {
        // Expected values cross-checked against the libjxl C oracle
        // (white point / primaries / transfer / intent are codestream enum values).
        let cases:
            [(
                name: String, bits: UInt32, exponentBits: UInt32, colorSpace: JXLColorSpace,
                alpha: Bool, extra: Int, whitePoint: UInt32, primaries: UInt32,
                transfer: UInt32, intent: UInt32
            )] = [
                ("40x30_gray8.jxl", 8, 0, .grayscale, false, 0, 1, 0, 13, 1),
                ("40x30_rgba8.jxl", 8, 0, .rgb, true, 1, 1, 1, 13, 1),
                ("40x30_rgb16.jxl", 16, 0, .rgb, false, 0, 1, 1, 13, 1),
                ("40x30_rgbf32.jxl", 32, 8, .rgb, false, 0, 1, 1, 13, 1),
            ]

        let dir = fixturesDir()
        for c in cases {
            let url = dir.appendingPathComponent(c.name)
            guard let data = try? Data(contentsOf: url) else {
                check(false, "missing fixture \(c.name)")
                continue
            }
            do {
                let info = try JXL.readInfo(from: data)
                eq(info.width, 40, "\(c.name) width")
                eq(info.height, 30, "\(c.name) height")
                eq(info.bitDepth.bitsPerSample, c.bits, "\(c.name) bits")
                eq(info.bitDepth.exponentBitsPerSample, c.exponentBits, "\(c.name) exponent bits")
                eq(info.bitDepth.isFloatingPoint, c.exponentBits > 0, "\(c.name) float")
                eq(info.colorSpace, c.colorSpace, "\(c.name) color space")
                eq(info.hasAlpha, c.alpha, "\(c.name) alpha")
                eq(info.extraChannelCount, c.extra, "\(c.name) extra channels")
                eq(info.colorEncoding.whitePoint, c.whitePoint, "\(c.name) white point")
                eq(info.colorEncoding.primaries, c.primaries, "\(c.name) primaries")
                eq(info.colorEncoding.transferFunction, c.transfer, "\(c.name) transfer function")
                eq(info.colorEncoding.renderingIntent, c.intent, "\(c.name) rendering intent")
            } catch {
                check(false, "\(c.name) metadata threw \(error)")
            }
        }
    }

    // MARK: - Entropy coding (M3)

    /// LSB-first bit writer used to construct streams for round-trip tests.
    final class BitWriter {
        var bytes: [UInt8] = []
        var bitPos = 0
        func write(_ value: UInt64, _ count: Int) {
            for i in 0..<count {
                let bit = UInt8((value >> UInt64(i)) & 1)
                let byteIndex = bitPos >> 3
                if byteIndex >= bytes.count { bytes.append(0) }
                bytes[byteIndex] |= bit << UInt8(bitPos & 7)
                bitPos += 1
            }
        }
        var reader: BitReader { BitReader(bytes.isEmpty ? [0] : bytes) }
    }

    /// Mirror of BuildHuffmanTable's reversed-key advance (for the test encoder).
    static func nextKey(_ key: Int, _ len: Int) -> Int {
        var step = 1 << (len - 1)
        while (key & step) != 0 { step >>= 1 }
        return (key & (step - 1)) + step
    }

    /// Canonical (key, length) per symbol, matching BuildHuffmanTable's assignment.
    static func canonicalCodes(_ codeLengths: [UInt8]) -> [(key: Int, len: Int)] {
        var symbolsByLen = [[Int]](repeating: [], count: 16)
        for (sym, cl) in codeLengths.enumerated() where cl != 0 {
            symbolsByLen[Int(cl)].append(sym)
        }
        var codes = [(key: Int, len: Int)](repeating: (0, 0), count: codeLengths.count)
        var key = 0
        for len in 1...15 {
            for sym in symbolsByLen[len] {
                codes[sym] = (key, len)
                key = nextKey(key, len)
            }
        }
        return codes
    }

    static func entropy() {
        // Hybrid-uint: Encode -> bits -> Decode round-trips for several configs.
        let configs = [
            HybridUintConfig(splitExponent: 4, msbInToken: 2, lsbInToken: 0),
            HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0),
            HybridUintConfig(splitExponent: 6, msbInToken: 3, lsbInToken: 2),
            HybridUintConfig(splitExponent: 8, msbInToken: 0, lsbInToken: 0),
        ]
        let values: [UInt32] = [
            0, 1, 2, 7, 15, 16, 17, 63, 64, 100, 1000, 65535, 1 << 20, 0xFF_FFFF,
        ]
        for cfg in configs {
            for v in values {
                let (token, nbits, bits) = cfg.encode(v)
                let w = BitWriter()
                w.write(UInt64(bits), Int(nbits))
                let decoded = cfg.decode(token: token, reader: w.reader)
                eq(
                    decoded, v,
                    "hybriduint se=\(cfg.splitExponent) msb=\(cfg.msbInToken) lsb=\(cfg.lsbInToken) v=\(v)"
                )
            }
        }

        // Prefix code: BuildHuffmanTable + readSymbol round-trip, including codes
        // longer than the 8-bit root table (exercises 2nd-level sub-tables).
        let lengthSets: [[UInt8]] = [
            [2, 2, 2, 2],
            [1, 2, 3, 3],
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 9],  // Kraft sum = 1, max length 9 > 8
        ]
        for lengths in lengthSets {
            var count = [UInt16](repeating: 0, count: 16)
            for c in lengths { count[Int(c)] += 1 }
            var table = [HuffmanCode](
                repeating: HuffmanCode(bits: 0, value: 0), count: lengths.count + 376)
            let size = buildHuffmanTable(&table, rootBits: 8, codeLengths: lengths, count: &count)
            check(size > 0, "buildHuffmanTable size>0 for \(lengths)")
            table.removeLast(table.count - size)
            let pc = PrefixCode(table: table)

            let codes = canonicalCodes(lengths)
            // Encode a sequence of all symbols (twice, shuffled) and decode it back.
            let sequence = Array(0..<lengths.count) + Array((0..<lengths.count).reversed())
            let w = BitWriter()
            for sym in sequence { w.write(UInt64(codes[sym].key), codes[sym].len) }
            let reader = w.reader
            var allOK = true
            for sym in sequence where Int(pc.readSymbol(reader)) != sym { allOK = false }
            check(allOK, "prefix round-trip for lengths \(lengths)")
        }

        // Simple prefix code: 2 explicit symbols, decode a known bit pattern.
        let sw = BitWriter()
        sw.write(1, 2)  // simple code
        sw.write(1, 2)  // num_symbols - 1 = 1  -> 2 symbols
        sw.write(1, 2)  // symbol 1
        sw.write(3, 2)  // symbol 3   (alphabet size 4 -> maxBits 2)
        if let simple = PrefixCode(reader: sw.reader, alphabetSize: 4) {
            let r = BitReader([0b0000_1010])  // bits LSB-first: 0,1,0,1
            eq(simple.readSymbol(r), 1, "simple code bit0 -> sym1")
            eq(simple.readSymbol(r), 3, "simple code bit1 -> sym3")
        } else {
            check(false, "simple code failed to parse")
        }

        ans()
    }

    static func writeVarLenUint8(_ w: BitWriter, _ v: Int) {
        if v == 0 {
            w.write(0, 1)
            return
        }
        w.write(1, 1)
        if v == 1 {
            w.write(0, 3)
            return
        }
        let nbits = floorLog2Nonzero(UInt32(v))
        w.write(UInt64(nbits), 3)
        w.write(UInt64(v - (1 << nbits)), nbits)
    }

    static func ans() {
        // Flat histogram: positive, differ by <= 1, sum to total, bigger first.
        let flat = createFlatHistogram(length: 5, totalCount: 4096)
        eq(flat.reduce(0) { $0 + Int($1) }, 4096, "flat histogram sum")
        eq(flat, [820, 819, 819, 819, 819], "flat histogram shape")

        // Population-count precision against the closed-form formula.
        eq(getPopulationCountPrecision(5, shift: 12), 5, "popcount precision (5,12)")
        eq(getPopulationCountPrecision(2, shift: 2), 0, "popcount precision clamps to 0")

        // Alias table realises the distribution exactly: each symbol appears
        // `freq` times across the 4096 slots, with offsets 0..freq-1, and the
        // looked-up freq matches the distribution. (Tests InitAliasTable + Lookup,
        // the hardest part of the ANS engine.)
        let logAlpha = 8
        let tableSize = 1 << logAlpha
        let logEntry = 12 - logAlpha
        let entryM1 = (1 << logEntry) - 1
        let distributions: [[Int32]] = [
            [1000, 2000, 1096],
            [4096],
            [1, 4095],
            createFlatHistogram(length: 7, totalCount: 4096),
        ]
        for dist in distributions {
            var table = [AliasEntry](repeating: AliasEntry(), count: tableSize)
            initAliasTable(distribution: dist, logAlphaSize: logAlpha, into: &table, base: 0)
            var counts = [Int: Int]()
            var offsetSets = [Int: Set<Int>]()
            for res in 0..<4096 {
                let s = aliasLookup(
                    table, base: 0, value: res, logEntrySize: logEntry, entrySizeMinus1: entryM1)
                counts[s.value, default: 0] += 1
                offsetSets[s.value, default: []].insert(s.offset)
                eq(s.freq, Int(dist[s.value]), "alias freq for sym \(s.value)")
            }
            var ok = true
            for (sym, f) in dist.enumerated() where f > 0 {
                if counts[sym] != Int(f) { ok = false }
                if offsetSets[sym] != Set(0..<Int(f)) { ok = false }
            }
            check(ok, "alias table realises distribution \(dist)")
        }

        // Inverse move-to-front is the inverse of forward MTF.
        func forwardMTF(_ v: [UInt8]) -> [UInt8] {
            var mtf = (0..<256).map { UInt8($0) }
            var out = [UInt8]()
            for x in v {
                let idx = mtf.firstIndex(of: x)!
                out.append(UInt8(idx))
                mtf.remove(at: idx)
                mtf.insert(x, at: 0)
            }
            return out
        }
        let original: [UInt8] = [3, 3, 1, 0, 0, 2, 3, 1, 1, 4]
        var roundtrip = forwardMTF(original)
        inverseMoveToFront(&roundtrip)
        eq(roundtrip, original, "inverse MTF round-trips")

        // ReadHistogram: hand-built "simple 1-symbol" and "flat" streams.
        let hw = BitWriter()
        hw.write(1, 1)  // simple
        hw.write(0, 1)  // num_symbols - 1 = 0
        writeVarLenUint8(hw, 5)  // symbol = 5
        if let counts = readHistogram(precisionBits: 12, reader: hw.reader) {
            eq(counts.count, 6, "simple histogram size")
            eq(counts[5], 4096, "simple histogram count")
        } else {
            check(false, "simple histogram failed to parse")
        }

        let fw = BitWriter()
        fw.write(0, 1)  // not simple
        fw.write(1, 1)  // flat
        writeVarLenUint8(fw, 3)  // alphabet_size - 1 = 3 -> 4
        if let counts = readHistogram(precisionBits: 12, reader: fw.reader) {
            eq(counts, [1024, 1024, 1024, 1024], "flat histogram decode")
        } else {
            check(false, "flat histogram failed to parse")
        }
    }

    // MARK: - Frame layer (M4)

    static func frame() {
        let dir = fixturesDir()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            check(false, "list fixtures for frame test")
            return
        }
        for f in files.sorted() where f.hasSuffix(".jxl") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)) else { continue }
            do {
                let info = try JXL.readFrameInfo(from: [UInt8](data))
                // The header + TOC + all section bytes must exactly fill the codestream.
                eq(
                    info.dataStartByte + info.totalSectionBytes, info.codestreamLength,
                    "\(f) TOC sum invariant")
                check(info.frameType == .regular, "\(f) is a regular frame")
                eq(info.sectionSizes.count, info.tocEntryCount, "\(f) section count")
                eq(info.sections.count, info.tocEntryCount, "\(f) section range count")

                var totalRangeBytes = 0
                for section in info.sections {
                    eq(
                        section.size, Int(info.sectionSizes[section.index]),
                        "\(f) section \(section.index) size mirrors TOC")
                    eq(
                        section.codestreamRange.lowerBound, info.dataStartByte + section.offset,
                        "\(f) section \(section.index) range start")
                    eq(
                        section.codestreamRange.count, section.size,
                        "\(f) section \(section.index) range size")
                    eq(
                        section.role, expectedSectionRole(section.index, info),
                        "\(f) section \(section.index) role")
                    if let bytes = try? JXL.readFrameSectionData(
                        from: [UInt8](data), sectionIndex: section.index)
                    {
                        eq(
                            bytes.count, section.size,
                            "\(f) section \(section.index) byte slice size")
                    } else {
                        check(false, "\(f) section \(section.index) byte slice")
                    }
                    if let reader = try? JXL.readFrameSectionReader(
                        from: [UInt8](data), sectionIndex: section.index)
                    {
                        eq(
                            reader.bitCount, section.size * 8,
                            "\(f) section \(section.index) reader size")
                    } else {
                        check(false, "\(f) section \(section.index) reader")
                    }
                    check(
                        section.codestreamRange.lowerBound >= info.dataStartByte,
                        "\(f) section \(section.index) starts after TOC")
                    check(
                        section.codestreamRange.upperBound <= info.codestreamLength,
                        "\(f) section \(section.index) ends inside codestream")
                    totalRangeBytes += section.size
                }
                eq(totalRangeBytes, info.totalSectionBytes, "\(f) section ranges total")

                let physicalRanges = info.sections.map(\.codestreamRange).sorted {
                    $0.lowerBound < $1.lowerBound
                }
                var nextByte = info.dataStartByte
                var coversPayload = true
                for range in physicalRanges {
                    if range.lowerBound != nextByte { coversPayload = false }
                    nextByte = range.upperBound
                }
                check(
                    coversPayload && nextByte == info.codestreamLength,
                    "\(f) section ranges cover payload")
            } catch {
                check(false, "\(f) frame parse threw \(error)")
            }
        }

        // Lossless fixtures are Modular; lossy are VarDCT.
        if let m = try? JXL.readFrameInfo(
            contentsOf: dir.appendingPathComponent("64x48_lossless.jxl"))
        {
            check(m.isModular, "lossless fixture is Modular")
        } else {
            check(false, "read 64x48_lossless frame")
        }
        if let v = try? JXL.readFrameInfo(
            contentsOf: dir.appendingPathComponent("513x257_lossy.jxl"))
        {
            check(!v.isModular, "lossy fixture is VarDCT")
        } else {
            check(false, "read 513x257_lossy frame")
        }
    }

    static func expectedSectionRole(_ index: Int, _ info: JXLFrameInfo) -> JXLFrameSectionRole {
        if info.numGroups == 1 && info.numPasses == 1 { return .singleSectionCoalesced }
        if index == 0 { return .dcGlobal }
        let acGlobalIndex = info.numDCGroups + 1
        if index < acGlobalIndex { return .dcGroup(index - 1) }
        if index == acGlobalIndex { return .acGlobal }
        let acIndex = index - acGlobalIndex - 1
        return .acGroup(pass: acIndex / info.numGroups, group: acIndex % info.numGroups)
    }

    // MARK: - Container

    static func container() {
        let dir = fixturesDir()
        if let raw = try? JXL.readInfo(
            from: Data(contentsOf: dir.appendingPathComponent("64x48_lossless.jxl")))
        {
            check(!raw.isContainer, "raw not container")
            check(raw.boxTypes.isEmpty, "raw no boxes")
        } else {
            check(false, "load raw fixture")
        }

        if let c = try? JXL.readInfo(
            from: Data(contentsOf: dir.appendingPathComponent("64x48_container.jxl")))
        {
            check(c.isContainer, "container detected")
            check(c.boxTypes.contains("ftyp"), "has ftyp box")
            check(c.boxTypes.contains { $0 == "jxlc" || $0 == "jxlp" }, "has codestream box")
        } else {
            check(false, "load container fixture")
        }

        // Non-JXL rejection
        do {
            _ = try JXL.readInfo(from: [0x00, 0x01, 0x02, 0x03])
            check(false, "should reject non-JXL")
        } catch let e as JXLError {
            eq(e, .invalidSignature, "non-JXL -> invalidSignature")
        } catch {
            check(false, "wrong error type")
        }
    }
}
