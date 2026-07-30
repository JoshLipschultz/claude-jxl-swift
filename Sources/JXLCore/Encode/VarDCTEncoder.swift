// VarDCTEncoder.swift
//
// E5a–E5g: the baseline lossy VarDCT encoder — valid, improving toward
// competitive. One regular XYB VarDCT frame, VARIABLE-SIZE AC transforms
// (DCT8 + DCT16, E5e) chosen by a frame-level race (E5f), an ADAPTIVE
// per-block quant field (E5b), a per-color-tile CHROMA-FROM-LUMA search
// (E5c), RATE-DISTORTION coefficient quantization (E5d), default dequant
// tables / block context map, loop filters off, single pass, 4:4:4.
//
// EXTRA CHANNELS (E5g) are supported and are LOSSLESS: the format codes them
// as a modular image inside the VarDCT frame, sharing the DC/metadata global
// tree and ANS code, so alpha round-trips byte-exactly while color is lossy.
// See the EC section in encodeLossyPass for the group-split rule.
//
// Per AC group the coefficient walk is FOUR passes (see the group loop):
//   1a. forward DCT8 of every block + its adaptive quant value;
//   1b. per aligned 2x2 cell, the DCT16-vs-4xDCT8 rate-distortion choice
//       (VarDCTStrategy.swift); a chosen DCT16 overwrites the four DCT8
//       coefficient slots it replaces — they are the same four slots, by
//       construction of the cell-major scratch layout;
//   1c. per VARBLOCK: placement metadata, the quant field, DC (for DCT16 the
//       four DC samples are the inverse of the decoder's insertLLF), Y-AC
//       quantization, and each color tile's least-squares CfL accumulation;
//   2.  X/B-AC quantization (using 1c's chosen per-tile CfL) and token
//       emission — STRICT group raster order skipping covered blocks, the one
//       order decodeACGroupPass reads.
// Passes 1a–1c are order-insensitive (they write only per-varblock scratch,
// the frame-wide planes at their own blocks, and per-tile accumulators, and
// emit no tokens). Splitting them from pass 2 is what lets a tile's CfL be
// decided from all its blocks — and each cell's transform be chosen — before
// any tokens are emitted, without perturbing the emission order the decoder
// depends on.
//
// The load-bearing rule: every field written here is the exact dual of a
// decoder reader in this repo —
//   * frame shape/TOC: FrameDecoder.sectionRole / parseFrameSlot,
//   * LfGlobal: readVarDCTDCGlobal (VarDCTInfo.swift),
//   * DC groups: decodeVarDCTDC + decodeAcMetadataGroup (DCImage.swift /
//     ACMetadata.swift), via the modular machinery's own tokenizer — the
//     varblock placement walk (raster order, skipping covered blocks, one
//     strategy+quant entry per varblock at index `num`) is replayed here
//     step for step,
//   * DCT16 lowest frequencies: insertLLF (DCTTransforms.swift) and its
//     DCTResampleScales, inverted in VarDCTStrategy.swift,
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

/// Mirror of zeroDensityContext (PassGroup.swift). `covered` is the varblock's
/// 8x8-block count (1 for DCT8, 4 for DCT16) and `log2Covered` its log2 — both
/// the non-zero count and the coefficient index are divided down by it, so a
/// multi-block varblock's 256 coefficients reuse the same 64-entry tables.
@inline(__always)
private func encZeroDensityContext(
    nonzerosLeft nz: Int, k: Int, covered: Int, log2Covered: Int, prev: Int
) -> Int {
    let n = (nz + covered - 1) >> log2Covered
    let kk = k >> log2Covered
    return (kEncCoeffNumNonzeroContext[n] + kEncCoeffFreqContext[kk]) * 2 + prev
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
let kEncQuantBiasX: Float = 1.0 - 0.05465007330715401
let kEncQuantBiasY: Float = 1.0 - 0.07005449891748593
let kEncQuantBiasB: Float = 1.0 - 0.049935103337343655
private let kEncQuantBiasNumerator: Float = 0.145

@inline(__always)
func encAdjustQuantBias(_ q: Int32, _ bias: Float) -> Float {
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

/// Block contexts [0, 7) are the LUMA ones under the default block context
/// map: its index is `channelBucket * kNumCoeffOrders + order`, and the luma
/// bucket's 13 order entries are [0,1,2,2,3,3,4,5,6,6,6,6,6] while both chroma
/// buckets' are [7,8,9,9,10,...,14]. So "is this context luma?" is exactly
/// `blockCtx < 7` — for EVERY coefficient order, which is what makes it the
/// right split once more than one AC strategy is in play (DCT8 luma is block
/// context 0, DCT16 luma is 2; clustering on `== 0` would entropy-code every
/// DCT16 luma coefficient against the chroma histogram).
private let kEncFirstChromaBlockCtx = 7

/// Fixed AC context -> cluster map. Context layout (PassGroup.swift with
/// numHistograms == 1): [0, 555) non-zero-count contexts (bucket*15 +
/// blockCtx); [555, 7425) zero-density contexts (555 + 458*blockCtx + zd).
/// 8 clusters: luma/chroma block contexts x {nonzeros, 3 zero-density bands}.
/// Every cluster index appears in the map by construction (decodeContextMap
/// requires surjectivity onto [0, max]).
private func acFixedClusterMap(numContexts: Int) -> [UInt8] {
    let nzEnd = kNumBlockCtxClusters * kNonZeroBuckets
    var map = [UInt8](repeating: 0, count: numContexts)
    for ctx in 0..<numContexts {
        if ctx < nzEnd {
            map[ctx] = (ctx % kNumBlockCtxClusters) < kEncFirstChromaBlockCtx ? 0 : 1
        } else {
            let rel = ctx - nzEnd
            let blockCtx = rel / kZeroDensityContextCount
            let zd = rel % kZeroDensityContextCount
            let half = zd >> 1  // nonzero bucket + frequency bucket
            let band = half < 31 ? 0 : (half < 93 ? 1 : 2)
            map[ctx] = UInt8(2 + (blockCtx < kEncFirstChromaBlockCtx ? 0 : 3) + band)
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
    /// Raw (un-normalized) per-cluster token occurrences, kept so the map race
    /// can price a candidate's payload analytically instead of serializing it.
    private let rawHist: [[Int]]

    /// Picks the AC context map by MEASURED serialized size.
    ///
    /// The multi-cluster map makes the AC payload cheaper but costs a
    /// 7425-entry context map plus one ANS histogram per cluster in HfGlobal —
    /// and that header cost does NOT shrink with the amount of AC data. The
    /// previous rule (`total < 4096` tokens) could not see this, because
    /// `total` counts every AC token including the per-block nonzero-COUNT
    /// tokens, of which there is one per block per channel even when every
    /// coefficient is zero. At 768x512 that is ~18k tokens before a single
    /// coefficient exists, so the threshold was effectively never met and the
    /// expensive map was always chosen.
    ///
    /// The cost of getting it wrong is severe in both directions, so neither
    /// map can simply be preferred (photo_sky, races off):
    ///     q1   8-cluster 3065 B   1-cluster  271 B   (-91%)
    ///     q30  8-cluster 3829 B   1-cluster 1077 B   (-72%)
    ///     q90  photo_bridge 151715 B vs 159242 B     (+5% the other way)
    ///     q90  synth_noise  391025 B vs 442228 B     (+13% the other way)
    /// Sparse AC wants one cluster; dense AC wants eight.
    ///
    /// This is a PURE SIZE choice with no quality dimension — the coefficients
    /// are already fixed, and only their entropy coding changes — so the
    /// candidates are compared on real serialized bytes with no lambda, and the
    /// smaller simply wins. Measuring costs building the histograms twice and
    /// serializing twice; it does NOT re-encode any coefficients.
    ///
    /// `JXL_AC_CLUSTERS=1` / `=8` pins one map for measurement.
    static func choose(numContexts: Int, streams: [[EncToken]]) -> ACEntropyCoder {
        let forced = ProcessInfo.processInfo.environment["JXL_AC_CLUSTERS"]
        let single = [UInt8](repeating: 0, count: numContexts)
        let multi = acFixedClusterMap(numContexts: numContexts)
        if forced == "1" { return ACEntropyCoder(numContexts: numContexts, streams: streams, map: single) }
        if forced == "8" { return ACEntropyCoder(numContexts: numContexts, streams: streams, map: multi) }

        let a = ACEntropyCoder(numContexts: numContexts, streams: streams, map: single)
        let b = ACEntropyCoder(numContexts: numContexts, streams: streams, map: multi)
        return a.estimatedSize(streams) <= b.estimatedSize(streams) ? a : b
    }

    /// What this coder would cost for `streams`, in bytes.
    ///
    /// The HfGlobal header — the part that differs enormously between
    /// candidates and is the entire point of the race — is measured EXACTLY by
    /// running the real writer. The payload is priced analytically as the
    /// entropy of the tokens under the SAME normalized (sum-4096) counts the
    /// ANS coder will actually use, which tracks the real coded size closely
    /// because that is precisely what rANS achieves.
    ///
    /// Serializing every group's payload twice just to compare two numbers cost
    /// 0.66 s on a 6 MP frame — 16% of total encode time — for a decision that
    /// two histograms already determine. Extra bits are omitted deliberately:
    /// they depend only on the token values, which are identical across
    /// candidates, so they cancel in the comparison.
    private func estimatedSize(_ streams: [[EncToken]]) -> Double {
        let w = BitWriter()
        writeHeader(w)
        let headerBytes = Double(w.finalize().count)
        var payloadBits = 0.0
        let denom = Double(1 << 12)  // counts are normalized to sum 4096
        for c in 0..<rawHist.count {
            let raw = rawHist[c]
            let norm = counts[c]
            for sym in 0..<raw.count where raw[sym] > 0 {
                let f = Double(norm[sym])
                // A symbol that occurs cannot have been normalized to zero.
                payloadBits -= Double(raw[sym]) * (f > 0 ? log2(f / denom) : -32.0)
            }
        }
        return headerBytes + payloadBits / 8.0
    }

    private init(numContexts: Int, streams: [[EncToken]], map: [UInt8]) {
        self.numContexts = numContexts
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
        rawHist = hist

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
private func encAdaptiveQuant(_ cY: UnsafePointer<Float>, base: Int, baseQuant: Int32) -> Int32 {
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
/// Chroma-from-luma master switch. `JXL_CFL=0` pins every tile to the base
/// correlation, which is how CfL is isolated when bisecting a quality anomaly
/// (it is otherwise invisible: no other knob turns it off).
let kEncCfLEnabled: Bool = {
    if let s = ProcessInfo.processInfo.environment["JXL_CFL"] { return s != "0" }
    return true
}()

private func encFitColorTile(sumTargetY: Double, sumYY: Double, base: Float) -> Int32 {
    guard kEncCfLEnabled else { return 0 }
    guard sumYY > 1e-9 else { return 0 }
    let slope = Float(sumTargetY / sumYY)
    let raw = ((slope - base) / kColorScale).rounded()
    let quantized = Int32(min(127, max(-128, raw)))

    // ACCEPT THE FIT ONLY IF IT ACTUALLY LOWERS THE RESIDUAL.
    //
    // `sumYY > 1e-9` guards division by zero but NOT ill-conditioning, and the
    // difference is a real bug rather than a nicety. On near-flat tiles sumYY
    // is tiny but nonzero, so the least-squares slope is driven by numerical
    // noise and comes out enormous — and the clamp then applies a FULL-SCALE
    // (+-127) chroma correction derived from that noise.
    //
    // It showed up as quality going BACKWARDS as quality rose: on the
    // benchmark's smoothest image the B channel fell from 17.4 dB at q10 to
    // 15.5 dB at q25. The U-shape is diagnostic — at coarse quant the
    // reconstructed Y is all zeros so sumYY trips the guard and the fit is
    // skipped; at high quality Y is accurate and the fit is genuine; the damage
    // lands in between, where Y is nonzero but nearly constant.
    //
    // The test is exact and needs no tuned epsilon. Residual energy for slope s
    // is `sumTT - 2*s*sumTargetY + s^2*sumYY`, so COMPARING two slopes cancels
    // the unknown sumTT term entirely. Compare the slope the decoder will
    // actually reconstruct (base + quantized*kColorScale, not the unrounded
    // least-squares value) against the base, and keep the correction only when
    // it wins. Returning 0 means "use base", which is what the decoder computes
    // for a zero correlation index.
    let fitted = Double(base) + Double(quantized) * Double(kColorScale)
    let baseline = Double(base)
    let deltaEnergy =
        -2.0 * (fitted - baseline) * sumTargetY
        + (fitted * fitted - baseline * baseline) * sumYY
    return deltaEnergy < 0 ? quantized : 0
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
let kRDLambda0: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_RD_LAMBDA"], let v = Float(s) { return v }
    return 0.10
}()
let kRDNonzeroBits: Float = {
    if let s = ProcessInfo.processInfo.environment["JXL_RD_NZBITS"], let v = Float(s) { return v }
    return 2.4
}()

/// RD-refines a naive quantized coefficient. `c` is the (CfL-corrected)
/// forward coefficient, `mul` its dequant multiplier, `q0` the naive rounded
/// quant. Returns the value minimizing (c - recon)^2 + lambda*rate over the
/// candidates {q0, q0 shrunk one step toward zero, 0}; recon mirrors the
/// decoder's adjustQuantBias. Enabled only for kRDLambda0 > 0.
@inline(__always)
func encRDQuant(c: Float, mul: Float, q0: Int32, bias: Float) -> Int32 {
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
    /// E5f: race the DCT16-enabled encode against an all-DCT8 one and keep
    /// whichever is better in true rate-distortion terms.
    ///
    /// Per-cell criteria cannot decide this. Two sweeps (the rate model's
    /// zero-token cost, and a scan-depth guard) both floored ~12% above the
    /// all-DCT8 size on noise-dominated content, because DCT16 and DCT8 blocks
    /// use different block-context buckets: ANY mixture fragments the ANS
    /// histograms, a frame-global cost invisible to a per-cell model. So the
    /// decision is made where the cost actually lives — per frame, on measured
    /// output rather than a model — the same "race the real encodings" pattern
    /// the lossless encoder uses for palette.
    ///
    /// Both candidates are decoded and scored as `distortion + lambda * bytes`
    /// with lambda from the same quality knob, so a candidate that is merely
    /// smaller-and-worse cannot win. The extra cost is one encode plus two
    /// decodes; it is skipped entirely when DCT16 is disabled or when the
    /// DCT16 encode chose no DCT16 blocks at all (then the two are identical
    /// by construction).
    static func encodeLossy(
        _ image: JXLDecodedImage, quality: Int = 90, effort: Int = 2
    ) throws -> [UInt8] {
        // Effort 1 skips learning the global modular tree (E5k). That tree buys
        // 20-30% on smooth content at identical quality, but `learnTree`'s
        // greedy split search runs over every DC sample and roughly DOUBLES
        // encode time on typical images (photo_city q50 0.08 s -> 0.18 s), so
        // which side of that trade you want is a caller's decision, not ours.
        let learnDCTree = effort >= 2 && kEncLearnedDCTree
        // Score any candidate on what was actually produced: true SSE against
        // the source (decoded through our own decoder) plus lambda * bytes.
        //
        // Decoding rather than modelling is what makes E5h possible at all.
        // Gaborish and EPF happen at the very end of reconstruction, so a
        // modelled score would have to simulate both — including EPF's
        // nonlinear, quant-field-driven behaviour — and any drift between that
        // simulation and the real filters would silently corrupt the decision.
        // Decoding our own output measures the truth by construction.
        func rdScore(_ bytes: [UInt8]) -> Double? {
            guard let dec = try? JXL.decodeImage(from: bytes),
                dec.width == image.width, dec.height == image.height,
                dec.planes.count >= image.colorChannels
            else { return nil }
            var sse = 0.0
            for c in 0..<image.colorChannels {
                let a = image.planes[c]
                let b = dec.planes[c]
                guard a.count == b.count else { return nil }
                for i in 0..<a.count {
                    let d = Double(a[i]) - Double(b[i])
                    sse += d * d
                }
            }
            // lambda in SSE-per-byte: the same step-scale relationship the
            // coefficient RD uses, so the frame decision and the per-cell
            // decisions agree about what a byte is worth.
            let params = quantParams(quality: quality)
            let step = Double(1 << 16) / Double(params.globalScale)
            return sse + kEncFrameRaceLambda * step * step * Double(bytes.count)
        }

        // The race is a LADDER, not a cross product: each axis is settled
        // against the current best rather than every combination being encoded,
        // which keeps the worst case at three encodes instead of four+ while
        // still letting either axis flip the outcome.
        //
        // Axis 1 (E5h): restoration filters. Raced first because it changes
        // what the coefficients should even represent (Gaborish compensation
        // pre-sharpens the input), so the DCT16 decision is better made on the
        // filter setting we are actually keeping.
        var best = try encodeLossyPass(
            image, quality: quality, allowDCT16: true, filters: kEncDefaultFilters,
            learnDCTree: learnDCTree)
        var bestScore = rdScore(best.bytes)
        if kEncFilterRaceEnabled, kEncDefaultFilters != .off {
            let unfiltered = try encodeLossyPass(
                image, quality: quality, allowDCT16: true, filters: .off,
                learnDCTree: learnDCTree)
            if let a = bestScore, let b = rdScore(unfiltered.bytes), b < a {
                best = unfiltered
                bestScore = b
            } else if bestScore == nil {
                // Filtered candidate failed to decode: fall back rather than
                // ship something we could not verify.
                best = unfiltered
                bestScore = rdScore(unfiltered.bytes)
            }
        }
        let bestFilters = best.usedFilters

        // Axis 2 (E5f): DCT16 vs all-DCT8, on the winning filter setting. Only
        // worth an encode when some cell actually chose DCT16 — otherwise the
        // two candidates are identical by construction.
        guard kEncDCT16Enabled, best.usedDCT16 else {
            return preferLosslessIfSmaller(image, lossy: best.bytes)
        }
        let plainDCT8 = try encodeLossyPass(
            image, quality: quality, allowDCT16: false, filters: bestFilters,
            learnDCTree: learnDCTree)
        guard let s16 = bestScore, let s8 = rdScore(plainDCT8.bytes) else {
            // decode failure: keep the primary path
            return preferLosslessIfSmaller(image, lossy: best.bytes)
        }
        return preferLosslessIfSmaller(image, lossy: s8 < s16 ? plainDCT8.bytes : best.bytes)
    }

    /// Ships the LOSSLESS encoding instead when it comes out smaller than the
    /// lossy one.
    ///
    /// This is a DOMINANCE check, not a rate-distortion trade, which is why it
    /// needs no lambda: a lossless stream is exact, so if it is also smaller it
    /// beats the lossy candidate on BOTH axes simultaneously and there is
    /// nothing to weigh. The lossy result is only ever kept when it is actually
    /// buying something — fewer bytes.
    ///
    /// Measured motivation (docs/lossy-vs-cjxl.md): on text/screen content our
    /// lossy path emitted 64299 B where our own lossless emitted 4042 B — 16x
    /// larger AND worse. The benchmark scored that class at +874% BD-rate, by
    /// far our largest gap, and cjxl's advantage there is mode selection rather
    /// than better coding tools. We already have the encoder to route to; this
    /// is the routing.
    ///
    /// Racing the real encoder rather than classifying the image is the same
    /// choice E5f and E5h made, and for the same reason: cheap proxies for "is
    /// this flat/text-like" mis-rank exactly the mixed content that matters.
    /// It is affordable because lossless is roughly an order of magnitude
    /// FASTER than the lossy path (6 MP: e1 ~0.11 s vs lossy ~2.2 s), so the
    /// probe costs a few percent. Effort 1 is the probe; effort 2 is only run
    /// once effort 1 has already proven lossless competitive.
    ///
    /// `JXL_LOSSLESS_RACE=0` disables it, matching the other encoder knobs.
    private static func preferLosslessIfSmaller(
        _ image: JXLDecodedImage, lossy: [UInt8]
    ) -> [UInt8] {
        guard kEncLosslessRaceEnabled else { return lossy }
        // GRAYSCALE IS EXCLUDED, and the reason is a contract issue rather than
        // a quality one. The lossy path replicates a gray plane into RGB before
        // the XYB transform, so its output decodes as 3 channels; the lossless
        // path correctly preserves grayscale and decodes as 1. Letting the rule
        // fire here would make `encodeLossy`'s decoded channel COUNT depend on
        // which candidate happened to win — an unpredictable API is a worse
        // failure than a missed size win, and it crashed a caller that indexed
        // planes[0..<3] the first time it happened.
        //
        // The real fix is native grayscale lossy (the replication is a wart in
        // its own right, costing 3 channels where 1 would do); once the lossy
        // path preserves gray, both candidates agree and this guard can go.
        // Until then gray content — including scanned text, where this rule
        // would otherwise pay well — keeps the lossy stream. Tracked separately.
        guard image.colorChannels != 1 else { return lossy }
        guard let fast = try? ModularEncoder.encodeLossless(image, effort: 1),
            fast.count < lossy.count
        else { return lossy }
        if let dense = try? ModularEncoder.encodeLossless(image, effort: 2),
            dense.count < fast.count {
            return dense
        }
        return fast
    }

    private static func encodeLossyPass(
        _ image: JXLDecodedImage, quality: Int, allowDCT16: Bool,
        filters: EncFilterConfig = .off, learnDCTree: Bool = true
    ) throws -> (bytes: [UInt8], usedDCT16: Bool, usedFilters: EncFilterConfig) {
        guard !image.isFloat else {
            throw JXLEncodeError(reason: "lossy encode supports integer samples only")
        }
        // Extra channels are modular-coded inside a VarDCT frame, so alpha
        // rides along LOSSLESS while the color planes are lossy. Float ECs are
        // rejected because the decoder rejects them too
        // (decodeExtraChannelGlobal).
        guard image.planes.count == image.colorChannels + image.extraChannels else {
            throw JXLEncodeError(reason: "plane count must be colorChannels + extraChannels")
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
        guard image.planes.allSatisfy({ $0.count == planeSize }) else {
            throw JXLEncodeError(reason: "plane size mismatch")
        }
        let maxSample = Int32((1 << image.bitsPerSample) - 1)
        for p in image.planes {
            for v in p where v < 0 || v > maxSample {
                throw JXLEncodeError(
                    reason: "sample \(v) out of range for \(image.bitsPerSample)-bit")
            }
        }

        let params = quantParams(quality: quality)
        // Set when any cell selects DCT16; drives the E5f frame-level race.
        var anyDCT16 = false
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
            // E5h: when the frame asks the decoder to run Gaborish, the
            // coefficients must describe a PRE-SHARPENED image, so that the
            // decoder's blur lands back on the source instead of shipping a
            // blurred one. Done on the visible rect with the padded stride,
            // matching the rect and mirror rule the decoder filters over; the
            // padding below is (re)built afterwards because sharpening moves
            // edge pixels.
            //
            // EPF gets no compensation: it is edge-preserving and
            // quant-field-driven, i.e. nonlinear with no useful inverse. Its
            // value is removing ringing, and whether that pays is settled by
            // the frame race on measured output rather than modelled here.
            if filters.gaborish {
                // The header is written with gab_custom = false, so all three
                // planes use the shared defaults the decoder will read back.
                let g1 = kGaborishDefaultWeight1
                let g2 = kGaborishDefaultWeight2
                encGaborishInverse(&planeX, w: w, h: h, stride: pw, weight1: g1, weight2: g2)
                encGaborishInverse(&planeY, w: w, h: h, stride: pw, weight1: g1, weight2: g2)
                encGaborishInverse(&planeB, w: w, h: h, stride: pw, weight1: g1, weight2: g2)
                // Re-replicate the right edge, now that column w-1 changed.
                for y in 0..<h {
                    let dst = y * pw
                    for x in w..<pw {
                        planeX[dst + x] = planeX[dst + w - 1]
                        planeY[dst + x] = planeY[dst + w - 1]
                        planeB[dst + x] = planeB[dst + w - 1]
                    }
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
        // Dequant tables and coefficient orders as manually-managed buffers
        // (a few KB, freed on exit). The group walk indexes them from its
        // innermost loops and hands them to the cost model; wrapping every use
        // in `withUnsafeBufferPointer` would nest closures five deep, which
        // costs refcount traffic and — measurably — sends Swift's type checker
        // exponential.
        func rawFloats(_ a: [Float]) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: a.count)
            for i in 0..<a.count { p[i] = a[i] }
            return p
        }
        func rawUInt32(_ a: [UInt32]) -> UnsafeMutablePointer<UInt32> {
            let p = UnsafeMutablePointer<UInt32>.allocate(capacity: a.count)
            for i in 0..<a.count { p[i] = a[i] }
            return p
        }
        let tab8 = rawFloats(defaultDequantTable(.dct))  // [X 64, Y 64, B 64]
        let tab16 = rawFloats(defaultDequantTable(.dct16x16))  // [X 256, Y 256, B 256]
        let ord8 = rawUInt32(computeNaturalCoeffOrder(cbx: 1, cby: 1))  // CoeffOrder.swift
        let ord16 = rawUInt32(computeNaturalCoeffOrder(cbx: 2, cby: 2))  // 256, LLF first
        defer {
            tab8.deallocate()
            tab16.deallocate()
            ord8.deallocate()
            ord16.deallocate()
        }

        // ---- Per-AC-group walk: forward DCT8/DCT16, quantize (DC into the
        // shared block-resolution planes, AC into tokens mirroring
        // decodeACGroupPass).
        var qDCX = [Int32](repeating: 0, count: bw * bh)
        var qDCY = qDCX
        var qDCB = qDCX
        // Per-block adaptive quant field (E5b), full block grid; read back
        // when building each DC group's AcMetadata stream. A multi-block
        // varblock writes ONE value into every block it covers, because that
        // is what decodeAcMetadataGroup fills in.
        var blockQuantField = [Int32](repeating: params.quantField, count: bw * bh)
        // Frame-wide varblock placement (E5e) — the encoder-side twins of the
        // decoder's `strategy` / `isFirstBlock` planes. The AcMetadata writer
        // replays decodeAcMetadataGroup's own raster walk over these, so the
        // strategy/quant rows land at exactly the `num` indices the decoder
        // reads them from.
        var frameStrategy = [UInt8](repeating: UInt8(kEncStrategyDCT8), count: bw * bh)
        var frameIsFirst = [Bool](repeating: true, count: bw * bh)
        // Per-color-tile CfL ints (E5c), full-frame color-tile grid (8x8
        // blocks/tile); read back the same way when building AcMetadata.
        let cmapFullW = divCeil(bw, kColorTileDimInBlocks)
        let cmapFullH = divCeil(bh, kColorTileDimInBlocks)
        var globalYtoX = [Int32](repeating: 0, count: cmapFullW * cmapFullH)
        var globalYtoB = [Int32](repeating: 0, count: cmapFullW * cmapFullH)
        let bgDim = dim.groupDim >> 3  // group dimension in blocks (32)
        var acTokens: [[EncToken]] = []
        acTokens.reserveCapacity(dim.numGroups)

        var qY = [Int32](repeating: 0, count: 256)
        var qX = qY
        var qB = qY

        let blockCtx8: [Int] = [1, 0, 2].reduce(into: [Int](repeating: 0, count: 3)) {
            out, c in
            out[c] = encBlockContext(channel: c, order: kStrategyOrder[kEncStrategyDCT8])
        }
        let blockCtx16: [Int] = [1, 0, 2].reduce(into: [Int](repeating: 0, count: 3)) {
            out, c in
            out[c] = encBlockContext(channel: c, order: kStrategyOrder[kEncStrategyDCT16])
        }

        // Per-group scratch, in CELL-MAJOR slot order:
        //     cell = (byl >> 1) * cellsX + (bxl >> 1)
        //     slot = cell * 4 + (byl & 1) * 2 + (bxl & 1)
        // A DCT8 block's 64 coefficients live at `slot * 64`; a DCT16
        // varblock's 256 live at its top-left block's `slot * 64` — which is
        // exactly the four consecutive slots of its own 2x2 cell. So one flat
        // buffer holds either choice with no aliasing, and committing a DCT16
        // simply overwrites the four DCT8 blocks it replaces. Sized to the
        // largest possible group (bgDim x bgDim blocks).
        let maxCellsX = divCeil(bgDim, 2)
        let maxSlots = maxCellsX * maxCellsX * 4
        func rawScratchF(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        let gcY = rawScratchF(maxSlots * 64)
        let gcX = rawScratchF(maxSlots * 64)
        let gcB = rawScratchF(maxSlots * 64)
        let gRecY = rawScratchF(maxSlots * 64)
        let gQY = UnsafeMutablePointer<Int32>.allocate(capacity: maxSlots * 64)
        gQY.initialize(repeating: 0, count: maxSlots * 64)
        let gScaledDequant = rawScratchF(maxSlots)
        // One candidate DCT16 varblock, all three channels (the cost model
        // needs chroma too — see VarDCTStrategy.swift).
        let t16Y = rawScratchF(256)
        let t16X = rawScratchF(256)
        let t16B = rawScratchF(256)
        defer {
            gcY.deallocate()
            gcX.deallocate()
            gcB.deallocate()
            gRecY.deallocate()
            gQY.deallocate()
            gScaledDequant.deallocate()
            t16Y.deallocate()
            t16X.deallocate()
            t16B.deallocate()
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

            let tilesX = divCeil(gw, kColorTileDimInBlocks)
            let tilesY = divCeil(gh, kColorTileDimInBlocks)
            var tileSumXY = [Double](repeating: 0, count: tilesX * tilesY)
            var tileSumBY = [Double](repeating: 0, count: tilesX * tilesY)
            var tileSumYY = [Double](repeating: 0, count: tilesX * tilesY)
            let cellsX = divCeil(gw, 2)
            let cellsY = divCeil(gh, 2)
            // `cellUse16[cell]` is the whole of this group's varblock layout:
            // a set cell is one DCT16 varblock at its (even, even) top-left
            // block, every other block is its own DCT8 varblock. Aligning
            // DCT16 to even block positions makes the decoder's raster walk
            // unambiguous — the first block it reaches in a cell is always the
            // top-left — and group origins are multiples of bgDim (32), so
            // group-local and frame-global parity agree.
            var cellUse16 = [Bool](repeating: false, count: cellsX * cellsY)
            @inline(__always) func cellOf(_ bxl: Int, _ byl: Int) -> Int {
                (byl >> 1) * cellsX + (bxl >> 1)
            }
            @inline(__always) func slotOf(_ bxl: Int, _ byl: Int) -> Int {
                cellOf(bxl, byl) * 4 + (byl & 1) * 2 + (bxl & 1)
            }

            // ---- Pass 1a: forward DCT8 of every block plus its adaptive
            // quant value (E5b). Order-insensitive (per-block scratch only).
            var blockQuant = [Int32](repeating: params.quantField, count: gw * gh)
            for byl in 0..<gh {
                let by = by0 + byl
                for bxl in 0..<gw {
                    let bx = bx0 + bxl
                    let base = slotOf(bxl, byl) * 64
                    let px = by * 8 * pw + bx * 8
                    planeY.withUnsafeBufferPointer {
                        forwardDCT8(pixels: $0.baseAddress! + px, stride: pw, out: gcY + base)
                    }
                    planeX.withUnsafeBufferPointer {
                        forwardDCT8(pixels: $0.baseAddress! + px, stride: pw, out: gcX + base)
                    }
                    planeB.withUnsafeBufferPointer {
                        forwardDCT8(pixels: $0.baseAddress! + px, stride: pw, out: gcB + base)
                    }
                    blockQuant[byl * gw + bxl] = encAdaptiveQuant(
                        gcY, base: base, baseQuant: params.quantField)
                }
            }

            // ---- Pass 1b (E5e): per-cell strategy choice. A DCT16 is only a
            // candidate where both of its blocks fit inside the AC GROUP —
            // `bxl + 2 <= gw`, `byl + 2 <= gh` — which is simultaneously the
            // image-edge and DC-group constraints decodeAcMetadataGroup
            // enforces (AC groups are 32 blocks, DC groups 256, so AC groups
            // nest exactly), and is required anyway because decodeACGroupPass
            // writes the non-zero prediction plane at every covered block of
            // its own group-sized plane.
            if kEncDCT16Enabled && allowDCT16 {
                for cy in 0..<cellsY {
                    let byl = cy * 2
                    if byl + 2 > gh { continue }
                    for cx in 0..<cellsX {
                        let bxl = cx * 2
                        if bxl + 2 > gw { continue }
                        // One quant step for both candidates: a DCT16 varblock
                        // can carry only one quant value anyway, and comparing
                        // two candidates under different steps is not a
                        // comparison.
                        let qAgg = encCellQuant(blockQuant, gw: gw, bxl: bxl, byl: byl)
                        let sd = invGlobalScale / Float(qAgg)
                        let lambda =
                            kRDLambda0 * kEncStratLambdaScale * kEncStratRefEnergy * sd * sd
                        let base = slotOf(bxl, byl) * 64
                        let srcPx = (by0 + byl) * 8 * pw + (bx0 + bxl) * 8
                        planeY.withUnsafeBufferPointer {
                            forwardDCT16(pixels: $0.baseAddress! + srcPx, stride: pw, out: t16Y)
                        }
                        planeX.withUnsafeBufferPointer {
                            forwardDCT16(pixels: $0.baseAddress! + srcPx, stride: pw, out: t16X)
                        }
                        planeB.withUnsafeBufferPointer {
                            forwardDCT16(pixels: $0.baseAddress! + srcPx, stride: pw, out: t16B)
                        }
                        let cost16 = encStrategyACCost(
                            cX: t16X, cY: t16Y, cB: t16B, table: tab16, order: ord16,
                            size: 256, covered: 4, scaledDequant: sd, lambda: lambda)
                        var cost8: Float = 0
                        for s in 0..<4 {
                            let off = base + s * 64
                            cost8 += encStrategyACCost(
                                cX: gcX + off, cY: gcY + off, cB: gcB + off,
                                table: tab8, order: ord8, size: 64, covered: 1,
                                scaledDequant: sd, lambda: lambda)
                        }
                        guard cost16 < cost8 else { continue }
                        cellUse16[cy * cellsX + cx] = true
                        anyDCT16 = true
                        // Commit: the 16x16 transform of each channel replaces
                        // the four 8x8 blocks it covers, in place — those four
                        // slots ARE this cell's slots.
                        (gcY + base).update(from: t16Y, count: 256)
                        (gcX + base).update(from: t16X, count: 256)
                        (gcB + base).update(from: t16B, count: 256)
                    }
                }
            }

            // ---- Pass 1c: per VARBLOCK — placement metadata, the quant
            // field, DC, Y AC quantization + its reconstructed value, and each
            // color tile's least-squares CfL sums (E5c). Order-insensitive:
            // it writes only per-varblock scratch (indexed by group-local
            // position, not visitation order), the frame-wide planes at its
            // own blocks, and per-TILE accumulators; it emits no tokens. Kept
            // in raster order purely for simplicity.
            for byl in 0..<gh {
                let by = by0 + byl
                for bxl in 0..<gw {
                    let use16 = cellUse16[cellOf(bxl, byl)]
                    if use16 && ((bxl | byl) & 1) != 0 { continue }  // covered, not first
                    let bx = bx0 + bxl
                    let cov = use16 ? 2 : 1  // covered blocks per axis
                    let size = use16 ? 256 : 64
                    let base = slotOf(bxl, byl) * 64

                    // One quant value per varblock: decodeAcMetadataGroup
                    // fills every covered block with the single coded value.
                    let quant =
                        use16
                        ? encCellQuant(blockQuant, gw: gw, bxl: bxl, byl: byl)
                        : blockQuant[byl * gw + bxl]
                    let scaledDequant = invGlobalScale / Float(quant)
                    gScaledDequant[slotOf(bxl, byl)] = scaledDequant

                    // Placement, mirroring decodeAcMetadataGroup's own fill.
                    for dy in 0..<cov {
                        for dx in 0..<cov {
                            let p = (by + dy) * bw + (bx + dx)
                            frameStrategy[p] = UInt8(
                                use16 ? kEncStrategyDCT16 : kEncStrategyDCT8)
                            frameIsFirst[p] = (dx | dy) == 0
                            blockQuantField[p] = quant
                        }
                    }

                    // DC. For DCT8 the DC coefficient IS the block mean. For
                    // DCT16 the four DC-image samples under the varblock are
                    // the exact inverse of the decoder's `insertLLF` on the
                    // transform's 2x2 corner (encDCT16DCFromLLF) — they are
                    // NOT the four sub-blocks' means, and the resample scales
                    // are what makes the difference.
                    if use16 {
                        let dY = encDCT16DCFromLLF(gcY + base)
                        let dX = encDCT16DCFromLLF(gcX + base)
                        let dB = encDCT16DCFromLLF(gcB + base)
                        let llfY = [dY.0, dY.1, dY.2, dY.3]
                        let llfX = [dX.0, dX.1, dX.2, dX.3]
                        let llfB = [dB.0, dB.1, dB.2, dB.3]
                        for i in 0..<4 {
                            let p = (by + i / 2) * bw + (bx + i % 2)
                            let vY = Int32((llfY[i] / facY).rounded())
                            let recDCY = Float(vY) * facY
                            qDCY[p] = vY
                            qDCX[p] = Int32((llfX[i] / facX).rounded())
                            qDCB[p] = Int32(((llfB[i] - cflBDC * recDCY) / facB).rounded())
                        }
                    } else {
                        let p = by * bw + bx
                        let vY = Int32((gcY[base] / facY).rounded())
                        let vX = Int32((gcX[base] / facX).rounded())
                        let recDCY = Float(vY) * facY
                        let vB = Int32(((gcB[base] - cflBDC * recDCY) / facB).rounded())
                        qDCY[p] = vY
                        qDCX[p] = vX
                        qDCB[p] = vB
                    }

                    // Y AC quantization (never CfL-corrected — Y is the
                    // reference channel) and its reconstructed (bias-
                    // adjusted) value, both cached for pass 2, plus this
                    // varblock's contribution to its color tile's CfL fit.
                    // A DCT16 varblock is 2x2 blocks aligned to even
                    // positions, so it never straddles a color tile (8 blocks).
                    let tileIdx =
                        (byl / kColorTileDimInBlocks) * tilesX + (bxl / kColorTileDimInBlocks)
                    let table = use16 ? tab16 : tab8
                    for k in 0..<size where !encIsLLF(size: size, k) {
                        let yMulK = table[size + k] * scaledDequant
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

            // ---- Pass 2: X/B AC quantization with each varblock's tile CfL,
            // then token emission — STRICT raster order (byl outer, bxl
            // inner, across the FULL group, skipping blocks a varblock
            // already covers), matching decodeACGroupPass's own traversal
            // exactly. This is the one order the decoder actually cares
            // about; pass 1 above may run in any order precisely because it
            // never emits tokens.
            for byl in 0..<gh {
                for bxl in 0..<gw {
                    let use16 = cellUse16[cellOf(bxl, byl)]
                    if use16 && ((bxl | byl) & 1) != 0 { continue }
                    let cov = use16 ? 2 : 1
                    let covered = cov * cov
                    let log2Covered = use16 ? 2 : 0
                    let size = covered * 64
                    let base = slotOf(bxl, byl) * 64
                    let scaledDequant = gScaledDequant[slotOf(bxl, byl)]
                    let table = use16 ? tab16 : tab8
                    let order = use16 ? ord16 : ord8
                    let blockCtxOf = use16 ? blockCtx16 : blockCtx8
                    let tileIdx = (byl / kColorTileDimInBlocks) * tilesX + (bxl / kColorTileDimInBlocks)
                    let xCC = Float(groupYtoX[tileIdx]) * kColorScale
                    let bCC = 1 + Float(groupYtoB[tileIdx]) * kColorScale

                    var nzY = 0
                    var nzX = 0
                    var nzB = 0
                    for k in 0..<size where !encIsLLF(size: size, k) {
                        let yq = gQY[base + k]  // already RD-refined in pass 1c
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
                        let bMulK = table[2 * size + k] * scaledDequant
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
                        // The decoder stores ceil(nz / covered) at EVERY block
                        // the varblock covers, so the neighbours' predictions
                        // see a per-8x8-block density (decodeACGroupPass).
                        let stored = Int32((totalNZ + covered - 1) >> log2Covered)
                        for dy in 0..<cov {
                            for dx in 0..<cov { nzeros[c][(byl + dy) * gw + bxl + dx] = stored }
                        }

                        let histoOffset = encZeroDensityOffset(blockCtx: blockCtx)
                        var prev = totalNZ > size / 16 ? 0 : 1
                        var nz = totalNZ
                        var k = covered
                        while k < size && nz != 0 {
                            let ctx = histoOffset
                                + encZeroDensityContext(
                                    nonzerosLeft: nz, k: k, covered: covered,
                                    log2Covered: log2Covered, prev: prev)
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

        // ---- Modular streams: the DC image (channels in modular order
        // Y, X, B) and the AC metadata per DC group.
        //
        // E5k: THE GLOBAL TREE IS LEARNED, not a fixed single-leaf gradient.
        // On smooth content the DC image is where the bytes are — 79% of a
        // grad_smooth q50 file, 49% of photo_sky at q90 — and coding it with
        // one predictor and one context left it at ~1.7 bits/sample for what is
        // essentially a ramp. This project already owns a much better modular
        // coder (E4a's learned MA trees, the machinery the LOSSLESS encoder
        // uses to beat cjxl -e7); the lossy path simply was not reaching for
        // it. Same lesson as E5j: the win was in using what we had.
        //
        // Training samples the DC planes only. They dominate the byte count,
        // and the AC-metadata channels (CfL maps, ACS/quant rows, the all-zero
        // sharpness field) have such different statistics that including them
        // mostly buys splits that serve a few hundred bytes. The tree still
        // CODES them — correctness does not depend on what it was trained on,
        // only the density does.
        let tree: [MATreeNode] = {
            guard learnDCTree else {
                return [
                    MATreeNode(
                        property: -1, splitVal: 0, lchild: 0, rchild: 0,
                        predictor: 5, predictorOffset: 0, multiplier: 1)
                ]
            }
            let planeSamples = bw * bh
            // The 400k sample target the LOSSLESS encoder uses is calibrated
            // for megapixel-scale planes; on a DC image (bw*bh, e.g. ~9k
            // samples for a 0.7 MP frame) it never engages and the stride
            // collapses to 1, so learnTree's greedy split search visits EVERY
            // DC sample. That, not the race's pricing encodes, is what made
            // E5k roughly double encode time — verified by measurement: cutting
            // the pricing cost recovered only ~4%.
            //
            // A decision tree over ~10 properties and a handful of candidate
            // predictors does not need tens of thousands of samples to rank
            // splits; the target here is deliberately far lower, and the size
            // effect is measured rather than assumed.
            let strideStep = max(1, (planeSamples * 3) / kEncDCTreeTrainingTarget)
            var training = TreeTrainingSet()
            for (chan, plane) in [(0, qDCY), (1, qDCX), (2, qDCB)] {
                plane.withUnsafeBufferPointer { buf in
                    training.collect(
                        plane: buf, width: bw, x0: 0, y0: 0, gw: bw, gh: bh,
                        chan: chan, stride: strideStep)
                }
            }
            let fixed = [
                MATreeNode(
                    property: -1, splitVal: 0, lchild: 0, rchild: 0,
                    predictor: 5, predictorOffset: 0, multiplier: 1)
            ]
            let learned = learnTree(training)
            guard !learned.isEmpty, learned.count > 1 else { return fixed }
            // RACE THEM ON MEASURED COST — but see the KNOWN LIMITATION
            // below, because this race is not yet complete.
            //
            // A learned tree is not free: it is serialized into LfGlobal and
            // every extra leaf adds an ANS histogram to the residual header.
            // The race prices both candidates on real serialized bytes and
            // keeps the smaller, the same way E5j chooses its context map.
            //
            // KNOWN LIMITATION, with the mechanism measured rather than
            // guessed: pricing covers the DC planes ONLY, while the real
            // encoder shares one histogram set across the DC *and* the
            // AC-metadata streams. With the single-leaf tree everything shared
            // one context anyway, so nothing was lost; with a learned tree the
            // contexts are DC-specialised and the metadata tokens land in those
            // same contexts and skew the histograms — degrading the very DC
            // they were fitted to. The estimate cannot see that, so it is
            // optimistic. Measured on gray_city q50, where the race wrongly
            // picks the learned tree:
            //     LfGlobal    30 B -> 205 B   (tree + histogram header)
            //     DC groups 6352 B -> 6781 B  (the DC itself got WORSE)
            //     total    15772 B -> 16376 B (+3.8%)
            // Every other measured case wins, several by a lot (grad_smooth q50
            // -29.4%, photo_sky q30 -27.3%, synth_text q30 -16.7%), so this
            // ships with the regression documented rather than withheld. The
            // fix is to price both candidates over the DC *and* metadata token
            // streams — i.e. build both token sets and compare them whole —
            // which is a refactor of the stream-building block, tracked
            // separately.
            let costFixed = encDCTreeCost(
                tree: fixed, planes: [(0, qDCY), (1, qDCX), (2, qDCB)], bw: bw, bh: bh)
            let costLearned = encDCTreeCost(
                tree: learned, planes: [(0, qDCY), (1, qDCX), (2, qDCB)], bw: bw, bh: bh)
            return costLearned < costFixed ? learned : fixed
        }()
        var dcTokens: [[EncToken]] = []
        var metaTokens: [[EncToken]] = []
        /// Varblocks placed per DC group — the `count` its AcMetadata stream
        /// codes, and the width of that stream's (count x 2) ACS+QF channel.
        var dcGroupVarblocks = [Int](repeating: 0, count: dim.numDCGroups)
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
            // sharpness (zeros). `count` is the number of varblocks whose
            // top-left block lies in this DC group's rect (E5e: no longer
            // rw*rh, since a DCT16 covers four blocks with one entry).
            let crW = divCeil(rw, kColorTileDimInBlocks)
            let crH = divCeil(rh, kColorTileDimInBlocks)
            var count = 0
            for iy in 0..<rh {
                for ix in 0..<rw where frameIsFirst[(y0 + iy) * bw + (x0 + ix)] { count += 1 }
            }
            dcGroupVarblocks[dcg] = count
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
            // Row-major (iy, ix) over the DC group's rect, SKIPPING blocks an
            // earlier varblock already covers — the exact walk
            // decodeAcMetadataGroup performs, so `num` there and `num` here
            // index the same (count x 2) channel entries. Row 0 is the raw AC
            // strategy, row 1 the quant field.
            var num = 0
            for iy in 0..<rh {
                for ix in 0..<rw {
                    let p = (y0 + iy) * bw + (x0 + ix)
                    if !frameIsFirst[p] { continue }
                    acsQF[num] = Int32(frameStrategy[p])
                    // decoder: quant = 1 + clamp(coded, 0, 255)
                    acsQF[count + num] = blockQuantField[p] - 1
                    num += 1
                }
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

        // ---- Extra channels (E5g). In a VarDCT frame the ECs are a MODULAR
        // image carried in the same streams as the DC/metadata data and coded
        // with the same global tree — so alpha is lossless while color is
        // lossy. Geometry mirrors decodeExtraChannelGlobal: ec_upsampling 1
        // and color upsampling 1 give shift 0 and full-frame dimensions.
        // Split mirrors modularDecode's maxChanSize == groupDim: channels no
        // larger than group_dim ride in the LfGlobal stream, bigger ones are
        // split across the AC-group sections (the same rects
        // decodeModularGroupImage computes, tile = groupDim).
        let ecCount = image.extraChannels
        let ecGlobalFits = ecCount > 0 && w <= dim.groupDim && h <= dim.groupDim
        var ecGlobalTokens: [EncToken] = []
        var ecGroupTokens = [[EncToken]](repeating: [], count: dim.numGroups)
        if ecCount > 0 {
            let ecPlanes = (0..<ecCount).map { image.planes[image.colorChannels + $0] }
            if ecGlobalFits {
                for (chan, plane) in ecPlanes.enumerated() {
                    plane.withUnsafeBufferPointer { buf in
                        tokenizeChannelWithTree(
                            into: &ecGlobalTokens, plane: buf, width: w,
                            x0: 0, y0: 0, gw: w, gh: h,
                            chan: chan, streamID: 0, tree: tree)
                    }
                }
            } else {
                for g in 0..<dim.numGroups {
                    let gx0 = (g % dim.xsizeGroups) * dim.groupDim
                    let gy0 = (g / dim.xsizeGroups) * dim.groupDim
                    let gw = min(dim.groupDim, w - gx0)
                    let gh = min(dim.groupDim, h - gy0)
                    guard gw > 0, gh > 0 else { continue }
                    // ecStreamID(g, 0) = 1 + 3*numDCGroups + 17 + g
                    let sid = 1 + 3 * dim.numDCGroups + 17 + g
                    for (chan, plane) in ecPlanes.enumerated() {
                        plane.withUnsafeBufferPointer { buf in
                            tokenizeChannelWithTree(
                                into: &ecGroupTokens[g], plane: buf, width: w,
                                x0: gx0, y0: gy0, gw: gw, gh: gh,
                                chan: chan, streamID: sid, tree: tree)
                        }
                    }
                }
            }
        }

        // ---- Entropy back-ends: the shared modular machinery for the global
        // tree + DC/metadata residuals; the local AC coder for coefficients.
        // The EC streams are appended only when there are extra channels, so an
        // ordinary lossy encode builds the exact same coder it always did (the
        // size goldens are the gate on that).
        let residual = ANSEntropyEncoder(
            numContexts: treeNumLeaves(tree),
            streams: ecCount > 0
                ? dcTokens + metaTokens + [ecGlobalTokens] + ecGroupTokens
                : dcTokens + metaTokens)
        let acCoder = ACEntropyCoder.choose(numContexts: kNumACContexts, streams: acTokens)

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
            // decodeExtraChannelGlobal reads the EC modular image here, right
            // after the histograms. modularDecode always consumes a
            // GroupHeader; the channel data itself is present only for
            // channels <= group_dim (numChans > 0), so a large-EC frame writes
            // the header and leaves the samples to the AC groups.
            if ecCount > 0 {
                s.writeBool(true)  // use_global_tree
                s.writeBool(true)  // wp_header: all_default
                s.write(0, 2)  // nb_transforms = 0
                if ecGlobalFits { residual.encodeStream(s, ecGlobalTokens) }
            }
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
            // count - 1, in ceilLog2(rw*rh) bits (decodeAcMetadataGroup).
            if nbits > 0 { s.write(UInt64(dcGroupVarblocks[dcg] - 1), nbits) }
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
            // Then this group's slice of the EC modular image, which
            // decodeACGroupPass reads from the same reader (only for channels
            // bigger than group_dim — smaller ones already rode in LfGlobal).
            if ecCount > 0 && !ecGlobalFits {
                s.writeBool(true)  // use_global_tree
                s.writeBool(true)  // wp_header: all_default
                s.write(0, 2)  // nb_transforms = 0
                residual.encodeStream(s, ecGroupTokens[g])
            }
        }

        // ---- Assembly: headers, frame header, TOC, sections (the modular
        // encoder's exact layout; section roles per sectionRole()).
        let head = BitWriter()
        HeaderWriter.writeCodestreamHeadersXYB(
            head, width: UInt32(w), height: UInt32(h),
            bitsPerSample: UInt32(image.bitsPerSample),
            alphaChannels: image.extraChannels)
        writeFrameHeader(head, numExtraChannels: image.extraChannels, filters: filters)

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
            return (head.finalize(), anyDCT16, filters)
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
        return (head.finalize(), anyDCT16, filters)
    }

    /// FrameHeader for the E5a lossy shape — dual of `FrameHeader.init` with
    /// xyb_encoded metadata: regular VarDCT frame, XYB (implicit),
    /// kSkipAdaptiveDCSmoothing, no upsampling, default QM scales, single
    /// pass, full canvas, replace blending, last frame, no name, loop
    /// filters off.
    /// Which restoration filters the frame asks the decoder to run (E5h). The
    /// encoder races these against each other on measured output, so both a
    /// filtered and an unfiltered candidate must be expressible.
    struct EncFilterConfig: Equatable {
        let gaborish: Bool
        let epfIters: UInt32

        /// Filters disabled — every frame the encoder wrote before E5h.
        static let off = EncFilterConfig(gaborish: false, epfIters: 0)
        /// libjxl's own defaults, and the bundle's all_default shape.
        static let defaultOn = EncFilterConfig(gaborish: true, epfIters: 2)
        /// Gaborish alone: useful because it is the half of the pair the
        /// encoder can compensate for exactly.
        static let gaborishOnly = EncFilterConfig(gaborish: true, epfIters: 0)
    }

    private static func writeFrameHeader(
        _ w: BitWriter, numExtraChannels: Int = 0, filters: EncFilterConfig = .off
    ) {
        w.writeBool(false)  // all_default
        w.write(0, 2)  // frame_type: regular (U32 Val selector)
        w.writeBool(false)  // encoding: VarDCT
        w.writeU64(128)  // flags: kSkipAdaptiveDCSmoothing
        // (xyb_encoded => color transform is XYB, nothing serialized)
        w.write(0, 2)  // upsampling = 1 (U32 Val selector)
        for _ in 0..<numExtraChannels {
            w.write(0, 2)  // ec_upsampling = 1 (U32 Val selector)
        }
        // (VarDCT => no group_size_shift; group_size_shift stays default 1)
        w.write(2, 3)  // x_qm_scale = 2 (xDmMul == 1)
        w.write(2, 3)  // b_qm_scale = 2 (bDmMul == 1)
        w.write(0, 2)  // num_passes = 1 (U32 Val selector)
        w.writeBool(false)  // custom_size_or_origin
        w.write(0, 2)  // blending mode: replace (U32 Val selector)
        // Then one ec_blending_info per extra channel (parseBlendingInfo is
        // called numExtraChannels extra times). Mode 0 (replace) on a non-
        // partial frame serializes nothing beyond the selector: no
        // alpha_channel/clamp (those need a blend mode involving alpha, or
        // kMul) and no source.
        for _ in 0..<numExtraChannels {
            w.write(0, 2)  // ec blending mode: replace
        }
        w.writeBool(true)  // is_last
        // (is_last => no save_as_reference; not referenceable => no save_before)
        w.write(0, 2)  // name length = 0 (U32 Val selector)
        // Loop filter. The bundle's all_default shape is exactly libjxl's
        // default (gaborish ON, epf_iters 2), so that combination costs a
        // single bit; anything else is written explicitly.
        if filters == .defaultOn {
            w.writeBool(true)  // loop filter all_default: gab on, epf_iters 2
        } else {
            w.writeBool(false)  // not all_default
            w.writeBool(filters.gaborish)
            // (gaborish on => gab_custom bit; we always use the default
            // weights, so it stays false)
            if filters.gaborish { w.writeBool(false) }
            w.write(UInt64(filters.epfIters), 2)
            if filters.epfIters > 0 {
                w.writeBool(false)  // epf_sharp_custom (non-modular)
                w.writeBool(false)  // epf_weight_custom
                w.writeBool(false)  // epf_sigma_custom
            }
            w.writeU64(0)  // loop-filter extensions
        }
        w.writeU64(0)  // frame-header extensions
    }

    /// Real serialized cost of coding the DC planes under `tree`: the tree's
    /// own serialization, the residual ANS histogram header (one histogram per
    /// leaf), and the payload. Exact — it runs the real writers over the DC,
    /// which is small relative to the AC work, so racing two trees is cheap.
    private static func encDCTreeCost(
        tree: [MATreeNode], planes: [(Int, [Int32])], bw: Int, bh: Int
    ) -> Int {
        let tTokens = treeTokens(tree)
        let tw = BitWriter()
        let tEnc = PrefixEntropyEncoder(numContexts: 6, streams: [tTokens])
        tEnc.writeHeader(tw)
        tEnc.encodeStream(tw, tTokens)
        var toks: [EncToken] = []
        for (chan, plane) in planes {
            plane.withUnsafeBufferPointer { buf in
                tokenizeChannelWithTree(
                    into: &toks, plane: buf, width: bw, x0: 0, y0: 0, gw: bw, gh: bh,
                    chan: chan, streamID: 1, tree: tree)
            }
        }
        let coder = ANSEntropyEncoder(numContexts: treeNumLeaves(tree), streams: [toks])
        let pw = BitWriter()
        coder.writeHeader(pw)
        coder.encodeStream(pw, toks)
        return tw.finalize().count + pw.finalize().count
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
    /// JXL: 1…16-bit integer samples, 1 (replicated to RGB) or 3 color
    /// channels, and any number of integer extra channels. `quality` 1…100
    /// (default 90) maps to a uniform quantization step scale — see
    /// `VarDCTEncoder.quantParams`. The output decodes with this decoder and
    /// djxl. Current shape (E5a–E5g): DCT8 + DCT16 variable-size transforms
    /// chosen per aligned 2x2 block cell by rate-distortion, a per-block
    /// adaptive AC quant field, a per-color-tile chroma-from-luma search, RD
    /// coefficient quantization, and a frame-level DCT8-vs-DCT16 race.
    ///
    /// Extra channels (alpha) are carried as a MODULAR image inside the VarDCT
    /// frame — the format gives them no lossy coding path — so **alpha is
    /// lossless while the color planes are lossy**. Float samples are still
    /// rejected, matching the decoder, which rejects float extra channels in a
    /// VarDCT frame outright.
    /// `effort` 1 skips learning the global modular tree: roughly half the
    /// encode time, at 20-30% larger files on smooth content. 2 (default)
    /// learns it.
    public static func encodeLossy(
        image: JXLDecodedImage, quality: Int = 90, effort: Int = 2
    ) throws -> [UInt8] {
        try VarDCTEncoder.encodeLossy(image, quality: quality, effort: effort)
    }
}
