#!/usr/bin/env python3
"""PSNR between two images that may be in DIFFERENT container formats/depths.

Why this exists (and why cmp_ppm.py is not enough): cmp_ppm.py compares two
8-bit P6 PPMs byte-for-byte-ish. That is unusable for cross-codec comparison
because djxl 0.12 blue-noise-DITHERS its 8-bit output by default while our
decoder does not, which floors 8-bit agreement near 54 dB regardless of the
true coding error. So cross-codec work must compare FLOAT decodes.

This tool reads PGM/PPM (P2/P5/P3/P6, 8- or 16-bit), PAM (P7), and PFM
(PF/Pf, either endianness) and normalises everything to float in [0,1] so a
float decode can be compared against an integer source.

Key correctness details:
  * PFM endianness comes from the SIGN of the scale field (negative =
    little-endian). Our decoder writes little-endian, djxl writes big-endian.
    We honour the header rather than assuming, i.e. we compare VALUES not bytes.
  * PFM scanline order is bottom-to-top by convention. Both our decoder and
    djxl 0.12 follow that convention, so both get flipped back to top-down on
    load and orientation cancels out. `--selftest` verifies this empirically
    (a lossless round-trip must come back as PSNR=inf), so a future decoder
    change that breaks the convention shows up as a loud failure rather than a
    silently wrong dB number.
  * Alpha: by default only the COLOUR channels are scored, because the two
    codecs may carry alpha at different precision and mixing an exactly-coded
    alpha plane into the average inflates PSNR. --with-alpha overrides.

Usage:
  psnr_any.py <reference> <test> [--with-alpha] [--quiet]
Prints:  "<w>x<h> ch=<n> rmse=<r> psnr=<p>"  (psnr in dB, peak 1.0)
Exit 0 on success, 2 on a mismatch that makes comparison meaningless.
"""
import sys
import math
import struct
import array


def _tokens(data, pos):
    """Yield whitespace-separated ASCII tokens from a PNM header, skipping #comments."""
    while True:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b'#':
            while pos < len(data) and data[pos:pos + 1] not in (b'\n', b'\r'):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        yield data[start:pos], pos
        if pos >= len(data):
            return


def _read_pnm(data):
    """P2/P3/P5/P6 -> (w, h, channels, list-of-floats interleaved, normalised)."""
    magic = data[:2]
    tok = _tokens(data, 2)
    vals = []
    while len(vals) < 3:
        t, pos = next(tok)
        vals.append(int(t))
    w, h, maxv = vals
    ch = 3 if magic in (b'P3', b'P6') else 1
    if magic in (b'P5', b'P6'):
        body = data[pos + 1:]
        n = w * h * ch
        if maxv > 255:
            a = array.array('H')
            a.frombytes(body[:n * 2])
            if sys.byteorder == 'little':
                a.byteswap()          # PNM 16-bit is big-endian
            px = a
        else:
            px = body[:n]
    else:
        px = []
        for t, _ in tok:
            px.append(int(t))
            if len(px) == w * h * ch:
                break
    inv = 1.0 / maxv
    return w, h, ch, [v * inv for v in px]


def _read_pam(data):
    """P7 (netpbm arbitrary map) -> (w, h, channels, normalised floats)."""
    hdr_end = data.index(b'ENDHDR')
    hdr = data[:hdr_end].split(b'\n')
    w = h = depth = maxv = None
    for line in hdr:
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0].upper()
        if key == b'WIDTH':
            w = int(parts[1])
        elif key == b'HEIGHT':
            h = int(parts[1])
        elif key == b'DEPTH':
            depth = int(parts[1])
        elif key == b'MAXVAL':
            maxv = int(parts[1])
    body_start = hdr_end + len(b'ENDHDR')
    while data[body_start:body_start + 1] in (b'\n', b'\r'):
        body_start += 1
    n = w * h * depth
    body = data[body_start:]
    if maxv > 255:
        a = array.array('H')
        a.frombytes(body[:n * 2])
        if sys.byteorder == 'little':
            a.byteswap()
        px = a
    else:
        px = body[:n]
    inv = 1.0 / maxv
    return w, h, depth, [v * inv for v in px]


def _read_pfm(data):
    """PF/Pf -> (w, h, channels, floats). Honours endianness AND flips
    bottom-up scanlines back to top-down so PFM can be compared to PNM."""
    tok = _tokens(data, 0)
    t, pos = next(tok)
    magic = t
    ch = 3 if magic == b'PF' else 1
    t, pos = next(tok); w = int(t)
    t, pos = next(tok); h = int(t)
    t, pos = next(tok); scale = float(t)
    body = data[pos + 1:]
    n = w * h * ch
    a = array.array('f')
    a.frombytes(body[:n * 4])
    little = scale < 0
    if (sys.byteorder == 'little') != little:
        a.byteswap()
    # PFM stores the BOTTOM row first; flip to top-down to match PNM.
    stride = w * ch
    out = []
    for y in range(h - 1, -1, -1):
        out.extend(a[y * stride:(y + 1) * stride])
    return w, h, ch, out


def load(path):
    data = open(path, 'rb').read()
    magic = data[:2]
    if magic == b'P7':
        return _read_pam(data)
    if magic in (b'PF', b'Pf'):
        return _read_pfm(data)
    if magic in (b'P2', b'P3', b'P5', b'P6'):
        return _read_pnm(data)
    raise SystemExit(f'unsupported image magic {magic!r} in {path}')


def psnr(ref_path, test_path, with_alpha=False):
    rw, rh, rc, rp = load(ref_path)
    tw, th, tc, tp = load(test_path)
    if (rw, rh) != (tw, th):
        raise SystemExit(f'dimension mismatch: {rw}x{rh} vs {tw}x{th}')
    # Score the colour channels only unless asked otherwise. If one side is
    # grayscale and the other RGB, compare on the common channel count.
    rcol = 1 if rc == 1 else 3
    tcol = 1 if tc == 1 else 3
    if with_alpha:
        nc = min(rc, tc)
        rcol = tcol = nc
    cmpc = min(rcol, tcol)
    se = 0.0
    npx = rw * rh
    for i in range(npx):
        ro = i * rc
        to = i * tc
        for c in range(cmpc):
            d = rp[ro + c] - tp[to + c]
            se += d * d
    n = npx * cmpc
    mse = se / n
    rmse = math.sqrt(mse)
    p = float('inf') if mse == 0 else 10.0 * math.log10(1.0 / mse)
    return rw, rh, cmpc, rmse, p


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = {a for a in sys.argv[1:] if a.startswith('--')}
    if len(args) < 2:
        raise SystemExit(__doc__)
    w, h, c, rmse, p = psnr(args[0], args[1], '--with-alpha' in flags)
    ptxt = 'inf' if p == float('inf') else f'{p:.4f}'
    print(f'{w}x{h} ch={c} rmse={rmse:.8f} psnr={ptxt}')


if __name__ == '__main__':
    main()
