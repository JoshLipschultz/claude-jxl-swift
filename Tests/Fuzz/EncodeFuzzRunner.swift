// EncodeFuzzRunner.swift
//
// Deterministic encoder-input fuzzer (docs/encoder-design.md correctness
// discipline): generates seeded random images across the encoder's whole
// input space — edge dimensions (1-pixel sides, group and DC-group boundary
// crossings), every depth (1..16-bit integer + binary32 float), gray/RGB,
// alpha extra channels, adversarial content patterns — encodes at every
// (effort, backend) combination, decodes with our own decoder, and requires
// bit-exact planes. Any mismatch or process trap is a bug; the status file
// names the failing seed. Reproduce with:  fuzz-encode --repro <seed>
//
// (djxl spec-validation of the same streams lives in the per-milestone
// oracle sweeps; this runner is the always-on, no-oracle-needed net.)
//
// Compiled together with JXLCore by Scripts/fuzz-encode.sh (single module).

import Foundation

struct EncSplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

func makeRandomImage(seed: UInt64) -> JXLDecodedImage {
    var rng = EncSplitMix64(seed: seed)

    // Dimensions biased toward the boundaries where bugs live.
    let interesting = [1, 2, 3, 7, 8, 9, 31, 255, 256, 257, 511, 513]
    func dim() -> Int {
        switch rng.below(4) {
        case 0: return interesting[rng.below(interesting.count)]
        case 1: return 1 + rng.below(40)
        default: return 16 + rng.below(304)
        }
    }
    var w = dim()
    var h = dim()
    // Occasionally cross a DC-group boundary in one (cheap, thin) dimension.
    if rng.below(24) == 0 {
        if rng.below(2) == 0 { w = 2049 } else { h = 2049 }
    }
    if w * h > 1 << 21 { h = max(1, (1 << 21) / w) }

    let isFloat = rng.below(6) == 0
    let bits = isFloat ? 32 : 1 + rng.below(16)
    let colors = rng.below(2) == 0 ? 3 : 1
    let extras = rng.below(3) == 0 ? 1 + rng.below(2) : 0
    let maxV = isFloat ? 0 : Int64((1 << bits) - 1)

    let n = w * h
    var planes: [[Int32]] = []
    for c in 0..<(colors + extras) {
        var p = [Int32](repeating: 0, count: n)
        let mode = rng.below(8)
        // A shared scale exercises the leaf-multiplier path.
        let scale = Int64(1 + rng.below(300))
        var fewColors: [Int32] = []
        if mode == 5 {
            for _ in 0..<(2 + rng.below(40)) {
                fewColors.append(
                    isFloat
                        ? Int32(truncatingIfNeeded: rng.next())
                        : Int32(Int64(rng.below(Int(maxV) + 1))))
            }
        }
        for i in 0..<n {
            let x = i % w
            let y = i / w
            var v: Int64
            switch mode {
            case 0: v = 0  // constant zero
            case 1: v = maxV / 2  // constant mid
            case 2: v = Int64((x + y * 3 + c * 37)) * scale  // scaled ramp
            case 3: v = Int64(rng.next() & 0xFFFF)  // noise
            case 4: v = (x / 8 + y / 8) % 2 == 0 ? 0 : maxV  // blocks
            case 5: v = Int64(fewColors[rng.below(fewColors.count)])  // palette-ish
            case 6: v = Int64(x ^ y) * scale  // xor texture
            default: v = (i % 2 == 0) ? 0 : maxV  // alternating extremes
            }
            if isFloat {
                // Any bit pattern round-trips (identity path) — including
                // NaN payloads, infinities, subnormals.
                p[i] = mode == 3 ? Int32(truncatingIfNeeded: rng.next()) : Int32(truncatingIfNeeded: v)
            } else {
                p[i] = Int32(((v % (maxV + 1)) + (maxV + 1)) % (maxV + 1))
            }
        }
        planes.append(p)
    }
    return JXLDecodedImage(
        width: w, height: h, colorChannels: colors, extraChannels: extras,
        bitsPerSample: bits, isFloat: isFloat, planes: planes)
}

func runCase(seed: UInt64) -> String? {
    let img = makeRandomImage(seed: seed)
    var rng = EncSplitMix64(seed: seed ^ 0xDEAD_BEEF)
    let backend: ModularEncoder.EntropyBackend = rng.below(2) == 0 ? .ans : .prefix
    let effort = rng.below(3) == 0 ? 1 : 2
    // Squeeze (responsive) on a third of integer cases (rejected for float).
    let squeeze = !img.isFloat && rng.below(3) == 0
    let what =
        "seed \(seed): \(img.width)x\(img.height) \(img.colorChannels)ch+\(img.extraChannels)ec "
        + "\(img.isFloat ? "f32" : "\(img.bitsPerSample)b") \(backend) e\(effort)"
        + "\(squeeze ? " sq" : "")"
    do {
        let bytes = try ModularEncoder.encodeLossless(
            img, backend: backend, effort: effort, squeeze: squeeze)
        let dec = try JXL.decodeImage(from: bytes)
        guard dec.width == img.width, dec.height == img.height,
            dec.colorChannels == img.colorChannels, dec.extraChannels == img.extraChannels
        else { return "\(what): geometry mismatch" }
        for c in 0..<img.planes.count where dec.planes[c] != img.planes[c] {
            return "\(what): plane \(c) mismatch"
        }
        return nil
    } catch let e as JXLEncodeError {
        // Clean rejections are fine only for inputs we document as
        // unsupported; everything generated here must encode.
        return "\(what): unexpected rejection: \(e)"
    } catch {
        return "\(what): decode threw: \(error)"
    }
}

// ENCODE_FUZZ_NO_MAIN lets debugging harnesses compile this file for its
// generator without a second @main.
#if !ENCODE_FUZZ_NO_MAIN
@main
struct EncodeFuzzMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--repro", let seed = UInt64(args[2]) {
            if let failure = runCase(seed: seed) {
                FileHandle.standardError.write(Data("FAIL \(failure)\n".utf8))
                exit(1)
            }
            print("seed \(seed): ok")
            return
        }
        let iterations = args.count >= 2 ? Int(args[1]) ?? 400 : 400
        let statusPath = "/tmp/jxl-encode-fuzz-status"
        for i in 0..<iterations {
            let seed = UInt64(1000 + i)
            try? "\(seed)".write(toFile: statusPath, atomically: true, encoding: .utf8)
            if let failure = runCase(seed: seed) {
                FileHandle.standardError.write(Data("FAIL \(failure)\n".utf8))
                exit(1)
            }
        }
        try? FileManager.default.removeItem(atPath: statusPath)
        print("encode-fuzz clean: \(iterations) random images, all round-trips bit-exact")
    }
}
#endif
