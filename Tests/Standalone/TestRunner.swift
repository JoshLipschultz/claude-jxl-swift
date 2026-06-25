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
        let values: [UInt32] = [0, 1, 2, 7, 15, 16, 17, 63, 64, 100, 1000, 65535, 1 << 20, 0xFF_FFFF]
        for cfg in configs {
            for v in values {
                let (token, nbits, bits) = cfg.encode(v)
                let w = BitWriter()
                w.write(UInt64(bits), Int(nbits))
                let decoded = cfg.decode(token: token, reader: w.reader)
                eq(decoded, v, "hybriduint se=\(cfg.splitExponent) msb=\(cfg.msbInToken) lsb=\(cfg.lsbInToken) v=\(v)")
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
            var table = [HuffmanCode](repeating: HuffmanCode(bits: 0, value: 0), count: lengths.count + 376)
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
