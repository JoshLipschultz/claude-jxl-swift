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
    Frame.swift         group/pass orchestration                   [M4]
    Frame.swift         role-aware TOC sections (in JXLDecoder)     [M4 ✅]
  Headers/
    CustomTransformData.swift opsin matrix + upsampling weights    [M4 ✅]
  Modular/
    MATree.swift        meta-adaptive decision tree                [M5 ✅]
    ModularImage.swift  Image/Channel sample planes                [M5 ✅]
    Predictors.swift    14 predictors + self-correcting weighted   [M5 ✅]
    ModularDecoder.swift GroupHeader, transforms, channel decode   [M5 ✅ decode]
    Transforms.swift    inverse RCT ✅ + Palette ✅ (Squeeze pending) [M5 wip]
  VarDCT/
    XYB.swift           XYB <-> linear color                       [M6]
    DCT.swift           separable DCTs for all block sizes         [M6]
    Quant.swift         adaptive quant field + dequant weights     [M6]
    ChromaFromLuma.swift                                           [M6]
    VarDCTDecoder.swift LF/HF assembly, coefficient decode         [M6]
  Restoration/
    Gaborish.swift      Gabor-like smoothing                       [M7]
    EPF.swift           edge-preserving filter                     [M7]
    Upsampling.swift                                               [M7]
  Color/
    ColorManagement.swift XYB->linear->display, tone mapping       [M8]
  JXLImage.swift        decoded pixel buffer (public)              [M5+]
  JXLDecoder.swift      top-level orchestrator                     [M1 ✅ partial]
  Errors.swift                                                     [M1 ✅]
```

## Milestones

| #  | Milestone | Deliverable | Status |
|----|-----------|-------------|--------|
| M1 | Foundation | container demux, dimensions, CLI, oracle harness | ✅ done |
| M2 | Image metadata | full `ImageMetadata` bit-exact vs libjxl (depth, channels, full color encoding) | ✅ done |
| M3 | Entropy coding | prefix + ANS + LZ77 + context modeling | ✅ done — validated on real codestream data via the MA tree |
| M4 | Frame layer | FrameHeader, TOC, role-aware sections | ✅ structural parser done |
| M5 | **Modular mode** | lossless `.jxl` → pixels | 🟢 **all 17 lossless fixtures byte-exact vs djxl** — single + multi-group, RCT + Palette, gray/RGB/RGBA/8/16-bit. Float, Squeeze, progressive remain |
| M6 | VarDCT mode | lossy photographic `.jxl` → pixels | 🟢 **DCT8 lossy → pixels at ~54 dB vs djxl** — full pipeline (entropy → dequant → IDCT → CfL → XYB→sRGB); residual is only the not-yet-applied Gaborish/EPF (M7). Larger DCT sizes (16/32/AFV) remain |
| M7 | Restoration | Gaborish + EPF + upsampling | 🟡 Gaborish + EPF1 implemented (faithful ports); near-identity on the current DCT8 corpus (encoder leaves them off/weak), so full validation waits on images that use them. Upsampling remains |
| M8 | Color pipeline | XYB→sRGB, ICC, alpha, 8/16-bit/float output | |
| M9 | Advanced | patches, splines, noise, animation, extra channels, JPEG recon | |
| M10 | macOS integration | `CGImage` bridge + Quick Look thumbnail/preview appex | |

Cross-cutting, ongoing: conformance corpus from the libjxl test suite, fuzzing,
and SIMD/performance once correctness is locked per stage.

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
transpose relative to the pixel layout. The remaining ≈54 dB gap is exactly the
Gaborish + edge-preserving filter (M7), which libjxl applies and we don't yet;
larger transforms (DCT16/32/…, AFV) are the other remaining piece.

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
