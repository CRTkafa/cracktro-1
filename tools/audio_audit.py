"""Read-only PCM audit; emits JSON, never renders, plays, or rewrites audio.

Usage: python tools/audio_audit.py dump.wav [other.wav ...]
Requires numpy. Optional ffmpeg supplies EBU R128/true-peak measurements.
Row-boundary steps are diagnostics, not proof of audible clicks: chip waves
and intended drum transients also have large first differences.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import wave
from pathlib import Path

import numpy as np


def db(value):
    return float(20 * np.log10(max(float(value), 1e-12)))


def audit(path):
    path = Path(path).resolve()
    with wave.open(str(path), "rb") as wav:
        rate, channels, width, frames = (wav.getframerate(), wav.getnchannels(),
                                         wav.getsampwidth(), wav.getnframes())
        if width != 2 or channels != 2 or rate != 44100:
            raise ValueError("Expected 44100 Hz stereo 16-bit PCM")
        pcm = np.frombuffer(wav.readframes(frames), dtype="<i2").reshape(-1, 2)
    x = pcm.astype(np.float64) / 32768.0
    if not len(x):
        raise ValueError("Empty audio")
    step = np.max(np.abs(np.diff(x, axis=0)), axis=1)
    boundaries = np.arange(5000, len(x), 5000)
    row_steps = step[boundaries - 1]
    rms = float(np.sqrt(np.mean(x*x)))
    peak = float(np.max(np.abs(x)))
    result = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                  frames=frames, seconds=frames/rate, sample_peak_dbfs=db(peak),
                  rms_dbfs=db(rms), crest_db=db(peak)-db(rms),
                  dc_fs=x.mean(axis=0).tolist(),
                  clipped_samples=int(np.count_nonzero((pcm == -32768) | (pcm == 32767))),
                  last_sample=pcm[-1].tolist(),
                  stereo_correlation=float(np.corrcoef(x.T)[0, 1])
                  if np.all(np.std(x, axis=0) > 0) else None,
                  final_100ms_rms_dbfs=db(np.sqrt(np.mean(x[-4410:]**2))),
                  row_step_quantiles_fs=np.quantile(row_steps, [.5, .95, 1]).tolist()
                  if len(row_steps) else [],
                  all_step_quantiles_fs=np.quantile(step, [.5, .95, 1]).tolist()
                  if len(step) else [])
    result["worst_row_steps"] = [dict(order=int(boundaries[i]//160000),
        row=int(boundaries[i]//5000 % 32), step_fs=float(row_steps[i]))
        for i in np.argsort(row_steps)[-12:][::-1]]
    result["orders"] = [dict(order=i//160000,
        rms_dbfs=db(np.sqrt(np.mean(x[i:i+160000]**2))),
        peak_dbfs=db(np.max(np.abs(x[i:i+160000]))))
        for i in range(0,len(x),160000)]
    if shutil.which("ffmpeg"):
        proc = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-nostdin",
            "-i", str(path), "-af", "ebur128=peak=true:framelog=verbose",
            "-f", "null", "-"], capture_output=True, text=True, check=True)
        summary = proc.stderr.rsplit("Summary:", 1)[-1]
        for key, pattern in (("integrated_lufs", r"I:\s+(-?[\d.]+) LUFS"),
                             ("lra_lu", r"LRA:\s+([\d.]+) LU"),
                             ("true_peak_dbtp", r"Peak:\s+(-?[\d.]+) dBFS")):
            match = re.search(pattern, summary)
            if match:
                result[key] = float(match[1])
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", nargs="+", type=Path)
    args = parser.parse_args()
    print(json.dumps([audit(path) for path in args.wav], indent=2, allow_nan=False))
