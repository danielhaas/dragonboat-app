#!/usr/bin/env bash
# Launches the Connect IQ simulator inside the f39-ciq toolbox and
# pushes bin/dragonboat.prg to it via monkeydo. Leaves both running.
#
# Prereqs (one-time setup, already done):
#   toolbox create -r 39 -c f39-ciq --assumeyes
#   toolbox run -c f39-ciq sudo dnf install -y webkit2gtk4.0 java-17-openjdk-headless
#   toolbox run -c f39-ciq sudo ln -sf /usr/lib64/libjpeg.so.62 /usr/lib64/libjpeg.so.8
set -euo pipefail

PRG="${1:-$HOME/code/dragonboat-app/bin/dragonboat.prg}"
DEVICE="${2:-fenix6}"
SDK="$HOME/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-8.3.0-2025-09-22-5813687a0/bin"

toolbox run -c f39-ciq bash -lc "
  $SDK/simulator > /tmp/sim.log 2>&1 &
  SIM_PID=\$!
  echo \"simulator pid \$SIM_PID\"
  sleep 5
  $SDK/monkeydo '$PRG' '$DEVICE' > /tmp/monkeydo.log 2>&1 &
  MD_PID=\$!
  echo \"monkeydo pid \$MD_PID\"
  wait \$SIM_PID
"
