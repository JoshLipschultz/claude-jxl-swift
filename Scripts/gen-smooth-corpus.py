#!/usr/bin/env python3
"""Smooth-content corpus, for the class the benchmark keeps naming worst.

WHY A SEPARATE CORPUS: the main corpus has exactly TWO smooth images, and the
RD calibration study's headline smooth-content result rested on both of them.
Two images is not enough to justify the work that result implies, so this widens
the class to eight before anything is built on it.

ARTEFACT HYGIENE, same rule as gen-corpus.py: every source is itself already
lossily coded (HEIC), so each crop is Lanczos-downscaled 2x. That pushes the
source's own transform artefacts below the new Nyquist limit — without it we
would partly be measuring Apple's encoder rather than ours, and on SMOOTH
content, where our gap is largest, that bias would be worst.
"""
import os
import subprocess
import sys

OUT = os.path.join(os.path.dirname(__file__), "..", ".build", "smooth-corpus")
DESK = "/System/Library/Desktop Pictures"

# name, source, crop w, crop h, offset x, offset y
JOBS = [
    ("smooth_radial", f"{DESK}/Radial Sky Blue.heic", 1600, 1200, 200, 200),
    ("smooth_imacblue", f"{DESK}/iMac Blue.heic", 1600, 1200, 300, 300),
    ("smooth_macpurp", f"{DESK}/Mac Purple.heic", 1600, 1200, 300, 300),
    ("smooth_imacpink", f"{DESK}/iMac Pink.heic", 1600, 1200, 300, 300),
    ("smooth_imacgrn", f"{DESK}/iMac Green.heic", 1600, 1200, 300, 300),
    ("smooth_sonoma", f"{DESK}/Sonoma.heic", 2400, 1800, 1200, 1200),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    made = 0
    for name, src, cw, ch, ox, oy in JOBS:
        if not os.path.exists(src):
            sys.stderr.write(f"SKIP (missing source): {name}\n")
            continue
        out = os.path.join(OUT, f"{name}.ppm")
        # "[0]" selects the first frame: some system HEICs carry light/dark
        # variants and without it magick writes both, concatenated.
        cmd = [
            "magick", f"{src}[0]",
            "-crop", f"{cw}x{ch}+{ox}+{oy}", "+repage",
            "-filter", "Lanczos", "-resize", f"{cw // 2}x{ch // 2}!",
            "-colorspace", "sRGB", "-depth", "8", f"ppm:{out}",
        ]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode == 0 and os.path.exists(out):
            print(f"  {name}: {os.path.getsize(out)} bytes")
            made += 1
        else:
            sys.stderr.write(f"FAILED {name}: {r.stderr.decode()[:200]}\n")
    # The two smooth images from the main corpus belong here too.
    main_corpus = os.path.join(os.path.dirname(__file__), "..", ".build", "cjxl-corpus")
    for name in ("grad_smooth.ppm", "photo_sky.ppm"):
        src = os.path.join(main_corpus, name)
        if os.path.exists(src):
            subprocess.run(["cp", src, OUT], check=False)
            made += 1
    print(f"built {made} smooth images in {OUT}")
    print("Run: sh Scripts/cjxl-compare.sh .build/smooth-corpus --quick")


if __name__ == "__main__":
    main()
