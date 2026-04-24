using Toybox.System;
using Toybox.Math;
using Toybox.Lang;

// Streaming, multi-pass stroke-detection analyzer.
//
// Must finish within the Connect IQ watchdog budget (~1.5 s) because
// analyze() runs synchronously on the UI tick from endPiece().
//
// The raw buffer holds one big-endian unsigned int16 per sample,
// representing |a| in milli-g, sampled at 25 Hz.
//
// Each pass re-reads the raw buffer and recomputes the filter stream on
// the fly. This is cheap (~30 ops/sample) and avoids materializing any
// per-sample float arrays.
//
// Pipeline per sample:
//   raw_mg → mag_g (÷1000)
//          → high-pass: subtract slow MA (50-sample sliding sum)
//          → low-pass:  3-tap MA (3-sample sliding sum)
//          → square (rectify)
//          → dyn
//
// Pass 1: stream → dyn → 50-sample rolling-mean sliding sum → track
//         max(rolling_mean) as the trim peak.
// Pass 2: stream → dyn → rolling mean → record first/last index where
//         rolling >= 0.2 * peak → also accumulate sum(dyn) within the
//         active region for the noise-floor check.
// Pass 3: stream → dyn → restricted to active region [i0, i1].
//         Detect strict local maxima using a 3-sample window and collect
//         them, height-gated at 4 × meanDyn. No autocorrelation —
//         cadence is estimated from the median of peak intervals, which
//         is O(peaks log peaks) rather than O(N × numLags).
//
// After the passes: median of diff(peakIdx) gives cadence, then greedy
// non-max suppression on the peak list at 0.8 × cadence cycle.
class DragonBoatAnalyzer {

    // ── Tunable constants ───────────────────────────────────────────
    const SAMPLE_RATE       = 25;       // Hz
    const SAMPLE_PERIOD_MS  = 40;       // 1000 / SAMPLE_RATE

    // Bandpass: subtract slow MA, then smooth with fast MA.
    const SLOW_WINDOW       = 50;       // samples (~2 s)
    const FAST_WINDOW       = 3;        // samples (~120 ms)

    // Active region trimming: rolling 2 s mean must exceed 20% of peak.
    const TRIM_WINDOW       = 50;       // samples (2 s rolling)
    const TRIM_THRESHOLD_PCT = 0.20;

    // Noise floor on meanDyn (squared bandpassed signal). Calibrated from
    // real paddling data: active-region meanDyn runs ~0.02–0.10. Anything
    // under 0.005 is essentially a still watch — reject as non-paddling.
    const NOISE_FLOOR       = 0.005;

    // Cadence bounds (clamp median-of-diffs into a sane range).
    const MIN_LAG           = 10;       // samples (= 400 ms = 150 SPM)
    const MAX_LAG           = 100;      // samples (= 4 s = 15 SPM)

    // Non-max suppression: as a fraction of the cadence cycle.
    const SUPPRESSION_FRAC  = 0.8;

    // ── Entry point ─────────────────────────────────────────────────

    // `byteBuf` is a ByteArray containing `numSamples` packed unsigned
    // int16 values (big-endian), each = |a| in milli-g.
    function analyze(byteBuf, numSamples) {
        if (numSamples < SAMPLE_RATE) {
            return emptyResult();
        }

        // Pass 1: find peak of rolling-mean(dyn).
        var peakRolling = pass1FindPeak(byteBuf, numSamples);
        if (peakRolling <= 0.0) {
            return emptyResult();
        }

        // Pass 2: find active region [i0, i1] and noise-floor mean.
        var threshold = peakRolling * TRIM_THRESHOLD_PCT;
        var p2 = pass2TrimAndNoise(byteBuf, numSamples, threshold);
        var i0 = p2[0];
        var i1 = p2[1];
        var meanDyn = p2[2];
        var activeLen = i1 - i0;

        if (activeLen < SAMPLE_RATE) {
            return emptyResult();
        }
        if (meanDyn < NOISE_FLOOR) {
            return makeResult(0, i0, i1, 0, meanDyn);
        }

        // Pass 3: local-maxima (height-gated) over [i0, i1].
        // Height threshold = 4 × meanDyn rejects noise peaks cheaply so the
        // peak list stays bounded (a real 5-min piece has ~300 strokes;
        // real stroke peaks are typically 10–50 × meanDyn).
        var heightThreshold = meanDyn * 4.0;
        var p3 = pass3FindPeaks(byteBuf, numSamples, i0, i1, heightThreshold);
        var peakIdx = p3[:peakIdx];
        var peakHeight = p3[:peakHeight];

        if (peakIdx.size() == 0) {
            return makeResult(0, i0, i1, 0, meanDyn);
        }

        var cadenceLag = estimateCadenceFromPeaks(peakIdx);
        if (cadenceLag == null) {
            return makeResult(0, i0, i1, 0, meanDyn);
        }

        var suppression = (cadenceLag * SUPPRESSION_FRAC).toNumber();
        if (suppression < 5) { suppression = 5; }

        var accepted = nonMaxSuppress(peakIdx, peakHeight, suppression);
        return makeResult(accepted.size(), i0, i1, cadenceLag, meanDyn);
    }

    // ── Pass 1 ──────────────────────────────────────────────────────

    // Stream the buffer, compute the filtered/squared dyn signal sample
    // by sample, run a 50-sample sliding-sum rolling mean over dyn, and
    // return the maximum value of that rolling mean.
    function pass1FindPeak(byteBuf, n) {
        var slow = new SlidingSum(SLOW_WINDOW);
        var fast = new SlidingSum(FAST_WINDOW);
        var roll = new SlidingSum(TRIM_WINDOW);
        var peak = 0.0;

        for (var i = 0; i < n; i++) {
            var dyn = streamDyn(byteBuf, i, slow, fast);
            var rollVal = roll.pushAndMean(dyn);
            if (rollVal > peak) { peak = rollVal; }
        }
        return peak;
    }

    // ── Pass 2 ──────────────────────────────────────────────────────

    // Same stream, but track first/last index where rolling >= threshold,
    // and accumulate sum(dyn) for samples in [firstCross..lastCross].
    // Returns [i0, i1, meanDyn]. If nothing crosses, returns [0, n, 0.0].
    function pass2TrimAndNoise(byteBuf, n, threshold) {
        var slow = new SlidingSum(SLOW_WINDOW);
        var fast = new SlidingSum(FAST_WINDOW);
        var roll = new SlidingSum(TRIM_WINDOW);

        var first = -1;
        var last = -1;

        // We need sum(dyn) in [first, last], but we discover first/last
        // as we go. Trick: keep a running sum of dyn since `first`, and
        // a snapshot at `last+1` we update each time we see a crossing.
        var sumSinceFirst = 0.0;
        var sumAtLast = 0.0;

        for (var i = 0; i < n; i++) {
            var dyn = streamDyn(byteBuf, i, slow, fast);
            var rollVal = roll.pushAndMean(dyn);

            if (first != -1) {
                sumSinceFirst += dyn;
            }
            if (rollVal >= threshold) {
                if (first == -1) {
                    first = i;
                    sumSinceFirst = dyn;
                }
                last = i;
                sumAtLast = sumSinceFirst;
            }
        }

        if (first == -1) {
            return [0, n, 0.0];
        }
        var i0 = first;
        var i1 = last + 1;
        var len = i1 - i0;
        var meanDyn = (len > 0) ? (sumAtLast / len) : 0.0;
        return [i0, i1, meanDyn];
    }

    // ── Pass 3 ──────────────────────────────────────────────────────

    // Stream over the full buffer, processing samples in [i0, i1) to
    // collect strict local maxima (3-sample window) above the height
    // gate. A hard cap of 1000 peaks is a safety net — real pieces
    // produce ~300 after the 4×meanDyn gate.
    function pass3FindPeaks(byteBuf, n, i0, i1, heightThreshold) {
        var slow = new SlidingSum(SLOW_WINDOW);
        var fast = new SlidingSum(FAST_WINDOW);

        var prev2 = 0.0;
        var prev1 = 0.0;
        var have = 0;

        var peakIdx = [];
        var peakHeight = [];

        for (var i = 0; i < n; i++) {
            if (i >= i1) { break; }
            var dyn = streamDyn(byteBuf, i, slow, fast);
            if (i < i0) { continue; }

            if (peakIdx.size() < 1000
                    && have >= 2 && prev1 > prev2 && prev1 > dyn
                    && prev1 >= heightThreshold) {
                peakIdx.add(i - 1);
                peakHeight.add(prev1);
            }

            prev2 = prev1;
            prev1 = dyn;
            have++;
        }

        return {:peakIdx => peakIdx, :peakHeight => peakHeight};
    }

    // ── Per-sample stream pipeline ──────────────────────────────────

    // Read raw sample i, decode |a| in g, run it through the slow MA
    // (high-pass) and fast MA (low-pass) sliding sums, square, and
    // return the resulting dyn value.
    function streamDyn(byteBuf, i, slow, fast) {
        var off = i * 2;
        var hi = byteBuf[off];
        var lo = byteBuf[off + 1];
        var raw = (hi << 8) | lo;
        var magG = raw / 1000.0;

        var slowMean = slow.pushAndMean(magG);
        var hp = magG - slowMean;
        var bp = fast.pushAndMean(hp);
        return bp * bp;
    }

    // ── Cadence estimate from peak intervals ────────────────────────

    // Peaks are already in ascending order (collected in a left-to-right
    // stream). Take the median of consecutive gaps, then clamp into
    // [MIN_LAG, MAX_LAG]. Returns null if fewer than 2 peaks or the
    // clamped median is implausible.
    function estimateCadenceFromPeaks(peakIdx) {
        var n = peakIdx.size();
        if (n < 2) { return null; }

        var diffs = new [n - 1];
        for (var i = 0; i < n - 1; i++) {
            diffs[i] = peakIdx[i + 1] - peakIdx[i];
        }

        // Insertion sort (n-1 is small — bounded by the 1000-peak cap).
        for (var i = 1; i < diffs.size(); i++) {
            var key = diffs[i];
            var j = i - 1;
            while (j >= 0 && diffs[j] > key) {
                diffs[j + 1] = diffs[j];
                j -= 1;
            }
            diffs[j + 1] = key;
        }

        var median = diffs[diffs.size() / 2];
        if (median < MIN_LAG) { median = MIN_LAG; }
        if (median > MAX_LAG) { median = MAX_LAG; }
        return median;
    }

    // ── Non-max suppression (operates on the streaming peak list) ──

    function nonMaxSuppress(maxima, heights, minIntervalSamples) {
        var n = maxima.size();
        if (n == 0) { return []; }

        // Sort indices by height descending (insertion sort).
        var order = new [n];
        for (var i = 0; i < n; i++) { order[i] = i; }
        for (var i = 1; i < n; i++) {
            var key = order[i];
            var keyVal = heights[key];
            var j = i - 1;
            while (j >= 0 && heights[order[j]] < keyVal) {
                order[j + 1] = order[j];
                j -= 1;
            }
            order[j + 1] = key;
        }

        var acceptedIdx = [];
        for (var k = 0; k < n; k++) {
            var pi = order[k];
            var idx = maxima[pi];
            var tooClose = false;
            for (var a = 0; a < acceptedIdx.size(); a++) {
                var diff = idx - acceptedIdx[a];
                if (diff < 0) { diff = -diff; }
                if (diff < minIntervalSamples) {
                    tooClose = true;
                    break;
                }
            }
            if (!tooClose) {
                acceptedIdx.add(idx);
            }
        }
        return acceptedIdx;
    }

    // ── Result construction ─────────────────────────────────────────

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

    function makeResult(strokes, i0, i1, cadenceLag, meanDyn) {
        var startMs = i0 * SAMPLE_PERIOD_MS;
        var endMs = i1 * SAMPLE_PERIOD_MS;
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
            :meanDyn => meanDyn,
        };
    }

    function initialize() {
    }
}

// Chunked, resumable analyzer job. Each call to step(maxSamples) does
// up to that many samples worth of work across whichever pass is active,
// then yields. The caller drives stepping via Toybox.Timer so the
// Connect IQ watchdog never sees a single long execution.
//
// Constants are duplicated from DragonBoatAnalyzer to keep this class
// self-contained — Monkey C const access across classes is finicky.
class AnalyzerJob {
    // ── Constants (mirror DragonBoatAnalyzer) ───────────────────────
    const SAMPLE_RATE       = 25;
    const SAMPLE_PERIOD_MS  = 40;
    const SLOW_WINDOW       = 50;
    const FAST_WINDOW       = 3;
    const TRIM_WINDOW       = 50;
    const TRIM_THRESHOLD_PCT = 0.20;
    const NOISE_FLOOR       = 0.005;
    const MIN_LAG           = 10;
    const MAX_LAG           = 100;
    const SUPPRESSION_FRAC  = 0.8;
    const FINISH_CHUNK      = 30;   // outer sort/NMS iterations per step()

    // ── State machine ───────────────────────────────────────────────
    // 1 = PASS1, 2 = PASS2, 3 = PASS3,
    // 4 = FINISH_INIT (one-shot; builds diffs[], transitions to 6),
    // 6 = SORT_DIFFS (chunked insertion sort for cadence median),
    // 7 = NMS_SORT   (chunked insertion sort of order[] by height desc),
    // 8 = NMS_ACCEPT (chunked greedy accept),
    // 5 = DONE
    var state;
    var result;       // populated when state == 5

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

    // Pass 3
    var i0;
    var i1;
    var meanDyn;
    var heightThreshold;
    var prev2;
    var prev1;
    var have;
    var peakIdx;
    var peakHeight;

    // Finish (chunked)
    var diffs;          // cadence-diff array, sorted to find median
    var order;          // peak indices sorted by peakHeight desc
    var accepted;       // NMS-accepted peak positions
    var sortK;          // insertion-sort outer cursor
    var nmsK;           // NMS accept outer cursor
    var lag;            // median cadence in samples
    var minInterval;    // NMS min-interval (suppression)

    function initialize(buffer, numSamples) {
        buf = buffer;
        n = numSamples;
        result = null;

        if (n < SAMPLE_RATE) {
            result = emptyResult();
            state = 5;
            return;
        }

        slow = new SlidingSum(SLOW_WINDOW);
        fast = new SlidingSum(FAST_WINDOW);
        roll = new SlidingSum(TRIM_WINDOW);
        peak = 0.0;
        i = 0;
        state = 1;
    }

    function isDone() { return state == 5; }
    function getResult() { return result; }

    // Advance by up to `maxSamples` samples of work. Returns true when
    // the job has finished (result is available via getResult()).
    function step(maxSamples) {
        if (state == 1) {
            stepPass1(maxSamples);
        } else if (state == 2) {
            stepPass2(maxSamples);
        } else if (state == 3) {
            stepPass3(maxSamples);
        } else if (state == 4) {
            finishInit();
        } else if (state == 6) {
            stepSortDiffs(FINISH_CHUNK);
        } else if (state == 7) {
            stepNmsSort(FINISH_CHUNK);
        } else if (state == 8) {
            stepNmsAccept(FINISH_CHUNK);
        }
        return state == 5;
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
                result = emptyResult();
                state = 5;
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
            i = 0;
            state = 2;
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
            if (rollVal >= threshold) {
                if (first == -1) {
                    first = i;
                    sumSinceFirst = dyn;
                }
                last = i;
                sumAtLast = sumSinceFirst;
            }
            i++;
        }
        if (i >= n) {
            if (first == -1) {
                i0 = 0; i1 = n; meanDyn = 0.0;
            } else {
                i0 = first;
                i1 = last + 1;
                var len = i1 - i0;
                meanDyn = (len > 0) ? (sumAtLast / len) : 0.0;
            }
            var activeLen = i1 - i0;
            if (activeLen < SAMPLE_RATE) {
                result = emptyResult();
                state = 5;
                return;
            }
            if (meanDyn < NOISE_FLOOR) {
                result = makeResult(0, i0, i1, 0, meanDyn);
                state = 5;
                return;
            }
            heightThreshold = meanDyn * 4.0;
            slow = new SlidingSum(SLOW_WINDOW);
            fast = new SlidingSum(FAST_WINDOW);
            prev2 = 0.0;
            prev1 = 0.0;
            have = 0;
            peakIdx = [];
            peakHeight = [];
            i = 0;
            state = 3;
        }
    }

    // ── Pass 3: height-gated local maxima over [i0, i1) ─────────────
    function stepPass3(maxSamples) {
        var end = i + maxSamples;
        if (end > i1) { end = i1; }
        while (i < end) {
            var dyn = streamDyn(i);
            if (i >= i0) {
                if (peakIdx.size() < 1000
                        && have >= 2 && prev1 > prev2 && prev1 > dyn
                        && prev1 >= heightThreshold) {
                    peakIdx.add(i - 1);
                    peakHeight.add(prev1);
                }
                prev2 = prev1;
                prev1 = dyn;
                have++;
            }
            i++;
        }
        if (i >= i1) {
            state = 4;
        }
    }

    // ── Finish: chunked across states 4/6/7/8 to stay under watchdog ─
    function finishInit() {
        var m = peakIdx.size();
        if (m < 2) {
            result = makeResult(0, i0, i1, 0, meanDyn);
            state = 5;
            return;
        }
        diffs = new [m - 1];
        for (var k = 0; k < m - 1; k++) {
            diffs[k] = peakIdx[k + 1] - peakIdx[k];
        }
        sortK = 1;
        state = 6;
    }

    function stepSortDiffs(maxOuter) {
        var mLimit = diffs.size();
        var end = sortK + maxOuter;
        if (end > mLimit) { end = mLimit; }
        while (sortK < end) {
            var key = diffs[sortK];
            var j = sortK - 1;
            while (j >= 0 && diffs[j] > key) {
                diffs[j + 1] = diffs[j];
                j -= 1;
            }
            diffs[j + 1] = key;
            sortK++;
        }
        if (sortK >= mLimit) {
            var median = diffs[diffs.size() / 2];
            if (median < MIN_LAG) { median = MIN_LAG; }
            if (median > MAX_LAG) { median = MAX_LAG; }
            lag = median;
            var suppression = (lag * SUPPRESSION_FRAC).toNumber();
            if (suppression < 5) { suppression = 5; }
            minInterval = suppression;
            var m = peakIdx.size();
            order = new [m];
            for (var k = 0; k < m; k++) { order[k] = k; }
            sortK = 1;
            state = 7;
        }
    }

    function stepNmsSort(maxOuter) {
        var mLimit = order.size();
        if (mLimit < 2) {
            accepted = [];
            nmsK = 0;
            state = 8;
            return;
        }
        var end = sortK + maxOuter;
        if (end > mLimit) { end = mLimit; }
        while (sortK < end) {
            var key = order[sortK];
            var keyVal = peakHeight[key];
            var j = sortK - 1;
            while (j >= 0 && peakHeight[order[j]] < keyVal) {
                order[j + 1] = order[j];
                j -= 1;
            }
            order[j + 1] = key;
            sortK++;
        }
        if (sortK >= mLimit) {
            accepted = [];
            nmsK = 0;
            state = 8;
        }
    }

    function stepNmsAccept(maxOuter) {
        var mLimit = order.size();
        var end = nmsK + maxOuter;
        if (end > mLimit) { end = mLimit; }
        while (nmsK < end) {
            var pi = order[nmsK];
            var idx = peakIdx[pi];
            var tooClose = false;
            for (var a = 0; a < accepted.size(); a++) {
                var diff = idx - accepted[a];
                if (diff < 0) { diff = -diff; }
                if (diff < minInterval) {
                    tooClose = true;
                    break;
                }
            }
            if (!tooClose) { accepted.add(idx); }
            nmsK++;
        }
        if (nmsK >= mLimit) {
            result = makeResult(accepted.size(), i0, i1, lag, meanDyn);
            state = 5;
        }
    }

    // ── Helpers (mirror the free-function versions in DragonBoatAnalyzer) ──

    function streamDyn(idx) {
        var off = idx * 2;
        var hi = buf[off];
        var lo = buf[off + 1];
        var raw = (hi << 8) | lo;
        var magG = raw / 1000.0;
        var slowMean = slow.pushAndMean(magG);
        var hp = magG - slowMean;
        var bp = fast.pushAndMean(hp);
        return bp * bp;
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
