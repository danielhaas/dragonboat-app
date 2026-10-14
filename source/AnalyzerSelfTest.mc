using Toybox.Lang;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Timer;

// Runs AnalyzerJob over the recording baked into AccelTestData (see
// extract_accel_blob.py) exactly the way DragonBoatModel does — chunked
// on a Timer — and prints the result next to the expected count. Also
// reports the slowest single step so the per-step budgets can be
// checked against the watchdog.
(:selftest)
class AnalyzerSelfTest {
    const CHUNK_SAMPLES = 150;   // same as DragonBoatModel.PIECE_CHUNK_SAMPLES

    var job;
    var timer;
    var steps;
    var maxStepMs;
    var startMs;

    function initialize() {
    }

    function start() {
        var buf = decodeBlob();
        System.println("SELFTEST start: " + AccelTestData.NUM_SAMPLES
            + " samples, expect " + AccelTestData.EXPECTED_STROKES + " strokes");
        job = new AnalyzerJob(buf, AccelTestData.NUM_SAMPLES);
        steps = 0;
        maxStepMs = 0;
        startMs = System.getTimer();
        timer = new Timer.Timer();
        timer.start(method(:tick), 30, false);
    }

    function tick() as Void {
        var t0 = System.getTimer();
        var done = job.step(CHUNK_SAMPLES);
        var dt = System.getTimer() - t0;
        if (dt > maxStepMs) { maxStepMs = dt; }
        steps++;
        if (!done) {
            timer.start(method(:tick), 30, false);
            return;
        }
        var r = job.getResult();
        var got = r[:strokes];
        var want = AccelTestData.EXPECTED_STROKES;
        System.println("SELFTEST " + (got == want ? "PASS" : "FAIL")
            + ": strokes=" + got + " expected=" + want
            + " cadenceMs=" + r[:cadenceMs]
            + " steps=" + steps
            + " maxStepMs=" + maxStepMs
            + " totalMs=" + (System.getTimer() - startMs));
    }

    function decodeBlob() {
        var out = new [0]b;
        var parts = AccelTestData.HEX_PARTS;
        for (var k = 0; k < parts.size(); k++) {
            out.addAll(StringUtil.convertEncodedString(parts[k], {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_HEX,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
            }));
        }
        return out;
    }
}
