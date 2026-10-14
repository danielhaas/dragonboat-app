using Toybox.Lang;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

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
    var buf;
    var partIdx;
    var bufPos;

    function initialize() {
    }

    // The blob is decoded across timer ticks too: copying all of it in
    // one call trips the watchdog.
    function start() {
        buf = new [AccelTestData.NUM_BYTES]b;
        partIdx = 0;
        bufPos = 0;
        timer = new Timer.Timer();
        timer.start(method(:decodeTick), 30, false);
    }

    function decodeTick() as Void {
        if (decodeSome()) {
            System.println("SELFTEST start: " + AccelTestData.NUM_SAMPLES
                + " samples, expect " + AccelTestData.EXPECTED_STROKES + " strokes");
            job = new AnalyzerJob(buf, AccelTestData.NUM_SAMPLES);
            buf = null;
            steps = 0;
            maxStepMs = 0;
            startMs = System.getTimer();
            timer.start(method(:tick), 30, false);
        } else {
            timer.start(method(:decodeTick), 30, false);
        }
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

    // Decodes one jsonData chunk per call into the preallocated buffer.
    // Only that chunk is on the heap meanwhile; growing the buffer with
    // addAll() or holding the whole blob leaves the analyzer too little
    // memory on a fenix 6. Returns true when the whole blob is decoded.
    function decodeSome() {
        var parts = WatchUi.loadResource(AccelTestData.CHUNKS[partIdx]) as Lang.Array;
        for (var k = 0; k < parts.size(); k++) {
            var bytes = StringUtil.convertEncodedString(parts[k], {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_HEX,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
            }) as Lang.ByteArray;
            for (var b = 0; b < bytes.size(); b++) {
                buf[bufPos] = bytes[b];
                bufPos++;
            }
        }
        partIdx++;
        return partIdx >= AccelTestData.CHUNKS.size();
    }
}
