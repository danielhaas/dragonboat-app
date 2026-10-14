#!/usr/bin/env bash
# Replays a recorded session live in the (already running) CIQ simulator.
# Start the simulator first with ./run_sim.sh.
#
#   ./run_replay.sh data/2026-10-11-08-48-01.fit [--skip SECONDS] [--max SECONDS]
set -euo pipefail
cd "$(dirname "$0")"

FIT="${1:?usage: $0 <file.fit> [--skip S] [--max S]}"; shift
DEVICE="${DEVICE:-fenix6}"
SDK="$HOME/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-8.3.0-2025-09-22-5813687a0/bin"

python3 make_replay_data.py "$FIT" "$@"
"$SDK/monkeyc" -d "$DEVICE" -f "monkey.jungle;sim.jungle" \
  -o bin/dragonboat-replay.prg -y "$HOME/.Garmin/ConnectIQ/developer_key.der" \
  -w 2>&1 | grep --line-buffered -v '^WARNING'
toolbox run -c f39-ciq bash -lc "$SDK/monkeydo '$PWD/bin/dragonboat-replay.prg' $DEVICE" \
  2>&1 | grep --line-buffered -v 'Timer interval'
