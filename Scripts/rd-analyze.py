#!/usr/bin/env python3
"""Full analysis of the RD-calibration sweep.

Two BD-rate variants are reported everywhere:
  full   -- the standard integral over the whole shared quality range, exactly
            as Scripts/cjxl_compare.py computes it.
  window -- the same integral clipped to a USEFUL quality window, anchored at
            SSIMULACRA2 >= 50 (see window_lo). Our q30 points land at SSIMULACRA2 -40 on some
            content, i.e. visibly destroyed; the full-range integral gives that
            garbage region the same weight per quality-unit as the region anyone
            would ship, which flatters whatever setting happens to be least bad
            there. The window is the honest read for "which default should we
            ship"; the full range is kept so the two can be compared.
"""
import os
import sys
import json
import math
import argparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import cjxl_compare as CC  # noqa: E402

IMGS = ['photo_bridge.ppm', 'photo_city.ppm', 'photo_ocean.ppm', 'photo_rocks.ppm',
        'photo_sky.ppm', 'grad_smooth.ppm', 'gray_city.pgm', 'synth_noise.ppm',
        'synth_text.ppm']
CLASS = {
    'photo_bridge.ppm': 'photo', 'photo_city.ppm': 'photo',
    'photo_ocean.ppm': 'photo', 'photo_rocks.ppm': 'photo',
    'photo_sky.ppm': 'smooth', 'grad_smooth.ppm': 'smooth',
    'gray_city.pgm': 'grayscale', 'synth_noise.ppm': 'noise',
    'synth_text.ppm': 'text',
}
CLASSES = ['photo', 'smooth', 'grayscale', 'noise', 'text']
SHORT = {i: i.rsplit('.', 1)[0] for i in IMGS}
WINDOW = {'psnr': 30.0, 's2': 50.0}

CACHE = None
REF = 'L0.10_N2.4_Foff'
_curve_memo = {}
_win_memo = {}


def curve(img, cfg):
    k = (img, cfg)
    if k in _curve_memo:
        return _curve_memo[k]
    pts = []
    pre = f'{img}|{cfg}|'
    for kk, v in CACHE.items():
        if kk.startswith(pre) and isinstance(v, dict) and 'err' not in v:
            pts.append({'label': kk.rsplit('|', 1)[1], 'size': v['size'],
                        'psnr': v.get('psnr'), 's2': v.get('s2')})
    _curve_memo[k] = pts
    return pts


def bd_rate_clip(ours, theirs, key, qlo=None, qhi=None):
    """CC.bd_rate with the integration interval clipped to [qlo, qhi]."""
    a = CC._clean(ours, key)
    b = CC._clean(theirs, key)
    if len(a) < 2 or len(b) < 2:
        return None, None
    a_by_q = sorted((v, ls) for ls, v in a)
    b_by_q = sorted((v, ls) for ls, v in b)
    lo = max(a_by_q[0][0], b_by_q[0][0])
    hi = min(a_by_q[-1][0], b_by_q[-1][0])
    if qlo is not None:
        lo = max(lo, qlo)
    if qhi is not None:
        hi = min(hi, qhi)
    if not (hi > lo):
        return None, None
    n = 200
    acc, prev, step = 0.0, None, (hi - lo) / n
    for i in range(n + 1):
        q = lo + i * step
        ra, rb = CC.interp(a_by_q, q), CC.interp(b_by_q, q)
        if ra is None or rb is None:
            continue
        d = ra - rb
        if prev is not None:
            acc += 0.5 * (prev + d) * step
        prev = d
    return (2.0 ** (acc / (hi - lo)) - 1.0) * 100.0, (lo, hi)


def window_lo(img, key):
    """Lower edge of the useful-quality window for this image and metric.

    Anchored at SSIMULACRA2 = 50 on the SHIPPED-DEFAULT curve -- one perceptual
    operating point, converted to that image's PSNR scale by reading the shipped
    curve's PSNR at the same file size. A fixed PSNR threshold cannot be used:
    synth_noise tops out at 24.8 dB while reaching SSIMULACRA2 90, so "PSNR >=
    30" would delete that image entirely rather than window it. Computed once
    from the reference config so every compared config is judged over the same
    interval."""
    k = (img, key)
    if k in _win_memo:
        return _win_memo[k]
    if key == 's2':
        _win_memo[k] = 50.0
        return 50.0
    ref = curve(img, REF)
    s2c = CC._clean(ref, 's2')        # (log2 size, s2), frontier
    pc = CC._clean(ref, 'psnr')
    lo = None
    if len(s2c) >= 2 and len(pc) >= 2:
        inv = sorted((v, ls) for ls, v in s2c)   # s2 -> log2 size
        ls = CC.interp(inv, 50.0)
        if ls is not None:
            lo = CC.interp(pc, ls)
    _win_memo[k] = lo
    return lo


def band_edge(img, key, s2_threshold):
    """Translate an SSIMULACRA2 band edge onto this image's metric scale, by
    reading the SHIPPED curve at the file size where it hits that S2."""
    if s2_threshold is None:
        return None
    if key == 's2':
        return s2_threshold
    ref = curve(img, REF)
    s2c, pc = CC._clean(ref, 's2'), CC._clean(ref, 'psnr')
    if len(s2c) < 2 or len(pc) < 2:
        return None
    ls = CC.interp(sorted((v, l) for l, v in s2c), s2_threshold)
    return None if ls is None else CC.interp(pc, ls)


def bd(img, cfg, ref, key, window=False):
    a, b = curve(img, cfg), curve(img, ref)
    if len(a) < 2 or len(b) < 2:
        return None
    return bd_rate_clip(a, b, key, window_lo(img, key) if window else None)[0]


def med(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


def f(v, spec='{:+7.2f}%', w=9):
    return ('--').rjust(w) if v is None else spec.format(v).rjust(w)


def per_image(cfgs, ref, key, window, title):
    print(f'\n{title}')
    print(f'  BD-rate {key}{" (window)" if window else " (full range)"} '
          f'vs {ref}.  NEGATIVE = better (fewer bits for equal quality).')
    hdr = f'{"config":<17}' + ''.join(f'{SHORT[i][:11]:>11}' for i in IMGS) + f'{"median":>10}'
    print(hdr)
    print('-' * len(hdr))
    for c in cfgs:
        vals = [bd(i, c, ref, key, window) for i in IMGS]
        print(f'{c:<17}' + ''.join(f(v, '{:+10.2f}%', 11) for v in vals)
              + f(med(vals), '{:+9.2f}%', 10))


def per_class(cfgs, ref, key, window, title):
    print(f'\n{title}')
    print(f'  median BD-rate {key}{" (window)" if window else " (full range)"} '
          f'within class vs {ref}.  NEGATIVE = better.')
    hdr = f'{"config":<17}' + ''.join(f'{c:>11}' for c in CLASSES) + f'{"all":>11}'
    print(hdr)
    print('-' * len(hdr))
    out = {}
    for c in cfgs:
        vals = {i: bd(i, c, ref, key, window) for i in IMGS}
        row = {cl: med([vals[i] for i in IMGS if CLASS[i] == cl]) for cl in CLASSES}
        row['all'] = med(list(vals.values()))
        out[c] = row
        print(f'{c:<17}' + ''.join(f(row[cl], '{:+10.2f}%', 11) for cl in CLASSES)
              + f(row['all'], '{:+10.2f}%', 11))
    return out


def eq_size(img, cfg, ref, key):
    """Metric delta cfg-minus-ref at each of cfg's file sizes."""
    a, b = curve(img, cfg), curve(img, ref)
    rows = []
    bb = CC._clean(b, key)
    for p in sorted(a, key=lambda p: p['size']):
        v = p.get(key)
        if v is None:
            continue
        got = CC.interp(bb, math.log2(p['size']))
        rows.append((p['label'], p['size'], v, None if got is None else v - got))
    return rows


def main():
    global CACHE
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', required=True)
    ap.add_argument('--mode', required=True)
    args = ap.parse_args()
    CACHE = json.load(open(args.cache))
    have = {k.split('|')[1] for k in CACHE}

    LAMS = ['0', '0.02', '0.05', '0.10', '0.20', '0.35', '0.50', '0.75', '1.0']
    NZ = ['1.2', '1.8', '2.4', '3.2', '4.5']
    LAMS_B = ['0.02', '0.05', '0.10', '0.15', '0.20', '0.30', '0.50']

    if args.mode == 'gab':
        print('=' * 120)
        print('STUDY 1 -- IS GABORISH MISPRICED?')
        print('=' * 120)
        for key in ('psnr', 's2'):
            for win in (False, True):
                print(f'\n### GABORISH vs FILTERS-OFF at the SAME lambda '
                      f'[{key}{", useful-quality window" if win else ", full range"}]')
                print('  Each column: BD-rate of JXL_FILTERS=gab against JXL_FILTERS=off '
                      'at that lambda.')
                print('  NEGATIVE = Gaborish wins at matched size.')
                hdr = f'{"lambda":<17}' + ''.join(f'{SHORT[i][:11]:>11}' for i in IMGS) + f'{"median":>10}'
                print(hdr)
                print('-' * len(hdr))
                for l in LAMS:
                    g, o = f'L{l}_N2.4_Fgab', f'L{l}_N2.4_Foff'
                    if g not in have or o not in have:
                        continue
                    vals = [bd(i, g, o, key, win) for i in IMGS]
                    print(f'{l:<17}' + ''.join(f(v, '{:+10.2f}%', 11) for v in vals)
                          + f(med(vals), '{:+9.2f}%', 10))
        cfgs = ([f'L{l}_N2.4_Foff' for l in LAMS] + [f'L{l}_N2.4_Fgab' for l in LAMS]
                + [c for c in ['L0.10_N2.4_Fon', 'L0.35_N2.4_Fon'] if c in have])
        cfgs = [c for c in cfgs if c in have]
        for key in ('psnr', 's2'):
            for win in (False, True):
                per_class(cfgs, REF, key, win,
                          f'### ABSOLUTE: every filter/lambda config vs the shipped default [{key}]')
        per_image(cfgs, REF, 'psnr', True, '### per image, PSNR, window')
        per_image(cfgs, REF, 's2', True, '### per image, SSIMULACRA2, window')

    elif args.mode == 'nz':
        print('=' * 120)
        print('STUDY 2/3 -- LAMBDA x NZBITS, FILTERS OFF')
        print('=' * 120)
        cfgs = [f'L{l}_N{n}_Foff' for l in LAMS_B for n in NZ]
        cfgs = [c for c in cfgs if c in have]
        for key in ('psnr', 's2'):
            for win in (False, True):
                per_class(cfgs, REF, key, win,
                          f'### lambda x nzbits vs shipped default [{key}]')
        per_image(cfgs, REF, 'psnr', True, '### per image, PSNR, window')
        per_image(cfgs, REF, 's2', True, '### per image, SSIMULACRA2, window')

    elif args.mode == 'best':
        # Per-image argmin over the whole measured config space.
        cfgs = sorted(c for c in have if c.startswith('L'))
        print('\n### Per-image best config (window BD-rate vs shipped default)')
        print(f'{"image":<14}{"class":<10}'
              f'{"best PSNR":<20}{"gain":>9}   {"best S2":<20}{"gain":>9}'
              f'   {"joint best":<20}{"psnr":>8}{"s2":>8}')
        print('-' * 128)
        for i in IMGS:
            bp = [(bd(i, c, REF, 'psnr', True), c) for c in cfgs]
            bs = [(bd(i, c, REF, 's2', True), c) for c in cfgs]
            bp = sorted((v, c) for v, c in bp if v is not None)
            bs = sorted((v, c) for v, c in bs if v is not None)
            pm = {c: v for v, c in bp}
            sm = {c: v for v, c in bs}
            joint = sorted(((max(pm[c], sm[c]), c) for c in pm if c in sm))
            jc = joint[0][1] if joint else None
            print(f'{SHORT[i]:<14}{CLASS[i]:<10}'
                  f'{bp[0][1]:<20}{bp[0][0]:+8.2f}%   {bs[0][1]:<20}{bs[0][0]:+8.2f}%'
                  f'   {str(jc):<20}{pm.get(jc, float("nan")):+7.2f}%{sm.get(jc, float("nan")):+7.2f}%')
        print('\n### Best SINGLE global config (worst-case-over-metrics, median over images)')
        rank = []
        for c in cfgs:
            vp = med([bd(i, c, REF, 'psnr', True) for i in IMGS])
            vs = med([bd(i, c, REF, 's2', True) for i in IMGS])
            if vp is None or vs is None:
                continue
            rank.append((max(vp, vs), vp, vs, c))
        rank.sort()
        print(f'{"config":<20}{"median psnr":>13}{"median s2":>12}{"worse-of":>11}')
        for w, vp, vs, c in rank[:20]:
            print(f'{c:<20}{vp:+12.2f}%{vs:+11.2f}%{w:+10.2f}%')
        print('  ... (worst 5)')
        for w, vp, vs, c in rank[-5:]:
            print(f'{c:<20}{vp:+12.2f}%{vs:+11.2f}%{w:+10.2f}%')

    elif args.mode == 'cjxl':
        want = [w for w in sys.stdin.read().split() if w in have]
        print('=' * 120)
        print('AGAINST THE EXTERNAL REFERENCE (cjxl -e7)')
        print('=' * 120)
        for key in ('psnr', 's2'):
            for win in (False, True):
                per_class(want, 'cjxl_e7', key, win,
                          f'### BD-rate vs cjxl -e7 [{key}]')
        per_image(want, 'cjxl_e7', 'psnr', True, '### vs cjxl -e7 per image, PSNR, window')
        per_image(want, 'cjxl_e7', 's2', True, '### vs cjxl -e7 per image, SSIMULACRA2, window')

    elif args.mode == 'eqsize':
        want = sys.stdin.read().split()
        for cfg in want:
            for i in IMGS:
                print(f'\n{SHORT[i]}  {cfg} vs {REF}  (delta at MATCHED SIZE)')
                print(f'  {"q":<5}{"bytes":>9}{"PSNR":>8}{"dPSNR":>8}{"S2":>8}{"dS2":>8}')
                pr = {r[0]: r for r in eq_size(i, cfg, REF, 'psnr')}
                sr = {r[0]: r for r in eq_size(i, cfg, REF, 's2')}
                for q in sorted(pr, key=lambda x: int(x)):
                    _, sz, v, d = pr[q]
                    s2 = sr.get(q)
                    print(f'  {q:<5}{sz:>9}{v:>8.2f}{f(d, "{:+.2f}", 8)}'
                          f'{(f"{s2[2]:.1f}" if s2 else "--"):>8}'
                          f'{f(s2[3] if s2 else None, "{:+.1f}", 8)}')

    elif args.mode == 'band':
        # BD-rate split into three quality bands, so a setting that helps at
        # low rate and hurts at high rate cannot hide inside one average.
        # Bands are anchored on the SHIPPED curve's SSIMULACRA2 (<50 / 50-75 /
        # >75) and mapped onto each image's PSNR scale at the same file sizes.
        want = [w for w in sys.stdin.read().split() if w in have]
        for key in ('psnr', 's2'):
            for bname, (blo, bhi) in (('LOW  (S2<50)', (None, 50.0)),
                                      ('MID  (S2 50-75)', (50.0, 75.0)),
                                      ('HIGH (S2>75)', (75.0, None))):
                print(f'\n### band {bname} [{key}] -- BD-rate vs shipped default '
                      f'(negative = better)')
                hdr = f'{"config":<17}' + ''.join(f'{SHORT[i][:11]:>11}' for i in IMGS) + f'{"median":>10}'
                print(hdr)
                print('-' * len(hdr))
                for c in want:
                    vals = []
                    for i in IMGS:
                        lo = band_edge(i, key, blo)
                        hi = band_edge(i, key, bhi)
                        a, b = curve(i, c), curve(i, REF)
                        vals.append(None if len(a) < 2 or len(b) < 2
                                    else bd_rate_clip(a, b, key, lo, hi)[0])
                    print(f'{c:<17}' + ''.join(f(v, '{:+10.2f}%', 11) for v in vals)
                          + f(med(vals), '{:+9.2f}%', 10))

    elif args.mode == 'owner':
        # Which config OWNS each part of the rate axis? Answers "is the best
        # lambda rate-dependent?" without any BD-rate integral in the way.
        want = [w for w in sys.stdin.read().split() if w in have]
        for key in ('psnr', 's2'):
            print(f'\n### Frontier ownership by rate [{key}] -- best config at each size')
            print(f'  {"image":<14}{"class":<10}' + ''.join(f'{f"{p}%":>22}'
                  for p in (5, 25, 50, 75, 95)))
            for i in IMGS:
                ref = CC._clean(curve(i, REF), key)
                if len(ref) < 2:
                    continue
                lo, hi = ref[0][0], ref[-1][0]
                cells = []
                for frac in (0.05, 0.25, 0.50, 0.75, 0.95):
                    x = lo + frac * (hi - lo)
                    best, bestv, refv = None, -1e18, CC.interp(ref, x)
                    for c in want:
                        cc = CC._clean(curve(i, c), key)
                        v = CC.interp(cc, x) if len(cc) >= 2 else None
                        if v is not None and v > bestv:
                            bestv, best = v, c
                    d = None if refv is None else bestv - refv
                    cells.append(f'{best}{"" if d is None else f" {d:+.2f}"}')
                print(f'  {SHORT[i]:<14}{CLASS[i]:<10}' + ''.join(f'{c:>22}' for c in cells))

    elif args.mode == 'oracle':
        # How much does a per-image (or per-class) lambda buy over the best
        # SINGLE global setting? This is the size of the content-adaptive prize.
        want = [w for w in sys.stdin.read().split() if w in have]
        for key in ('psnr', 's2'):
            rank = sorted((med([bd(i, c, REF, key, True) for i in IMGS]), c)
                          for c in want
                          if med([bd(i, c, REF, key, True) for i in IMGS]) is not None)
            gbest = rank[0]
            print(f'\n### [{key}] best single global config: {gbest[1]} '
                  f'({gbest[0]:+.2f}% median vs shipped)')
            per_img, per_cls = [], {}
            for i in IMGS:
                vals = sorted((bd(i, c, REF, key, True), c) for c in want
                              if bd(i, c, REF, key, True) is not None)
                per_img.append(vals[0][0])
                per_cls.setdefault(CLASS[i], []).append((i, vals[0]))
                gv = bd(i, gbest[1], REF, key, True)
                print(f'    {SHORT[i]:<14}{CLASS[i]:<10} oracle {vals[0][1]:<18}'
                      f'{vals[0][0]:+7.2f}%   global {gv:+7.2f}%   '
                      f'extra {(vals[0][0] - gv):+6.2f}pp')
            print(f'    per-image oracle median {med(per_img):+.2f}% vs '
                  f'global {gbest[0]:+.2f}%')
            # best single config per class
            for cl, items in per_cls.items():
                rk = sorted((med([bd(i, c, REF, key, True) for i, _ in items]), c)
                            for c in want
                            if med([bd(i, c, REF, key, True) for i, _ in items]) is not None)
                print(f'    class {cl:<10} best config {rk[0][1]:<18}{rk[0][0]:+7.2f}%'
                      f'   (global {gbest[1]} gives '
                      f'{med([bd(i, gbest[1], REF, key, True) for i, _ in items]):+.2f}%)')

    elif args.mode == 'coverage':
        cfgs = sorted(c for c in have if c.startswith('L'))
        print('config coverage (points present / expected 63):')
        for c in cfgs + ['cjxl_e7']:
            n = sum(1 for k in CACHE if k.split('|')[1] == c
                    and 'err' not in CACHE[k])
            e = sum(1 for k in CACHE if k.split('|')[1] == c and 'err' in CACHE[k])
            print(f'  {c:<20} ok={n:<4} err={e}')
        print('\nnarrowest window overlaps (frac of ref span used by the integral):')
        rows = []
        for c in cfgs:
            for i in IMGS:
                for key in ('psnr', 's2'):
                    a, b = curve(i, c), curve(i, REF)
                    if len(a) < 2 or len(b) < 2:
                        continue
                    wl = window_lo(i, key)
                    pct, rng = bd_rate_clip(a, b, key, wl)
                    bq = [v for _, v in CC._clean(b, key)]
                    span = max(bq) - min(wl if wl is not None else min(bq), max(bq))
                    if rng is None:
                        rows.append((0.0, c, SHORT[i], key))
                    elif span > 0:
                        rows.append(((rng[1] - rng[0]) / span, c, SHORT[i], key))
        rows.sort()
        for fr, c, i, key in rows[:15]:
            print(f'  {fr:5.2f}  {c:<18}{i:<14}{key}')


if __name__ == '__main__':
    main()
