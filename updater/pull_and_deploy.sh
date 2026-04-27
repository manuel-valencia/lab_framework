#!/bin/bash

# =============================================================================
# pull_and_deploy.sh
#
# Description:
# - Core deployment script for the Lab Framework.
# - Pulls latest code from the current Git branch on every launch or update.
# - Preserves node_role.txt and machine config files (gitignored).
# - Uses Python to parse manifest.json for the current machine profile.
# - Launches Mosquitto broker (from network/mosquitto.conf) then all nodes.
#   All processes run as background processes; a single "lead" process is
#   tracked whose exit code drives the self-update loop.
# - On health-check failure, rolls back to the previous commit.
#
# Mosquitto:
#   Launched directly from network/mosquitto.conf so config is versioned in
#   git and deployed automatically. The system-installed Mosquitto Windows
#   service should be disabled to avoid port conflicts.
#
# Self-update loop:
#   Nodes can request a code update over MQTT by sending {"cmd":"Update"} to
#   their /cmd topic (only accepted when the node is in IDLE state). The node
#   publishes {"state":"UPDATING"}, shuts down, and exits with code 42.
#   This script detects exit code 42, kills all remaining background nodes,
#   re-pulls the latest code, and relaunches — no remote login required.
#
# Exit code convention (used by node processes):
#   0   — clean shutdown → launcher exits normally
#   42  — update requested → re-pull and relaunch automatically
#   other — unexpected crash → launcher exits with a warning
#
# Usage:
#   bash updater/pull_and_deploy.sh
#
# =============================================================================

UPDATE_EXIT_CODE=42

echo "[INFO] $(date) :: Deployment launcher started"

# Detect current branch once — does not change between relaunches
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "[INFO] Branch: $CURRENT_BRANCH"

# --- Read machine profile once (survives relaunches) ---
if [ ! -f config/node_role.txt ]; then
  echo "[ERROR] config/node_role.txt not found! Cannot determine machine profile."
  exit 1
fi

PROFILE=$(cat config/node_role.txt | tr -d '[:space:]')
echo "[INFO] Machine profile: $PROFILE"

CONFIG_FILE="config/${PROFILE}.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Machine config file not found: $CONFIG_FILE"
  echo "[INFO] Copy config/${PROFILE}.json.example to config/${PROFILE}.json and fill in your settings."
  exit 1
fi

# --- Parse node count once ---
NODE_COUNT=$(python3 -c "
import json, sys
manifest = json.load(open('config/manifest.json'))
if '$PROFILE' not in manifest:
    print(0)
    sys.exit(1)
print(len(manifest['$PROFILE']['nodes']))
")

if [ "$NODE_COUNT" -eq 0 ] 2>/dev/null; then
  echo "[ERROR] Profile '$PROFILE' not found in manifest.json or has no nodes."
  exit 1
fi

# --- Background PID tracking ---
BG_PIDS=()
MOSQUITTO_PID=""

# Stop all tracked background processes (called between loop iterations and on EXIT)
kill_background_nodes() {
  for PID in "${BG_PIDS[@]}"; do
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      echo "[INFO] Stopped background node PID $PID"
    fi
  done
  BG_PIDS=()
  # Kill Mosquitto last so nodes can disconnect cleanly
  if [ -n "$MOSQUITTO_PID" ] && kill -0 "$MOSQUITTO_PID" 2>/dev/null; then
    kill "$MOSQUITTO_PID"
    echo "[INFO] Stopped Mosquitto (PID $MOSQUITTO_PID)"
    MOSQUITTO_PID=""
  fi
}
trap kill_background_nodes EXIT

# =============================================================================
# DEPLOY LOOP
#
# Each iteration:
#   1. Kill any nodes left over from the previous iteration
#   2. git pull + health check (with rollback on failure)
#   3. Launch all nodes in background; elect a "lead" PID
#      - Python node takes the lead role if present (preferred for signaling)
#      - Otherwise the first (and typically only) MATLAB node is the lead
#   4. wait for the lead PID and capture its exit code
#   5. exit code 42  → re-pull and relaunch (loop continues)
#      exit code 0   → clean shutdown (break)
#      anything else → unexpected exit (break with warning)
# =============================================================================
while true; do

  # --- Step 1: Kill lingering nodes from previous iteration ---
  kill_background_nodes

  # --- Step 2: Pull latest code ---
  PREVIOUS_COMMIT=$(git rev-parse HEAD)
  echo "[INFO] $(date) :: Pulling latest code (previous: ${PREVIOUS_COMMIT:0:8})"
  git fetch --all
  git reset --hard origin/$CURRENT_BRANCH

  # --- Step 3: Health check ---
  echo "[INFO] Running health check..."
  python3 updater/health_check.py
  if [ $? -ne 0 ]; then
    echo "[ERROR] Health check failed. Rolling back to ${PREVIOUS_COMMIT:0:8}"
    git reset --hard $PREVIOUS_COMMIT
    echo "[INFO] Rollback complete. Launching previous code."
  fi

  # --- Step 3b: Launch Mosquitto broker (master computer only) ---
  # Mosquitto is launched from the versioned config in network/mosquitto.conf.
  # This manages both the standard MQTT listener (:1883) and the WebSocket
  # listener (:9001) needed by the web UI.
  # The carriage computer connects to the master's broker and does not run
  # its own — controlled by "launchMosquitto" in manifest.json.
  # NOTE: disable the system Mosquitto Windows service to avoid port conflicts:
  #   sc config mosquitto start= disabled && net stop mosquitto
  LAUNCH_MOSQUITTO=$(python3 -c "import json; m=json.load(open('config/manifest.json')); print(str(m.get('$PROFILE',{}).get('launchMosquitto',False)).lower())")
  if [ "$LAUNCH_MOSQUITTO" = "true" ]; then
    if kill -0 "$MOSQUITTO_PID" 2>/dev/null; then
      echo "[INFO] Mosquitto already running (PID $MOSQUITTO_PID), skipping relaunch."
    else
      echo "[INFO] Starting Mosquitto broker from network/mosquitto.conf..."
      mosquitto -c network/mosquitto.conf &
      MOSQUITTO_PID=$!
      echo "[INFO] Mosquitto PID: $MOSQUITTO_PID"
      sleep 2   # Give broker time to bind ports before nodes connect
    fi
  else
    echo "[INFO] launchMosquitto=false for profile '$PROFILE' — skipping broker launch."
  fi

  # --- Step 4: Launch nodes ---
  echo "[INFO] Launching $NODE_COUNT node(s) for profile: $PROFILE"
  LEAD_PID=""

  for i in $(seq 0 $((NODE_COUNT - 1))); do
    SCRIPT=$(python3 -c "import json; n=json.load(open('config/manifest.json'))['$PROFILE']['nodes'][$i]; print(n['startup_script'])")
    PATH_TO_SCRIPT=$(python3 -c "import json; n=json.load(open('config/manifest.json'))['$PROFILE']['nodes'][$i]; print(n['path'])")
    FULL_PATH="${PATH_TO_SCRIPT}${SCRIPT}"
    EXT="${SCRIPT##*.}"

    if [ "$EXT" = "m" ]; then
      echo "[INFO] Launching MATLAB node (background): $FULL_PATH"
      matlab -batch "addpath('$PATH_TO_SCRIPT'); ${SCRIPT%.m}('$CONFIG_FILE', '$PROFILE')" &
      MATLAB_PID=$!
      BG_PIDS+=($MATLAB_PID)
      echo "[INFO] MATLAB node PID: $MATLAB_PID"
      # Elect as lead only if no Python node has claimed the role yet
      if [ -z "$LEAD_PID" ]; then
        LEAD_PID=$MATLAB_PID
      fi
      echo "[INFO] Waiting 10s for MATLAB to connect to MQTT broker..."
      sleep 10

    elif [ "$EXT" = "py" ]; then
      echo "[INFO] Launching Python node (background): $FULL_PATH"
      python3 "$FULL_PATH" "$CONFIG_FILE" "$PROFILE" &
      PYTHON_PID=$!
      BG_PIDS+=($PYTHON_PID)
      echo "[INFO] Python node PID: $PYTHON_PID"
      # Python always wins the lead role (preferred for exit-code signaling)
      LEAD_PID=$PYTHON_PID

    else
      echo "[ERROR] Unknown script type: $FULL_PATH"
      exit 1
    fi
  done

  if [ -z "$LEAD_PID" ]; then
    echo "[ERROR] No lead process identified. Exiting."
    exit 1
  fi

  echo "[INFO] All nodes launched. Lead PID: $LEAD_PID. Waiting for exit..."

  # --- Step 5: Wait for lead process ---
  wait $LEAD_PID
  LEAD_EXIT=$?

  echo "[INFO] Lead process (PID $LEAD_PID) exited with code $LEAD_EXIT"

  if [ "$LEAD_EXIT" -eq "$UPDATE_EXIT_CODE" ]; then
    echo "[INFO] Update requested by node. Re-pulling code and relaunching..."
    # Loop continues; kill_background_nodes runs at the top of the next iteration
  elif [ "$LEAD_EXIT" -eq 0 ]; then
    echo "[INFO] Node shut down cleanly. Exiting launcher."
    break
  else
    echo "[WARN] Node exited with unexpected code $LEAD_EXIT. Exiting launcher."
    break
  fi

done

echo "[INFO] $(date) :: Deployment launcher stopped."
