#!/usr/bin/env python3
"""
Regression test for the on-watch stroke analyzer.

Runs the Python mirror of AnalyzerJob (validate_mc_analyzer.py) over
every reference piece and matches its detections stroke by stroke
against a reference list of blade-load start times. Fails on any missed
or extra stroke.

A piece is one FIT lap. Samples carry their real time (record timestamp
+ k / 25 Hz), so gaps in the log (missing record batches) don't shift
later strokes. Within a lap the analyzer sees the remaining samples
back to back, as the watch buffer would.

Time convention: seconds since the first record minus 1.0 (= since the
first valid accel sample when, as usual, the first record has none).

Reference lists were built from smoothed-|a| load plateaus plus a wrist-
tilt reach check (gsim session, 2026-10-14) and agree with Garmin's own
lap total_cycles within the strokes lost in log gaps. The by-feel counts
Dan gave earlier are kept for comparison only.

To add a piece: put the FIT in data/, a reference file (one load-start
time per line, '#' comments allowed) in data/reference/, and a row below.

Usage:
  python3 test_analyzer_regression.py
"""
import math
import sys

import fitdecode

import validate_mc_analyzer as mc


APR12 = "data/recordings/2026-04-12-09-35-17.fit"
OCT11 = "data/2026-10-11-08-48-01.fit"
REF = "data/reference/"

PIECES = [
    # (label, fit_file, lap_number, reference_file, counted_by_feel,
    #  allowed_errors)
    #
    # allowed_errors is a ratchet: the stroke-level misses + extras the
    # analyzer has today (2026-10-14), so any regression fails. Known
    # residuals: the weak first stroke of each April lap is missed, one
    # post-piece movement is counted on laps 1, 4 and 10, and lap 10's
    # irregular start burst (872-885 s) is misaligned by ~1 stroke.
    # Lower these as the analyzer improves; never raise them silently.
    #
    # Lap 1: ~3 more strokes fall in accel log gaps (records missing at
    # 15 s and 45-46 s) and can't be observed; Garmin's total_cycles is 85.
    ("2026-04-12 lap 1",  APR12,  1, REF + "2026-04-12-09-35-17.lap1.strokes.txt",   78,  4),
    ("2026-04-12 lap 3",  APR12,  3, REF + "2026-04-12-09-35-17.lap3.strokes.txt",   11,  1),
    ("2026-04-12 lap 4",  APR12,  4, REF + "2026-04-12-09-35-17.lap4.strokes.txt",   22,  2),
    ("2026-04-12 lap 10", APR12, 10, REF + "2026-04-12-09-35-17.lap10.strokes.txt", 160, 10),
    ("2026-10-11 piece",  OCT11,  1, REF + "2026-10-11-08-48-01.strokes.txt",       132,  0),
]

# Reference times are load starts; detections sit on the load peak a
# little after, by a per-piece offset (-0.08 to -0.28 s on the reference
# pieces). Match one-to-one, closest first, after shifting detections by
# the piece's median offset, within MATCH_TOL_S.
MATCH_TOL_S = 0.45

TIME_ZERO_OFFSET_S = 1.0


def _f(frame, name):
    for field in frame.fields:
        if field.name == name:
            return field.value
    return None


def load_laps(path, cache={}):
    """{lap_number: (mag_mg list, time_s list)} for every lap."""
    if path in cache:
        return cache[path]
    records, laps = [], []
    with fitdecode.FitReader(path) as fit:
        for frame in fit:
            if not isinstance(frame, fitdecode.FitDataMessage):
                continue
            if frame.name == "lap":
                laps.append((_f(frame, "start_time"), _f(frame, "timestamp")))
            elif frame.name == "record":
                records.append(frame)
    t_first = _f(records[0], "timestamp")
    out = {k + 1: ([], []) for k in range(len(laps))}
    for frame in records:
        ts = _f(frame, "timestamp")
        lap = next((k + 1 for k, (s, e) in enumerate(laps) if s <= ts <= e),
                   None)
        ax, ay, az = _f(frame, "accel_x"), _f(frame, "accel_y"), _f(frame, "accel_z")
        if lap is None or ax is None or ay is None or az is None:
            continue
        n = _f(frame, "accel_n") or len(ax)
        if any(v is None for arr in (ax, ay, az) for v in arr[:n]):
            continue
        base = (ts - t_first).total_seconds() - TIME_ZERO_OFFSET_S
        mags, times = out[lap]
        for k in range(n):
            mags.append(int(round(math.sqrt(ax[k] ** 2 + ay[k] ** 2 + az[k] ** 2))))
            times.append(base + k / mc.SAMPLE_RATE)
    cache[path] = out
    return out


def load_reference(path):
    with open(path) as f:
        return [float(line) for line in f
                if line.strip() and not line.startswith("#")]


def median_offset(ref, det):
    """Median of (nearest reference − detection)."""
    offs = sorted(min((r - d for r in ref), key=abs) for d in det)
    return offs[len(offs) // 2] if offs else 0.0


def match(ref, det, offset):
    """Returns (missed reference times, extra detection times)."""
    pairs = sorted((abs(r - (d + offset)), ri, di)
                   for ri, r in enumerate(ref) for di, d in enumerate(det)
                   if abs(r - (d + offset)) <= MATCH_TOL_S)
    used_r, used_d = set(), set()
    for _, ri, di in pairs:
        if ri not in used_r and di not in used_d:
            used_r.add(ri)
            used_d.add(di)
    missed = [ref[i] for i in range(len(ref)) if i not in used_r]
    extra = [det[i] for i in range(len(det)) if i not in used_d]
    return missed, extra


def main():
    print(f"{'piece':<20} {'ref':>4} {'got':>4} {'miss':>5} {'extra':>6} "
          f"{'allowed':>8} {'offset':>7} {'(by feel)':>10}")
    print("─" * 72)
    failures = 0
    for label, path, lap, ref_path, by_feel, allowed in PIECES:
        mags, times = load_laps(path)[lap]
        res = mc.analyze(mags)
        det = [times[k] for k in res.get("stroke_idx", [])]
        ref = load_reference(ref_path)
        offset = median_offset(ref, det)
        missed, extra = match(ref, det, offset)
        ok = len(missed) + len(extra) <= allowed
        failures += not ok
        print(f"{label:<20} {len(ref):>4} {len(det):>4} {len(missed):>5} "
              f"{len(extra):>6} {allowed:>8} {offset:>+7.2f} {by_feel:>10}"
              f"  {'ok' if ok else 'FAIL'}")
        if missed:
            print(f"    missed: {[round(t, 2) for t in missed]}")
        if extra:
            print(f"    extra:  {[round(t, 2) for t in extra]}")
    print("─" * 72)
    print("PASS" if failures == 0 else f"{failures} piece(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
