# JXL Encoder Design

How a JPEG XL *encoder* should be built in this codebase — scope, architecture,
Swift idioms, macOS performance, and above all the correctness discipline that
made the decoder trustworthy. Written before any encoder code exists; this is
the plan of record.

## 1. Why, and what kind of encoder

The decoder is feature-complete (25/26 conformance, oracle-validated). An
encoder turns the project from a viewer's engine into a full codec: `jxl
encode` for PNG/PPM→JXL, round-trip tooling, and a real test of whether the
codebase's abstractions were honest (an encoder is the harshest consumer of a
decoder's model of the format).

**Scope decision: lossless Modular first, and possibly only.** The reasoning:

- *Lossless is provably correct.* Encode → decode must reproduce input bytes
  exactly, under BOTH our decoder and djxl. There is no perceptual judgment
  anywhere; every property we care about is machine-checkable. This extends
  the project's oracle discipline unchanged.
- *Lossy is a research project wearing an engineering costume.* A valid VarDCT
  encoder is easy (fixed DCT8 strategy, uniform quant); a *good* one is
  psychovisual modeling (adaptive quantization, AC strategy search, chroma-
  from-luma fitting, XYB error metrics) — years of libjxl's tuning. A naive
  lossy encoder would produce files 2-3× larger than cjxl at equal quality,
  which serves nobody. If lossy ever happens, it is milestone E5, explicitly
  labeled "baseline quality," and gated on butteraugli-style metrics — not
  before.
- *JPEG recompression (jbrd) is a plausible E6*: bounded, byte-exactly
  verifiable (recompress → reconstruct → original JPEG bytes), and genuinely
  useful. But it depends on VarDCT coefficient *writing*, so it follows lossy
  plumbing.

Compression-ratio target for lossless: within ~10% of `cjxl -e 2..3` on the
fixture corpus at the default effort. Matching `-e 7+` (full MA-tree search,
palette heuristics) is a stretch goal, not a gate.

## 2. Architecture

New subtree mirroring the decoder's layout — encode stages live beside the
decode stages whose formats they must mirror:

```
Sources/JXLCore/
  Bitstream/ BitWriter.swift          — LSB-first bit packing (dual of BitReader)
  Entropy/   EntropyEncoder.swift     — histogram build, clustering, ANS/prefix writing
             TokenBuffer.swift        — per-group token accumulation
  Modular/   ModularEncoder.swift     — prediction, residual tokenization, group split
             ForwardTransforms.swift  — forward RCT (palette/squeeze later)
  Frame/     FrameEncoder.swift       — frame header, TOC assembly, section stitching
  Headers/   (extend)                 — write paths for SizeHeader/ImageMetadata
  Container/ (extend)                 — jxlc container writing (or bare codestream)
  JXLEncoder.swift                    — public API: JXL.encode(image:options:)
```

**The single most important structural idea: shared prediction.** The encoder
computes `residual = actual − predicted` with the *decoder's own* predictor
code — `predictOne`, `WPState`, the MA-tree property computation, the
fast-track clamp semantics. This is not code reuse for economy; it is
correctness by construction. Every subtle decode-side behavior we fought for
(uint32 error-weight wrap, gradient clamp ranges, property ordering) is
automatically consistent because there is one implementation. Encode-side
divergence from decode-side prediction is the classic codec bug class; this
design makes it structurally impossible. Where a decode-side type is hot-loop
specialized (raw pointers), the encoder calls the same entry points — the
shapes were built for this.

**Inverse machinery stays decode-only; forwards are new.** Forward RCT is ~20
lines (the YCoCg-style lifting is exactly invertible in integers — property
tests must verify forward∘inverse = identity over the full sample range, not
just fixture data). Palette and Squeeze forwards are *selection problems*
(when to apply, which colors) and land in E3/E4, not E1.

**Entropy encoding is genuinely new code:**
- *Tokenization*: hybrid-uint (token, nbits, bits) via the existing
  `HybridUintConfig` logic run forward. Tokens accumulate per (context,
  group) into flat `TokenBuffer`s.
- *Histograms*: count per context, cluster contexts (start: identity
  clustering — one histogram per context — valid and simple; real clustering
  is an E4 quality lever), normalize to the 12-bit ANS table sum (4096) with
  the same normalization the decoder's `initAliasTable` expects.
- *rANS writing*: encode tokens in REVERSE order (rANS streams decode
  forward only if encoded backward), 32-bit state, 16-bit renormalization —
  the exact dual of `readSymbolANS`. Because our own decoder validates the
  final-state checksum, every in-suite round-trip exercises this.
- *Prefix-code alternative*: the format allows prefix codes instead of ANS;
  they are simpler to write (canonical code construction, forward-order
  emission) and are a legitimate E1 starting point (cjxl's fastest efforts
  use them). Plan: E1 ships prefix codes, E2 adds ANS, measured against each
  other on the corpus.

**Section/TOC assembly**: each group encodes to its own `BitWriter` buffer
concurrently; the frame assembler then writes the TOC (sizes now known) and
concatenates. This mirrors the decoder's section model exactly and gives
group-parallel encoding for free. Single-group images collapse to the
coalesced section layout the decoder already understands.

**Color handling**: E1 emits *enumerated* color encodings only (sRGB or the
input's declared space) with `want_icc = false`. Writing ICC profiles
requires Brotli *compression* (we only have decompression) — a deliberate
non-goal until something needs it.

**Public API and CLI:**
```swift
let jxl = try JXL.encode(image: JXLDecodedImage, options: JXLEncodeOptions())
// options: effort (1-3 initially), container: Bool, colorEncoding override
```
CLI: `jxl encode in.ppm out.jxl [effort]` — PPM/PGM/PAM/PFM readers are the
duals of the writers the CLI already has.

## 3. Swift idioms (carried over from the decoder, hard-won)

- **Value types for headers, `final class` for stateful coders** (BitWriter,
  ANS encoder state), exactly like the decode side.
- **Hot loops on raw pointers.** The per-pixel encode loop (predict →
  residual → tokenize) is the mirror of `decodeChannel` and inherits its
  rules: property vectors as `UnsafeMutablePointer`, no `inout [T]` per
  pixel, no array subscripts in the pixel loop, tables as process-lifetime
  pointers. The ARCHITECTURE.md "Decode performance" lessons apply verbatim.
- **Nothing refcounted crosses into `concurrentPerform` workers.** Per-group
  encoding passes raw pointers + scalars in, returns owned buffers out.
- **COW discipline**: token buffers are detached to locals and written
  through `withUnsafeMutableBufferPointer`; conditional provenance defeats
  uniqueness analysis (learned twice already).
- **No dependencies.** Pure Swift + Foundation, like everything else.

## 4. macOS performance posture

- **Group-parallel encode** via `concurrentPerform` (the natural unit; same
  as decode). Expectation: lossless encode within ~2× of decode time at
  effort 1-2 (prediction is the same cost; tokenize+ANS-write replaces
  ANS-read; histogram passes add one traversal).
- **Two-pass structure per group**: pass 1 predicts + tokenizes (collecting
  histograms), pass 2 writes ANS. Token buffers are flat `[UInt32]`-style
  storage, sized once — no per-token allocation.
- **Memory**: whole-image planes in, per-group buffers out; no streaming in
  v1 (the decoder is whole-buffer too). A 100MP lossless encode peaks at
  ~2.5× plane memory — acceptable for the CLI/app use case.
- **No GPU.** Encoding is branchy integer work (prediction, tokenization);
  nothing here is GPU-shaped. The display-arc Metal work stays display-only.
- **Bench gate from day one**: `jxl benchenc` mirroring `jxl bench`;
  encoded-size AND wall-time tracked per commit, both directions gated (a
  compression regression is a regression).

## 5. Correctness discipline (the non-negotiables)

The decoder's credibility came from oracle discipline; the encoder doubles it
because there are now two independent checkers:

1. **Round-trip, ours**: encode → our decoder → planes byte-identical to
   input. Every fixture, every effort, in-suite.
2. **Round-trip, theirs**: encode → `djxl` → byte-identical pixels. This is
   the *spec* check: it prevents the classic failure where encoder and
   decoder agree on a private dialect. Our decoder accepting a file proves
   nothing about validity; djxl accepting it does. (Also run djxl's strict
   final-state/ANS checks — they validate stream internals, not just pixels.)
3. **Determinism**: same input + options → identical bytes. Committed golden
   .jxl outputs for a few fixtures, byte-compared in-suite (goldens re-blessed
   only with an explicit commit noting why).
4. **Cross-decode of the corpus**: every committed fixture's *pixels*, when
   re-encoded and decoded by both decoders, byte-match the original decode.
5. **Property tests for forwards**: forward∘inverse = identity for RCT (all
   7 types × full Int32 range sampling), later palette/squeeze — not
   fixture-only.
6. **Encoder-input fuzzing**: random dimensions/bit-depths/plane contents
   (including adversarial: all-same, alternating extremes, out-of-range
   samples) → encode must either succeed with a valid round-trip or throw
   cleanly. Plus the existing decode-fuzz run over our encoded outputs.
7. **Size regression gate**: per-fixture encoded sizes recorded; a change
   that grows the corpus >1% fails the check unless the commit says why.

The rule that ties it together, inherited from the display arc: **verify at
the boundary the artifact crosses.** For the encoder that boundary is djxl —
every milestone lands with djxl round-trip proof, never just self-consistency.

## 6. Milestones

- **E0 — skeleton** ✅ (2026-07-20): BitWriter (+ exhaustive unit tests
  against BitReader: write→read identity for random field sequences),
  SizeHeader/ImageMetadata writers, bare-codestream assembly. The round-trip
  test caught a latent *decoder* bug (subnormal F16 headers).
- **E1 — minimum honest encoder** ✅ (2026-07-20): 8/16-bit RGB/gray
  lossless, single + multi group, single-leaf gradient tree, real canonical
  prefix codes (package-merge; both simple and complex serialization forms),
  forward YCoCg RCT, `jxl encode` CLI, size-golden gate. djxl byte-exact.
  Sizes landed *better* than planned: RGB natural fixtures already beat
  cjxl -e2 (prediction + real Huffman is most of e2's game).
- **E2 — real entropy** ✅ (2026-07-20): rANS (reverse-order stream writer,
  alias-table slot inversion, exact-precision histogram serialization at
  shift=13), selectable back-end (ANS default, prefix kept exercised).
  Gate met: 6MP photo within ~5% of cjxl -e2, small RGB fixtures at parity
  or better; the exception is 16-bit smooth synthetic content (~3×), which
  is a *modeling* gap (single context, no WP) owned by E4. Deferred from the
  original E2 scope, with reasons recorded: context clustering (pointless at
  one context — becomes real work when E4 grows the tree) and LZ77 emission
  (its natural wins — constant/synthetic regions — already cost ~nothing via
  the single-symbol ANS path; revisit with E4's graphics corpus).
- **E3 — full sample support** ✅ (2026-07-20, subagent in a jj workspace):
  float32 (identity bit-pattern path incl. NaN/Inf/subnormals; float16
  rejected — the decoder doesn't model the re-pack), alpha/extra channels
  (dim_shift 0, same-size), PAM/PFM CLI input. Found two wrap-semantics
  fixes full-range samples force: residuals truncate to Int32 BEFORE
  packSigned (mod-2^32 congruence is the round-trip invariant) and
  forwardYCoCg wraps every intermediate. All djxl byte-exact.
- **E4 — compression quality** (in progress; E4a ✅ 2026-07-21): learned MA
  trees over properties 0-14 with per-leaf stateless-predictor selection
  (cost = token entropy + raw extra bits), multi-histogram entropy
  (clustering ≤8 + context maps). **The 6MP bench photo now beats
  cjxl -e3** (10.05 vs 10.91 MB) — the "within ~10% of -e3" gate is
  already exceeded on photos. E4b (✅ 2026-07-21): WP predictor as a leaf
  candidate + property 15 (full-res state pass during training since the
  error window carries in scan order; wpClamp fast-track mirrored) and
  per-leaf multipliers (residual GCDs — the 16-bit smooth gap was scaled
  ramps, w40 1595 → 729 B vs cjxl 603; two-pass tokenization because
  multipliers change fast-track kernel selection, with a divisibility
  fallback). E4c (✅ 2026-07-21): global palette (≤256 colors, abort-early
  detection, encode-both-ways when eligible since RCT occasionally wins on
  small images — a 40-color test image lands 10× smaller than cjxl -e2's
  34.9 KB), effort levels (e1 fast = fixed gradient tree + RCT, 6MP 0.31 s
  wall; e2 default = everything, 1.31 s), and parallel encoding
  (training/tokenization/section entropy across groups via concurrentPerform
  under the decoder's no-refcounts rules; channel planes copied once into
  raw buffers). E4d (✅ 2026-07-22, two subagents in jj workspaces +
  encoder-input fuzzing in main): **squeeze** (responsive mode; forward
  transform derived as the exact invSqueeze inverse, layout produced by
  executing the decoder's own metaSqueeze, DC-group streams; the 6MP photo
  gets ~1% SMALLER with progressive decode as a bonus; float+squeeze
  rejected — diff/2 is not congruence-preserving mod 2^32) and a
  **byte-identical perf round**: 6MP e2 1.33 → 0.37 s wall (3.7×), e1
  0.27 → 0.11 s, proven by a 60-encode SHA256 battery. The new
  `Scripts/fuzz-encode.sh` (seeded random images → encode/decode bit-exact,
  all efforts/backends/squeeze) found a latent channel-index bug on its
  12th case: per-group streams number channels LOCALLY (decoder renumbers
  from beginC) — palette's meta channel shifted property 0 on the encode
  side only. The encoder is now **feature-complete for lossless**; open
  threads: palette∘squeeze composition, squeeze auto-off heuristic, E5
  lossy decision (design §7).
- **E5 — baseline lossy** (GO decision 2026-07-22, per §7's "decide with E4
  numbers in hand": the modular machinery lossy needs — trees, entropy
  writers, quantized-channel streams — is built and oracle-hardened, and
  the complete VarDCT decode pipeline is the dual to write against). XYB
  forward, fixed DCT8, quality knob; "valid, improving." Gate for every
  sub-milestone includes a CROSS-ORACLE check: our decoder and djxl must
  agree to high precision (>100 dB) on the same lossy file.
    - **E5a** (2026-07-22): uniform quant field. Baseline lossy end to end.
    - **E5b** (2026-07-22): adaptive per-block AC quant field from local
      luma-AC energy. Coarsen-only (measured: boosting flat blocks above
      baseline loses on gradient content). Photo +1.53 dB AND −5.1% size.
    - **E5c** (2026-07-23): per-color-tile chroma-from-luma search — the
      per-tile YtoX/YtoB maps (which E5a/E5b left at the base-0/base-1
      default) fitted by unweighted least squares of each block's forward
      X/B AC coefficients against its reconstructed Y AC. Two-pass AC walk
      (fit, then quantize+emit in raster order) so the emission order the
      decoder reads is untouched. Photo +0.46 dB AND −2.0% size; the 6 MP
      gradient/edge bench −7.1% size AND +6.5 dB (strong Y↔chroma
      correlation there). All cross-oracle ≥117 dB.
    - **E5d** (2026-07-23): RD (rate-distortion) coefficient quantization —
      per AC coefficient, minimize distortion + λ·rate over {naive, one step
      toward zero, zero} instead of round-to-nearest. The scaled inverse DCT
      is an isometry (per-coefficient pixel energy = 64 for all frequencies),
      so pixel MSE ∝ coefficient-space SE and a single λ (scaled ∝ mul² for
      quality-invariant drop behavior) suffices — no per-frequency weight.
      Evaluated as an RD *curve* (not single points — dropping coefficients
      trivially trades size for PSNR): λ₀=0.10 gives matched-size gains of
      ~+0.4 dB at q90 on both the photo and the 6 MP bench, and a −24%
      Pareto win (smaller AND higher PSNR) at q70 on the bench, while q90's
      absolute PSNR barely moves (quality ladder preserved). Only changes
      emitted coefficient values (all legal); no bitstream-structure change.
    - **E5e** (2026-07-25): DCT16x16 AC strategy, RD-selected per 2x2 cell —
      the largest single quality jump of the series. Forward DCT16 plus the
      LLF↔DC coupling (a DCT16 varblock's lowest 2x2 coefficients ARE the
      DC-image samples of its four covered blocks, re-inserted by the
      decoder's `insertLLF`; the encoder inverts that and excludes storage
      positions {0,1,16,17} from the AC scan) and generalized AcMetadata
      varblock placement. Photo fixture is strictly dominant — smaller AND
      higher PSNR at every quality (q50 3134 B/31.55 dB vs 6627 B/29.05 dB;
      q90 27264 B/39.94 dB vs 30847/37.64). Cross-oracle 122–130 dB.
      **Known regression, kept deliberately:** on noise-heavy synthetic
      content DCT16 loses at q70 (+23% size for +0.07 dB). A sweep of the
      rate model's zero-token cost shrinks that monotonically but never
      reaches the DCT8-only size while degrading photos — it is structural
      (noise needs more coded coefficients under a 16x16 transform), so the
      fix is a content-adaptive guard (E5f), not another global constant.
      Rate-model lesson: counting only non-zeros is dishonest here — every
      zero BEFORE the last non-zero costs a zero-density token, and a
      256-coefficient scan pays that far more often than four 64-coefficient
      scans; ignoring it made DCT16 lose ~35% at q70.
    - **E5f** (2026-07-25): the E5e regression is **fixed** — a frame-level
      race replaces the per-cell guard it was scoped as. RACE recovers the
      better endpoint everywhere: bench q70 138482 B/33.917 dB (identical to
      all-DCT8, regression gone) while photo q50/q70/q90 stay exactly on
      E5e's DCT16 results (3134/31.55, 9431/35.44, 27264/39.94). 6 MP encode
      0.91 s; cross-oracle 122–130 dB on both branches.
      **Two negative results recorded so they are not retried:** (a) tuning
      `kEncStratZeroBits` and (b) a per-cell scan-depth guard both floor
      ~12% above all-DCT8 on noisy content, and (b) additionally destroys
      the q90 win because scan depth tracks the QUANT STEP, not content
      (fine quantization leaves non-zeros deep in the scan even for smooth
      cells). That shared floor is the tell: DCT16 and DCT8 use different
      block-context buckets, so ANY mixture fragments the ANS histograms — a
      frame-global cost no per-cell criterion can price. Hence the decision
      belongs per frame, judged on measured output (`SSE + λ·step²·bytes`,
      both axes so a smaller-but-worse candidate cannot win), which is the
      same "race the real encodings" pattern the lossless encoder uses for
      palette. The second encode is skipped when no cell chose DCT16.
    - **E5g** (2026-07-25): **alpha (extra channels) with lossy** — closes a
      real gap, since `encodeLossy` previously rejected any image with extra
      channels and alpha is common. The format gives extra channels no lossy
      coding path in a VarDCT frame: they are a **modular** image carried in
      the same streams as the DC/AC-metadata data and coded with the same
      global tree and ANS code. So the honest description is **alpha is
      lossless while the color planes are lossy**, and "alpha byte-exact" —
      not a PSNR bound — is the gate.
      The subtlety that decides correctness is the split rule. `modularDecode`
      partitions on `maxChanSize == group_dim`: channels no larger than 256 px
      decode entirely inside the LfGlobal stream, larger ones per AC group.
      But `modularDecode` **always** consumes a `GroupHeader` first, and only
      then returns early when no channel is small enough — so a large-EC frame
      must still write that header in LfGlobal and leave only the samples to
      the AC groups. Writing the header only in the small case desyncs every
      image wider or taller than 256 px, i.e. essentially all real ones.
      Two smaller mirrors, each of which alone corrupts the stream: the frame
      header carries one `ec_blending_info` per extra channel after the color
      one (omitting them mis-sizes the header and the TOC read fails), and the
      per-group EC data uses **decoder-local** channel indices (property 0),
      renumbered from `beginC` — the same trap that cost a bug in E3.
      Verified: alpha byte-exact against the source on both layouts (160x120
      and 96x64 16-bit global; 300x200 and 600x300 per-group, 2x1 and 3x2 group
      grids), **and byte-exact through djxl's own decoder**, which is the real
      proof that libjxl agrees the alpha is lossless. Color cross-oracle
      113–131 dB. Alpha exactness is now also an invariant in the encode
      fuzzer's new lossy arm, so random geometry keeps sweeping both layouts.
      Note the cross-oracle for lossy+alpha must run on **float PFM**: djxl
      0.12 blue-noise-dithers 8-bit output by default and we do not, which
      floors 8-bit agreement near 54 dB and would look like a bug.
      Known density limitation, deliberately not addressed here: the ECs share
      the DC/metadata single-leaf gradient tree and its one histogram, so alpha
      is coded with a context fitted to DC residuals. Cheap for typical
      flat/edge alpha, but a learned tree (or a second context) is the lever if
      alpha-heavy content ever matters.
    - **E5h** (2026-07-25): **restoration filters with encoder
      compensation** — every frame before this disabled both (gaborish off,
      epf_iters 0) while cjxl enables both by default.
      The work is the COMPENSATION, not the header bit. With `loop_filter_gab`
      set the decoder blurs the reconstructed XYB planes, so flipping the flag
      alone ships a blurred image; the coefficients must describe a
      pre-sharpened P with `gaborish(P) ~= S`. libjxl hardcodes a 5x5 kernel
      approximating that inverse — deliberately NOT transcribed here, because
      those constants are unverifiable from first principles and would invert a
      filter subtly different from ours if any weight drifted. Instead the
      encoder inverts the decoder's OWN `gaborish` as a black box by Van
      Cittert / Richardson iteration (`P += S - gaborish(P)`), which converges
      because the filter is a mild near-identity blur. `gaborish` became
      internal and the default weights moved to one shared constant referenced
      by both FrameHeader and the compensation, so the two cannot drift.
      RESULT — Gaborish is STRICTLY DOMINANT at low bitrate (smaller AND
      higher PSNR), and the race declines it at high quality:
        content   q    OFF                GAB(compensated)   race
        photo     30   1446 / 22.63       1407 / 23.02       GAB
        photo     50   3134 / 31.55       3108 / 31.98       GAB
        photo     90   27264 / 39.94      35373 / 42.27      OFF
        smooth    50    917 / 33.99        915 / 34.40       GAB
        noise     90   128262 / 19.72     150323 / 22.45     GAB
      The q90 photo size golden is UNCHANGED at 27264 because the race keeps
      filters off there. Iteration count is 5, not the 3 first guessed: three
      measured only an 11.8x residual improvement (0.265 -> 0.0225) across a
      HARD EDGE, the slowest case for a deconvolution.
      **NEGATIVE RESULT — EPF IS INERT for this encoder, so E5h ships Gaborish
      only.** `epf_iters = 2` produced output PIXEL-IDENTICAL to Gaborish alone
      in all 12 measured cases, and the mechanism is exact: `computeEPFSigma`
      forms `sharp = epfSharpness/7`, and this encoder writes an ALL-ZERO
      sharpness field, so `sigma -> min(-1e-4, 0)`, `invSigma -> -10000`, and
      every block trips `rowSigma < kEpfMinSigma` and is skipped. Zero
      sharpness means "maximally sharp, do not filter". Requesting EPF would
      only cost header bits and make the decoder build a sigma field it never
      reads. EPF becomes a real lever once the encoder emits a meaningful
      per-block sharpness — that is the work, tracked separately.
      COST: the filter race adds an encode+decode per frame (worst case three
      of each, vs two before). Whether that stays is a measurement question,
      and `JXL_FILTER_RACE=0` is the lever.
    - **E5i** (2026-07-26): **ship the lossless stream when it is smaller.**
      The first external benchmark scored text/screen at +874% BD-rate, and the
      cause was mode selection, not coding: our lossy path emitted 64299 B where
      our OWN lossless emitted 4042 B. This is a DOMINANCE check, not an RD
      trade — a lossless stream is exact, so if it is also smaller it wins on
      both axes and needs no lambda. Text -93.7%; every other corpus image
      BYTE-IDENTICAL, which is the evidence it is dominance and not a heuristic.
      Affordable because lossless is ~an order of magnitude FASTER than lossy
      (6 MP: e1 ~0.11 s vs ~2.2 s). GRAYSCALE IS EXCLUDED: the lossy path
      replicates gray to RGB so it decodes as 3 channels while lossless
      preserves 1, and letting the rule fire would make the decoded channel
      COUNT depend on which candidate won (it crashed a caller indexing
      planes[0..<3]). Fixing that is native grayscale lossy, tracked separately.
    - **E5j** (2026-07-26): **choose the AC context map by measured size.**
      `jxl info <file> sections` (added here) showed HfGlobal was a near-CONSTANT
      ~2800 B — 92% of a q1 file, describing 24 B of AC data. The threshold that
      should have caught this measured the WRONG QUANTITY: it counted AC tokens
      including per-block nonzero-COUNT tokens, one per block per channel even
      when every coefficient is zero, so on any non-tiny image it could not fall
      below 4096 and the expensive 8-cluster map was always chosen. Now both
      maps are priced on real bytes and the smaller wins — a pure size choice
      with no quality dimension, since only the entropy coding of already-fixed
      coefficients changes. Corpus total -5.9%, q30 wins of -18% to -72% on
      every image, byte-identical where dense AC genuinely wants 8 clusters.
    - **E5k** (2026-07-26): **learn the global modular tree.** With HfGlobal
      gone, the DC image was 79% of a smooth-content file at ~1.7 bits/sample
      for a ramp, because the lossy path used a FIXED single-leaf gradient
      predictor while the lossless encoder has had learned MA trees since E4a.
      Learned tree, raced against the fixed one on real serialized bytes.
      grad_smooth q50 -29.4%, photo_sky q30 -27.3%, golden fixture q50 -34.4%,
      all at identical PSNR. KNOWN REGRESSION shipped deliberately: gray_city
      q50 +3.8%, because pricing covers the DC planes only while the real
      encoder shares one histogram set with the AC-metadata streams, so a
      DC-specialised tree gets its contexts polluted and the DC itself degrades.
      The fix is to price both candidates over DC AND metadata; tracked.
    - **Perf** (2026-07-26): the races had stacked to +69% encode time. Two came
      out with BYTE-IDENTICAL output: the E5j map race is now priced
      analytically (entropy under the same normalized counts ANS will use;
      extra bits cancel between candidates) rather than serialized, 0.66 s ->
      0.12 s; and the E5h filter race was RETIRED because E5j inverted its
      economics — with the fat header gone, Gaborish's extra coefficient bytes
      dominate and forced-GAB lost to forced-OFF in all 17 re-measured cases.
      6 MP q90 4.25 s -> 2.26 s. That is filters under OUR RD calibration, not a
      property of the format; recalibrating lambda under Gaborish is tracked.
    - THE PATTERN WORTH INHERITING: E5i, E5j and E5k were all the same shape —
      the win was in USING MACHINERY THIS REPO ALREADY OWNED (the lossless
      encoder, a header that described nothing, E4a's learned trees). The lossy
      path had been built as though it were a separate codec from the lossless
      one, and the seams between them were where the bytes were hiding. Reach
      for `jxl info <file> sections` FIRST in any density question: it found all
      three root causes in an afternoon after whole-file differencing had failed
      to.
    - **E5l** (2026-08-02): **DCT32 (AC strategy 5).** Smooth content was the
      encoder's worst class (+54.6% BD-rate on a gradient, +72.0% on a smooth
      photo, vs +24–26% for ordinary photos) while the encoder placed only two
      of the format's ~27 strategies. A 4x4 block super-cell is now raced
      against the DCT16/DCT8 tiling that won those sixteen blocks.
      Three pieces: `forwardDCT32`; `encDCT32DCFromLLF`, the exact inverse of
      the decoder's `insertLLF` for a 4x4 LLF corner (two 4-point scaled IDCTs
      plus `kResampleScale4`, pinned by a round-trip test through the DECODER's
      own `insertLLF`); and a per-group scratch layout changed from cell-major
      to **Z-order over 4x4 super-cells**, because cell-major does not nest at
      the 4x4 level — a super-cell's sixteen blocks were not contiguous, so a
      1024-coefficient varblock had nowhere to land.
      SELECTION IS HIERARCHICAL, and the alternative it is scored against
      matters: one DCT32 replaces not "sixteen DCT8" but whatever DCT16/DCT8
      mixture already won those blocks, RE-SCORED at the super-cell's own quant
      step (cost is not comparable across steps — lambda scales as step², the
      modelled rate does not). Re-scoring runs no new transform.
      RESULT, sizes at matched quality (DCT32 off -> on):
        grad_smooth  q50  5697 -> 4988  (-12.5%)   q90 26320 -> 24543 (-6.8%)
        photo_sky    q50  1748 -> 1606  ( -8.1%)   q90 11538 -> 10890 (-5.6%)
        gray_city    q50 15772 -> 13777 (-12.7%)   photo_city q50 -6.4%
        photo_bridge q50 20904 -> 19400 ( -7.2%)   synth_noise  byte-identical
      Matched-SIZE PSNR (the only honest read) is positive everywhere measured:
      grad_smooth +0.38…+1.81 dB, photo_sky +0.31…+1.95 dB, photo_bridge
      +0.05…+0.94 dB, photo_city +0.05…+0.78 dB. Golden fixture 24958 -> 21038
      (-15.7%), re-verified against djxl before the constant moved.
      **NO NEW FRAME-LEVEL RACE, and this is the interesting part.** E5f's
      lesson was that a new strategy fragments the ANS histograms because its
      blocks use a different block-context bucket. DCT32 does NOT: `kStrategy
      Order` sends DCT16 to order bucket 2 and DCT32 to bucket 3, and the
      default block context map's rows are [0,1,2,2,3,…] / [7,8,9,9,10,…] — 2
      and 3 collapse to the SAME cluster in all three channel buckets. So
      mixing DCT32 into a DCT16 frame adds no histogram, the per-cell RD choice
      stands on its own, and the existing large-vs-all-DCT8 rung still answers
      the only frame-global question there is. Asserted in-suite against the
      DECODER's table so a future map change cannot silently invalidate it.
      Checked at frame-race lambda 6.0 / 0.5 / 0.1: the DCT32 decision is
      identical at all three on 8 of 9 corpus images. The exception is
      photo_rocks q50, where lambda 6.0 declines large transforms entirely and
      hides a +0.76 dB / +1.1% DCT32 win that appears at 0.5 — i.e. a lambda
      recalibration would make DCT32 look BETTER, never worse.
      COST: +16–30% encode time. A cheap admission gate (evaluate a super-cell
      only where some sub-cell already chose DCT16) recovers up to 22% of the
      worst case (synth_noise q90 0.221 s -> 0.172 s) and is 41/45 corpus points
      byte-identical, the other four differing by -0.005%…+0.51% in both
      directions at equal PSNR. `JXL_DCT32=0` / `JXL_DCT32_GATE=0` isolate both.
    - **BENCHMARK after E5l** (vs `cjxl -e7`, 9 measurable corpus images):
      BD-rate PSNR median **+22.0%**, SSIMULACRA2 median **+11.2%** — down from
      +35.4/+35.5% at the start of the E5i..E5l sequence, with the perceptual
      metric roughly halving. Against `cjxl -e3` the mean is +12.4%, and we now
      WIN on photo_rocks (-3.4%) and synth_noise (-15.4%) and sit at parity on
      grad_smooth (+0.1%) — the first operating points where this encoder beats
      the reference at any preset. Equal-PSNR size 1.28x mean. Encode ~4.1x
      `cjxl -e7`, which remains the weak axis.
      Remaining worst classes: smooth gradient +53.9% and dark/grain +46.5%.
      Weight SSIMULACRA2 over PSNR — cjxl targets butteraugli, and the RD
      calibration study showed the two can disagree in SIGN about a tool.
      CAVEAT that applies to every number here: the corpus has only THREE
      genuinely independent photographs, and no repo fixture is photographic.
      That is how every lossy decision from E5a to E5h came to be tuned on
      synthetic content in the first place.
    - Remaining lossy quality levers: further strategies (rectangular
      DCT16x8/32x16, AFV), real trellis/joint RD across the block,
      a real EPF sharpness field (above). Note what E5l refined about the E5f
      finding: the histogram-fragmentation cost is not "one per new strategy",
      it is one per new **block-context cluster**. Check `kStrategyOrder`
      composed with `kDefaultBlockContextMap` before assuming a new strategy
      needs its own race — the rectangular transforms land in buckets 4/5/6,
      which map to luma clusters 3/3/4, i.e. distinct from DCT8's 0 and
      DCT16/32's 2, so those probably DO need the race treatment.
- **E6 (undecided) — jbrd**: JPEG recompression, byte-exact reconstruction.

Each milestone = the full existing ritual: suite + fuzz + bench + size gate +
djxl proof, one jj commit with measurements in the description.

## 7. Risks, called out now

- *rANS reverse-order writing* is the fiddliest new algorithm; mitigate by
  landing prefix codes first (E1) so entropy-writing bugs are isolated from
  stream-structure bugs.
- *Normalization mismatch* (histogram → 4096-sum table) has sharp edges
  (zero-frequency symbols, single-symbol histograms); the decoder's
  `initAliasTable` is the arbiter — round-trip through it in unit tests
  before ever writing a file.
- *Spec-dialect drift* is the silent killer; djxl-in-the-loop from E0, not
  E4.
- *Scope creep toward lossy*: the E5 "undecided" label is load-bearing. The
  decision point comes after E4 ships, with corpus numbers in hand.
