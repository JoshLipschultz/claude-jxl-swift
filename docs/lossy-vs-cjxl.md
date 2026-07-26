# Our lossy encoder vs `cjxl` — first external measurement

**Date:** 2026-07-25 · **Oracle:** libjxl 0.12.0 (`cjxl`/`djxl`, Homebrew, NEON)
**Harness:** `Scripts/cjxl-compare.sh` → `.build/cjxl-compare/report.txt`, `results.json`

Every previous lossy milestone in this repo was measured against *its own previous
commit* — that is what `Scripts/rd-curve.sh` does. Nothing had ever compared the
encoder to the reference implementation, so "are we 1 dB or 6 dB behind" was
genuinely unknown. This is that measurement.

## Headline

On ordinary photographic content we are **roughly 1 dB behind at useful quality
levels, and need about 25–35 % more bytes for the same PSNR**. That is a
respectable place to be for a from-scratch encoder, and much closer than a
worst-case guess would have suggested.

But the aggregate hides two content classes where we do not merely lose, we
collapse:

| Content | BD-rate vs `cjxl -e7` | Worst equal-size gap |
|---|--:|--|
| Photographic (4 images) | **+34 %** (median) | −2.6 dB |
| Grayscale photo | +35 % | −2.3 dB |
| Noise-heavy (synthetic) | **+0.1 %** (parity) | — |
| Smooth gradient | **+108 %** | −20.0 dB @ low rate |
| Smooth photo (sky) | **+179 %** | −26.5 dB @ low rate |
| Text / screen content | **+874 %** | ~10× the bytes |
| RGBA (alpha) | *not measured* (see §5) | — |

BD-rate is the Bjøntegaard average bitrate difference over the quality range the
two curves share; **positive means we need that many percent more bits for equal
quality.** Median over all 9 measurable images is **+35.4 %** (PSNR) and
**+35.5 %** (SSIMULACRA2). The *mean* is +150 %, but that number is meaningless —
it is dominated by the two pathological classes. Use the median plus the
per-class table, never the mean.

**Speed:** we are **~1.8–2.0× slower than `cjxl -e7`** (three full runs gave
median 1.76×, 1.84×, 2.06×) and **~5.2× slower than `cjxl -e3`**. Process
startup is 3 ms for us and 7 ms for cjxl, so this is real encoder time, not
launch overhead. We are beaten on compression by `cjxl -e3` (median +38.6 %
BD-rate) while taking five times as long as it does — there is currently no
operating point at which we win on the speed/quality trade.

---

## Method

### What is compared

For each source image, our encoder is swept over `q30…q95` (10 points) and
`cjxl` over `--distance 0.3…20` (15 points), at efforts 7 (its default) and 3.
Each point records file size, encode wall time (best of 3 runs), and three
quality metrics computed **against the original source**.

### Metrics, and why three of them

| Metric | Tool | Why |
|---|---|---|
| PSNR | `Scripts/psnr_any.py` (ours) | Squared error. Fully under our control and auditable. |
| SSIMULACRA2 | `ssimulacra2` (libjxl) | Perceptual, 0–100. |
| Butteraugli | `butteraugli_main` (libjxl) | Perceptual distance, lower better. Recorded per point. |

**PSNR alone flatters us and must not be quoted on its own.** `cjxl --distance`
targets *butteraugli*, not squared error: libjxl deliberately spends bits where
they help perceived quality and accepts a worse MSE for it. Judging it by PSNR
therefore scores it on a metric it is not playing. This is the single most
important bias in the whole exercise, and it points in *our* favour.

The reassuring result is that it does not change the conclusion: BD-rate on
SSIMULACRA2 (+35.5 % median) lands essentially on top of BD-rate on PSNR
(+35.4 % median). Where the two disagree it is worth reading the per-image
numbers — e.g. `photo_ocean` is +55.9 % on PSNR but +27.7 % on SSIMULACRA2, so
part of that particular loss is metric artefact rather than real.

### The 8-bit dither trap

`djxl` 0.12 applies blue-noise dithering to 8-bit output **by default** and our
decoder does not. Comparing 8-bit decodes therefore floors agreement near 54 dB
with dither noise rather than coding error, which looks exactly like a codec
bug. **Every decode in this harness is float PFM**, which has no dither.

PFM endianness differs between the two (ours writes little-endian, `scale=-1.0`;
djxl writes big-endian, `scale=1.0`) and PFM scanlines are bottom-up.
`psnr_any.py` honours the header's scale sign and flips rows on load, i.e. it
compares **values, never bytes**.

### Calibration (run automatically on every invocation)

`cjxl-compare.sh` refuses to proceed unless a **lossless round-trip through both
codecs** returns to the source. Both give **148.99 dB** (RMSE 4e-8) — that is
pure float32 rounding and is the noise floor of the entire measurement, ~100 dB
below anything reported here. This one check simultaneously validates
endianness, scanline order, colour-space handling and channel mapping; if any
were wrong the number would be ~9 dB, not ~149 dB (a deliberately flipped image
scores 8.7 dB).

### Which decoder decodes what — and a cross-check

Each codec is decoded by its own decoder (`jxl decode … float` / `djxl`), so
what is measured is each codec **as shipped**.

Using our own decoder on our own files could in principle flatter us, if encoder
and decoder shared a compensating misunderstanding. They do not. Decoding *our*
bitstreams with `djxl` instead gives:

| Image | q | our decoder | djxl |
|---|---|--:|--:|
| photo_rocks | 50 / 75 / 90 | 27.0623 / 33.1672 / 36.3811 | 27.0623 / 33.1672 / 36.3811 |
| photo_sky | 50 / 75 / 90 | 34.4037 / 46.9933 / 50.6255 | 34.4037 / 46.9933 / 50.6255 |
| synth_text | 50 / 75 / 90 | 24.6450 / 36.5030 / 44.7254 | 24.6450 / 36.5029 / 44.7254 |
| gray_city | 50 / 75 / 90 | 32.1347 / 39.0232 / 45.2009 | 32.1347 / 39.0231 / 45.2009 |

Agreement to four decimal places. The results are decoder-independent, and our
lossy bitstreams are conformant enough for the reference decoder to reproduce
them exactly.

### Interpolation, and refusing to extrapolate

Both framings interpolate the *other* codec's curve piecewise-linearly in
**log2(size)** rather than linearly in size, because quality is close to linear
in log(rate) over a 20× rate range. (`rd-curve.sh` interpolates linearly in
size; that is fine for two nearby curves from the same encoder, biased across
this range.)

Two hardening changes over `rd-curve.sh`, both of which make the numbers *less*
favourable to us:

1. **No extrapolation.** `rd-curve.sh` clamps an out-of-range query to the
   endpoint. This harness returns `--` instead. Several low-rate cells in the
   report are `--` precisely because our quality falls below anything cjxl
   produces — clamping would have quietly invented a flattering number there.
2. **Pareto frontier.** Neither sweep is monotonic in practice. On text content
   **11 of 15** cjxl points are dominated (beaten on size *and* PSNR) by another
   cjxl point, because cjxl switches to modular/palette mode and `--distance`
   stops meaning much; on smooth content its `-d 10` point is both smaller and
   better than its `-d 8` point. Interpolating through such a curve as if it
   were a function of size is nonsense, so only the non-dominated frontier is
   used. This is the charitable reading for the codec being interpolated — and
   applying it made our text and smooth results *worse* (+448 % → +874 %,
   +175 % → +179 %), which is the honest direction.

Dominated points are marked `x` in the per-image tables in `report.txt`.

---

## Corpus

Built by `Scripts/gen-corpus.py` into `.build/cjxl-corpus/` (not committed).
Photographic sources are **macOS system assets**, so the corpus reproduces
bit-exactly on any Mac with no download.

| Entry | Class | Provenance |
|---|---|---|
| `photo_bridge.ppm` 1024×540 | photo (mixed) | `DefaultDesktop.heic` 4096×2160, full frame → Lanczos 1024×540 |
| `photo_rocks.ppm` 768×512 | photo (high detail) | same, native crop 1536×1024 @ (2380,1130) → 768×512 |
| `photo_sky.ppm` 768×512 | photo (smooth) | same, native crop 1536×1024 @ (300,60) → 768×512 |
| `photo_city.ppm` 960×540 | photo (high detail) | `category-preview-5EF41171….jpg` 1920×1080 Manhattan aerial → 960×540 |
| `photo_ocean.ppm` 960×540 | photo (dark/grain) | `category-preview-8BE8B524….jpg` 1920×1080 underwater → 960×540 |
| `gray_city.pgm` 960×540 | grayscale | luma of the Manhattan aerial |
| `grad_smooth.ppm` 768×768 | smooth gradient | `Sonoma.heic` 6016×6016 crop → 768×768 |
| `synth_text.ppm` 768×512 | text/synthetic | generated: embedded 8×8 bitmap font + UI chrome |
| `synth_noise.ppm` 768×512 | noise-heavy | generated: ±64 uniform noise on a low-frequency base |
| `alpha_bridge.pam` 1024×540 | alpha | `photo_bridge` + synthetic alpha (radial + ramp) |

**Artefact hygiene.** Every photographic source is itself already lossily coded
(HEVC or JPEG). Handing a native-resolution crop of such a source to a DCT codec
is a biased test, because the source's own transform artefacts are cheap for a
DCT codec to reproduce. So every photographic entry is cropped at **2× the
target size and Lanczos-downscaled 2×**, pushing the source's coding artefacts
below the new Nyquist limit while preserving real sensor detail statistics.

### The repo's own fixtures are *not* photographs

The task brief for this work stated that many `Tests/JXLCoreTests/Fixtures/*.jxl`
are real photos and that `384x256_prog.jxl` in particular is photographic.
**That is incorrect**, and it matters enough to record. Decoding them:

* `384x256_prog.jxl` — smooth diagonal colour gradient plus uniform noise.
* `640x480_lossless.jxl`, `513x257_lossless.jxl` — periodic high-frequency
  checkerboards (which is why they are ~0.6× of raw even losslessly coded).
* `100x100_lossless.jxl`, `384x256_pdcac.jxl`, `256x256_dct64_lossy.jxl` —
  gradients and tiled patterns.
* `256x192_epf2.jxl`, `256x192_squeeze.jxl` — tiled synthetic noise blocks.

There is no photographic content in the fixture set at all. Combined with
`Scripts/gen-bench.sh` (a `sin()`-plus-noise field), **every lossy tuning
decision in this repo's history was validated exclusively on synthetic
content.** Given that the smooth-gradient and text classes are exactly where
this benchmark finds catastrophic behaviour, that is a plausible root cause and
not a coincidence.

---

## Results

Full tables in `.build/cjxl-compare/report.txt`. `dPSNR`/`dS2` are ours minus
cjxl **at our file size** (negative = worse). `size@eqQ` is our bytes ÷ cjxl
bytes **at equal PSNR** (>1 = we are bigger).

| image | class | BD-rate PSNR | BD-rate S2 | dPSNR @low | @mid | @high | dS2 @mid | size@eqQ | enc vs cjxl |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| photo_bridge | photo (mixed) | +31.4 % | +35.5 % | −2.21 | −1.00 | −0.63 | −1.5 | 1.24× | 1.72× |
| photo_city | photo (detail) | +31.8 % | +31.1 % | −4.29 | −1.19 | −0.82 | −1.5 | 1.25× | 2.16× |
| photo_rocks | photo (detail) | +35.4 % | +33.6 % | −4.50 | −1.04 | −0.75 | −2.0 | 1.25× | 2.06× |
| photo_ocean | photo (dark/grain) | +55.9 % | +27.7 % | −3.91 | −2.61 | −2.04 | −5.2 | 1.57× | 2.16× |
| gray_city | grayscale | +35.4 % | +37.4 % | −2.32 | −2.30 | −1.14 | −4.2 | 1.37× | 2.08× |
| synth_noise | noise-heavy | +0.1 % | −3.3 % | +0.01 | −0.22 | −1.73 | **+8.4** | 1.03× | 2.87× |
| grad_smooth | smooth gradient | +108.0 % | +111.7 % | **−19.95** | −5.78 | −1.91 | −6.0 | 2.02× | 1.96× |
| photo_sky | photo (smooth) | +179.2 % | +180.4 % | **−26.48** | −4.37 | −1.43 | −6.6 | 2.42× | 1.37× |
| synth_text | text/synthetic | +873.9 % | +871.9 % | — | — | — | — | ~10× | 1.53× |
| alpha_bridge | alpha | **unsupported** | | | | | | | |

Aggregates over the 9 measurable images: BD-rate PSNR median **+35.4 %**,
SSIMULACRA2 median **+35.5 %**; equal-size dPSNR median **−4.1 dB** at low rate,
**−1.7 dB** at mid, **−1.3 dB** at high; equal-PSNR size median **1.31×**.

### 1. Photographs — about 1 dB, and it narrows as quality rises

`photo_rocks` (dense rock/pebble texture), ours vs `cjxl -e7` at our size:

| q | bytes | bpp | PSNR | S2 | dPSNR | dS2 | size@eqPSNR |
|---|--:|--:|--:|--:|--:|--:|--:|
| q30 | 9 374 | 0.19 | 21.69 | −41.6 | −4.50 | −36.7 | — |
| q50 | 21 543 | 0.44 | 27.06 | 23.3 | −2.38 | −25.5 | 1.66× |
| q70 | 54 820 | 1.12 | 32.16 | 75.0 | −1.02 | −2.9 | 1.26× |
| q85 | 104 883 | 2.13 | 35.28 | 87.5 | −0.92 | −1.2 | 1.22× |
| q95 | 155 347 | 3.16 | 37.53 | 92.1 | −0.75 | −0.5 | 1.15× |

The shape is consistent across all four ordinary photos: **the gap closes as
bitrate rises.** At q85–q95 we are within 1 dB and within 2 SSIMULACRA2 points —
genuinely close. At q50 and below we are 2.4–4.5 dB behind and, more tellingly,
25–37 SSIMULACRA2 points behind. Our low-rate behaviour is far worse than the
PSNR gap alone suggests.

`photo_ocean` is the weakest ordinary photo (+55.9 %, −2.6 dB at mid, flat
across the whole range). It is dark, low-contrast and carries real sensor grain.
Its SSIMULACRA2 BD-rate is only +27.7 %, so roughly half of that PSNR gap is
libjxl spending bits differently rather than us being worse.

### 2. Smooth content — the largest *fixable* gap

This is where we fall off a cliff. `grad_smooth`:

| q | bytes | PSNR | dPSNR | dS2 | size@eqPSNR |
|---|--:|--:|--:|--:|--:|
| q30 | 6 191 | 21.03 | **−19.95** | −125.8 | — |
| q50 | 10 083 | 33.28 | −11.56 | −43.0 | — |
| q70 | 16 538 | 42.24 | −6.67 | −9.1 | 2.09× |
| q95 | 35 510 | 50.51 | −1.91 | −0.6 | 1.69× |

and `photo_sky` is worse still: at 3 829 bytes we produce **21.13 dB**
(SSIMULACRA2 −40.0), while cjxl at a *smaller* 3 587 bytes produces **46.93 dB**
(SSIMULACRA2 83.5). A 26 dB gap on the easiest possible content.

Three things are going wrong, and they compound:

* **We cannot get small.** Sweeping `photo_sky` all the way down to q1 bottoms
  out at **3 065 bytes (0.062 bpp)** — q1 through q30 only span 3 065 → 3 829
  bytes. cjxl reaches **1 244 bytes (0.025 bpp)** at `-d 25` while still holding
  42.4 dB. Our floor is ~2.5× cjxl's, so some per-image or per-group cost is not
  shrinking with quality.
* **We degrade catastrophically rather than gracefully.** At its floor cjxl
  holds 42.4 dB / SSIMULACRA2 68.8; at ours we produce **17.0 dB /
  SSIMULACRA2 −37.5**. Negative SSIMULACRA2 means visibly destroyed, not merely
  soft.
* **Quality is not monotonic in q on the smoothest content.** On `photo_sky`,
  PSNR wanders as q rises: q1 17.01, q5 15.44, q10 17.63, q15 19.56, q20 17.72,
  q25 17.94, q30 21.13 dB. Below ~q30 the quality knob does not order the
  outputs. This is **specific to the smoothest entry** — `photo_rocks`,
  `photo_city` and `grad_smooth` are all cleanly monotonic from q1 up — so it
  looks like a distinct defect in how near-flat regions are handled at coarse
  quantisation, not a general rate-control problem.

Smooth regions are where DC precision, adaptive quantisation and the smoothing
tools (Gaborish/EPF) matter most, and it is precisely the content the historical
synthetic benchmarks under-weighted.

### 3. Text / screen content — a mode-selection gap, not a tuning gap

`cjxl` reaches **63.90 dB in 6 824 bytes** on `synth_text`. Our best point is
**47.76 dB in 69 224 bytes** — about **10× the size and 16 dB worse**. cjxl is
not out-tuning us here; it detects palettisable synthetic content and leaves
VarDCT entirely for modular/palette mode. Our lossy path is VarDCT-only.

The decisive evidence that this is mode selection and not encoder quality is
that **our own lossless encoder already wins this content by a mile:**

| `synth_text.ppm` | bytes | quality |
|---|--:|---|
| ours, `q95` (lossy VarDCT) | 69 224 | 47.76 dB |
| **ours, `e2` (lossless modular)** | **4 042** | **mathematically lossless** |
| cjxl, `-d 0` (lossless) | 1 925 | mathematically lossless |

Our lossy mode is **17× larger than our own lossless mode** on this image while
also being worse. Any content classifier that routed such images to the existing
modular path — even a crude one — would convert the worst result in this
benchmark into a win, using code that already exists and is already tested.

For context, our lossless path is competitive on photographs
(`photo_rocks` 450 719 B vs cjxl 443 204 B, +1.7 %; `photo_sky` 91 273 B vs
92 850 B, i.e. we are *smaller*). The lossless work has landed; the lossy path
is what is behind.

### 4. Noise — parity, but do not celebrate it

`synth_noise` is our only non-loss (+0.1 % PSNR, −3.3 % SSIMULACRA2, and we are
up to **+8.4 SSIMULACRA2 points ahead** at equal size around q80–q85).

Discount this heavily. The entry is ±64 uniform noise, far harsher than real
sensor noise, and at 0.1–9.5 bpp both codecs are essentially storing
incompressible data where neither has much room to be clever. The realistic
noise test is `photo_ocean` (real grain) — and there we lose by 55.9 %. The
honest reading is "we are not *worse* on pathological noise", not "we are good
at noise".

### 5. Alpha — implemented after this run; still unmeasured

**Superseded while this benchmark was running.** At the time of the sweep,
`jxl encode … q<N>` on a PAM P7 input failed outright with
`lossy encode does not support extra channels yet`, and the harness still
reports the entry as UNSUPPORTED. Encoder milestone **E5g** (commit `a846711`)
implemented it: extra channels are modular-coded inside the VarDCT frame, so
alpha round-trips BYTE-EXACTLY while colour is lossy.

So the capability gap is closed, but the **quality gap here is still
unmeasured** — no number in this document covers alpha. Re-running the harness
against an alpha-aware metric (below) is outstanding work.

**A trap for whoever implements this:** RGB PSNR over an image with transparent
regions is meaningless. Where alpha = 0, cjxl treats colour as don't-care and
quantises it away — measured directly, decoded RGB in those regions is flat fill
against a source that had real colour there, scoring **10.6 dB** overall for an
otherwise fine encode. Alpha-aware comparison must score only where alpha > 0,
or score alpha-weighted. The harness still reports this entry as UNSUPPORTED
and computes nothing; now that E5g has landed, teaching it an alpha-aware metric
is the blocking step for measuring this class at all.

---

## Where the methodology is weak

Stated plainly, because these bound how far the numbers can be pushed.

1. **Only three distinct photographs.** `photo_bridge`, `photo_rocks` and
   `photo_sky` are three crops of *the same* Golden Gate photograph and are not
   statistically independent. Real independence is: bridge, Manhattan aerial,
   underwater — **n = 3**. The ±5 % differences between individual photo entries
   are not resolvable; the "photographs cost ~30–35 % more bits" conclusion is
   solid, "photo_city is better than photo_rocks" is not.
2. **All sources are macOS system assets** and were already lossily coded before
   we saw them. The 2× downscale mitigates but does not eliminate this. A proper
   run against camera raw or a standard set (Kodak, CLIC) would be stronger; no
   such set is present on this machine and fetching one was out of scope.
3. **No true low-bitrate floor for our encoder.** Our sweep stops at q30 because
   below that we fall outside cjxl's measured range entirely. The `--` cells are
   honest, but they mean *the low-rate gap is a lower bound* — we know we are at
   least 4.5 dB behind at q30 on photos, not that 4.5 dB is the worst of it.
4. **BD-rate on `synth_text` (+874 %) should not be quoted to three digits.**
   The curves barely overlap (41.8–47.8 dB) and cjxl's is mode-switching and
   heavily non-monotonic there. The robust statement is the direct one: ~10× the
   bytes at equal quality, and 16 dB short of cjxl's best point at any size.
5. **PSNR structurally favours us** (cjxl targets butteraugli). SSIMULACRA2
   agreeing so closely is reassuring, but both are still objective metrics; no
   human looked at these images side by side.
6. **Timing is single-machine, wall-clock, both codecs multi-threaded on the
   same box.** Best-of-3 with 3–7 ms startup on 36–140 ms encodes. Quality
   numbers are bit-exactly reproducible across runs; **timings are not**. The
   same image moved between 1.48× and 2.16× across three runs, so per-image
   ratios are noise at the ±30 % level and must not be compared to each other.
   Only the aggregate (~1.8–2.0× vs `-e7`, ~5.2× vs `-e3`), which was stable
   across all three runs, should be quoted.
7. **`cjxl -e7` is its default, not its best.** `-e 8/9/10` would widen the gap.
   Conversely we lose to `-e 3` while being 5.2× slower than it, so this choice
   does not flatter cjxl.
8. **Alpha and animation are unmeasured** for our lossy path — the first because
   it is unimplemented, the second not attempted at all.

---

## Ranked conclusions

1. **Text/screen content (+874 %, ~10× size) — worst, and cheapest to fix.**
   Not an encoder-quality problem: our *own* lossless modular path already
   produces 4 042 bytes where our lossy path produces 69 224. Needs content
   classification and a route to modular, not new coding tools.
2. **Smooth content (+108 % / +179 %, up to −26 dB) — worst genuine coding
   deficit.** Affects real photographs (skies, walls, bokeh, defocused
   backgrounds), not just synthetic gradients. Three distinct sub-problems: a
   size floor ~2.5× cjxl's, catastrophic rather than graceful degradation below
   ~q60, and non-monotonic quality-vs-q below q30 on the smoothest content —
   that last one smells like an outright bug and is the cheapest thing here to
   go look at first.
3. **Low bitrate generally.** Across *every* class the gap is far larger at low
   rate (median −4.1 dB, and 25–37 SSIMULACRA2 points on photos at q50) than at
   high rate (−1.3 dB). Whatever rate allocation we do stops working when bits
   get scarce.
4. **Photographs at mid/high rate (+31–36 %, ~1 dB) — the healthy result.**
   Real, consistent, and the least urgent thing to work on.
5. **Dark/grainy photographs (+55.9 %)** are meaningfully worse than other
   photos, though roughly half of that is metric artefact (SSIMULACRA2 says
   +27.7 %).
6. **Alpha is unimplemented** in the lossy path — a correctness/capability gap
   that no amount of tuning addresses.
7. **Speed: ~2× slower than `cjxl -e7`, ~5.2× slower than `-e3`.** We currently
   lose to `-e3` on compression *and* on time, so there is no operating point
   where we are the better choice today.

## Reproducing

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer sh Scripts/build.sh
sh Scripts/cjxl-compare.sh              # full sweep, ~6 min, builds corpus on first run
sh Scripts/cjxl-compare.sh --quick      # coarse sweep
sh Scripts/cjxl-compare.sh /path/to/my/images
```

Requires `cjxl`, `djxl`, `ssimulacra2`, `butteraugli_main` (all from libjxl) and
ImageMagick `magick` for corpus generation. Without the perceptual tools the
harness still runs but prints a warning that PSNR-only conclusions are an upper
bound on our standing. Outputs land in `.build/cjxl-compare/`.
