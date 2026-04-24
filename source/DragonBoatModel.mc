using Toybox.System;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.ActivityRecording;
using Toybox.Activity;
using Toybox.FitContributor;
using Toybox.Timer;
using Toybox.WatchUi;

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

    // Offline-analyzer results (populated by DragonBoatAnalyzer at piece end).
    // These override the live strokeCount / duration when present.
    var analyzedStrokes;          // Stroke count from offline detector (null until run)
    var analyzedActiveStartMs;    // Active region start, ms into the piece
    var analyzedActiveEndMs;      // Active region end, ms into the piece
    var analyzedActiveDurationMs; // analyzedActiveEndMs - analyzedActiveStartMs
    var analyzedAvgSpm;           // Strokes / activeDuration × 60
    var analyzedCadenceMs;        // Autocorrelation-detected cycle length

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

        // Offline analyzer results — null until analyze() is called
        analyzedStrokes = null;
        analyzedActiveStartMs = 0;
        analyzedActiveEndMs = 0;
        analyzedActiveDurationMs = 0;
        analyzedAvgSpm = 0.0;
        analyzedCadenceMs = 0;
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

    // Best stroke count: analyzed value if available, otherwise live count.
    function getBestStrokeCount() {
        if (analyzedStrokes != null) {
            return analyzedStrokes;
        }
        return strokeCount;
    }

    // Best duration in ms: trimmed active duration if analyzed, else raw piece duration.
    function getBestDurationMs() {
        if (analyzedStrokes != null && analyzedActiveDurationMs > 0) {
            return analyzedActiveDurationMs;
        }
        return getDurationMs();
    }

    // True if this piece has been analyzed offline.
    function isAnalyzed() {
        return analyzedStrokes != null;
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
    //
    // Look-ahead local-maximum detector. Each sample we compute |a| in g,
    // subtract a slow gravity baseline, and push the absolute deviation
    // into a small ring buffer. A stroke is committed when the *center*
    // sample of that buffer is a strict local max above PEAK_THRESHOLD_G.
    // This introduces a fixed ~PEAK_HALF_INDEX*40ms latency which is
    // acceptable since the watch is not glanced at while paddling.
    var strokeBuffer;     // timestamps of confirmed strokes (for SPM calc)
    var lastStrokeTime;   // timestamp of most recently confirmed stroke
    var peakBufMag;       // ring buffer of dynamic magnitudes (g)
    var peakBufTime;      // ring buffer of sample timestamps (ms)
    var peakBufFilled;    // number of valid samples in the ring (until full)
    var gravityEMA;       // slow-moving estimate of gravity magnitude (g)

    const PEAK_BUF_SIZE = 21;          // 21 samples @25Hz = 840ms window
    const PEAK_HALF_INDEX = 10;        // center of the ring (±400ms)
    const PEAK_THRESHOLD_G = 0.3;      // dynamic |a-g| required at the peak
    const MIN_STROKE_INTERVAL = 300;   // ms between confirmed strokes (200 SPM ceiling)
    const GRAVITY_EMA_ALPHA = 0.01;    // gravity baseline update rate

    // Activity session
    var session;
    var sessionStartTime;

    // Accelerometer logging to FIT developer fields.
    // Each 1-second FIT record stores the batch of ~25 raw accel samples
    // as three SINT16 array fields (x, y, z) plus a sample count field.
    // This adds ~150 bytes/record to the FIT file.
    var accelXField;
    var accelYField;
    var accelZField;
    var accelNField;
    const ACCEL_LOG_BATCH = 25; // max samples per FIT record (matches 25 Hz × 1s)

    // Per-piece raw sample buffer for offline analysis.
    // Stores |a| in milli-g as one big-endian sint16 per sample (2 bytes).
    // x,y,z are collapsed to magnitude in the sensor callback so the
    // analyzer only has to stream int16s. Capped at 5 minutes @ 25 Hz
    // = 7500 samples × 2 bytes = 15000 bytes.
    var sampleBuffer;
    var numBufferedSamples;
    const SAMPLE_BUFFER_MAX_SAMPLES = 7500;
    const SAMPLE_BUFFER_BYTES = 15000; // 7500 × 2

    // Offline analyzer instance (one per app, reused per piece)
    var analyzer;

    // Piece-analysis state. endPiece() kicks off an AnalyzerJob that is
    // stepped chunk-by-chunk by a Timer callback, so the UI never blocks
    // on the analyzer and the watchdog never sees a long invocation.
    // A fresh ByteArray snapshot is handed to the job so a new piece
    // starting during analysis doesn't overwrite samples being analyzed.
    var pieceAnalyzeTimer;
    var pieceAnalyzeJob;
    var pieceAnalyzePiece;   // the Piece whose results we'll populate
    // Chunk size is tuned for a real fenix watch: ~150 samples × ~1–2 ms
    // per sample leaves comfortable margin under the ~1.5 s watchdog.
    const PIECE_CHUNK_SAMPLES = 150;

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

        strokeBuffer = [];
        lastStrokeTime = 0;

        // Initialize the peak-detection ring buffer
        peakBufMag = new [PEAK_BUF_SIZE];
        peakBufTime = new [PEAK_BUF_SIZE];
        for (var i = 0; i < PEAK_BUF_SIZE; i++) {
            peakBufMag[i] = 0.0;
            peakBufTime[i] = 0;
        }
        peakBufFilled = 0;
        gravityEMA = 1.0; // start at 1g and let the EMA settle

        lastPosition = null;
        sessionStartTime = System.getTimer();

        // Allocate the per-piece sample buffer once at app start to avoid
        // heap fragmentation from reallocating large ByteArrays.
        sampleBuffer = new [SAMPLE_BUFFER_BYTES]b;
        numBufferedSamples = 0;
        analyzer = new DragonBoatAnalyzer();

        pieceAnalyzeTimer = null;
        pieceAnalyzeJob = null;
        pieceAnalyzePiece = null;

        // Start activity recording session
        session = ActivityRecording.createSession({
            :name => "Dragon Boat",
            :sport => ActivityRecording.SPORT_PADDLING,
            :subSport => ActivityRecording.SUB_SPORT_GENERIC
        });

        // Create developer fields for raw accelerometer logging.
        // Three SINT16 arrays (x/y/z, 25 elements each) + one UINT8 count.
        // These get written into each 1-second FIT record automatically.
        accelXField = session.createField("accel_x", 0,
            FitContributor.DATA_TYPE_SINT16,
            {:mesgType => FitContributor.MESG_TYPE_RECORD,
             :count => ACCEL_LOG_BATCH, :units => "mg"});
        accelYField = session.createField("accel_y", 1,
            FitContributor.DATA_TYPE_SINT16,
            {:mesgType => FitContributor.MESG_TYPE_RECORD,
             :count => ACCEL_LOG_BATCH, :units => "mg"});
        accelZField = session.createField("accel_z", 2,
            FitContributor.DATA_TYPE_SINT16,
            {:mesgType => FitContributor.MESG_TYPE_RECORD,
             :count => ACCEL_LOG_BATCH, :units => "mg"});
        accelNField = session.createField("accel_n", 3,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "samples"});

        session.start();
    }

    // Update with new position data
    function updatePosition(info) {
        // Get speed - prefer raw GPS for responsiveness,
        // fall back to Activity sensor fusion if raw GPS unavailable
        if (info has :speed && info.speed != null) {
            currentSpeed = info.speed;
        } else {
            var activityInfo = Activity.getActivityInfo();
            if (activityInfo != null && activityInfo.currentSpeed != null) {
                currentSpeed = activityInfo.currentSpeed;
            }
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

                // Log raw samples to FIT developer fields.
                // Pad/truncate to ACCEL_LOG_BATCH so the field arrays are fixed-size.
                var n = numSamples < ACCEL_LOG_BATCH ? numSamples : ACCEL_LOG_BATCH;
                var xPad = new [ACCEL_LOG_BATCH];
                var yPad = new [ACCEL_LOG_BATCH];
                var zPad = new [ACCEL_LOG_BATCH];
                for (var j = 0; j < ACCEL_LOG_BATCH; j++) {
                    if (j < n) {
                        xPad[j] = xSamples[j];
                        yPad[j] = ySamples[j];
                        zPad[j] = zSamples[j];
                    } else {
                        xPad[j] = 0;
                        yPad[j] = 0;
                        zPad[j] = 0;
                    }
                }
                accelXField.setData(xPad);
                accelYField.setData(yPad);
                accelZField.setData(zPad);
                accelNField.setData(n);

                // Append |a| samples to the per-piece buffer for offline
                // analysis. Magnitude is computed here so the analyzer only
                // streams int16s. Drops samples once the 5-min cap is reached.
                if (pieceActive
                        && numBufferedSamples < SAMPLE_BUFFER_MAX_SAMPLES) {
                    for (var j = 0; j < numSamples; j++) {
                        if (numBufferedSamples >= SAMPLE_BUFFER_MAX_SAMPLES) {
                            break;
                        }
                        var sx = xSamples[j];
                        var sy = ySamples[j];
                        var sz = zSamples[j];
                        var magMg = Math.sqrt(sx*sx + sy*sy + sz*sz).toNumber();
                        appendBufferMag(magMg);
                    }
                }
            }
        }
    }

    // Detect strokes from accelerometer data (single sample).
    //
    // Algorithm:
    //   1. Compute |a| in g for this sample.
    //   2. Track a slow EMA of |a| as the gravity baseline.
    //   3. dyn = ||a| - gravity| is the dynamic (motion) component.
    //   4. Push dyn into a ring buffer of size PEAK_BUF_SIZE.
    //   5. Once the ring is full, look at the *center* element of the
    //      ring. If it is strictly larger than every other element in
    //      the ring AND exceeds PEAK_THRESHOLD_G, it is a confirmed
    //      stroke peak. Commit the stroke at the center sample's time.
    //   6. MIN_STROKE_INTERVAL is a sanity floor to reject impossibly
    //      fast double-detections; the local-max requirement does most
    //      of the rejection work.
    function detectStroke(x, y, z, sampleTime) {
        // Magnitude in g (raw samples are in milli-g)
        var mag = Math.sqrt(x*x + y*y + z*z) / 1000.0;

        // Update slow gravity baseline
        gravityEMA = (1.0 - GRAVITY_EMA_ALPHA) * gravityEMA + GRAVITY_EMA_ALPHA * mag;

        // Absolute deviation from gravity = dynamic motion component
        var dyn = mag - gravityEMA;
        if (dyn < 0) { dyn = -dyn; }

        // Shift ring buffer left by one and append the new sample at the end
        for (var i = 0; i < PEAK_BUF_SIZE - 1; i++) {
            peakBufMag[i] = peakBufMag[i + 1];
            peakBufTime[i] = peakBufTime[i + 1];
        }
        peakBufMag[PEAK_BUF_SIZE - 1] = dyn;
        peakBufTime[PEAK_BUF_SIZE - 1] = sampleTime;

        // Wait until the ring is full before looking for peaks
        if (peakBufFilled < PEAK_BUF_SIZE) {
            peakBufFilled++;
            return;
        }

        // Examine the center sample as a candidate peak
        var centerVal = peakBufMag[PEAK_HALF_INDEX];
        var centerTime = peakBufTime[PEAK_HALF_INDEX];

        if (centerVal < PEAK_THRESHOLD_G) {
            return;
        }

        // Strict local maximum check across the whole window
        for (var i = 0; i < PEAK_BUF_SIZE; i++) {
            if (i == PEAK_HALF_INDEX) { continue; }
            if (peakBufMag[i] >= centerVal) {
                return;
            }
        }

        // Sanity floor on stroke spacing
        if (centerTime - lastStrokeTime < MIN_STROKE_INTERVAL) {
            return;
        }

        // Confirmed stroke at the center sample's time
        registerStroke(centerTime);
        lastStrokeTime = centerTime;
    }

    // Register a stroke
    function registerStroke(strokeTime) {
        totalStrokes++;

        // Only handle piece tracking if enabled
        if (pieceDetectionEnabled) {
            // Start new piece if no active piece
            if (!pieceActive || currentPiece == null) {
                currentPiece = new Piece();
                pieceActive = true;
                // Reset the per-piece sample buffer for offline analysis
                numBufferedSamples = 0;
            }

            // Add stroke to current piece
            currentPiece.strokeCount++;
            lastPieceStrokeTime = strokeTime;
        }

        // Update stroke rate (strokes per minute)
        updateStrokeRate(strokeTime);
    }

    // Update stroke rate calculation
    function updateStrokeRate(strokeTime) {
        strokeBuffer.add(strokeTime);

        // Keep only strokes from last 10 seconds
        var cutoffTime = strokeTime - 10000;
        var newBuffer = [];
        for (var i = 0; i < strokeBuffer.size(); i++) {
            if (strokeBuffer[i] > cutoffTime) {
                newBuffer.add(strokeBuffer[i]);
            }
        }
        strokeBuffer = newBuffer;

        // Calculate rate from N strokes spanning N-1 intervals.
        // (N / timeSpan) overestimates rate; (N - 1) / timeSpan is correct.
        if (strokeBuffer.size() > 1) {
            var timeSpan = (strokeTime - strokeBuffer[0]) / 1000.0; // seconds
            if (timeSpan > 0) {
                strokeRate = ((strokeBuffer.size() - 1) / timeSpan) * 60.0; // per minute
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

    // End current piece.
    //
    // The offline analyzer runs asynchronously via an AnalyzerJob driven
    // by a Toybox.Timer, so we can close the piece synchronously here
    // (UI stays responsive, checkPieceEnd returns immediately) while the
    // multi-pass analysis completes over the following seconds. A fresh
    // ByteArray snapshot is handed to the job so a new piece starting
    // during analysis doesn't overwrite the samples being analyzed.
    function endPiece() {
        if (currentPiece != null && currentPiece.strokeCount >= 3) {
            currentPiece.finalize(lastPieceStrokeTime);

            if (numBufferedSamples >= 25 && pieceAnalyzeJob == null) {
                var snapshotBytes = numBufferedSamples * 2;
                var snapshot = sampleBuffer.slice(0, snapshotBytes);
                pieceAnalyzeJob = new AnalyzerJob(snapshot, numBufferedSamples);
                pieceAnalyzePiece = currentPiece;
                if (pieceAnalyzeTimer == null) {
                    pieceAnalyzeTimer = new Timer.Timer();
                }
                pieceAnalyzeTimer.start(method(:pieceAnalyzeStep), 30, false);
            }

            pieces.add(currentPiece);

            if (session != null && session.isRecording()) {
                session.addLap();
            }
        }
        currentPiece = null;
        pieceActive = false;
        lastPieceStrokeTime = 0;
        numBufferedSamples = 0;
    }

    // Timer tick that advances the in-flight piece analysis job. When
    // the job finishes, its result is written back onto the stored Piece
    // so getBestStrokeCount() / getBestDurationMs() start returning the
    // analyzed values.
    function pieceAnalyzeStep() {
        if (pieceAnalyzeJob == null || pieceAnalyzePiece == null) {
            return;
        }
        try {
            var done = pieceAnalyzeJob.step(PIECE_CHUNK_SAMPLES);
            if (done) {
                var result = pieceAnalyzeJob.getResult();
                pieceAnalyzePiece.analyzedStrokes = result[:strokes];
                pieceAnalyzePiece.analyzedActiveStartMs = result[:activeStartMs];
                pieceAnalyzePiece.analyzedActiveEndMs = result[:activeEndMs];
                pieceAnalyzePiece.analyzedActiveDurationMs = result[:activeDurationMs];
                pieceAnalyzePiece.analyzedAvgSpm = result[:avgSpm];
                pieceAnalyzePiece.analyzedCadenceMs = result[:cadenceMs];
                pieceAnalyzeJob = null;
                pieceAnalyzePiece = null;
                WatchUi.requestUpdate();
                return;
            }
        } catch (ex) {
            System.println("Piece analyze failed: " + ex.getErrorMessage());
            pieceAnalyzePiece.analyzedStrokes = null;
            pieceAnalyzeJob = null;
            pieceAnalyzePiece = null;
            return;
        }
        pieceAnalyzeTimer.start(method(:pieceAnalyzeStep), 30, false);
    }

    // Pack a single |a| (milli-g) value into the buffer as a big-endian
    // unsigned int16 (2 bytes). |a| is always non-negative, so the full
    // 0..65535 range is available. Clamp to that range to be safe.
    function appendBufferMag(magMg) {
        if (magMg < 0) { magMg = 0; }
        if (magMg > 65535) { magMg = 65535; }
        var off = numBufferedSamples * 2;
        sampleBuffer[off]     = (magMg >> 8) & 0xFF;
        sampleBuffer[off + 1] = magMg & 0xFF;
        numBufferedSamples++;
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
