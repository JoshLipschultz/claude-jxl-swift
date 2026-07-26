#!/bin/sh
# Compare OUR lossy encoder against cjxl (libjxl 0.12) on a real corpus, at
# equal file size AND at equal quality.
#
# WHY THIS EXISTS: every prior lossy milestone in this repo compared the encoder
# only against its own previous commit (that is what Scripts/rd-curve.sh does).
# So the project had no idea whether it was 1 dB or 6 dB off the reference
# implementation. This script answers that, and is built to be pessimistic
# rather than flattering: it refuses to extrapolate, it reports a perceptual
# metric alongside PSNR (because cjxl optimises butteraugli, not squared error,
# so PSNR alone systematically favours us), and it uses float decodes so that
# djxl's default 8-bit blue-noise dither cannot floor the numbers near 54 dB.
#
# USAGE
#   sh Scripts/cjxl-compare.sh                     # default corpus, full sweep
#   sh Scripts/cjxl-compare.sh <corpus_dir>        # your own PPM/PGM/PAM dir
#   sh Scripts/cjxl-compare.sh --quick             # coarse sweep, ~4x faster
#   sh Scripts/cjxl-compare.sh <dir> --quick
#   REPS=1 sh Scripts/cjxl-compare.sh              # 1 timing rep (noisier)
#
# The default corpus is generated into .build/cjxl-corpus by Scripts/gen-corpus.py
# from macOS system photographs, so it is reproducible on any Mac without a
# download. Pass a directory to benchmark your own images instead (8-bit binary
# PPM / PGM / PAM P7 only -- that is what our CLI reads).
#
# Results are written to .build/cjxl-compare/report.txt and results.json, and
# also printed. See docs/lossy-vs-cjxl.md for the method and the findings.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JXL="$ROOT/.build/manual/jxl"
OUTDIR="$ROOT/.build/cjxl-compare"
CORPUS_DEFAULT="$ROOT/.build/cjxl-corpus"

CORPUS=""
EXTRA=""
for arg in "$@"; do
    case "$arg" in
        --quick) EXTRA="$EXTRA --quick" ;;
        --no-perceptual) EXTRA="$EXTRA --no-perceptual" ;;
        --efforts=*) EXTRA="$EXTRA --efforts ${arg#--efforts=}" ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) CORPUS="$arg" ;;
    esac
done

# ---- prerequisites. Checked explicitly and up front, because a missing tool
# midway through would otherwise show up as a column of "--" that looks like a
# measurement rather than an absent one.
fail=0
[ -x "$JXL" ] || { echo "missing $JXL -- run: DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer sh Scripts/build.sh" >&2; fail=1; }
for t in cjxl djxl python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; fail=1; }
done
PERC=1
for t in ssimulacra2 butteraugli_main; do
    command -v "$t" >/dev/null 2>&1 || PERC=0
done
[ "$fail" -eq 0 ] || exit 1
if [ "$PERC" -eq 0 ]; then
    echo "note: ssimulacra2/butteraugli_main not found -- perceptual metrics disabled."
    echo "      PSNR alone FAVOURS us, because cjxl tunes for butteraugli. Treat"
    echo "      any PSNR-only conclusion as an upper bound on our standing."
    EXTRA="$EXTRA --no-perceptual"
fi

# ---- corpus
if [ -z "$CORPUS" ]; then
    CORPUS="$CORPUS_DEFAULT"
    if [ ! -d "$CORPUS" ] || [ -z "$(ls -A "$CORPUS" 2>/dev/null)" ]; then
        echo "==> building default corpus in $CORPUS"
        python3 "$ROOT/Scripts/gen-corpus.py" "$CORPUS"
    else
        echo "==> reusing corpus in $CORPUS (delete it to rebuild)"
    fi
fi
[ -d "$CORPUS" ] || { echo "no such corpus dir: $CORPUS" >&2; exit 1; }

mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> sanity: both decoders must agree with the source on a LOSSLESS"
echo "    round-trip, else every dB below is suspect."
CAL="$TMP/cal.ppm"
python3 - "$CAL" <<'PY'
import sys
w, h = 61, 43
b = bytearray(b'P6\n%d %d\n255\n' % (w, h))
for y in range(h):
    for x in range(w):
        b += bytes([(x * 7 + y * 3) % 256, (y * 11) % 256, (x * x + y) % 256])
open(sys.argv[1], 'wb').write(b)
PY
"$JXL" encode "$CAL" "$TMP/cal_o.jxl" e2 >/dev/null 2>&1
"$JXL" decode "$TMP/cal_o.jxl" "$TMP/cal_o.pfm" float >/dev/null 2>&1
cjxl -d 0 --quiet "$CAL" "$TMP/cal_c.jxl" >/dev/null 2>&1
djxl --quiet "$TMP/cal_c.jxl" "$TMP/cal_c.pfm" >/dev/null 2>&1
# NOTE the redirect-to-file pattern: piping into grep would report GREP's exit
# status, not python's, which has produced false "all green" reports here before.
python3 "$ROOT/Scripts/psnr_any.py" "$CAL" "$TMP/cal_o.pfm" > "$TMP/cal_o.txt" 2>&1
o_rc=$?
python3 "$ROOT/Scripts/psnr_any.py" "$CAL" "$TMP/cal_c.pfm" > "$TMP/cal_c.txt" 2>&1
c_rc=$?
echo "    ours: $(cat "$TMP/cal_o.txt")   (rc=$o_rc)"
echo "    cjxl: $(cat "$TMP/cal_c.txt")   (rc=$c_rc)"
python3 - "$TMP/cal_o.txt" "$TMP/cal_c.txt" <<'PY'
import sys
bad = False
for p in sys.argv[1:]:
    txt = open(p).read()
    tok = [t for t in txt.split() if t.startswith('psnr=')]
    if not tok:
        print(f'    FAIL: no psnr in {txt.strip()[:80]}'); bad = True; continue
    v = tok[0].split('=', 1)[1]
    val = float('inf') if v == 'inf' else float(v)
    if val < 100:
        print(f'    FAIL: lossless round-trip only {val:.1f} dB -- expected >100 '
              f'(float32 rounding floor is ~149 dB). Orientation, endianness or '
              f'colour-space handling is wrong; do NOT trust the report.')
        bad = True
if bad:
    sys.exit(1)
print('    OK: both decoders round-trip losslessly (float32 rounding floor only).')
PY

echo ""
echo "==> sweeping (this takes a few minutes)"
# Deliberately NOT `python3 ... | tee report.txt`: a pipeline reports the LAST
# command's status, so tee's success would mask a python failure and we would
# cheerfully announce a report that was never produced. Redirect, capture the
# real status, then show the file.
rc=0
python3 "$ROOT/Scripts/cjxl_compare.py" \
    --corpus "$CORPUS" --tmp "$TMP" \
    --json "$OUTDIR/results.json" \
    --reps "${REPS:-3}" \
    $EXTRA > "$OUTDIR/report.txt" 2>&1 || rc=$?
cat "$OUTDIR/report.txt"

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "==> FAILED (exit $rc); $OUTDIR/report.txt holds the output above." >&2
    exit "$rc"
fi

echo ""
echo "==> wrote $OUTDIR/report.txt and $OUTDIR/results.json"
