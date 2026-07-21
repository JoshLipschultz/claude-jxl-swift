# JXL — a pure-Swift JPEG XL codec

A from-scratch implementation of a [JPEG XL](https://jpeg.org/jpegxl/)
(ISO/IEC 18181) decoder — and a growing lossless encoder — in Swift: a
dependency-free core library (`JXLCore`), a CoreGraphics bridge (`JXLKit`),
a command-line tool (`jxl`), a macOS viewer app, and a Quick Look extension.
libjxl is not linked — it serves only as the test oracle (`cjxl`/`djxl`
compare runs).

> **Status: feature-complete for real-world files.** Both coding modes decode
> end to end — **Modular** (lossless and lossy, byte-exact vs `djxl` including
> float32 bit patterns) and **VarDCT** (all transform sizes, Gaborish + EPF,
> chroma-from-luma, adaptive quantization) — plus animation with frame
> blending, progressive (multi-pass AC and LF frames), patches, splines, noise
> synthesis, delta palette, squeeze, extra channels at any depth/upsampling,
> JPEG bitstream reconstruction (byte-exact), and a color pipeline covering
> 8/16-bit/float output, PQ/HLG HDR, custom opsin matrices, and CMS output to
> embedded matrix+TRC ICC profiles. On the libjxl conformance corpus, every
> testcase whose pixels we decode meets its official error tolerance, and float
> output matches libjxl's own fast-math transfer functions to >120 dB PSNR.
> See [ARCHITECTURE.md](ARCHITECTURE.md) for the design and
> [docs/jxl-primer.md](docs/jxl-primer.md) for a format primer.

On the official conformance corpus: **25 of 26 testcases** meet their official
tolerances (6 bit-exact); the one exception embeds a third-party CMS
approximation in the reference itself — see
[docs/conformance-report.md](docs/conformance-report.md). Every JPEG XL
codestream feature the corpus exercises now decodes, including nested DC
frames (`progressive_dc=2`) and custom parametric dequantization matrices.

## Command-line tool

```
$ jxl info image.jxl                    # dimensions + metadata + color encoding
640 x 480  8-bit RGB  (bare codestream)
color: RGB white_point=1 primaries=1 tf=13 intent=1

$ jxl boxes image.jxl                   # ISOBMFF container box listing
$ jxl frames anim.jxl out               # decode animation frames -> out_<i>.ppm
$ jxl decode image.jxl out.ppm          # decode to PGM/PPM (or .pam with alpha)
$ jxl decode image.jxl out.ppm 16       # ... at 16-bit, or `float` -> PFM
$ jxl decode image.jxl out.ppm dither   # blue-noise dither 8-bit output
                                        #   (`nospot` = don't render spot colors)
$ jxl tojpeg recon.jxl out.jpg          # byte-exact JPEG reconstruction
$ jxl icc image.jxl out.icc             # extract the embedded ICC profile
$ jxl bench image.jxl                   # decode benchmark
```

(plus `vardct*` debug subcommands that dump intermediate VarDCT state.)

## Library

```swift
import JXLCore

let info  = try JXL.readInfo(contentsOf: url)       // metadata only, no pixel work
let image = try JXL.decodeImage(contentsOf: url)    // pixel planes (uint8/uint16/float32)
let anim  = try JXL.decodeFrames(contentsOf: url)   // composited animation frames + durations
let jpeg  = try JXL.reconstructJPEG(contentsOf: url) // byte-exact JPEG, when jbrd is present
let icc   = try JXL.readICCProfile(contentsOf: url)
```

`JXLKit` wraps the same decode paths in `CGImage` construction — 8- and
16-bit-per-channel images tagged with the matching color space (Display P3,
BT.2020, PQ/HLG for HDR, or the embedded ICC profile), with EXIF orientation
baked in.

## Apps

- `Apps/JXLViewer` — a macOS viewer (window/zoom/inspector, animation
  playback honoring per-frame durations, HDR display via EDR).
  Build with `sh Scripts/build-viewer.sh`.
- `Apps/JXLQuickLook` — Quick Look thumbnail extension
  (generate the Xcode project from `project.yml` with xcodegen).

## Building & testing

Standard SwiftPM (requires full Xcode; on macOS 26/27 the bare Command Line
Tools ship a broken SwiftPM build service):

```
swift build -c release
swift test
```

The `swiftc`-direct scripts remain the fast day-to-day loop:

```
sh Scripts/build.sh        # builds .build/manual/jxl
sh Scripts/run-tests.sh    # compiles + runs the standalone suite (~18,000 tests)
sh Scripts/fuzz.sh [n]     # mutation-fuzzes the decoder over the fixtures
sh Scripts/gen-bench.sh    # regenerates the 6-megapixel benchmark images
```

Both test paths cover the same ground; `Tests/Standalone/TestRunner.swift` is
the dependency-free runner, and `Tests/JXLCoreTests/*` is the XCTest mirror.

## Testing methodology

Every feature is validated against libjxl (`cjxl`/`djxl` v0.12.x) as an
oracle: lossless decodes must be **byte-exact** (including float32 bit
patterns), lossy decodes must meet PSNR thresholds against `djxl`'s output,
and JPEG reconstruction must be byte-exact. Small generated fixtures
(`Tests/JXLCoreTests/Fixtures/*.jxl`, with expected rasters committed
alongside) keep the suite self-contained — no oracle binaries are needed to
run the tests. Bitstream-touching changes additionally get a mutation-fuzz
round and a decode-benchmark regression check (~43 ms lossy / ~115 ms
lossless per 6-megapixel image on Apple Silicon, single image,
`DispatchQueue.concurrentPerform` across groups).

## Repository layout

- `Sources/JXLCore` — the decoder library (see [ARCHITECTURE.md](ARCHITECTURE.md))
- `Sources/JXLKit` — CGImage/color-space bridge for Apple platforms
- `Sources/jxl` — the `jxl` command-line tool
- `Apps/` — viewer app + Quick Look extension
- `Scripts/` — build/test/fuzz/bench scripts
- `Tests/` — XCTest suite + standalone runner + fixtures
- `docs/` — [JPEG XL primer](docs/jxl-primer.md), [conformance report](docs/conformance-report.md)

## License & provenance

Licensed under the [BSD 3-Clause License](LICENSE).

Implemented primarily from the ISO/IEC 18181 specification, with libjxl as the
test oracle. Portions of the decoder — notably splines, noise synthesis, frame
blending, the fast transfer-function evaluators, and other bit-exactness-critical
paths — are derived from [libjxl](https://github.com/libjxl/libjxl), used under
its BSD 3-Clause license (Copyright (c) the JPEG XL Project Authors).
