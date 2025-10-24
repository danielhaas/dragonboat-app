# DragonBoat - Garmin Watch App for Dragon Boating

A specialized Connect IQ app for dragon boating that tracks speed, stroke rate, distance, and automatically detects training pieces.

## Features

### Overall Session Tracking
- Real-time speed (km/h)
- Average speed
- Stroke rate (strokes per minute)
- Heart rate (BPM)
- Total distance traveled
- Total strokes
- Elapsed time

### Automatic Piece Detection
- Pieces are defined by paddling activity (first stroke to last stroke)
- Automatically ends piece 10 seconds after the last stroke
- Tracks individual pieces separately
- Each piece records:
  - Time duration (from first to last stroke)
  - Stroke count
  - Distance
  - Maximum speed

### Stroke Detection
- Uses accelerometer to detect paddle strokes
- Sensitive stroke detection with minimum threshold to avoid false positives
- Real-time stroke rate calculation

### Multiple View Modes
Switch between four display modes using UP/DOWN buttons:
1. **Overall View**: Speed, stroke rate, and total distance
2. **Current Piece View**: Stats for the current training piece
3. **All Metrics View**: Comprehensive display of all data
4. **Optimized Grid View** (Default): Kayaking-style layout with:
   - Color-coded boxes for SPM (green) and HR (blue)
   - Current and average speed
   - Time and distance
   - Piece counter at bottom

### Activity Recording
- Saves activities to Garmin Connect
- Syncs automatically with your Garmin account
- Activity type: Rowing (Generic)

## Installation

### Prerequisites
1. Install [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
2. Install [Visual Studio Code](https://code.visualstudio.com/) with Monkey C extension (recommended)

### Building the App

#### Using Visual Studio Code:
1. Open the `dragonboat-app` folder in VS Code
2. Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on Mac)
3. Select "Monkey C: Build for Device"
4. Choose "fenix6xpro" as the target device

#### Using Command Line:
```bash
cd dragonboat-app
monkeyc -d fenix6xpro -f monkey.jungle -o dragonboat.prg -y /path/to/developer_key
```

### Installing on Your Watch

#### Via USB:
1. Connect your Fenix 6X to your computer
2. Copy the `.prg` file to `GARMIN/Apps/` folder on your watch
3. Disconnect and the app will appear in your apps list

#### Via Connect IQ Store (for distribution):
1. Package and submit to the Connect IQ Store
2. Download directly to your watch from the store

## Usage

### Starting the App
1. On your Fenix 6X, press the UP button to open the app launcher
2. Scroll to find "DragonBoat" and press START to launch

### During Activity
- **UP/DOWN buttons**: Switch between view modes
- **Activity auto-starts**: GPS and accelerometer tracking begins immediately
- **Pieces auto-detect**: First stroke starts a piece; piece ends 10 seconds after last stroke

### Ending Activity
- **Press BACK button**: Shows confirmation to save or discard
- **Select YES**: Saves activity to Garmin Connect
- **Select NO**: Discards activity

## Technical Details

### Stroke Detection
- Uses 3-axis accelerometer at 25 Hz sampling rate
- Detects stroke based on acceleration magnitude change
- 200ms cooldown between strokes to prevent double-counting
- Threshold: 1.5g acceleration change

### Piece Detection
- Stroke-based detection: pieces defined by active paddling
- First stroke starts a new piece
- Piece ends 10 seconds after the last detected stroke
- Automatically tracks time from first to last stroke
- New piece starts automatically when paddling resumes

### GPS Tracking
- Continuous GPS mode for accurate distance and speed
- Distance calculated using Haversine formula
- Speed provided directly from GPS

## Customization

### Adjusting Sensitivity
Edit `DragonBoatModel.mc` to modify:
- `ACCEL_THRESHOLD`: Stroke detection sensitivity (default: 1.5g)
- `STROKE_COOLDOWN`: Minimum time between strokes (default: 200ms)
- `PIECE_END_DURATION`: Time after last stroke to end piece (default: 10000ms / 10 seconds)

### Changing Display
Edit `DragonBoatView.mc` to customize:
- Layouts and font sizes
- Data fields shown
- View modes

## Target Device
- Garmin Fenix 6 series (Fenix 6, 6S, 6X)

## Permissions Required
- **Positioning**: GPS for speed and distance
- **Sensor**: Accelerometer for stroke detection, heart rate monitoring
- **FitContributor**: Save activities to Garmin Connect

## License
This app is provided as-is for personal use in dragon boating training.
