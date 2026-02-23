using Toybox.System;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.ActivityRecording;
using Toybox.Activity;

// Class to track a single piece
class Piece {
    var strokeCount;
    var distance;
    var maxSpeed;
    var startTime;
    var endTime;
    var duration; // in seconds
    var startTimeMs; // Raw milliseconds for display precision
    var endTimeMs; // Raw milliseconds for display precision

    // Historical data for graphs
    var speedHistory;      // Array of speed samples
    var strokeRateHistory; // Array of stroke rate samples
    var sampleTimes;       // Array of sample timestamps
    var lastSampleTime;    // Time of last sample
    const SAMPLE_INTERVAL = 1000; // 1 second between samples

    // Heart rate tracking
    var maxHeartRate;       // Highest HR seen during piece
    var avgHeartRate;       // Running average HR
    var heartRateSum;       // Sum for computing average
    var heartRateSamples;   // Count for computing average

    // Start/Chug phase detection
    var startPhaseEndIndex; // Sample index where start phase ends (null until detected)
    var peakStrokeRate;     // Highest stroke rate seen so far during piece
    const PHASE_DROP_PERCENT = 25; // Stroke rate must drop 25% from peak to trigger transition

    function initialize() {
        strokeCount = 0;
        distance = 0.0;
        maxSpeed = 0.0;
        startTime = System.getTimer();
        startTimeMs = startTime; // Store raw ms
        endTime = null;
        endTimeMs = null;
        duration = 0;

        // Initialize history arrays
        speedHistory = [];
        strokeRateHistory = [];
        sampleTimes = [];
        lastSampleTime = startTime;

        // Heart rate tracking
        maxHeartRate = 0;
        avgHeartRate = 0;
        heartRateSum = 0;
        heartRateSamples = 0;

        // Phase detection
        startPhaseEndIndex = null;
        peakStrokeRate = 0.0;
    }

    // Calculate duration when piece ends
    function finalize(lastStrokeTime) {
        endTime = lastStrokeTime;
        endTimeMs = lastStrokeTime; // Store raw ms
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
    
    // Get duration in milliseconds for display
    function getDurationMs() {
        if (endTimeMs != null) {
            return endTimeMs - startTimeMs;
        } else {
            return System.getTimer() - startTimeMs;
        }
    }

    // Record a sample for graphs
    function recordSample(speed, strokeRate, heartRate) {
        var currentTime = System.getTimer();

        // Only record if enough time has passed since last sample
        if (currentTime - lastSampleTime >= SAMPLE_INTERVAL) {
            speedHistory.add(speed);
            strokeRateHistory.add(strokeRate);
            sampleTimes.add((currentTime - startTime) / 1000.0); // Relative time in seconds
            lastSampleTime = currentTime;

            // Heart rate tracking
            if (heartRate > maxHeartRate) {
                maxHeartRate = heartRate;
            }
            if (heartRate > 0) {
                heartRateSum += heartRate;
                heartRateSamples++;
                avgHeartRate = heartRateSum / heartRateSamples;
            }

            // Phase detection: track peak stroke rate
            if (strokeRate > peakStrokeRate) {
                peakStrokeRate = strokeRate;
            }

            // Detect start-to-chug transition once
            if (startPhaseEndIndex == null && speedHistory.size() >= 3 && peakStrokeRate > 0) {
                var dropThreshold = peakStrokeRate * (1.0 - PHASE_DROP_PERCENT / 100.0);
                if (strokeRate <= dropThreshold) {
                    startPhaseEndIndex = speedHistory.size() - 1;
                }
            }
        }
    }

    // Get max speed during start phase
    function getStartMaxSpeed() {
        if (startPhaseEndIndex == null || startPhaseEndIndex == 0) {
            return 0.0;
        }
        var maxVal = 0.0;
        for (var i = 0; i < startPhaseEndIndex; i++) {
            if (speedHistory[i] > maxVal) {
                maxVal = speedHistory[i];
            }
        }
        return maxVal;
    }

    // Get max stroke rate during start phase
    function getStartMaxStrokeRate() {
        if (startPhaseEndIndex == null || startPhaseEndIndex == 0) {
            return 0.0;
        }
        var maxVal = 0.0;
        for (var i = 0; i < startPhaseEndIndex; i++) {
            if (strokeRateHistory[i] > maxVal) {
                maxVal = strokeRateHistory[i];
            }
        }
        return maxVal;
    }

    // Get average speed during chug phase
    function getChugAvgSpeed() {
        if (startPhaseEndIndex == null || startPhaseEndIndex >= speedHistory.size()) {
            return 0.0;
        }
        var sum = 0.0;
        var count = 0;
        for (var i = startPhaseEndIndex; i < speedHistory.size(); i++) {
            sum += speedHistory[i];
            count++;
        }
        return count > 0 ? sum / count : 0.0;
    }

    // Get average stroke rate during chug phase
    function getChugAvgStrokeRate() {
        if (startPhaseEndIndex == null || startPhaseEndIndex >= strokeRateHistory.size()) {
            return 0.0;
        }
        var sum = 0.0;
        var count = 0;
        for (var i = startPhaseEndIndex; i < strokeRateHistory.size(); i++) {
            sum += strokeRateHistory[i];
            count++;
        }
        return count > 0 ? sum / count : 0.0;
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
    var pieceDetectionEnabled; // Toggle for piece detection

    // Piece detection - based on strokes
    var lastPieceStrokeTime; // Time of last stroke in current piece
    const PIECE_END_DURATION = 5000; // 5 seconds in milliseconds

    // Stroke detection
    var lastAccelData;
    var strokeBuffer;
    var lastStrokeTime;
    const STROKE_COOLDOWN = 500; // milliseconds between strokes (120 SPM max)
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
        pieceDetectionEnabled = true; // Default to enabled

        lastPieceStrokeTime = 0;

        lastAccelData = null;
        strokeBuffer = [];
        lastStrokeTime = 0;

        lastPosition = null;
        sessionStartTime = System.getTimer();

        // Start activity recording session
        session = ActivityRecording.createSession({
            :name => "Dragon Boat",
            :sport => ActivityRecording.SPORT_PADDLING,
            :subSport => ActivityRecording.SUB_SPORT_GENERIC
        });
        session.start();
    }

    // Update with new position data
    function updatePosition(info) {
        // Get speed - prefer Activity.getActivityInfo() (firmware sensor fusion)
        // over Position.Info.speed (raw GPS, often null on some devices)
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo.currentSpeed != null) {
            currentSpeed = activityInfo.currentSpeed;
        } else if (info has :speed && info.speed != null) {
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
            currentPiece.recordSample(currentSpeed, strokeRate, heartRate);
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
                // Calculate per-sample timestamps based on 25 Hz sample rate.
                // Samples span the last batch period, so space them accordingly.
                var batchTime = System.getTimer();
                var samplePeriod = 1000 / 25; // 40ms per sample at 25 Hz
                for (var i = 0; i < numSamples; i++) {
                    var sampleTime = batchTime - ((numSamples - 1 - i) * samplePeriod);
                    detectStroke(xSamples[i], ySamples[i], zSamples[i], sampleTime);
                }
            }
        }
    }

    // Detect strokes from accelerometer data (single sample)
    function detectStroke(x, y, z, sampleTime) {
        // Cooldown check - don't detect strokes too frequently
        if (sampleTime - lastStrokeTime < STROKE_COOLDOWN) {
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
                lastStrokeTime = sampleTime;
            }
        }

        lastAccelData = [x, y, z];
    }

    // Register a stroke
    function registerStroke() {
        var currentTime = System.getTimer();

        totalStrokes++;

        // Only handle piece tracking if enabled
        if (pieceDetectionEnabled) {
            // Start new piece if no active piece
            if (!pieceActive || currentPiece == null) {
                currentPiece = new Piece();
                pieceActive = true;
            }

            // Add stroke to current piece
            currentPiece.strokeCount++;
            lastPieceStrokeTime = currentTime;
        }

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
        if (!pieceActive || currentPiece == null || !pieceDetectionEnabled) {
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
        if (currentPiece != null && currentPiece.strokeCount >= 3) {
            // Only save pieces with 3 or more strokes
            // Finalize the piece at the last stroke time (not current time)
            // This excludes the rest period from the piece duration
            currentPiece.finalize(lastPieceStrokeTime);
            pieces.add(currentPiece);
            
            // Add lap to FIT file for this piece
            if (session != null && session.isRecording()) {
                session.addLap();
            }
        }
        currentPiece = null;
        pieceActive = false;
        lastPieceStrokeTime = 0;
    }
    
    // Toggle piece detection on/off
    function togglePieceDetection() {
        pieceDetectionEnabled = !pieceDetectionEnabled;
        
        // If turning off and there's an active piece, end it
        if (!pieceDetectionEnabled && pieceActive) {
            endPiece();
        }
        
        return pieceDetectionEnabled;
    }
    
    // Get piece detection status
    function isPieceDetectionEnabled() {
        return pieceDetectionEnabled;
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

        // Poll speed from activity info for more responsive updates
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo.currentSpeed != null) {
            currentSpeed = activityInfo.currentSpeed;
        }

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
