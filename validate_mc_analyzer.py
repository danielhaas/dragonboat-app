#!/usr/bin/env python3
"""
Validate the Monkey C analyzer algorithm against saved FIT files before
flashing.

Mirrors AnalyzerJob in source/DragonBoatAnalyzer.mc exactly:
  pass 1/2: stream |a| (milli-g) through the slow/fast MA bandpass,
            keep only the load side (bp > 0) and square it; the active
            region is the longest run where the 2 s rolling mean stays
            above threshold (gaps < 5 s bridged), with mean(dyn) over
            it; its edges are then tightened to the single dyn samples
            above the threshold
  pass 3:   collect every strict local maximum of dyn between those
            edges (no height gate), and store a 2× decimated, meanDyn-
            centred copy of dyn over a 60 s window in the middle of the
            rolling-mean active region
  ACF:      autocorrelation of that window over lags 400 ms – 4 s gives
            the stroke cadence (with a half-lag harmonic check)
  NMS:      greedy non-max suppression by height at 0.6 × cadence
  load:     drop strokes with no blade load after them (|a| never rises
            well above 1 g within 0.48 s)

Usage:
  python3 validate_mc_analyzer.py data/<file>.fit
"""
import math
import sys

import fitdecode


SAMPLE_RATE = 25
SAMPLE_PERIOD_MS = 40
SLOW_WINDOW = 50
FAST_WINDOW = 3
TRIM_WINDOW = 50
TRIM_THRESHOLD_PCT = 0.20
NOISE_FLOOR = 0.005
MIN_LAG = 10
MAX_LAG = 100
SUPPRESSION_FRAC = 0.6
CLUSTER_GAP = 125
ACF_WINDOW = 1500
ACF_DECIMATE = 2
HARMONIC_FRAC = 0.8
EDGE_GAP = 50
EDGE_MARGIN = 2
LOAD_LOOK = 12
LOAD_MA_HALF = 2
LOAD_FRAC = 0.35


class SlidingSum:
    def __init__(self, window):
        self.window = window
        self.buf = [0.0] * window
        self.head = 0
        self.filled = 0
        self.sum = 0.0

    def push_and_mean(self, v):
        if self.filled >= self.window:
            self.sum -= self.buf[self.head]
        self.buf[self.head] = v
        self.sum += v
        self.head = (self.head + 1) % self.window
        if self.filled < self.window:
            self.filled += 1
        return self.sum / self.filled


def stream_dyn(raw_mg, i, slow, fast):
    mag_g = raw_mg[i] / 1000.0
    slow_mean = slow.push_and_mean(mag_g)
    hp = mag_g - slow_mean
    bp = fast.push_and_mean(hp)
    return bp * bp if bp > 0.0 else 0.0


def pass1_find_peak(raw_mg):
    slow = SlidingSum(SLOW_WINDOW)
    fast = SlidingSum(FAST_WINDOW)
    roll = SlidingSum(TRIM_WINDOW)
    peak = 0.0
    for i in range(len(raw_mg)):
        dyn = stream_dyn(raw_mg, i, slow, fast)
        rv = roll.push_and_mean(dyn)
        if rv > peak:
            peak = rv
    return peak


def pass2_trim_and_noise(raw_mg, threshold):
    slow = SlidingSum(SLOW_WINDOW)
    fast = SlidingSum(FAST_WINDOW)
    roll = SlidingSum(TRIM_WINDOW)
    # A cluster is a run of rolling-mean crossings with gaps of at most
    # CLUSTER_GAP; the longest one wins. Per cluster: first/last crossing,
    # sum(dyn) between them, and the hot-sample edges.
    first, last = -1, -1
    sum_since = 0.0
    sum_at_last = 0.0
    edge_start = -1
    edge_end = -1
    best = None   # (r0, r1, sum, edge_start, edge_end)
    # "Hot" = a single dyn sample above the threshold. hot_run_start is
    # where the current cluster of hot samples (gaps < EDGE_GAP) began.
    hot_run_start = -1
    last_hot = -EDGE_GAP - 1

    def close():
        nonlocal best
        if first != -1 and (best is None
                            or last + 1 - first > best[1] - best[0]):
            best = (first, last + 1, sum_at_last, edge_start, edge_end)

    for i in range(len(raw_mg)):
        dyn = stream_dyn(raw_mg, i, slow, fast)
        rv = roll.push_and_mean(dyn)
        if first != -1:
            sum_since += dyn
        if dyn >= threshold:
            if i - last_hot > EDGE_GAP:
                hot_run_start = i
            last_hot = i
        if rv >= threshold:
            if first == -1 or i - last > CLUSTER_GAP:
                close()
                first = i
                sum_since = dyn
                edge_start = hot_run_start
            last = i
            sum_at_last = sum_since
            edge_end = last_hot
    close()
    n = len(raw_mg)
    if best is None:
        return 0, n, 0, n, 0.0
    r0, r1, s, e0, e1 = best
    i0 = max(0, e0 - EDGE_MARGIN)
    i1 = min(n, e1 + 1 + EDGE_MARGIN)
    return i0, i1, r0, r1, s / (r1 - r0)


def acf_window(i0, i1):
    """[w0, w1) — at most ACF_WINDOW samples centred in [i0, i1)."""
    active = i1 - i0
    w = min(active, ACF_WINDOW)
    w0 = i0 + (active - w) // 2
    return w0, w0 + w


def pass3_peaks_and_window(raw_mg, i0, i1, r0, r1, mean_dyn):
    """Strict local maxima of dyn in [i0, i1) plus the decimated,
    centred ACF window taken from the rolling-mean region [r0, r1)."""
    slow = SlidingSum(SLOW_WINDOW)
    fast = SlidingSum(FAST_WINDOW)
    w0, w1 = acf_window(r0, r1)

    prev2 = 0.0
    prev1 = 0.0
    have = 0
    peak_idx = []
    peak_height = []
    dec = []
    pair_sum = 0.0
    pair_cnt = 0

    for i in range(max(i1, w1)):
        dyn = stream_dyn(raw_mg, i, slow, fast)
        if i0 <= i < i1:
            if have >= 2 and prev1 > prev2 and prev1 > dyn:
                peak_idx.append(i - 1)
                peak_height.append(prev1)
            prev2 = prev1
            prev1 = dyn
            have += 1

        if w0 <= i < w1:
            pair_sum += dyn
            pair_cnt += 1
            if pair_cnt == ACF_DECIMATE:
                dec.append(pair_sum / ACF_DECIMATE - mean_dyn)
                pair_sum = 0.0
                pair_cnt = 0

    return peak_idx, peak_height, dec


def estimate_cadence_acf(dec):
    """Cadence lag in full-rate samples from the decimated window."""
    n = len(dec)
    lo = MIN_LAG // ACF_DECIMATE
    hi = min(n - 1, MAX_LAG // ACF_DECIMATE)
    if hi < lo:
        return MIN_LAG
    corrs = []
    for lag in range(lo, hi + 1):
        c = 0.0
        for i in range(n - lag):
            c += dec[i] * dec[i + lag]
        corrs.append(c)

    best = 0
    for k in range(1, len(corrs)):
        if corrs[k] > corrs[best]:
            best = k
    best_lag = lo + best

    # Harmonic check: a strong peak near half the best lag is the true
    # fundamental (every other stroke emphasised).
    half = best_lag // 2
    if half >= lo:
        k_lo = max(0, half - lo - 2)
        k_hi = min(len(corrs), half - lo + 3)
        hk = k_lo
        for k in range(k_lo + 1, k_hi):
            if corrs[k] > corrs[hk]:
                hk = k
        if corrs[hk] >= corrs[best] * HARMONIC_FRAC:
            best_lag = lo + hk

    lag = best_lag * ACF_DECIMATE
    return min(MAX_LAG, max(MIN_LAG, lag))


def non_max_suppress(peak_idx, peak_height, min_interval):
    """Greedy NMS: tallest first (ties keep time order), reject any peak
    within min_interval of an accepted one. Returns accepted sample
    indices in time order."""
    order = sorted(range(len(peak_idx)), key=lambda k: -peak_height[k])
    taken = [False] * len(peak_idx)
    for p in order:
        idx = peak_idx[p]
        too_close = False
        j = p - 1
        while j >= 0 and idx - peak_idx[j] < min_interval:
            if taken[j]:
                too_close = True
                break
            j -= 1
        j = p + 1
        while not too_close and j < len(peak_idx) \
                and peak_idx[j] - idx < min_interval:
            if taken[j]:
                too_close = True
                break
            j += 1
        if not too_close:
            taken[p] = True
    return [peak_idx[k] for k in range(len(peak_idx)) if taken[k]]


def load_after(raw_mg, idx):
    """Peak 5-sample-MA |a| (g) in the LOAD_LOOK samples from idx."""
    n = len(raw_mg)
    best = 0.0
    for j in range(idx, min(n, idx + LOAD_LOOK)):
        lo = max(0, j - LOAD_MA_HALF)
        hi = min(n, j + LOAD_MA_HALF + 1)
        s = 0
        for k in range(lo, hi):
            s += raw_mg[k]
        v = s / (hi - lo) / 1000.0
        if v > best:
            best = v
    return best


def drop_unloaded(raw_mg, strokes):
    """Drop detections the blade never loads after (e.g. the exit dip
    after the last stroke). Threshold is relative to the mean load."""
    if not strokes:
        return strokes
    loads = [load_after(raw_mg, s) for s in strokes]
    mean_load = sum(loads) / len(loads)
    thr = 1.0 + LOAD_FRAC * (mean_load - 1.0)
    return [s for s, ld in zip(strokes, loads) if ld >= thr]


def analyze(raw_mg):
    n = len(raw_mg)
    if n < SAMPLE_RATE:
        return {"strokes": 0, "reason": "too_short"}

    peak_rolling = pass1_find_peak(raw_mg)
    if peak_rolling <= 0:
        return {"strokes": 0, "reason": "no_peak"}

    threshold = peak_rolling * TRIM_THRESHOLD_PCT
    i0, i1, r0, r1, mean_dyn = pass2_trim_and_noise(raw_mg, threshold)
    if r1 - r0 < SAMPLE_RATE:
        return {"strokes": 0, "reason": "active_too_short"}
    if mean_dyn < NOISE_FLOOR:
        return {"strokes": 0, "reason": "below_noise", "mean_dyn": mean_dyn,
                "i0": i0, "i1": i1}

    peak_idx, peak_height, dec = pass3_peaks_and_window(
        raw_mg, i0, i1, r0, r1, mean_dyn)
    if len(peak_idx) < 2:
        return {"strokes": 0, "reason": "no_peaks",
                "i0": i0, "i1": i1, "mean_dyn": mean_dyn}

    lag = estimate_cadence_acf(dec)
    suppression = max(5, int(lag * SUPPRESSION_FRAC))
    stroke_idx = drop_unloaded(
        raw_mg, non_max_suppress(peak_idx, peak_height, suppression))
    return {
        "strokes": len(stroke_idx),
        "stroke_idx": stroke_idx,
        "i0": i0, "i1": i1,
        "active_sec": (i1 - i0) / SAMPLE_RATE,
        "mean_dyn": mean_dyn,
        "cadence_ms": lag * SAMPLE_PERIOD_MS,
        "avg_spm": 60000.0 / (lag * SAMPLE_PERIOD_MS),
        "num_candidate_peaks": len(peak_idx),
    }


def extract_mag_series(fit_path):
    """Per-lap magnitude series in milli-g."""
    laps = []
    current = []
    with fitdecode.FitReader(fit_path) as fit:
        for frame in fit:
            if not isinstance(frame, fitdecode.FitDataMessage):
                continue
            if frame.name == "lap":
                if current:
                    laps.append(current)
                    current = []
                continue
            if frame.name != "record":
                continue
            ax = _f(frame, "accel_x")
            ay = _f(frame, "accel_y")
            az = _f(frame, "accel_z")
            an = _f(frame, "accel_n")
            if ax is None or ay is None or az is None:
                continue
            n = an if an is not None else len(ax)
            for i in range(n):
                if ax[i] is None or ay[i] is None or az[i] is None:
                    continue
                mag = math.sqrt(ax[i] ** 2 + ay[i] ** 2 + az[i] ** 2)
                current.append(int(round(mag)))
    if current:
        laps.append(current)
    return laps


def _f(frame, name):
    for field in frame.fields:
        if field.name == name:
            return field.value
    return None


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "data/2025-11-22-09-40-48.fit"
    print(f"== {path}")
    laps = extract_mag_series(path)
    print(f"{len(laps)} laps found")
    for li, lap in enumerate(laps):
        if len(lap) < 100:
            print(f"  lap {li+1}: {len(lap)} samples — SKIP (too short)")
            continue
        res = analyze(lap)
        n_samples = len(lap)
        duration_s = n_samples / SAMPLE_RATE
        print(f"  lap {li+1}: {n_samples:5d} samples ({duration_s:5.1f} s) "
              f"→ strokes={res.get('strokes')} "
              f"candidates={res.get('num_candidate_peaks','-'):>4} "
              f"cadence={res.get('cadence_ms','-'):>5}ms "
              f"spm={res.get('avg_spm',0):5.1f} "
              f"reason={res.get('reason','ok')}")
