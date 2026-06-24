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
├── ImageMetadata         bit depth, channels, color, animation…   [M2]
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
    ImageMetadata.swift basic info: BitDepth, channels, color      [M2]
    ColorEncoding.swift color space signaling / ICC                [M2]
  Entropy/
    PrefixCode.swift    canonical prefix (Huffman) codes           [M3]
    ANS.swift           rANS alias-method decoder                  [M3]
    EntropyDecoder.swift histograms, clustering, LZ77, hybrid uint [M3]
  Frame/
    FrameHeader.swift   frame type, passes, blending, TOC          [M4]
    Frame.swift         group/pass orchestration                   [M4]
  Modular/
    MATree.swift        meta-adaptive decision tree                [M5]
    Predictors.swift    self-correcting predictor + weighted       [M5]
    Transforms.swift    RCT, Palette, Squeeze                      [M5]
    ModularDecoder.swift channel decode driver                     [M5]
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
| M2 | Image metadata | full `jxl info` matching `jxlinfo` (depth, channels, color, animation) | next |
| M3 | Entropy coding | prefix + ANS + LZ77 + context modeling | |
| M4 | Frame layer | FrameHeader, TOC, group/pass model | |
| M5 | **Modular mode** | first real pixels: lossless `.jxl` → RGBA | |
| M6 | VarDCT mode | lossy photographic `.jxl` → pixels | |
| M7 | Restoration | Gaborish + EPF + upsampling | |
| M8 | Color pipeline | XYB→sRGB, ICC, alpha, 8/16-bit/float output | |
| M9 | Advanced | patches, splines, noise, animation, extra channels, JPEG recon | |
| M10 | macOS integration | `CGImage` bridge + Quick Look thumbnail/preview appex | |

Cross-cutting, ongoing: conformance corpus from the libjxl test suite, fuzzing,
and SIMD/performance once correctness is locked per stage.

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
        └── links JXLCore, declares public.jxl / org.jpeg.jxl in Info.plist
```

The decoder produces a `CGImage`; the thumbnail provider hands it to
`QLThumbnailReply(contextSize:…)` and the preview provider renders it. The
appex itself requires **full Xcode** to build and codesign — `Apps/` holds the
provider source and Info.plist so it is ready to drop into an Xcode project. The
core decoder stays a plain SwiftPM library so it builds and tests without Xcode.

## Toolchain note

The macOS 26/27 Command Line Tools ship a broken SwiftPM build service (dyld
cannot resolve its bundled frameworks), so `swift build`/`swift test` fail. We
build with `swiftc` directly via `Scripts/build.sh` and `Scripts/run-tests.sh`.
`Package.swift` is maintained so that once full Xcode is installed, standard
`swift build` / `swift test` work unchanged.
