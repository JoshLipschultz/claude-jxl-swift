#!/usr/bin/env python3
# Compare two binary PPMs (P6); print mean|d| and PSNR, and exit non-zero if
# PSNR is below the threshold (default 40). Used to check VarDCT reconstruction
# against djxl.
import sys, math
def rd(p):
    d = open(p, "rb").read(); i = 2; f = []
    while len(f) < 3:
        while d[i:i+1].isspace(): i += 1
        s = i
        while not d[i:i+1].isspace(): i += 1
        f.append(int(d[s:i]))
    return f[0], f[1], d[i+1:]
w, h, a = rd(sys.argv[1]); w2, h2, b = rd(sys.argv[2])
assert (w, h) == (w2, h2), f"size {w}x{h} vs {w2}x{h2}"
threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 40.0
n = min(len(a), len(b))
mse = sum((a[i]-b[i])**2 for i in range(n)) / n
md = sum(abs(a[i]-b[i]) for i in range(n)) / n
psnr = 10*math.log10(255*255/mse) if mse else 99.0
print(f"{w}x{h}  mean|d|={md:.3f}  PSNR={psnr:.2f} dB")
sys.exit(0 if psnr >= threshold else 1)
