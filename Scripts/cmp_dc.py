#!/usr/bin/env python3
# Cross-check our VarDCT DC image against djxl.
# 1. djxl decodes the fixture to a PPM (sRGB).
# 2. We sRGB->linear, forward-opsin to XYB, average each 8x8 block.
# 3. Compare to our DC dump (.dcxyb), which is the dequantized XYB DC.
import sys, struct, subprocess, math, os

fixture, our_dump = sys.argv[1], sys.argv[2]
ppm = our_dump + ".ref.ppm"
subprocess.run(["djxl", fixture, ppm], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# --- read PPM (P6) ---
with open(ppm, "rb") as f:
    data = f.read()
assert data[:2] == b"P6"
idx = 2
fields = []
while len(fields) < 3:
    while idx < len(data) and data[idx:idx+1].isspace():
        idx += 1
    if data[idx:idx+1] == b'#':
        while data[idx:idx+1] not in (b'\n', b''):
            idx += 1
        continue
    start = idx
    while idx < len(data) and not data[idx:idx+1].isspace():
        idx += 1
    fields.append(int(data[start:idx]))
idx += 1  # single whitespace after maxval
W, H, maxval = fields
pix = data[idx:]
assert maxval == 255

# --- sRGB EOTF (display-from-encoded) ---
def srgb_to_linear(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

# --- forward opsin constants (libjxl v0.11.2) ---
M = [[0.30, 1.0-0.078-0.30, 0.078],
     [0.23, 1.0-0.078-0.23, 0.078],
     [0.24342268924547819, 0.20476744424496821, 1.0-0.24342268924547819-0.20476744424496821]]
BIAS = 0.0037930732552754493
cbrt_bias = BIAS ** (1.0/3.0)

def rgb_to_xyb(r, g, b):
    m0 = M[0][0]*r + M[0][1]*g + M[0][2]*b + BIAS
    m1 = M[1][0]*r + M[1][1]*g + M[1][2]*b + BIAS
    m2 = M[2][0]*r + M[2][1]*g + M[2][2]*b + BIAS
    m0 = max(m0, 0.0); m1 = max(m1, 0.0); m2 = max(m2, 0.0)
    g0 = m0 ** (1.0/3.0) - cbrt_bias
    g1 = m1 ** (1.0/3.0) - cbrt_bias
    g2 = m2 ** (1.0/3.0) - cbrt_bias
    return (0.5*(g0-g1), 0.5*(g0+g1), g2)

# --- block-average XYB of the reference ---
bw = (W + 7) // 8
bh = (H + 7) // 8
ref = [[0.0, 0.0, 0.0] for _ in range(bw*bh)]
cnt = [0]*(bw*bh)
for y in range(H):
    for x in range(W):
        off = (y*W + x)*3
        r = srgb_to_linear(pix[off]); g = srgb_to_linear(pix[off+1]); b = srgb_to_linear(pix[off+2])
        xx, yy, bb = rgb_to_xyb(r, g, b)
        bi = (y//8)*bw + (x//8)
        ref[bi][0] += xx; ref[bi][1] += yy; ref[bi][2] += bb; cnt[bi] += 1
for i in range(bw*bh):
    if cnt[i]:
        ref[i] = [v/cnt[i] for v in ref[i]]

# --- read our dump ---
with open(our_dump, "rb") as f:
    d = f.read()
nl = d.index(b'\n')
ow, oh = map(int, d[:nl].split())
vals = struct.unpack("<%df" % (ow*oh*3), d[nl+1:nl+1+ow*oh*3*4])
assert ow == bw and oh == bh, f"size mismatch {ow}x{oh} vs {bw}x{bh}"

# --- compare ---
names = ["X", "Y", "B"]
print(f"{fixture}: {bw}x{bh} blocks")
overall_ok = True
for c in range(3):
    diffs = []
    sref = sour = 0.0
    for i in range(bw*bh):
        o = vals[i*3+c]; r = ref[i][c]
        diffs.append(abs(o-r)); sref += r; sour += o
    mad = sum(diffs)/len(diffs)
    mx = max(diffs)
    mean_ref = sref/len(diffs); mean_our = sour/len(diffs)
    # Y/B span ~0.5, X spans ~0.01; gaborish+AC perturb per-block means a little.
    tol_mean = 0.01
    ok = abs(mean_our - mean_ref) < tol_mean
    overall_ok = overall_ok and ok
    print(f"  {names[c]}: mean ours={mean_our:+.4f} ref={mean_ref:+.4f} "
          f"(Δmean={mean_our-mean_ref:+.4f})  per-block MAD={mad:.4f} max={mx:.4f}  "
          f"{'OK' if ok else 'MISMATCH'}")
print("  RESULT:", "PLAUSIBLE (DC matches block-mean XYB)" if overall_ok else "MISMATCH")
os.remove(ppm)
