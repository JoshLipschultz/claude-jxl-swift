// VarDCTEncoder.swift
//
// E5a: the baseline lossy VarDCT encoder — valid, not competitive. One
// regular XYB VarDCT frame, all-DCT8 strategies, a uniform quant field,
// default dequant tables / block context map / color correlation, loop
// filters off, single pass, 4:4:4, no extra channels.
//
// The load-bearing rule: every field written here is the exact dual of a
// decoder reader in this repo —
//   * frame shape/TOC: FrameDecoder.sectionRole / parseFrameSlot,
//   * LfGlobal: readVarDCTDCGlobal (VarDCTInfo.swift),
//   * DC groups: decodeVarDCTDC + decodeAcMetadataGroup (DCImage.swift /
//     ACMetadata.swift), via the modular machinery's own tokenizer,
//   * HfGlobal: decodeVarDCTACGlobal (CoeffOrder.swift), histograms through
//     `decodeHistograms`,
//   * AC groups: decodeACGroupPass (PassGroup.swift) — the per-block context
//     chain (block context, non-zero prediction, zero-density contexts) is
//     mirrored computation-for-computation below,
//   * quantization semantics: DequantDC / reconstructXYB (Reconstruct.swift)
//     define the decoder-side multipliers this encoder divides by, including
//     the default chroma-from-luma (B is coded minus the reconstructed Y
//     coefficient, for AC and DC alike) and AdjustQuantBias,
//   * color: ForwardXYB.swift inverts ConvertState.linear + the sRGB EOTF.
//
// Deliberate E5a shape choices:
//   * flags = 128 (kSkipAdaptiveDCSmoothing) so decoded DC equals what we
//     quantized (both this decoder and djxl honor it),
//   * a single-leaf gradient MA tree codes the DC image + AC metadata,
//   * quality (1…100) maps to one uniform step scale via globalScale with a
//     fixed quant field; see `quantParams`.

import Foundation

// MARK: - Context tables mirrored from the decoder
// (private in PassGroup.swift / VarDCTInfo.swift; duplicated here as the
// encoder-side dual — the suite's round-trips pin the two against each other.)

private let kNumBlockCtxClusters = 15  // default block context map clusters
private let kNonZeroBuckets = 37
private let kZeroDensityContextCount = 458
private let kNumACContexts = kNumBlockCtxClusters * (kNonZeroBuckets + kZeroDensityContextCount)

/// Mirror of kDefaultBlockContextMap (VarDCTInfo.swift).
private let kEncDefaultBlockContextMap: [UInt8] = [
    0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
]

/// Mirrors of kCoeffFreqContext / kCoeffNumNonzeroContext (PassGroup.swift).
private let kEncCoeffFreqContext: [Int] = [
    0xBAD, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
]
private let kEncCoeffNumNonzeroContext: [Int] = [
    0xBAD, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123,
    152, 152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180, 180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
]

/// Mirror of blockCtxContext (PassGroup.swift) for the DEFAULT block context
/// map (no DC/QF thresholds, numDCContexts == 1): channel + coeff-order
/// bucket select the map entry.
@inline(__always)
private func encBlockContext(channel c: Int, order ord: Int) -> Int {
    var idx = c < 2 ? c ^ 1 : 2
    idx = idx * kNumCoeffOrders + ord
    // * (qfThresholds.count + 1 == 1) + qfIdx(0); * numDCContexts(1) + dcIdx(0)
    return Int(kEncDefaultBlockContextMap[idx])
}

/// Mirror of blockCtxNonZeroContext (PassGroup.swift).
@inline(__always)
private func encNonZeroContext(predicted: Int, blockCtx: Int) -> Int {
    var nz = predicted
    if nz >= 64 { nz = 64 }
    let ctx: Int = nz < 8 ? nz : 4 + nz / 2
    return ctx * kNumBlockCtxClusters + blockCtx
}

/// Mirror of blockCtxZeroDensityOffset (PassGroup.swift).
@inline(__always)
private func encZeroDensityOffset(blockCtx: Int) -> Int {
    kNumBlockCtxClusters * kNonZeroBuckets + kZeroDensityContextCount * blockCtx
}

/// Mirror of zeroDensityContext (PassGroup.swift), DCT8 shape (1 covered
/// block, log2Covered = 0).
@inline(__always)
private func encZeroDensityContext(nonzerosLeft nz: Int, k: Int, prev: Int) -> Int {
    (kEncCoeffNumNonzeroContext[nz] + kEncCoeffFreqContext[k]) * 2 + prev
}

/// Mirror of predictFromTopAndLeft (PassGroup.swift).
@inline(__always)
private func encPredictNonZeros(_ nz: [Int32], w: Int, bx: Int, by: Int) -> Int32 {
    let hasTop = by > 0
    if bx == 0 { return hasTop ? nz[(by - 1) * w + bx] : 32 }
    let left = nz[by * w + (bx - 1)]
    if !hasTop { return left }
    return (nz[(by - 1) * w + bx] + left + 1) / 2
}

/// Mirror of adjustQuantBias (Reconstruct.swift), default quant biases (no
/// custom OpsinInverseMatrix is ever written by this encoder).
private let kEncQuantBiasX: Float = 1.0 - 0.05465007330715401
private let kEncQuantBiasY: Float = 1.0 - 0.07005449891748593
private let kEncQuantBiasB: Float = 1.0 - 0.049935103337343655
private let kEncQuantBiasNumerator: Float = 0.145

@inline(__always)
private func encAdjustQuantBias(_ q: Int32, _ bias: Float) -> Float {
    if q == 0 { return 0 }
    if q == 1 { return bias }
    if q == -1 { return -bias }
    let qf = Float(q)
    return qf - kEncQuantBiasNumerator / qf
}

// MARK: - AC entropy coder (local dual of decodeHistograms + ANSSymbolReader)
//
// The shared ANSEntropyEncoder clusters contexts by pairwise entropy merging,
// which is O(n²) memory / O(n³) time in the context count — fine for modular
// trees (dozens of contexts), unusable for the 7425 AC contexts. The AC
// header is plain `decodeHistograms`, so this local coder writes the same
// wire format with a FIXED context clustering (any surjective map is valid;
// the decoder reads whatever map we write).

/// Fixed AC context -> cluster map. Context layout (PassGroup.swift with
/// numHistograms == 1): [0, 555) non-zero-count contexts (bucket*15 +
/// blockCtx); [555, 7425) zero-density contexts (555 + 458*blockCtx + zd).
/// 8 clusters: Y/non-Y block contexts x {nonzeros, 3 zero-density bands}.
/// Every cluster index appears in the map by construction (decodeContextMap
/// requires surjectivity onto [0, max]).
private func acFixedClusterMap(numContexts: Int) -> [UInt8] {
    let nzEnd = kNumBlockCtxClusters * kNonZeroBuckets
    var map = [UInt8](repeating: 0, count: numContexts)
    for ctx in 0..<numContexts {
        if ctx < nzEnd {
            map[ctx] = (ctx % kNumBlockCtxClusters) == 0 ? 0 : 1
        } else {
            let rel = ctx - nzEnd
            let blockCtx = rel / kZeroDensityContextCount
            let zd = rel % kZeroDensityContextCount
            let half = zd >> 1  // nonzero bucket + frequency bucket
            let band = half < 31 ? 0 : (half < 93 ? 1 : 2)
            map[ctx] = UInt8(2 + (blockCtx == 0 ? 0 : 3) + band)
        }
    }
    return map
}

private struct ACEntropyCoder {
    let numContexts: Int
    let contextMap: [UInt8]
    let numClusters: Int
    let logAlphaSize: Int
    /// Per-cluster normalized (sum 4096) counts and inverted alias tables:
    /// `slots[cluster][symbol][offset]` = ANS slot (mirror of ANSWriter's
    /// private ANSClusterCode, built on the decoder's own initAliasTable /
    /// aliasLookup so encode inverts decode by construction).
    private let counts: [[Int32]]
    private let slots: [[[UInt16]]]

    init(numContexts: Int, streams: [[EncToken]]) {
        self.numContexts = numContexts
        var total = 0
        for s in streams { total += s.count }
        // Tiny images: a single cluster costs 0 map bits (all-zero simple map)
        // and one histogram; the 8-cluster map pays for itself only with
        // enough tokens.
        let map = total < 4096
            ? [UInt8](repeating: 0, count: numContexts)
            : acFixedClusterMap(numContexts: numContexts)
        contextMap = map
        let nc = Int(map.max()!) + 1
        numClusters = nc

        // Token histograms per cluster (hybrid-uint (4,2,0) tokens stay < 128).
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 128), count: nc)
        var maxToken = 0
        for s in streams {
            for t in s {
                precondition(Int(t.ctx) < numContexts, "AC context out of range")
                let (tok, _, _) = encUintConfig.encode(t.value)
                hist[Int(map[Int(t.ctx)])][Int(tok)] += 1
                if Int(tok) > maxToken { maxToken = Int(tok) }
            }
        }
        logAlphaSize = max(5, ceilLog2Nonzero(UInt32(maxToken + 1)))

        var cnts: [[Int32]] = []
        var slts: [[[UInt16]]] = []
        let logEntrySize = ansLogTabSize - logAlphaSize
        let entrySizeMinus1 = (1 << logEntrySize) - 1
        for c in 0..<nc {
            var h = hist[c]
            if h.reduce(0, +) == 0 { h = [1] }  // headers need a valid code
            var normalized = normalizeANSCounts(h)
            while let last = normalized.last, last == 0, normalized.count > 1 {
                normalized.removeLast()
            }
            var table = [AliasEntry](repeating: AliasEntry(), count: 1 << logAlphaSize)
            initAliasTable(
                distribution: normalized, logAlphaSize: logAlphaSize, into: &table, base: 0)
            var s = normalized.map { [UInt16](repeating: 0, count: Int($0)) }
            table.withUnsafeBufferPointer { tp in
                for v in 0..<ansTabSize {
                    let sym = aliasLookup(
                        tp.baseAddress!, base: 0, value: v, logEntrySize: logEntrySize,
                        entrySizeMinus1: entrySizeMinus1)
                    s[sym.value][sym.offset] = UInt16(v)
                }
            }
            cnts.append(normalized)
            slts.append(s)
        }
        counts = cnts
        slots = slts
    }

    /// Dual of `decodeHistograms` (ANS path, no LZ77): the header the decoder
    /// reads before the per-group AC token streams.
    func writeHeader(_ w: BitWriter) {
        w.writeBool(false)  // lz77 enabled
        // Context map, simple form (numContexts > 1 always for AC).
        w.writeBool(true)  // is_simple
        let bits = numClusters > 1 ? ceilLog2Nonzero(UInt32(numClusters)) : 0
        w.write(UInt64(bits), 2)
        if bits > 0 {
            for entry in contextMap { w.write(UInt64(entry), bits) }
        }
        w.writeBool(false)  // use_prefix_code = false: ANS
        w.write(UInt64(logAlphaSize - 5), 2)
        for _ in 0..<numClusters {
            // Hybrid-uint config (4,2,0) — same shape ANSEntropyEncoder writes.
            w.write(4, ceilLog2Nonzero(UInt32(logAlphaSize + 1)))
            w.write(2, 3)
            w.write(0, 2)
        }
        for c in counts { writeANSHistogram(w, counts: c) }
    }

    /// One section's tokens: reverse rANS pass for the final state + renorm
    /// schedule, then the forward serialization `ANSSymbolReader` consumes
    /// (32-bit state, then per value its renorm chunk and raw extra bits).
    /// Mirror of ANSEntropyEncoder.encodeStream over this coder's tables.
    func encodeStream(_ w: BitWriter, _ tokens: [EncToken]) {
        let n = tokens.count
        var symbols = [Int](repeating: 0, count: max(1, n))
        var cluster = [Int](repeating: 0, count: max(1, n))
        var exNBits = [UInt32](repeating: 0, count: max(1, n))
        var exBits = [UInt32](repeating: 0, count: max(1, n))
        var chunk = [UInt32](repeating: .max, count: max(1, n))
        for i in 0..<n {
            let t = tokens[i]
            let (tok, nbits, bits) = encUintConfig.encode(t.value)
            symbols[i] = Int(tok)
            cluster[i] = Int(contextMap[Int(t.ctx)])
            exNBits[i] = nbits
            exBits[i] = bits
        }
        var state: UInt32 = ansSignature << 16
        var i = n - 1
        while i >= 0 {
            let c = cluster[i]
            let sym = symbols[i]
            let f = UInt32(counts[c][sym])
            // 64-bit compare: f == 4096 (single-symbol code) would overflow
            // f << 20 in UInt32; the emit threshold is then 2^32 = never.
            if UInt64(state) >= UInt64(f) << 20 {
                chunk[i] = state & 0xFFFF
                state >>= 16
            }
            let slot = slots[c][sym][Int(state % f)]
            state = ((state / f) << UInt32(ansLogTabSize)) | UInt32(slot)
            i -= 1
        }
        w.write(UInt64(state), 32)
        for j in 0..<n {
            if chunk[j] != UInt32.max { w.write(UInt64(chunk[j]), 16) }
            if exNBits[j] > 0 { w.write(UInt64(exBits[j]), Int(exNBits[j])) }
        }
    }
}

// MARK: - Encoder

enum VarDCTEncoder {
    /// Quantization knobs derived from `quality` (1…100). One uniform step
    /// scale: the decoder's per-coefficient step is
    /// `dequantTable[c][k] * (65536/globalScale) / quantField`, so with the
    /// fixed quant field 32 the step scale is invGlobalScale/32 =
    /// 2048/globalScale. quality 90 (default) → ~0.8x the default table
    /// steps; each quality point is ~7% on the step (a log scale), which
    /// spans ~0.4x (q100) to ~330x (q1). DC uses quantDC = 64: DC steps of
    /// stepScale * {1/8192 (X), 1/1024 (Y), 1/512 (B)} — finer than the AC
    /// low-frequency steps, keeping block DC honest.
    struct QuantParams {
        let globalScale: UInt32
        let quantDC: UInt32
        let quantField: Int32
    }

    static func quantParams(quality: Int) -> QuantParams {
        let q = min(100, max(1, quality))
        let stepScale = 0.8 * pow(1.07, Double(90 - q))
        let globalScale = UInt32(min(73728, max(1, Int((2048.0 / stepScale).rounded()))))
        return QuantParams(globalScale: globalScale, quantDC: 64, quantField: 32)
    }

    /// Encodes integer RGB or grayscale planes as a lossy XYB VarDCT bare
    /// codestream. Grayscale is replicated into RGB before the color
    /// transform (the decoded image is 3-channel). Alpha/extra channels and
    /// float samples are E5a non-goals and rejected.
    static func encodeLossy(_ image: JXLDecodedImage, quality: Int = 90) throws -> [UInt8] {
        guard !image.isFloat else {
            throw JXLEncodeError(reason: "lossy encode supports integer samples only")
        }
        guard image.extraChannels == 0 else {
            throw JXLEncodeError(reason: "lossy encode does not support extra channels yet")
        }
        guard image.colorChannels == 1 || image.colorChannels == 3 else {
            throw JXLEncodeError(reason: "lossy encode supports 1 or 3 color channels")
        }
        guard image.bitsPerSample >= 1, image.bitsPerSample <= 16 else {
            throw JXLEncodeError(reason: "lossy encode supports 1-16 bit integer samples")
        }
        guard image.width >= 1, image.height >= 1 else {
            throw JXLEncodeError(reason: "empty image")
        }
        let planeSize = image.width * image.height
        guard image.planes.count == image.colorChannels,
            image.planes.allSatisfy({ $0.count == planeSize })
        else {
            throw JXLEncodeError(reason: "plane count/size mismatch")
        }
        let maxSample = Int32((1 << image.bitsPerSample) - 1)
        for p in image.planes {
            for v in p where v < 0 || v > maxSample {
                throw JXLEncodeError(
                    reason: "sample \(v) out of range for \(image.bitsPerSample)-bit")
            }
        }

        let params = quantParams(quality: quality)
        let w = image.width
        let h = image.height
        let bw = divCeil(w, 8)
        let bh = divCeil(h, 8)
        let pw = bw * 8
        let ph = bh * 8

        // ---- Forward color: sRGB integer samples -> linear -> XYB, padded to
        // whole blocks by edge replication.
        var planeX = [Float](repeating: 0, count: pw * ph)
        var planeY = planeX
        var planeB = planeX
        do {
            let opsin = ForwardOpsin()
            let maxVal = Double(maxSample)
            var lut = [Double](repeating: 0, count: Int(maxSample) + 1)
            for i in 0...Int(maxSample) { lut[i] = srgbToLinear(Double(i) / maxVal) }
            let gray = image.colorChannels == 1
            let pR = image.planes[0]
            let pG = gray ? image.planes[0] : image.planes[1]
            let pB = gray ? image.planes[0] : image.planes[2]
            for y in 0..<h {
                let src = y * w
                let dst = y * pw
                for x in 0..<w {
                    let r = lut[Int(pR[src + x])]
                    let g = lut[Int(pG[src + x])]
                    let b = lut[Int(pB[src + x])]
                    let v = opsin.xyb(r, g, b)
                    planeX[dst + x] = Float(v.x)
                    planeY[dst + x] = Float(v.y)
                    planeB[dst + x] = Float(v.b)
                }
                // Pad right edge.
                for x in w..<pw {
                    planeX[dst + x] = planeX[dst + w - 1]
                    planeY[dst + x] = planeY[dst + w - 1]
                    planeB[dst + x] = planeB[dst + w - 1]
                }
            }
            // Pad bottom edge.
            for y in h..<ph {
                let src = (h - 1) * pw
                let dst = y * pw
                for x in 0..<pw {
                    planeX[dst + x] = planeX[src + x]
                    planeY[dst + x] = planeY[src + x]
                    planeB[dst + x] = planeB[src + x]
                }
            }
        }

        var dim = FrameDimensions()
        dim.set(
            xsize: w, ysize: h, groupSizeShift: 1, maxHShift: 0, maxVShift: 0,
            modular: false, upsampling: 1)
        precondition(dim.xsizeBlocks == bw && dim.ysizeBlocks == bh)

        // ---- Quantizer multipliers, from the decoder's own math.
        let bctxDefault = VarDCTBlockContextMap(
            dcThresholds: [[], [], []], qfThresholds: [],
            contextMap: kEncDefaultBlockContextMap,
            numContexts: kNumBlockCtxClusters, numDCContexts: 1)
        let dcGlobalInfo = VarDCTDCGlobalInfo(
            dcQuantIsDefault: true, dcQuant: [],
            quantizer: VarDCTQuantizerInfo(
                globalScale: params.globalScale, quantDC: params.quantDC),
            blockContextMap: bctxDefault, colorCorrelation: nil,
            modularGlobalHasTree: nil, modularGlobalTreeNodeCount: nil)
        let dcDequant = computeDCDequant(dcGlobalInfo)  // DCImage.swift
        let facX = dcDequant.mulDC[0]  // extra_precision 0 => mul == 1
        let facY = dcDequant.mulDC[1]
        let facB = dcDequant.mulDC[2]
        let cflBDC = dcDequant.cfl[2]  // 1.0 (default color correlation)

        // AC multipliers per storage index (Reconstruct.swift dequant chain
        // with the default table, xQmScale = bQmScale = 2 => DmMul == 1,
        // default CfL: ytox 0, ytob base 1).
        let invGlobalScale = Float(1 << 16) / Float(params.globalScale)
        let scaledDequant = invGlobalScale / Float(params.quantField)
        let table = defaultDequantTable(.dct)  // [X 64, Y 64, B 64]
        var xMul = [Float](repeating: 0, count: 64)
        var yMul = xMul
        var bMul = xMul
        for k in 0..<64 {
            xMul[k] = table[k] * scaledDequant
            yMul[k] = table[64 + k] * scaledDequant
            bMul[k] = table[128 + k] * scaledDequant
        }
        let order = computeNaturalCoeffOrder(cbx: 1, cby: 1)  // CoeffOrder.swift

        // ---- Per-AC-group walk: forward DCT8, quantize (DC into the shared
        // block-resolution planes, AC into tokens mirroring decodeACGroupPass).
        var qDCX = [Int32](repeating: 0, count: bw * bh)
        var qDCY = qDCX
        var qDCB = qDCX
        let bgDim = dim.groupDim >> 3  // group dimension in blocks (32)
        var acTokens: [[EncToken]] = []
        acTokens.reserveCapacity(dim.numGroups)

        var cY = [Float](repeating: 0, count: 64)
        var cX = cY
        var cB = cY
        var qY = [Int32](repeating: 0, count: 64)
        var qX = qY
        var qB = qY

        let blockCtxOf: [Int] = [1, 0, 2].reduce(into: [Int](repeating: 0, count: 3)) {
            out, c in out[c] = encBlockContext(channel: c, order: kStrategyOrder[0])
        }

        for g in 0..<dim.numGroups {
            let bx0 = (g % dim.xsizeGroups) * bgDim
            let by0 = (g / dim.xsizeGroups) * bgDim
            let gw = min(bgDim, bw - bx0)
            let gh = min(bgDim, bh - by0)
            var tokens: [EncToken] = []
            // Group-local non-zero prediction planes (4:4:4: one per channel
            // at full block resolution).
            var nzeros = [[Int32]](repeating: [Int32](repeating: 0, count: gw * gh), count: 3)

            for byl in 0..<gh {
                let by = by0 + byl
                for bxl in 0..<gw {
                    let bx = bx0 + bxl
                    let px = by * 8 * pw + bx * 8
                    planeY.withUnsafeBufferPointer { p in
                        cY.withUnsafeMutableBufferPointer { o in
                            forwardDCT8(pixels: p.baseAddress! + px, stride: pw, out: o.baseAddress!)
                        }
                    }
                    planeX.withUnsafeBufferPointer { p in
                        cX.withUnsafeMutableBufferPointer { o in
                            forwardDCT8(pixels: p.baseAddress! + px, stride: pw, out: o.baseAddress!)
                        }
                    }
                    planeB.withUnsafeBufferPointer { p in
                        cB.withUnsafeMutableBufferPointer { o in
                            forwardDCT8(pixels: p.baseAddress! + px, stride: pw, out: o.baseAddress!)
                        }
                    }

                    // DC (storage[0], == block mean): DequantDC inverse. The
                    // decoder reconstructs B-DC as qY*facY*cfl + qB*facB, so
                    // B is quantized minus the reconstructed Y DC.
                    let dcPos = by * bw + bx
                    let vY = Int32((cY[0] / facY).rounded())
                    let vX = Int32((cX[0] / facX).rounded())
                    let recDCY = Float(vY) * facY
                    let vB = Int32(((cB[0] - cflBDC * recDCY) / facB).rounded())
                    qDCY[dcPos] = vY
                    qDCX[dcPos] = vX
                    qDCB[dcPos] = vB

                    // AC: quantize each storage index (1..63); B minus the
                    // reconstructed (bias-adjusted) Y coefficient — the
                    // decoder adds bufY back with the default ytob base 1.
                    var nzY = 0
                    var nzX = 0
                    var nzB = 0
                    for k in 1..<64 {
                        let yq = Int32((cY[k] / yMul[k]).rounded())
                        qY[k] = yq
                        if yq != 0 { nzY += 1 }
                        let xq = Int32((cX[k] / xMul[k]).rounded())
                        qX[k] = xq
                        if xq != 0 { nzX += 1 }
                        let recY = encAdjustQuantBias(yq, kEncQuantBiasY) * yMul[k]
                        let bq = Int32(((cB[k] - recY) / bMul[k]).rounded())
                        qB[k] = bq
                        if bq != 0 { nzB += 1 }
                    }

                    // Token emission, channels in the decoder's Y, X, B order.
                    for c in [1, 0, 2] {
                        let qc = c == 1 ? qY : (c == 0 ? qX : qB)
                        let totalNZ = c == 1 ? nzY : (c == 0 ? nzX : nzB)
                        let blockCtx = blockCtxOf[c]
                        let predicted = Int(
                            encPredictNonZeros(nzeros[c], w: gw, bx: bxl, by: byl))
                        let nzeroCtx = encNonZeroContext(
                            predicted: predicted, blockCtx: blockCtx)
                        tokens.append(EncToken(ctx: UInt32(nzeroCtx), value: UInt32(totalNZ)))
                        nzeros[c][byl * gw + bxl] = Int32(totalNZ)

                        let histoOffset = encZeroDensityOffset(blockCtx: blockCtx)
                        var prev = totalNZ > 64 / 16 ? 0 : 1
                        var nz = totalNZ
                        var k = 1
                        while k < 64 && nz != 0 {
                            let ctx = histoOffset
                                + encZeroDensityContext(nonzerosLeft: nz, k: k, prev: prev)
                            let value = qc[Int(order[k])]
                            tokens.append(
                                EncToken(ctx: UInt32(ctx), value: encPackSigned(Int(value))))
                            prev = value != 0 ? 1 : 0
                            nz -= prev
                            k += 1
                        }
                    }
                }
            }
            acTokens.append(tokens)
        }

        // ---- Modular streams (single-leaf gradient global tree): the DC
        // image (channels in modular order Y, X, B) and the AC metadata per
        // DC group.
        let tree = [
            MATreeNode(
                property: -1, splitVal: 0, lchild: 0, rchild: 0,
                predictor: 5, predictorOffset: 0, multiplier: 1)
        ]
        var dcTokens: [[EncToken]] = []
        var metaTokens: [[EncToken]] = []
        let dcTile = dim.groupDim  // DC group tile in blocks (256)
        for dcg in 0..<dim.numDCGroups {
            let x0 = (dcg % dim.xsizeDCGroups) * dcTile
            let y0 = (dcg / dim.xsizeDCGroups) * dcTile
            let rw = min(dcTile, bw - x0)
            let rh = min(dcTile, bh - y0)

            // VarDCTDC stream: modular channel c holds plane (c<2 ? c^1 : c),
            // i.e. channels [Y, X, B]; group-local borders at the rect edge.
            var t: [EncToken] = []
            let dcStreamID = 1 + dcg
            for (chan, plane) in [(0, qDCY), (1, qDCX), (2, qDCB)] {
                plane.withUnsafeBufferPointer { buf in
                    tokenizeChannelWithTree(
                        into: &t, plane: buf, width: bw, x0: x0, y0: y0, gw: rw, gh: rh,
                        chan: chan, streamID: dcStreamID, tree: tree)
                }
            }
            dcTokens.append(t)

            // AcMetadata stream: 4 channels — YtoX/YtoB color-tile maps
            // (zeros: default CfL), (count x 2) strategy+quant rows, EPF
            // sharpness (zeros). All-DCT8 => count == rw*rh varblocks.
            let crW = divCeil(rw, kColorTileDimInBlocks)
            let crH = divCeil(rh, kColorTileDimInBlocks)
            let count = rw * rh
            let cmapZero = [Int32](repeating: 0, count: crW * crH)
            var acsQF = [Int32](repeating: 0, count: count * 2)
            for i in 0..<count { acsQF[count + i] = params.quantField - 1 }
            let epfZero = [Int32](repeating: 0, count: rw * rh)
            var mt: [EncToken] = []
            let metaStreamID = 1 + 2 * dim.numDCGroups + dcg
            let chans: [(plane: [Int32], w: Int, h: Int)] = [
                (cmapZero, crW, crH), (cmapZero, crW, crH),
                (acsQF, count, 2), (epfZero, rw, rh),
            ]
            for (i, ch) in chans.enumerated() {
                ch.plane.withUnsafeBufferPointer { buf in
                    tokenizeChannelWithTree(
                        into: &mt, plane: buf, width: ch.w, x0: 0, y0: 0, gw: ch.w, gh: ch.h,
                        chan: i, streamID: metaStreamID, tree: tree)
                }
            }
            metaTokens.append(mt)
        }

        // ---- Entropy back-ends: the shared modular machinery for the global
        // tree + DC/metadata residuals; the local AC coder for coefficients.
        let residual = ANSEntropyEncoder(
            numContexts: treeNumLeaves(tree), streams: dcTokens + metaTokens)
        let acCoder = ACEntropyCoder(numContexts: kNumACContexts, streams: acTokens)

        // ---- Section writers (bit-exact duals listed in the file header).
        func writeLfGlobal(_ s: BitWriter) {
            // readVarDCTDCGlobal: dc-quant default, quantizer, default block
            // context map, default color correlation, global MA tree +
            // residual histograms. No global modular image (no extra
            // channels: the decoder reads nothing after the histograms).
            s.writeBool(true)  // dc_quant all_default
            s.writeU32(
                params.globalScale, .bits(11, offset: 1), .bits(11, offset: 2049),
                .bits(12, offset: 4097), .bits(16, offset: 8193))
            s.writeU32(
                params.quantDC, .value(16), .bits(5, offset: 1), .bits(8, offset: 1),
                .bits(16, offset: 1))
            s.writeBool(true)  // block context map all_default
            s.writeBool(true)  // color correlation all_default
            s.writeBool(true)  // has_tree
            let tTokens = treeTokens(tree)
            let tEnc = PrefixEntropyEncoder(numContexts: 6, streams: [tTokens])
            tEnc.writeHeader(s)
            tEnc.encodeStream(s, tTokens)
            residual.writeHeader(s)
        }
        func writeDCGroup(_ s: BitWriter, _ dcg: Int) {
            // decodeVarDCTDC: extra_precision, then a modular sub-stream
            // (GroupHeader + one ANS state); then decodeAcMetadataGroup:
            // the varblock count, then its own modular sub-stream.
            s.write(0, 2)  // extra_precision = 0
            s.writeBool(true)  // use_global_tree
            s.writeBool(true)  // wp_header: all_default
            s.write(0, 2)  // nb_transforms = 0
            residual.encodeStream(s, dcTokens[dcg])

            let x0 = (dcg % dim.xsizeDCGroups) * dcTile
            let y0 = (dcg / dim.xsizeDCGroups) * dcTile
            let rw = min(dcTile, bw - x0)
            let rh = min(dcTile, bh - y0)
            let upperBound = rw * rh
            let nbits = ceilLog2Nonzero(UInt32(upperBound))
            if nbits > 0 { s.write(UInt64(upperBound - 1), nbits) }  // count-1 (all DCT8)
            s.writeBool(true)  // use_global_tree
            s.writeBool(true)  // wp_header: all_default
            s.write(0, 2)  // nb_transforms = 0
            residual.encodeStream(s, metaTokens[dcg])
        }
        func writeHfGlobal(_ s: BitWriter) {
            // decodeVarDCTACGlobal: default dequant tables, one histogram,
            // used_orders = 0 (natural order for every strategy — no
            // permutations follow), then the AC histograms.
            s.writeBool(true)  // dequant all_default
            let histoBits = ceilLog2Nonzero(UInt32(dim.numGroups))
            if histoBits > 0 { s.write(0, histoBits) }  // num_histograms - 1 = 0
            s.writeU32(0, .value(0x5F), .value(0x13), .value(0), .bits(13))  // used_orders
            acCoder.writeHeader(s)
        }
        func writeACGroup(_ s: BitWriter, _ g: Int) {
            // decodeACGroupPass: numHistograms == 1 => no selector bits; the
            // group's token stream under one fresh ANS state.
            acCoder.encodeStream(s, acTokens[g])
        }

        // ---- Assembly: headers, frame header, TOC, sections (the modular
        // encoder's exact layout; section roles per sectionRole()).
        let head = BitWriter()
        HeaderWriter.writeCodestreamHeadersXYB(
            head, width: UInt32(w), height: UInt32(h),
            bitsPerSample: UInt32(image.bitsPerSample))
        writeFrameHeader(head)

        if dim.numGroups == 1 {
            // Coalesced: every stage concatenates into section 0, read
            // sequentially from one BitReader (no internal alignment).
            let s = BitWriter()
            writeLfGlobal(s)
            writeDCGroup(s, 0)
            writeHfGlobal(s)
            writeACGroup(s, 0)
            let section = s.finalize()
            head.writeBool(false)  // TOC: no permutation
            head.alignToByte()
            writeTocSize(head, section.count)
            head.alignToByte()
            head.append(bytes: section)
            return head.finalize()
        }

        var sections: [[UInt8]] = []
        let s0 = BitWriter()
        writeLfGlobal(s0)
        sections.append(s0.finalize())
        for dcg in 0..<dim.numDCGroups {
            let s = BitWriter()
            writeDCGroup(s, dcg)
            sections.append(s.finalize())
        }
        let sHf = BitWriter()
        writeHfGlobal(sHf)
        sections.append(sHf.finalize())
        for g in 0..<dim.numGroups {
            let s = BitWriter()
            writeACGroup(s, g)
            sections.append(s.finalize())
        }

        head.writeBool(false)  // TOC: no permutation
        head.alignToByte()
        for section in sections { writeTocSize(head, section.count) }
        head.alignToByte()
        for section in sections { head.append(bytes: section) }
        return head.finalize()
    }

    /// FrameHeader for the E5a lossy shape — dual of `FrameHeader.init` with
    /// xyb_encoded metadata: regular VarDCT frame, XYB (implicit),
    /// kSkipAdaptiveDCSmoothing, no upsampling, default QM scales, single
    /// pass, full canvas, replace blending, last frame, no name, loop
    /// filters off.
    private static func writeFrameHeader(_ w: BitWriter) {
        w.writeBool(false)  // all_default
        w.write(0, 2)  // frame_type: regular (U32 Val selector)
        w.writeBool(false)  // encoding: VarDCT
        w.writeU64(128)  // flags: kSkipAdaptiveDCSmoothing
        // (xyb_encoded => color transform is XYB, nothing serialized)
        w.write(0, 2)  // upsampling = 1 (U32 Val selector)
        // (no extra channels => no ec_upsampling)
        // (VarDCT => no group_size_shift; group_size_shift stays default 1)
        w.write(2, 3)  // x_qm_scale = 2 (xDmMul == 1)
        w.write(2, 3)  // b_qm_scale = 2 (bDmMul == 1)
        w.write(0, 2)  // num_passes = 1 (U32 Val selector)
        w.writeBool(false)  // custom_size_or_origin
        w.write(0, 2)  // blending mode: replace (U32 Val selector)
        w.writeBool(true)  // is_last
        // (is_last => no save_as_reference; not referenceable => no save_before)
        w.write(0, 2)  // name length = 0 (U32 Val selector)
        w.writeBool(false)  // loop filter: not all_default
        w.writeBool(false)  // gaborish off
        w.write(0, 2)  // epf_iters = 0
        w.writeU64(0)  // loop-filter extensions
        w.writeU64(0)  // frame-header extensions
    }

    /// TOC entry size (toc.cc U32 distribution; mirror of ModularEncoder's).
    private static func writeTocSize(_ w: BitWriter, _ size: Int) {
        w.writeU32(
            UInt32(size), .bits(10), .bits(14, offset: 1024),
            .bits(22, offset: 17408), .bits(30, offset: 4_211_712))
    }
}

extension JXL {
    /// Encodes integer pixel planes as a lossy (XYB VarDCT) bare-codestream
    /// JXL: 8/16-bit integer samples, 1 (replicated to RGB) or 3 color
    /// channels, no extra channels. `quality` 1…100 (default 90) maps to a
    /// uniform quantization step scale — see `VarDCTEncoder.quantParams`.
    /// The output decodes with this decoder and djxl; expect transparent
    /// quality at the default, not competitive density (E5a baseline:
    /// all-DCT8, uniform quant field, no adaptive quantization).
    public static func encodeLossy(image: JXLDecodedImage, quality: Int = 90) throws -> [UInt8] {
        try VarDCTEncoder.encodeLossy(image, quality: quality)
    }
}
