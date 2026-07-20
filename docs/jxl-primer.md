# A JPEG XL Primer for This Codebase

JPEG XL (ISO/IEC 18181) is a royalty-free image format with two coding paths —
a lossless/near-lossless **Modular** mode and a lossy, DCT-based **VarDCT**
mode — sharing one container, one header layer, one frame model, and one
entropy-coding substrate. This document is the conceptual map: what each layer
of the format does, why it exists, and where its implementation lives in this
repository's pure-Swift decoder (`Sources/JXLCore`). The reference
implementation used as the test oracle throughout is **libjxl v0.11.2**;
libjxl file names cited below (e.g. `dec_frame.cc`) are paths under its
`lib/jxl/`.

## Table of contents

1. [Format overview: container and codestream](#1-format-overview-container-and-codestream)
2. [Codestream headers](#2-codestream-headers)
3. [The frame model](#3-the-frame-model)
4. [Entropy coding](#4-entropy-coding)
5. [Modular mode](#5-modular-mode)
6. [VarDCT mode](#6-vardct-mode)
7. [Progressive decoding](#7-progressive-decoding)
8. [Frame features: splines, noise, patches](#8-frame-features-splines-noise-patches)
9. [Color management on output](#9-color-management-on-output)
10. [JPEG bitstream reconstruction (jbrd)](#10-jpeg-bitstream-reconstruction-jbrd)
11. [Glossary](#11-glossary)
12. [Reading list](#12-reading-list)

---

## 1. Format overview: container and codestream

A `.jxl` file comes in two shapes:

- **Bare codestream** — the file starts directly with the two signature bytes
  `FF 0A` and is nothing but the codestream. This is what `cjxl` emits by
  default for simple encodes.
- **ISOBMFF container** — the file starts with the fixed 12-byte signature box
  `00 00 00 0C 'JXL ' 0D 0A 87 0A` followed by a `ftyp` box (brand `jxl `),
  then a sequence of boxes in the usual ISO base-media format (4-byte size,
  4-byte type, payload; size 1 means a 64-bit `largesize` follows). The
  container exists so the codestream can travel with metadata that has no
  place inside it.

The boxes that matter:

| Box | Contents |
|---|---|
| `jxlc` | The entire codestream in one box. |
| `jxlp` | A *partial* codestream. Multiple `jxlp` boxes are concatenated in order; each payload begins with a 4-byte index whose high bit marks the final part. Exists so a streaming encoder can interleave codestream chunks with other boxes. |
| `jxll` | The **level** byte: 5 (default) or 10. Levels are conformance profiles — level 5 caps dimensions (≤ 2²⁸ per side, ≤ 2³⁰ pixels), bit depth (≤ 16), channel counts, etc.; level 10 raises the caps for huge/scientific images. A decoder can use it to reject files beyond its capability up front. |
| `Exif` | Exif metadata: a 4-byte big-endian offset, then a TIFF-header Exif payload. |
| `xml ` | XMP (XML) metadata. |
| `brob` | A **Brotli-compressed box**: the first 4 payload bytes are the *inner* box type (e.g. `Exif`, `xml `), the rest is a Brotli stream of that box's payload. This is why the decoder carries a full Brotli implementation. |
| `jbrd` | JPEG bitstream reconstruction data — see [§10](#10-jpeg-bitstream-reconstruction-jbrd). |

Either way, the codestream itself always begins with `FF 0A` and has the
layered structure the rest of this document walks through: `SizeHeader` →
`ImageMetadata` (+ optional ICC) → `CustomTransformData` → byte-alignment →
frames.

**Where it lives here:** `Container/Container.swift` (box demux, `jxlc`/`jxlp`
reassembly, signature constants, `brob` unwrapping via
`Brotli/BrotliDecoder.swift`). This decoder currently ignores `jxll` and
enforces its own resource caps via `JXLDecodeLimits` instead
(`Frame/FrameDecoder.swift`).

## 2. Codestream headers

All header fields use a small vocabulary of bit-level field types (spec
clause "Fields"): `u(n)` fixed-width bits, `U32(d0,d1,d2,d3)` — a 2-bit
selector choosing one of four distributions, each either a literal value or
`n` raw bits plus an offset — `U64`, `Bool`, `F16` (half-float), and `Enum`
(a `U32` with a fixed distribution). Many bundles start with an `all_default`
bit that stands in for the entire bundle. Getting one distribution wrong
desyncs everything after it, which is why this layer is validated bit-exactly
against libjxl.

**Where it lives here:** `Bitstream/BitReader.swift` (LSB-first reader),
`Bitstream/Fields.swift` (the field vocabulary).

### SizeHeader

Width and height, with a compact encoding: a `small` bit selects a
multiple-of-8 ≤ 256 shortcut; otherwise sizes are `U32`-coded, and the width
can optionally be derived from the height through one of seven fixed aspect
ratios. A preview image, if present, gets its own small size header inside
`ImageMetadata`.

**Where it lives here:** `Headers/SizeHeader.swift`.

### ImageMetadata

The image-wide metadata bundle (libjxl `ImageMetadata::VisitFields`,
`image_metadata.cc`). In field order, the parts that matter:

- **`extra_fields`** — when set: **orientation** (EXIF values 1–8; the
  decoder must apply it, unlike JPEG where it is advisory), optional intrinsic
  size, an optional **preview** header, and the **animation header** (tick
  rate as `tps_numerator/tps_denominator`, loop count where 0 = forever,
  `have_timecodes`). Frame durations live in each frame header, measured in
  these ticks.
- **BitDepth** — `bits_per_sample` and, when samples are floating point,
  `exponent_bits_per_sample > 0` (e.g. 32-bit float = 32/8, half = 16/5).
  This describes the *original* sample type; Modular mode codes float samples
  as their bit patterns.
- **`modular_16bit_buffers`** — a promise that Modular data fits 16-bit
  buffers (a libjxl memory optimization; this decoder uses Int32 planes
  regardless).
- **Extra channels** — a count, then per-channel `ExtraChannelInfo`: type
  (alpha, depth, spot color, selection mask, black/CMYK, CFA, thermal,
  optional/unknown), its own BitDepth, `dim_shift` (the channel is stored at
  `1 << dim_shift` downsampling), a name, and for alpha whether the color
  channels are **premultiplied** by it.
- **`xyb_encoded`** — the single most consequential bit in the file: whether
  frames are stored in the XYB opsin color space (lossy path) or in the
  declared color space directly (lossless path). It decides whether the
  decoder must run the inverse opsin transform, and whether
  `CustomTransformData` carries an opsin matrix.
- **ColorEncoding** — see below.
- **ToneMapping** — `intensity_target` (nits; default 255), `min_nits`,
  `relative_to_max_display`, `linear_below`. See [§9](#9-color-management-on-output).
- **Extensions** — a forward-compatibility escape: a bitmask of extension ids,
  then a length per extension so unknown ones can be skipped.

**Where it lives here:** `Headers/ImageMetadata.swift` (`JXLImageMetadata`,
`JXLBitDepth`, `JXLExtraChannelInfo`, `JXLToneMapping`, `JXLAnimationInfo`).

### ColorEncoding: enumerated vs embedded ICC

A JXL file declares its color space one of two ways:

- **Enumerated** — color space (RGB / grayscale / XYB / unknown), white point
  (D65, E, DCI, or custom xy chromaticity), primaries (sRGB, BT.2100, P3, or
  custom), transfer function (sRGB, linear, PQ, HLG, 709, DCI, or an explicit
  gamma), and rendering intent. Compact, and lets a decoder do color math
  directly.
- **Embedded ICC** — the `want_icc` bit says "the authoritative description is
  an ICC profile embedded in the codestream." The profile itself is not stored
  raw: it goes through a dedicated ICC codec (a domain-specific predictor +
  the shared entropy coder) that typically shrinks profiles several-fold.
  Decoding it is a byte-exact reconstruction (`ReadICC` + `UnpredictICC` in
  libjxl `icc_codec.cc`).

Note the two are not exclusive in effect: even with `want_icc`, lossy files
are still XYB-encoded and the decoder still needs *some* numeric
understanding of the target space to leave XYB (see [§9](#9-color-management-on-output)).

**Where it lives here:** `Headers/ImageMetadata.swift` (`JXLColorEncoding`),
`Color/ICCCodec.swift` (embedded-profile decode, byte-exact vs djxl),
`Color/ICCOutput.swift` (using a decoded matrix+TRC profile as the *output*
space).

### CustomTransformData

A small bundle after `ImageMetadata` holding overridable decoder constants:

- **Custom opsin inverse matrix** (only when `xyb_encoded`): the 3×3
  XYB→linear-RGB inverse absorbance matrix, three opsin biases, and four AC
  dequantization biases. Almost every file uses the defaults
  (`all_default = 1`), but a conforming decoder must honor overrides.
- **Custom upsampling weights**: the ×2/×4/×8 upsampling kernels are derived
  from 15/55/210 half-float weights (the defaults live in the spec); a file
  may replace them.

**Where it lives here:** `Headers/CustomTransformData.swift`;
default kernels in `VarDCT/UpsamplingWeights.swift`.

## 3. The frame model

A codestream is a sequence of **frames**. A single still image is one frame;
animations, layered images, patch dictionaries, and progressive DC previews
are all expressed as multiple frames. Each frame is:

```
FrameHeader → TOC → sections…
  LfGlobal                     patches, splines, noise, DC quant info,
                               global Modular tree/stream
  LfGroup × numDCGroups        per-DC-group low-frequency data
                               (VarDCT DC + AC metadata, or Modular DC channels)
  HfGlobal                     VarDCT only: dequant matrices, coefficient
                               orders, AC histograms
  PassGroup × groups × passes  per-group AC coefficients / Modular channel data
```

If the frame has exactly one group and one pass, all of that is coalesced
into a **single section**.

### Frame types

`FrameType` (libjxl `frame_header.h`):

- **`kRegularFrame` (0)** — a presented frame (or a layer composited into one).
- **`kDCFrame` (1)** — stores the 8×-downsampled image that a later frame
  references instead of coding its own DC (see [§7](#7-progressive-decoding)).
  Never presented directly.
- **`kReferenceOnly` (2)** — decoded only to fill a reference slot, e.g. as a
  patch source. Always full-image-size, never presented.
- **`kSkipProgressive` (3)** — a regular frame that tells progressive
  renderers not to display intermediate passes (used when a later kRegular
  frame will blend over it).

### FrameHeader fields worth knowing

- **`encoding`** — Modular vs VarDCT. Per frame, not per file: a lossy file's
  patch dictionary frame may be Modular while the main frame is VarDCT.
- **`flags`** — a `U64` bitmask: `kNoise` (1), `kPatches` (2),
  `kSplines` (16), `kUseDcFrame` (32), `kSkipAdaptiveDCSmoothing` (128).
- **`color_transform`** — XYB, None, or YCbCr. YCbCr (with optional 4:2:2 /
  4:2:0 chroma subsampling via `chromaChannelMode`) exists essentially for
  JPEG transcodes; native lossy encodes use XYB.
- **`upsampling` / `ec_upsampling`** — the frame is coded at 1/2, 1/4, or 1/8
  size and upsampled at the end (per extra channel too).
- **`group_size_shift`** — group dimension = `128 << shift` (default shift 1
  → 256×256 groups).
- **`passes`** — number of passes, per-pass coefficient `shift`s and
  `downsample` brackets ([§7](#7-progressive-decoding)).
- **Crops and origins** — `custom_size_or_origin` gives the frame its own
  `frameWidth/Height` and a signed `frameX0/Y0` origin: frames may be smaller
  than the canvas (layers), larger, or negatively offset. A frame that does
  not cover the canvas *must* blend.
- **Blending** — a `BlendingInfo` for color and one per extra channel: mode
  (0 Replace, 1 Add, 2 Blend i.e. alpha-over, 3 AlphaWeightedAdd, 4 Mul),
  which alpha channel drives it, a `clamp` bit, and which reference slot is
  the background `source`.
- **`duration`** (animation ticks; 0 = this frame composites with the next
  one into the same displayed image — that is how layered stills work) and
  optional 32-bit SMPTE `timecode`.
- **`is_last`, `save_as_reference` (0–3), `save_before_color_transform`** —
  after decoding, a frame may be stored into one of **four reference slots**.
  `save_before_color_transform` stores the pre-color-transform planes (XYB
  for lossy) — required for patch sources and DC frames; blending backgrounds
  for presented frames are saved after.
- **Restoration-filter controls** — Gaborish on/off + custom weights, EPF
  iteration count (0–3) and sharpness/sigma parameters
  ([§6](#6-vardct-mode)).

### TOC: sections and permutation

The **TOC** (table of contents) after the frame header lists the byte size of
every section (`U32`-coded, `kTocDist`). A leading bit optionally introduces
a **permutation** (a Lehmer code, decoded with the full entropy machinery —
the TOC is the first entropy-coded data in a file): sections may be stored in
any order, and the TOC maps stored order back to logical order. Encoders use
this to front-load DC and LF sections for progressive display. After the TOC
the reader is byte-aligned, and every section is an independent, byte-aligned,
independently decodable blob — this is what makes per-group parallel decode
possible.

### The frame walk, compositing, and animation

Decoding a multi-frame file is a loop: parse `FrameHeader` + TOC, decode the
frame, optionally store it in a reference slot, blend it onto its background
(the canvas or a reference slot) per its `BlendingInfo` with crop/origin
clipping, present it if it has a duration or `is_last`, continue until
`is_last`. Layered stills are the duration-0 case of the same machinery;
animations are the duration>0 case with the animation header's tick rate.

**Where it lives here:** `Frame/FrameHeader.swift`,
`Frame/FrameDimensions.swift` (group/DC-group grid math), `Frame/TOC.swift`
(sizes + Lehmer permutation), `Frame/FrameDecoder.swift` (the single-parse
orchestrator: headers + TOC once, staged decode, section-bounds validation,
the multi-frame walk with `skipPresentedFrames` and reference-slot
accumulation), `Frame/FrameComposite.swift` (the blending port of libjxl
`blending.cc` / `stage_blending.cc`, including premultiplied-alpha handling
and libjxl's inverted-clamp quirk in the alpha-plane blend), and
`JXLDecoder.swift` (`JXL.decodeFrames` for animation).

## 4. Entropy coding

Everything entropy-coded in JXL — TOCs, MA trees, Modular residuals, VarDCT
coefficients, ICC profiles, patch/spline parameters — goes through **one
substrate** (libjxl `dec_ans.cc`, `dec_huffman.cc`, `dec_context_map.cc`).
A block of coded data is preceded by a header declaring, in order:

1. **LZ77 parameters** — enabled flag, `min_symbol`, `min_length`. When
   enabled, decoded values ≥ `min_symbol` are copy commands: a length token,
   then a distance token, replaying previously decoded *values* (not bytes).
   Distances can use a table of 120 special two-dimensional offsets (useful
   for image-shaped data) or plain offsets.
2. **The context map** — the coder is context-modeled: each call site
   supplies a context id, and the context map (an array `context → cluster`)
   collapses the potentially many contexts onto a small set of **clustered
   histograms**. The map itself is either "simple" (raw bits) or recursively
   entropy-coded with an optional move-to-front transform.
3. **Prefix-vs-ANS flag** — one bit selects the backend for all clusters:
   - **Prefix codes**: Brotli-style canonical Huffman, ≤ 15-bit codes, with
     compact code-length coding. Chosen for small payloads where ANS table
     cost dominates.
   - **ANS**: a range-variant asymmetric numeral system with 12-bit
     precision (4096 states). Each cluster's histogram is coded (small /
     flat / general with RLE), then realized as an **alias table** for O(1)
     symbol lookup. The reader keeps a 32-bit state, refills 16 bits at a
     time, and the state must equal `0x130000` (the initial value) after the
     last symbol — the **ANS final-state check**, a free integrity check the
     decoder verifies at the end of every stream. A single wrong context
     anywhere desyncs the state, so a passing check is strong evidence of a
     bit-exact decode.
4. **Per-cluster hybrid-uint configs.** Symbols are not raw integers: a value
   is split into a **token** (entropy-coded) and **raw bits**. Config
   `(split_exponent, msb_in_token, lsb_in_token)`: values below
   `2^split_exponent` are their own token; larger values put the exponent and
   a few MSBs/LSBs in the token and the middle bits raw. This keeps alphabets
   small while coding unbounded integers.

**Where it lives here:** `Entropy/HybridUint.swift`,
`Entropy/PrefixCode.swift`, `Entropy/ANS.swift` (histograms + alias table),
`Entropy/ANSReader.swift` (state machine + LZ77 layer),
`Entropy/EntropyDecoder.swift` (header assembler, context map, MTF).

## 5. Modular mode

Modular mode is a general-purpose, fully reversible image coder: integer
channels, per-pixel prediction driven by a decision tree, residuals through
the entropy coder, and a stack of invertible transforms. It codes lossless
images end-to-end, and inside VarDCT frames it carries the DC image, AC
metadata, and extra channels — so it is always in play.

### Channels and streams

A Modular image is an ordered list of channels, each with its own size and
`(hshift, vshift)` downsampling shifts. Channels are decoded in order, and
earlier channels can inform later ones (palette indices, squeeze residuals,
MA-tree properties from "previous channel" values). Transforms may prepend
**meta-channels** (e.g. the palette).

A frame's Modular data is split across sections as sub-streams identified by
a **stream id** (libjxl `ModularStreamId`): stream 0 is the **global stream**
(decoded in LfGlobal; holds channels small enough to not warrant splitting —
after shifts, dimensions ≤ group size), then per-DC-group streams (VarDCT DC
= id `1+g`, Modular DC for heavily squeezed channels = id
`1 + numDCGroups + g`), AC metadata streams, and per-group-per-pass
**ModularAC** streams holding each group's rectangle of the remaining
channels. Which channels appear in which pass-group stream is decided by
**shift brackets**: each pass covers a `[minShift, maxShift)` range derived
from its downsample bracket (8→3, 4→2, 2→1, 1→0), and a channel belongs to
the pass whose bracket contains its shift. Channels with shift ≥ 3 ride the
DC-group streams so a DC-only decode can reconstruct a 1/8 preview.

### MA trees and prediction

Every Modular stream is decoded under a **meta-adaptive (MA) tree** — a
binary decision tree, itself entropy-coded (either one global tree in
LfGlobal shared by all streams, or a local tree per stream). Interior nodes
test `property > value`; leaves carry a **predictor**, a signed offset, and a
multiplier. Per pixel, the decoder computes the properties, walks the tree,
entropy-decodes a residual in the leaf's context (leaf index = entropy
context — this is how context modeling reaches Modular), then reconstructs
`value = predictor + offset + multiplier * unpack_signed(residual)`.

The properties (indices as in libjxl `context_predict.h`): 0 channel index,
1 stream id, 2 y, 3 x, 4 |N|, 5 |W|, 6 N, 7 W, 8 W minus the prediction at
W (local error), 9 W+N−NW (the gradient prediction), 10 W−NW, 11 NW−N,
12 N−NE, 13 N−NN, 14 W−WW, 15 the weighted predictor's `max_error`, and
16+ are values from previously decoded channels at the same position. The
tree splitting on *static* properties (0/1) effectively specializes the tree
per channel/stream.

The 14 predictors: Zero, Left, Top, Average0 ((W+N)/2), Select, Gradient
(clamped W+N−NW), **Weighted**, TopRight, TopLeft, LeftLeft, Average1–4, —
where **Weighted** is the self-correcting weighted predictor (WP): four
sub-predictors combined with weights continuously updated from their recent
prediction errors, plus a per-pixel `max_error` property the tree can branch
on. It is the expensive one; this decoder skips its bookkeeping entirely when
the tree provably never consults it (libjxl's `use_wp` gating).

### Transforms

After all channels decode, the transform stack is inverted in reverse order:

- **RCT** (reversible color transform): 42 variants = 7 channel permutations
  × 6 lifting-style transforms (including YCoCg-like). Exactly invertible in
  integers.
- **Palette**: replaces up to all channels with one index channel plus a
  palette meta-channel. The index space is layered (libjxl
  `GetPaletteValue`): `[0, palette_size)` hits the explicit palette;
  indices above it address *implicit* colors (an 8×8×8 small color cube,
  then a larger cube) that cost no palette storage; negative indices mirror
  a fixed 72-entry signed **delta table**. When `nb_deltas > 0`, indices
  below it are **delta pixels**: the looked-up value is *added to a
  per-pixel prediction* (any of the 14 predictors, including WP) instead of
  used directly — this is what makes palette lossy-capable
  (`--lossy_palette`).
- **Squeeze**: a Haar-like lifting wavelet. Each step splits a channel into a
  half-resolution average channel and a residual channel, with a
  **smooth tendency** term making the averages visually good previews.
  Iterated, it gives Modular files a multi-resolution structure (this is what
  makes shift brackets meaningful and Modular progressive). Default
  parameters squeeze down until the top level fits in one group.

### Lossy Modular

Two lossy paths reuse the machinery: quantizing squeeze residuals (still
decoded identically; the inverse squeeze just reconstructs an approximation),
and **XYB Modular** (`xyb_encoded` + Modular frame): channels are Y, X, B−Y,
scaled by the DC quant factors, and the output flows into the same
XYB→display pipeline as VarDCT.

**Where it lives here:** `Modular/MATree.swift`, `Modular/Predictors.swift`
(14 predictors + WP), `Modular/ModularDecoder.swift` (GroupHeader, property
computation, channel decode, stream plumbing), `Modular/Transforms.swift`
(inverse RCT/Palette/Squeeze incl. `SmoothTendency`),
`Modular/ModularImage.swift` (planes).

## 6. VarDCT mode

VarDCT is the lossy path: a photographic coder in the JPEG lineage —
block transforms, quantization, entropy coding — with every knob modernized.

### XYB and the opsin transform

Lossy JXL operates in **XYB**, a perceptual color space derived from human
cone responses: linear RGB is mixed through the opsin absorbance matrix into
LMS-like components with a bias, cube-rooted (an approximation of
psychovisual lightness), and recombined as X (L−M, red-green), Y (L+M,
luminance-like), B (S, blue). Quantization error in XYB is roughly
perceptually uniform, which is the point. The decoder inverts this:
per-pixel cube (undoing the cube root, with the bias folded in as
`cbrt(−bias)`), then the 3×3 inverse matrix (possibly custom, see
CustomTransformData) to linear RGB, scaled by `255 / intensity_target`.

### DC image and adaptive smoothing

Each 8×8 block's DC coefficient (its mean) forms the **DC image** at 1/8
resolution. It is coded as a Modular sub-stream per DC group (quantized by
per-channel DC quants), then — unless `kSkipAdaptiveDCSmoothing` — the
decoder applies **adaptive DC smoothing**, a conditional blur that smooths DC
only where the change stays within one quantization step, removing 8×8
blocking in flat gradients for free.

### AC strategies: the 27 transforms

Instead of a fixed 8×8 DCT, each **varblock** picks one of 27 transform
types (libjxl `AcStrategy`): DCT8×8; DCT of every rectangular size from 8×16
/ 16×8 up to 256×256; the small-block specials IDENTITY (near-lossless
pixels), DCT2×2, DCT4×4, DCT4×8/8×4; and AFV0–3 (a 4×4 corner triangle basis
for hard diagonal edges, in 4 orientations). The **AC strategy field** —
itself Modular-coded inside each DC group's AcMetadata stream — tiles every
DC group exactly: each varblock covers 1×1 up to 32×32 blocks, larger
transforms trading ringing risk for coding efficiency on smooth areas.

For a varblock of N×M blocks, the lowest N×M frequency coefficients (the
**LLF**) are not coded in the AC stream — they are recomputed from the DC
image via a reinterpreting low-frequency DCT, so the DC image stays exactly
the 1/8 view regardless of transform sizes.

### Quantization

Dequantization of coefficient `c` in channel/frequency position `(ch, k)` of
a block with raw quant value `qf`:
`value ≈ c · dequant_matrix[ch][k] · global_scale / qf`, refined by
**quant biases** (`AdjustQuantBias`): coefficients of magnitude 1 are nudged
toward the center of mass of their quantization bucket instead of the bucket
edge, per-channel, per the four bias constants.

- **Global scale + quant_dc** come from LfGlobal.
- The **quant field** (per-block `qf`) is Modular-coded in AcMetadata —
  this is adaptive quantization, the encoder spending bits where the eye
  looks. It is replicated across all cells of a multi-block varblock.
- **Dequant matrices** (per strategy × channel) come from HfGlobal: default
  library tables, parametrized encodings (DCT-shaped falloffs, distance
  bands, AFV), or RAW (Modular-coded verbatim — used by JPEG transcodes).
  X and B channels get frame-level `x_qm_scale` / `b_qm_scale` multipliers.

### Chroma from luma (CfL)

X and B are predicted from Y: per 64×64 **color tile**, AcMetadata carries
correlation factors `ytox` and `ytob`, and dequantized X/B coefficients get
`+ factor · Y-coefficient` added (base correlation + tile delta /
`color_factor`, default 84). Since blue-yellow and red-green structure
usually tracks luma, this removes most chroma energy for free. (For JPEG
transcodes the same machinery runs in fixed-point over the JPEG's actual
quant tables so it stays exactly invertible.)

### AC entropy: orders and contexts

Per pass, HfGlobal codes for each used strategy a **coefficient order** —
a zigzag-like "natural" order, optionally permuted per-file via a Lehmer
code (encoders sort by average coefficient magnitude). AC groups then decode
per varblock, per channel in **Y, X, B order**: first the **non-zero count**
(context-predicted from the neighbor blocks above/left), then that many
coefficients in scan order, each in a **zero-density context** derived from
(number of non-zeros remaining, position in scan). A **block context map**
first buckets (channel, strategy's order bucket, optional DC/qf thresholds)
into histogram clusters. Every AC group's stream ends in an ANS final-state
check.

### Restoration filters

After the inverse transforms produce XYB pixels, two in-loop filters run
(both mandatory parts of the codec — the encoder anticipated them):

- **Gaborish**: a fixed 3×3 blur (per-channel weights in FrameHeader) that
  undoes the encoder's pre-sharpening; softens residual block edges.
- **EPF** (edge-preserving filter): 1–3 passes of a self-guided
  bilateral-style filter. Tap weights come from a 3-channel SAD between
  pixel neighborhoods scaled by a per-block **sigma** derived from the quant
  field and a per-block sharpness value (AcMetadata) — more smoothing where
  quantization was coarse, none across real edges. Pass order at
  `epf_iters = 3/2/1` is EPF0 (5×5) → EPF1 (3×3) → EPF2 (3×3).

Then, in order: patches, splines, noise ([§8](#8-frame-features-splines-noise-patches)),
and **upsampling** (×2/×4/×8, 5×5 kernels from the default or custom weight
tables) if the frame was coded downsampled.

### Chroma subsampling

Native VarDCT is always 4:4:4 in XYB. YCbCr frames (JPEG transcodes) may be
4:2:2/4:2:0 via per-channel shifts; chroma is upsampled with a triangle
filter after reconstruction.

**Where it lives here:** `VarDCT/VarDCTInfo.swift` (DC-global: quantizer,
block context map), `VarDCT/DCImage.swift` (DC decode + dequant + adaptive
smoothing), `VarDCT/ACMetadata.swift` (strategy field, quant field, EPF
sharpness, CfL tiles), `VarDCT/CoeffOrder.swift`, `VarDCT/PassGroup.swift`
(AC entropy), `VarDCT/DequantWeights.swift`, `VarDCT/DCTTransforms.swift`
(inverse transforms + LLF insertion), `VarDCT/Reconstruct.swift`
(dequant → CfL → IDCT → Gaborish/EPF → XYB planes),
`VarDCT/Upsampling.swift` + `UpsamplingWeights.swift`.

## 7. Progressive decoding

JXL is progressive by construction, through four cooperating mechanisms:

- **DC-first layout.** The DC image (1/8 × 1/8) lives in the LF sections. A
  decoder with only LfGlobal + LfGroups can already render a 1:8 preview —
  this is also what a thumbnailer decodes for large files.
- **DC frames (`kUseDcFrame`).** For a real progressive encode, the frame's
  flags say "my DC is the previous `kDCFrame`" — a full nested frame (itself
  usually VarDCT) stored at 1/8 size in reference slot `dc_level`. DC frames
  nest up to 4 deep (1/8, 1/64, …), so a gigapixel image can open with a
  tiny first chunk.
- **Passes.** A frame's AC coefficients can split across up to 11 passes.
  Each pass has a `shift`: coefficients arrive divided by `2^shift`
  (bit-plane refinement), with later passes adding the missing low bits.
  Passes also carry `downsample` markers (8/4/2/1) telling a renderer "after
  this pass you effectively have a 1/N image" — for VarDCT via
  coefficient-energy ordering, for Modular via the squeeze shift brackets
  ([§5](#5-modular-mode)).
- **TOC permutation.** Sections are reordered so that everything a partial
  render needs comes first in the byte stream.

What a progressive renderer shows: DC frame / LF sections → 1:8 preview;
first AC pass → full-resolution but coarse (or its downsample bracket);
each further pass sharpens until the final pass is the exact image.

**Where it lives here:** pass metadata parses in `Frame/FrameHeader.swift`
(`numPasses`, `passShifts`, `passDownsample`) and the section walk in
`Frame/FrameDecoder.swift`/`Frame/TOC.swift`. Multi-pass *rendering* is not
yet implemented here (single-pass fixtures throughout); DC-frame handling
rides the reference-slot machinery.

## 8. Frame features: splines, noise, patches

Three synthesis features run between reconstruction and the color transform.
All three exist because some image content is cheaper to *describe* than to
code as pixels.

### Patches (flags bit 2)

The **patch dictionary** (head of LfGlobal, libjxl `dec_patch_dictionary.cc`)
references rectangular crops of frames stored in the four reference slots
(typically a `kReferenceOnly` frame coded lossless-Modular) and blends each
crop at many entropy-coded positions with per-channel blend modes (None,
Replace, Add, Mul, BlendAbove/Below, AlphaWeightedAddAbove/Below). Use case:
text and logos — code the glyphs once, sharp, and stamp them; the VarDCT
layer underneath then doesn't waste bits fighting ringing around every
letter. Positions are delta-coded; blending happens after filters, before
the color transform, in encoded (XYB) space.

### Splines (flags bit 4, value 16)

Centripetal Catmull-Rom curves with entropy-coded control points, plus a
32-coefficient DCT each for the three color channels and for the Gaussian
sigma along the curve. Rendering interpolates the curve, resamples at unit
arc length, and splats a Gaussian at each sample onto the XYB planes. Meant
for hair-thin high-contrast strokes that DCTs handle terribly. Rendered
after patches, before upsampling; the float math is specified down to
libjxl's `FastCosf`/`FastErff` polynomial approximations, since the outputs
feed pixels directly.

### Noise (flags bit 0)

Photographic grain is expensive to code and dies under quantization, so JXL
re-synthesizes it: an 8-entry lookup table (intensity → noise strength,
10 bits each) is the entire coded payload. The decoder generates
pseudo-random planes with an **xorshift128+ RNG seeded per 256×256 tile from
the frame index and tile origin** — fully deterministic, so every conforming
decoder (and every decode of the same file) produces the identical grain —
convolves them with a 5×5 Laplacian-like kernel, and adds
intensity-modulated noise to the color channels with the CfL base
correlations coupling X and B to Y.

**Where it lives here:** `Frame/PatchDictionary.swift`,
`Frame/Splines.swift`, `Frame/NoiseSynthesis.swift`; application order in
`VarDCT/Reconstruct.swift` / `Frame/FrameDecoder.swift`.

## 9. Color management on output

For an XYB-encoded frame the decoder ends with float XYB planes; producing
display pixels means:

1. **XYB → linear RGB**: inverse opsin ([§6](#6-vardct-mode)), giving linear
   sRGB-primaries RGB scaled so that 1.0 = `intensity_target` nits.
2. **Primaries/white point**: if the declared encoding is not
   sRGB-primaries/D65, convert via 3×3 RGB→XYZ→RGB matrices with **Bradford
   chromatic adaptation** between white points.
3. **Transfer function**: encode with the declared curve — sRGB piecewise,
   BT.709, DCI (γ2.6), plain gamma, linear, **PQ** (SMPTE ST 2084; an
   *absolute* curve: display 1.0 maps to `intensity_target` nits on the
   10000-nit scale, and content may legitimately exceed 1.0), or **HLG**
   (ARIB STD-B67 OETF, with inverse-OOTF handling using the target
   primaries' luminances).
4. **Quantize** to the requested sample format (8/16-bit int or float).

**`intensity_target` semantics:** the peak luminance the image is mastered
for — 255 nits for SDR (the default), typically 1000–10000 for PQ/HLG
content. It scales the inverse opsin output, anchors PQ's absolute mapping,
and is what a tone-mapping display pipeline should treat as content peak.

**ICC output:** when the file's authoritative encoding is an embedded ICC
profile, the decoded profile should be attached to the output verbatim
(byte-exact decode, [§2](#2-codestream-headers)). If the caller wants actual
pixels in that space, matrix+TRC display profiles can be applied numerically;
arbitrary (CLUT/CMYK) profiles need a real CMS.

**Gamut:** XYB covers more than any output RGB space, so out-of-gamut values
appear (especially with PQ). This decoder hard-clamps; libjxl desaturates
toward the luminance axis — the residual visible in PQ comparisons.

**Where it lives here:** `Color/ColorManagement.swift` (inverse opsin,
primaries matrices + Bradford, all transfer curves, the threshold-table
quantizers that are bit-identical to the `powf` reference),
`Color/ICCCodec.swift` (embedded-profile decode), `Color/ICCOutput.swift`
(matrix+TRC ICC as output space). Display integration (CGImage color-space
tagging, EDR) is `Sources/JXLKit/JXLImageConverter.swift`.

## 10. JPEG bitstream reconstruction (jbrd)

A JPEG can be transcoded to JXL ~20% smaller and later reconstructed
**byte-exactly**. This works because a JPEG's information content splits
cleanly:

- **The DCT coefficients** — JPEG's quantized 8×8 DCT values are stored
  *exactly* in a VarDCT frame: `color_transform` None or YCbCr (never XYB),
  DCT8-only strategies, the JPEG quant tables carried as RAW dequant
  matrices, chroma subsampling preserved, and JXL's CfL run in fixed-point so
  the stored values round-trip to the original integers. JXL merely
  re-entropy-codes them (ANS + context modeling beats Huffman + zigzag RLE).
- **Everything else** — the `jbrd` box stores what the codestream cannot:
  the exact marker sequence, APPn/COM payloads (Brotli-compressed), Huffman
  tables, scan script and progressive parameters, restart intervals, the
  padding bits before each marker, encoder quirks like extra zero-runs —
  every degree of freedom the original entropy coder had.

Reconstruction: decode the codestream's quantized coefficients (kept as raw
integers, never dequantized), undo JXL's transcode-time transforms (CfL,
per-block transpose) in exact integer arithmetic, then replay `jbrd`'s
marker walk, re-encoding scans with the stored Huffman tables and the stored
padding decisions. Exif/XMP come back from container boxes; the ICC profile
is re-chunked into APP2 segments. The output is bit-identical to the source
JPEG, verified byte-for-byte.

**Where it lives here:** `JPEG/JPEGReconData.swift` (the `jbrd` bundle parse,
libjxl `JPEGData::VisitFields`), `JPEG/JPEGRecon.swift` (coefficient
restoration and assembly), `JPEG/JPEGWriter.swift` (the
`dec_jpeg_data_writer` port: marker walk, sequential/progressive scan
encoders, stuffing/restarts/padding), `Brotli/BrotliDecoder.swift` +
`BrotliDictionary.swift` (RFC 7932, needed for `jbrd` and `brob`). Public
entry: `JXL.reconstructJPEG` (`jxl tojpeg` in the CLI).

## 11. Glossary

- **Block** — an 8×8 pixel tile; the unit of the DC image and quant field.
  `kBlockDim = 8` (`Frame/FrameDimensions.swift`).
- **Varblock** — one transform's coverage: 1×1 up to 32×32 blocks (8×8 …
  256×256 pixels), per its AC strategy.
- **Group** — the unit of parallel/random-access coding: `128 <<
  group_size_shift` pixels square, default **256×256**. One AC/PassGroup
  section per group per pass.
- **DC group** — the LF unit: the same grid measured in *blocks*, i.e.
  2048×2048 pixels at default group size. One LfGroup section each.
- **Section** — one independently decodable, byte-aligned TOC entry
  (LfGlobal / LfGroup / HfGlobal / PassGroup, or one coalesced section).
- **Stream id** — identifies a Modular sub-stream (global = 0, then
  VarDCT-DC, Modular-DC, AcMetadata, quant-table, ModularAC streams);
  feeds MA-tree property 1.
- **Pass** — one AC refinement layer ([§7](#7-progressive-decoding)).
- **LF / HF** — low frequency (DC image + AC metadata, 1/8 scale) vs high
  frequency (AC coefficients).
- **LLF** — a varblock's lowest N×M coefficients, recomputed from DC rather
  than coded.
- **XYB / opsin** — the perceptual color space of lossy JXL ([§6](#6-vardct-mode)).
- **CfL** — chroma-from-luma prediction; per-64×64-tile `ytox`/`ytob`.
- **EPF** — edge-preserving (restoration) filter; **Gaborish** — the fixed
  3×3 deblur.
- **MA tree** — meta-adaptive decision tree driving Modular prediction and
  contexts; **WP** — the self-correcting weighted predictor.
- **RCT / Squeeze** — Modular's reversible color transform / lifting wavelet.
- **Hybrid uint** — token + raw-bits integer coding ([§4](#4-entropy-coding)).
- **ANS final state** — `0x130000`; every entropy stream must return to it,
  giving a built-in checksum.
- **EC** — extra channel (alpha, depth, spot, …).
- **Reference slots** — the 4 frame stores used by blending, patches, and DC
  frames.
- **jbrd** — the JPEG-reconstruction box ([§10](#10-jpeg-bitstream-reconstruction-jbrd)).

## 12. Reading list

- **ISO/IEC 18181-1** (codestream) and **18181-2** (container) — the spec;
  the freely available final drafts are close to the published text.
  18181-3 defines conformance testing, 18181-4 the reference software.
- **libjxl v0.11.2 sources** — the ground truth this decoder is written
  against: <https://github.com/libjxl/libjxl/tree/v0.11.2/lib/jxl>. Start
  with `dec_frame.cc`, `frame_header.h`, `dec_ans.cc`,
  `modular/encoding/encoding.cc`, `dec_group.cc`, `dec_patch_dictionary.cc`.
- **libjxl docs** — format overview and notes:
  <https://github.com/libjxl/libjxl/tree/v0.11.2/doc> (`format_overview.md`).
- **This repo's `ARCHITECTURE.md`** — the decoder's structure, milestone
  history, validation discipline (oracle testing vs `djxl`, fuzzing), and
  performance notes.
- **JPEG XL white paper** (ICIP/SPIE papers by Alakuijala et al.) — design
  rationale for XYB, VarDCT, and Modular.
