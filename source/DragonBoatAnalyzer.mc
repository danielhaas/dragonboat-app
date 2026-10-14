using Toybox.System;
using Toybox.Math;
using Toybox.Lang;

// Chunked, resumable end-of-piece stroke analyzer. Each call to
// step(maxSamples) does a bounded amount of work, then yields. The
// caller drives stepping via Toybox.Timer so the Connect IQ watchdog
// never sees a single long execution.
//
// The raw buffer holds one big-endian unsigned int16 per sample,
// representing |a| in milli-g, sampled at 25 Hz.
//
// Each streaming pass re-reads the raw buffer and recomputes the filter
// stream on the fly, which avoids materializing per-sample float arrays:
//   raw_mg → mag_g (÷1000)
//          → high-pass: subtract slow MA (50-sample sliding sum)
//          → low-pass:  3-tap MA (3-sample sliding sum)
//          → keep the load side only (bp > 0), square
//          → dyn
//
// Load side only: squaring the full bandpass makes both the reach dip
// and the blade load into peaks, and which one wins NMS flips from
// stroke to stroke — irregular intervals, merged strokes.
//
// Pass 1: track max of the 2 s rolling mean of dyn (trim peak).
// Pass 2: rolling-mean active region [r0, r1) = the longest run where
//         the 2 s rolling mean >= 0.2 × peak (dips under 5 s bridged),
//         plus meanDyn over it for the noise floor. Taking the longest
//         run keeps a stray movement long before or after the piece
//         from stretching the region. The rolling mean trails the
//         signal, so it switches on late (missing the first strokes of
//         a standing start) and off ~2 s late (picking up post-piece
//         noise). The stroke region [i0, i1) is therefore taken from
//         the single dyn samples above the same threshold: from the
//         start of the hot cluster that triggered r0 to the last hot
//         sample before r1.
// Pass 3: collect every strict local maximum of dyn in [i0, i1) — no
//         height gate — and store a 2× decimated, meanDyn-centred copy
//         of dyn over a 60 s window in the middle of [r0, r1).
// ACF:    autocorrelation of that window over lags 400 ms – 4 s gives
//         the stroke cadence. A height gate + median-of-gaps estimate
//         was tried first and undercounted badly: steady paddling has
//         stroke peaks only ~2 × meanDyn, so any fixed gate either drops
//         real strokes or lets sub-peaks set the cadence.
// Sort:   bottom-up merge sort of the peaks by height (descending).
// NMS:    greedy non-max suppression at 0.6 × cadence.
// Load:   drop survivors the blade never loads after: the 5-sample MA
//         of |a| must reach 1 g + 0.35 × (mean over survivors − 1 g)
//         within 0.48 s. Removes small post-piece movements.
//
// validate_mc_analyzer.py mirrors this exactly, and
// test_analyzer_regression.py checks it stroke by stroke against the
// reference pieces in data/reference/.
class AnalyzerJob {
    // ── Tunable constants ───────────────────────────────────────────
    const SAMPLE_RATE       = 25;       // Hz
    const SAMPLE_PERIOD_MS  = 40;       // 1000 / SAMPLE_RATE

    // Bandpass: subtract slow MA, then smooth with fast MA.
    const SLOW_WINDOW       = 50;       // samples (~2 s)
    const FAST_WINDOW       = 3;        // samples (~120 ms)

    // Active region trimming: rolling 2 s mean must exceed 20% of peak.
    const TRIM_WINDOW       = 50;       // samples (2 s rolling)
    const TRIM_THRESHOLD_PCT = 0.20;

    // Noise floor on meanDyn (squared bandpassed signal). Anything under
    // 0.005 is essentially a still watch — reject as non-paddling.
    const NOISE_FLOOR       = 0.005;

    // Cadence search range.
    const MIN_LAG           = 10;       // samples (= 400 ms = 150 SPM)
    const MAX_LAG           = 100;      // samples (= 4 s = 15 SPM)

    // Autocorrelation runs on at most ACF_WINDOW samples from the middle
    // of the active region, decimated by ACF_DECIMATE. This caps the
    // cost at ~34k multiply-adds regardless of piece length; on the
    // ground-truth pieces a 60 s window gives the same cadence as the
    // full piece.
    const ACF_WINDOW        = 1500;     // samples (60 s)
    const ACF_DECIMATE      = 2;
    // Promote the half lag if its correlation is this close to the best.
    const HARMONIC_FRAC     = 0.8;

    // Non-max suppression: as a fraction of the cadence cycle. 0.8 was
    // too wide for the faster cycles at a race start (~0.75 s vs a
    // 0.88 s median) and merged neighbouring strokes; 0.6 is the best
    // fit on the per-stroke reference pieces.
    const SUPPRESSION_FRAC  = 0.6;

    // Rolling-mean crossings less than this far apart belong to one
    // active-region candidate; the longest candidate wins.
    const CLUSTER_GAP       = 125;      // samples (5 s)

    // Stroke-region edges: hot dyn samples less than EDGE_GAP apart form
    // one cluster; widen the edges by EDGE_MARGIN so the first/last
    // peak still has a neighbour on each side.
    const EDGE_GAP          = 50;       // samples (2 s)
    const EDGE_MARGIN       = 2;

    // Load check after each stroke (see header).
    const LOAD_LOOK         = 12;       // samples (0.48 s)
    const LOAD_MA_HALF      = 2;        // 5-sample centred MA
    const LOAD_FRAC         = 0.35;

    // Per-step work budgets, as multiples of step()'s maxSamples. One
    // streamed sample costs roughly as much as 4 multiply-adds, 4 merge
    // writes, or 1 NMS candidate.
    const ACF_OPS_PER_SAMPLE  = 4;
    const SORT_OPS_PER_SAMPLE = 4;

    // ── State machine ───────────────────────────────────────────────
    const ST_PASS1 = 1;
    const ST_PASS2 = 2;
    const ST_PASS3 = 3;
    const ST_ACF   = 4;
    const ST_SORT  = 6;
    const ST_NMS   = 7;
    const ST_LOAD  = 8;
    const ST_DONE  = 5;

    var state;
    var result;       // populated when state == ST_DONE

    // Input
    var buf;
    var n;

    // Shared per-pass streaming filters (reinitialized at transitions)
    var slow;
    var fast;
    var roll;
    var i;            // index into buf for the active pass

    // Pass 1
    var peak;

    // Pass 2
    var threshold;
    var first;
    var last;
    var sumSinceFirst;
    var sumAtLast;
    var hotRunStart;  // start of the current cluster of hot dyn samples
    var lastHot;
    var edgeStart;
    var edgeEnd;
    var bestR0;       // longest rolling-mean cluster so far (-1 = none)
    var bestR1;
    var bestSum;
    var bestEdgeStart;
    var bestEdgeEnd;

    // Pass 3
    var i0;           // stroke region [i0, i1)
    var i1;
    var r0;           // rolling-mean active region [r0, r1)
    var r1;
    var meanDyn;
    var prev2;
    var prev1;
    var have;
    var peakIdx;      // preallocated; first peakCount entries valid
    var peakHeight;
    var peakCount;
    var w0;           // ACF window [w0, w1)
    var w1;
    var dec;          // decimated, centred dyn over the ACF window
    var decCount;
    var pairSum;
    var pairCount;

    // ACF
    var acfLo;
    var acfHi;
    var acfLag;
    var acfI;
    var acfSum;
    var corrs;
    var lag;          // cadence in samples
    var minInterval;  // NMS suppression window in samples

    // Merge sort (order[] = peak indices sorted by height desc)
    var order;
    var tmp;
    var sortWidth;
    var sortLeft;
    var sortMid;
    var sortRight;
    var sortA;
    var sortB;
    var sortK;
    var merging;

    // NMS
    var taken;        // ByteArray flag per peak (time order)
    var nmsK;
    var strokeCount;

    // Load check
    var loads;        // load per peak; only entries with taken[] set
    var loadK;        // cursor into peaks (time order)
    var loadSum;

    function initialize(buffer, numSamples) {
        buf = buffer;
        n = numSamples;
        result = null;

        if (n < SAMPLE_RATE) {
            result = emptyResult();
            state = ST_DONE;
            return;
        }

        slow = new SlidingSum(SLOW_WINDOW);
        fast = new SlidingSum(FAST_WINDOW);
        roll = new SlidingSum(TRIM_WINDOW);
        peak = 0.0;
        i = 0;
        state = ST_PASS1;
    }

    function isDone() { return state == ST_DONE; }
    function getResult() { return result; }

    // Advance by up to `maxSamples` samples of work. Returns true when
    // the job has finished (result is available via getResult()).
    function step(maxSamples) {
        if (state == ST_PASS1) {
            stepPass1(maxSamples);
        } else if (state == ST_PASS2) {
            stepPass2(maxSamples);
        } else if (state == ST_PASS3) {
            stepPass3(maxSamples);
        } else if (state == ST_ACF) {
            stepAcf(maxSamples * ACF_OPS_PER_SAMPLE);
        } else if (state == ST_SORT) {
            stepSort(maxSamples * SORT_OPS_PER_SAMPLE);
        } else if (state == ST_NMS) {
            stepNms(maxSamples);
        } else if (state == ST_LOAD) {
            stepLoad(maxSamples);
        }
        return state == ST_DONE;
    }

    // ── Pass 1: rolling-mean peak ───────────────────────────────────
    function stepPass1(maxSamples) {
        var end = i + maxSamples;
        if (end > n) { end = n; }
        while (i < end) {
            var dyn = streamDyn(i);
            var rollVal = roll.pushAndMean(dyn);
            if (rollVal > peak) { peak = rollVal; }
            i++;
        }
        if (i >= n) {
            if (peak <= 0.0) {
                finish(emptyResult());
                return;
            }
            threshold = peak * TRIM_THRESHOLD_PCT;
            slow = new SlidingSum(SLOW_WINDOW);
            fast = new SlidingSum(FAST_WINDOW);
            roll = new SlidingSum(TRIM_WINDOW);
            first = -1;
            last = -1;
            sumSinceFirst = 0.0;
            sumAtLast = 0.0;
            hotRunStart = -1;
            lastHot = -EDGE_GAP - 1;
            edgeStart = -1;
            edgeEnd = -1;
            bestR0 = -1;
            bestR1 = -1;
            bestSum = 0.0;
            bestEdgeStart = -1;
            bestEdgeEnd = -1;
            i = 0;
            state = ST_PASS2;
        }
    }

    // ── Pass 2: active region + mean(dyn) ───────────────────────────
    function stepPass2(maxSamples) {
        var end = i + maxSamples;
        if (end > n) { end = n; }
        while (i < end) {
            var dyn = streamDyn(i);
            var rollVal = roll.pushAndMean(dyn);
            if (first != -1) {
                sumSinceFirst += dyn;
            }
            if (dyn >= threshold) {
                if (i - lastHot > EDGE_GAP) {
                    hotRunStart = i;
                }
                lastHot = i;
            }
            if (rollVal >= threshold) {
                if (first == -1 || i - last > CLUSTER_GAP) {
                    closeCluster();
                    first = i;
                    sumSinceFirst = dyn;
                    edgeStart = hotRunStart;
                }
                last = i;
                sumAtLast = sumSinceFirst;
                edgeEnd = lastHot;
            }
            i++;
        }
        if (i >= n) {
            closeCluster();
            if (bestR0 == -1) {
                r0 = 0; r1 = n; meanDyn = 0.0;
                i0 = 0; i1 = n;
            } else {
                r0 = bestR0;
                r1 = bestR1;
                meanDyn = bestSum / (r1 - r0);
                // A rolling-mean crossing implies a hot sample inside the
                // window, so the edges are always set here.
                i0 = bestEdgeStart - EDGE_MARGIN;
                if (i0 < 0) { i0 = 0; }
                i1 = bestEdgeEnd + 1 + EDGE_MARGIN;
                if (i1 > n) { i1 = n; }
            }
            var activeLen = r1 - r0;
            if (activeLen < SAMPLE_RATE) {
                finish(emptyResult());
                return;
            }
            if (meanDyn < NOISE_FLOOR) {
                finish(makeResult(0, i0, i1, 0, meanDyn));
                return;
            }

            // A strict local maximum needs a lower sample on each side,
            // so there are at most (i1 - i0) / 2 of them.
            peakIdx = new [(i1 - i0) / 2 + 1];
            peakHeight = new [(i1 - i0) / 2 + 1];
            peakCount = 0;

            var w = (activeLen < ACF_WINDOW) ? activeLen : ACF_WINDOW;
            w0 = r0 + (activeLen - w) / 2;
            w1 = w0 + w;
            dec = new [w / ACF_DECIMATE];
            decCount = 0;
            pairSum = 0.0;
            pairCount = 0;

            slow = new SlidingSum(SLOW_WINDOW);
            fast = new SlidingSum(FAST_WINDOW);
            roll = null;
            prev2 = 0.0;
            prev1 = 0.0;
            have = 0;
            i = 0;
            state = ST_PASS3;
        }
    }

    // Keep the current rolling-mean cluster if it is the longest so far.
    function closeCluster() {
        if (first != -1 && (bestR0 == -1 || last + 1 - first > bestR1 - bestR0)) {
            bestR0 = first;
            bestR1 = last + 1;
            bestSum = sumAtLast;
            bestEdgeStart = edgeStart;
            bestEdgeEnd = edgeEnd;
        }
    }

    // ── Pass 3: local maxima in [i0, i1) + decimated ACF window ─────
    function stepPass3(maxSamples) {
        var stop = (i1 > w1) ? i1 : w1;
        var end = i + maxSamples;
        if (end > stop) { end = stop; }
        while (i < end) {
            var dyn = streamDyn(i);
            if (i >= i0 && i < i1) {
                if (have >= 2 && prev1 > prev2 && prev1 > dyn) {
                    peakIdx[peakCount] = i - 1;
                    peakHeight[peakCount] = prev1;
                    peakCount++;
                }
                prev2 = prev1;
                prev1 = dyn;
                have++;
            }
            if (i >= w0 && i < w1) {
                pairSum += dyn;
                pairCount++;
                if (pairCount == ACF_DECIMATE) {
                    dec[decCount] = pairSum / ACF_DECIMATE - meanDyn;
                    decCount++;
                    pairSum = 0.0;
                    pairCount = 0;
                }
            }
            i++;
        }
        if (i >= stop) {
            slow = null;
            fast = null;
            if (peakCount < 2) {
                finish(makeResult(0, i0, i1, 0, meanDyn));
                return;
            }
            acfLo = MIN_LAG / ACF_DECIMATE;
            acfHi = MAX_LAG / ACF_DECIMATE;
            if (acfHi > decCount - 1) { acfHi = decCount - 1; }
            if (acfHi < acfLo) {
                // Window too short for autocorrelation — fall back to the
                // fastest plausible cadence.
                startSort(MIN_LAG);
                return;
            }
            corrs = new [acfHi - acfLo + 1];
            acfLag = acfLo;
            acfI = 0;
            acfSum = 0.0;
            state = ST_ACF;
        }
    }

    // ── ACF: chunked autocorrelation over [acfLo, acfHi] ────────────
    function stepAcf(budget) {
        while (budget > 0) {
            if (acfLag > acfHi) {
                finishAcf();
                return;
            }
            var end = decCount - acfLag;
            var stop = acfI + budget;
            if (stop > end) { stop = end; }
            budget -= (stop - acfI);
            var s = acfSum;
            for (var k = acfI; k < stop; k++) {
                s += dec[k] * dec[k + acfLag];
            }
            acfI = stop;
            if (acfI >= end) {
                corrs[acfLag - acfLo] = s;
                acfLag++;
                acfI = 0;
                acfSum = 0.0;
            } else {
                acfSum = s;
            }
        }
    }

    function finishAcf() {
        var best = 0;
        for (var k = 1; k < corrs.size(); k++) {
            if (corrs[k] > corrs[best]) { best = k; }
        }
        var bestLag = acfLo + best;

        // Harmonic check: a strong peak near half the best lag is the
        // true fundamental (every other stroke emphasised).
        var half = bestLag / 2;
        if (half >= acfLo) {
            var kLo = half - acfLo - 2;
            if (kLo < 0) { kLo = 0; }
            var kHi = half - acfLo + 3;
            if (kHi > corrs.size()) { kHi = corrs.size(); }
            var hk = kLo;
            for (var k = kLo + 1; k < kHi; k++) {
                if (corrs[k] > corrs[hk]) { hk = k; }
            }
            if (corrs[hk] >= corrs[best] * HARMONIC_FRAC) {
                bestLag = acfLo + hk;
            }
        }

        var cadence = bestLag * ACF_DECIMATE;
        if (cadence < MIN_LAG) { cadence = MIN_LAG; }
        if (cadence > MAX_LAG) { cadence = MAX_LAG; }
        dec = null;
        corrs = null;
        startSort(cadence);
    }

    // ── Sort: chunked bottom-up merge sort of peaks by height desc ──
    function startSort(cadence) {
        lag = cadence;
        minInterval = (lag * SUPPRESSION_FRAC).toNumber();
        if (minInterval < 5) { minInterval = 5; }

        order = new [peakCount];
        for (var k = 0; k < peakCount; k++) { order[k] = k; }
        tmp = new [peakCount];
        sortWidth = 1;
        sortLeft = 0;
        merging = false;
        state = ST_SORT;
    }

    // Stable: on equal heights the earlier peak stays first.
    function stepSort(budget) {
        while (budget > 0) {
            if (!merging) {
                if (sortLeft >= peakCount) {
                    var t = order;
                    order = tmp;
                    tmp = t;
                    sortWidth *= 2;
                    sortLeft = 0;
                    if (sortWidth >= peakCount) {
                        tmp = null;
                        startNms();
                        return;
                    }
                }
                sortMid = sortLeft + sortWidth;
                if (sortMid > peakCount) { sortMid = peakCount; }
                sortRight = sortLeft + 2 * sortWidth;
                if (sortRight > peakCount) { sortRight = peakCount; }
                sortA = sortLeft;
                sortB = sortMid;
                sortK = sortLeft;
                merging = true;
            }
            while (budget > 0 && sortK < sortRight) {
                if (sortA < sortMid && (sortB >= sortRight
                        || peakHeight[order[sortA]] >= peakHeight[order[sortB]])) {
                    tmp[sortK] = order[sortA];
                    sortA++;
                } else {
                    tmp[sortK] = order[sortB];
                    sortB++;
                }
                sortK++;
                budget--;
            }
            if (sortK >= sortRight) {
                merging = false;
                sortLeft = sortRight;
            }
        }
    }

    // ── NMS: greedy accept, tallest first ───────────────────────────
    function startNms() {
        taken = new [peakCount]b;
        nmsK = 0;
        strokeCount = 0;
        state = ST_NMS;
    }

    // Peaks are in time order, so only neighbours within minInterval
    // in the peak list need checking against already-accepted ones.
    function stepNms(maxOuter) {
        var end = nmsK + maxOuter;
        if (end > peakCount) { end = peakCount; }
        while (nmsK < end) {
            var p = order[nmsK];
            var idx = peakIdx[p];
            var tooClose = false;
            var j = p - 1;
            while (j >= 0 && idx - peakIdx[j] < minInterval) {
                if (taken[j] != 0) { tooClose = true; break; }
                j--;
            }
            j = p + 1;
            while (!tooClose && j < peakCount && peakIdx[j] - idx < minInterval) {
                if (taken[j] != 0) { tooClose = true; break; }
                j++;
            }
            if (!tooClose) {
                taken[p] = 1;
                strokeCount++;
            }
            nmsK++;
        }
        if (nmsK >= peakCount) {
            loads = new [peakCount];
            loadK = 0;
            loadSum = 0.0;
            state = ST_LOAD;
        }
    }

    // ── Load: drop strokes the blade never loads after ──────────────
    function stepLoad(maxSamples) {
        var budget = maxSamples * ACF_OPS_PER_SAMPLE;
        var cost = LOAD_LOOK * (2 * LOAD_MA_HALF + 1);
        while (budget > 0 && loadK < peakCount) {
            if (taken[loadK] != 0) {
                var ld = loadAfter(peakIdx[loadK]);
                loads[loadK] = ld;
                loadSum += ld;
                budget -= cost;
            } else {
                budget--;
            }
            loadK++;
        }
        if (loadK >= peakCount) {
            // NMS always accepts the tallest peak, so strokeCount >= 1.
            var thr = 1.0 + LOAD_FRAC * (loadSum / strokeCount - 1.0);
            var kept = 0;
            for (var k = 0; k < peakCount; k++) {
                if (taken[k] != 0 && loads[k] >= thr) { kept++; }
            }
            finish(makeResult(kept, i0, i1, lag, meanDyn));
        }
    }

    // Peak of the 5-sample centred MA of |a| (in g) over the LOAD_LOOK
    // samples starting at idx.
    function loadAfter(idx) {
        var best = 0.0;
        var stop = idx + LOAD_LOOK;
        if (stop > n) { stop = n; }
        for (var j = idx; j < stop; j++) {
            var lo = j - LOAD_MA_HALF;
            if (lo < 0) { lo = 0; }
            var hi = j + LOAD_MA_HALF + 1;
            if (hi > n) { hi = n; }
            var s = 0;
            for (var k = lo; k < hi; k++) {
                s += (buf[k * 2] << 8) | buf[k * 2 + 1];
            }
            var v = s.toFloat() / (hi - lo) / 1000.0;
            if (v > best) { best = v; }
        }
        return best;
    }

    // ── Helpers ─────────────────────────────────────────────────────

    // Publish the result and drop the large working arrays.
    function finish(res) {
        result = res;
        buf = null;
        peakIdx = null;
        peakHeight = null;
        dec = null;
        order = null;
        tmp = null;
        taken = null;
        loads = null;
        state = ST_DONE;
    }

    // Read raw sample idx, decode |a| in g, run it through the slow MA
    // (high-pass) and fast MA (low-pass) sliding sums, keep the load
    // side (bp > 0), square, and return the resulting dyn value.
    function streamDyn(idx) {
        var off = idx * 2;
        var hi = buf[off];
        var lo = buf[off + 1];
        var raw = (hi << 8) | lo;
        var magG = raw / 1000.0;
        var slowMean = slow.pushAndMean(magG);
        var hp = magG - slowMean;
        var bp = fast.pushAndMean(hp);
        return (bp > 0.0) ? bp * bp : 0.0;
    }

    function emptyResult() {
        return {
            :strokes => 0,
            :activeStartMs => 0,
            :activeEndMs => 0,
            :activeDurationMs => 0,
            :avgSpm => 0.0,
            :cadenceMs => 0,
            :meanDyn => 0.0,
        };
    }

    function makeResult(strokes, i0arg, i1arg, cadenceLag, meanDynArg) {
        var startMs = i0arg * SAMPLE_PERIOD_MS;
        var endMs = i1arg * SAMPLE_PERIOD_MS;
        var durMs = endMs - startMs;
        var spm = 0.0;
        if (durMs > 0 && strokes > 1) {
            spm = ((strokes - 1).toFloat() / (durMs.toFloat() / 1000.0)) * 60.0;
        }
        var cadenceMs = (cadenceLag != null && cadenceLag > 0)
            ? cadenceLag * SAMPLE_PERIOD_MS : 0;
        return {
            :strokes => strokes,
            :activeStartMs => startMs,
            :activeEndMs => endMs,
            :activeDurationMs => durMs,
            :avgSpm => spm,
            :cadenceMs => cadenceMs,
            :meanDyn => meanDynArg,
        };
    }
}

// Fixed-size sliding-sum moving average. push a value, get the mean of
// the last `window` values back. Constant time per push, constant
// memory.
class SlidingSum {
    var buf;
    var window;
    var head;
    var filled;
    var sum;

    function initialize(w) {
        window = w;
        buf = new [w];
        for (var i = 0; i < w; i++) { buf[i] = 0.0; }
        head = 0;
        filled = 0;
        sum = 0.0;
    }

    function pushAndMean(v) {
        if (filled >= window) {
            sum -= buf[head];
        }
        buf[head] = v;
        sum += v;
        head = (head + 1) % window;
        if (filled < window) { filled++; }
        return sum / filled;
    }
}
