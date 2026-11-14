#!/usr/bin/env python3
"""F0 error of an output against a reference, pitch-aware — the absolute protocol of
docs/PLAN_CONTEXT.md. Conventions match scripts/quality_gate.py (16 kHz pyin, frame 1024 /
hop 160, resolution 0.1, lag alignment 0..200 ms minimising median|err|).

Usage:
  venv/bin/python -I scripts/f0_vs_input.py --root . --wav OUT.wav --ref REF.wav --pitch 12 [--json OUT.json]

--ref = input speech for the absolute check (pitch = configured pitch);
--ref = another output with --pitch 0 for zero / inter-seed checks.
Needs the converter venv (librosa/scipy); PYIN_CACHE speeds up repeated runs.
"""
import argparse
import importlib.util
import json
import os

import numpy as np


def load_qg(root):
    p = os.path.join(root, 'scripts', 'quality_gate.py')
    spec = importlib.util.spec_from_file_location('quality_gate', p)
    qg = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qg)
    return qg


def compare(qg, wav, ref, pitch):
    x = qg.load(wav)
    r = qg.load(ref)
    ratio = 2 ** (pitch / 12.0)
    fi, vi = qg.pyin(r, qg.FMIN, qg.FMAX)
    fo, vo = qg.pyin(x, qg.FMIN * ratio, qg.FMAX * ratio)
    best = None
    for lag in range(0, 21):
        n = min(len(fi), len(fo) - lag)
        if n <= 0:
            continue
        k = vi[:n] & vo[lag:lag + n] & np.isfinite(fi[:n]) & np.isfinite(fo[lag:lag + n])
        if k.sum() < 20:
            continue
        e = 1200 * np.log2(fo[lag:lag + n][k] / (ratio * fi[:n][k]))
        c = float(np.median(np.abs(e)))
        if best is None or c < best[0]:
            best = (c, lag, e)
    if best is None:
        return dict(n=0, lag_ms=None)
    _, lag, e = best
    w = e - 1200 * np.round(e / 1200)
    ae = np.abs(e)
    return dict(n=int(len(e)), lag_ms=lag * 10,
                median_abs=float(np.median(ae)), mean_abs=float(ae.mean()),
                p95_abs=float(np.percentile(ae, 95)),
                gt50=float((ae > 50).mean()), gt100=float((ae > 100).mean()),
                octave=float((ae > 600).mean()),
                wrap_median=float(np.median(np.abs(w))), wrap_mae=float(np.abs(w).mean()),
                bias=float(np.median(e)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', required=True)
    p.add_argument('--wav', required=True)
    p.add_argument('--ref', required=True)
    p.add_argument('--pitch', type=float, default=12)
    p.add_argument('--json')
    o = p.parse_args()
    qg = load_qg(o.root)
    res = compare(qg, o.wav, o.ref, o.pitch)
    res['wav'] = o.wav
    res['ref'] = o.ref
    res['pitch'] = o.pitch
    if o.json:
        os.makedirs(os.path.dirname(o.json), exist_ok=True)
        json.dump(res, open(o.json, 'w'), indent=1)
    print(json.dumps({k: (round(v, 3) if isinstance(v, float) else v) for k, v in res.items()}))


if __name__ == '__main__':
    main()