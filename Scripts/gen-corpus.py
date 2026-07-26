#!/usr/bin/env python3
"""Build the lossy-benchmark corpus in .build/cjxl-corpus/.

WHY THIS FILE EXISTS AND WHAT IT IS CAREFUL ABOUT
-------------------------------------------------
The project's existing bench fixture (Scripts/gen-bench.sh) is a synthetic
sin()+noise field. A headline lossless number once came from it and turned out
not to generalise, so lossy conclusions must NOT rest on synthetic content
alone. This script therefore builds a corpus around GENUINE PHOTOGRAPHS.

It also does not use the repo's own .jxl test fixtures as photographic sources,
even though the task brief suggested some were photos. They are not: decoding
384x256_prog.jxl gives a smooth gradient plus uniform noise, and
640x480_lossless.jxl / 513x257_lossless.jxl are periodic high-frequency
checkerboards. Verified by inspection; see docs/lossy-vs-cjxl.md.

Photographic sources are macOS system assets, so any macOS machine can
reproduce the corpus bit-exactly without a download:

  A /System/Library/CoreServices/DefaultDesktop.heic          4096x2160 HEIC
    Golden Gate Bridge at sunset. Smooth sky, breaking surf, rock/pebble
    texture. (The same photo also ships as .../Wallpapers/.default/DefaultAerial.jpg.)
  B .../com.apple.idleassetsd/snapshots/category-preview-5EF41171-*.jpg
    1920x1080 aerial of Manhattan. Extremely dense fine detail (facades,
    windows) over a smooth cloudy sky. The hardest photographic case here.
  C .../com.apple.idleassetsd/snapshots/category-preview-8BE8B524-*.jpg
    1920x1080 underwater shot: dark, low-contrast, natural grain, fine bubbles.
  D /System/Library/Desktop Pictures/Sonoma.heic              6016x6016
    Not a photo — a smooth synthetic gradient artwork, used deliberately as
    the "smooth gradient" class because its gradients are multi-scale and
    realistic rather than a single mathematical ramp.

ARTEFACT HYGIENE (important): every source is itself already lossily coded
(HEVC or JPEG). Feeding a native-resolution crop of such a source to a DCT
codec is a biased test, because the source's own 8x8/transform artefacts are
cheap for a DCT codec to reproduce. So every photographic entry is produced by
cropping at 2x the target size and then downscaling 2x with a Lanczos filter,
which pushes the source's coding artefacts below the new Nyquist limit while
preserving real sensor detail statistics. This is standard practice for
preparing codec test images.

Synthetic entries are generated in pure Python from a fixed seed, so they are
reproducible on any platform. The text-like entry embeds its own 8x8 bitmap
font rather than depending on a system font, so no font version can change it.

Usage:  python3 Scripts/gen-corpus.py <outdir>
"""
import os
import sys
import math
import subprocess
import shutil

IDLE = "/Library/Application Support/com.apple.idleassetsd/snapshots"
SRC_BRIDGE = "/System/Library/CoreServices/DefaultDesktop.heic"
SRC_BRIDGE_ALT = "/System/Library/Wallpapers/.default/DefaultAerial.jpg"
SRC_CITY = f"{IDLE}/category-preview-5EF41171-4862-4F93-800C-AD86CE5E6891.jpg"
SRC_OCEAN = f"{IDLE}/category-preview-8BE8B524-6EAE-43F5-A3E8-01DCFA1BCD4B.jpg"
SRC_GRAD = "/System/Library/Desktop Pictures/Sonoma.heic"


def run(cmd):
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(f"FAILED: {' '.join(map(str, cmd))}\n{r.stderr.decode()[:400]}\n")
        return False
    return True


def photo(src, out, crop_w, crop_h, off_x, off_y, dst_w, dst_h, gray=False):
    """Crop crop_w x crop_h at (off_x,off_y) from src, Lanczos-downscale to
    dst_w x dst_h, write 8-bit binary PPM (or PGM when gray)."""
    if not os.path.exists(src):
        sys.stderr.write(f"SKIP (missing source): {src}\n")
        return False
    # "[0]" selects the FIRST frame. Some system HEICs (Sonoma.heic) carry two
    # frames -- light and dark appearance variants -- and without this magick
    # happily writes both, producing a PNM with two concatenated images that
    # every reader then mis-parses.
    cmd = ["magick", f"{src}[0]",
           "-crop", f"{crop_w}x{crop_h}+{off_x}+{off_y}", "+repage",
           "-filter", "Lanczos", "-resize", f"{dst_w}x{dst_h}!",
           "-colorspace", "sRGB", "-depth", "8"]
    if gray:
        cmd += ["-colorspace", "Gray", "-depth", "8", f"pgm:{out}"]
    else:
        cmd += [f"ppm:{out}"]
    return run(cmd)


# ---------------------------------------------------------------- synthetic
class Rnd:
    """Fixed LCG so synthetic content is identical on every machine/Python."""

    def __init__(self, seed=20260725):
        self.s = seed

    def next(self):
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s >> 11


# 8x8 bitmap font, uppercase + digits + a few marks. Sharp 1px stems, which is
# what makes text hard for a DCT codec (ringing) -- the point of this entry.
FONT = {
    'A': (0x18, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x00),
    'B': (0x7C, 0x42, 0x42, 0x7C, 0x42, 0x42, 0x7C, 0x00),
    'C': (0x3C, 0x42, 0x40, 0x40, 0x40, 0x42, 0x3C, 0x00),
    'D': (0x7C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x7C, 0x00),
    'E': (0x7E, 0x40, 0x40, 0x7C, 0x40, 0x40, 0x7E, 0x00),
    'F': (0x7E, 0x40, 0x40, 0x7C, 0x40, 0x40, 0x40, 0x00),
    'G': (0x3C, 0x42, 0x40, 0x4E, 0x42, 0x42, 0x3C, 0x00),
    'H': (0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00),
    'I': (0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00),
    'J': (0x1E, 0x04, 0x04, 0x04, 0x04, 0x44, 0x38, 0x00),
    'K': (0x42, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42, 0x00),
    'L': (0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7E, 0x00),
    'M': (0x42, 0x66, 0x5A, 0x5A, 0x42, 0x42, 0x42, 0x00),
    'N': (0x42, 0x62, 0x52, 0x4A, 0x46, 0x42, 0x42, 0x00),
    'O': (0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00),
    'P': (0x7C, 0x42, 0x42, 0x7C, 0x40, 0x40, 0x40, 0x00),
    'Q': (0x3C, 0x42, 0x42, 0x42, 0x4A, 0x44, 0x3A, 0x00),
    'R': (0x7C, 0x42, 0x42, 0x7C, 0x48, 0x44, 0x42, 0x00),
    'S': (0x3C, 0x42, 0x40, 0x3C, 0x02, 0x42, 0x3C, 0x00),
    'T': (0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00),
    'U': (0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00),
    'V': (0x42, 0x42, 0x42, 0x42, 0x24, 0x24, 0x18, 0x00),
    'W': (0x42, 0x42, 0x42, 0x5A, 0x5A, 0x66, 0x42, 0x00),
    'X': (0x42, 0x24, 0x18, 0x18, 0x18, 0x24, 0x42, 0x00),
    'Y': (0x42, 0x42, 0x24, 0x18, 0x18, 0x18, 0x18, 0x00),
    'Z': (0x7E, 0x02, 0x04, 0x18, 0x20, 0x40, 0x7E, 0x00),
    '0': (0x3C, 0x42, 0x46, 0x5A, 0x62, 0x42, 0x3C, 0x00),
    '1': (0x18, 0x28, 0x08, 0x08, 0x08, 0x08, 0x3E, 0x00),
    '2': (0x3C, 0x42, 0x02, 0x0C, 0x30, 0x40, 0x7E, 0x00),
    '3': (0x3C, 0x42, 0x02, 0x1C, 0x02, 0x42, 0x3C, 0x00),
    '4': (0x04, 0x0C, 0x14, 0x24, 0x7E, 0x04, 0x04, 0x00),
    '5': (0x7E, 0x40, 0x7C, 0x02, 0x02, 0x42, 0x3C, 0x00),
    '6': (0x1C, 0x20, 0x40, 0x7C, 0x42, 0x42, 0x3C, 0x00),
    '7': (0x7E, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00),
    '8': (0x3C, 0x42, 0x42, 0x3C, 0x42, 0x42, 0x3C, 0x00),
    '9': (0x3C, 0x42, 0x42, 0x3E, 0x02, 0x04, 0x38, 0x00),
    '.': (0, 0, 0, 0, 0, 0x18, 0x18, 0),
    ',': (0, 0, 0, 0, 0, 0x18, 0x08, 0x10),
    '-': (0, 0, 0, 0x3C, 0, 0, 0, 0),
    ':': (0, 0, 0x18, 0, 0, 0x18, 0, 0),
    '(': (0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0),
    ')': (0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0),
    '/': (0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00, 0),
    ' ': (0, 0, 0, 0, 0, 0, 0, 0),
}

TEXT = """THE JPEG XL BITSTREAM SPLITS AN IMAGE INTO GROUPS OF 256 PIXELS
AND CODES EACH GROUP WITH AN ADAPTIVE CONTEXT MODEL. VARDCT MODE
SELECTS A TRANSFORM SIZE PER BLOCK, FROM 2X2 UP TO 256X256, AND
QUANTISES THE RESULTING COEFFICIENTS IN THE XYB COLOUR SPACE.
MODULAR MODE INSTEAD PREDICTS EACH SAMPLE FROM ITS NEIGHBOURS
USING A WEIGHTED SELF-CORRECTING PREDICTOR (23 SUB-PREDICTORS),
THEN ENTROPY-CODES THE RESIDUAL. LOSSLESS USES MODULAR ONLY.
SHARP EDGES AND THIN STEMS ARE THE WORST CASE FOR ANY DCT CODEC
BECAUSE TRUNCATING HIGH-FREQUENCY COEFFICIENTS PRODUCES RINGING
VISIBLE AS HALOS AROUND GLYPHS. 0123456789 (SEE SECTION 4.2/K)"""


def gen_text(path, w=768, h=512, scale=2):
    """Text-like page: white bg, black 8x8 glyphs at 2x, plus hard-edged UI
    rectangles and 1px rules. Bimodal histogram, many sharp edges."""
    px = bytearray([245] * (w * h * 3))

    def rect(x0, y0, x1, y1, rgb):
        x0 = max(0, x0); y0 = max(0, y0); x1 = min(w, x1); y1 = min(h, y1)
        for y in range(y0, y1):
            base = (y * w) * 3
            for x in range(x0, x1):
                o = base + x * 3
                px[o] = rgb[0]; px[o + 1] = rgb[1]; px[o + 2] = rgb[2]

    # UI chrome: title bar, sidebar, accent chips -- large flat areas + edges.
    rect(0, 0, w, 26, (32, 34, 40))
    rect(0, 26, 120, h, (228, 230, 236))
    for i, col in enumerate([(200, 60, 50), (40, 130, 200), (230, 170, 40), (60, 160, 90)]):
        rect(12, 40 + i * 30, 108, 62 + i * 30, col)
    rect(126, 30, w - 6, 31, (170, 172, 178))          # 1px rule
    rect(w - 40, 6, w - 12, 20, (220, 60, 60))

    def glyph(ch, gx, gy, rgb=(16, 16, 20)):
        rows = FONT.get(ch)
        if rows is None:
            return
        for ry in range(8):
            bits = rows[ry]
            for rx in range(8):
                if bits & (0x80 >> rx):
                    for sy in range(scale):
                        for sx in range(scale):
                            x = gx + rx * scale + sx
                            y = gy + ry * scale + sy
                            if 0 <= x < w and 0 <= y < h:
                                o = (y * w + x) * 3
                                px[o] = rgb[0]; px[o + 1] = rgb[1]; px[o + 2] = rgb[2]

    y = 40
    for line in TEXT.strip('\n').split('\n'):
        x = 132
        for ch in line:
            glyph(ch, x, y)
            x += 8 * scale
            if x > w - 8 * scale:
                break
        y += 10 * scale
        if y > h - 8 * scale:
            break
    # A second, smaller block of text at 1x to add sub-8x8 detail.
    y2 = y + 8
    for line in TEXT.strip('\n').split('\n')[:4]:
        x = 132
        for ch in line:
            rows = FONT.get(ch)
            if rows:
                for ry in range(8):
                    bits = rows[ry]
                    for rx in range(8):
                        if bits & (0x80 >> rx):
                            xx, yy = x + rx, y2 + ry
                            if 0 <= xx < w and 0 <= yy < h:
                                o = (yy * w + xx) * 3
                                px[o] = px[o + 1] = px[o + 2] = 24
            x += 8
            if x > w - 8:
                break
        y2 += 9
        if y2 > h - 8:
            break
    with open(path, 'wb') as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        f.write(px)
    return True


def gen_noise(path, w=768, h=512):
    """Noise-heavy: broadband uniform noise (sigma ~ 32) on a mild low-frequency
    base, plus a few hard edges. Nearly incompressible high-frequency energy --
    this is where a codec's noise/adaptive-quant policy shows up."""
    r = Rnd(4242)
    px = bytearray()
    for y in range(h):
        row = bytearray()
        for x in range(w):
            base_r = 128 + 40 * math.sin(x * 0.006) + 20 * math.sin(y * 0.011)
            base_g = 120 + 35 * math.sin((x + y) * 0.005)
            base_b = 132 + 38 * math.cos(y * 0.008)
            edge = 45 if ((x // 96) + (y // 96)) % 5 == 0 else 0
            for base in (base_r, base_g, base_b):
                n = (r.next() % 129) - 64
                row.append(max(0, min(255, int(base + n + edge))))
        px += row
    with open(path, 'wb') as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        f.write(px)
    return True


def gen_alpha(path, rgb_src):
    """RGBA PAM (P7) = a photographic RGB plus a synthetic alpha plane that
    mixes a smooth radial ramp with a hard-edged circle, so alpha has both
    smooth and sharp structure."""
    d = open(rgb_src, 'rb').read()
    i = 2
    vals = []
    while len(vals) < 3:
        while d[i:i + 1].isspace():
            i += 1
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        vals.append(int(d[s:i]))
    w, h, _ = vals
    body = d[i + 1:]
    out = bytearray()
    cx, cy = w * 0.42, h * 0.55
    rad = min(w, h) * 0.30
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * 3
            dist = math.hypot(x - cx, y - cy)
            a = 255 if dist < rad else max(0, min(255, int(255 - (dist - rad) * 1.6)))
            ramp = int(255 * (0.35 + 0.65 * x / max(1, w - 1)))
            av = min(a, ramp)
            out += body[o:o + 3] + bytes([av])
    with open(path, 'wb') as f:
        f.write(f"P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".encode())
        f.write(out)
    return True


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '.build/cjxl-corpus'
    os.makedirs(out, exist_ok=True)
    if shutil.which('magick') is None:
        sys.exit("ImageMagick (`magick`) is required to build the photographic entries.")

    bridge = SRC_BRIDGE if os.path.exists(SRC_BRIDGE) else SRC_BRIDGE_ALT
    made = []

    def note(ok, name):
        if ok:
            made.append(name)
        return ok

    # --- Photographic. Crop 2x the target, Lanczos-downscale 2x (see header).
    # Whole scene: sky gradient + surf + rock, a balanced "typical photo".
    note(photo(bridge, f'{out}/photo_bridge.ppm', 4096, 2160, 0, 0, 1024, 540), 'photo_bridge')
    # Rocky foreground at high detail density.
    note(photo(bridge, f'{out}/photo_rocks.ppm', 1536, 1024, 2380, 1130, 768, 512), 'photo_rocks')
    # Sunset sky: smooth photographic gradient, very little detail.
    note(photo(bridge, f'{out}/photo_sky.ppm', 1536, 1024, 300, 60, 768, 512), 'photo_sky')
    # Manhattan aerial: the densest fine detail in the corpus.
    note(photo(SRC_CITY, f'{out}/photo_city.ppm', 1920, 1080, 0, 0, 960, 540), 'photo_city')
    # Underwater: dark, low contrast, natural grain.
    note(photo(SRC_OCEAN, f'{out}/photo_ocean.ppm', 1920, 1080, 0, 0, 960, 540), 'photo_ocean')
    # Grayscale, from the city photo's luma (hardest content, 1 channel).
    note(photo(SRC_CITY, f'{out}/gray_city.pgm', 1920, 1080, 0, 0, 960, 540, gray=True), 'gray_city')
    # Smooth gradient artwork (real asset, multi-scale gradients).
    note(photo(SRC_GRAD, f'{out}/grad_smooth.ppm', 4096, 4096, 960, 960, 768, 768), 'grad_smooth')

    # --- Synthetic, deterministic.
    note(gen_text(f'{out}/synth_text.ppm'), 'synth_text')
    note(gen_noise(f'{out}/synth_noise.ppm'), 'synth_noise')

    # --- Alpha (needs photo_bridge to exist).
    if os.path.exists(f'{out}/photo_bridge.ppm'):
        note(gen_alpha(f'{out}/alpha_bridge.pam', f'{out}/photo_bridge.ppm'), 'alpha_bridge')

    print(f"corpus in {out}: {len(made)} entries")
    for n in made:
        for ext in ('ppm', 'pgm', 'pam'):
            p = f'{out}/{n}.{ext}'
            if os.path.exists(p):
                print(f"  {n:<14} {os.path.getsize(p):>9} bytes  ({ext})")
                break


if __name__ == '__main__':
    main()
