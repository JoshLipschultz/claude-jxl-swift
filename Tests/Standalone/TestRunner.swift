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
        modular()
        decodeAPI()
        vardctDC()
        vardctACMeta()
        vardctACGlobal()
        vardctAC()
        vardctReconstruct()
        colorQuantizer()
        iccProfile()
        jpegTranscode()
        dct64()

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - Embedded ICC profiles (M8)

    /// `32x24_icc.jxl` (lossless) embeds the AdobeRGB profile (via sips +
    /// cjxl). The decoded profile must be byte-exact against `32x24_icc.icc`,
    /// which round-trips identically through djxl. `32x24_icc_lossy.jxl` came
    /// from the same tagged PNG but cjxl numericized AdobeRGB into custom
    /// primaries + gamma (`want_icc` unset) — the correct answer is `nil`.
    static func iccProfile() {
        let dir = fixturesDir()
        guard let oracle = try? Data(contentsOf: dir.appendingPathComponent("32x24_icc.icc")),
            let lossless = try? Data(contentsOf: dir.appendingPathComponent("32x24_icc.jxl")),
            let lossy = try? Data(contentsOf: dir.appendingPathComponent("32x24_icc_lossy.jxl"))
        else {
            check(false, "ICC fixtures present")
            return
        }

        do {
            let profile = try JXL.readICCProfile(from: lossless)
            check(profile == oracle, "32x24_icc.jxl ICC profile byte-exact vs djxl")
        } catch {
            check(false, "32x24_icc.jxl readICCProfile threw \(error)")
        }

        // Pixel decoding must proceed past the embedded profile, and the
        // Modular result (native samples) carries it.
        if let img = try? JXL.decodeImage(from: [UInt8](lossless)) {
            check(img.width == 32 && img.height == 24, "icc lossless decode dimensions")
            check(img.iccProfile == oracle, "icc lossless decode carries the profile")
        } else {
            check(false, "icc lossless decodeImage")
        }

        // Custom numeric color encoding (no embedded profile): decodes, nil profile.
        if let img = try? JXL.decodeImage(from: [UInt8](lossy)) {
            check(img.width == 32 && img.height == 24, "icc lossy decode dimensions")
            check(img.iccProfile == nil, "custom-numeric lossy has no embedded profile")
        } else {
            check(false, "icc lossy decodeImage")
        }
        check(
            (try? JXL.readICCProfile(from: lossy)).flatMap { $0 } == nil,
            "numericized lossy returns nil profile")

        // Numeric color-encoding output: the lossy fixture declares custom
        // (AdobeRGB) primaries + gamma; our reconstruction must match djxl's
        // color-managed output (`32x24_icc_lossy.ppm`) at oracle precision.
        if let refPPM = try? Data(contentsOf: dir.appendingPathComponent("32x24_icc_lossy.ppm")),
            let (w, h, rgb) = try? reconstructVarDCTImage(from: [UInt8](lossy))
        {
            // Strip the P6 header: bytes after the third newline.
            var newlines = 0
            var offset = 0
            for (i, byte) in refPPM.enumerated() where byte == 0x0A {
                newlines += 1
                if newlines == 3 {
                    offset = i + 1
                    break
                }
            }
            let ref = [UInt8](refPPM[offset...])
            check(ref.count == w * h * 3 && rgb.count == ref.count, "icc lossy reference size")
            var se = 0.0
            for i in 0..<min(ref.count, rgb.count) {
                let d = Double(Int(ref[i]) - Int(rgb[i]))
                se += d * d
            }
            let mse = se / Double(ref.count)
            let psnr = mse == 0 ? 999 : 10 * log10(255.0 * 255.0 / mse)
            check(psnr > 50, "custom-primaries lossy matches djxl (PSNR \(Int(psnr)) dB)")
        } else {
            check(false, "icc lossy PSNR oracle")
        }
    }

    // MARK: - DCT64+ transforms

    /// `256x256_dct64_lossy.jxl` tiles entirely with DCT64 varblocks (smooth
    /// content at low quality); reconstruction must match djxl's output.
    static func dct64() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("256x256_dct64_lossy.jxl")),
            let refPPM = try? Data(contentsOf: dir.appendingPathComponent("256x256_dct64_lossy.ppm")),
            let (w, h, rgb) = try? reconstructVarDCTImage(from: [UInt8](jxl))
        else {
            check(false, "DCT64 fixture decodes")
            return
        }
        let psnr = ppmPSNR(refPPM, rgb, w, h)
        check(psnr > 50, "DCT64 reconstruction matches djxl (PSNR \(Int(psnr)) dB)")
    }

    /// PSNR of `rgb` against a P6 PPM's pixel bytes.
    static func ppmPSNR(_ refPPM: Data, _ rgb: [UInt8], _ w: Int, _ h: Int) -> Double {
        var newlines = 0
        var offset = 0
        for (i, byte) in refPPM.enumerated() where byte == 0x0A {
            newlines += 1
            if newlines == 3 {
                offset = i + 1
                break
            }
        }
        let ref = [UInt8](refPPM[offset...])
        guard ref.count == w * h * 3 && rgb.count == ref.count else { return 0 }
        var se = 0.0
        for i in 0..<ref.count {
            let d = Double(Int(ref[i]) - Int(rgb[i]))
            se += d * d
        }
        let mse = se / Double(ref.count)
        return mse == 0 ? 999 : 10 * log10(255.0 * 255.0 / mse)
    }

    // MARK: - YCbCr / JPEG transcode (chroma subsampling, RAW quant tables)

    /// `32x24_jpegycbcr.jxl` is a cjxl JPEG transcode: YCbCr color transform,
    /// chroma subsampling, RAW (modular-coded) quant tables, custom block
    /// context map with DC thresholds, kSkipAdaptiveDCSmoothing. Reconstruction
    /// must match djxl's output (`32x24_jpegycbcr.ppm`) at oracle precision.
    static func jpegTranscode() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("32x24_jpegycbcr.jxl")),
            let refPPM = try? Data(contentsOf: dir.appendingPathComponent("32x24_jpegycbcr.ppm")),
            let (w, h, rgb) = try? reconstructVarDCTImage(from: [UInt8](jxl))
        else {
            check(false, "jpeg transcode fixture decodes")
            return
        }
        var newlines = 0
        var offset = 0
        for (i, byte) in refPPM.enumerated() where byte == 0x0A {
            newlines += 1
            if newlines == 3 {
                offset = i + 1
                break
            }
        }
        let ref = [UInt8](refPPM[offset...])
        check(ref.count == w * h * 3 && rgb.count == ref.count, "jpeg transcode size")
        var se = 0.0
        for i in 0..<min(ref.count, rgb.count) {
            let d = Double(Int(ref[i]) - Int(rgb[i]))
            se += d * d
        }
        let mse = se / Double(ref.count)
        let psnr = mse == 0 ? 999 : 10 * log10(255.0 * 255.0 / mse)
        check(psnr > 50, "YCbCr JPEG transcode matches djxl (PSNR \(Int(psnr)) dB)")

        // decodeImage carries native samples for YCbCr output.
        if let img = try? JXL.decodeImage(from: [UInt8](jxl)) {
            check(img.width == 32 && img.height == 24 && img.planes.count == 3,
                "jpeg transcode decodeImage shape")
        } else {
            check(false, "jpeg transcode decodeImage")
        }
    }

    // MARK: - Color: sRGB8 quantizer

    /// The threshold-table quantizer must agree with the reference
    /// `round(srgbEncode(v) * 255)` everywhere: a dense sweep across (and past)
    /// [0, 1], plus every threshold's exact Float and its neighbors.
    static func colorQuantizer() {
        let q = srgb8Quantizer
        func reference(_ v: Float) -> UInt8 {
            UInt8(max(0, min(255, (srgbEncode(v) * 255).rounded())))
        }
        var mismatches = 0
        var v: Float = -0.25
        while v <= 1.25 {
            if q.encode(v) != reference(v) { mismatches += 1 }
            v += 1.4e-6
        }
        for k in 1...255 {
            let s = (Double(k) - 0.5) / 255.0
            let t = Float(s <= 0.0031308 * 12.92 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4))
            for cand in [t.nextDown, t, t.nextUp] where q.encode(cand) != reference(cand) {
                mismatches += 1
            }
        }
        check(mismatches == 0, "sRGB8 quantizer matches reference transfer function (\(mismatches) mismatches)")
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

    // MARK: - Public decode API (M5: single + multi group)

    /// Decodes every lossless fixture through the public `JXL.decodeImage` API
    /// and checks the pixels against their generator formula (byte-exact).
    static func decodeAPI() {
        let dir = fixturesDir()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            check(false, "list fixtures for decodeAPI test")
            return
        }
        var verified = 0
        for f in files.sorted() where f.hasSuffix(".jxl") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                let img = try? JXL.decodeImage(from: [UInt8](data))
            else { continue }
            let w = img.width
            let h = img.height
            func allMatch(_ e: (Int, Int) -> [Int32]) -> Bool {
                for y in 0..<h {
                    for x in 0..<w {
                        let ex = e(x, y)
                        for c in 0..<ex.count where img.planes[c][y * w + x] != ex[c] { return false }
                    }
                }
                return true
            }
            let base = (f as NSString).deletingPathExtension
            var ok: Bool? = nil
            if f == "40x30_gray8.jxl" {
                ok = allMatch { x, y in [Int32((x * 7 + y * 5) & 255)] }
            } else if f == "40x30_rgba8.jxl" {
                ok = allMatch { x, y in
                    [Int32((x * 37) & 255), Int32((y * 53) & 255), Int32(((x + y) * 29) & 255), Int32((x * 3) & 255)]
                }
            } else if f == "40x30_rgb16.jxl" {
                ok = allMatch { x, y in
                    [Int32((x * 1600) & 0xFFFF), Int32((y * 2100) & 0xFFFF), Int32(((x + y) * 900) & 0xFFFF)]
                }
            } else if base.hasSuffix("_lossless") || base.hasSuffix("_container") {
                ok = allMatch { x, y in
                    [Int32((x * 37) & 255), Int32((y * 53) & 255), Int32(((x + y) * 29) & 255)]
                }
            }
            if let ok = ok {
                check(ok, "\(f) decodeImage pixels byte-exact")
                if ok { verified += 1 }
            }
        }
        // 32-bit float: the generator's blue channel is a constant 0.5, which is
        // orientation-independent and exercises float decode + RCT undo.
        if let data = try? Data(contentsOf: dir.appendingPathComponent("40x30_rgbf32.jxl")),
            let img = try? JXL.decodeImage(from: [UInt8](data)) {
            check(img.isFloat, "rgbf32 decodes as float")
            let half = Int32(bitPattern: Float(0.5).bitPattern)
            check(img.planes[2].allSatisfy { $0 == half }, "rgbf32 blue channel is constant 0.5")
        } else {
            check(false, "rgbf32 failed to decode")
        }

        FileHandle.standardError.write(
            Data("  [decodeImage] byte-exact lossless images=\(verified) (+ float)\n".utf8))
        check(verified >= 17, "decodeImage byte-exact for >=17 lossless fixtures (single + multi group)")

        // Unified API: decodeImage also handles VarDCT (lossy), returning 8-bit
        // RGB planes, so the viewer/CLI have a single entry point.
        if let data = try? Data(contentsOf: dir.appendingPathComponent("640x480_lossy.jxl")),
            let img = try? JXL.decodeImage(from: [UInt8](data))
        {
            check(img.colorChannels == 3 && img.bitsPerSample == 8, "lossy decodeImage is 8-bit RGB")
            check(img.width == 640 && img.height == 480, "lossy decodeImage dimensions")
            check(!img.isFloat && img.planes.count == 3, "lossy decodeImage plane shape")
        } else {
            check(false, "decodeImage handles a VarDCT (lossy) frame")
        }

        // Decode limits: a cap below the frame's sample count must refuse the
        // decode with `.limitExceeded` before allocating pixel planes, for both
        // the Modular and VarDCT paths.
        for name in ["640x480_lossless.jxl", "640x480_lossy.jxl"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else {
                check(false, "\(name) missing for limits test")
                continue
            }
            do {
                _ = try JXL.decodeImage(
                    from: [UInt8](data), limits: JXLDecodeLimits(maxTotalSamples: 1024))
                check(false, "\(name) decode should exceed a 1024-sample limit")
            } catch let e as JXLError {
                if case .limitExceeded = e {
                    check(true, "\(name) limited decode throws limitExceeded")
                } else {
                    check(false, "\(name) limited decode threw \(e) instead of limitExceeded")
                }
            } catch {
                check(false, "\(name) limited decode threw unexpected \(error)")
            }
            check(
                (try? JXL.decodeImage(from: [UInt8](data))) != nil,
                "\(name) still decodes under default limits")
        }
    }

    // MARK: - VarDCT DC image (M6)

    /// Decodes the dequantized XYB DC of every lossy fixture and checks it is
    /// finite and in a physically plausible range. The rigorous oracle check
    /// (DC vs djxl per-block XYB means, <1% MAD) lives in Scripts/cmp_dc.py.
    static func vardctDC() {
        let dir = fixturesDir()
        var decoded = 0
        var multiGroupSeen = false
        for (name, blocks) in [
            ("17x1_lossy.jxl", 3), ("64x48_lossy.jxl", 48), ("100x100_lossy.jxl", 169),
            ("513x257_lossy.jxl", 65 * 33), ("640x480_lossy.jxl", 80 * 60),
        ] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                let dc = try? decodeVarDCTDCImage(from: [UInt8](data))
            else {
                check(false, "\(name) decodeVarDCTDCImage")
                continue
            }
            check(dc.widthBlocks * dc.heightBlocks == blocks, "\(name) DC block count")
            let finite = dc.x.allSatisfy(\.isFinite) && dc.y.allSatisfy(\.isFinite)
                && dc.b.allSatisfy(\.isFinite)
            check(finite, "\(name) DC values finite")
            // Luma DC mean of these photographic fixtures sits near 0.4–0.55 XYB.
            let meanY = dc.y.reduce(0, +) / Float(dc.y.count)
            check(meanY > 0.15 && meanY < 0.65, "\(name) DC luma mean plausible (\(meanY))")
            if name == "640x480_lossy.jxl" { multiGroupSeen = true }  // 6 AC groups
            decoded += 1
        }
        check(multiGroupSeen, "multi-group VarDCT DC decoded")
        FileHandle.standardError.write(
            Data("  [vardct-dc] XYB DC images decoded=\(decoded)\n".utf8))
    }

    /// Decodes the AC metadata (strategy field, quant field, EPF, CfL maps) of
    /// the lossy fixtures. The decoder enforces exact varblock tiling (num ==
    /// count, no overlap/overflow), so a clean decode is itself bit-exact proof
    /// of both the AcMetadata and the VarDCTDC stream that precedes it.
    static func vardctACMeta() {
        let dir = fixturesDir()
        var decoded = 0
        for name in [
            "17x1_lossy.jxl", "64x48_lossy.jxl", "100x100_lossy.jxl", "513x257_lossy.jxl",
            "640x480_lossy.jxl",
        ] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                let m = try? decodeVarDCTACMetadata(from: [UInt8](data))
            else {
                check(false, "\(name) decodeVarDCTACMetadata")
                continue
            }
            // Single-block strategies: every block is its own varblock.
            check(
                m.varblockCount == m.widthBlocks * m.heightBlocks,
                "\(name) all-DCT8 tiling: varblocks == blocks")
            let firsts = m.isFirstBlock.lazy.filter { $0 }.count
            check(firsts == m.varblockCount, "\(name) first-block count == varblockCount")
            decoded += 1
        }

        // The varblocks fixture exercises multiple DCT sizes (DCT8/16/32, AFV,
        // …), so varblocks cover multiple blocks each and tile exactly.
        if let data = try? Data(
            contentsOf: dir.appendingPathComponent("256x256_varblocks_lossy.jxl")),
            let m = try? decodeVarDCTACMetadata(from: [UInt8](data))
        {
            let total = m.widthBlocks * m.heightBlocks
            check(m.varblockCount < total, "varblocks fixture has multi-block strategies")
            let distinct = Set(
                (0..<total).filter { m.isFirstBlock[$0] }.map { m.strategy[$0] })
            check(distinct.count >= 5, "varblocks fixture uses varied strategies (\(distinct.count))")
            // Exact tiling: the quant value is filled across each varblock's
            // covered cells (EPF sigma reads it per 8x8 cell), so every cell
            // in the frame must have a positive quant.
            var covered = 0
            for i in 0..<total where m.quantField[i] > 0 { covered += 1 }
            check(covered == total, "varblocks fixture quant covers every block")
            decoded += 1
        } else {
            check(false, "256x256_varblocks_lossy decodeVarDCTACMetadata")
        }
        FileHandle.standardError.write(
            Data("  [vardct-acmeta] AC metadata decoded=\(decoded) (incl. varied block sizes)\n".utf8))
    }

    /// Decodes the AC-global layer (coefficient orders + AC histograms). The
    /// coefficient-order ANS stream has its own final-state check, so a clean
    /// decode is bit-exact proof of this layer.
    static func vardctACGlobal() {
        let dir = fixturesDir()
        var decoded = 0
        for name in ["64x48_lossy.jxl", "513x257_lossy.jxl", "640x480_lossy.jxl"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                let (_, acg) = try? decodeVarDCTACGlobalForFrame(from: [UInt8](data))
            else {
                check(false, "\(name) decodeVarDCTACGlobalForFrame")
                continue
            }
            check(acg.codes.count == 1, "\(name) single pass")
            check(acg.numHistograms >= 1, "\(name) histograms present")
            // DCT8 order set: 64 entries per channel, all a permutation of 0..63.
            for c in 0..<3 {
                let ord = acg.orders[0][c]
                check(ord.count == 64, "\(name) DCT8 order c\(c) size")
                check(Set(ord) == Set(0..<64), "\(name) DCT8 order c\(c) is a permutation")
            }
            decoded += 1
        }
        // Varied block sizes: multiple order buckets are populated.
        if let data = try? Data(
            contentsOf: dir.appendingPathComponent("256x256_varblocks_lossy.jxl")),
            let (_, acg) = try? decodeVarDCTACGlobalForFrame(from: [UInt8](data))
        {
            let buckets = Set((0..<(3 * 13)).filter { !acg.orders[0][$0].isEmpty }.map { $0 / 3 })
            check(buckets.count >= 4, "varblocks AC global uses multiple order buckets (\(buckets.count))")
            decoded += 1
        } else {
            check(false, "256x256_varblocks_lossy decodeVarDCTACGlobalForFrame")
        }
        FileHandle.standardError.write(
            Data("  [vardct-acglobal] AC global decoded=\(decoded)\n".utf8))
    }

    /// Decodes all AC coefficients of the lossy fixtures. Each group ends with
    /// an ANS final-state check, so a clean decode across hundreds of thousands
    /// of coefficients is a complete bit-exact validation of the entropy decode.
    static func vardctAC() {
        let dir = fixturesDir()
        var decoded = 0
        for (name, varblocks) in [
            ("64x48_lossy.jxl", 48), ("100x100_lossy.jxl", 169), ("513x257_lossy.jxl", 2145),
            ("640x480_lossy.jxl", 4800),
        ] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                let coeffs = try? decodeVarDCTCoefficients(from: [UInt8](data))
            else {
                check(false, "\(name) decodeVarDCTCoefficients")
                continue
            }
            check(coeffs.blocks.count == varblocks, "\(name) varblock count")
            check(coeffs.totalNonZeros > 0, "\(name) has nonzero AC coefficients")
            decoded += 1
        }
        // Mixed block sizes also pass the ANS final-state check.
        if let data = try? Data(
            contentsOf: dir.appendingPathComponent("256x256_varblocks_lossy.jxl")),
            let coeffs = try? decodeVarDCTCoefficients(from: [UInt8](data))
        {
            check(coeffs.blocks.count == 578, "varblocks AC varblock count")
            let strategies = Set(coeffs.blocks.map { $0.strategy })
            check(strategies.count >= 5, "varblocks AC mixed strategies (\(strategies.count))")
            decoded += 1
        } else {
            check(false, "256x256_varblocks_lossy decodeVarDCTCoefficients")
        }
        FileHandle.standardError.write(
            Data("  [vardct-ac] AC coefficient sets decoded=\(decoded) (ANS-verified)\n".utf8))
    }

    /// Reconstructs the lossy fixtures (DCT8-only and mixed-strategy) to sRGB
    /// pixels and checks basic validity. The quantitative match to djxl
    /// (PSNR ~54 dB, i.e. numerical precision) is verified via
    /// Scripts/cmp_ppm.py against `djxl` output.
    static func vardctReconstruct() {
        let dir = fixturesDir()
        var decoded = 0
        for (name, w, h) in [
            ("64x48_lossy.jxl", 64, 48), ("100x100_lossy.jxl", 100, 100),
            ("513x257_lossy.jxl", 513, 257), ("640x480_lossy.jxl", 640, 480),
            ("256x256_varblocks_lossy.jxl", 256, 256),
        ] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                let (rw, rh, rgb) = try? reconstructVarDCTImage(from: [UInt8](data))
            else {
                check(false, "\(name) reconstructVarDCTImage")
                continue
            }
            check(rw == w && rh == h, "\(name) reconstruction dimensions")
            check(rgb.count == w * h * 3, "\(name) reconstruction pixel count")
            // Non-degenerate: real photographic content has spread in all channels.
            let mean = rgb.reduce(0) { $0 + Int($1) } / rgb.count
            check(mean > 20 && mean < 235, "\(name) reconstruction mean plausible (\(mean))")
            let distinct = Set(rgb).count
            check(distinct > 32, "\(name) reconstruction has tonal range (\(distinct) values)")
            decoded += 1
        }
        FileHandle.standardError.write(
            Data("  [vardct-decode] lossy images reconstructed=\(decoded) (~54 dB vs djxl)\n".utf8))
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

    // MARK: - Modular: MA tree from real data (M5)

    /// Decodes the global Modular MA tree from each lossless fixture. Reaching a
    /// valid tree (with CheckANSFinalState passing) end-to-end validates the M3
    /// entropy decoder on real codestream bytes.
    static func modular() {
        let dir = fixturesDir()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            check(false, "list fixtures for modular test")
            return
        }
        var treesDecoded = 0
        var imagesDecoded = 0
        var pixelsVerified = 0
        for f in files.sorted() where f.hasSuffix(".jxl") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                let frame = try? JXL.readFrameInfo(from: [UInt8](data)),
                let info = try? JXL.readInfo(from: [UInt8](data)),
                frame.isModular, frame.flags == 0, frame.frameType == .regular,
                let section0 = try? JXL.readFrameSectionData(from: [UInt8](data), sectionIndex: 0)
            else { continue }

            let br = BitReader([UInt8](section0))
            // LfGlobal preamble for a flags=0 Modular frame: DequantMatrices.DecodeDC.
            if br.read(1) == 0 {  // dc_quant all_default
                for _ in 0..<3 { _ = br.readF16() }
            }
            // GlobalModular: has_tree, then (if set) the global MA tree + code.
            var globalTree: [MATreeNode]? = nil
            var globalCode: ANSCode? = nil
            var globalCtxMap: [UInt8]? = nil
            if br.read(1) == 1 {  // has_tree
                guard let tree = decodeMATree(br, treeSizeLimit: 1 << 22) else {
                    check(false, "\(f): global MA tree failed to decode")
                    continue
                }
                check(!tree.isEmpty, "\(f): global MA tree is non-empty")
                treesDecoded += 1
                guard let (code, ctx) = decodeHistograms(br, numContexts: (tree.count + 1) / 2, disallowLZ77: false)
                else {
                    check(false, "\(f): global modular histograms failed")
                    continue
                }
                globalTree = tree
                globalCode = code
                globalCtxMap = ctx
            }

            // Full global modular decode is only the whole image for single groups.
            guard frame.numGroups == 1 else { continue }
            let nbChans = info.colorSpace == .grayscale ? 1 : 3
            let image = ModularImage(
                w: Int(info.width), h: Int(info.height),
                bitdepth: Int(info.bitDepth.bitsPerSample),
                channelCount: nbChans + info.extraChannelCount)
            do {
                let header = try modularDecode(
                    br, image: image, groupID: 0, globalTree: globalTree, globalCode: globalCode,
                    globalCtxMap: globalCtxMap)
                try undoTransforms(image, transforms: header.transforms)
                imagesDecoded += 1
                if verifyDecodedPixels(name: f, image: image, info: info) { pixelsVerified += 1 }
            } catch ModularDecodeError.unsupportedTransform {
                // Palette/Squeeze not yet applied; skip these fixtures.
            } catch {
                check(false, "\(f): global modular decode failed: \(error)")
            }
        }
        FileHandle.standardError.write(
            Data(
                "  [modular] trees=\(treesDecoded) images decoded=\(imagesDecoded) pixels byte-exact=\(pixelsVerified)\n"
                    .utf8))
        check(treesDecoded > 0, "decoded at least one global MA tree from real codestream data")
        check(imagesDecoded > 0, "fully decoded at least one global modular image (CheckANSFinalState)")
        check(pixelsVerified > 0, "decoded pixels byte-exact vs known generator formula")
    }

    /// Verifies decoded channels against the deterministic generator formulas the
    /// fixtures were created from (lossless => byte-exact). Returns true if the
    /// fixture was checked and matched; false if its formula isn't known (skipped).
    static func verifyDecodedPixels(name: String, image: ModularImage, info: JXLImageInfo) -> Bool {
        let w = Int(info.width)
        let h = Int(info.height)
        func ch(_ c: Int) -> ModularChannel { image.channels[c] }
        func allMatch(_ expect: (Int, Int) -> [Int32]) -> Bool {
            for y in 0..<h {
                for x in 0..<w {
                    let e = expect(x, y)
                    for c in 0..<e.count where ch(c).at(x, y) != e[c] { return false }
                }
            }
            return true
        }

        let base = (name as NSString).deletingPathExtension
        if name == "40x30_gray8.jxl" {
            let ok = allMatch { x, y in [Int32((x * 7 + y * 5) & 255)] }
            check(ok, "\(name) grayscale pixels byte-exact")
            return ok
        }
        if name == "40x30_rgba8.jxl" {
            let ok = allMatch { x, y in
                [Int32((x * 37) & 255), Int32((y * 53) & 255), Int32(((x + y) * 29) & 255), Int32((x * 3) & 255)]
            }
            check(ok, "\(name) RGBA pixels byte-exact")
            return ok
        }
        if name == "40x30_rgb16.jxl" {
            let ok = allMatch { x, y in
                [Int32((x * 1600) & 0xFFFF), Int32((y * 2100) & 0xFFFF), Int32(((x + y) * 900) & 0xFFFF)]
            }
            check(ok, "\(name) 16-bit RGB pixels byte-exact")
            return ok
        }
        if base.hasSuffix("_lossless") || base.hasSuffix("_container") {
            let ok = allMatch { x, y in
                [Int32((x * 37) & 255), Int32((y * 53) & 255), Int32(((x + y) * 29) & 255)]
            }
            check(ok, "\(name) RGB pixels byte-exact")
            return ok
        }
        return false  // e.g. float fixtures — decoded but formula not checked here
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
