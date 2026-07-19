// FuzzRunner.swift
//
// Deterministic mutation fuzzer for the untrusted-input decode paths. Takes
// every fixture, applies seeded byte flips and/or truncations, and runs the
// public entry points (`readInfo`, `readFrameInfo`, `decodeImage` under a small
// `JXLDecodeLimits`). Every outcome is acceptable except a process trap
// (fatalError / precondition / array index / integer overflow) or a runaway
// allocation — thrown `JXLError`s are the correct response to garbage.
//
// Because a trap cannot be caught, the runner writes "<fixture> <seed>" to a
// status file before each attempt; after a crash the file names the guilty
// case. Reproduce with:  fuzz <fixturesDir> --repro <fixture> <seed>
//
// Compiled together with JXLCore by Scripts/fuzz.sh (single module).

import Foundation

/// SplitMix64: tiny, seedable, and stable across runs/platforms.
struct SplitMix64 {
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

func mutate(_ original: [UInt8], seed: UInt64) -> [UInt8] {
    var rng = SplitMix64(seed: seed)
    var bytes = original
    // 1 in 4 cases truncate; otherwise (or additionally) flip 1-16 bytes.
    let mode = rng.below(4)
    if mode == 0, bytes.count > 2 {
        bytes = Array(bytes[0..<(2 + rng.below(bytes.count - 2))])
    }
    if mode != 0 || rng.below(2) == 0 {
        let flips = 1 + rng.below(16)
        for _ in 0..<flips where !bytes.isEmpty {
            let i = rng.below(bytes.count)
            bytes[i] = mode == 1 ? UInt8(rng.below(256)) : bytes[i] ^ UInt8(1 << rng.below(8))
        }
    }
    return bytes
}

/// When true, announces each entry point on stderr so a trap names its caller.
var traceCalls = false

func exercise(_ bytes: [UInt8]) {
    // Small allocation cap: a fuzzer mutation that inflates claimed dimensions
    // should hit `limitExceeded`, not exhaust memory.
    let limits = JXLDecodeLimits(maxTotalSamples: 1 << 24)
    func note(_ s: String) {
        if traceCalls { FileHandle.standardError.write(Data("\(s)\n".utf8)) }
    }
    note("readInfo")
    _ = try? JXL.readInfo(from: bytes)
    note("readFrameInfo")
    _ = try? JXL.readFrameInfo(from: bytes)
    note("readVarDCTInfo")
    _ = try? JXL.readVarDCTInfo(from: bytes)
    note("decodeImage")
    _ = try? JXL.decodeImage(from: bytes, limits: limits)
    note("reconstructJPEG")
    _ = try? JXL.reconstructJPEG(from: bytes, limits: limits)
}

@main
struct FuzzRunner {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("""
                usage: fuzz <fixturesDir> [iterationsPerFixture] [--status <file>]
                       fuzz <fixturesDir> --repro <fixture.jxl> <seed>

                """.utf8))
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)

        if args.count >= 5, args[2] == "--repro" {
            let name = args[3]
            let seed = UInt64(args[4])!
            let data = try! Data(contentsOf: dir.appendingPathComponent(name))
            print("repro \(name) seed \(seed) ...")
            traceCalls = true
            exercise(mutate([UInt8](data), seed: seed))
            print("no crash")
            return
        }

        let iterations = args.count >= 3 ? Int(args[2]) ?? 300 : 300
        var statusPath = "/tmp/jxl-fuzz-status"
        if let i = args.firstIndex(of: "--status"), i + 1 < args.count {
            statusPath = args[i + 1]
        }

        let names = (try! FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { $0.hasSuffix(".jxl") }.sorted()
        var total = 0
        for name in names {
            let data = [UInt8](try! Data(contentsOf: dir.appendingPathComponent(name)))
            for i in 0..<iterations {
                let seed = UInt64(i)
                try? "\(name) \(seed)\n".write(
                    toFile: statusPath, atomically: false, encoding: .utf8)
                exercise(mutate(data, seed: seed))
                total += 1
            }
            print("  fuzzed \(name): \(iterations) mutations")
        }
        try? FileManager.default.removeItem(atPath: statusPath)
        print("fuzz clean: \(total) mutated decodes, no crashes")
    }
}
