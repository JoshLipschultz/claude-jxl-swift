# RD calibration study — is our cost model mispricing perceptual tools?

**Date:** 2026-08-02 · **Binary:** `.build/manual/jxl` as found (built 2026-07-30
23:04, i.e. after the E5k density work; **not** rebuilt for this study, so the
absolute numbers are pinned to that binary rather than to a commit)
**Harness:** `Scripts/rd-sweep.py` + `Scripts/rd-analyze.py` (both reuse the metric,
frontier and BD-rate machinery of `Scripts/cjxl_compare.py`)
**Raw data:** 3 285 measured operating points, cached at
`.build/rd-calibration-cache.json` (0 encode failures, 0 missing metrics)

## Why this study exists

`docs/lossy-vs-cjxl.md` measured us at roughly +27 % BD-rate behind `cjxl -e7` and
noted that our rate-distortion cost model is **squared error** while `cjxl`
optimises **butteraugli**. Gaborish was then measured losing to filters-off in all
17 raced cases and disabled by default, with the open question recorded in
`Sources/JXLCore/Encode/GaborishCompensation.swift`:

> THIS IS NOT "FILTERS DO NOT HELP IN JPEG XL". It is filters under OUR RD
> calibration … Recalibrating lambda under filters is the open question.

The structural worry was that a squared-error RD systematically *undervalues*
perceptual tools, so that implementing more of them (EPF, noise synthesis, more
transforms) would not pay until the cost model was fixed. This study tests that,
because it gates a lot of expensive downstream work.

## Headline — the worry is not confirmed, and the sign is backwards

1. **Gaborish is not mispriced in the hypothesised direction.** At matched size it
   *improves* squared error (median **−4.4 % BD-rate PSNR** at the shipped lambda)
   while *degrading* the perceptual metric (median **+6.7 % BD-rate SSIMULACRA2**).
   Our squared-error model **over**-values Gaborish relative to SSIMULACRA2, not
   under-values it. **No lambda in 0…1.0 makes Gaborish win on both metrics** on
   photographic, grayscale, noisy or text content.
2. **The shipped defaults are already at the optimum.** Over a 35-point
   (lambda × nzbits) grid, the best single global setting beats `0.10 / 2.4` by
   **≤0.6 %** BD-rate on either metric — noise, not a finding. Do not retune them.
3. **There IS a content-adaptive prize, and it is confined to smooth content.**
   On `photo_sky` + `grad_smooth`, `lambda 1.0` **with** Gaborish is
   **−14.3 % PSNR / −12.5 % SSIMULACRA2** against the shipped default — both
   metrics agreeing, which no other class shows. Against `cjxl -e7` that moves the
   smooth class from **+71.7 % / +58.1 %** to **+46.6 % / +41.1 %**.
4. **Two separate defects were found along the way** (§6): the frame race's own
   lambda is 20–100× above break-even, so it declines *any* candidate that buys
   quality with bytes; and `JXL_FILTERS=on` is **pixel-identical** to `gab` —
   our EPF signalling is inert, verified against `djxl`.

---

## 1. Method

### What was swept

| Axis | Values |
|---|---|
| `JXL_RD_LAMBDA` | 0, 0.02, 0.05, 0.10, 0.15, 0.20, 0.30, 0.35, 0.50, 0.75, 1.0 |
| `JXL_RD_NZBITS` | 1.2, 1.8, 2.4, 3.2, 4.5 |
| `JXL_FILTERS` | `off`, `gab`, `on` |
| quality | q30, q45, q60, q70, q80, q88, q95 |
| corpus | all 9 measurable entries of `.build/cjxl-corpus` |

50 encoder configurations × 9 images × 7 q = 3 150 points, plus `cjxl -e7` over 15
distances × 9 images = 135 points. Each point records file size, PSNR (float PFM,
`Scripts/psnr_any.py`) and SSIMULACRA2 against the original source, exactly as
`cjxl_compare.py` does. Butteraugli was not computed — it is a third opinion, and
where PSNR and SSIMULACRA2 disagree here they disagree by a lot, so a tiebreak was
not the limiting factor.

### What was pinned, and why

Every run of our encoder sets `JXL_LOSSLESS_RACE=0` and `JXL_FILTER_RACE=0`, so
the lossy path is measured in isolation and the filter setting is the one under
test rather than one a race chose.

**This does not change the baseline for 8 of 9 images.** Pinned `filters=off` is
**byte-identical** to the shipped default at q30/q70/q95 on `photo_rocks` — the
filter race is skipped entirely when the default is `off`, and the lossless race
never fires on photographic content. The single exception is `synth_text`, where
the shipped encoder ships a **4 042-byte lossless** stream from q70 up while the
pinned lossy path produces 41 544 / 68 121 bytes. **Every `synth_text` number in
this document therefore describes the lossy path in isolation and not what
ships.** It is kept because it is still a content class the RD model has to
handle, not because the numbers are shippable.

### BD-rate, and a windowed variant

BD-rate is computed by `cjxl_compare.bd_rate` — piecewise-linear in log2(size),
Pareto frontier only, no extrapolation. **Negative = better** (fewer bits for
equal quality) throughout this document.

Every number is reported in two forms:

* **full range** — the standard integral over the whole shared quality span.
* **window** — the same integral clipped to a *useful* quality range.

The window is necessary and it is not a thumb on the scale. Our q30 points land at
SSIMULACRA2 **−40 to −64** on real content: visibly destroyed, not merely soft. The
full-range integral gives that region the same weight per quality-unit as the
region anyone would actually ship, so a setting that is "least bad in the rubble"
scores as a win. `L1.0_N2.4_Foff` is the clean demonstration: **−0.5 %** on the
full-range median and **+15.3 %** on the windowed one. The two disagree by 16
points, and the window is the one that answers "what should we ship".

The window is anchored at **SSIMULACRA2 = 50 on the shipped-default curve**, and
that same file size is read back through the shipped PSNR curve to give each image
its own PSNR floor. A fixed PSNR threshold cannot be used: `synth_noise` tops out
at 24.8 dB while reaching SSIMULACRA2 90, so "PSNR ≥ 30" would delete the image
rather than window it. Resulting PSNR floors run 18.4 dB (`synth_noise`) to
37.3 dB (`photo_sky`). The window is computed **once from the reference config**,
so every compared configuration is judged over the same interval.

### Validity checks actually run

* 3 285/3 285 points produced both metrics; **zero** encode or decode failures.
* Pinned-vs-shipped byte-identity confirmed on `photo_rocks` (above).
* `JXL_FILTERS=on` vs `gab` checked through **both** decoders (§6.2).
* Worst-case BD-rate overlap audited: the narrowest windowed integral covers
  **0.34** of the reference quality span (`L1.0` on `synth_noise`), and the extreme
  lambdas generally sit at 0.5–0.6 because their q95 point falls short of the
  reference's. Configurations at lambda ≥ 0.5 are integrated over a genuinely
  narrower slice and their windowed numbers should be read as approximate.
* Quality numbers are deterministic and reproduce bit-exactly. **No timings are
  quoted anywhere in this document** — the machine was under contention from
  another lane for part of the run.

---

## 2. Question 1 — is Gaborish unprofitable, or mispriced?

Gaborish is measured against filters-off **at the same lambda**, so the comparison
isolates the filter rather than confounding it with an operating-point shift.

**Table 1 — `JXL_FILTERS=gab` vs `off` at matched size, windowed BD-rate, `PSNR / SSIMULACRA2`.**
Negative = Gaborish wins. Median within each class.

| lambda | photo | smooth | grayscale | noise | text | all (median) |
|---|--:|--:|--:|--:|--:|--:|
| 0 | −4.1 / **+6.8** | −2.4 / −0.3 | −7.3 / **+6.9** | −2.7 / **+17.2** | +22.0 / +19.4 | −2.7 / **+6.9** |
| 0.02 | −3.4 / +7.3 | −2.6 / −1.2 | −7.4 / +6.7 | −2.6 / +17.4 | +22.7 / +20.5 | −2.8 / +6.7 |
| 0.05 | −4.3 / +7.0 | −4.3 / −2.8 | −6.2 / +10.2 | −2.8 / +17.7 | +22.5 / +20.7 | −4.2 / +7.6 |
| **0.10 (shipped)** | −4.9 / +6.6 | −4.6 / −2.0 | −7.6 / +6.7 | −3.1 / +18.1 | +22.0 / +19.2 | **−4.4 / +6.7** |
| 0.20 | −4.8 / +6.3 | −4.6 / −1.6 | −6.4 / +15.9 | −3.1 / +13.7 | +20.3 / +18.1 | −4.3 / +6.9 |
| 0.35 | −4.7 / +5.8 | −6.3 / −2.6 | −8.5 / +6.1 | −4.2 / +12.7 | +21.1 / +17.9 | −5.1 / +6.0 |
| 0.50 | −5.0 / +5.4 | −7.1 / −3.3 | −8.5 / +7.2 | −4.2 / +15.4 | +17.5 / +17.7 | −5.4 / +6.0 |
| 0.75 | −4.8 / +6.3 | **−8.4 / −4.7** | −9.0 / +6.7 | −2.3 / +11.3 | +16.6 / +16.8 | −4.6 / +6.7 |
| 1.0 | −4.8 / +5.8 | −8.0 / −4.6 | **−9.2** / +6.2 | −2.0 / +10.2 | +16.4 / +15.4 | −4.7 / +6.2 |

### Reading

**The PSNR column is negative everywhere except text. The SSIMULACRA2 column is
positive everywhere except smooth.** That pattern is stable across all nine
lambdas, so it is a property of the tool and the metrics, not of the operating
point.

This is the **opposite** of the hypothesis. The suspicion was that a squared-error
RD would under-price a perceptual tool. In fact squared error *likes* Gaborish —
it buys 0.1–0.4 dB at matched size on photographs — and SSIMULACRA2 dislikes it,
by 5–8 % of bitrate. Concretely, `photo_rocks` at the shipped lambda:

| q | bytes (gab) | PSNR | dPSNR @matched size | S2 | dS2 @matched size |
|---|--:|--:|--:|--:|--:|
| 45 | 15 274 | 26.42 | **+0.37** | 8.2 | +1.0 |
| 60 | 36 114 | 30.49 | +0.30 | 58.5 | −0.6 |
| 70 | 61 995 | 33.10 | +0.28 | 76.7 | −0.6 |
| 80 | 99 839 | 35.26 | +0.07 | 86.9 | −0.2 |
| 88 | 139 681 | 37.15 | +0.14 | 91.2 | +0.0 |

A consistent small PSNR gain, and nothing perceptual to show for it. That is the
signature of a tool that is trading visible sharpness for MSE, which is exactly
what a decoder-side blur plus encoder-side inverse-blur will do when the inversion
is not free.

### Answer

**Gaborish is genuinely unprofitable on photographic, grayscale, noisy and text
content, at every lambda tested.** The one exception is real and is covered in §4:
on **smooth** content it wins on *both* metrics, and the margin grows with lambda
(−8.4 % / −4.7 % at lambda 0.75, and −14.3 % / −12.5 % when the lambda change is
counted too).

The claim in the source comment — that the "all 17 cases" result might be a
calibration artefact — is **half right**. The race's verdict *is* an artefact, but
of the frame race's lambda (§6.1), not of the coefficient RD's. Correcting that
artefact would make the encoder pick Gaborish, and picking Gaborish would make the
perceptual metric worse. The current default is right for the wrong reason.

---

## 3. Question 2 — is the default lambda optimal for the filters-off path?

**Table 2 — filters-off lambda sweep at nzbits 2.4, windowed BD-rate vs the
shipped default, `PSNR / SSIMULACRA2`.** Negative = better than shipped.

| lambda | photo | smooth | grayscale | noise | text | all (median) |
|---|--:|--:|--:|--:|--:|--:|
| 0 (RD off) | +5.0 / +3.8 | +7.4 / +8.0 | +5.3 / +8.9 | +12.9 / +6.5 | +1.2 / +2.2 | +5.3 / +4.1 |
| 0.02 | +4.5 / +2.2 | +5.2 / +5.5 | +4.2 / +7.6 | +12.8 / +6.3 | +1.0 / +1.4 | +4.7 / +3.2 |
| 0.05 | +2.1 / +1.0 | +3.1 / +3.6 | +1.3 / +2.1 | +6.1 / +3.2 | +0.3 / +0.4 | +2.8 / +1.7 |
| **0.10 (shipped)** | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | **0.0 / 0.0** |
| 0.20 | +0.1 / +0.3 | −4.3 / −4.4 | −0.1 / −7.0 | −1.9 / −0.6 | +1.1 / −0.6 | −0.6 / −0.6 |
| 0.35 | +4.3 / +3.5 | −6.2 / −7.3 | +4.8 / −2.1 | +3.5 / +0.6 | +2.8 / +1.0 | +3.0 / +1.0 |
| 0.50 | +8.9 / +6.6 | −6.8 / −8.4 | +9.0 / +1.2 | +9.7 / +4.3 | +6.8 / +1.8 | +7.1 / +4.3 |
| 0.75 | +14.2 / +10.3 | −6.3 / −7.9 | +13.6 / +4.7 | +19.3 / +8.6 | +10.1 / +4.0 | +12.9 / +4.7 |
| 1.0 | +16.7 / +11.9 | −6.8 / −8.4 | +15.3 / +5.5 | +24.1 / +10.3 | +11.9 / +6.3 | +15.3 / +6.3 |

RD quantisation itself is comfortably worth having — turning it off (lambda 0)
costs +5.3 % / +4.1 %. But the lambda **value** is at its optimum.

### The two knobs are very nearly one knob

Sorting the whole 35-point (lambda × nzbits) grid by the **product**
`lambda × nzbits` collapses it onto a single smooth unimodal curve. That is
predictable from the code — the drop-to-zero test is
`d(q0)² − d(0)² < lambda·(nzbits + log2|q0|)`, so `lambda·nzbits` sets the
dead-zone knee and `nzbits` only reweights the `log2|q|` term against it — and the
data confirms it:

| lambda·nzbits | (lambda, nzbits) | BD-rate PSNR | BD-rate S2 |
|---|---|--:|--:|
| 0.12 | (0.05, 2.4) / (0.10, 1.2) | +2.79 / +1.47 | +1.69 / +1.49 |
| **0.24 (shipped)** | (0.10, 2.4) / (0.20, 1.2) | 0.00 / −0.10 | 0.00 / +0.08 |
| 0.36 | (0.15, 2.4) / (0.20, 1.8) / (0.30, 1.2) | −0.81 / −0.95 / −1.28 | −0.38 / −0.23 / −0.41 |
| 0.48 | (0.20, 2.4) / (0.15, 3.2) | −0.57 / −0.44 | −0.62 / −0.54 |
| 0.72 | (0.30, 2.4) | +1.58 | +0.21 |
| 1.20 | (0.50, 2.4) | +7.06 | +4.33 |

The minimum sits at a product of **0.36–0.48** rather than the shipped 0.24, i.e.
1.5–2× the current dead zone. The best configurations found were
`lambda 0.20 / nzbits 1.8` (−0.95 % PSNR, −0.23 % S2) and `lambda 0.20 / nzbits
2.4` (−0.57 %, −0.62 %).

### Answer

**Yes, the defaults are effectively optimal — do not change them.** The entire
available gain from retuning `(lambda, nzbits)` globally is **≤0.6 %** BD-rate on
the metric that matters, against a 20–30 % deficit versus `cjxl`. That is inside
the noise of a 9-image corpus with 3 independent photographs. The earlier sweep
that chose 0.10 / 2.4 on different content still holds after three density changes,
which is a mildly reassuring result about the tuning's robustness.

---

## 4. Question 3 — does the optimum differ by content class?

**Table 3 — best configuration per class** (windowed, ranked by the *worse* of the
two metrics so a PSNR-only win cannot take the slot; searched over all 50
configurations).

| class | best config | BD-rate PSNR | BD-rate S2 |
|---|---|--:|--:|
| photo (4 images) | `lambda 0.15 / nz 1.8 / off` | −0.28 % | −0.24 % |
| **smooth (2 images)** | **`lambda 1.0 / nz 2.4 / gab`** | **−14.34 %** | **−12.48 %** |
| grayscale | `lambda 0.20 / nz 2.4 / off` | −0.09 % | **−7.03 %** |
| noise | `lambda 0.30 / nz 1.2 / off` | −3.18 % | −0.71 % |
| text (lossy path only) | `lambda 0.15 / nz 2.4 / off` | −0.20 % | −0.95 % |

**Photographs are already optimal.** Grayscale shows a 7 % perceptual gain from
`lambda 0.20`, but on one image only — treat it as a hint, not a result.

**Smooth content is the finding.** It wants a lambda **10× the shipped value**
*and* Gaborish, and both metrics agree, which is what separates this from the
PSNR-only mirages elsewhere in this study. At matched size, `grad_smooth`:

| q | bytes | PSNR | dPSNR | S2 | dS2 |
|---|--:|--:|--:|--:|--:|
| 45 | 3 801 | 30.28 | **+2.58** | 17.3 | **+17.2** |
| 60 | 6 490 | 37.15 | +2.45 | 62.8 | +14.9 |
| 70 | 9 060 | 41.03 | +2.14 | 77.1 | +6.2 |
| 80 | 14 174 | 44.50 | +0.94 | 85.3 | +1.3 |
| 95 | 25 231 | 49.46 | +0.72 | 91.6 | +0.3 |

and `photo_sky` at q45: 1 105 bytes, **+3.55 dB / +20.3 SSIMULACRA2** against the
shipped default at the same size.

### But the stronger axis is RATE, not content

Splitting the BD-rate into three quality bands (band edges anchored on the shipped
curve's SSIMULACRA2) shows where each lambda actually earns its keep. Median over
all nine images, `PSNR / SSIMULACRA2`:

| config | LOW (S2 < 50) | MID (S2 50–75) | HIGH (S2 > 75) |
|---|--:|--:|--:|
| lambda 0.05 | +3.3 / +2.9 | +2.7 / +1.9 | +2.3 / +1.4 |
| **lambda 0.20** | **−3.4 / −3.5** | **−1.0 / −1.2** | −0.2 / +0.5 |
| lambda 0.35 | −4.4 / −3.7 | +2.7 / +0.3 | +2.8 / +3.4 |
| lambda 0.50 | −2.7 / −2.3 | +6.4 / +4.0 | +7.4 / +6.8 |
| lambda 1.0 | **−10.4** / −0.5 | +13.7 / +5.1 | +15.4 / +12.9 |

Frontier ownership — which of the 50 configurations is highest-quality at each
file size — tells the same story without any integral in the way:

| where on the rate axis | winning lambda | margin over shipped |
|---|---|---|
| bottom 5 % | ≥ 0.35 on **7 of 9** images, on both metrics | +0.12…+3.43 dB · +1.85…+18.62 S2 |
| top 95 % | ≤ 0.35 on **9 of 9** images, on both metrics | +0.05…+0.95 dB · +0.01…+0.54 S2 |

(The dissenters at the bottom are `synth_text` on both metrics, plus `gray_city`
on PSNR and `synth_noise` on SSIMULACRA2 — and both of those pick 0.20–0.30, still
above the shipped 0.10.)
The winner shifts from a large lambda to a small one as rate rises, and the
*margin* collapses by an order of magnitude as it does — which is why the low-rate
end is where the whole effect lives.

This matters because `kRDLambda0` is *deliberately* rate-invariant — `lambda =
kRDLambda0 · mul²` exists precisely so the `mul²` cancels and one constant works at
every quality. **The data says that scale-invariance assumption is wrong**, and it
lines up with the known symptom in `docs/lossy-vs-cjxl.md` ("across *every* class
the gap is far larger at low rate … whatever rate allocation we do stops working
when bits get scarce").

**Be pessimistic about how much of this is real, though.** On PSNR the low-band
effect is large (−10.4 % at lambda 1.0); on SSIMULACRA2 it is **−0.5 %** and
inconsistent in sign across images. Most of the low-rate PSNR gain from a big
lambda is metric-specific and does not survive contact with a perceptual metric.
The exception is again smooth content, where the two metrics agree at every band.
So the honest statement is:

* **Rate-dependent lambda: supported by PSNR, not corroborated perceptually,
  except on smooth content.**
* **Content-dependent lambda: supported by both metrics, on smooth content only.**

### External check — does it move us against `cjxl -e7`?

Windowed BD-rate vs `cjxl -e7`, `PSNR / SSIMULACRA2`, median within class:

| config | photo | smooth | grayscale | noise |
|---|--:|--:|--:|--:|
| shipped (`0.10 / 2.4 / off`) | +22.5 / +17.7 | +71.7 / +58.1 | +29.4 / +28.7 | +3.5 / −17.5 |
| best global (`0.20 / 1.8 / off`) | +22.3 / +18.8 | +68.1 / +54.8 | +30.2 / +28.6 | +0.8 / −18.0 |
| `0.10 / 2.4 / gab` | **+16.0** / +24.0 | +59.7 / +52.1 | **+16.2** / +36.3 | +2.1 / −2.7 |
| `1.0 / 2.4 / gab` | +42.4 / +44.3 | **+46.6 / +41.1** | +39.7 / +47.5 | +19.4 / −0.1 |

A smooth-only rule would take that class from **+71.7 / +58.1** to
**+46.6 / +41.1** — roughly **25 points of PSNR BD-rate and 17 points of
SSIMULACRA2 BD-rate**, on the class `lossy-vs-cjxl.md` ranks as our worst genuine
coding deficit. Applied globally it would be a large regression, so it needs
either content classification or (better) a real per-block decision, which is a
design question this study does not answer.

The `0.10 / gab` row is also the cleanest single illustration of the whole study:
switching Gaborish on moves the photo class **6.5 points closer to `cjxl` on PSNR
and 6.3 points further away on SSIMULACRA2**.

---

## 5. What this means for the "should we build more perceptual tools" question

The study was commissioned to decide whether a squared-error RD is a blocker for
perceptual tooling. On the evidence:

**It is not the blocker, and the specific fear was backwards.** Where PSNR and
SSIMULACRA2 disagree in this data, PSNR is the *optimistic* one — it liked
Gaborish, it liked big low-rate lambdas, and SSIMULACRA2 declined both. A
squared-error cost model here is not systematically leaving perceptual wins on the
table; if anything it is at risk of banking perceptual *losses* that look like MSE
gains. So "fix the cost model first" is not justified as a gate on tool work by
anything measured here.

What the data *does* support, ranked:

1. **A smooth-content-aware operating point** (high lambda + Gaborish) is worth
   ~25 pp of BD-rate on our worst genuine class, agreed by both metrics.
2. **Fix the frame race's lambda** (§6.1) — it is currently 20–100× off and is
   silently overriding the coefficient RD's judgement on every axis it races.
3. **Make EPF actually do something** (§6.2) before drawing any conclusion about
   EPF at all.
4. **Do not retune `kRDLambda0` / `kRDNonzeroBits`.** ≤0.6 % is available.

---

## 6. Two defects found while measuring

### 6.1 The frame race's lambda is 20–100× above break-even

`rdScore` in `VarDCTEncoder.swift` scores frame candidates as
`SSE + kEncFrameRaceLambda · step² · bytes` with `kEncFrameRaceLambda = 6.0`.
Sweeping the (already-exposed) `JXL_FRAME_RACE_LAMBDA` shows where the filter axis
actually flips:

| image / q | pinned OFF | pinned GAB | flips to GAB at |
|---|--:|--:|---|
| `photo_rocks` q70 | 52 133 B | 61 995 B | between 0.12 and 0.06 |
| `photo_bridge` q88 | 137 770 B | 171 286 B | between 0.5 and 0.2 |
| `photo_sky` q70 | 4 502 B | 4 709 B | between 0.2 and 0.1 |

Break-even computed by hand from the measured SSE and byte deltas on
`photo_rocks` q70 lands at **λ ≈ 0.116**, matching the observed flip. The shipped
6.0 therefore does not "slide along the same rate/quality tradeoff the coefficient
RD uses", as its comment claims — it prices bytes so dearly that the smaller
candidate wins essentially always. That is why the filter race picked OFF in all
17 cases, and it is a *different* explanation from the one recorded in the source.

The same constant also decides the **DCT16 axis**, which this study did not
measure. If it is equally biased toward "smaller", the DCT16 decision may be
leaving quality on the table too. Worth checking; not checked here.

Note the irony before acting on this: a correctly-priced SSE race would start
choosing Gaborish, and §2 says that would make SSIMULACRA2 worse. Fixing the
lambda without fixing the metric would make the encoder measurably worse
perceptually.

### 6.2 `JXL_FILTERS=on` is inert — EPF does nothing

`JXL_FILTERS=on` (gaborish + `epf_iters = 2`) produced **bit-identical PSNR and
SSIMULACRA2 to `gab` on all 126 paired points** (two lambdas × 9 images × 7 q),
including file size, to every digit recorded.
The bitstreams differ (the loop-filter header differs) but the decoded pixels do
not — and this was confirmed with **`djxl`**, not just our own decoder:

```
djxl  gab  → 768x512 rmse=0.04058706 psnr=27.8322
djxl  on   → 768x512 rmse=0.04058706 psnr=27.8322
```

So the reference decoder agrees that our `epf_iters = 2` frames are unfiltered —
the EPF sigma our frames imply is below libjxl's activation threshold. **This
study therefore says nothing whatsoever about EPF's potential**, and neither does
the "filters lose in all 17 cases" result, which raced the same inert
configuration.

---

## 7. Where this study is weak

Stated plainly, because these bound the conclusions.

1. **Only 3 statistically independent photographs.** `photo_bridge`, `photo_rocks`
   and `photo_sky` are crops of the same source. Inherited from
   `docs/lossy-vs-cjxl.md` and not fixed here. Sub-2 % differences between
   configurations are not resolvable; that is exactly the size of the §3 result,
   which is why §3 concludes "leave it alone".
2. **The smooth class is 2 images and the grayscale, noise and text classes are
   1 image each.** The −14 % smooth result rests on `photo_sky` and `grad_smooth`
   agreeing; that is encouraging but it is n = 2, and both are unusually smooth.
   It should be re-tested on skies and defocused backgrounds inside ordinary
   photographs before anything is built on it.
3. **Two metrics, no human.** SSIMULACRA2 is treated as ground truth for
   "perceptual" throughout. Butteraugli was not run, and nobody looked at the
   images. The whole Gaborish conclusion is one metric's opinion, and it is the
   opinion of a metric from the same project as the encoder we are chasing.
4. **High-lambda configurations are integrated over a narrower quality slice**
   (as low as 0.34 of the reference span) because their q95 point falls short of
   the reference's. Their windowed numbers are approximate; the direction is
   reliable, the second digit is not.
5. **`synth_text` numbers describe a path that does not ship** (§1), and its
   BD-rate against `cjxl` (~+850 to +1 200 %) should not be quoted at all — the
   curves barely overlap.
6. **Per-frequency lambda was not tested.** It requires a code change and was out
   of scope. The isometry argument that justifies a single unweighted lambda is
   untouched by anything measured here; only its *rate*-invariance was challenged.
7. **The adaptive quant field (E5b) was not swept**, so lambda and the quant field
   were not jointly optimised. If they interact, the per-class optima above are
   conditional on the shipped field.
8. **No timings.** The machine was contended for part of the run.
9. **Alpha (`alpha_bridge.pam`) was excluded**, as in the parent benchmark — RGB
   metrics over transparent regions are meaningless.

---

## 8. Reproducing

```sh
# 1. sweep (writes a resumable JSON cache; ~3300 points)
python3 Scripts/rd-sweep.py --cache /tmp/rd.json --plan /tmp/plan.json --tmp /tmp/rdwork

# 2. analyse
python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode gab       # study 1
python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode nz        # study 2/3
python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode best      # per-image optima
echo "<configs>" | python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode band
echo "<configs>" | python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode owner
echo "<configs>" | python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode cjxl
python3 Scripts/rd-analyze.py --cache /tmp/rd.json --mode coverage  # audit
```

`--plan` is a JSON list of jobs, each
`{"name": "L0.10_N2.4_Foff", "env": {"JXL_RD_LAMBDA": "0.10", "JXL_RD_NZBITS":
"2.4", "JXL_FILTERS": "off"}, "images": [...], "qs": [...]}`; a job with
`"kind": "cjxl"` sweeps `cjxl` distances instead. Requires `cjxl`, `djxl`,
`ssimulacra2` and the corpus in `.build/cjxl-corpus`.

The cache backing every number in this document is preserved at
`.build/rd-calibration-cache.json`.
