#!/usr/bin/env python3
"""RD-calibration sweep driver.

Measures OUR encoder against ITSELF across (JXL_RD_LAMBDA, JXL_RD_NZBITS,
JXL_FILTERS) settings, and optionally against cjxl -e7, reusing the metric and
BD-rate machinery from Scripts/cjxl_compare.py.

Results are cached per (image, config, q) in a JSON file so the sweep is
resumable and configs can be added incrementally.
"""
import os
import sys
import json
import math
import argparse
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import cjxl_compare as CC  # noqa: E402  (bd_rate, _clean, interp, metrics)

JXL = os.path.join(ROOT, '.build', 'manual', 'jxl')
CORPUS = os.path.join(ROOT, '.build', 'cjxl-corpus')

# Every run of OUR encoder pins these, so the lossy path is measured in
# isolation: the lossless-dominance race would otherwise replace the lossy
# bitstream on synthetic content and hide the RD behaviour we are calibrating.
BASE_ENV = {'JXL_LOSSLESS_RACE': '0', 'JXL_FILTER_RACE': '0'}


def load(path):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save(path, d):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(d, f)
    os.replace(tmp, path)


def run_point(kind, env, src, q, tmp):
    """Encode+decode+measure one operating point. Returns dict or None."""
    jxlf = os.path.join(tmp, 'p.jxl')
    pfm = os.path.join(tmp, 'p.pfm')
    for f in (jxlf, pfm):
        if os.path.exists(f):
            os.remove(f)
    e = dict(os.environ)
    if kind == 'ours':
        e.update(BASE_ENV)
        e.update(env)
        p = subprocess.run([JXL, 'encode', src, jxlf, f'q{q}'],
                           capture_output=True, env=e)
        if p.returncode != 0:
            return {'err': p.stderr.decode('utf-8', 'replace').strip()[:200]}
        p = subprocess.run([JXL, 'decode', jxlf, pfm, 'float'], capture_output=True)
        if p.returncode != 0:
            return {'err': 'decode: ' + p.stderr.decode('utf-8', 'replace').strip()[:160]}
    else:
        p = subprocess.run(['cjxl', '-d', str(q), '-e', env.get('effort', '7'),
                            '--quiet', src, jxlf], capture_output=True)
        if p.returncode != 0:
            return {'err': p.stderr.decode('utf-8', 'replace').strip()[:200]}
        p = subprocess.run(['djxl', '--quiet', jxlf, pfm], capture_output=True)
        if p.returncode != 0:
            return {'err': 'djxl: ' + p.stderr.decode('utf-8', 'replace').strip()[:160]}
    out = {'size': os.path.getsize(jxlf),
           'psnr': CC.metric_psnr(src, pfm),
           's2': CC.metric_s2(src, pfm)}
    os.remove(pfm)
    os.remove(jxlf)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', required=True)
    ap.add_argument('--plan', required=True, help='JSON file: list of jobs')
    ap.add_argument('--tmp', required=True)
    args = ap.parse_args()

    os.makedirs(args.tmp, exist_ok=True)
    cache = load(args.cache)
    plan = json.load(open(args.plan))

    todo = []
    for job in plan:
        for img in job['images']:
            for q in job['qs']:
                key = f"{img}|{job['name']}|{q}"
                if key not in cache:
                    todo.append((key, job, img, q))
    print(f'{len(todo)} points to measure ({len(cache)} cached)', flush=True)

    done = 0
    for key, job, img, q in todo:
        src = os.path.join(CORPUS, img)
        r = run_point(job.get('kind', 'ours'), job.get('env', {}), src, q, args.tmp)
        cache[key] = r
        done += 1
        if done % 25 == 0:
            save(args.cache, cache)
            print(f'  {done}/{len(todo)}', flush=True)
    save(args.cache, cache)
    print(f'done: {done} new points, {len(cache)} total', flush=True)


if __name__ == '__main__':
    main()
