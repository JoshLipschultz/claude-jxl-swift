// VarDCTEncoder.swift
//
// E5a–E5d: the baseline lossy VarDCT encoder — valid, improving toward
// competitive. One regular XYB VarDCT frame, all-DCT8 strategies, an
// ADAPTIVE per-block quant field (E5b), a per-color-tile CHROMA-FROM-LUMA
// search (E5c), RATE-DISTORTION coefficient quantization (E5d), default
// dequant tables / block context map, loop filters off, single pass, 4:4:4,
// no extra channels.
//
// Per AC group the coefficient walk is TWO passes (see the group loop):
//   1. forward DCT, adaptive quant field, DC, Y-AC quantization, and each
//      color tile's least-squares CfL accumulation — order-insensitive
//      (writes only per-block scratch + per-tile accumulators, emits no
//      tokens), so it may run in any block order;
//   2. X/B-AC quantization (using pass 1's chosen per-tile CfL) and token
//      emission — STRICT group raster order, the one order decodeACGroupPass
//      reads. Splitting the passes is what lets a tile's CfL be decided from
//      all its blocks before any block's tokens are emitted, without
//      perturbing the emission order the decoder depends on.
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
//     chroma-from-luma (X += xCC*recY, B += bCC*recY, where xCC/bCC derive
//     from the per-tile YtoX/YtoB maps around bases 0/1) and AdjustQuantBias,
//   * color: ForwardXYB.swift inverts ConvertState.linear + the sRGB EOTF.
//
// Deliberate shape choices:
//   * flags = 128 (kSkipAdaptiveDCSmoothing) so decoded DC equals what we
//     quantized (both this decoder and djxl honor it),
//   * a single-leaf gradient MA tree codes the DC image + AC metadata,
//   * quality (1…100) maps to a baseline step scale via globalScale; the
//     per-block AC quant field (E5b, `encAdaptiveQuant`) modulates AROUND
//     that baseline from each block's own pre-quantization luma AC energy —
//     DC dequant stays uniform (it doesn't read the quant field at all; see
//     `computeDCDequant`, DCImage.swift).

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

// MARK: - Adaptive quantization (E5b)
//
// The bitstream carries an arbitrary per-block quant field (ACMetadata.swift:
// `quantField[block] = 1 + clamp(coded, 0, 255)`), and only the AC dequant
// step reads it (`Reconstruct.swift`: `scaledDequant = invGlobalScale /
// quant`) — DC dequant and the default block-context map are both
// quant-field-independent, confirmed by reading their decode paths. That
// makes AC-only adaptive quantization a self-contained per-block choice: any
// masking heuristic is spec-legal, so this one is ours, not libjxl's.
//
// Heuristic: RMS of the block's own pre-quantization luma AC coefficients
// (already computed by the forward DCT, no extra pass over pixels) as a
// proxy for local texture/edge energy; busy blocks (high RMS) get a LOWER
// quant value (coarser AC step — quant field co-varies inversely with step
// size, so "lower quant" means "less precision") than flat ones, spending
// the saved bits where the coarsening is cheapest.
//
// COARSEN-ONLY BY MEASUREMENT, NOT ASSUMPTION: the textbook move is also to
// push flat blocks ABOVE baseline (finer, to suppress banding) — kAqMaxMul
// > 1. Measured on a real-photo fixture and the mixed gradient/edge/noise
// bench image (quality/size, both quant-field-only, DC untouched): any
// maxMul > 1 (even the mild 1.05–1.15 range) blew up the bench image's size
// by 10–70%+ for well under 1 dB of PSNR gain — large smooth/gradient
// regions there were already near-exact under the baseline step, so
// resolving their now-tiny residual to a finer grid turns huge numbers of
// previously-all-zero AC blocks nonzero for almost no distortion payoff.
// Capping at kAqMaxMul == 1.0 (never finer than baseline — only ever
// coarsen) was Pareto-better on the photo fixture (+1.53 dB PSNR AND -5.1%
// size vs. uniform) and a clean win on the bench image (-6.3% size for
// -0.10 dB, i.e. effectively free) — the actual RD-optimal point across both
// fixtures, not the intuitive one. `kAqActivitySigma` sets how quickly
// activity saturates toward `kAqMinMul`; tuned on the same sweep.
private let kAqMinMul: Float = 0.55
private let kAqMaxMul: Float = 1.0
private let kAqActivitySigma: Float = 0.008

/// Adaptive per-block quant value from the block's pre-quantization Y AC
/// coefficients (`cY[base+1..<base+64]` in a flat per-tile buffer), scaled
/// around `baseQuant`, clamped to the bitstream's valid range [1, 256].
@inline(__always)
private func encAdaptiveQuant(_ cY: UnsafeBufferPointer<Float>, base: Int, baseQuant: Int32) -> Int32 {
    var sumSq: Float = 0
    for k in 1..<64 { sumSq += cY[base + k] * cY[base + k] }
    let activity = (sumSq / 63).squareRoot()
    let adj = 1 / (1 + activity / kAqActivitySigma)  // 1 (flat) .. ~0 (busy)
    let mul = kAqMinMul + (kAqMaxMul - kAqMinMul) * adj
    let q = (Float(baseQuant) * mul).rounded()
    return Int32(min(256, max(1, q)))
}

// MARK: - Chroma-from-luma search (E5c)
//
// Reconstruct.swift's AC dequant adds `xCC * bufY[k]` / `bCC * bufY[k]` back
// onto the X/B coefficients, where bufY is the ALREADY-DEQUANTIZED
// (bias-adjusted) Y value and xCC/bCC = base + tileVal*colorScale (base 0
// for X, 1 for B — the "B minus Y" baseline this encoder always used before
// this milestone). Per-tile `tileVal` is free: the decoder reads whatever
// the color-tile-resolution YtoX/YtoB channels carry. That makes the optimal
// per-tile choice a single unweighted least-squares slope fit (no
// intercept, since the model IS the multiplicative term) of the block's
// forward XYB coefficients against the block's own reconstructed Y:
//   slope = Σ(targetChannel[k] * recY[k]) / Σ(recY[k]²)  over every AC
//   coefficient in every block of the tile.
private let kDefaultColorFactor: Float = 84
private let kColorScale: Float = 1 / kDefaultColorFactor

/// Least-squares slope -> nearest valid per-tile int8 offset from `base`.
@inline(__always)
private func encFitColorTile(sumTargetY: Double, sumYY: Double, base: Float) -> Int32 {
    guard sumYY > 1e-9 else { return 0 }
    let slope = Float(sumTargetY / sumYY)
    let raw = ((slope - base) / kColorScale).rounded()
    return Int32(min(127, max(-128, raw)))
}

// MARK: - Rate-distortion coefficient quantization (E5d)
//
// Naive round-to-nearest minimizes distortion alone. RD quantization instead
// minimizes distortion + lambda*rate per AC coefficient: a small coefficient
// that would round to +-1 often costs more bits than the error it removes, so
// zeroing it (or shrinking its magnitude by one) is the better trade. This is
// the classic RD "dead zone", the largest quality-per-byte lever available
// without changing the bitstream structure — it only alters which coefficient
// values are emitted, all still legal.
//
// Domain: this repo's scaled inverse DCT is an isometry up to a constant
// (norm1D[j] = sum_x w(j)^2 cos^2((2x+1)j*pi/16) = 8 for EVERY frequency j, so
// the 2D per-coefficient pixel energy is 8*8 = 64 for all coefficients).
// Pixel MSE is therefore a constant multiple of coefficient-space squared
// error, so RD can work per coefficient in coefficient space with a single
// lambda and no per-frequency energy weight.
//
// Scale invariance: distortion scales as mul^2 (coefficient ~ mul * integer),
// so lambda is set to kRDLambda0 * mul^2. The mul^2 then cancels in every
// keep-vs-drop comparison, making the drop decision consistent across quality
// settings from a single tunable kRDLambda0. kRDNonzeroBits is the modeled
// per-nonzero rate floor (token + its effect on the nonzero-count / zero-
// density coding); |q|'s magnitude cost adds log2(|q|) on top.
// Shipped defaults were chosen by an offline RD-curve sweep (PSNR vs size at
// q30/50/70/90 on a real photo and the 6 MP gradient/edge bench, both fixtures
// showing matched-size gains of ~+0.4 dB at q90 and a −24% Pareto win at q70
// on the bench). The env overrides (JXL_RD_LAMBDA / JXL_RD_NZBITS) exist so
// that sweep is repeatable from a shipped binary — JXL_RD_LAMBDA=0 reproduces
// pre-RD (E5c naive-rounding) output exactly. Read once at process start.
private let kRDLambda0: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_RD_LAMBDA"], let v = Float(s) { return v }
    return 0.10
}()
private let kRDNonzeroBits: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_RD_NZBITS"], let v = Float(s) { return v }
    return 2.4
}()

/// RD-refines a naive quantized coefficient. `c` is the (CfL-corrected)
/// forward coefficient, `mul` its dequant multiplier, `q0` the naive rounded
/// quant. Returns the value minimizing (c - recon)^2 + lambda*rate over the
/// candidates {q0, q0 shrunk one step toward zero, 0}; recon mirrors the
/// decoder's adjustQuantBias. Enabled only for kRDLambda0 > 0.
@inline(__always)
private func encRDQuant(c: Float, mul: Float, q0: Int32, bias: Float) -> Int32 {
    if q0 == 0 || kRDLambda0 <= 0 { return q0 }
    let lambda = kRDLambda0 * mul * mul
    @inline(__always) func recon(_ q: Int32) -> Float {
        encAdjustQuantBias(q, bias) * mul
    }
    @inline(__always) func rate(_ q: Int32) -> Float {
        q == 0 ? 0 : kRDNonzeroBits + log2(Float(abs(q)))
    }
    @inline(__always) func cost(_ q: Int32) -> Float {
        let d = c - recon(q)
        return d * d + lambda * rate(q)
    }
    // Candidates: the naive value, one step toward zero, and zero. Enumerating
    // more is pointless — distortion is convex in q about c/mul and rate is
    // monotonic in |q|, so the optimum is q0 or lies between it and 0, and the
    // dominant win is the drop to zero.
    var best = q0
    var bestCost = cost(q0)
    let stepped = q0 > 0 ? q0 - 1 : q0 + 1
    for cand in [stepped, 0] where cand != best {
        let cc = cost(cand)
        if cc < bestCost {
            bestCost = cc
            best = cand
        }
    }
    return best
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
        // default CfL: ytox 0, ytob base 1). `scaledDequant` varies per block
        // now (E5b adaptive quant field), so `table`/`invGlobalScale` are the
        // only parts still hoisted out of the block loop.
        let invGlobalScale = Float(1 << 16) / Float(params.globalScale)
        let table = defaultDequantTable(.dct)  // [X 64, Y 64, B 64]
        let order = computeNaturalCoeffOrder(cbx: 1, cby: 1)  // CoeffOrder.swift

        // ---- Per-AC-group walk: forward DCT8, quantize (DC into the shared
        // block-resolution planes, AC into tokens mirroring decodeACGroupPass).
        var qDCX = [Int32](repeating: 0, count: bw * bh)
        var qDCY = qDCX
        var qDCB = qDCX
        // Per-block adaptive quant field (E5b), full block grid; read back
        // when building each DC group's AcMetadata stream.
        var blockQuantField = [Int32](repeating: params.quantField, count: bw * bh)
        // Per-color-tile CfL ints (E5c), full-frame color-tile grid (8x8
        // blocks/tile); read back the same way when building AcMetadata.
        let cmapFullW = divCeil(bw, kColorTileDimInBlocks)
        let cmapFullH = divCeil(bh, kColorTileDimInBlocks)
        var globalYtoX = [Int32](repeating: 0, count: cmapFullW * cmapFullH)
        var globalYtoB = [Int32](repeating: 0, count: cmapFullW * cmapFullH)
        let bgDim = dim.groupDim >> 3  // group dimension in blocks (32)
        var acTokens: [[EncToken]] = []
        acTokens.reserveCapacity(dim.numGroups)

        var qY = [Int32](repeating: 0, count: 64)
        var qX = qY
        var qB = qY

        let blockCtxOf: [Int] = [1, 0, 2].reduce(into: [Int](repeating: 0, count: 3)) {
            out, c in out[c] = encBlockContext(channel: c, order: kStrategyOrder[0])
        }

        // Per-group scratch (sized to the largest possible group,
        // bgDim x bgDim blocks): forward DCT results flat (block-major, 64
        // coefficients each), Y quantization + its reconstructed value, and
        // the per-block adaptive-quant scale. Reused across groups.
        let maxGroupBlocks = bgDim * bgDim
        var gcY = [Float](repeating: 0, count: maxGroupBlocks * 64)
        var gcX = gcY
        var gcB = gcY
        var gRecY = gcY
        var gQY = [Int32](repeating: 0, count: maxGroupBlocks * 64)
        var gScaledDequant = [Float](repeating: 0, count: maxGroupBlocks)

        for g in 0..<dim.numGroups {
            let bx0 = (g % dim.xsizeGroups) * bgDim
            let by0 = (g / dim.xsizeGroups) * bgDim
            let gw = min(bgDim, bw - bx0)
            let gh = min(bgDim, bh - by0)
            var tokens: [EncToken] = []
            // Group-local non-zero prediction planes (4:4:4: one per channel
            // at full block resolution).
            var nzeros = [[Int32]](repeating: [Int32](repeating: 0, count: gw * gh), count: 3)

            // ---- Pass 1: forward DCT, adaptive quant field, DC, Y AC
            // quantization + its reconstructed value, accumulating each
            // color tile's least-squares CfL sums (E5c) — in ANY block
            // order, since this pass only writes into per-block scratch
            // (indexed by group-local position, not visitation order) and
            // per-TILE accumulators, nothing here is order-sensitive. Kept
            // as the group's natural raster order purely for simplicity.
            let tilesX = divCeil(gw, kColorTileDimInBlocks)
            let tilesY = divCeil(gh, kColorTileDimInBlocks)
            var tileSumXY = [Double](repeating: 0, count: tilesX * tilesY)
            var tileSumBY = [Double](repeating: 0, count: tilesX * tilesY)
            var tileSumYY = [Double](repeating: 0, count: tilesX * tilesY)

            for byl in 0..<gh {
                let by = by0 + byl
                for bxl in 0..<gw {
                    let bx = bx0 + bxl
                    let gi = byl * gw + bxl
                    let base = gi * 64
                    let px = by * 8 * pw + bx * 8
                    planeY.withUnsafeBufferPointer { p in
                        gcY.withUnsafeMutableBufferPointer { o in
                            forwardDCT8(pixels: p.baseAddress! + px, stride: pw, out: o.baseAddress! + base)
                        }
                    }
                    planeX.withUnsafeBufferPointer { p in
                        gcX.withUnsafeMutableBufferPointer { o in
                            forwardDCT8(pixels: p.baseAddress! + px, stride: pw, out: o.baseAddress! + base)
                        }
                    }
                    planeB.withUnsafeBufferPointer { p in
                        gcB.withUnsafeMutableBufferPointer { o in
                            forwardDCT8(pixels: p.baseAddress! + px, stride: pw, out: o.baseAddress! + base)
                        }
                    }

                    // Adaptive quant field (E5b): from this block's own
                    // pre-quantization Y AC energy.
                    let dcPos = by * bw + bx
                    let blockQuant = gcY.withUnsafeBufferPointer {
                        encAdaptiveQuant($0, base: base, baseQuant: params.quantField)
                    }
                    blockQuantField[dcPos] = blockQuant
                    let scaledDequant = invGlobalScale / Float(blockQuant)
                    gScaledDequant[gi] = scaledDequant

                    // DC (storage[0], == block mean): DequantDC inverse,
                    // independent of the AC CfL search (the decoder
                    // overwrites AC-dequant's k=0 entry with the DC image
                    // value regardless — insertLLF).
                    let vY = Int32((gcY[base] / facY).rounded())
                    let vX = Int32((gcX[base] / facX).rounded())
                    let recDCY = Float(vY) * facY
                    let vB = Int32(((gcB[base] - cflBDC * recDCY) / facB).rounded())
                    qDCY[dcPos] = vY
                    qDCX[dcPos] = vX
                    qDCB[dcPos] = vB

                    // Y AC quantization (never CfL-corrected — Y is the
                    // reference channel) and its reconstructed (bias-
                    // adjusted) value, both cached for pass 2, plus this
                    // block's contribution to its color tile's CfL fit.
                    let tileIdx = (byl / kColorTileDimInBlocks) * tilesX + (bxl / kColorTileDimInBlocks)
                    for k in 1..<64 {
                        let yMulK = table[64 + k] * scaledDequant
                        let yq0 = Int32((gcY[base + k] / yMulK).rounded())
                        // RD-refine (E5d) BEFORE recon: the CfL fit and the
                        // pass-2 B/X-minus-Y correction must both see the Y
                        // value the decoder will actually reconstruct.
                        let yq = encRDQuant(c: gcY[base + k], mul: yMulK, q0: yq0, bias: kEncQuantBiasY)
                        gQY[base + k] = yq
                        let recY = encAdjustQuantBias(yq, kEncQuantBiasY) * yMulK
                        gRecY[base + k] = recY
                        tileSumXY[tileIdx] += Double(gcX[base + k]) * Double(recY)
                        tileSumBY[tileIdx] += Double(gcB[base + k]) * Double(recY)
                        tileSumYY[tileIdx] += Double(recY) * Double(recY)
                    }
                }
            }

            // ---- Finalize this group's per-tile CfL ints (E5c) into the
            // full-frame map (group block offsets are 8-block-aligned —
            // bgDim is a multiple of kColorTileDimInBlocks — so the divide
            // below is exact).
            var groupYtoX = [Int32](repeating: 0, count: tilesX * tilesY)
            var groupYtoB = [Int32](repeating: 0, count: tilesX * tilesY)
            for t in 0..<(tilesX * tilesY) {
                let ytoX = encFitColorTile(sumTargetY: tileSumXY[t], sumYY: tileSumYY[t], base: 0)
                let ytoB = encFitColorTile(sumTargetY: tileSumBY[t], sumYY: tileSumYY[t], base: 1)
                groupYtoX[t] = ytoX
                groupYtoB[t] = ytoB
                let fullTileX = bx0 / kColorTileDimInBlocks + t % tilesX
                let fullTileY = by0 / kColorTileDimInBlocks + t / tilesX
                globalYtoX[fullTileY * cmapFullW + fullTileX] = ytoX
                globalYtoB[fullTileY * cmapFullW + fullTileX] = ytoB
            }

            // ---- Pass 2: X/B AC quantization with each block's tile CfL,
            // then token emission — STRICT raster order (byl outer, bxl
            // inner, across the FULL group), matching decodeACGroupPass's
            // own traversal exactly. This is the one order the decoder
            // actually cares about; pass 1 above may run in any order
            // precisely because it never emits tokens.
            for byl in 0..<gh {
                for bxl in 0..<gw {
                    let gi = byl * gw + bxl
                    let base = gi * 64
                    let scaledDequant = gScaledDequant[gi]
                    let tileIdx = (byl / kColorTileDimInBlocks) * tilesX + (bxl / kColorTileDimInBlocks)
                    let xCC = Float(groupYtoX[tileIdx]) * kColorScale
                    let bCC = 1 + Float(groupYtoB[tileIdx]) * kColorScale

                    var nzY = 0
                    var nzX = 0
                    var nzB = 0
                    for k in 1..<64 {
                        let yq = gQY[base + k]  // already RD-refined in pass 1
                        qY[k] = yq
                        if yq != 0 { nzY += 1 }
                        let recY = gRecY[base + k]
                        // X/B quantize the CfL residual (coefficient minus the
                        // reconstructed-Y contribution the decoder adds back);
                        // RD-refine that residual's quant (E5d).
                        let xMulK = table[k] * scaledDequant
                        let xc = gcX[base + k] - xCC * recY
                        let xq = encRDQuant(
                            c: xc, mul: xMulK, q0: Int32((xc / xMulK).rounded()), bias: kEncQuantBiasX)
                        qX[k] = xq
                        if xq != 0 { nzX += 1 }
                        let bMulK = table[128 + k] * scaledDequant
                        let bc = gcB[base + k] - bCC * recY
                        let bq = encRDQuant(
                            c: bc, mul: bMulK, q0: Int32((bc / bMulK).rounded()), bias: kEncQuantBiasB)
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
            // (E5c per-tile CfL search), (count x 2) strategy+quant rows, EPF
            // sharpness (zeros). All-DCT8 => count == rw*rh varblocks.
            let crW = divCeil(rw, kColorTileDimInBlocks)
            let crH = divCeil(rh, kColorTileDimInBlocks)
            let count = rw * rh
            // Same (ctX0, ctY0) full-frame color-tile origin the decoder
            // computes from the DC group's rect (ACMetadata.swift).
            let ctX0 = x0 >> 3
            let ctY0 = y0 >> 3
            var cmapX = [Int32](repeating: 0, count: crW * crH)
            var cmapB = [Int32](repeating: 0, count: crW * crH)
            for cy in 0..<crH {
                for cx in 0..<crW {
                    let src = (ctY0 + cy) * cmapFullW + (ctX0 + cx)
                    cmapX[cy * crW + cx] = globalYtoX[src]
                    cmapB[cy * crW + cx] = globalYtoB[src]
                }
            }
            var acsQF = [Int32](repeating: 0, count: count * 2)
            // Row-major (iy, ix) over the DC group's rect: with every block a
            // DCT8 varblock, `num` in decodeAcMetadataGroup increments once
            // per (iy, ix) in exactly this order, so index i == that num.
            for i in 0..<count {
                let iy = i / rw
                let ix = i % rw
                let bq = blockQuantField[(y0 + iy) * bw + (x0 + ix)]
                acsQF[count + i] = bq - 1  // decoder: quant = 1 + clamp(coded, 0, 255)
            }
            let epfZero = [Int32](repeating: 0, count: rw * rh)
            var mt: [EncToken] = []
            let metaStreamID = 1 + 2 * dim.numDCGroups + dcg
            let chans: [(plane: [Int32], w: Int, h: Int)] = [
                (cmapX, crW, crH), (cmapB, crW, crH),
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
    /// quality at the default (E5a+E5b baseline: all-DCT8, per-block
    /// adaptive AC quantization from a local luma-energy heuristic — not yet
    /// competitive density: no adaptive DCT strategies or CfL search).
    public static func encodeLossy(image: JXLDecodedImage, quality: Int = 90) throws -> [UInt8] {
        try VarDCTEncoder.encodeLossy(image, quality: quality)
    }
}
