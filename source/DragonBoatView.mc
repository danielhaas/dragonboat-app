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
        viewMode = 3; // Start with optimized grid view

        // Enable GPS
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));

        // Enable accelerometer and heart rate
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));
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
        var y = 28;

        // Title
        dc.drawText(centerX, 8, Graphics.FONT_TINY, "OVERALL", Graphics.TEXT_JUSTIFY_CENTER);

        // Speed
        dc.drawText(centerX, y, Graphics.FONT_SMALL, "Speed", Graphics.TEXT_JUSTIFY_CENTER);
        y += 42;
        var speedKmh = model.currentSpeed * 3.6; // m/s to km/h
        dc.drawText(centerX, y, Graphics.FONT_NUMBER_MEDIUM, speedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_CENTER);
        y += 58;

        // Stroke rate
        dc.drawText(centerX, y, Graphics.FONT_SMALL, "Stroke Rate", Graphics.TEXT_JUSTIFY_CENTER);
        y += 42;
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, model.strokeRate.format("%.0f") + " spm", Graphics.TEXT_JUSTIFY_CENTER);
        y += 50;

        // Distance
        dc.drawText(centerX, y, Graphics.FONT_SMALL, "Distance", Graphics.TEXT_JUSTIFY_CENTER);
        y += 38;
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, (model.totalDistance / 1000.0).format("%.2f") + " km", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Draw current piece view
    function drawCurrentPieceView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var y = 25;

        // Title
        dc.drawText(centerX, 10, Graphics.FONT_SMALL, "CURRENT PIECE", Graphics.TEXT_JUSTIFY_CENTER);

        if (model.currentPiece != null && model.pieceActive) {
            // Time
            dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Time", Graphics.TEXT_JUSTIFY_CENTER);
            y += 30;
            var pieceDuration = model.currentPiece.getCurrentDuration();
            var minutes = pieceDuration / 60;
            var seconds = pieceDuration % 60;
            dc.drawText(centerX, y, Graphics.FONT_NUMBER_MEDIUM, minutes.format("%d") + ":" + seconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
            y += 40;

            // Strokes
            dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Strokes", Graphics.TEXT_JUSTIFY_CENTER);
            y += 30;
            dc.drawText(centerX, y, Graphics.FONT_NUMBER_HOT, model.currentPiece.strokeCount.toString(), Graphics.TEXT_JUSTIFY_CENTER);
            y += 45;

            // Distance
            dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Distance", Graphics.TEXT_JUSTIFY_CENTER);
            y += 25;
            dc.drawText(centerX, y, Graphics.FONT_MEDIUM, (model.currentPiece.distance / 1000.0).format("%.2f") + " km", Graphics.TEXT_JUSTIFY_CENTER);
            y += 35;

            // Max Speed
            dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Max Speed", Graphics.TEXT_JUSTIFY_CENTER);
            y += 25;
            var maxSpeedKmh = model.currentPiece.maxSpeed * 3.6;
            dc.drawText(centerX, y, Graphics.FONT_MEDIUM, maxSpeedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            // No active piece
            dc.drawText(centerX, height / 2, Graphics.FONT_MEDIUM, "Start paddling...", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Draw all metrics view
    function drawAllMetricsView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var y = 28;
        var lineHeight = 22;
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
        y += lineHeight + 8;

        // Current piece
        dc.drawText(centerX, y, Graphics.FONT_XTINY, "-- Piece --", Graphics.TEXT_JUSTIFY_CENTER);
        y += lineHeight;

        if (model.currentPiece != null && model.pieceActive) {
            dc.drawText(margin, y, Graphics.FONT_XTINY, "Time:", Graphics.TEXT_JUSTIFY_LEFT);
            var pieceDuration = model.currentPiece.getCurrentDuration();
            var pieceMinutes = pieceDuration / 60;
            var pieceSeconds = pieceDuration % 60;
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, pieceMinutes.format("%d") + ":" + pieceSeconds.format("%02d"), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(margin, y, Graphics.FONT_XTINY, "Strokes:", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, model.currentPiece.strokeCount.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(margin, y, Graphics.FONT_XTINY, "Dist:", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(width - margin, y, Graphics.FONT_XTINY, (model.currentPiece.distance / 1000.0).format("%.2f"), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(margin, y, Graphics.FONT_XTINY, "Max:", Graphics.TEXT_JUSTIFY_LEFT);
            var maxSpeedKmh = model.currentPiece.maxSpeed * 3.6;
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
        var boxWidth = (width - 15) / 2;
        var boxY = 8;
        var boxHeight = 75;

        // Stroke Rate box (green background) - covers SPM and km/h
        dc.setColor(Graphics.COLOR_DK_GREEN, Graphics.COLOR_DK_GREEN);
        dc.fillRectangle(5, boxY, boxWidth, boxHeight);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(5 + boxWidth / 2, boxY + 4, Graphics.FONT_XTINY, "SPM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(5 + boxWidth / 2, boxY + 20, Graphics.FONT_SMALL, model.strokeRate.format("%.0f"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(5 + boxWidth / 2, boxY + 50, Graphics.FONT_XTINY, "km/h", Graphics.TEXT_JUSTIFY_CENTER);

        // Heart Rate box (blue background) - covers HR and Avg
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_BLUE);
        dc.fillRectangle(10 + boxWidth, boxY, boxWidth, boxHeight);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(10 + boxWidth + boxWidth / 2, boxY + 4, Graphics.FONT_XTINY, "HR", Graphics.TEXT_JUSTIFY_CENTER);
        var hrDisplay = model.heartRate > 0 ? model.heartRate.toString() : "--";
        dc.drawText(10 + boxWidth + boxWidth / 2, boxY + 20, Graphics.FONT_SMALL, hrDisplay, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(10 + boxWidth + boxWidth / 2, boxY + 50, Graphics.FONT_XTINY, "Avg", Graphics.TEXT_JUSTIFY_CENTER);

        // Row 2: Speed values (below boxes)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var currentSpeedKmh = model.currentSpeed * 3.6;
        dc.drawText(quarterX, 95, Graphics.FONT_NUMBER_MEDIUM, currentSpeedKmh.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);

        var avgSpeed = 0.0;
        if (model.elapsedTime > 0) {
            avgSpeed = (model.totalDistance / model.elapsedTime) * 3.6;
        }
        dc.drawText(threeQuarterX, 95, Graphics.FONT_NUMBER_MEDIUM, avgSpeed.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);

        // Row 3: Time and Distance - Labels above values (more spacing)
        dc.drawText(quarterX, 145, Graphics.FONT_XTINY, "Time", Graphics.TEXT_JUSTIFY_CENTER);
        var minutes = model.elapsedTime / 60;
        var seconds = model.elapsedTime % 60;
        dc.drawText(quarterX, 173, Graphics.FONT_MEDIUM, minutes.format("%d") + ":" + seconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);

        dc.drawText(threeQuarterX, 145, Graphics.FONT_XTINY, "km", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(threeQuarterX, 173, Graphics.FONT_MEDIUM, (model.totalDistance / 1000.0).format("%.2f"), Graphics.TEXT_JUSTIFY_CENTER);

        // Row 4: Pieces and Current Piece - Bottom of screen
        var piecesBoxWidth = 65;
        dc.setColor(Graphics.COLOR_PURPLE, Graphics.COLOR_PURPLE);
        dc.fillRectangle(8, 205, piecesBoxWidth, 30);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(8 + piecesBoxWidth / 2, 208, Graphics.FONT_XTINY, "Pieces", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(8 + piecesBoxWidth / 2, 220, Graphics.FONT_SMALL, model.pieces.size().toString(), Graphics.TEXT_JUSTIFY_CENTER);

        // Current piece
        if (model.currentPiece != null && model.pieceActive) {
            var pieceDuration = model.currentPiece.getCurrentDuration();
            var pieceMinutes = pieceDuration / 60;
            var pieceSeconds = pieceDuration % 60;
            dc.drawText(width - 75, 208, Graphics.FONT_XTINY, "Piece", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(width - 75, 220, Graphics.FONT_SMALL, pieceMinutes.format("%d") + ":" + pieceSeconds.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Called when this View is removed from the screen
    function onHide() {
    }

    // Position callback
    function onPosition(info as Position.Info) as Void {
        model.updatePosition(info);
        WatchUi.requestUpdate();
    }

    // Sensor callback
    function onSensor(sensorInfo as Sensor.Info) as Void {
        model.updateAccelerometer(sensorInfo);
        WatchUi.requestUpdate();
    }

    // Switch view mode
    function switchView(direction) {
        viewMode = (viewMode + direction) % 4;
        if (viewMode < 0) {
            viewMode = 3;
        }
        WatchUi.requestUpdate();
    }

    // Get the model
    function getModel() {
        return model;
    }
}
