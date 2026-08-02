#!/bin/sh
# Sweep kEncFrameRaceLambda and report BD-rate per value.
#
# WHY: the RD calibration study (docs/rd-calibration.md) found the frame-level
# race prices bytes far too dearly — hand-computed break-even ~0.116 against the
# shipped 6.0. That constant decides the large-transform-vs-DCT8 axis, so it
# gates how often DCT16/DCT32 are used at all.
#
# WHY NOT POINT SAMPLES: spot checks showed the decision changing on some images
# and not others, and trading MORE bytes for MORE quality — good on photos
# (photo_city q50 +0.62 dB for +1.3% bytes), bad on noise (synth_noise q70
# +0.19 dB for +5.6%). Whether that nets out can only be answered by integrating
# over the rate range, which is what BD-rate does and a point sample cannot.
#
# WHAT TO WATCH FOR: E5f introduced this race specifically to stop DCT16 being
# chosen too aggressively on noise-dominated content. Lowering lambda risks
# reintroducing exactly that regression, so synth_noise is the canary — check it
# individually, not just the aggregate.
#
# JUDGE ON SSIMULACRA2. cjxl targets butteraugli, and the calibration study
# showed PSNR and S2 can disagree in SIGN about a tool (Gaborish improves PSNR
# while degrading S2). PSNR alone would mislead here.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/.build/frame-race-sweep}"
LAMBDAS="${LAMBDAS:-6.0 2.0 0.5 0.2 0.1}"
mkdir -p "$OUT"

for L in $LAMBDAS; do
    log="$OUT/lambda-$L.txt"
    echo "=== JXL_FRAME_RACE_LAMBDA=$L ==="
    JXL_FRAME_RACE_LAMBDA="$L" sh "$ROOT/Scripts/cjxl-compare.sh" --quick > "$log" 2>&1 || {
        echo "  run FAILED (see $log)"; continue; }
    # Aggregates only: per-image timings are noisy run-to-run, per the harness's
    # own warning, and only the quality columns are reproducible.
    sed -n '/AGGREGATE/,/encode wall time/p' "$log" | sed 's/^/  /'
    echo "  --- canary: noise must not regress ---"
    grep -E "^synth_noise" "$log" | sed 's/^/  /' || echo "  (synth_noise row not found)"
done

echo
echo "Reports written to $OUT/lambda-*.txt"
echo "Pick by BD-rate SSIMULACRA2, and reject any value that regresses synth_noise"
echo "relative to 6.0 — that regression is the reason this race exists."
