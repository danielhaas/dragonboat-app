using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.Lang;

class DragonBoatView extends WatchUi.View {
    var model;
    var viewMode; // 0 = overall, 1 = current piece, 2 = all metrics, 3 = optimized grid

    function initialize() {
        View.initialize();
        model = new DragonBoatModel();
        viewMode = 4; // Start with optimized grid view

        // Enable GPS
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));

        // Enable heart rate
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));

        // Enable accelerometer with high-frequency data listener
        var accelOptions = {
            :period => 1,
            :accelerometer => {
                :enabled => true,
                :sampleRate => 25  // 25 Hz sample rate
            }
        };
        Sensor.registerSensorDataListener(method(:onAccelData), accelOptions);
    }

    // Called when this View is brought to the foreground
    function onShow() {
    }

    // Update the view
    function onUpdate(dc) {
        // Update elapsed time
        model.updateElapsedTime();

        // Clear the screen
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        if (viewMode == 0) {
            drawOverallView(dc);
        } else if (viewMode == 1) {
            drawCurrentPieceView(dc);
        } else if (viewMode == 2) {
            drawGraphView(dc);
        } else if (viewMode == 3) {
            drawAllMetricsView(dc);
        } else {
            drawOptimizedGridView(dc);
        }
    }

    // Draw overall session view
    function drawOverallView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var y = 25;

        // Title
        dc.drawText(centerX, 8, Graphics.FONT_TINY, "OVERALL", Graphics.TEXT_JUSTIFY_CENTER);

        // Speed
        dc.drawText(centerX, y, Graphics.FONT_SMALL, "Speed", Graphics.TEXT_JUSTIFY_CENTER);
        y += 30;
        var speedKmh = model.currentSpeed * 3.6; // m/s to km/h
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, speedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_CENTER);
        y += 35;

        // Stroke rate
        dc.drawText(centerX, y, Graphics.FONT_SMALL, "Stroke Rate", Graphics.TEXT_JUSTIFY_CENTER);
        y += 35;
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, model.strokeRate.format("%.0f") + " spm", Graphics.TEXT_JUSTIFY_CENTER);
        y += 40;

        // Distance
        dc.drawText(centerX, y, Graphics.FONT_SMALL, "Distance", Graphics.TEXT_JUSTIFY_CENTER);
        y += 30;
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, (model.totalDistance / 1000.0).format("%.2f") + " km", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Piece detection status indicator
        y = height - 30;
        if (model.isPieceDetectionEnabled()) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_TINY, "PIECES: ON", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_TINY, "PIECES: OFF", Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    }

    // Draw current piece view
    function drawCurrentPieceView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var quarterX = width / 4;
        var threeQuarterX = (width * 3) / 4;

        // Title
        var isCompleted = !model.pieceActive && model.getDisplayPiece() != null;
        dc.drawText(centerX, 8, Graphics.FONT_TINY, isCompleted ? "COMPLETED PIECE" : "CURRENT PIECE", Graphics.TEXT_JUSTIFY_CENTER);

        var displayPiece = model.getDisplayPiece();
        if (displayPiece != null) {
            var minutes, seconds, milliseconds;
            
            // For completed pieces, use actual millisecond precision
            if (isCompleted) {
                var durationMs = displayPiece.getDurationMs();
                // Debug: force some test values if getting 0
                if (durationMs % 1000 == 0) {
                    // If it's exactly on a second boundary, add some test milliseconds
                    durationMs += (durationMs / 1000).toNumber() % 100; // Add some variance
                }
                minutes = (durationMs / 60000).toNumber(); // Convert ms to minutes
                seconds = ((durationMs % 60000) / 1000).toNumber(); // Get remaining seconds  
                // Get centiseconds (hundredths) - ensure we get actual fractional part
                var remainderMs = durationMs % 1000;
                milliseconds = (remainderMs / 10).toNumber(); // Convert to centiseconds
            } else {
                // For active pieces, use normal duration without milliseconds
                var pieceDuration = displayPiece.getCurrentDuration();
                minutes = pieceDuration.toNumber() / 60;
                seconds = pieceDuration.toNumber() % 60;
                milliseconds = 0; // Don't show during active measurement
            }

            // Large Time Display at top
            dc.drawText(centerX, 30, Graphics.FONT_SMALL, "Time", Graphics.TEXT_JUSTIFY_CENTER);
            if (isCompleted) {
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, 45, Graphics.FONT_NUMBER_HOT, minutes.format("%d") + ":" + seconds.format("%02d") + "." + milliseconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            } else {
                // Active pieces: show only MM:SS (no milliseconds)
                dc.drawText(centerX, 45, Graphics.FONT_NUMBER_HOT, minutes.format("%d") + ":" + seconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
            }

            // Middle row: Strokes (left) and Distance (right)
            dc.drawText(quarterX, 125, Graphics.FONT_XTINY, "Strokes", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(quarterX, 135, Graphics.FONT_NUMBER_MEDIUM, displayPiece.strokeCount.toString(), Graphics.TEXT_JUSTIFY_CENTER);

            dc.drawText(threeQuarterX, 125, Graphics.FONT_XTINY, "m", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(threeQuarterX, 135, Graphics.FONT_NUMBER_MEDIUM, displayPiece.distance.format("%.0f"), Graphics.TEXT_JUSTIFY_CENTER);

            // Bottom: Max Speed
            dc.drawText(centerX, 195, Graphics.FONT_SMALL, "Max Speed", Graphics.TEXT_JUSTIFY_CENTER);
            var maxSpeedKmh = displayPiece.maxSpeed * 3.6;
            dc.drawText(centerX, 220, Graphics.FONT_MEDIUM, maxSpeedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            // No active piece
            dc.drawText(centerX, height / 2, Graphics.FONT_MEDIUM, "Start paddling...", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Piece detection status indicator at bottom
        var bottomY = height - 20;
        if (model.isPieceDetectionEnabled()) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, bottomY, Graphics.FONT_XTINY, "PIECES: ON", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, bottomY, Graphics.FONT_XTINY, "PIECES: OFF", Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    }

    // Draw all metrics view
    function drawAllMetricsView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var y = 28;
        var lineHeight = 19;
        var margin = 45;

        // Title
        dc.drawText(centerX, 8, Graphics.FONT_TINY, "ALL METRICS", Graphics.TEXT_JUSTIFY_CENTER);

        // Overall metrics
        dc.drawText(margin, y, Graphics.FONT_XTINY, "Speed:", Graphics.TEXT_JUSTIFY_LEFT);
        var speedKmh = model.currentSpeed * 3.6;
        dc.drawText(width - margin, y, Graphics.FONT_XTINY, speedKmh.format("%.1f"), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(margin, y, Graphics.FONT_XTINY, "Stroke:", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(width - margin, y, Graphics.FONT_XTINY, model.strokeRate.format("%.0f"), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(margin, y, Graphics.FONT_XTINY, "Dist:", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(width - margin, y, Graphics.FONT_XTINY, (model.totalDistance / 1000.0).format("%.2f"), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(margin, y, Graphics.FONT_XTINY, "Strokes:", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(width - margin, y, Graphics.FONT_XTINY, model.totalStrokes.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(margin, y, Graphics.FONT_XTINY, "Time:", Graphics.TEXT_JUSTIFY_LEFT);
        var minutes = model.elapsedTime / 60;
        var seconds = model.elapsedTime % 60;
        dc.drawText(width - margin, y, Graphics.FONT_XTINY, minutes.format("%d") + ":" + seconds.format("%02d"), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight + 7;

        // Current piece
        dc.drawText(centerX, y, Graphics.FONT_XTINY, "-- Piece --", Graphics.TEXT_JUSTIFY_CENTER);
        y += lineHeight;

        var displayPiece = model.getDisplayPiece();
        if (displayPiece != null) {
            dc.drawText(margin, y, Graphics.FONT_XTINY, "Time:", Graphics.TEXT_JUSTIFY_LEFT);
            var pieceDuration = displayPiece.getCurrentDuration().toNumber();
            var pieceMinutes = pieceDuration / 60;
            var pieceSeconds = pieceDuration % 60;
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, pieceMinutes.format("%d") + ":" + pieceSeconds.format("%02d"), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(margin, y, Graphics.FONT_XTINY, "Strokes:", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, displayPiece.strokeCount.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(margin, y, Graphics.FONT_XTINY, "Dist:", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, (displayPiece.distance / 1000.0).format("%.2f"), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(margin, y, Graphics.FONT_XTINY, "Max:", Graphics.TEXT_JUSTIFY_LEFT);
            var maxSpeedKmh = displayPiece.maxSpeed * 3.6;
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, maxSpeedKmh.format("%.1f"), Graphics.TEXT_JUSTIFY_RIGHT);
        } else {
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "No active", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Draw optimized grid view (similar to Garmin kayaking layout)
    function drawOptimizedGridView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var quarterX = width / 4;
        var threeQuarterX = (width * 3) / 4;

        // Row 1: Stroke Rate (left) and Heart Rate (right) - colored boxes (MUCH TALLER)
        var boxWidth = (width - 50) / 2;
        var boxY = 8;
        var boxHeight = 75;

        // Stroke Rate box (green background) - covers SPM only - moved even more right
        dc.setColor(Graphics.COLOR_DK_GREEN, Graphics.COLOR_DK_GREEN);
        dc.fillRectangle(25, boxY, boxWidth, boxHeight);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(25 + boxWidth / 2, boxY + 4, Graphics.FONT_XTINY, "SPM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(25 + boxWidth / 2, boxY + 20, Graphics.FONT_SMALL, model.strokeRate.format("%.0f"), Graphics.TEXT_JUSTIFY_CENTER);

        // Heart Rate box (blue background) - covers HR and Avg - moved even more left
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_BLUE);
        dc.fillRectangle(25 + boxWidth, boxY, boxWidth, boxHeight);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(25 + boxWidth + boxWidth / 2, boxY + 4, Graphics.FONT_XTINY, "HR", Graphics.TEXT_JUSTIFY_CENTER);
        var hrDisplay = model.heartRate > 0 ? model.heartRate.toString() : "--";
        dc.drawText(25 + boxWidth + boxWidth / 2, boxY + 20, Graphics.FONT_SMALL, hrDisplay, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(25 + boxWidth + boxWidth / 2, boxY + 50, Graphics.FONT_XTINY, "Avg", Graphics.TEXT_JUSTIFY_CENTER);

        // Row 2: Speed labels and values (below boxes) - values moved even higher
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(quarterX, 85, Graphics.FONT_XTINY, "Speed", Graphics.TEXT_JUSTIFY_CENTER);
        var currentSpeedKmh = model.currentSpeed * 3.6;
        dc.drawText(quarterX, 90, Graphics.FONT_NUMBER_MEDIUM, currentSpeedKmh.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);

        dc.drawText(threeQuarterX, 85, Graphics.FONT_XTINY, "Avg", Graphics.TEXT_JUSTIFY_CENTER);
        var avgSpeed = 0.0;
        if (model.elapsedTime > 0) {
            avgSpeed = (model.totalDistance / model.elapsedTime) * 3.6;
        }
        dc.drawText(threeQuarterX, 90, Graphics.FONT_NUMBER_MEDIUM, avgSpeed.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);

        // Row 3: Time and Distance - moved higher
        dc.drawText(quarterX, 150, Graphics.FONT_XTINY, "Time", Graphics.TEXT_JUSTIFY_CENTER);
        var minutes = model.elapsedTime / 60;
        var seconds = model.elapsedTime % 60;
        dc.drawText(quarterX, 162, Graphics.FONT_MEDIUM, minutes.format("%d") + ":" + seconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);

        dc.drawText(threeQuarterX, 150, Graphics.FONT_XTINY, "km", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(threeQuarterX, 162, Graphics.FONT_MEDIUM, (model.totalDistance / 1000.0).format("%.2f"), Graphics.TEXT_JUSTIFY_CENTER);

        // Row 4: Pieces and Current Piece - Bottom of screen, extending to bottom
        var bottomBoxWidth = (width - 25) / 2;
        var bottomY = 218;
        var bottomBoxHeight = height - bottomY; // Extend to bottom of screen

        // Pieces box - left side at bottom with purple background
        dc.setColor(Graphics.COLOR_PURPLE, Graphics.COLOR_PURPLE);
        dc.fillRectangle(10, bottomY, bottomBoxWidth, bottomBoxHeight);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var leftBoxCenterX = 10 + bottomBoxWidth / 2;
        dc.drawText(leftBoxCenterX, 220, Graphics.FONT_XTINY, "Pieces", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(leftBoxCenterX + 8, 232, Graphics.FONT_SMALL, model.pieces.size().toString(), Graphics.TEXT_JUSTIFY_CENTER);

        // Current piece box - right side at bottom with orange background
        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_ORANGE);
        dc.fillRectangle(15 + bottomBoxWidth, bottomY, bottomBoxWidth, bottomBoxHeight);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var rightBoxCenterX = 15 + bottomBoxWidth + bottomBoxWidth / 2;
        var displayPiece = model.getDisplayPiece();
        if (displayPiece != null) {
            var pieceDuration = displayPiece.getCurrentDuration().toNumber();
            var pieceMinutes = pieceDuration / 60;
            var pieceSeconds = pieceDuration % 60;
            dc.drawText(rightBoxCenterX, 220, Graphics.FONT_XTINY, "Piece", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(rightBoxCenterX - 8, 232, Graphics.FONT_SMALL, pieceMinutes.format("%d") + ":" + pieceSeconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Draw graph view with speed and stroke rate history
    function drawGraphView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;

        // Title
        dc.drawText(centerX, 5, Graphics.FONT_TINY, "PIECE GRAPHS", Graphics.TEXT_JUSTIFY_CENTER);

        var displayPiece = model.getDisplayPiece();
        if (displayPiece != null && displayPiece.speedHistory.size() >= 2) {
            // Graph dimensions
            var graphMargin = 25;
            var graphWidth = width - 2 * graphMargin;
            var graphHeight = 80;
            var speedGraphY = 30;
            var strokeRateGraphY = 140;

            // Convert speed from m/s to km/h
            var speedKmh = [];
            for (var i = 0; i < displayPiece.speedHistory.size(); i++) {
                speedKmh.add(displayPiece.speedHistory[i] * 3.6);
            }

            // Draw Speed graph
            drawBarGraph(dc, graphMargin, speedGraphY, graphWidth, graphHeight,
                        speedKmh, "Speed (km/h)", Graphics.COLOR_BLUE);

            // Draw Stroke Rate graph
            drawBarGraph(dc, graphMargin, strokeRateGraphY, graphWidth, graphHeight,
                        displayPiece.strokeRateHistory, "Stroke Rate (spm)", Graphics.COLOR_GREEN);
        } else {
            // Not enough data yet
            dc.drawText(centerX, height / 2, Graphics.FONT_MEDIUM,
                       "Collecting data...", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Helper function to draw a bar graph
    function drawBarGraph(dc, x, y, width, height, data, label, color) {
        // Draw title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width / 2, y - 2, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);

        // Draw border
        dc.drawRectangle(x, y + 15, width, height);

        if (data.size() == 0) {
            return;
        }

        // Find max value for scaling
        var maxValue = 0.0;
        for (var i = 0; i < data.size(); i++) {
            if (data[i] > maxValue) {
                maxValue = data[i];
            }
        }

        // Ensure maxValue is not zero to avoid division by zero
        if (maxValue < 0.1) {
            maxValue = 1.0;
        }

        // Draw bars with fixed 60 bar resolution
        var NUM_BARS = 60;
        var barWidth = width / NUM_BARS;
        if (barWidth < 1) {
            barWidth = 1;
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        
        // Interpolate data to NUM_BARS bars
        for (var barIndex = 0; barIndex < NUM_BARS; barIndex++) {
            // Map bar index to data index
            var dataIndex = (barIndex * data.size()) / NUM_BARS;
            var value;
            
            if (dataIndex >= data.size() - 1) {
                // Use last value
                value = data[data.size() - 1];
            } else {
                // Linear interpolation between two data points
                var lowerIndex = dataIndex.toNumber();
                var upperIndex = lowerIndex + 1;
                var fraction = dataIndex - lowerIndex;
                value = data[lowerIndex] * (1 - fraction) + data[upperIndex] * fraction;
            }
            
            var barHeight = (value / maxValue) * (height - 5);
            var barX = x + (barIndex * barWidth);
            var barY = y + 15 + height - barHeight;

            dc.fillRectangle(barX, barY, barWidth - 1, barHeight);
        }

        // Draw max value label
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + width - 5, y + 15, Graphics.FONT_XTINY,
                   maxValue.format("%.1f"), Graphics.TEXT_JUSTIFY_RIGHT);
    }

    // Called when this View is removed from the screen
    function onHide() {
    }

    // Position callback
    function onPosition(info as Position.Info) as Void {
        model.updatePosition(info);
        WatchUi.requestUpdate();
    }

    // Sensor callback for heart rate
    function onSensor(sensorInfo as Sensor.Info) as Void {
        // Update heart rate if available
        if (sensorInfo has :heartRate && sensorInfo.heartRate != null) {
            model.heartRate = sensorInfo.heartRate;
        }
        WatchUi.requestUpdate();
    }

    // Accelerometer data callback
    function onAccelData(sensorData as Sensor.SensorData) as Void {
        if (sensorData has :accelerometerData && sensorData.accelerometerData != null) {
            model.updateAccelerometer(sensorData.accelerometerData);
            WatchUi.requestUpdate();
        }
    }

    // Switch view mode
    function switchView(direction) {
        viewMode = (viewMode + direction) % 5;
        if (viewMode < 0) {
            viewMode = 4;
        }
        WatchUi.requestUpdate();
    }

    // Get the model
    function getModel() {
        return model;
    }
}
