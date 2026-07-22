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
        patches()
        vardctAlpha()
        epfIters()
        upsampling()
        splinesAndNoise()
        squeeze()
        animation()
        brotli()
        jbrdParse()
        hdrOutput()
        frameBlending()
        float32Modular()
        integerModularFloat()
        jpegTranscodeWide()
        spotColorRendering()
        jxlpOutOfOrder()
        modularPatches()
        nestedDCFrames()
        bitWriterRoundTrip()
        headerWriterRoundTrip()
        encoderRoundTrip()
        encoderSizeGate()
        squeezeEncoder()
        paletteGroupChannelIndex()
        orientationBaking()
        deltaPalette()
        iccOutput()
        progressiveAC()
        progressiveDC()
        wideExtraChannels()
        ditherOutput()

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - Blue-noise dithered 8-bit output (djxl 0.12 default)

    /// `96x64_dither.jxl` is an 8-bit gradient encoded with cjxl -d 1.0
    /// (VarDCT); `96x64_dither.ppm` is djxl v0.12's 8-bit PPM output, which
    /// applies channel-offset blue-noise dithering by default. Decoding with
    /// `dither: true` must match the oracle within ±1 on a tiny fraction of
    /// samples (the residue of ~1-ulp float-pipeline differences landing on
    /// opposite sides of a dithered rounding threshold). The flag defaults to
    /// off, and dithering is a no-op on lossless (exact-integer) content.
    static func ditherOutput() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("96x64_dither.jxl")),
            let ppm = try? Data(contentsOf: dir.appendingPathComponent("96x64_dither.ppm")),
            let dithered = try? JXL.decodeImage(from: [UInt8](jxl), dither: true),
            let plain = try? JXL.decodeImage(from: [UInt8](jxl)),
            let defaulted = try? JXL.decodeImage(from: [UInt8](jxl), dither: false)
        else {
            check(false, "dither fixtures decode")
            return
        }
        // Oracle: raw samples start after the 3rd newline (P6\n96 64\n255\n).
        var newlines = 0
        var offset = 0
        for (i, byte) in ppm.enumerated() where byte == 0x0A {
            newlines += 1
            if newlines == 3 {
                offset = i + 1
                break
            }
        }
        let oracle = [UInt8](ppm[offset...])
        let n = dithered.width * dithered.height
        check(oracle.count == n * 3, "dither oracle size")
        var maxDiff = 0
        var mismatches = 0
        for c in 0..<3 {
            for i in 0..<n {
                let d = abs(Int(oracle[i * 3 + c]) - Int(dithered.planes[c][i]))
                if d != 0 { mismatches += 1 }
                maxDiff = max(maxDiff, d)
            }
        }
        check(maxDiff <= 1, "dithered output within ±1 of djxl 0.12 (max \(maxDiff))")
        check(
            mismatches * 100 < n * 3,
            "dithered output mismatches <1% of samples (\(mismatches)/\(n * 3))")
        // Dither actually does something on lossy content...
        check(dithered.planes != plain.planes, "dither changes lossy 8-bit output")
        // ...and the flag defaults to off (non-dithered path unchanged).
        check(defaulted.planes == plain.planes, "dither defaults to off")
        // Lossless (native integer modular) output is exact: dithering is a
        // byte-identical no-op there.
        if let ll = try? Data(contentsOf: dir.appendingPathComponent("64x48_lossless.jxl")),
            let llPlain = try? JXL.decodeImage(from: [UInt8](ll)),
            let llDither = try? JXL.decodeImage(from: [UInt8](ll), dither: true)
        {
            check(llPlain.planes == llDither.planes, "dither is a no-op on lossless")
        } else {
            check(false, "lossless dither no-op fixtures decode")
        }
        FileHandle.standardError.write(
            Data("  [dither] blue-noise 8-bit vs djxl 0.12 (max ±1), default off, lossless no-op\n".utf8))
    }

    // MARK: - Lossless float32 modular (conformance: lossless_pfm)

    /// `64x64_f32e{1,3,7}.jxl` are the same random float image (values in
    /// [-0.5, 1.5), so bit patterns span nearly the full int32 range) encoded
    /// losslessly at cjxl efforts 1, 3, and 7. They pin down the arithmetic
    /// edge cases that only 32-bit samples reach: the uint32 wrap in the WP
    /// error-weight sum, and libjxl's gradient/WP "fast track" kernels whose
    /// property clamping differs from the generic path (e1 hits the gradient
    /// track, e3 the WP track, e7 the generic WP path). Oracles are djxl PFM
    /// output; every sample must match bit-for-bit.
    static func float32Modular() {
        let dir = fixturesDir()
        for effort in [1, 3, 7] {
            let base = "64x64_f32e\(effort)"
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent(base + ".jxl")),
                let pfm = try? Data(contentsOf: dir.appendingPathComponent(base + ".pfm")),
                let oracle = parsePFM(pfm)
            else {
                check(false, "\(base) fixtures present")
                continue
            }
            guard let img = try? JXL.decodeImage(from: [UInt8](jxl)) else {
                check(false, "\(base) decodes")
                continue
            }
            check(img.isFloat && img.bitsPerSample == 32, "\(base) is float32")
            eq(img.width, oracle.width, "\(base) width")
            eq(img.height, oracle.height, "\(base) height")
            var mismatches = 0
            for c in 0..<3 {
                for i in 0..<(img.width * img.height)
                where img.planes[c][i] != oracle.planes[c][i] {
                    mismatches += 1
                }
            }
            eq(mismatches, 0, "\(base) bit-exact vs djxl PFM")
        }
        FileHandle.standardError.write(
            Data("  [float32-modular] lossless float images bit-exact=3\n".utf8))
    }

    /// Integer-modular images decoded at `.float32` scale by 1/(2^bits − 1)
    /// without clamping (djxl PFM / conformance-reference convention; lossy
    /// modular legitimately produces out-of-range samples). Oracle is djxl's
    /// PFM output for the delta-palette fixture; must match bit-for-bit.
    static func integerModularFloat() {
        let dir = fixturesDir()
        let base = "96x64_deltapal"
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent(base + ".jxl")),
            let pfm = try? Data(contentsOf: dir.appendingPathComponent(base + ".pfm")),
            let oracle = parsePFM(pfm),
            let img = try? JXL.decodeImage(from: [UInt8](jxl), format: .float32)
        else {
            check(false, "\(base) float fixtures decode")
            return
        }
        check(img.isFloat && img.bitsPerSample == 32, "\(base) float output is float32")
        eq(img.width, oracle.width, "\(base) float width")
        eq(img.height, oracle.height, "\(base) float height")
        var mismatches = 0
        for c in 0..<3 {
            for i in 0..<(img.width * img.height)
            where img.planes[c][i] != oracle.planes[c][i] {
                mismatches += 1
            }
        }
        eq(mismatches, 0, "\(base) float bit-exact vs djxl PFM")
        FileHandle.standardError.write(
            Data("  [int-modular-float] unclamped float output bit-exact vs djxl\n".utf8))
    }

    // MARK: - Encoder E0: BitWriter + header writers

    /// Randomized write→read identity across every field primitive: 10k mixed
    /// operations (raw bits, bool, U32 with random alternatives, U64, Enum,
    /// F16) written with `BitWriter` must read back identically through
    /// `BitReader` — the writer is the reader's exact dual by construction.
    static func bitWriterRoundTrip() {
        // Deterministic LCG so failures reproduce.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }
        enum Op {
            case bits(UInt64, Int)
            case bool(Bool)
            case u32(UInt32, U32Choice, U32Choice, U32Choice, U32Choice)
            case u64(UInt64)
            case enumV(UInt32)
            case f16(Float)
        }
        var ops: [Op] = []
        let w = BitWriter()
        for _ in 0..<10_000 {
            switch rnd() % 6 {
            case 0:
                let n = Int(rnd() % 57)  // 0...56 (reader fast path + 0)
                let v = rnd() & ((n == 0) ? 0 : (UInt64.max >> (64 - UInt64(n))))
                ops.append(.bits(v, n))
                w.write(v, n)
            case 1:
                let b = rnd() & 1 == 1
                ops.append(.bool(b))
                w.writeBool(b)
            case 2:
                // Random alternatives; pick a value one of them can encode.
                func choice() -> U32Choice {
                    rnd() & 1 == 0
                        ? .value(UInt32(rnd() % 1000))
                        : .bits(Int(rnd() % 20) + 1, offset: UInt32(rnd() % 1000))
                }
                let cs = (choice(), choice(), choice(), choice())
                let pickList = [cs.0, cs.1, cs.2, cs.3]
                let pick = pickList[Int(rnd() % 4)]
                let maxExtra: UInt32 =
                    pick.bitCount == 0 ? 0 : (1 << UInt32(pick.bitCount)) - 1
                let v = pick.offset &+ UInt32(truncatingIfNeeded: rnd()) % (maxExtra &+ 1)
                ops.append(.u32(v, cs.0, cs.1, cs.2, cs.3))
                w.writeU32(v, cs.0, cs.1, cs.2, cs.3)
            case 3:
                // Exercise every U64 branch incl. the 60-bit continuation tail.
                let shift = rnd() % 64
                let v = rnd() >> shift
                ops.append(.u64(v))
                w.writeU64(v)
            case 4:
                let v = UInt32(rnd() % 82)  // Enum range 0...81
                ops.append(.enumV(v))
                w.writeEnum(v)
            default:
                let v = Float(Float16(bitPattern: UInt16(truncatingIfNeeded: rnd())))
                let safe = v.isNaN ? Float(0.5) : v
                ops.append(.f16(safe))
                w.writeF16(safe)
            }
        }
        let r = BitReader(w.finalize())
        var mismatches = 0
        for op in ops {
            switch op {
            case .bits(let v, let n): if r.read(n) != v { mismatches += 1 }
            case .bool(let b): if r.readBool() != b { mismatches += 1 }
            case .u32(let v, let a, let b, let c, let d):
                if r.readU32(a, b, c, d) != v { mismatches += 1 }
            case .u64(let v): if r.readU64() != v { mismatches += 1 }
            case .enumV(let v): if r.readEnum() != v { mismatches += 1 }
            case .f16(let v): if r.readF16() != v { mismatches += 1 }
            }
        }
        eq(mismatches, 0, "BitWriter/BitReader field identity (10k ops)")
        check(r.allReadsWithinBounds, "round-trip stayed in bounds")
        FileHandle.standardError.write(
            Data("  [bitwriter] 10k-op write->read identity\n".utf8))
    }

    /// E1: encode → decode must reproduce the input planes byte-exactly, for
    /// a spread of shapes and contents (gradients, LCG noise, constants,
    /// extremes; gray and RGB; 8- and 16-bit; 1×1 up to the full 256×256
    /// single-group limit). djxl round-trips of the same files are validated
    /// separately (`Scripts/` + fixtures); this test needs no oracle binary.
    static func encoderRoundTrip() {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func rnd() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }
        func makeImage(w: Int, h: Int, channels: Int, bits: Int, mode: Int) -> JXLDecodedImage {
            let maxV = Int32((1 << bits) - 1)
            var planes: [[Int32]] = []
            for c in 0..<channels {
                var p = [Int32](repeating: 0, count: w * h)
                for i in 0..<(w * h) {
                    switch mode {
                    case 0: p[i] = Int32((i + c * 37) % (Int(maxV) + 1))  // gradient-ish
                    case 1: p[i] = Int32(truncatingIfNeeded: Int64(rnd())) & maxV  // noise
                    case 2: p[i] = maxV / 2  // constant
                    default: p[i] = (i % 2 == 0) ? 0 : maxV  // alternating extremes
                    }
                }
                planes.append(p)
            }
            return JXLDecodedImage(
                width: w, height: h, colorChannels: channels, extraChannels: 0,
                bitsPerSample: bits, isFloat: false, planes: planes)
        }
        let shapes: [(Int, Int, Int, Int, Int)] = [
            (1, 1, 3, 8, 0), (8, 8, 3, 8, 1), (96, 64, 3, 8, 0), (96, 64, 3, 8, 1),
            (256, 256, 3, 8, 1), (65, 33, 1, 8, 0), (40, 30, 3, 16, 1),
            (17, 90, 1, 16, 3), (128, 5, 3, 8, 2),
            // Multi-group shapes: group-boundary crossings in each dimension,
            // both channel counts, both depths, ragged edges.
            (257, 256, 3, 8, 0), (300, 200, 3, 8, 1), (100, 600, 1, 8, 0),
            (513, 300, 3, 8, 0), (260, 259, 3, 16, 1), (1, 1000, 1, 8, 3),
            (777, 3, 3, 8, 1), (512, 512, 1, 16, 2),
        ]
        var failures = 0
        for (w, h, ch, bits, mode) in shapes {
            let img = makeImage(w: w, h: h, channels: ch, bits: bits, mode: mode)
            // Both entropy back-ends (ANS default + prefix) at effort 2, plus
            // the effort-1 fast path (fixed tree, no palette/WP/multipliers).
            for (backend, effort) in [
                (ModularEncoder.EntropyBackend.ans, 2), (.prefix, 2), (.ans, 1),
            ] {
                do {
                    let jxl = try ModularEncoder.encodeLossless(
                        img, backend: backend, effort: effort)
                    let dec = try JXL.decodeImage(from: jxl)
                    guard dec.width == w, dec.height == h, dec.colorChannels == ch,
                        dec.bitsPerSample == bits
                    else {
                        failures += 1
                        continue
                    }
                    for c in 0..<ch where dec.planes[c] != img.planes[c] {
                        failures += 1
                        break
                    }
                } catch {
                    check(
                        false,
                        "encode \(w)x\(h)/\(ch)ch/\(bits)bit mode \(mode) \(backend) e\(effort): \(error)")
                    failures += 1
                }
            }
        }
        eq(failures, 0, "encoder round-trip byte-exact (\(shapes.count) shapes x 3 configs)")

        // E3 shapes: alpha extra channels and binary32 floats. Float planes
        // carry IEEE-754 bit patterns as Int32 (identity through the modular
        // stream); contents cover negatives, ±0.0, subnormals, and extremes —
        // NaN/Inf excluded to mirror the committed float fixtures.
        func makeFloatPlane(_ n: Int, seed: Int) -> [Int32] {
            var p = [Int32](repeating: 0, count: n)
            let specials: [Float] = [
                0.0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
                .leastNormalMagnitude, -.leastNormalMagnitude,
                .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1.0, -1.0,
            ]
            for i in 0..<n {
                if (i + seed) % 17 == 0 {
                    p[i] = Int32(bitPattern: specials[(i + seed) % specials.count].bitPattern)
                } else {
                    // Random bit pattern with exponent LSB cleared: exponent
                    // is never 0xFF, so no NaN/Inf; sign, subnormals, and
                    // full-range magnitudes all occur.
                    p[i] = Int32(bitPattern: UInt32(truncatingIfNeeded: rnd()) & 0xFF7F_FFFF)
                }
            }
            return p
        }
        // (w, h, colorCh, alphaCh, bits, isFloat, mode)
        let e3Shapes: [(Int, Int, Int, Int, Int, Bool, Int)] = [
            (64, 48, 3, 1, 8, false, 0),  // RGB+alpha 8-bit
            (33, 70, 1, 1, 8, false, 1),  // gray+alpha 8-bit noise
            (40, 30, 3, 1, 16, false, 1),  // 16-bit RGB+alpha
            (25, 25, 3, 2, 8, false, 0),  // two alpha channels
            (64, 64, 3, 0, 32, true, 0),  // float32 RGB
            (48, 32, 1, 0, 32, true, 0),  // float32 gray
            (32, 32, 3, 1, 32, true, 0),  // float32 RGB+alpha
            (300, 130, 3, 1, 8, false, 1),  // multi-group alpha
            (270, 258, 1, 0, 32, true, 0),  // multi-group float
        ]
        var e3Failures = 0
        for (w, h, ch, extra, bits, isFloat, mode) in e3Shapes {
            var planes: [[Int32]] = []
            for c in 0..<(ch + extra) {
                if isFloat {
                    planes.append(makeFloatPlane(w * h, seed: c * 31))
                } else {
                    planes.append(makeImage(w: w, h: h, channels: 1, bits: bits, mode: mode)
                        .planes[0])
                }
            }
            let img = JXLDecodedImage(
                width: w, height: h, colorChannels: ch, extraChannels: extra,
                bitsPerSample: bits, isFloat: isFloat, planes: planes)
            for backend in [ModularEncoder.EntropyBackend.ans, .prefix] {
                do {
                    let jxl = try ModularEncoder.encodeLossless(img, backend: backend)
                    let dec = try JXL.decodeImage(from: jxl)
                    guard dec.width == w, dec.height == h, dec.colorChannels == ch,
                        dec.extraChannels == extra, dec.isFloat == isFloat,
                        dec.bitsPerSample == bits
                    else {
                        check(false, "e3 shape \(w)x\(h)/\(ch)+\(extra)/\(bits) \(backend) header")
                        e3Failures += 1
                        continue
                    }
                    for c in 0..<(ch + extra) where dec.planes[c] != img.planes[c] {
                        check(false, "e3 shape \(w)x\(h)/\(ch)+\(extra)/\(bits) \(backend) plane \(c)")
                        e3Failures += 1
                        break
                    }
                } catch {
                    check(false, "e3 encode \(w)x\(h)/\(ch)+\(extra)/\(bits) \(backend): \(error)")
                    e3Failures += 1
                }
            }
        }
        eq(e3Failures, 0, "E3 round-trip byte-exact (\(e3Shapes.count) shapes x 2 backends)")
        FileHandle.standardError.write(
            Data("  [encoder-e2] encode->decode byte-exact round-trips (ANS + prefix)\n".utf8))
        FileHandle.standardError.write(
            Data("  [encoder-e3] alpha + float32 round-trips (ANS + prefix)\n".utf8))
    }

    /// Encoder size + determinism goldens: encoding these deterministic images
    /// must produce exactly these byte counts. A size increase is a
    /// compression regression; ANY change means the bitstream changed and the
    /// djxl oracle sweep must be re-run before updating the constants.
    /// (Current honest baselines: 96x64 gradient 3290 B vs cjxl -e2 7056 B;
    /// noise shapes are near/above raw because gradient prediction widens
    /// incompressible residuals — predictor selection is E4.)
    static func encoderSizeGate() {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func rnd() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }
        func makeImage(w: Int, h: Int, channels: Int, bits: Int, mode: Int) -> JXLDecodedImage {
            let maxV = Int32((1 << bits) - 1)
            var planes: [[Int32]] = []
            for c in 0..<channels {
                var p = [Int32](repeating: 0, count: w * h)
                for i in 0..<(w * h) {
                    switch mode {
                    case 0: p[i] = Int32((i + c * 37) % (Int(maxV) + 1))
                    case 1: p[i] = Int32(truncatingIfNeeded: Int64(rnd())) & maxV
                    case 2: p[i] = maxV / 2
                    default: p[i] = (i % 2 == 0) ? 0 : maxV
                    }
                }
                planes.append(p)
            }
            return JXLDecodedImage(
                width: w, height: h, colorChannels: channels, extraChannels: 0,
                bitsPerSample: bits, isFloat: false, planes: planes)
        }
        let goldens: [(w: Int, h: Int, ch: Int, bits: Int, mode: Int, size: Int)] = [
            (96, 64, 3, 8, 0, 180), (96, 64, 3, 8, 1, 15739), (256, 256, 3, 8, 1, 92685),
            (300, 200, 3, 8, 1, 187529), (512, 512, 1, 16, 2, 74), (100, 600, 1, 8, 0, 455),
        ]
        for g in goldens {
            let img = makeImage(w: g.w, h: g.h, channels: g.ch, bits: g.bits, mode: g.mode)
            let size = (try? JXL.encodeLossless(image: img).count) ?? -1
            eq(size, g.size, "encoded size golden \(g.w)x\(g.h)/\(g.ch)ch/\(g.bits)bit mode \(g.mode)")
        }
        // E3 goldens: alpha and float32 shapes (deterministic contents; the
        // LCG state continues from the integer goldens above).
        func floatPlane(_ n: Int, seed: Int) -> [Int32] {
            var p = [Int32](repeating: 0, count: n)
            for i in 0..<n {
                if (i + seed) % 13 == 0 {
                    p[i] = Int32(bitPattern: Float(-0.0).bitPattern)
                } else {
                    p[i] = Int32(
                        bitPattern: (Float(i % 100) * 0.01 - 0.5 + Float(seed) * 0.125)
                            .bitPattern)
                }
            }
            return p
        }
        let alphaImg = JXLDecodedImage(
            width: 96, height: 64, colorChannels: 3, extraChannels: 1, bitsPerSample: 8,
            isFloat: false,
            planes: (0..<4).map { c in
                makeImage(w: 96, h: 64, channels: 1, bits: 8, mode: c == 3 ? 2 : 0).planes[0]
            })
        let floatImg = JXLDecodedImage(
            width: 64, height: 64, colorChannels: 3, extraChannels: 0, bitsPerSample: 32,
            isFloat: true, planes: (0..<3).map { floatPlane(64 * 64, seed: $0) })
        let floatNoiseImg = JXLDecodedImage(
            width: 48, height: 32, colorChannels: 1, extraChannels: 0, bitsPerSample: 32,
            isFloat: true,
            planes: [(0..<(48 * 32)).map { _ in
                Int32(bitPattern: UInt32(truncatingIfNeeded: rnd()) & 0xFF7F_FFFF)
            }])
        let e3Goldens: [(name: String, img: JXLDecodedImage, size: Int)] = [
            ("96x64 RGB+alpha gradient", alphaImg, 178),
            ("64x64 float32 RGB smooth", floatImg, 35951),
            ("48x32 float32 gray noise", floatNoiseImg, 6260),
        ]
        for g in e3Goldens {
            let size = (try? JXL.encodeLossless(image: g.img).count) ?? -1
            eq(size, g.size, "encoded size golden \(g.name)")
        }
        FileHandle.standardError.write(
            Data("  [encoder-size] deterministic size goldens hold\n".utf8))
    }

    /// Encoder squeeze (E4d): (a) the forward squeeze followed by the
    /// DECODER'S OWN invSqueeze must be an exact identity on random channels
    /// across odd/even shapes, with the forward channel layout matching the
    /// decoder's metaSqueeze bookkeeping (dims + shifts) — the load-bearing
    /// property, validated before any bitstream; (b) encode-with-squeeze →
    /// our decoder round-trips byte-exactly across coalesced/multi-group/
    /// multi-DC-group shapes, 1/3 channels, alpha, 8/16-bit, both entropy
    /// back-ends and both efforts; (c) float samples are rejected (squeeze's
    /// diff/2 is not congruence-preserving mod 2^32); (d) squeeze output is
    /// deterministic with pinned sizes (djxl oracle sweep re-run before any
    /// re-bless, as with the other size goldens).
    static func squeezeEncoder() {
        var state: UInt64 = 0x5EED_5EED_5EED_5EED
        func rnd() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }

        // (a) forward ∘ inverse identity + layout mirror.
        let idShapes: [(w: Int, h: Int, n: Int)] = [
            (1, 1, 1), (7, 1, 1), (1, 7, 1), (8, 8, 3), (9, 9, 3), (16, 1, 1),
            (1, 16, 3), (64, 48, 3), (33, 70, 1), (65, 33, 3), (127, 2, 3),
            (2, 127, 1), (257, 100, 1), (100, 257, 3), (300, 200, 3), (2100, 32, 1),
        ]
        var identityFailures = 0
        for (idx, shape) in idShapes.enumerated() {
            let (w, h, n) = shape
            // Alternate sample ranges: post-RCT-like 17-bit and tiny (the
            // tendency clamps behave differently near zero).
            let range: Int64 = idx % 3 == 2 ? 4 : 131072
            var original: [ModularChannel] = []
            for _ in 0..<n {
                var mc = ModularChannel(w: w, h: h)
                for i in 0..<(w * h) {
                    mc.pixels[i] = Int32(truncatingIfNeeded: Int64(rnd() % UInt64(2 * range)) - range)
                }
                original.append(mc)
            }
            let layout = ModularImage(w: w, h: h, bitdepth: 16, channelCount: n)
            var params: [SqueezeParams] = []
            guard (try? metaSqueeze(layout, params: &params)) != nil else {
                check(false, "metaSqueeze resolves \(w)x\(h)x\(n)")
                identityFailures += 1
                continue
            }
            var fwd = original
            forwardSqueeze(&fwd, params: params)
            var layoutOK = fwd.count == layout.channels.count
            if layoutOK {
                for (a, b) in zip(fwd, layout.channels)
                where a.w != b.w || a.h != b.h || a.hshift != b.hshift || a.vshift != b.vshift {
                    layoutOK = false
                }
            }
            guard layoutOK else {
                check(false, "squeeze layout mirror \(w)x\(h)x\(n)")
                identityFailures += 1
                continue
            }
            let img = ModularImage(w: w, h: h, bitdepth: 16, channelCount: 0)
            img.channels = fwd
            guard (try? invSqueeze(img, params: params)) != nil, img.channels.count == n else {
                check(false, "invSqueeze runs \(w)x\(h)x\(n)")
                identityFailures += 1
                continue
            }
            for (a, b) in zip(img.channels, original)
            where a.w != b.w || a.h != b.h || a.pixels != b.pixels {
                identityFailures += 1
                break
            }
        }
        eq(identityFailures, 0, "forward∘invSqueeze identity (\(idShapes.count) shapes)")

        // (b) bitstream round-trips through our decoder.
        func makeImage(w: Int, h: Int, channels: Int, extra: Int, bits: Int, mode: Int)
            -> JXLDecodedImage
        {
            let maxV = Int32((1 << bits) - 1)
            var planes: [[Int32]] = []
            for c in 0..<(channels + extra) {
                var p = [Int32](repeating: 0, count: w * h)
                for i in 0..<(w * h) {
                    switch mode {
                    case 0: p[i] = Int32((i + c * 37) % (Int(maxV) + 1))  // gradient-ish
                    default: p[i] = Int32(truncatingIfNeeded: Int64(rnd())) & maxV  // noise
                    }
                }
                planes.append(p)
            }
            return JXLDecodedImage(
                width: w, height: h, colorChannels: channels, extraChannels: extra,
                bitsPerSample: bits, isFloat: false, planes: planes)
        }
        // Odd/even dims, 1/3 channels, alpha, 8/16-bit, multi-group (>256)
        // and multi-DC-group (>2048 in one dimension, both orientations).
        let rtShapes: [(w: Int, h: Int, ch: Int, extra: Int, bits: Int, mode: Int)] = [
            (9, 7, 1, 0, 8, 0), (64, 48, 3, 0, 8, 1), (65, 33, 1, 0, 8, 0),
            (96, 64, 3, 0, 16, 1), (257, 130, 3, 0, 8, 0), (300, 200, 3, 0, 16, 1),
            (100, 600, 1, 0, 8, 0), (2100, 32, 1, 0, 8, 0), (31, 2100, 3, 0, 8, 1),
            (300, 130, 3, 1, 8, 1),
        ]
        var rtFailures = 0
        for (w, h, ch, extra, bits, mode) in rtShapes {
            let img = makeImage(w: w, h: h, channels: ch, extra: extra, bits: bits, mode: mode)
            var configs: [(ModularEncoder.EntropyBackend, Int)] = [(.ans, 2), (.prefix, 2)]
            if (w == 257 && h == 130) || (w == 2100 && h == 32) { configs.append((.ans, 1)) }
            for (backend, effort) in configs {
                do {
                    let jxl = try ModularEncoder.encodeLossless(
                        img, backend: backend, effort: effort, squeeze: true)
                    let dec = try JXL.decodeImage(from: jxl)
                    guard dec.width == w, dec.height == h, dec.colorChannels == ch,
                        dec.extraChannels == extra, dec.bitsPerSample == bits
                    else {
                        check(false, "squeeze rt header \(w)x\(h)/\(ch)+\(extra)/\(bits) \(backend) e\(effort)")
                        rtFailures += 1
                        continue
                    }
                    for c in 0..<(ch + extra) where dec.planes[c] != img.planes[c] {
                        check(false, "squeeze rt plane \(c) \(w)x\(h)/\(ch)+\(extra)/\(bits) \(backend) e\(effort)")
                        rtFailures += 1
                        break
                    }
                } catch {
                    check(false, "squeeze rt encode \(w)x\(h)/\(ch)+\(extra)/\(bits) \(backend) e\(effort): \(error)")
                    rtFailures += 1
                }
            }
        }
        eq(rtFailures, 0, "squeeze round-trip byte-exact (\(rtShapes.count) shapes x backends)")

        // (c) float + squeeze rejected.
        let floatImg = JXLDecodedImage(
            width: 8, height: 8, colorChannels: 1, extraChannels: 0, bitsPerSample: 32,
            isFloat: true, planes: [[Int32](repeating: Int32(bitPattern: Float(0.5).bitPattern), count: 64)])
        check(
            (try? ModularEncoder.encodeLossless(floatImg, squeeze: true)) == nil,
            "squeeze rejects float samples")

        // (d) determinism + size goldens (same regime as encoderSizeGate:
        // any change means the bitstream changed → djxl sweep before
        // re-blessing). Contents are isolated from the shared LCG above.
        let gradImg = makeImage(w: 100, h: 600, channels: 1, extra: 0, bits: 8, mode: 0)
        state = 0xA5A5_5A5A_1234_4321
        let noiseImg = makeImage(w: 96, h: 64, channels: 3, extra: 0, bits: 8, mode: 1)
        let gradSq = (try? JXL.encodeLossless(image: gradImg, squeeze: true)) ?? []
        eq(gradSq.count, 3668, "squeeze size golden 100x600 gradient")
        eq((try? JXL.encodeLossless(image: noiseImg, squeeze: true))?.count ?? -1, 18341,
            "squeeze size golden 96x64 noise")
        eq((try? JXL.encodeLossless(image: gradImg, squeeze: true)) ?? [], gradSq,
            "squeeze encode deterministic")
        FileHandle.standardError.write(
            Data("  [encoder-squeeze] forward identity + round-trips + goldens\n".utf8))
    }

    /// Regression (encoder-fuzzer seed 1011): palette + multi-group + extra
    /// channels. The decoder renumbers channels LOCALLY in per-group
    /// sub-streams (decodeModularGroupImage builds the group image from
    /// beginC onward, so property 0 restarts at 0), while the encoder used
    /// to pass full-image indices — any learned tree splitting on property 0
    /// then routed pixels to different leaves on the two sides and desynced
    /// the stream (finalState). A 2-value 16-bit gray plane forces palette
    /// (meta channel ⇒ beginC = 1); 513 tall forces multiple groups; two
    /// extra channels with contrasting content make a property-0 split
    /// near-certain.
    static func paletteGroupChannelIndex() {
        var state: UInt64 = 0xFEED_FACE_CAFE_BEEF
        func rnd() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }
        let w = 135
        let h = 513
        var gray = [Int32](repeating: 0, count: w * h)
        // 2-value noise: the palette index stream wins by an order of
        // magnitude, so the public entry's palette-vs-direct race reliably
        // keeps the palette encoding (the path under test).
        for i in 0..<(w * h) { gray[i] = rnd() & 1 == 0 ? 100 : 40000 }
        var extra1 = [Int32](repeating: 0, count: w * h)
        for i in 0..<(w * h) { extra1[i] = Int32(i % 65536) }  // gradient
        var extra2 = [Int32](repeating: 0, count: w * h)
        for i in 0..<(w * h) { extra2[i] = Int32(truncatingIfNeeded: Int64(rnd())) & 0xFFFF }
        let img = JXLDecodedImage(
            width: w, height: h, colorChannels: 1, extraChannels: 2, bitsPerSample: 16,
            isFloat: false, planes: [gray, extra1, extra2])
        var failures = 0
        for backend in [ModularEncoder.EntropyBackend.ans, .prefix] {
            do {
                let jxl = try ModularEncoder.encodeLossless(img, backend: backend, effort: 2)
                let dec = try JXL.decodeImage(from: jxl)
                for c in 0..<3 where dec.planes[c] != img.planes[c] {
                    check(false, "palette multi-group chan index: plane \(c) (\(backend))")
                    failures += 1
                    break
                }
            } catch {
                check(false, "palette multi-group chan index (\(backend)): \(error)")
                failures += 1
            }
        }
        eq(failures, 0, "palette + multi-group + extra channels round-trip (both backends)")
        FileHandle.standardError.write(
            Data("  [encoder-palette] group-local channel indices (fuzz regression)\n".utf8))
    }

    /// Header writers → the decoder's own parsers: dimensions, bit depth, and
    /// color space survive the round trip for a spread of shapes.
    static func headerWriterRoundTrip() {
        let cases: [(w: UInt32, h: UInt32, bits: UInt32, gray: Bool)] = [
            (1, 1, 8, false), (96, 64, 8, false), (4096, 2160, 16, false),
            (513, 511, 12, false), (200, 150, 8, true), (1 << 18, 3, 8, false),
        ]
        var failures = 0
        for c in cases {
            let w = BitWriter()
            HeaderWriter.writeCodestreamHeaders(
                w, width: c.w, height: c.h, bitsPerSample: c.bits, grayscale: c.gray)
            guard let info = try? JXL.readInfo(from: w.finalize()) else {
                check(false, "headers parse (\(c.w)x\(c.h))")
                failures += 1
                continue
            }
            if info.width != c.w || info.height != c.h
                || info.bitDepth.bitsPerSample != c.bits
                || (info.colorSpace == .grayscale) != c.gray
                || info.hasAlpha || info.hasAnimation || info.orientation != 1
            {
                failures += 1
            }
        }
        eq(failures, 0, "header write->readInfo identity (\(cases.count) shapes)")
        // E3 metadata: float32 bit depth and alpha extra channels survive the
        // write->readInfo round trip (BitDepth float path + ExtraChannelInfo).
        let e3Cases: [(bits: UInt32, exp: UInt32, gray: Bool, alpha: Int)] = [
            (32, 8, false, 0), (32, 8, true, 0), (32, 8, false, 1),
            (8, 0, false, 1), (16, 0, false, 1), (8, 0, true, 2),
        ]
        var e3Failures = 0
        for c in e3Cases {
            let w = BitWriter()
            HeaderWriter.writeCodestreamHeaders(
                w, width: 10, height: 10, bitsPerSample: c.bits, grayscale: c.gray,
                exponentBits: c.exp, alphaChannels: c.alpha)
            guard let info = try? JXL.readInfo(from: w.finalize()) else {
                e3Failures += 1
                continue
            }
            let depthOK =
                info.bitDepth.bitsPerSample == c.bits
                && info.bitDepth.exponentBitsPerSample == c.exp
            let colorOK = (info.colorSpace == .grayscale) == c.gray
            let countOK = info.extraChannelCount == c.alpha && info.hasAlpha == (c.alpha > 0)
            // (per-EC bit depth / dim_shift are exercised end-to-end by the
            // E3 round-trip tests, which decode through the full EC path)
            let ecOK = !info.alphaPremultiplied
            if !(depthOK && colorOK && countOK && ecOK) {
                e3Failures += 1
            }
        }
        eq(e3Failures, 0, "header write->readInfo identity, float/alpha (\(e3Cases.count) shapes)")
        FileHandle.standardError.write(
            Data("  [header-writer] size/metadata/transform-data duals verified\n".utf8))
    }

    /// `128x128_pdc2.jxl` (cjxl -d 1.5 --progressive_dc=2): a VarDCT frame
    /// whose DC comes from a level-1 DC frame that *itself* uses a level-2 DC
    /// frame (a two-deep kUseDcFrame chain, DCLEVELS=[2,1]). The intermediate
    /// DC frame is VarDCT and uses custom parametric dequant matrices (mode 6),
    /// so this also exercises the custom-quant-table decode. Oracle is djxl's
    /// float PFM; lossy, so compared at PSNR.
    static func nestedDCFrames() {
        let dir = fixturesDir()
        let base = "128x128_pdc2"
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent(base + ".jxl")),
            let pfm = try? Data(contentsOf: dir.appendingPathComponent(base + ".pfm")),
            let oracle = parsePFM(pfm),
            let img = try? JXL.decodeImage(from: [UInt8](jxl), format: .float32)
        else {
            check(false, "\(base) fixtures decode")
            return
        }
        eq(img.width, oracle.width, "\(base) width")
        eq(img.height, oracle.height, "\(base) height")
        var se = 0.0
        let n = img.width * img.height
        for c in 0..<3 {
            for i in 0..<n {
                let ours = Float(bitPattern: UInt32(bitPattern: img.planes[c][i]))
                let ref = Float(bitPattern: UInt32(bitPattern: oracle.planes[c][i]))
                let d = Double(ours - ref)
                se += d * d
            }
        }
        let rms = (se / Double(n * 3)).squareRoot()
        let psnr = rms == 0 ? 999 : -20 * log10(rms)
        check(psnr > 70, "nested DC frames match djxl (PSNR \(Int(psnr)) dB)")
        FileHandle.standardError.write(
            Data("  [nested-dc] progressive_dc=2 + custom parametric dequant vs djxl\n".utf8))
    }

    /// `256x192_patmod.jxl` (cjxl -d 0 -e 9 --patches=1, 16-bit RGBA with
    /// repeated alpha-blended stamps): a native-space Modular frame whose
    /// kPatches flag pulls crops from a referenceOnly frame through the
    /// full-plane blender (all-mode PerformBlending port, incl. alpha and
    /// extra-channel blendings). Oracle is djxl's 16-bit PAM; lossless, so
    /// byte-exact — color and alpha.
    static func modularPatches() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("256x192_patmod.jxl")),
            let pam = try? Data(contentsOf: dir.appendingPathComponent("256x192_patmod.pam")),
            let img = try? JXL.decodeImage(from: [UInt8](jxl), format: .uint16),
            img.planes.count == 4,
            let headerEnd = pam.range(of: Data("ENDHDR\n".utf8))
        else {
            check(false, "patmod fixture decodes")
            return
        }
        // The fixture must actually exercise the patch path.
        if let decoder = try? FrameDecoder(data: [UInt8](jxl)) {
            check(decoder.frameHeader.flags & 2 != 0, "patmod frame has kPatches set")
        } else {
            check(false, "patmod frame header parses")
        }
        let bytes = [UInt8](pam[headerEnd.upperBound...])
        let n = img.width * img.height
        guard bytes.count == n * 4 * 2 else {
            check(false, "patmod oracle size")
            return
        }
        var mismatches = 0
        for i in 0..<n {
            for c in 0..<4 {
                let idx = (i * 4 + c) * 2
                let ref = Int(bytes[idx]) << 8 | Int(bytes[idx + 1])
                if ref != Int(img.planes[c][i]) { mismatches += 1 }
            }
        }
        eq(mismatches, 0, "patmod byte-exact vs djxl (RGBA)")
        FileHandle.standardError.write(
            Data("  [modular-patches] native-modular patches byte-exact vs djxl\n".utf8))
    }

    /// Out-of-order `jxlp` boxes (ftyp minor version 1, libjxl v0.12):
    /// partial-codestream boxes are ordered by their 4-byte index, the top
    /// index bit marks the last box, and duplicate or missing indices are
    /// malformed. Containers are built programmatically from a bare fixture.
    static func jxlpOutOfOrder() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("96x64_deltapal.jxl")),
            let parsed = try? JXLContainer.parse([UInt8](jxl)),
            let want = try? JXL.decodeImage(from: [UInt8](jxl))
        else {
            check(false, "jxlp base fixture decodes")
            return
        }
        let cs = parsed.codestream
        let third = cs.count / 3
        let chunks = [Array(cs[0..<third]), Array(cs[third..<2 * third]), Array(cs[(2 * third)...])]
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            var out = [UInt8]()
            let size = UInt32(8 + payload.count)
            out.append(contentsOf: [
                UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF),
                UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF),
            ])
            out.append(contentsOf: Array(type.utf8))
            out.append(contentsOf: payload)
            return out
        }
        func jxlp(_ seq: UInt32, last: Bool, _ chunk: [UInt8]) -> [UInt8] {
            let idx = seq | (last ? 0x8000_0000 : 0)
            return box(
                "jxlp",
                [
                    UInt8(idx >> 24 & 0xFF), UInt8(idx >> 16 & 0xFF),
                    UInt8(idx >> 8 & 0xFF), UInt8(idx & 0xFF),
                ] + chunk)
        }
        let sig: [UInt8] = JXLContainer.containerSignature
        let ftyp = box("ftyp", Array("jxl ".utf8) + [0, 0, 0, 1] + Array("jxl ".utf8))
        // File order 1, 2(last), 0 — must reassemble as 0, 1, 2.
        let shuffled =
            sig + ftyp + jxlp(1, last: false, chunks[1]) + jxlp(2, last: true, chunks[2])
            + jxlp(0, last: false, chunks[0])
        if let img = try? JXL.decodeImage(from: shuffled) {
            var same = img.width == want.width && img.height == want.height
            if same { same = img.planes == want.planes }
            check(same, "out-of-order jxlp reassembles to the same image")
        } else {
            check(false, "out-of-order jxlp decodes")
        }
        // Duplicate index is malformed.
        let dup =
            sig + ftyp + jxlp(0, last: false, chunks[0]) + jxlp(0, last: false, chunks[1])
            + jxlp(2, last: true, chunks[2])
        check((try? JXLContainer.parse(dup)) == nil, "duplicate jxlp index rejected")
        // Missing index is malformed.
        let gap =
            sig + ftyp + jxlp(0, last: false, chunks[0]) + jxlp(2, last: true, chunks[2])
        check((try? JXLContainer.parse(gap)) == nil, "missing jxlp index rejected")
        // 'last' flag on a non-final box is malformed.
        let badLast =
            sig + ftyp + jxlp(0, last: true, chunks[0]) + jxlp(1, last: false, chunks[1])
        check((try? JXLContainer.parse(badLast)) == nil, "misplaced jxlp last flag rejected")
        FileHandle.standardError.write(
            Data("  [jxlp] out-of-order reassembly + index validation\n".utf8))
    }

    /// `96x64_spotcolor.jxl` (libjxl C API, lossless 16-bit RGB + alpha + one
    /// spot channel, spot_color ≈ (0.9, 0.2, 0.05, scale 0.75)): default
    /// decode renders the spot channel onto the color planes (libjxl
    /// stage_spot, `color = mix·spot_rgb + (1−mix)·color`); oracle is djxl's
    /// 16-bit PPM (max ±1 from double rounding). `renderSpotColors: false`
    /// must return the untouched lossless gradient exactly.
    static func spotColorRendering() {
        let dir = fixturesDir()
        guard
            let jxl = try? Data(contentsOf: dir.appendingPathComponent("96x64_spotcolor.jxl")),
            let ppm = try? Data(contentsOf: dir.appendingPathComponent("96x64_spotcolor.ppm")),
            let rendered = try? JXL.decodeImage(from: [UInt8](jxl), format: .uint16),
            let raw = try? JXL.decodeImage(
                from: [UInt8](jxl), format: .uint16, renderSpotColors: false)
        else {
            check(false, "spotcolor fixtures decode")
            return
        }
        // Parse the 16-bit big-endian PPM oracle.
        let bytes = [UInt8](ppm)
        var pos = 2
        var fields = [Int]()
        while fields.count < 3 {
            while bytes[pos] == 0x20 || bytes[pos] == 0x0A { pos += 1 }
            var v = 0
            while bytes[pos] >= 0x30 && bytes[pos] <= 0x39 {
                v = v * 10 + Int(bytes[pos] - 0x30)
                pos += 1
            }
            fields.append(v)
        }
        pos += 1
        let (w, h) = (fields[0], fields[1])
        eq(w, rendered.width, "spotcolor width")
        var maxDiff = 0
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let o = pos + (i * 3 + c) * 2
                let ref = Int(bytes[o]) << 8 | Int(bytes[o + 1])
                maxDiff = max(maxDiff, abs(ref - Int(rendered.planes[c][i])))
            }
        }
        check(maxDiff <= 1, "spot rendering within ±1 of djxl 16-bit (max \(maxDiff))")
        // Un-rendered output is the exact lossless gradient.
        var rawExact = true
        for y in 0..<h where rawExact {
            for x in 0..<w {
                let i = y * w + x
                if raw.planes[0][i] != Int32(x * 65535 / (w - 1))
                    || raw.planes[1][i] != Int32(y * 65535 / (h - 1))
                    || raw.planes[2][i] != Int32((x + y) * 65535 / (w + h - 2))
                {
                    rawExact = false
                    break
                }
            }
        }
        check(rawExact, "renderSpotColors: false leaves color planes untouched")
        check(rendered.planes[0] != raw.planes[0], "spot rendering changed the red plane")
        FileHandle.standardError.write(
            Data("  [spot-color] rendering vs djxl (max ±1), norender exact\n".utf8))
    }

    /// `96x64_jpeg444.jxl` is a 4:4:4 JPEG transcode (no chroma upsampling in
    /// play). Wide output: float32 must sit within a few ulp of djxl's PFM
    /// (the lossy VarDCT float pipeline itself carries ~1-ulp disagreement, so
    /// bit-exactness is not achievable), and uint16 must equal the clamped
    /// round of the float samples.
    static func jpegTranscodeWide() {
        let dir = fixturesDir()
        let base = "96x64_jpeg444"
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent(base + ".jxl")),
            let pfm = try? Data(contentsOf: dir.appendingPathComponent(base + ".pfm")),
            let oracle = parsePFM(pfm),
            let imgF = try? JXL.decodeImage(from: [UInt8](jxl), format: .float32),
            let img16 = try? JXL.decodeImage(from: [UInt8](jxl), format: .uint16)
        else {
            check(false, "\(base) wide fixtures decode")
            return
        }
        check(imgF.isFloat && imgF.bitsPerSample == 32, "\(base) float output is float32")
        eq(imgF.width, oracle.width, "\(base) width")
        var maxDiff: Float = 0
        var bad16 = 0
        for c in 0..<3 {
            for i in 0..<(imgF.width * imgF.height) {
                let ours = Float(bitPattern: UInt32(bitPattern: imgF.planes[c][i]))
                let ref = Float(bitPattern: UInt32(bitPattern: oracle.planes[c][i]))
                maxDiff = max(maxDiff, abs(ours - ref))
                let want16 = Int32(max(0, min(65535, (ours * 65535).rounded())))
                if img16.planes[c][i] != want16 { bad16 += 1 }
            }
        }
        check(maxDiff < 4e-6, "\(base) float within 4e-6 of djxl PFM (max \(maxDiff))")
        eq(bad16, 0, "\(base) uint16 consistent with float")
        check(img16.bitsPerSample == 16 && !img16.isFloat, "\(base) uint16 shape")
        FileHandle.standardError.write(
            Data("  [jpeg-wide] YCbCr transcode wide output vs djxl PFM\n".utf8))
    }

    /// Minimal PFM reader (color, either endianness) returning int32 bit
    /// patterns per plane in top-down row order.
    static func parsePFM(_ data: Data) -> (width: Int, height: Int, planes: [[Int32]])? {
        let bytes = [UInt8](data)
        var pos = 0
        func line() -> String? {
            guard let nl = bytes[pos...].firstIndex(of: 0x0A) else { return nil }
            defer { pos = nl + 1 }
            return String(bytes: bytes[pos..<nl], encoding: .utf8)
        }
        guard line() == "PF", let dims = line()?.split(separator: " "),
            dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]),
            let scaleStr = line(), let scale = Float(scaleStr)
        else { return nil }
        let littleEndian = scale < 0
        guard bytes.count - pos >= w * h * 12 else { return nil }
        var planes = [[Int32]](repeating: [Int32](repeating: 0, count: w * h), count: 3)
        for row in 0..<h {
            let y = h - 1 - row  // PFM rows are bottom-up
            for x in 0..<w {
                for c in 0..<3 {
                    let o = pos + (row * w + x) * 12 + c * 4
                    var v =
                        UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8
                        | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                    if !littleEndian { v = v.byteSwapped }
                    planes[c][y * w + x] = Int32(bitPattern: v)
                }
            }
        }
        return (w, h, planes)
    }

    // MARK: - Progressive (multi-pass) VarDCT

    /// `384x256_prog{,q}.jxl` (cjxl --progressive_ac / --qprogressive_ac) are
    /// multi-group, multi-pass VarDCT frames: each pass carries its own
    /// histograms/orders and its coefficients accumulate with the Passes
    /// header's per-pass shifts. Oracles are djxl PPMs.
    static func progressiveAC() {
        let dir = fixturesDir()
        for name in ["384x256_prog", "384x256_progq"] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img = try? JXL.decodeImage(from: [UInt8](jxl))
            else {
                check(false, "\(name) fixture decodes")
                continue
            }
            var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
            for c in 0..<3 {
                for i in 0..<(img.width * img.height) {
                    rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
                }
            }
            let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
            check(psnr > 50, "\(name) matches djxl (PSNR \(Int(psnr)) dB)")
        }
        FileHandle.standardError.write(
            Data("  [progressive] multi-pass AC fixtures match djxl=2\n".utf8))
    }

    // MARK: - Wide / upsampled extra channels in VarDCT

    /// `96x64_alpha16.jxl` (16-bit RGBA, cjxl -d 1) — non-8-bit extra
    /// channels decode at native depth and scale to the output format (16-bit
    /// output: alpha byte-exact vs djxl). `96x64_ecups.jxl` (cjxl
    /// --resampling=2 --ec_resampling=2) — the alpha channel is coded at half
    /// resolution and goes through the triangular upsampler.
    static func wideExtraChannels() {
        let dir = fixturesDir()
        func comparePAM(_ name: String, format: JXLSampleFormat, alphaExactRequired: Bool) {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let pam = try? Data(contentsOf: dir.appendingPathComponent("\(name).pam")),
                let img = try? JXL.decodeImage(from: [UInt8](jxl), format: format),
                img.planes.count == 4,
                let headerEnd = pam.range(of: Data("ENDHDR\n".utf8))
            else {
                check(false, "\(name) fixture decodes")
                return
            }
            let bytes = [UInt8](pam[headerEnd.upperBound...])
            let n = img.width * img.height
            let is16 = format == .uint16
            let maxVal = is16 ? 65535.0 : 255.0
            guard bytes.count == n * 4 * (is16 ? 2 : 1) else {
                check(false, "\(name) oracle size")
                return
            }
            func sample(_ i: Int, _ c: Int) -> Int {
                let idx = (i * 4 + c) * (is16 ? 2 : 1)
                return is16 ? Int(bytes[idx]) << 8 | Int(bytes[idx + 1]) : Int(bytes[idx])
            }
            var se = 0.0
            var alphaExact = true
            for i in 0..<n {
                for c in 0..<3 {
                    let d = Double(sample(i, c) - Int(img.planes[c][i]))
                    se += d * d
                }
                if sample(i, 3) != Int(img.planes[3][i]) { alphaExact = false }
            }
            let mse = se / Double(n * 3)
            let psnr = mse == 0 ? 999 : 10 * log10(maxVal * maxVal / mse)
            check(psnr > 50, "\(name) color matches djxl (PSNR \(Int(psnr)) dB)")
            if alphaExactRequired {
                check(alphaExact, "\(name) alpha byte-exact vs djxl")
            }
        }
        comparePAM("96x64_alpha16", format: .uint16, alphaExactRequired: true)
        comparePAM("96x64_ecups", format: .uint8, alphaExactRequired: false)
        FileHandle.standardError.write(
            Data("  [wide-ec] 16-bit + upsampled extra channels verified\n".utf8))
    }

    // MARK: - DC frames + progressive modular / extra channels

    /// LF-frame and pass-bracket coverage: `96x64_pdc.jxl` (cjxl
    /// --progressive_dc=1: a Modular-XYB DC frame feeds the main frame's
    /// kUseDcFrame flag), `384x256_pdcac.jxl` (DC frame + 3 HF passes,
    /// multi-group — the DC frame is itself multi-pass modular),
    /// `384x256_mprog.jxl` (progressive *modular* presented frame: squeeze
    /// channels bracketed by shift across pass sections; lossless, so
    /// byte-exact), and `96x64_alphaprog.jxl` (VarDCT + alpha + 3 passes:
    /// the extra channel rides the per-pass bracket walk; alpha byte-exact).
    static func progressiveDC() {
        let dir = fixturesDir()
        for (name, exact) in [("96x64_pdc", false), ("384x256_pdcac", false), ("384x256_mprog", true)] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img = try? JXL.decodeImage(from: [UInt8](jxl))
            else {
                check(false, "\(name) fixture decodes")
                continue
            }
            var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
            for c in 0..<3 {
                for i in 0..<(img.width * img.height) {
                    rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
                }
            }
            let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
            if exact {
                check(psnr == 999, "\(name) byte-exact vs djxl")
            } else {
                check(psnr > 50, "\(name) matches djxl (PSNR \(Int(psnr)) dB)")
            }
        }
        // Alpha through the pass-bracketed extra-channel walk.
        if let jxl = try? Data(contentsOf: dir.appendingPathComponent("96x64_alphaprog.jxl")),
            let pam = try? Data(contentsOf: dir.appendingPathComponent("96x64_alphaprog.pam")),
            let img = try? JXL.decodeImage(from: [UInt8](jxl)), img.planes.count == 4,
            let headerEnd = pam.range(of: Data("ENDHDR\n".utf8))
        {
            let pixels = [UInt8](pam[headerEnd.upperBound...])
            let n = img.width * img.height
            var se = 0.0
            var alphaExact = pixels.count == n * 4
            if alphaExact {
                for i in 0..<n {
                    for c in 0..<3 {
                        let d = Double(Int(pixels[i * 4 + c]) - Int(img.planes[c][i]))
                        se += d * d
                    }
                    if Int32(pixels[i * 4 + 3]) != img.planes[3][i] { alphaExact = false }
                }
            }
            let mse = se / Double(n * 3)
            check(mse > 0 && 10 * log10(255.0 * 255.0 / mse) > 50, "alphaprog color matches djxl")
            check(alphaExact, "alphaprog alpha byte-exact vs djxl")
        } else {
            check(false, "alphaprog fixture decodes")
        }
        FileHandle.standardError.write(
            Data("  [progressive-dc] DC frames + modular passes + EC brackets verified\n".utf8))
    }

    // MARK: - ICC output (matrix + TRC CMS)

    /// `appl_display.icc` is a real Apple display profile (matrix colorants +
    /// shared 1024-entry 'curv' TRC — the profile embedded by the conformance
    /// `patches` testcase). The expected linear-sRGB -> device matrix was
    /// computed independently (numpy: inv(colorants) @ bradford(D65->D50) @
    /// sRGB-to-XYZ), and the tone curve must round-trip. `96x64_iccout.jxl`
    /// embeds the same profile; its decode must attach it and produce samples
    /// in the profile's space (validated at the corpus level vs lcms/djxl).
    static func iccOutput() {
        let dir = fixturesDir()
        guard let iccData = try? Data(contentsOf: dir.appendingPathComponent("appl_display.icc")),
            let profile = parseICCOutputProfile([UInt8](iccData))
        else {
            check(false, "appl_display.icc parses as matrix+TRC")
            return
        }
        check(!profile.isGray, "profile is RGB")
        let expected: [Float] = [
            0.827775, 0.178156, -0.006040,
            0.032518, 0.952290, 0.015222,
            0.017108, 0.072526, 0.910725,
        ]
        if let m = profile.matrix {
            var maxErr: Float = 0
            for i in 0..<9 { maxErr = max(maxErr, abs(m[i] - expected[i])) }
            check(maxErr < 5e-4, "ICC output matrix matches independent computation (err \(maxErr))")
        } else {
            check(false, "profile has a matrix")
        }
        // TRC: decode is monotone on [0,1] and encode inverts it.
        var maxRT = 0.0
        var monotone = true
        var prev = -1.0
        for i in 0...200 {
            let s = Double(i) / 200
            let lin = profile.trc.decode(s)
            if lin < prev - 1e-9 { monotone = false }
            prev = lin
            maxRT = max(maxRT, abs(profile.trc.encode(lin) - s))
        }
        check(monotone, "TRC decode is monotone")
        check(maxRT < 2e-3, "TRC encode inverts decode (max err \(maxRT))")

        // Decode of a file embedding this profile: samples are in the
        // profile's space and the profile rides along.
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("96x64_iccout.jxl")),
            let img = try? JXL.decodeImage(from: [UInt8](jxl))
        else {
            check(false, "96x64_iccout decodes")
            return
        }
        eq(img.iccProfile, iccData, "decoded image carries the embedded ICC profile")
        FileHandle.standardError.write(
            Data("  [icc-output] matrix+TRC profile conversion verified\n".utf8))
    }

    // MARK: - Delta palette (lossy palette)

    /// `96x64_deltapal.jxl` was produced through the libjxl encoder API with
    /// JXL_ENC_FRAME_SETTING_LOSSY_PALETTE on a lossless modular frame, so its
    /// palette carries delta entries (indices below nb_deltas add the palette
    /// value to an Average4 prediction — the InvPalette delta path). Oracle is
    /// djxl's PPM; output must be byte-exact.
    static func deltaPalette() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("96x64_deltapal.jxl")),
            let refPPM = try? Data(contentsOf: dir.appendingPathComponent("96x64_deltapal.ppm")),
            let img = try? JXL.decodeImage(from: jxl), img.planes.count >= 3
        else {
            check(false, "delta palette fixture decodes")
            return
        }
        var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
        for c in 0..<3 {
            for i in 0..<(img.width * img.height) {
                rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
            }
        }
        let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
        check(psnr == 999, "96x64_deltapal byte-exact vs djxl")
        FileHandle.standardError.write(
            Data("  [delta-palette] lossy-palette fixture byte-exact\n".utf8))
    }

    // MARK: - EXIF orientation baking

    /// `JXL.applyOrientation` against hand-computed expectations on a 3x2
    /// raster (values = source index, so every position is distinguishable).
    static func orientationBaking() {
        // Source (w=3, h=2): 0 1 2 / 3 4 5.
        let src = JXLDecodedImage(
            width: 3, height: 2, colorChannels: 1, extraChannels: 0,
            bitsPerSample: 8, isFloat: false, planes: [[0, 1, 2, 3, 4, 5]],
            iccProfile: nil)
        let expected: [UInt32: (w: Int, h: Int, px: [Int32])] = [
            1: (3, 2, [0, 1, 2, 3, 4, 5]),
            2: (3, 2, [2, 1, 0, 5, 4, 3]),  // mirror horizontal
            3: (3, 2, [5, 4, 3, 2, 1, 0]),  // rotate 180
            4: (3, 2, [3, 4, 5, 0, 1, 2]),  // mirror vertical
            5: (2, 3, [0, 3, 1, 4, 2, 5]),  // transpose
            6: (2, 3, [3, 0, 4, 1, 5, 2]),  // rotate 90 CW
            7: (2, 3, [5, 2, 4, 1, 3, 0]),  // transverse
            8: (2, 3, [2, 5, 1, 4, 0, 3]),  // rotate 90 CCW
        ]
        for (o, exp) in expected.sorted(by: { $0.key < $1.key }) {
            let out = JXL.applyOrientation(src, orientation: o)
            eq(out.width, exp.w, "orientation \(o) width")
            eq(out.height, exp.h, "orientation \(o) height")
            eq(out.planes[0], exp.px, "orientation \(o) pixels")
        }
        FileHandle.standardError.write(
            Data("  [orientation] all 8 EXIF orientations verified\n".utf8))
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

    // MARK: - Patches (reference frames + patch dictionary)

    /// `256x192_patches.jxl` (cjxl -d 1.0 -e 7, repeated glyph stamps) encodes
    /// a Modular-XYB referenceOnly frame followed by a VarDCT main frame with
    /// kPatches: the dictionary places crops of the reference frame back onto
    /// the image before the color transform. Reconstruction must match djxl.
    static func patches() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("256x192_patches.jxl")),
            let refPPM = try? Data(contentsOf: dir.appendingPathComponent("256x192_patches.ppm"))
        else {
            check(false, "patches fixture present")
            return
        }
        // readFrameInfo skips the reference frame and reports the presented
        // VarDCT frame, whose header sets kPatches (flags bit 2).
        if let info = try? JXL.readFrameInfo(from: jxl) {
            check(!info.isModular, "patches presented frame is VarDCT")
            check(info.frameType == .regular, "patches presented frame is regular")
            check(info.flags & 2 != 0, "patches presented frame sets kPatches")
        } else {
            check(false, "patches readFrameInfo")
        }
        guard let img = try? JXL.decodeImage(from: jxl), img.planes.count == 3 else {
            check(false, "patches fixture decodes")
            return
        }
        var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
        for c in 0..<3 {
            for i in 0..<(img.width * img.height) {
                rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
            }
        }
        let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
        check(psnr > 50, "patches reconstruction matches djxl (PSNR \(Int(psnr)) dB)")
    }

    // MARK: - EPF pass counts (epf_iters != 1)

    /// `256x192_epf2.jxl` (cjxl --epf=2) runs EPF passes 1+2; `160x120_epf3.jxl`
    /// (cjxl --epf=3) runs all three (0, 1, 2). Both must match djxl.
    static func epfIters() {
        let dir = fixturesDir()
        for name in ["256x192_epf2", "160x120_epf3"] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img = try? JXL.decodeImage(from: jxl)
            else {
                check(false, "\(name) fixture decodes")
                continue
            }
            var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
            for c in 0..<3 {
                for i in 0..<(img.width * img.height) {
                    rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
                }
            }
            let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
            check(psnr > 50, "\(name) matches djxl (PSNR \(Int(psnr)) dB)")
        }
    }

    // MARK: - Brotli (RFC 7932 decoder, for jbrd JPEG reconstruction)

    /// `brotli_{text,rand,rep}.br` were produced by the reference `brotli` CLI
    /// (q11 English text — static dictionary + transforms + context modeling;
    /// q5 random bytes — uncompressed metablocks; q9 repeats — backward
    /// references). Decompression must be byte-exact.
    static func brotli() {
        let dir = fixturesDir()
        for name in ["brotli_text", "brotli_rand", "brotli_rep"] {
            guard
                let compressed = try? Data(contentsOf: dir.appendingPathComponent("\(name).br")),
                let expected = try? Data(contentsOf: dir.appendingPathComponent("\(name).raw"))
            else {
                check(false, "\(name) vectors present")
                continue
            }
            do {
                let got = try Brotli.decompress([UInt8](compressed), maxOutputSize: 16 << 20)
                check(got == [UInt8](expected), "\(name) decompresses byte-exact")
            } catch {
                check(false, "\(name) decompresses (\(error))")
            }
        }
        // A truncated stream must fail cleanly (throw or finish), never crash;
        // reaching the check at all is the assertion.
        if let compressed = try? Data(contentsOf: dir.appendingPathComponent("brotli_text.br")) {
            let truncated = [UInt8](compressed.prefix(compressed.count / 2))
            _ = try? Brotli.decompress(truncated, maxOutputSize: 16 << 20)
            check(true, "brotli truncated stream handled without crashing")
        }
    }

    // MARK: - Frame blending (composited animations)

    /// `96x64_blend.jxl` (lossy) / `96x64_blendll.jxl` (lossless) come from an
    /// APNG whose frames 1-3 are partial crops alpha-OVER-blended onto the
    /// canvas. Each decoded frame must match djxl's composited APNG output
    /// (`.rgba` oracles): near-exact for lossless (float-rounding ±1), looser
    /// for lossy where per-frame codec differences accumulate through the
    /// blend chain.
    static func frameBlending() {
        let dir = fixturesDir()
        for (name, minPSNR) in [("96x64_blendll", 55.0), ("96x64_blend", 40.0)] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let frames = try? JXL.decodeFrames(from: jxl)
            else {
                check(false, "\(name) composited decode")
                continue
            }
            check(frames.count == 4, "\(name) has 4 frames")
            var worst = 999.0
            var alphaOK = true
            for (f, frame) in frames.enumerated() {
                guard let rgba = try? Data(
                    contentsOf: dir.appendingPathComponent("\(name)_\(f).rgba"))
                else {
                    check(false, "\(name) frame \(f) oracle present")
                    continue
                }
                let img = frame.image
                let n = img.width * img.height
                guard rgba.count == n * 4, img.planes.count >= 4 else {
                    check(false, "\(name) frame \(f) shape")
                    continue
                }
                var se = 0.0
                for i in 0..<n {
                    for c in 0..<3 {
                        let d = Double(Int(rgba[i * 4 + c]) - Int(img.planes[c][i]))
                        se += d * d
                    }
                    if abs(Int(rgba[i * 4 + 3]) - Int(img.planes[3][i])) > 1 { alphaOK = false }
                }
                let mse = se / Double(n * 3)
                worst = min(worst, mse == 0 ? 999 : 10 * log10(255.0 * 255.0 / mse))
            }
            check(worst > minPSNR, "\(name) frames match djxl (worst \(Int(worst)) dB)")
            check(alphaOK, "\(name) composited alpha within 1")
        }
    }

    // MARK: - HDR output (PQ/HLG transfers, 16-bit + float formats)

    /// `192x128_pq.jxl` (BT.2020 + SMPTE 2084 at 1000 nits) and
    /// `192x128_hlg.jxl` (BT.2020 + HLG) must match djxl's 16-bit output
    /// (`--bits_per_sample=16` PPMs). PQ content exceeds the mastering peak,
    /// exercising the extended transfer domain; HLG exercises the inverse
    /// OOTF. The float32 format must agree exactly with the 16-bit format.
    static func hdrOutput() {
        let dir = fixturesDir()
        for name in ["192x128_pq", "192x128_hlg"] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img16 = try? JXL.decodeImage(from: jxl, format: .uint16),
                let imgF = try? JXL.decodeImage(from: jxl, format: .float32)
            else {
                check(false, "\(name) decodes at 16-bit + float")
                continue
            }
            check(img16.bitsPerSample == 16 && !img16.isFloat, "\(name) 16-bit shape")
            check(imgF.bitsPerSample == 32 && imgF.isFloat, "\(name) float shape")
            // Parse the 16-bit P6 (big-endian samples after 3 newlines).
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
            let n = img16.width * img16.height
            guard ref.count == n * 6 else {
                check(false, "\(name) oracle size")
                continue
            }
            var se = 0.0
            var floatAgrees = true
            for i in 0..<n {
                for c in 0..<3 {
                    let refVal = Int(ref[(i * 3 + c) * 2]) << 8 | Int(ref[(i * 3 + c) * 2 + 1])
                    let got = Int(img16.planes[c][i])
                    let d = Double(refVal - got)
                    se += d * d
                    let f = Float(
                        bitPattern: UInt32(bitPattern: imgF.planes[c][i]))
                    if abs(Int((f * 65535).rounded()) - got) > 0 { floatAgrees = false }
                }
            }
            let mse = se / Double(n * 3)
            let psnr = mse == 0 ? 999 : 10 * log10(65535.0 * 65535.0 / mse)
            check(psnr > 50, "\(name) 16-bit matches djxl (PSNR \(Int(psnr)) dB)")
            check(floatAgrees, "\(name) float32 agrees with 16-bit")
        }
    }

    // MARK: - jbrd (JPEG reconstruction metadata)

    /// `256x192_jbrd.jxl` is a cjxl --lossless_jpeg=1 transcode of
    /// `256x192_jbrd.jpg` (sips, quality 85). The jbrd bundle + Brotli tail
    /// must parse with the structure of that JPEG; byte-exact reconstruction
    /// lands with the JPEG writer.
    static func jbrdParse() {
        let dir = fixturesDir()
        guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("256x192_jbrd.jxl")),
            let parsed = try? JXLContainer.parse([UInt8](jxl)),
            let box = parsed.boxes.first(where: { $0.type == "jbrd" })
        else {
            check(false, "jbrd fixture has a jbrd box")
            return
        }
        do {
            let d = try parseJPEGReconData(Array([UInt8](jxl)[box.payload]))
            check(d.markerOrder.last == 0xD9, "jbrd marker order ends at EOI")
            check(d.components.count == 3 && d.components.map(\.id) == [1, 2, 3],
                "jbrd YCbCr components")
            check(d.quant.count == 2 && d.huffmanCodes.count == 4, "jbrd tables")
            check(d.scans.count == 1 && d.scans[0].ss == 0 && d.scans[0].se == 63,
                "jbrd sequential scan")
            check(d.restartInterval > 0, "jbrd restart interval")
        } catch {
            check(false, "jbrd parses (\(error))")
        }
        // Full reconstruction must reproduce the source JPEG byte-for-byte.
        if let original = try? Data(contentsOf: dir.appendingPathComponent("256x192_jbrd.jpg")),
            let recon = try? JXL.reconstructJPEG(from: jxl) {
            check(recon == original, "jbrd reconstruction byte-exact vs source JPEG")
        } else {
            check(false, "jbrd reconstruction runs")
        }
    }

    // MARK: - Animation (multi-frame)

    /// `96x64_anim.jxl` (lossy) and `96x64_anim_lossless.jxl` are 4-frame
    /// animations (APNG via cjxl, 100 ticks/frame at 1000 ticks/s, full-frame
    /// replace). Every frame must match djxl's APNG output — bit-exact for the
    /// lossless file — and durations/tick rate must come through.
    static func animation() {
        let dir = fixturesDir()
        for (name, exact) in [("96x64_anim", false), ("96x64_animll", true)] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let info = try? JXL.readInfo(from: jxl),
                let frames = try? JXL.decodeFrames(from: jxl)
            else {
                check(false, "\(name) decodes")
                continue
            }
            check(info.hasAnimation && info.animation?.tpsNumerator == 1000,
                "\(name) animation header (1000 ticks/s)")
            check(frames.count == 4, "\(name) has 4 frames")
            check(frames.allSatisfy { $0.durationTicks == 100 }, "\(name) frame durations")
            check(frames.last?.isLast == true, "\(name) last frame flagged")
            for (i, frame) in frames.enumerated() {
                guard let refPPM = try? Data(
                    contentsOf: dir.appendingPathComponent("\(name)_\(i).ppm"))
                else {
                    check(false, "\(name) frame \(i) oracle present")
                    continue
                }
                let img = frame.image
                var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
                for c in 0..<3 {
                    for j in 0..<(img.width * img.height) {
                        rgb[j * 3 + c] = UInt8(clamping: img.planes[c][j])
                    }
                }
                let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
                if exact {
                    check(psnr == 999, "\(name) frame \(i) byte-exact vs djxl")
                } else {
                    check(psnr > 50, "\(name) frame \(i) matches djxl (PSNR \(Int(psnr)) dB)")
                }
            }
        }
    }

    // MARK: - Squeeze (responsive / lossy modular)

    /// `256x192_squeeze.jxl` and `2100x32_squeeze_dc.jxl` (cjxl --responsive=1,
    /// lossless) must be byte-exact vs djxl — the wide one has squeeze channels
    /// larger than group_dim at shift >= 3, exercising the ModularDC group
    /// streams. `256x192_modular_lossy.jxl` (cjxl -m 1 -d 1.0) is Modular-XYB:
    /// squeeze + DC-quant scaling through the XYB output path, PSNR-gated.
    static func squeeze() {
        let dir = fixturesDir()
        for name in ["256x192_squeeze", "2100x32_squeeze_dc"] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img = try? JXL.decodeImage(from: jxl), img.planes.count == 3
            else {
                check(false, "\(name) fixture decodes")
                continue
            }
            var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
            for c in 0..<3 {
                for i in 0..<(img.width * img.height) {
                    rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
                }
            }
            let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
            check(psnr == 999, "\(name) byte-exact vs djxl")
        }
        guard
            let jxl = try? Data(
                contentsOf: dir.appendingPathComponent("256x192_modular_lossy.jxl")),
            let refPPM = try? Data(
                contentsOf: dir.appendingPathComponent("256x192_modular_lossy.ppm")),
            let img = try? JXL.decodeImage(from: jxl), img.planes.count == 3
        else {
            check(false, "modular lossy fixture decodes")
            return
        }
        var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
        for c in 0..<3 {
            for i in 0..<(img.width * img.height) {
                rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
            }
        }
        let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
        check(psnr > 50, "modular lossy (XYB squeeze) matches djxl (PSNR \(Int(psnr)) dB)")
    }

    // MARK: - Upsampling (2x/4x/8x)

    /// `256x192_ups{2,4,8}.jxl` (cjxl --resampling=N) encode at reduced size;
    /// the decoder applies the non-separable 5x5-kernel upsampler after the
    /// filters. Output dimensions must match the image header and djxl.
    static func upsampling() {
        let dir = fixturesDir()
        for name in ["256x192_ups2", "256x192_ups4", "256x192_ups8"] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img = try? JXL.decodeImage(from: jxl)
            else {
                check(false, "\(name) fixture decodes")
                continue
            }
            check(img.width == 256 && img.height == 192, "\(name) upsampled dimensions")
            var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
            for c in 0..<3 {
                for i in 0..<(img.width * img.height) {
                    rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
                }
            }
            let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
            check(psnr > 50, "\(name) matches djxl (PSNR \(Int(psnr)) dB)")
        }
    }

    // MARK: - Splines + noise synthesis

    /// `96x64_spline.jxl` (jxl_from_tree: Modular-XYB base + one 4-point
    /// spline with varying color/sigma DCTs) exercises the spline decode,
    /// Catmull-Rom resampling, and Gaussian drawing; `96x64_noise_modular.jxl`
    /// (jxl_from_tree Noise directive) and `96x64_noise_vardct.jxl` (cjxl
    /// --photon_noise_iso=3200, VarDCT) exercise the seeded XorShift128+
    /// noise planes, the 5x5 convolution, and the LUT-modulated application.
    /// Oracles are djxl PPM output; noise is random but deterministically
    /// seeded, so parity is at normal lossy-oracle levels.
    static func splinesAndNoise() {
        let dir = fixturesDir()
        for name in ["96x64_spline", "96x64_noise_modular", "96x64_noise_vardct"] {
            guard let jxl = try? Data(contentsOf: dir.appendingPathComponent("\(name).jxl")),
                let refPPM = try? Data(contentsOf: dir.appendingPathComponent("\(name).ppm")),
                let img = try? JXL.decodeImage(from: jxl)
            else {
                check(false, "\(name) fixture decodes")
                continue
            }
            check(img.width == 96 && img.height == 64, "\(name) dimensions")
            var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
            for c in 0..<3 {
                for i in 0..<(img.width * img.height) {
                    rgb[i * 3 + c] = UInt8(clamping: img.planes[c][i])
                }
            }
            let psnr = ppmPSNR(refPPM, rgb, img.width, img.height)
            check(psnr > 50, "\(name) matches djxl (PSNR \(Int(psnr)) dB)")
        }
    }

    // MARK: - VarDCT extra channels (alpha)

    /// `160x120_alpha_lossy.jxl` (cjxl -d 1.0 on an RGBA PNG) is a VarDCT
    /// frame whose alpha rides the modular sub-streams (global + per-group).
    /// Color must match djxl's PAM output at oracle precision and the alpha
    /// plane byte-exactly.
    static func vardctAlpha() {
        let dir = fixturesDir()
        guard
            let jxl = try? Data(contentsOf: dir.appendingPathComponent("160x120_alpha_lossy.jxl")),
            let pam = try? Data(contentsOf: dir.appendingPathComponent("160x120_alpha_lossy.pam"))
        else {
            check(false, "vardct alpha fixture present")
            return
        }
        guard let img = try? JXL.decodeImage(from: jxl), img.extraChannels == 1,
            img.planes.count == 4
        else {
            check(false, "vardct alpha decodes with an extra channel")
            return
        }
        // Parse the PAM header (P7 ... ENDHDR\n, then RGBA interleaved).
        guard let headerEnd = pam.range(of: Data("ENDHDR\n".utf8)) else {
            check(false, "vardct alpha oracle header")
            return
        }
        let pixels = [UInt8](pam[headerEnd.upperBound...])
        let n = img.width * img.height
        check(pixels.count == n * 4, "vardct alpha oracle size")
        guard pixels.count == n * 4 else { return }
        var se = 0.0
        var alphaExact = true
        for i in 0..<n {
            for c in 0..<3 {
                let d = Double(Int(pixels[i * 4 + c]) - Int(img.planes[c][i]))
                se += d * d
            }
            if Int32(pixels[i * 4 + 3]) != img.planes[3][i] { alphaExact = false }
        }
        let mse = se / Double(n * 3)
        let psnr = mse == 0 ? 999 : 10 * log10(255.0 * 255.0 / mse)
        check(psnr > 50, "vardct alpha color matches djxl (PSNR \(Int(psnr)) dB)")
        check(alphaExact, "vardct alpha plane byte-exact vs djxl")
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
    final class TestBitWriter {
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
                let w = TestBitWriter()
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
            let w = TestBitWriter()
            for sym in sequence { w.write(UInt64(codes[sym].key), codes[sym].len) }
            let reader = w.reader
            var allOK = true
            for sym in sequence where Int(pc.readSymbol(reader)) != sym { allOK = false }
            check(allOK, "prefix round-trip for lengths \(lengths)")
        }

        // Simple prefix code: 2 explicit symbols, decode a known bit pattern.
        let sw = TestBitWriter()
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

    static func writeVarLenUint8(_ w: TestBitWriter, _ v: Int) {
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
        let hw = TestBitWriter()
        hw.write(1, 1)  // simple
        hw.write(0, 1)  // num_symbols - 1 = 0
        writeVarLenUint8(hw, 5)  // symbol = 5
        if let counts = readHistogram(precisionBits: 12, reader: hw.reader) {
            eq(counts.count, 6, "simple histogram size")
            eq(counts[5], 4096, "simple histogram count")
        } else {
            check(false, "simple histogram failed to parse")
        }

        let fw = TestBitWriter()
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
                // The header + TOC + all section bytes must exactly fill the
                // codestream — for the last frame only (animations have more
                // frames after the presented one).
                if info.isLast {
                    eq(
                        info.dataStartByte + info.totalSectionBytes, info.codestreamLength,
                        "\(f) TOC sum invariant")
                }
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
                    coversPayload && (!info.isLast || nextByte == info.codestreamLength),
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
