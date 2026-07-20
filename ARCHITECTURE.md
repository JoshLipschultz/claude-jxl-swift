# Architecture & Roadmap

A pure-Swift, from-scratch JPEG XL (ISO/IEC 18181) **decoder** for macOS, with a
CLI and (later) a Quick Look extension. No dependency on libjxl — libjxl is used
only as a *test oracle* (`cjxl`/`djxl`/`jxlinfo`) to validate our output.

> Scope chosen for this project: **decoder first**, **full conformance (both
> Modular and VarDCT modes)**, packaged as a SwiftPM library + CLI now, with the
> Xcode app + Quick Look appex wired up once full Xcode is installed.

## The shape of the format

A `.jxl` file is either a **bare codestream** (starts with `FF 0A`) or an
**ISOBMFF container** (starts with the `JXL ` signature box). Either way the
codestream itself begins with `FF 0A` and is structured as:

```
codestream
├── SizeHeader            image dimensions                         [M1 ✅]
├── ImageMetadata         bit depth, channels, color, animation…   [M2 ✅]
└── frames…
    └── FrameHeader + TOC
        ├── LfGlobal       (incl. Modular global, patches, splines, noise)
        ├── LfGroup…       (per-group low-frequency data)
        ├── HfGlobal       (VarDCT: dequant tables, HF preset)
        └── PassGroup…     (per-pass, per-group AC coefficients / Modular)
```

Two coding paths share one entropy substrate:

- **Modular mode** — lossless & responsive: MA decision trees, self-correcting
  predictors, reversible transforms (RCT, Palette, Squeeze). Decodes lossless
  images and also carries VarDCT's LF image and extra channels.
- **VarDCT mode** — the lossy path: XYB color, variable-size DCT (2×2…256×256),
  adaptive quantization, chroma-from-luma, then restoration filters.

Everything entropy-coded uses the **hybrid ANS + prefix-code** layer with an
LZ77 stage and context modeling.

## Source layout

```
Sources/JXLCore/
  Bitstream/
    BitReader.swift     LSB-first bit reader                       [M1 ✅]
    Fields.swift        u(n), U32, U64, Enum, F16                  [M1 ✅]
  Container/
    Container.swift     ISOBMFF box demux + codestream reassembly  [M1 ✅]
  Headers/
    SizeHeader.swift    image dimensions                           [M1 ✅]
    ImageMetadata.swift BitDepth, channels, full ColorEncoding     [M2 ✅]
    CustomTransformData.swift header transform bundle skipper       [M4 ✅]
  Entropy/
    HybridUint.swift    hybrid integer coder (token + extra bits)  [M3 ✅]
    PrefixCode.swift    canonical prefix (Huffman) codes           [M3 ✅]
    ANS.swift           histogram decode + alias table + flat/prec [M3 ✅]
    ANSReader.swift     rANS state machine + LZ77 token reader     [M3 ✅]
    EntropyDecoder.swift header assembler + context map + MTF      [M3 ✅]
  Frame/
    FrameHeader.swift   frame type, passes, blending               [M4 ✅ partial]
    FrameDimensions.swift group/DC-group grid math                 [M4 ✅ partial]
    TOC.swift           section-size table + permutation decode    [M4 ✅ partial]
    FrameDecoder.swift  single-parse frame orchestrator: headers/TOC
                        parsed once, staged Modular + VarDCT decode,
                        decode limits, section-bounds validation      [✅]
  Headers/
    CustomTransformData.swift opsin matrix + upsampling weights    [M4 ✅]
  Modular/
    MATree.swift        meta-adaptive decision tree                [M5 ✅]
    ModularImage.swift  Image/Channel sample planes                [M5 ✅]
    Predictors.swift    14 predictors + self-correcting weighted   [M5 ✅]
    ModularDecoder.swift GroupHeader, transforms, channel decode   [M5 ✅ decode]
    Transforms.swift    inverse RCT ✅ + Palette ✅ (Squeeze pending) [M5 wip]
  VarDCT/
    VarDCTInfo.swift    DC-global preflight (quantizer, ctx map)   [M6 ✅]
    DCImage.swift       low-frequency pass: XYB DC + AC metadata   [M6 ✅]
    ACMetadata.swift    block strategies, quant field, CfL maps    [M6 ✅]
    CoeffOrder.swift    natural orders + permutations              [M6 ✅]
    PassGroup.swift     AC coefficient entropy decode              [M6 ✅]
    DequantWeights.swift default dequant matrices per strategy     [M6 ✅]
    DCTTransforms.swift inverse transforms ≤32x32 + LLF insertion  [M6 ✅]
    Reconstruct.swift   dequant→transform→Gaborish/EPF1→XYB planes [M6/M7 ✅]
  Restoration/
    Upsampling.swift                                               [M7]
  Color/
    ColorManagement.swift XYBImage planes; XYB→linear→declared
                        encoding (primaries matrix + Bradford,
                        gamma/709/DCI/sRGB/linear quantizer)       [M8 🟡]
                        (16-bit/float out, PQ/HLG, CMS remain)
    ICCCodec.swift      embedded ICC profile decode (ReadICC +
                        UnpredictICC, byte-exact vs djxl)          [M8 ✅]
  JXLImage.swift        decoded pixel buffer (public)              [M5+]
  JXLDecoder.swift      public API (thin wrappers over FrameDecoder) [✅]
  Errors.swift                                                     [M1 ✅]
Sources/JXLKit/
  JXLImageConverter.swift CGImage bridge (viewer + Quick Look)     [✅]
Tests/Fuzz/
  FuzzRunner.swift      seeded mutation fuzzer (Scripts/fuzz.sh)   [✅]
```

### Decoder architecture

`FrameDecoder` is the spine: it parses the container, codestream headers,
`FrameHeader`, and TOC exactly once at init (validating every section's byte
range), then exposes each decode stage as a cached accessor —
`decodeModularImage()`, or for VarDCT `varDCTDCGlobal()` →
`varDCTLowFrequency()` (each DC group's `VarDCTDC` + `AcMetadata` in one pass)
→ `varDCTACGlobal()` → `varDCTCoefficients()` → `reconstructXYB()`. Later
stages force earlier ones, which also keeps the shared section-0 reader
correctly sequenced for coalesced single-section frames. Section readers share
the codestream storage (`BitReader(_:byteRange:)`) — no per-section copies.
Every public `JXL.*` entry point and byte-taking VarDCT helper is a thin
wrapper constructing one `FrameDecoder`.

VarDCT reconstruction stops at `XYBImage` (padded float planes); conversion to
display pixels lives in `Color/ColorManagement.swift`, which is where M8 lands
without touching the transform pipeline. `JXLDecodeLimits` (default ~2^30
samples) bounds what a hostile header can make the decoder allocate;
pixel-decoding APIs take it as a parameter.

Per-AC-group decode is a pure function of its section bytes plus immutable
globals, and runs **concurrently** across groups
(`DispatchQueue.concurrentPerform`, coalesced single-section frames excepted);
results merge in group order, so output is deterministic. The public value
types are `Sendable`; `FrameDecoder` itself is not (mutable stage caches) —
one instance per decode.

`Sources/JXLKit` is the CoreGraphics bridge (`JXLImageConverter`:
`JXLDecodedImage` → `CGImage` with EXIF orientation), shared by the viewer app
and the Quick Look extension so `JXLCore` stays Foundation-only. The
stage-level VarDCT entry points (`decodeVarDCTDCImage`,
`decodeVarDCTACMetadata`, `decodeVarDCTACGlobalForFrame`,
`decodeVarDCTCoefficients`, `reconstructVarDCTImage` and their result types)
are gated behind `@_spi(Stages)` — visible to the `jxl` CLI's diagnostic
subcommands via `@_spi(Stages) import JXLCore`, absent from the plain public
API, which is now `JXL.*` + the metadata/info types + `BitReader`/fields.

## Milestones

| #  | Milestone | Deliverable | Status |
|----|-----------|-------------|--------|
| M1 | Foundation | container demux, dimensions, CLI, oracle harness | ✅ done |
| M2 | Image metadata | full `ImageMetadata` bit-exact vs libjxl (depth, channels, full color encoding) | ✅ done |
| M3 | Entropy coding | prefix + ANS + LZ77 + context modeling | ✅ done — validated on real codestream data via the MA tree |
| M4 | Frame layer | FrameHeader, TOC, role-aware sections | ✅ structural parser done |
| M5 | **Modular mode** | lossless `.jxl` → pixels | 🟢 **all lossless fixtures byte-exact vs djxl** — single + multi-group, RCT + Palette, gray/RGB/RGBA/8/16-bit. **Squeeze decodes byte-exact** (MetaSqueeze/DefaultSqueezeParameters/InvSqueeze port incl. SmoothTendency; ModularDC group streams for shift ≥ 3 channels — per-channel rect clamping against ceil-rounded squeeze dims, stream id 1+numDCGroups+g), and **lossy modular (Modular-XYB + squeeze) renders at ~54 dB** through the shared XYB output path (channels Y/X/B−Y × DC-quant factors). Float and progressive (multi-pass) remain |
| M6 | VarDCT mode | lossy photographic `.jxl` → pixels | 🟢 **all transforms up to 32×32 at ~54 dB vs djxl** — full pipeline (entropy → dequant → LLF-from-DC → inverse transform → CfL → filters → XYB→sRGB) for DCT8/16/32, all rectangular sizes, IDENTITY, DCT2x2/4x4/4x8/8x4, AFV0–3, validated on the mixed-strategy fixture. **JPEG transcodes decode**: YCbCr color transform (JFIF BT.601), 4:2:2/4:2:0 chroma subsampling with triangle-filter upsampling, RAW (modular-coded) quant tables, DC-threshold block contexts — ~54 dB vs djxl on real camera transcodes (in-suite oracle fixture). **DCT64/128/256 transforms** decode (~54 dB, in-suite oracle) — every AC strategy is now supported |
| M7 | Restoration | Gaborish + EPF + upsampling | 🟡 Gaborish + EPF1 validated at ~54 dB on the mixed-strategy fixture (EPF sigma exercised across multi-block varblocks). Upsampling and EPF0/EPF2 (epf_iters ≠ 1) remain |
| M8 | Color pipeline | XYB→sRGB, ICC, alpha, 8/16-bit/float output | 🟡 embedded ICC profiles decode **byte-exact vs djxl** (`ReadICC` + `UnpredictICC` port; `JXL.readICCProfile`, `JXLDecodedImage.iccProfile`, `CGImage` tagging in JXLKit). Numeric color encodings render correctly: custom/enum primaries + white points (Bradford adaptation) and gamma/709/DCI/linear transfers — **54.6 dB vs djxl** on the custom-primaries fixture, in-suite oracle. **PQ + HLG render correctly** (SMPTE 2084 with the mastering intensity target and the extended >1.0 domain for content above the peak; HLG OETF + inverse OOTF with target-primaries luminances; the inverse-opsin output now scales by 255/intensity_target as libjxl does) and **16-bit + float32 output formats** exist (`JXLSampleFormat`, threshold-table 16-bit quantizer, transfer-encoded float planes; extra channels rescale to match) — PQ 74 dB / HLG 100 dB vs djxl's 16-bit output (in-suite fixtures), float verified sample-exact against the 16-bit path. **JXLKit displays HDR**: 16-bit RGBA CGImages tagged with the matching well-known space (ITU-R 2100 PQ/HLG, ITU-R 2020, Display P3 — `displayColorSpace(for:)`), 16-bit orientation baking, and the viewer decodes PQ/HLG files at uint16 with `wantsExtendedDynamicRangeContent` on the canvas layer (macOS 14+), so HDR files composite through ColorSync with EDR headroom. Remaining: gamut mapping for out-of-gamut pixels (we hard-clamp; djxl desaturates — the PQ residual), CMS for XYB→ICC-profile space |
| M9 | Advanced | patches, splines, noise, animation, extra channels, JPEG recon | 🟡 **patches decode** (~54 dB vs djxl, in-suite oracle fixture): multi-frame parsing walks referenceOnly frames into slots 0–3, Modular-XYB reference frames decode through the shared modular pipeline (channels Y/X/B−Y × DC-quant factors), the patch dictionary is entropy-decoded from the DC-global head, and patches blend onto the reconstructed XYB image after filters / before the color transform (alpha-free blend modes; extra-channel blends rejected until VarDCT carries EC planes). **VarDCT extra channels (alpha) decode**: ECs ride the frame's modular sub-streams (global stream for channels ≤ group_dim, per-AC-group ModularAC streams for larger; per-EC metadata now parsed into `JXLExtraChannelInfo`), come out as native 8-bit integer planes on `JXLDecodedImage`, and flow through JXLKit's existing alpha path — color ~54 dB vs djxl, **alpha plane byte-exact**, single- and multi-group (in-suite PAM oracle fixture). Upsampled/shifted/non-8-bit ECs still rejected. **Animation decodes**: AnimationHeader parsed (tick rate, loops, timecodes), per-frame durations kept, `JXL.decodeFrames` walks presented frames (`FrameDecoder(skipPresentedFrames:)` re-walks headers per frame, accumulating reference slots), `jxl frames` CLI writes the sequence — lossy frames ~54 dB and lossless frames byte-exact vs djxl's APNG output (committed 4-frame fixtures). Frames composited with anything other than full-frame replace are cleanly rejected (blending port pending). **JPEG reconstruction (jbrd) in progress**: a pure-Swift Brotli decoder (RFC 7932, ported from the reference Java implementation, byte-exact vs the brotli CLI, embedded SHA-verified static dictionary) plus the jbrd bundle parse (JPEGData::VisitFields + Brotli marker-payload fill) land first — validated against DSCF9386.jxl and a committed cjxl --lossless_jpeg fixture whose djxl reconstruction is byte-exact vs the source JPEG. **JPEG reconstruction is complete and byte-exact** (`JXL.reconstructJPEG`, `jxl tojpeg`): RAW quant-table integers and raw quantized DC retained through the VarDCT decode, per-block transpose + JPEG CfL restoration (fixed-point scaled_qtable, RatioJPEG) into per-component coefficient arrays (kept outside the component structs during the fill — writing through them copied tens of MB per block, 8 min → ~2 s on 26 MP), Exif/XMP from container (brob-unwrapped) boxes, ICC re-chunked into APP2, and the full dec_jpeg_data_writer port (marker walk, DHT/DQT/SOF/SOS/DRI, sequential + progressive + refinement scan encoders, restart markers, recorded padding bits, extra zero runs, 0xFF stuffing). **Byte-identical output** on the committed 4:2:0 fixture (vs its source JPEG) and on a 26 MP camera transcode with ICC+Exif+XMP (vs djxl); progressive-JPEG scan encoding is ported but not yet exercised by a fixture. Splines and noise remain |
| M10 | macOS integration | `CGImage` bridge + Quick Look thumbnail/preview appex | ✅ `JXLQuickLook.appex` (decode via JXLCore, profile-aware `CGImage` via JXLKit) builds, sandbox-entitled, embeds in JXLViewer.app, and registers with PlugInKit (Xcode-beta + xcodegen; `swift build`/`swift test` also work under `DEVELOPER_DIR=/Applications/Xcode-beta.app/...`). **Caveat:** on this macOS (27), ImageIO decodes JXL natively and Quick Look always prefers the first-party provider — the appex registers but is never invoked (verified via `log stream` on the extension process). It exists for macOS versions without native JXL (deployment target 13.0). Our decoder is exercised by JXLViewer.app, the `jxl` CLI, and JXLCore consumers |

Cross-cutting, ongoing: conformance corpus from the libjxl test suite, fuzzing,
and SIMD/performance once correctness is locked per stage.

## Decode performance

Benchmarked on a 6 MP synthetic photographic fixture (`Scripts/gen-bench.sh`,
`jxl bench <file> [iters]`), Apple Silicon, all 17k+ oracle tests byte-exact /
54 dB throughout:

| Path | Before | After | |
|---|---|---|---|
| VarDCT (lossy, q95 e4) | 360 ms (16.7 MP/s) | **43 ms (~138 MP/s)** | 8.3× |
| Modular (lossless, e3) | 3585 ms (1.7 MP/s) | **115 ms (~52 MP/s)** | 31× |

What did it (in impact order): rewriting the weighted predictor on flat
manually-managed buffers with scalarized 4-wide math, and skipping it entirely
when the MA tree never observes it (libjxl's `use_wp` gating); decoding
Modular AC groups concurrently (decode phase parallel, blits serial, and
in-place blits — the old read-modify-write copied the whole plane per group);
parallel VarDCT reconstruction, filters (Gaborish/EPF row-parallel,
scalarized SAD), and color conversion; a threshold-table sRGB8 quantizer that
is bit-identical to the `powf` reference (asserted by a dense-sweep test); and
a 64-bit unaligned-load fast path in `BitReader`.

**The lesson that cost the most to learn:** accessing a global or shared
`[T]` array from inside a `concurrentPerform` worker — returning it, passing
it as an argument, or `withUnsafeBufferPointer`-ing it per call — takes an
atomic retain/release on *one shared refcount cacheline*, and under 8–10
threads that contention can eat the entire parallel speedup (first parallel
attempt: 268 → 550 ms). Everything crossing into a worker loop must be a raw
pointer, a scalar, or a thread-unique value: the IDCT basis tables, sRGB
thresholds, and opsin constants are now process-lifetime `UnsafePointer`s /
scalars for exactly this reason. Per-pixel closures (even `@Sendable` ones)
and per-pixel array temporaries are equally forbidden in hot loops.

**2026-07 round (161 → ~115 ms lossless, 68 → ~62 ms lossy):** the dominant
win was converting everything the per-pixel Modular loop touches to raw
pointers — the MA-tree property vector (was an `inout [Int32]` paying an
exclusivity check per pixel), the tree/context-map walks, and flattened
reference-channel properties (~25%). The WP error window is now a per-position
`SIMD4<UInt32>` (planes as lanes): `updateErrors` collapsed to two vector ops
(its samples dropped 10×), though the win shows as latitude, not wall time —
the predictor's serial dependency chain bounds the loop. WP divlookup and the
ANS reader's alias/uint-config tables became private allocations (bounds/borrow
machinery off the symbol path; neutral wall-time, cleaner profile).

**VarDCT tail round (2026-07-20, 62 → ~43 ms lossy):** flat coefficient
pooling (one frame-wide pool + per-block offsets, disjoint per-group raw-
pointer writes; ~14 ms) and parallel DC-group decode in the LF pass (~3.5 ms)
landed; the Gaborish/EPF interior/border split (branch prediction already
near-perfect) and a buffered ANS refill (loses to the existing 64-bit
unaligned-load path) were measured and *reverted* under the ≥2 ms bit-exact
gate — recorded here so they aren't re-attempted without new evidence. The Modular loop is now bound by the serial
WP-predict → tree-walk → ANS-read dependency chain; further gains there mean
restructuring (e.g., libjxl-style per-row specialization), not micro-opts.

**Metal (GPU) — assessed 2026-07, deferred.** Measured stage split (release,
6 MP / 26 MP): headers+DC/LF 24.6/97 ms, AC entropy +18.8/+82 ms,
reconstruct+filters+color +22.6/+63 ms. Decode is ~⅔ serial/branchy entropy
work that cannot leave the CPU, so Amdahl caps a *free* GPU tail at ~1.5×;
the GPU-shaped part (Gaborish/EPF/XYB→sRGB — streaming, bandwidth-bound) is
~15% of decode and already saturates cores via `concurrentPerform`. GPU float
rounding (FMA contraction) also breaks CPU/oracle bit-parity — fine for the
>50 dB gates, a new flakiness class otherwise. JXLCore stays pure CPU Swift.
JXLCore's *decode* stays pure CPU Swift for oracle bit-parity. The **display
color transform**, however, is exactly the GPU-shaped, parity-optional tail
that belongs on the GPU — and that trigger has now landed.

**Metal display-time color (implemented).** `JXLKit.JXLMetalColorConverter`
runs the opsin-inverse + primaries matrix + HLG OOTF in a compute kernel,
turning a lossy frame's pre-color-transform XYB float planes
(`JXL.decodeXYBForDisplay`) into **linear** target-space RGB — the input an
extended-linear/EDR display path wants (the compositor applies the display
transfer and HDR headroom). The kernel reproduces `ConvertState.linear`
exactly, so a full-precision render read back matches the CPU reference
(`jxlXYBToLinearPlanes`) to < 1e-4 absolute across all lossy fixtures — a
headless validation (`Scripts/metal-parity.sh`) that sidesteps the GPU/oracle
bit-parity problem by checking absolute error, not bit-equality. The viewer
uses it for SDR XYB stills (opsin/matrix on the GPU, extended-linear CGImage
into the existing `layer.contents` path). **HDR (PQ/HLG) rides the same GPU
route** (2026-07-20, user-verified identical to the CPU pair on an EDR
display): the kernel encodes SMPTE-2084 / the HLG OETF in-shader — the same
curves as the CPU 16-bit path — tagged `itur_2100_PQ`/`HLG`, restricted to
2020 primaries where those named spaces exist; verified through ColorSync
tone mapping at maxDiff ≤ 3 vs both the CPU path and djxl's PNG. The viewer
runs ONE decode for both outputs (`JXL.decodeImageForDisplay`: shared
`renderedXYB()` pass → pixels + display planes; was two full decodes,
173 → 73 ms on the dice fixture).

Still open (nice-to-haves, not correctness): a true extended-linear EDR
*experiment* (mapping PQ/HLG absolute nits to multiples of SDR white
directly, to compare against the PQ-tag rendering on real HDR photos); a
draw-time `MTKView` blit (the current path converts once at decode and
reuses the proven CGImage zoom architecture); a lazy XYB-backed inspector
sampler so the GPU route can skip the uint8 color convert entirely.

**Other Metal triggers, still open:** EPF iters ≠ 1 with a dominant filter
tail → fused Gaborish+EPF compute kernel; animation playback, where the GPU
tail of frame N overlaps CPU entropy of frame N+1.

**Display-color lessons (2026-07 user-assisted A/B; full post-mortems in the
two "display verification" commit messages).** Five bugs shipped past every
headless harness and were caught only on a real display. The transferable
rules:

1. *Decoded samples are signed.* Lossy output legitimately rings below 0 /
   above maxVal. Any output stage that reinterprets via `UInt32(bitPattern:)`
   turns α = −1 into *opaque* — the JXLKit converter painted encoder garbage
   under transparent regions as black fringes for months. Clamp signed at
   every presentation boundary (the CLI writers learned this in the
   conformance round; JXLKit had the same bug independently).
2. *"Linear light + linear tag" is not automatically correct display.* For
   BT.709-transfer content the display convention (Apple `itur_709`, libjxl's
   generated ICCs) decodes with an 1886-style curve, NOT the encoding OETF's
   inverse — the asymmetry is the intended rendering. A display path must
   reproduce the reference decoder's *rendering*, not its math.
3. *SDR display paths must clamp to [0,1].* Extended-range float formats
   faithfully preserve out-of-gamut DCT ringing that wide-gamut (P3) panels
   can actually show — as blocky hue shifts the 8-bit path's clamp hides.
4. *Know what each harness cannot see.* GPU-vs-CPU parity consumes the same
   decoded planes, so it cannot catch decode-side geometry bugs (cross-check
   against `decodeImage` output). An sRGB-context compare clamps away
   P3-visible out-of-gamut errors. CG normalizes alpha before interpolating,
   so CA-compositor behavior cannot be reproduced in a CGContext. The
   decisive oracle for display work: composite against djxl's own PNG through
   ColorSync, then confirm on a physical display.
5. *Tag SDR CGImages.* DeviceRGB means "skip color management": 709-encoded
   samples rendered with the panel response shift every mid-tone. Every
   enumerated sRGB-primary encoding now maps to a named space
   (`itur_709`/`sRGB`/`linearSRGB`); display images are premultiplied
   (straight alpha bleeds transparent-pixel garbage when the compositor
   scales).

Known follow-up: the viewer's Metal route decodes the file twice (once for
the sampler/CPU fallback, once for XYB planes) — fold into one decode.

**M3 status (implemented).** The full entropy substrate is ported from libjxl
v0.11.2: the hybrid-uint integer coder, canonical prefix codes, the rANS
alias-method decoder (histogram reading, alias-table construction, 32-bit state
machine), the context-map decoder (simple + entropy-coded/MTF), the LZ77 copy
layer, and the header assembler that ties them together. Unit-verified in
isolation: hybrid-uint and prefix-code round-trips, **the alias table realises
its distribution exactly across all 4096 slots** (the trickiest component),
flat-histogram/population-count math, inverse-MTF, and simple/flat histogram
decode. End-to-end validation against real ANS-coded bytes arrives at M4, the
first point a frame's entropy-coded data can actually be reached.

**M6 status (DC image).** The first VarDCT pixel stage is implemented and
oracle-validated: `decodeVarDCTDCImage` reproduces libjxl's `ProcessDCGlobal` +
`DecodeVarDCTDC` + `DequantDC` + `AdaptiveDCSmoothing` to produce the
dequantized XYB DC planes (one sample per 8×8 block). Because each block's DC
equals that block's XYB mean, validation decodes every lossy fixture with `djxl`,
converts its sRGB output back to XYB, averages each 8×8 block, and compares: the
per-block mean-absolute-difference is <1% of the plane range (~0.0006–0.004 on
Y/B, ~0.0001 on X) across grayscale/RGB and single/multi-group frames — see
`Scripts/cmp_dc.py`. (Sub-8px images differ only because the check averages real
pixels while libjxl's DC includes block-edge padding.) Restricted to 4:4:4,
single-pass, default/library quant tables, flags == 0; the next steps are the AC
coefficient decode, the per-block inverse DCT, chroma-from-luma, restoration
filters (M7), and XYB→sRGB color (M8) to reach full lossy pixels.

**M6 status (AC metadata).** The per-DC-group `AcMetadata` stream is decoded
(`decodeVarDCTACMetadata`, libjxl `DecodeAcMetadata`): the AC strategy field
(which variable-size DCT — 2×2…256×256, plus AFV/identity — tiles each block),
the raw quant field, EPF sharpness, and the per-color-tile chroma-from-luma
maps. It is validated by *exact tiling*: every block is covered exactly once and
`num == count` varblocks, which — because a DC group is one bounded TOC section
holding `VarDCTDC` then `AcMetadata` behind a single ANS final-state check — is
also a bit-exactness proof of the DC stream. A dedicated fixture
(`256x256_varblocks_lossy.jxl`) exercises mixed block sizes (DCT8/16/32, AFV,
identity, …): 578 varblocks tile its 1024 blocks exactly. The remaining AC work
is the coefficient entropy decode, the dequant weight matrices, and the inverse
DCTs.

**M6 status (AC global).** `ProcessACGlobal` is decoded
(`decodeVarDCTACGlobalForFrame`): the per-pass coefficient orders and AC
histograms. Each AC strategy's coefficients are read in a "natural" (zigzag-like)
frequency order, optionally Lehmer-permuted; `decodeVarDCTACGlobal` reproduces
`DecodeCoeffOrders` (natural-order generation, `ReadPermutation`,
`DecodeLehmerCode`, the order-bucket map) and the histogram decode. The
coefficient-order ANS stream carries its own final-state check, so a clean
decode is bit-exact: it passes on every fixture, including
`256x256_varblocks_lossy` whose custom orders span DCT8/16/32/16×8/32×8 (sizes
64/256/1024/128/512). Note: the `kOrderEnc` field encoding is
`U32Enc(Val(0x5F), Val(0x13), Val(0), Bits(13))` (an earlier preflight constant
was wrong). Dequant weight-matrix computation (`EnsureComputed`) is deferred to
the coefficient-dequant step.

**M6 status (AC coefficients).** The per-group AC coefficient entropy decode is
implemented (`decodeVarDCTCoefficients`, libjxl `DecodeGroupImpl` +
`DecodeACVarBlock`): for each varblock, for each channel in Y/X/B order, it reads
the non-zero count (predicted from neighbouring blocks) then the coefficients in
the block's frequency scan, using the block-context map, non-zero and
zero-density contexts. This is the last entropy-coded stage of VarDCT — every
group ends with an ANS final-state check, and it **passes on all fixtures**
(64×48 … 640×480 and the mixed-block-size `256x256_varblocks`, ~388k
coefficients in the largest). Because a single wrong entropy context desyncs the
ANS state, this is a complete bit-exact validation of the AC entropy decode. The
output is per-varblock quantized coefficient buffers; what remains is purely
arithmetic with no further bitstream reads: the dequant weight matrices, the
inverse DCTs, chroma-from-luma, DC insertion, restoration filters (M7), and
XYB→sRGB (M8).

**M6 status (DCT8 pixels).** The full VarDCT reconstruction runs for DCT8
(plain 8×8) blocks (`reconstructVarDCTImage`): AC dequant with chroma-from-luma
(the library DCT8 quant weights via `GetQuantWeights`, `AdjustQuantBias`), DC
insertion, a direct separable inverse DCT-III, then XYB→linear→sRGB. The IDCT is
implemented from its definition (not libjxl's recursive butterfly) and pinned by
DC=mean, then verified against `djxl`: **PSNR ≈ 54 dB, mean|Δ| ≈ 0.23/channel**
on all DCT8 fixtures (`Scripts/cmp_ppm.py`). Bugs found and fixed along the way:
the XYB→RGB gamma bias sign (`opsin_biases_cbrt = cbrt(−bias)`), the DCT AC
scale (`w(u>0)=√2`, from the 2-point butterfly), and a coefficient-block
transpose relative to the pixel layout.

**M6 status (all transforms ≤ 32×32).** Reconstruction now handles every AC
strategy up to 32×32: the scaled inverse DCT for all rectangular sizes
(`DCTTransforms.swift`, with libjxl's min×max coefficient storage and transposed
layout for tall blocks), the special 8×8 transforms (IDENTITY, DCT2X2, DCT4X4,
DCT4X8/8X4, AFV0–3 with the 16-basis AFV inverse), LLF-from-DC insertion
(`ReinterpretingDCT` with the DCT resample scales), and the per-strategy default
dequant matrices (`DequantWeights.swift`, ports of
`DequantMatricesLibraryDef` + `ComputeQuantTable`). Validated on the
mixed-strategy `256x256_varblocks` fixture (14 distinct strategies): **PSNR
≈ 54.4 dB vs djxl**, the same numerical-precision level as the DCT8 corpus, with
per-strategy PSNR uniform across strategies. One subtle bug found: the raw quant
field must be replicated across *all* 8×8 cells a varblock covers (libjxl fills
whole rows in `dec_group.cc`) — leaving non-first cells at 0 made the EPF sigma
degenerate there and cost ~27 dB. This fixture also exercises Gaborish + EPF1
for real (M7). DCT64 and larger remain (rare in practice; encoder emits them
only at very low quality).

**M4 status (partial).** The first-frame structural layer now consumes the full
codestream header prefix (`SizeHeader`, `ImageMetadata`, `CustomTransformData`,
and byte alignment), parses `FrameHeader`, derives frame/DC group counts, and
reads the entropy-coded TOC section sizes/permutation. It exposes logical section
roles (`singleSectionCoalesced`, DC global/group, AC global/group) plus raw
codestream byte ranges/readers for each section. Validation checks the header +
TOC + section-byte sum invariant and section coverage across the fixture matrix,
including both Modular/lossless and VarDCT/lossy samples. Pixel payload decoding
still starts at M5.

**M2 status (done).** The entire `ImageMetadata` bundle is now parsed
bit-exactly — a faithful port of libjxl v0.11.2's `VisitFields` (the field
layout was reverse-engineered against the libjxl source after differential
testing flagged a bug). This includes bit depth (integer/float + exponent
bits), the full `ColorEncoding` (color space, white point, primaries, gamma /
transfer function, rendering intent, custom chromaticities), extra channels,
tone mapping, and extensions. Validation: across the 25-fixture matrix, our
white point / primaries / transfer / intent values match a libjxl-backed C
oracle 25/25, and `jxl info`'s pixel-format line is byte-identical to
`jxlinfo`'s. The root-cause bug was a wrong `Enum` distribution
(`U32(Val(0), Val(1), BitsOffset(4, 2), BitsOffset(6, 18))`, not what we first
had). Implemented but not yet fixture-covered: the orientation/animation/preview
(`extra_fields`) path and named extra channels.

## Validation strategy

Every stage is validated against libjxl rather than trusted by inspection:

- **Structural** (M1–M2): compare `jxl info` to `jxlinfo` across a fixture matrix
  (see `Tests/JXLCoreTests/Fixtures`, generated by `cjxl`).
- **Pixel** (M5+): decode with our library and with `djxl --output ppm`, then
  assert exact match for lossless and bounded error (butteraugli/SSIMULACRA2,
  both shipped with libjxl) for lossy.
- Fixtures are produced from known-size PPMs, so dimensions are also checkable
  without any oracle.
- **Robustness**: `sh Scripts/fuzz.sh [iterations]` runs a deterministic
  mutation fuzzer (seeded byte flips + truncations of every fixture) against
  the public entry points. Garbage must produce a thrown `JXLError`, never a
  trap; on a crash, `/tmp/jxl-fuzz-status` names the fixture + seed and
  `.build/manual/fuzz <fixturesDir> --repro <fixture> <seed>` replays it.

## Quick Look integration (M10)

A Quick Look extension is a small appex embedded in a host app:

```
Apps/JXLViewer.app
└── PlugIns/
    └── JXLQuickLook.appex      (QuickLookThumbnailing provider)
        └── links JXLCore, declares public.jpeg-xl / org.jpeg.jxl in Info.plist
```

Once pixel decoding lands, the decoder will produce a `CGImage`; the thumbnail
provider will hand it to `QLThumbnailReply(contextSize:…)` and the preview
provider will render it. The appex itself requires **full Xcode** to build and
codesign — `Apps/` holds the provider source and Info.plist so it is ready to
drop into an Xcode project. The core decoder stays a plain SwiftPM library so it
builds and tests without Xcode.

## Toolchain note

The macOS 26/27 Command Line Tools ship a broken SwiftPM build service (dyld
cannot resolve its bundled frameworks), so `swift build`/`swift test` fail. We
build with `swiftc` directly via `Scripts/build.sh` and `Scripts/run-tests.sh`.
`Package.swift` is maintained so that once full Xcode is installed, standard
`swift build` / `swift test` work unchanged.

## Architectural review notes (2026-07-12)

From an architecture pass over the whole library. The validation discipline and
spec-mirroring layout are in good shape; these notes are about structure,
ordered by leverage. **Suggested sequencing: land items 1–2 (with 3–4 riding
along) as one refactor _before_ M7 upsampling / M8 color** — they touch every
stage boundary, and each milestone built on the current shape adds migration
cost. Items 5–7 get much easier once a single decoder object exists; item 6 is
a design constraint to hold while writing it.

> **Status (landed same day, "Architecture" revision):** items 1–4 are done —
> `FrameDecoder` single-parse orchestrator, unified Modular/VarDCT dispatch
> with a merged DC+ACMeta low-frequency pass, `XYBImage` + the color-stage
> split, and copy-free section readers. Item 5 is done for a first pass:
> `JXLDecodeLimits`, TOC section-bounds validation at init, and a seeded
> mutation fuzzer (`Scripts/fuzz.sh`, `Tests/Fuzz/FuzzRunner.swift`) that runs
> byte flips + truncations over the fixture corpus against `readInfo` /
> `readFrameInfo` / `decodeImage`. Its first runs found and fixed four traps
> on hostile input: hybrid-uint configs with `msb > split_exponent`
> (`readHybridUintConfig` is now failable, matching libjxl `DecodeUintConfig`),
> Modular transforms with out-of-range channels / bad RCT types (now gated by
> a `CheckEqualChannels` port in `metaApplyTransform`), a >Int.max extensions
> skip in `skipExtensions` (now clamps past-the-end and latches overread),
> and a >Int.max ISOBMFF `largesize` (now `malformed`). Keep the fuzzer in the
> loop when touching bitstream-facing code (it now also exercises
> `readVarDCTInfo`). Item 6 is done: AC groups decode concurrently
> (`concurrentPerform`, deterministic merge order) and the public value types
> are `Sendable`. Item 7 is done: the `JXLKit` target owns the `CGImage`
> bridge (viewer + Quick Look share it; `project.yml`/`Package.swift`/
> `build.sh` updated, xcodeproj regenerated), and the stage-level VarDCT
> functions + result types are `@_spi(Stages)` — the CLI imports the SPI; the
> plain public surface is `JXL.*`, the info/metadata types, and the bitstream
> primitives. See "Decoder architecture" above for the resulting shape. The
> section-by-section details below are kept for rationale.

### 1. One parse, one decode — a real decoder state object

Every public entry point is a stateless function taking raw bytes, and stages
compose by re-parsing the file. One `reconstructVarDCTImage` call runs
`setupVarDCT` itself, then `decodeVarDCTCoefficients(from: data)` (which runs
`setupVarDCT` again plus a full second `decodeLowFrequency` — the entire
DC-group entropy decode, redone), then `decodeVarDCTDCImage(from: data)` (a
third parse + DC decode). Container demux, headers, TOC, and DC-global each run
3× per image. The "parse headers up to the TOC" prologue is also hand-duplicated
in three places (`readFrameInfo`, `decodeImage`, `setupVarDCT`).

This was the right shape for incremental oracle validation, but the wrong shape
to grow M7–M9 on. Promote `VarDCTSetup` to a `FrameDecoder` (headers, TOC,
section readers, decoded globals, accumulated per-stage results); make every
stage take that state; reduce the public preflight APIs to thin views over it.
Per-stage testability is preserved — tests construct the decoder and stop at
any stage.

### 2. Unify Modular and VarDCT under one frame orchestrator

Two disjoint worlds today: Modular is inlined inside `JXL.decodeImage` (~100
lines of section logic in the API function, and it *rejects* VarDCT frames);
VarDCT is free functions returning a different type. Symptom: the viewer only
calls `JXL.decodeImage`, so it cannot display lossy images despite M6 being
essentially done.

The format argues for unification: both modes share the identical frame
skeleton (FrameHeader → TOC → LfGlobal/LfGroup/HfGlobal/PassGroup), VarDCT
frames already carry Modular sub-streams, and M9 (multi-frame, kReferenceOnly,
blending, patches) operates *above* the mode split. Write the long-ghosted
`Frame.swift` orchestrator: it owns section dispatch, with Modular and VarDCT
as strategy implementations filling a common output.

### 3. A shared plane/image type before M8, not during it

Pipeline outputs are incompatible: Modular → `[[Int32]]` (float bit patterns
punned into Int32), VarDCT → interleaved 8-bit sRGB with color hard-baked into
the bottom of `Reconstruct.swift`. Everything next — upsampling (M7), color/ICC
(M8), blending/patches (M9), CGImage bridge (M10) — wants float planes with
explicit stride and padded borders; the VarDCT code already invents this ad hoc
(`rowStride = bw * 8`, mirror-border logic duplicated in `gaborish` and `epf1`).

Define a `Plane` type (storage + width/height/stride, padded-border variant so
filters stop re-implementing mirroring) and an `ImageBundle` (color planes
tagged XYB-or-integer, extra channels, metadata) as *the* interstage currency.
Reconstruction stops at XYB float planes; color management and bit-depth
quantization become terminal stages both modes share. Also fixes the
`JXLDecodedImage.planes: [[Int32]]` + `isFloat` punning wart before app code
hardens around it.

### 4. Memory model: stop copying buffers

Three copy layers per decode: `[UInt8](data)` at every `Data` overload,
container reassembly copying the codestream out of the boxes, and
`sectionReader` doing `BitReader(Array(cs[range]))` per section. For a large
photo in a QuickLook extension that is several full-file copies before a pixel
exists. Make `BitReader` take shared storage plus a byte range (or
`ArraySlice`); single-`jxlc` files can borrow the payload range instead of
reassembling. (The byte-at-a-time `read` loop → 64-bit refill word is a
separate perf item; defer per the roadmap. The *ownership* change is
architectural and belongs in the item-1 refactor, when section readers get
restructured anyway.)

### 5. Hostile-input posture, earlier than "cross-cutting later"

QuickLook means parsing untrusted files in a system-invoked process: the bar is
"never trap, never OOM," not just "throw on malformed." Current gaps:
`precondition` in `BitReader.read`; forced unwraps in reconstruction;
`Array(cs[start..<start+size])` trapping on a malformed TOC with out-of-range
sections; and allocations sized directly from header-claimed dimensions (a
100-byte file claiming 2³⁰×2³⁰ allocates before validation). Add a
`DecodeLimits` (max pixel count / max memory) checked right after `SizeHeader`,
audit untrusted-input paths from trap to throw, and start fuzzing at the
`FrameDecoder` boundary once item 1 lands.

### 6. Shape the group loop for parallelism now, parallelize later

The TOC exists so groups decode independently, and the per-group loops are
already almost pure. In the `FrameDecoder`, keep per-group decode a pure
function of `(section bytes, immutable globals) → group result`, and keep the
coalesced single-section case (shared mutable `r0`) an explicit special case
rather than letting it shape the general path. Then `TaskGroup` parallelism is
a five-line change, and Swift-6 `Sendable` on the public value types comes
nearly free.

### 7. API surface: separate the library from its scaffolding

Milestone scaffolding is `public`: `decodeVarDCTCoefficients`,
`decodeVarDCTDCImage`, `reconstructVarDCTImage` (anonymous tuple return),
`readFrameSectionReader` (exposes `BitReader`). Once items 1–2 land, shrink the
public surface to `JXL.readInfo` / `readFrameInfo` / `decodeImage` plus
options; move stage-level access to `internal` + `@testable` (or
`@_spi(Testing)` if the standalone runner can't use `@testable`). Plan a small
`JXLKit`-style target for the CGImage bridge (currently in the viewer app;
QuickLook and third parties will want it), keeping `JXLCore` Foundation-only.

Doc note: the accumulated per-milestone "status" narratives above are becoming
a lab notebook — consider moving them to a `NOTES.md`/changelog and keeping
this file describing the current state, since multiple agents work from it as
shared truth.
