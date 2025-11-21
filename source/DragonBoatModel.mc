using Toybox.System;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.ActivityRecording;

// Class to track a single piece
class Piece {
    var strokeCount;
    var distance;
    var maxSpeed;
    var startTime;
    var endTime;
    var duration; // in seconds

    // Historical data for graphs
    var speedHistory;      // Array of speed samples
    var strokeRateHistory; // Array of stroke rate samples
    var sampleTimes;       // Array of sample timestamps
    var lastSampleTime;    // Time of last sample
    const SAMPLE_INTERVAL = 5000; // 5 seconds between samples

    function initialize() {
        strokeCount = 0;
        distance = 0.0;
        maxSpeed = 0.0;
        startTime = System.getTimer();
        endTime = null;
        duration = 0;

        // Initialize history arrays
        speedHistory = [];
        strokeRateHistory = [];
        sampleTimes = [];
        lastSampleTime = startTime;
    }

    // Calculate duration when piece ends
    function finalize(lastStrokeTime) {
        endTime = lastStrokeTime;
        duration = (endTime - startTime) / 1000.0; // convert to seconds
    }

    // Get current duration (for active piece)
    function getCurrentDuration() {
        if (endTime != null) {
            return duration;
        } else {
            return (System.getTimer() - startTime) / 1000.0;
        }
    }

    // Record a sample for graphs
    function recordSample(speed, strokeRate) {
        var currentTime = System.getTimer();

        // Only record if enough time has passed since last sample
        if (currentTime - lastSampleTime >= SAMPLE_INTERVAL) {
            speedHistory.add(speed);
            strokeRateHistory.add(strokeRate);
            sampleTimes.add((currentTime - startTime) / 1000.0); // Relative time in seconds
            lastSampleTime = currentTime;
        }
    }
}

class DragonBoatModel {
    // Overall session data
    var totalDistance;
    var totalStrokes;
    var currentSpeed;
    var strokeRate; // strokes per minute
    var elapsedTime;
    var heartRate; // current heart rate in bpm

    // Current piece tracking
    var currentPiece;
    var pieces;
    var pieceActive; // Is there an active piece

    // Piece detection - based on strokes
    var lastPieceStrokeTime; // Time of last stroke in current piece
    const PIECE_END_DURATION = 10000; // 10 seconds in milliseconds

    // Stroke detection
    var lastAccelData;
    var strokeBuffer;
    var lastStrokeTime;
    const STROKE_COOLDOWN = 200; // milliseconds between strokes
    const ACCEL_THRESHOLD = 1.5; // g-force threshold for stroke detection

    // Activity session
    var session;
    var sessionStartTime;

    // Last position for distance calculation
    var lastPosition;

    function initialize() {
        totalDistance = 0.0;
        totalStrokes = 0;
        currentSpeed = 0.0;
        strokeRate = 0.0;
        elapsedTime = 0;
        heartRate = 0;

        pieces = [];
        currentPiece = null; // No piece until first stroke
        pieceActive = false;

        lastPieceStrokeTime = 0;

        lastAccelData = null;
        strokeBuffer = [];
        lastStrokeTime = 0;

        lastPosition = null;
        sessionStartTime = System.getTimer();

        // Start activity recording session
        session = ActivityRecording.createSession({
            :name => "Dragon Boat",
            :sport => ActivityRecording.SPORT_ROWING,
            :subSport => ActivityRecording.SUB_SPORT_GENERIC
        });
        session.start();
    }

    // Update with new position data
    function updatePosition(info) {
        if (info has :speed && info.speed != null) {
            currentSpeed = info.speed;
        }

        // Calculate distance if we have a previous position
        if (info has :position && info.position != null) {
            if (lastPosition != null) {
                var distance = calculateDistance(lastPosition, info.position);
                totalDistance += distance;
                if (currentPiece != null && pieceActive) {
                    currentPiece.distance += distance;
                }
            }
            lastPosition = info.position;
        }

        // Update piece max speed
        if (currentPiece != null && pieceActive && currentSpeed > currentPiece.maxSpeed) {
            currentPiece.maxSpeed = currentSpeed;
        }

        // Record sample for graphs
        if (currentPiece != null && pieceActive) {
            currentPiece.recordSample(currentSpeed, strokeRate);
        }

        // Check if piece should end (30s since last stroke)
        checkPieceEnd();
    }

    // Update with accelerometer data
    function updateAccelerometer(accelData) {
        if (accelData != null) {
            // AccelerometerData contains arrays of samples
            // Process each sample to detect strokes
            var xSamples = accelData.x;
            var ySamples = accelData.y;
            var zSamples = accelData.z;

            if (xSamples != null && ySamples != null && zSamples != null) {
                var numSamples = xSamples.size();
                for (var i = 0; i < numSamples; i++) {
                    detectStroke(xSamples[i], ySamples[i], zSamples[i]);
                }
            }
        }
    }

    // Detect strokes from accelerometer data (single sample)
    function detectStroke(x, y, z) {
        var currentTime = System.getTimer();

        // Cooldown check - don't detect strokes too frequently
        if (currentTime - lastStrokeTime < STROKE_COOLDOWN) {
            lastAccelData = [x, y, z];
            return;
        }

        if (lastAccelData != null) {
            // Calculate magnitude of acceleration change
            var dx = x - lastAccelData[0];
            var dy = y - lastAccelData[1];
            var dz = z - lastAccelData[2];

            // Convert from milli-g to g (1000 milli-g = 1g)
            var magnitude = Math.sqrt(dx*dx + dy*dy + dz*dz) / 1000.0;

            // If magnitude exceeds threshold, count as a stroke
            if (magnitude > ACCEL_THRESHOLD) {
                registerStroke();
                lastStrokeTime = currentTime;
            }
        }

        lastAccelData = [x, y, z];
    }

    // Register a stroke
    function registerStroke() {
        var currentTime = System.getTimer();

        totalStrokes++;

        // Start new piece if no active piece
        if (!pieceActive || currentPiece == null) {
            currentPiece = new Piece();
            pieceActive = true;
        }

        // Add stroke to current piece
        currentPiece.strokeCount++;
        lastPieceStrokeTime = currentTime;

        // Update stroke rate (strokes per minute)
        updateStrokeRate();
    }

    // Update stroke rate calculation
    function updateStrokeRate() {
        var currentTime = System.getTimer();
        strokeBuffer.add(currentTime);

        // Keep only strokes from last 10 seconds
        var cutoffTime = currentTime - 10000;
        var newBuffer = [];
        for (var i = 0; i < strokeBuffer.size(); i++) {
            if (strokeBuffer[i] > cutoffTime) {
                newBuffer.add(strokeBuffer[i]);
            }
        }
        strokeBuffer = newBuffer;

        // Calculate rate
        if (strokeBuffer.size() > 1) {
            var timeSpan = (currentTime - strokeBuffer[0]) / 1000.0; // seconds
            if (timeSpan > 0) {
                strokeRate = (strokeBuffer.size() / timeSpan) * 60.0; // per minute
            }
        }
    }

    // Check if piece should end (10 seconds since last stroke)
    function checkPieceEnd() {
        if (!pieceActive || currentPiece == null) {
            return;
        }

        var currentTime = System.getTimer();

        // Check if 10 seconds have passed since last stroke
        if (lastPieceStrokeTime > 0 && (currentTime - lastPieceStrokeTime >= PIECE_END_DURATION)) {
            // End the current piece
            endPiece();
        }
    }

    // End current piece
    function endPiece() {
        if (currentPiece != null && currentPiece.strokeCount > 0) {
            // Finalize the piece with the last stroke time
            currentPiece.finalize(lastPieceStrokeTime);
            pieces.add(currentPiece);
        }
        currentPiece = null;
        pieceActive = false;
        lastPieceStrokeTime = 0;
    }
    
    // Get the piece to display (current active piece or last completed piece)
    function getDisplayPiece() {
        if (currentPiece != null) {
            return currentPiece;
        } else if (pieces.size() > 0) {
            return pieces[pieces.size() - 1];
        }
        return null;
    }

    // Calculate distance between two positions using Haversine formula
    function calculateDistance(pos1, pos2) {
        var lat1 = pos1.toRadians()[0];
        var lon1 = pos1.toRadians()[1];
        var lat2 = pos2.toRadians()[0];
        var lon2 = pos2.toRadians()[1];

        var dLat = lat2 - lat1;
        var dLon = lon2 - lon1;

        var a = Math.sin(dLat/2) * Math.sin(dLat/2) +
                Math.cos(lat1) * Math.cos(lat2) *
                Math.sin(dLon/2) * Math.sin(dLon/2);
        var c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
        var R = 6371000; // Earth's radius in meters

        return R * c;
    }

    // Update elapsed time
    function updateElapsedTime() {
        elapsedTime = (System.getTimer() - sessionStartTime) / 1000; // seconds
        
        // Also check if piece should end (since this is called frequently)
        checkPieceEnd();
    }

    // Stop the session
    function stopSession() {
        if (session != null && session.isRecording()) {
            session.stop();
            session.save();
        }
    }

    // Discard the session
    function discardSession() {
        if (session != null && session.isRecording()) {
            session.stop();
            session.discard();
        }
    }
}
