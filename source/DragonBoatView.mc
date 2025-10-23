using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.Lang;

class DragonBoatView extends WatchUi.View {
    var model;
    var viewMode; // 0 = overall, 1 = current piece, 2 = all metrics

    function initialize() {
        View.initialize();
        model = new DragonBoatModel();
        viewMode = 0;

        // Enable GPS
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));

        // Enable accelerometer
        Sensor.setEnabledSensors([]);
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
        } else {
            drawAllMetricsView(dc);
        }
    }

    // Draw overall session view
    function drawOverallView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var y = 30;

        // Title
        dc.drawText(centerX, 10, Graphics.FONT_SMALL, "OVERALL", Graphics.TEXT_JUSTIFY_CENTER);

        // Speed
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Speed", Graphics.TEXT_JUSTIFY_CENTER);
        y += 30;
        var speedKmh = model.currentSpeed * 3.6; // m/s to km/h
        dc.drawText(centerX, y, Graphics.FONT_NUMBER_HOT, speedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_CENTER);
        y += 50;

        // Stroke rate
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Stroke Rate", Graphics.TEXT_JUSTIFY_CENTER);
        y += 30;
        dc.drawText(centerX, y, Graphics.FONT_NUMBER_MEDIUM, model.strokeRate.format("%.0f") + " spm", Graphics.TEXT_JUSTIFY_CENTER);
        y += 45;

        // Distance
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, "Distance", Graphics.TEXT_JUSTIFY_CENTER);
        y += 30;
        dc.drawText(centerX, y, Graphics.FONT_MEDIUM, (model.totalDistance / 1000.0).format("%.2f") + " km", Graphics.TEXT_JUSTIFY_CENTER);

        // View indicator
        dc.drawText(centerX, height - 25, Graphics.FONT_TINY, "UP/DOWN to switch views", Graphics.TEXT_JUSTIFY_CENTER);
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

        // View indicator
        dc.drawText(centerX, height - 25, Graphics.FONT_TINY, "UP/DOWN to switch views", Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Draw all metrics view
    function drawAllMetricsView(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var y = 20;
        var lineHeight = 25;

        // Title
        dc.drawText(centerX, 5, Graphics.FONT_TINY, "ALL METRICS", Graphics.TEXT_JUSTIFY_CENTER);
        y += 15;

        // Overall metrics
        dc.drawText(10, y, Graphics.FONT_XTINY, "Speed:", Graphics.TEXT_JUSTIFY_LEFT);
        var speedKmh = model.currentSpeed * 3.6;
        dc.drawText(width - 10, y, Graphics.FONT_XTINY, speedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(10, y, Graphics.FONT_XTINY, "Stroke Rate:", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(width - 10, y, Graphics.FONT_XTINY, model.strokeRate.format("%.0f") + " spm", Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(10, y, Graphics.FONT_XTINY, "Total Distance:", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(width - 10, y, Graphics.FONT_XTINY, (model.totalDistance / 1000.0).format("%.2f") + " km", Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(10, y, Graphics.FONT_XTINY, "Total Strokes:", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(width - 10, y, Graphics.FONT_XTINY, model.totalStrokes.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight;

        dc.drawText(10, y, Graphics.FONT_XTINY, "Time:", Graphics.TEXT_JUSTIFY_LEFT);
        var minutes = model.elapsedTime / 60;
        var seconds = model.elapsedTime % 60;
        dc.drawText(width - 10, y, Graphics.FONT_XTINY, minutes.format("%d") + ":" + seconds.format("%02d"), Graphics.TEXT_JUSTIFY_RIGHT);
        y += lineHeight + 10;

        // Current piece
        dc.drawText(centerX, y, Graphics.FONT_XTINY, "--- Current Piece ---", Graphics.TEXT_JUSTIFY_CENTER);
        y += lineHeight;

        if (model.currentPiece != null && model.pieceActive) {
            dc.drawText(10, y, Graphics.FONT_XTINY, "Time:", Graphics.TEXT_JUSTIFY_LEFT);
            var pieceDuration = model.currentPiece.getCurrentDuration();
            var pieceMinutes = pieceDuration / 60;
            var pieceSeconds = pieceDuration % 60;
            dc.drawText(width - 10, y, Graphics.FONT_XTINY, pieceMinutes.format("%d") + ":" + pieceSeconds.format("%02d"), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(10, y, Graphics.FONT_XTINY, "Strokes:", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(width - 10, y, Graphics.FONT_XTINY, model.currentPiece.strokeCount.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(10, y, Graphics.FONT_XTINY, "Distance:", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(width - 10, y, Graphics.FONT_XTINY, (model.currentPiece.distance / 1000.0).format("%.2f") + " km", Graphics.TEXT_JUSTIFY_RIGHT);
            y += lineHeight;

            dc.drawText(10, y, Graphics.FONT_XTINY, "Max Speed:", Graphics.TEXT_JUSTIFY_LEFT);
            var maxSpeedKmh = model.currentPiece.maxSpeed * 3.6;
            dc.drawText(width - 10, y, Graphics.FONT_XTINY, maxSpeedKmh.format("%.1f") + " km/h", Graphics.TEXT_JUSTIFY_RIGHT);
        } else {
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "No active piece", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // View indicator
        dc.drawText(centerX, height - 20, Graphics.FONT_TINY, "UP/DOWN to switch", Graphics.TEXT_JUSTIFY_CENTER);
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
        viewMode = (viewMode + direction) % 3;
        if (viewMode < 0) {
            viewMode = 2;
        }
        WatchUi.requestUpdate();
    }

    // Get the model
    function getModel() {
        return model;
    }
}
