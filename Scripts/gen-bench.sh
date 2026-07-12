#!/bin/sh
# Generates large photographic-ish benchmark fixtures in .build/bench using
# cjxl (not committed — they are multi-megabyte). The source PPM mixes smooth
# gradients, edges, and pseudo-random texture so entropy coding sees realistic
# statistics rather than trivially-compressible content.
#
#   sh Scripts/gen-bench.sh          # 3000x2000 lossy + lossless
#   .build/manual/jxl bench .build/bench/bench_lossy.jxl
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/bench"
mkdir -p "$OUT"

W=${1:-3000}
H=${2:-2000}

if [ ! -f "$OUT/bench_${W}x${H}.ppm" ]; then
    echo "==> Generating ${W}x${H} source PPM"
    python3 - "$W" "$H" "$OUT/bench_${W}x${H}.ppm" <<'EOF'
import sys, math
w, h, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
buf = bytearray()
buf += f"P6\n{w} {h}\n255\n".encode()
state = 12345
def rnd():
    global state
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF
    return state
for y in range(h):
    row = bytearray()
    for x in range(w):
        # Smooth base gradients + sinusoidal "texture" + mild noise + hard edges.
        base_r = int(120 + 90 * math.sin(x * 0.004) + 40 * math.sin(y * 0.007))
        base_g = int(110 + 80 * math.sin((x + y) * 0.003))
        base_b = int(100 + 90 * math.sin(y * 0.005) * math.cos(x * 0.002))
        n = (rnd() >> 16) % 17 - 8
        edge = 40 if ((x // 200) + (y // 150)) % 7 == 0 else 0
        row.append(max(0, min(255, base_r + n + edge)))
        row.append(max(0, min(255, base_g + n)))
        row.append(max(0, min(255, base_b - n)))
    buf += row
open(path, "wb").write(buf)
EOF
fi

# -q 95 -e 4 stays within the decoder's current transform support (<= 32x32;
# higher efforts emit occasional DCT64+ blocks on smooth content).
echo "==> Encoding lossy (q95 e4)"
cjxl -q 95 -e 4 "$OUT/bench_${W}x${H}.ppm" "$OUT/bench_lossy.jxl" 2>/dev/null
echo "==> Encoding lossless"
cjxl -q 100 -e 3 "$OUT/bench_${W}x${H}.ppm" "$OUT/bench_lossless.jxl" 2>/dev/null
ls -la "$OUT" | grep bench_
