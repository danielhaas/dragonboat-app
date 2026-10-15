using Toybox.Application;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;

// Self-test build only: how much paddling history can a session hold
// before the end-of-piece analysis of a maximum-length piece no longer
// fits in memory?
//
// Fills the app's real sample buffer to its 5-minute cap (looping the
// baked-in recording), then repeatedly
//   1. runs the real DragonBoatModel.startAnalyzerJob() path on it while
//      sampling used memory every tick (peak = worst point seen), and
//   2. adds HISTORY_STEP_MIN more minutes of per-piece graph history (one
//      speed and one stroke-rate entry per second, as Piece.recordSample
//      does),
// logging "MEMTEST ..." after each round until MAX_HISTORY_MIN or an
// Out Of Memory crash. The last line logged is the limit.
//
// Phase 1 ("session"): history arrives in PIECE_MIN-minute pieces that
//   go through the real archivePiece(), i.e. a long session of pieces.
//   Each new piece is archived before it is filled, as the last finished
//   piece it keeps its history, like in the app.
// Phase 2 ("piece"):   all history goes into two pieces at once, the
//   last finished one (archived) and the current one, i.e. the worst case
//   for long pieces. History is capped per piece (Piece.HISTORY_MAX), so
//   memory should level off.
(:selftest)
class MemoryStressTest {
    const TICK_MS = 50;
    const COPY_BYTES_PER_TICK = 1500;
    const HISTORY_STEP_MIN = 10;
    const PIECE_MIN = 2;
    const ADD_SAMPLES_PER_TICK = 200;
    const MAX_HISTORY_MIN = 240;

    var model;
    var recording;     // decoded recording bytes, looped into the buffer
    var timer;
    var state;         // 1 = fill buffer, 2 = analyzing, 3 = growing history
    var copyPos;
    var historyMin;
    var peakUsed;
    var piece;         // the 5-minute piece being analyzed
    var growPiece;     // history piece currently being filled
    var currentGrow;   // phase 2: the "current" piece, grown alongside
    var growLeft;      // samples still to add this round
    var phase;         // 1 = session of pieces, 2 = one long piece

    function initialize(recordingBytes) {
        recording = recordingBytes;
    }

    function start() {
        model = (Application.getApp() as DragonBoatApp).mainView.getModel();
        copyPos = 0;
        historyMin = 0;
        phase = 1;
        state = 1;
        var st = System.getSystemStats();
        System.println("MEMTEST start: used " + st.usedMemory + "/" + st.totalMemory +
            ", filling " + model.SAMPLE_BUFFER_MAX_SAMPLES + "-sample buffer");
        timer = new Timer.Timer();
        timer.start(method(:tick), TICK_MS, false);
    }

    function tick() as Void {
        if (state == 1) {
            fillSome();
        } else if (state == 2) {
            var used = System.getSystemStats().usedMemory;
            if (used > peakUsed) { peakUsed = used; }
            if (model.pieceAnalyzeJob == null) {
                var st = System.getSystemStats();
                System.println("MEMTEST " + (phase == 1 ? "session" : "piece") +
                    " history=" + historyMin + "min pieces=" +
                    model.pieceCount + " idle=" + st.usedMemory +
                    " analysisPeak=" + peakUsed + "/" + st.totalMemory +
                    " headroom=" + (st.totalMemory - peakUsed) +
                    " strokes=" + piece.analyzedStrokes);
                if (historyMin >= MAX_HISTORY_MIN) {
                    System.println("MEMTEST " + (phase == 1 ? "session" : "piece") +
                        " OK: no OOM up to " + historyMin + " min of history");
                    if (phase == 2) {
                        System.println("MEMTEST DONE");
                        return;
                    }
                    // Phase 2 starts from an empty session.
                    phase = 2;
                    historyMin = 0;
                    model.pieceCount = 0;
                    model.lastPiece = null;
                    growPiece = new Piece();
                    model.archivePiece(growPiece);
                    currentGrow = new Piece();
                    startAnalysis();
                    timer.start(method(:tick), TICK_MS, false);
                    return;
                }
                growLeft = HISTORY_STEP_MIN * 60;
                state = 3;
            }
        } else if (state == 3) {
            growSome();
        }
        timer.start(method(:tick), TICK_MS, false);
    }

    // Loop the recording into model.sampleBuffer, then start analysis.
    function fillSome() {
        var buf = model.sampleBuffer;
        var end = copyPos + COPY_BYTES_PER_TICK;
        if (end > buf.size()) { end = buf.size(); }
        var n = recording.size();
        while (copyPos < end) {
            buf[copyPos] = recording[copyPos % n];
            copyPos++;
        }
        if (copyPos >= buf.size()) {
            recording = null;
            model.numBufferedSamples = model.SAMPLE_BUFFER_MAX_SAMPLES;
            piece = new Piece();
            piece.strokeCount = 300;
            startAnalysis();
        }
    }

    function startAnalysis() {
        peakUsed = System.getSystemStats().usedMemory;
        model.startAnalyzerJob(piece);
        state = 2;
    }

    // Append history the way Piece.recordSample does: two Float entries
    // per second. Phase 1 splits it into PIECE_MIN-minute pieces archived
    // like endPiece() does; phase 2 keeps growing one piece.
    function growSome() {
        var budget = ADD_SAMPLES_PER_TICK;
        while (budget > 0 && growLeft > 0) {
            if (phase == 1 && (growPiece == null
                    || growPiece.speedHistory.size() >= PIECE_MIN * 60)) {
                growPiece = new Piece();
                model.archivePiece(growPiece);
            }
            addSample(growPiece);
            if (phase == 2) {
                addSample(currentGrow);
            }
            growLeft--;
            budget--;
        }
        if (growLeft == 0) {
            historyMin += HISTORY_STEP_MIN;
            startAnalysis();
        }
    }

    // One second of history, capped exactly like Piece.recordSample().
    function addSample(p) {
        var k = p.speedHistory.size();
        p.speedHistory.add(3.5 + (k % 7) * 0.1);
        p.strokeRateHistory.add(60.0 + (k % 5));
        if (p.speedHistory.size() >= p.HISTORY_MAX) {
            p.compactHistory();
        }
    }
}
