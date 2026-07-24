#!/bin/sh
# Lossy RD-curve harness: encode a source at several qualities, decode, and
# report (size, PSNR) at each — plus, against the pre-RD baseline (obtained
# from the SAME binary via JXL_RD_LAMBDA=0), the matched-size PSNR gain.
#
# WHY A CURVE, NOT A POINT: rate-distortion changes (E5d RD quantization, and
# any future quant/strategy work) trivially trade size for quality — a smaller
# file at lower PSNR is NOT a win by itself. The only honest comparison is the
# PSNR-vs-size CURVE: at matched size, does PSNR go up? This script computes
# exactly that so lossy tuning is judged consistently.
#
# Usage:  sh Scripts/rd-curve.sh <source.ppm> [q1 q2 ...]
#   (default qualities: 30 50 70 90)
#
# Requires a built CLI (sh Scripts/build.sh) and cjxl/djxl not needed — this
# measures our encoder against our own decoder. cmp_ppm.py provides PSNR.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JXL="$ROOT/.build/manual/jxl"
CMP="$ROOT/Scripts/cmp_ppm.py"
SRC="${1:?usage: rd-curve.sh <source.ppm> [qualities...]}"
shift || true
QUALITIES="${*:-30 50 70 90}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Encode+decode+measure one (lambda, quality); echoes "size psnr".
measure() {
    lam="$1"; q="$2"
    JXL_RD_LAMBDA="$lam" "$JXL" encode "$SRC" "$TMP/e.jxl" "q$q" >/dev/null 2>&1
    sz=$(stat -f%z "$TMP/e.jxl")
    "$JXL" decode "$TMP/e.jxl" "$TMP/e.ppm" >/dev/null 2>&1
    ps=$(python3 "$CMP" "$SRC" "$TMP/e.ppm" 0 2>/dev/null | grep -oE 'PSNR=[0-9.]+' | cut -d= -f2)
    echo "$sz $ps"
}

# Collect both curves.
: > "$TMP/rd.dat"
: > "$TMP/base.dat"
printf '%-6s %12s %8s %12s %8s %10s\n' quality rd_size rd_psnr base_size base_psnr "gain@size"
for q in $QUALITIES; do
    set -- $(measure "" "$q");        rd_sz="$1";  rd_ps="$2"
    set -- $(measure 0 "$q");         bs_sz="$1";  bs_ps="$2"
    echo "$rd_sz $rd_ps" >> "$TMP/rd.dat"
    echo "$bs_sz $bs_ps" >> "$TMP/base.dat"
    printf '%-6s %12s %8s %12s %8s %10s\n' "q$q" "$rd_sz" "$rd_ps" "$bs_sz" "$bs_ps" "(see below)"
done

# Matched-size gain: for each RD point, interpolate the BASELINE curve at the
# RD point's size and report rd_psnr - baseline_psnr_at_that_size. Positive =
# genuine RD win (higher quality at the same bytes).
echo ""
echo "matched-size PSNR gain (RD vs pre-RD baseline, + = win):"
python3 - "$TMP/rd.dat" "$TMP/base.dat" <<'PY'
import sys
rd  = [tuple(map(float, l.split())) for l in open(sys.argv[1]) if l.strip()]
base= [tuple(map(float, l.split())) for l in open(sys.argv[2]) if l.strip()]
base.sort()
def interp(size):
    # piecewise-linear PSNR of the baseline curve at a given size
    if size <= base[0][0]:  return base[0][1]
    if size >= base[-1][0]: return base[-1][1]
    for (s0,p0),(s1,p1) in zip(base, base[1:]):
        if s0 <= size <= s1:
            t = 0 if s1==s0 else (size-s0)/(s1-s0)
            return p0 + t*(p1-p0)
    return base[-1][1]
for sz, ps in rd:
    g = ps - interp(sz)
    print(f"  size {int(sz):>10}: {g:+.3f} dB")
PY
