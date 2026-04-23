#!/bin/bash

# =============================================================================
# pull_and_deploy.sh
#
# Description:
# - Core deployment script for the Lab Framework.
# - Pulls latest code from the current Git branch.
# - Preserves node_role.txt and machine config files (gitignored).
# - Uses Python to parse manifest.json for the current machine profile.
# - Launches all nodes defined for this machine profile.
#   MATLAB nodes are launched in the background; the Python node runs in the
#   foreground so this script stays alive as the process supervisor.
# - On health-check failure, rolls back to the previous commit.
#
# Usage:
#   bash updater/pull_and_deploy.sh
#
# =============================================================================

echo "[INFO] $(date) :: STARTING UPDATE"

# Preserve the current commit hash in case rollback is needed
PREVIOUS_COMMIT=$(git rev-parse HEAD)
echo "[INFO] Previous commit: $PREVIOUS_COMMIT"

# Detect current branch dynamically
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "[INFO] Pulling latest code from branch: $CURRENT_BRANCH"

git fetch --all
git reset --hard origin/$CURRENT_BRANCH

# --- Health check ---
# Run a basic Python import/syntax validation to catch broken code before launch.
# Add more checks to updater/health_check.py as the codebase grows.
echo "[INFO] Running health check..."
python3 updater/health_check.py
if [ $? -ne 0 ]; then
  echo "[ERROR] Health check failed. Rolling back to previous commit: $PREVIOUS_COMMIT"
  git reset --hard $PREVIOUS_COMMIT
  echo "[INFO] Rollback complete. Running previous code."
fi

# --- Read machine profile ---
if [ ! -f config/node_role.txt ]; then
  echo "[ERROR] config/node_role.txt not found! Cannot determine machine profile."
  exit 1
fi

PROFILE=$(cat config/node_role.txt | tr -d '[:space:]')
echo "[INFO] Machine profile: $PROFILE"

# --- Validate machine config file exists ---
CONFIG_FILE="config/${PROFILE}.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Machine config file not found: $CONFIG_FILE"
  echo "[INFO] Copy config/${PROFILE}.json.example to config/${PROFILE}.json and fill in your settings."
  exit 1
fi

# --- Parse node list for this profile ---
NODE_COUNT=$(python3 -c "
import json, sys
manifest = json.load(open('config/manifest.json'))
if '$PROFILE' not in manifest:
    print(0)
    sys.exit(1)
print(len(manifest['$PROFILE']['nodes']))
")

if [ "$NODE_COUNT" -eq 0 ] 2>/dev/null; then
  echo "[ERROR] Profile '$PROFILE' not found in config/manifest.json or has no nodes."
  exit 1
fi

echo "[INFO] Launching $NODE_COUNT node(s) for profile: $PROFILE"

# --- Track background PIDs for cleanup ---
BG_PIDS=()

# Graceful shutdown: stop all background nodes when this script exits
cleanup() {
  echo "[INFO] Shutting down background nodes..."
  for PID in "${BG_PIDS[@]}"; do
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      echo "[INFO] Stopped PID $PID"
    fi
  done
}
trap cleanup EXIT

# --- Launch each node ---
for i in $(seq 0 $((NODE_COUNT - 1))); do
  SCRIPT=$(python3 -c "import json; n=json.load(open('config/manifest.json'))['$PROFILE']['nodes'][$i]; print(n['startup_script'])")
  PATH_TO_SCRIPT=$(python3 -c "import json; n=json.load(open('config/manifest.json'))['$PROFILE']['nodes'][$i]; print(n['path'])")
  FULL_PATH="${PATH_TO_SCRIPT}${SCRIPT}"
  EXT="${SCRIPT##*.}"

  if [ "$EXT" = "m" ]; then
    # MATLAB nodes launch in background; pass profile and config file path as arguments
    echo "[INFO] Launching MATLAB node (background): $FULL_PATH"
    matlab -batch "${SCRIPT%.m}('$CONFIG_FILE', '$PROFILE')" &
    BG_PIDS+=($!)
    echo "[INFO] MATLAB node PID: ${BG_PIDS[-1]}"
    echo "[INFO] Waiting 10s for MATLAB to connect to MQTT broker before continuing..."
    sleep 10

  elif [ "$EXT" = "py" ]; then
    # Python node launches in foreground — keeps this script alive
    echo "[INFO] Launching Python node (foreground): $FULL_PATH"
    python3 "$FULL_PATH" "$CONFIG_FILE" "$PROFILE"

  else
    echo "[ERROR] Unknown script type for: $FULL_PATH"
    exit 1
  fi
done

echo "[INFO] All nodes launched. Waiting for background nodes to finish..."
wait
