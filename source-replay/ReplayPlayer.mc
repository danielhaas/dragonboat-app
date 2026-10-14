using Toybox.Lang;
using Toybox.Position;
using Toybox.StringUtil;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Simulator-only live replay of a recorded session (see make_replay_data.py
// and sim.jungle). Once per second it feeds one recorded second of |a|
// samples, speed, position and heart rate through the same model entry
// points the real sensor callbacks use, so stroke detection, pieces and
// the end-of-piece analyzer all run exactly as they would on the water.
//
// |a| is fed as x with y = z = 0: the model only uses the magnitude for
// detection and the analyzer buffer, so this is lossless for both.
class ReplayPlayer {
    const NO_SPEED = 0xFFFF;
    const NO_POS = 0x7FFFFFFF;

    var model;
    var timer;
    var sec;
    var chunk;      // hex strings for the loaded chunk (one per second)
    var chunkIdx;
    var ignoredLiveEvents = 0;  // simulator GPS/HR events dropped by the view
    var tailSec = 0;            // seconds since the data ended

    function initialize(m) {
        model = m;
        sec = 0;
        chunk = null;
        chunkIdx = -1;
    }

    // Only one CHUNK_SECONDS-long resource is held at a time; the whole
    // recording in memory pushes the app past the fenix 6 heap.
    function hexForSecond(s) {
        var idx = s / ReplayData.CHUNK_SECONDS;
        if (idx != chunkIdx) {
            chunk = null;
            chunk = WatchUi.loadResource(ReplayData.CHUNKS[idx]);
            chunkIdx = idx;
            var stats = System.getSystemStats();
            System.println("Replay " + s + "s mem " + stats.usedMemory + "/" +
                stats.totalMemory + " strokes=" + model.totalStrokes +
                " speed=" + model.currentSpeed.format("%.2f") +
                " dist=" + model.totalDistance.format("%.0f") +
                " ignoredLive=" + ignoredLiveEvents);
        }
        return chunk[s % ReplayData.CHUNK_SECONDS];
    }

    function start() {
        timer = new Timer.Timer();
        timer.start(method(:tick), 1000, true);
    }

    function isRunning() {
        return sec < ReplayData.NUM_SECONDS;
    }

    function getStatus() {
        if (isRunning()) {
            return "REPLAY " + sec + "/" + ReplayData.NUM_SECONDS + "s";
        }
        return "REPLAY DONE";
    }

    function tick() as Void {
        // After the data ends, keep redrawing once a second: in the
        // simulator nothing else drives onUpdate(), so the screen would
        // freeze and the piece-end timeout would never fire.
        if (sec >= ReplayData.NUM_SECONDS) {
            chunk = null;
            tailSec++;
            // By now the last piece has ended and its analysis finished.
            if (tailSec == 15) {
                logPieces();
            }
            WatchUi.requestUpdate();
            return;
        }

        var b = StringUtil.convertEncodedString(hexForSecond(sec), {
            :fromRepresentation => StringUtil.REPRESENTATION_STRING_HEX,
            :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY
        }) as Lang.ByteArray;
        sec++;

        var n = b[0];
        var hr = b[1];
        var speed = b.decodeNumber(Lang.NUMBER_FORMAT_UINT16,
            {:offset => 2, :endianness => Lang.ENDIAN_BIG});
        var lat = b.decodeNumber(Lang.NUMBER_FORMAT_SINT32,
            {:offset => 4, :endianness => Lang.ENDIAN_BIG});
        var lon = b.decodeNumber(Lang.NUMBER_FORMAT_SINT32,
            {:offset => 8, :endianness => Lang.ENDIAN_BIG});

        if (hr > 0) {
            model.heartRate = hr;
        }

        var accel = new ReplayAccelData(n);
        for (var i = 0; i < n; i++) {
            accel.x[i] = b.decodeNumber(Lang.NUMBER_FORMAT_UINT16,
                {:offset => 12 + i * 2, :endianness => Lang.ENDIAN_BIG});
        }
        model.updateAccelerometer(accel);

        var pos = new ReplayPositionInfo();
        if (speed != NO_SPEED) {
            pos.speed = speed / 100.0;
        }
        if (lat != NO_POS) {
            pos.position = new Position.Location({
                :latitude => lat,
                :longitude => lon,
                :format => :semicircles
            });
        }
        if (pos.speed != null || pos.position != null) {
            model.updatePosition(pos);
        }

        if (sec == ReplayData.NUM_SECONDS) {
            System.println("Replay finished: totalStrokes=" + model.totalStrokes +
                " pieces=" + model.pieces.size());
        }
        WatchUi.requestUpdate();
    }

    function logPieces() {
        for (var k = 0; k < model.pieces.size(); k++) {
            var p = model.pieces[k];
            System.println("Piece " + (k + 1) + ": live=" + p.strokeCount +
                " analyzed=" + p.analyzedStrokes +
                " shown=" + p.getBestStrokeCount());
        }
    }
}

// Duck-typed stand-in for Sensor.AccelerometerData.
class ReplayAccelData {
    var x;
    var y;
    var z;

    function initialize(n) {
        x = new [n];
        y = new [n];
        z = new [n];
        for (var i = 0; i < n; i++) {
            y[i] = 0;
            z[i] = 0;
        }
    }
}

// Duck-typed stand-in for Position.Info (model checks `has :speed`).
class ReplayPositionInfo {
    var speed;
    var position;

    function initialize() {
        speed = null;
        position = null;
    }
}
