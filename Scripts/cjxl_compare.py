#!/usr/bin/env python3
"""Sweep our lossy encoder and cjxl over a corpus and compare their RD curves.

Invoked by Scripts/cjxl-compare.sh (which checks prerequisites and builds the
default corpus). See docs/lossy-vs-cjxl.md for the method write-up.

WHAT IS MEASURED
  For every source image, our encoder is swept over q values and cjxl over
  --distance values (at two efforts). Each point records file size, encode wall
  time, and three quality metrics computed against the ORIGINAL source:
    PSNR          - our own float comparison (Scripts/psnr_any.py)
    SSIMULACRA2   - libjxl's perceptual metric, 0..100
    Butteraugli   - libjxl's perceptual distance, lower is better
  All three are needed because cjxl's --distance targets butteraugli, not
  squared error: judging it on PSNR alone flatters us. Reporting all three
  keeps that bias visible instead of hidden.

DECODERS
  Each codec is decoded by its OWN decoder (ours -> `jxl decode ... float`,
  cjxl -> `djxl`), to float PFM. This measures encoder+decoder as shipped, and
  it is required here anyway: djxl 0.12 blue-noise-dithers 8-bit output by
  default while our decoder does not, so any 8-bit comparison would be floored
  near 54 dB by dither noise rather than by coding error. Float PFM has no
  dither. Scripts/psnr_any.py verifies both decoders agree to ~149 dB on a
  lossless round-trip, which is the noise floor of this whole measurement.

TWO FRAMINGS, PLUS AN AGGREGATE
  equal-size quality delta : ours - cjxl, interpolating cjxl's curve at our
                             file size. "At the same bytes, how much worse?"
  equal-quality size ratio : our size / cjxl size at the same quality.
                             "To look the same, how many more bytes?"
  BD-rate                  : Bjontegaard average bitrate difference over the
                             quality range the two curves share. The standard
                             single number; positive means we need more bits.

  Interpolation is piecewise-linear in log2(size) rather than linear in size.
  Scripts/rd-curve.sh interpolates linearly in size, which is fine for two
  nearby curves from the same encoder but biased across a 20x rate range,
  because quality is close to linear in log(rate), not in rate. Crucially, and
  unlike rd-curve.sh, this script REFUSES to extrapolate: a query outside the
  measured range yields None and is reported as "--" rather than being silently
  clamped to an endpoint, which would manufacture a favourable number.
"""
import os
import sys
import math
import json
import time
import argparse
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
JXL = os.path.join(ROOT, '.build', 'manual', 'jxl')
PSNR = os.path.join(HERE, 'psnr_any.py')

OUR_Q = [30, 40, 50, 60, 70, 75, 80, 85, 90, 95]
CJXL_D = [0.3, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 13.0, 16.0, 20.0]
QUICK_Q = [40, 60, 75, 85, 95]
QUICK_D = [0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 20.0]

# Content class per corpus entry, used only to group the summary.
CLASS = {
    'photo_bridge': 'photo (mixed)',
    'photo_rocks': 'photo (high detail)',
    'photo_city': 'photo (high detail)',
    'photo_ocean': 'photo (dark/grain)',
    'photo_sky': 'photo (smooth)',
    'grad_smooth': 'smooth gradient',
    'synth_text': 'text/synthetic',
    'synth_noise': 'noise-heavy',
    'gray_city': 'grayscale',
    'alpha_bridge': 'alpha',
}


def sh(cmd, reps=1):
    """Run cmd, returning (returncode, best_wall_seconds, stderr_text).
    Wall time is the BEST of `reps` runs: the minimum is the least
    noise-contaminated estimate of the work, since scheduling and cache effects
    only ever add time."""
    best = float('inf')
    rc = 0
    err = ''
    for _ in range(reps):
        t0 = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True)
        dt = time.perf_counter() - t0
        rc = p.returncode
        err = p.stderr.decode('utf-8', 'replace')
        best = min(best, dt)
        if rc != 0:
            break
    return rc, best, err


def metric_psnr(ref, test):
    p = subprocess.run([sys.executable, PSNR, ref, test], capture_output=True)
    if p.returncode != 0:
        return None
    for tok in p.stdout.decode().split():
        if tok.startswith('psnr='):
            v = tok.split('=', 1)[1]
            return float('inf') if v == 'inf' else float(v)
    return None


def metric_s2(ref, test):
    p = subprocess.run(['ssimulacra2', ref, test], capture_output=True)
    if p.returncode != 0:
        return None
    try:
        return float(p.stdout.decode().strip().split()[0])
    except (ValueError, IndexError):
        return None


def metric_ba(ref, test):
    p = subprocess.run(['butteraugli_main', ref, test], capture_output=True)
    if p.returncode != 0:
        return None
    try:
        return float(p.stdout.decode().strip().split()[0])
    except (ValueError, IndexError):
        return None


# ------------------------------------------------------------------ sweeps
def pixel_count(path):
    """Pixels in a PNM/PAM, so sizes can be reported as bits per pixel."""
    d = open(path, 'rb').read(400)
    if d[:2] == b'P7':
        w = h = None
        for line in d.split(b'\n'):
            p = line.split()
            if len(p) >= 2 and p[0].upper() == b'WIDTH':
                w = int(p[1])
            if len(p) >= 2 and p[0].upper() == b'HEIGHT':
                h = int(p[1])
        return (w or 0) * (h or 0)
    i, vals = 2, []
    while len(vals) < 2:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] not in (b'\n', b''):
                i += 1
            continue
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        vals.append(int(d[s:i]))
    return vals[0] * vals[1]


def sweep_ours(src, tmp, qs, reps, want_perceptual):
    pts = []
    for q in qs:
        jxl = os.path.join(tmp, f'o_q{q}.jxl')
        rc, enc_t, err = sh([JXL, 'encode', src, jxl, f'q{q}'], reps)
        if rc != 0:
            return pts, err.strip().splitlines()[0] if err.strip() else f'encode rc={rc}'
        dec = os.path.join(tmp, f'o_q{q}.pfm')
        rc2, dec_t, err2 = sh([JXL, 'decode', jxl, dec, 'float'], 1)
        if rc2 != 0:
            return pts, f'decode failed: {err2.strip()[:120]}'
        pt = {
            'label': f'q{q}', 'size': os.path.getsize(jxl),
            'enc_s': enc_t, 'dec_s': dec_t,
            'psnr': metric_psnr(src, dec),
        }
        if want_perceptual:
            pt['s2'] = metric_s2(src, dec)
            pt['ba'] = metric_ba(src, dec)
        pts.append(pt)
        os.remove(dec)
    return pts, None


def sweep_cjxl(src, tmp, ds, effort, reps, want_perceptual):
    pts = []
    for d in ds:
        jxl = os.path.join(tmp, f'c_e{effort}_d{d}.jxl')
        rc, enc_t, err = sh(['cjxl', '-d', str(d), '-e', str(effort),
                             '--quiet', src, jxl], reps)
        if rc != 0:
            return pts, err.strip()[:160] or f'cjxl rc={rc}'
        dec = os.path.join(tmp, f'c_e{effort}_d{d}.pfm')
        rc2, dec_t, err2 = sh(['djxl', '--quiet', jxl, dec], 1)
        if rc2 != 0:
            return pts, f'djxl failed: {err2.strip()[:120]}'
        pt = {
            'label': f'd{d}', 'size': os.path.getsize(jxl),
            'enc_s': enc_t, 'dec_s': dec_t,
            'psnr': metric_psnr(src, dec),
        }
        if want_perceptual:
            pt['s2'] = metric_s2(src, dec)
            pt['ba'] = metric_ba(src, dec)
        pts.append(pt)
        os.remove(dec)
    return pts, None


# ----------------------------------------------------------- interpolation
def pareto(pts):
    """Keep only non-dominated (log2size, quality) points -- the RD frontier.

    Necessary, not cosmetic. Neither encoder's sweep is monotonic in practice:
    cjxl on text content jumps to modular/palette mode and lands 9323 bytes at
    53.2 dB while ALSO landing 6728 bytes at 60.2 dB, and on smooth content its
    -d 10 point is both smaller and better than its -d 8 point. Interpolating
    through such a curve as if it were a function of size produces nonsense.
    Taking the frontier -- for each size, the best quality actually achieved at
    that size or below -- is the standard fix, and it is the charitable reading
    for whichever codec is being interpolated, since it uses that codec's best
    observed operating points rather than its unlucky ones."""
    out = []
    best = -float('inf')
    for ls, v in sorted(pts):          # ascending size
        if v > best:
            out.append((ls, v))
            best = v
    return out


def _clean(pts, key):
    """(log2 size, metric) pairs, finite only, reduced to the RD frontier."""
    out = []
    for p in pts:
        v = p.get(key)
        s = p.get('size')
        if v is None or s is None or not math.isfinite(v) or s <= 0:
            continue
        out.append((math.log2(s), float(v)))
    return pareto(out)


def interp(xs_ys, x):
    """Piecewise-linear y at x. Returns None outside the measured range --
    deliberately, so extrapolation can never masquerade as a measurement."""
    pts = sorted(xs_ys)
    if not pts or x < pts[0][0] - 1e-12 or x > pts[-1][0] + 1e-12:
        return None
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x0 <= x <= x1:
            if x1 == x0:
                return (y0 + y1) / 2
            t = (x - x0) / (x1 - x0)
            return y0 + t * (y1 - y0)
    return pts[-1][1]


def equal_size_delta(ours, theirs, key):
    """For each of our points, ours_metric - cjxl_metric at OUR file size."""
    ref = [(ls, v) for ls, v in _clean(theirs, key)]
    by_size = sorted(ref)
    res = []
    for p in ours:
        v = p.get(key)
        if v is None or not math.isfinite(v):
            res.append((p, None))
            continue
        got = interp(by_size, math.log2(p['size']))
        res.append((p, None if got is None else v - got))
    return res


def equal_quality_ratio(ours, theirs, key, higher_better=True):
    """For each of our points, our_size / cjxl_size at OUR quality.
    >1 means we spend more bytes for the same quality."""
    ref = [(v, ls) for ls, v in _clean(theirs, key)]
    res = []
    for p in ours:
        v = p.get(key)
        if v is None or not math.isfinite(v):
            res.append((p, None))
            continue
        got = interp(ref, float(v))
        if got is None:
            res.append((p, None))
        else:
            res.append((p, p['size'] / (2.0 ** got)))
    return res


def bd_rate(ours, theirs, key):
    """Bjontegaard average bitrate difference (%) over the quality interval the
    curves share. Positive = we need that many percent MORE bits for equal
    quality. Trapezoidal integration of log2(size) against the quality metric,
    piecewise-linear between measured points (the classic formulation fits a
    cubic; with 10-15 well-spaced points the piecewise-linear integral is
    within a few tenths of a percent and cannot oscillate)."""
    a = _clean(ours, key)      # (log2 size, metric)
    b = _clean(theirs, key)
    if len(a) < 2 or len(b) < 2:
        return None, None
    a_by_q = sorted((v, ls) for ls, v in a)
    b_by_q = sorted((v, ls) for ls, v in b)
    lo = max(a_by_q[0][0], b_by_q[0][0])
    hi = min(a_by_q[-1][0], b_by_q[-1][0])
    if not (hi > lo):
        return None, None
    n = 200
    acc = 0.0
    step = (hi - lo) / n
    prev = None
    for i in range(n + 1):
        q = lo + i * step
        ra = interp(a_by_q, q)
        rb = interp(b_by_q, q)
        if ra is None or rb is None:
            continue
        d = ra - rb
        if prev is not None:
            acc += 0.5 * (prev + d) * step
        prev = d
    mean_dlog2 = acc / (hi - lo)
    pct = (2.0 ** mean_dlog2 - 1.0) * 100.0
    return pct, (lo, hi)


# ---------------------------------------------------------------- reporting
def fmt(v, spec='{:+.2f}', dash='   --'):
    return dash if v is None else spec.format(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', required=True)
    ap.add_argument('--tmp', required=True)
    ap.add_argument('--json', default=None)
    ap.add_argument('--quick', action='store_true')
    ap.add_argument('--reps', type=int, default=3)
    ap.add_argument('--no-perceptual', action='store_true')
    ap.add_argument('--efforts', default='7,3')
    args = ap.parse_args()

    qs = QUICK_Q if args.quick else OUR_Q
    ds = QUICK_D if args.quick else CJXL_D
    efforts = [int(x) for x in args.efforts.split(',') if x.strip()]
    perceptual = not args.no_perceptual

    exts = ('.ppm', '.pgm', '.pam', '.pnm')
    srcs = sorted(f for f in os.listdir(args.corpus) if f.lower().endswith(exts))
    if not srcs:
        sys.exit(f'no PPM/PGM/PAM sources in {args.corpus}')

    print(f'corpus: {args.corpus}   images: {len(srcs)}')
    print(f'our q sweep : {qs}')
    print(f'cjxl -d sweep: {ds}   efforts: {efforts}')
    print(f'metrics: PSNR' + ('  SSIMULACRA2  Butteraugli' if perceptual else '')
          + f'   timing = best of {args.reps}')
    print()

    results = {}
    for fn in srcs:
        name = os.path.splitext(fn)[0]
        src = os.path.join(args.corpus, fn)
        sys.stdout.write(f'  sweeping {name:<14} ')
        sys.stdout.flush()
        ours, oerr = sweep_ours(src, args.tmp, qs, args.reps, perceptual)
        cj = {}
        cerr = {}
        for e in efforts:
            cj[e], cerr[e] = sweep_cjxl(src, args.tmp, ds, e, args.reps, perceptual)
        results[name] = {'src': fn, 'ours': ours, 'ours_err': oerr,
                         'cjxl': cj, 'cjxl_err': cerr, 'px': pixel_count(src),
                         'class': CLASS.get(name, '?')}
        if oerr:
            sys.stdout.write(f'OURS UNSUPPORTED: {oerr}\n')
        else:
            sys.stdout.write(f'{len(ours)} ours / '
                             + ' / '.join(f'{len(cj[e])} cjxl-e{e}' for e in efforts) + '\n')
        sys.stdout.flush()

    if args.json:
        with open(args.json, 'w') as f:
            json.dump(results, f, indent=1)

    prim = efforts[0]
    report(results, prim, efforts, perceptual)


def report(results, prim, efforts, perceptual):
    W = 92
    keys = [('psnr', 'PSNR (dB)', True)]
    if perceptual:
        keys.append(('s2', 'SSIMULACRA2', True))

    # ---------------- per-image RD detail
    for name, r in results.items():
        print('\n' + '=' * W)
        print(f'{name}   [{r["class"]}]   source: {r["src"]}')
        print('=' * W)
        if r['ours_err']:
            print(f'  our lossy encoder: UNSUPPORTED -- {r["ours_err"]}')
            cjp = r['cjxl'].get(prim) or []
            if cjp:
                print(f'  cjxl -e{prim} works; its curve spans '
                      f'{min(p["size"] for p in cjp)}..{max(p["size"] for p in cjp)} bytes.')
            continue
        cjp = r['cjxl'].get(prim) or []
        if not cjp:
            print(f'  cjxl -e{prim} produced no points: {r["cjxl_err"].get(prim)}')
            continue

        px = r.get('px') or 1
        print(f'  OURS                                          | vs cjxl -e{prim} at OUR size / OUR quality')
        hdr = (f'  {"q":<5}{"bytes":>9}{"bpp":>7}{"PSNR":>8}'
               + (f'{"S2":>7}{"BA":>7}' if perceptual else '')
               + f'{"enc_s":>8}  |  {"dPSNR":>8}'
               + (f'{"dS2":>7}' if perceptual else '')
               + f'{"size/cjxl":>11}')
        print(hdr)
        d_psnr = dict((id(p), v) for p, v in equal_size_delta(r['ours'], cjp, 'psnr'))
        d_s2 = dict((id(p), v) for p, v in equal_size_delta(r['ours'], cjp, 's2')) if perceptual else {}
        rat = dict((id(p), v) for p, v in equal_quality_ratio(r['ours'], cjp, 'psnr'))
        for p in r['ours']:
            line = (f'  {p["label"]:<5}{p["size"]:>9}{p["size"]*8.0/px:>7.3f}'
                    f'{fmt(p.get("psnr"), "{:.2f}"):>8}')
            if perceptual:
                line += f'{fmt(p.get("s2"), "{:.1f}"):>7}{fmt(p.get("ba"), "{:.2f}"):>7}'
            line += f'{p["enc_s"]:>8.3f}  |  {fmt(d_psnr.get(id(p))):>8}'
            if perceptual:
                line += f'{fmt(d_s2.get(id(p)), "{:+.1f}"):>7}'
            rv = rat.get(id(p))
            line += f'{("  --" if rv is None else f"{rv:.2f}x"):>11}'
            print(line)

        print(f'  cjxl -e{prim} reference curve:')
        front = {round(ls, 9) for ls, _ in _clean(cjp, 'psnr')}
        for p in cjp:
            mark = ' ' if round(math.log2(p['size']), 9) in front else 'x'
            line = (f' {mark}{p["label"]:<5}{p["size"]:>9}{p["size"]*8.0/px:>7.3f}'
                    f'{fmt(p.get("psnr"), "{:.2f}"):>8}')
            if perceptual:
                line += f'{fmt(p.get("s2"), "{:.1f}"):>7}{fmt(p.get("ba"), "{:.2f}"):>7}'
            line += f'{p["enc_s"]:>8.3f}'
            print(line)
        ndrop = sum(1 for p in cjp if round(math.log2(p['size']), 9) not in front)
        if ndrop:
            print(f'    ("x" = dominated: {ndrop}/{len(cjp)} cjxl points are beaten on BOTH '
                  f'size and PSNR by\n     another of its own points, so cjxl\'s sweep is '
                  f'non-monotonic here. Only the\n     frontier is used for interpolation '
                  f'and BD-rate.)')

        for key, kname, _ in keys:
            pct, rng = bd_rate(r['ours'], cjp, key)
            if pct is None:
                print(f'  BD-rate ({kname:<11}): -- (curves do not overlap)')
            else:
                print(f'  BD-rate ({kname:<11}): {pct:+7.1f} %   '
                      f'(over {kname} {rng[0]:.2f}..{rng[1]:.2f}; + = we need more bits)')

    # ---------------- summary table
    print('\n\n' + '#' * W)
    print('# SUMMARY -- our lossy encoder vs cjxl -e%d (libjxl 0.12)' % prim)
    print('#' * W)
    print(f'{"image":<14}{"class":<21}{"BDrate":>9}{"BDrate":>9}'
          f'{"dPSNR":>7}{"dPSNR":>7}{"dPSNR":>7}{"dS2":>7}{"size":>8}{"enc x":>7}')
    print(f'{"":<14}{"":<21}{"PSNR":>9}{"S2":>9}'
          f'{"@low":>7}{"@mid":>7}{"@high":>7}{"@mid":>7}{"@eqQ":>8}{"slower":>7}')
    print('-' * W)

    agg = {'psnr': [], 's2': [], 'dlow': [], 'dmid': [], 'dhigh': [],
           's2mid': [], 'ratio': [], 'tx': []}
    by_class = {}
    for name, r in results.items():
        cls = r['class']
        if r['ours_err']:
            print(f'{name:<14}{cls:<21}  UNSUPPORTED -- our lossy encoder rejects this input')
            continue
        cjp = r['cjxl'].get(prim) or []
        if not cjp:
            print(f'{name:<14}{cls:<21}   cjxl failed')
            continue
        bp, _ = bd_rate(r['ours'], cjp, 'psnr')
        bs, _ = bd_rate(r['ours'], cjp, 's2') if perceptual else (None, None)
        dmap = dict((id(p), v) for p, v in equal_size_delta(r['ours'], cjp, 'psnr'))
        s2map = dict((id(p), v) for p, v in equal_size_delta(r['ours'], cjp, 's2')) if perceptual else {}
        rmap = dict((id(p), v) for p, v in equal_quality_ratio(r['ours'], cjp, 'psnr'))
        # Rate regions: lowest / middle / highest of OUR sweep points that
        # actually land inside cjxl's measured range (no extrapolation).
        valid = [p for p in r['ours'] if dmap.get(id(p)) is not None]
        low = valid[0] if valid else None
        mid = valid[len(valid) // 2] if valid else None
        high = valid[-1] if valid else None
        dlow = dmap.get(id(low)) if low else None
        dmid = dmap.get(id(mid)) if mid else None
        dhigh = dmap.get(id(high)) if high else None
        s2mid = s2map.get(id(mid)) if mid else None
        rmid = rmap.get(id(mid)) if mid else None
        # Encode-time ratio: median of ours over median of cjxl across the sweep.
        ot = sorted(p['enc_s'] for p in r['ours'])[len(r['ours']) // 2]
        ct = sorted(p['enc_s'] for p in cjp)[len(cjp) // 2]
        tx = ot / ct if ct > 0 else None
        print(f'{name:<14}{cls:<21}{fmt(bp, "{:+.1f}%"):>9}{fmt(bs, "{:+.1f}%"):>9}'
              f'{fmt(dlow, "{:+.2f}"):>7}{fmt(dmid, "{:+.2f}"):>7}{fmt(dhigh, "{:+.2f}"):>7}'
              f'{fmt(s2mid, "{:+.1f}"):>7}'
              f'{("--" if rmid is None else f"{rmid:.2f}x"):>8}'
              f'{("--" if tx is None else f"{tx:.2f}x"):>7}')
        for k, v in (('psnr', bp), ('s2', bs), ('dlow', dlow), ('dmid', dmid),
                     ('dhigh', dhigh), ('s2mid', s2mid), ('ratio', rmid), ('tx', tx)):
            if v is not None:
                agg[k].append(v)
        by_class.setdefault(cls, []).append((bp, dmid, s2mid))

    def stat(xs):
        if not xs:
            return '--'
        xs = sorted(xs)
        n = len(xs)
        med = xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])
        return f'mean {sum(xs)/n:+.1f}  median {med:+.1f}'

    print('-' * W)
    print(f'AGGREGATE over {len(agg["psnr"])} measurable images')
    print(f'  BD-rate PSNR        : {stat(agg["psnr"])} %  (+ = we need more bits)')
    if perceptual:
        print(f'  BD-rate SSIMULACRA2 : {stat(agg["s2"])} %')
    print(f'  equal-size dPSNR low : {stat(agg["dlow"])} dB')
    print(f'  equal-size dPSNR mid : {stat(agg["dmid"])} dB')
    print(f'  equal-size dPSNR high: {stat(agg["dhigh"])} dB')
    if perceptual:
        print(f'  equal-size dS2 @mid : {stat(agg["s2mid"])} points')
    if agg['ratio']:
        rs = sorted(agg['ratio'])
        n = len(rs)
        med = rs[n // 2] if n % 2 else 0.5 * (rs[n // 2 - 1] + rs[n // 2])
        print(f'  equal-PSNR size     : mean {sum(rs)/n:.2f}x  median {med:.2f}x cjxl bytes')
    if agg['tx']:
        ts = sorted(agg['tx'])
        n = len(ts)
        med = ts[n // 2] if n % 2 else 0.5 * (ts[n // 2 - 1] + ts[n // 2])
        print(f'  encode wall time    : mean {sum(ts)/n:.2f}x  median {med:.2f}x cjxl -e{prim}')

    print(f'\nBY CONTENT CLASS (BD-rate PSNR, + = we need more bits):')
    for cls in sorted(by_class):
        vals = [b for b, _, _ in by_class[cls] if b is not None]
        dm = [d for _, d, _ in by_class[cls] if d is not None]
        s2 = [s for _, _, s in by_class[cls] if s is not None]
        if not vals:
            continue
        print(f'  {cls:<22} BD-rate {sum(vals)/len(vals):+8.1f} %   '
              f'dPSNR@mid {("--" if not dm else f"{sum(dm)/len(dm):+.2f}")} dB   '
              f'dS2@mid {("--" if not s2 else f"{sum(s2)/len(s2):+.1f}")}')

    # Secondary efforts: pure speed/quality context.
    for e in efforts[1:]:
        rows = []
        for name, r in results.items():
            if r['ours_err']:
                continue
            c = r['cjxl'].get(e) or []
            if not c:
                continue
            bp, _ = bd_rate(r['ours'], c, 'psnr')
            ot = sorted(p['enc_s'] for p in r['ours'])[len(r['ours']) // 2]
            ct = sorted(p['enc_s'] for p in c)[len(c) // 2]
            rows.append((name, bp, ot / ct if ct else None))
        if not rows:
            continue
        vals = [b for _, b, _ in rows if b is not None]
        txs = [t for _, _, t in rows if t is not None]
        print(f'\nvs cjxl -e{e} (fast preset), {len(rows)} images:')
        for name, bp, tx in rows:
            print(f'  {name:<14} BD-rate {fmt(bp, "{:+.1f}%"):>9}   '
                  f'enc {("--" if tx is None else f"{tx:.2f}x")} its time')
        if vals:
            print(f'  mean BD-rate {sum(vals)/len(vals):+.1f} %'
                  + (f'   mean enc {sum(txs)/len(txs):.2f}x' if txs else ''))

    print('\nNotes: dPSNR/dS2 are OURS minus cjxl at OUR file size (negative = we are '
          'worse).\n"size@eqQ" is our bytes / cjxl bytes at equal PSNR (>1 = we are '
          'bigger). "--"\nmeans the query fell outside cjxl\'s measured curve and was '
          'refused rather than\nextrapolated. PSNR flatters us: cjxl targets butteraugli, '
          'so trust dS2/BD-rate S2.')


if __name__ == '__main__':
    main()
