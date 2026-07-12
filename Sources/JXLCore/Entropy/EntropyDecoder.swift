// EntropyDecoder.swift
//
// The entropy-code header assembler. `decodeHistograms` reads the full header
// that precedes a block of entropy-coded tokens (LZ77 params, context map,
// prefix-vs-ANS flag, alphabet size, hybrid-uint configs, and the per-cluster
// codes) and returns an `ANSCode` + context map ready to drive an
// `ANSSymbolReader`. Mirrors libjxl `DecodeHistograms` / `DecodeContextMap`
// (dec_ans.cc, dec_context_map.cc).

import Foundation

/// Inverse move-to-front transform (inverse_mtf-inl.h).
func inverseMoveToFront(_ v: inout [UInt8]) {
    var mtf = (0..<256).map { UInt8($0) }
    for i in 0..<v.count {
        let index = Int(v[i])
        let value = mtf[index]
        v[i] = value
        var j = index
        while j > 0 {
            mtf[j] = mtf[j - 1]
            j -= 1
        }
        mtf[0] = value
    }
}

/// Reads a context map of `size` entries; returns it plus the histogram count.
func decodeContextMap(_ br: BitReader, size: Int) -> (contextMap: [UInt8], numHistograms: Int)? {
    var contextMap = [UInt8](repeating: 0, count: size)
    let isSimple = br.read(1) == 1
    if isSimple {
        let bitsPerEntry = Int(br.read(2))
        if bitsPerEntry != 0 {
            for i in 0..<size { contextMap[i] = UInt8(truncatingIfNeeded: br.read(bitsPerEntry)) }
        }
    } else {
        let useMTF = br.read(1) == 1
        // LZ77 is disallowed for tiny maps to avoid unbounded recursion.
        guard let (code, sinkCtxMap) = decodeHistograms(br, numContexts: 1, disallowLZ77: size <= 2)
        else { return nil }
        let reader = ANSSymbolReader(code: code, reader: br)
        var maxsym: UInt32 = 0
        for i in 0..<size {
            let sym = reader.readHybridUint(0, br, contextMap: sinkCtxMap)
            maxsym = max(maxsym, sym)
            contextMap[i] = UInt8(truncatingIfNeeded: sym)
        }
        if maxsym >= 256 { return nil }
        if !reader.checkANSFinalState() { return nil }
        if useMTF { inverseMoveToFront(&contextMap) }
    }

    let numHistograms = Int(contextMap.max() ?? 0) + 1
    // Verify completeness: every histogram index in [0, numHistograms) is used.
    var seen = [Bool](repeating: false, count: numHistograms)
    for h in contextMap {
        if Int(h) >= numHistograms { return nil }
        seen[Int(h)] = true
    }
    if seen.contains(false) { return nil }
    return (contextMap, numHistograms)
}

/// Reads the per-cluster codes (prefix tables or ANS alias tables).
private func decodeANSCodes(_ code: inout ANSCode, numHistograms: Int, maxAlphabetSize: Int, br: BitReader)
    -> Bool {
    if code.usePrefixCode {
        var alphabetSizes = [Int]()
        for _ in 0..<numHistograms {
            let a = decodeVarLenUint16(br) + 1
            if a > maxAlphabetSize { return false }
            alphabetSizes.append(a)
        }
        for c in 0..<numHistograms {
            if alphabetSizes[c] > 1 {
                guard let pc = PrefixCode(reader: br, alphabetSize: alphabetSizes[c]) else { return false }
                code.huffmanData.append(pc)
            } else {
                // 0-bit code: a table of zero-length entries (always symbol 0).
                code.huffmanData.append(
                    PrefixCode(table: [HuffmanCode](repeating: HuffmanCode(bits: 0, value: 0), count: 1 << kHuffmanTableBits)))
            }
        }
    } else {
        let tableSize = 1 << code.logAlphaSize
        code.aliasTables = [AliasEntry](repeating: AliasEntry(), count: numHistograms * tableSize)
        for c in 0..<numHistograms {
            guard var counts = readHistogram(precisionBits: ansLogTabSize, reader: br) else { return false }
            if counts.count > maxAlphabetSize { return false }
            while let last = counts.last, last == 0 { counts.removeLast() }
            initAliasTable(distribution: counts, logAlphaSize: code.logAlphaSize, into: &code.aliasTables, base: c * tableSize)
        }
    }
    return true
}

/// Reads a full entropy-code header (mirrors `DecodeHistograms`). `numContexts`
/// is the number of raw contexts the caller will use.
func decodeHistograms(_ br: BitReader, numContexts numContexts0: Int, disallowLZ77: Bool)
    -> (code: ANSCode, contextMap: [UInt8])? {
    var code = ANSCode()
    var numContexts = numContexts0

    // LZ77Params bundle.
    code.lz77.enabled = br.readBool()
    if code.lz77.enabled {
        code.lz77.minSymbol = br.readU32(.value(224), .value(512), .value(4096), .bits(15, offset: 8))
        code.lz77.minLength = br.readU32(.value(3), .value(4), .bits(2, offset: 5), .bits(8, offset: 9))
        guard let lengthConfig = br.readHybridUintConfig(logAlphaSize: 8) else { return nil }
        code.lz77.lengthUintConfig = lengthConfig
        numContexts += 1
    }
    if code.lz77.enabled && disallowLZ77 { return nil }

    var numHistograms = 1
    var contextMap = [UInt8](repeating: 0, count: numContexts)
    if numContexts > 1 {
        guard let (cm, nh) = decodeContextMap(br, size: numContexts) else { return nil }
        contextMap = cm
        numHistograms = nh
    }
    code.lz77.nonserializedDistanceContext = Int(contextMap.last ?? 0)

    code.usePrefixCode = br.read(1) == 1
    if code.usePrefixCode {
        code.logAlphaSize = kPrefixMaxBits  // 15
    } else {
        code.logAlphaSize = Int(br.read(2)) + 5
    }

    var uintConfigs: [HybridUintConfig] = []
    for _ in 0..<numHistograms {
        guard let config = br.readHybridUintConfig(logAlphaSize: code.logAlphaSize) else { return nil }
        uintConfigs.append(config)
    }
    code.uintConfig = uintConfigs

    let maxAlphabetSize = 1 << code.logAlphaSize
    guard decodeANSCodes(&code, numHistograms: numHistograms, maxAlphabetSize: maxAlphabetSize, br: br)
    else { return nil }

    return (code, contextMap)
}
