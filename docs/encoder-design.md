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
  the complete VarDCT decode pipeline is the dual to write against; E5a in
  progress): XYB forward, fixed DCT8, uniform quant, quality knob;
  explicitly "valid, not competitive." Gates include a CROSS-ORACLE check:
  our decoder and djxl must agree to high precision on the same lossy file.
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
