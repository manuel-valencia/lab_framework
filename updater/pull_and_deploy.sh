# This script is the core of the node update mechanism. Every node runs this script to:
# > Pull the latest code from the central repository
# > Determine which code and script it should run (based on its role)
# > Launch that script appropriately (Python or MATLAB)
# > Log all actions and roll back to a safe state if startup fails
# This enables CI/CD-style deployment with per-node modularity and reliability.

#!/bin/bash

cd ~/lab_framework # Navigate to the main project directory (adjust path if needed)

# === LOGGING SETUP ===
LOGFILE="/var/log/lab_framework_update.log"
mkdir -p $(dirname "$LOGFILE") 2>/dev/null # Create log directory if it doesn't exist
exec > >(tee -a "$LOGFILE") 2>&1           # Redirect stdout and stderr to terminal AND log file

echo "==========================================================="
echo "[INFO] $(date) :: STARTING UPDATE"

# === BACKUP CURRENT COMMIT FOR ROLLBACK ===
PREV_COMMIT=$(git rev-parse HEAD)
echo "[INFO] Previous commit: $PREV_COMMIT"

# === GIT SYNC ===
echo "[INFO] Pulling latest code from remote..."
git fetch --all
git reset --hard origin/main
git clean -fd
# !!! Because of force-sync and file removal, developers should test on 'dev' branch, not 'main' !!!

# === ROLE DETECTION ===
ROLE=$(cat config/node_role.txt) # Load this node’s role (e.g., master_node)
SCRIPT=$(jq -r ".$ROLE.startup_script" config/manifest.json) # Lookup script name
PATH_TO_SCRIPT=$(jq -r ".$ROLE.path" config/manifest.json)   # Lookup path to code

echo "[INFO] Detected role: $ROLE"
echo "[INFO] Launching: $PATH_TO_SCRIPT$SCRIPT"

# === SCRIPT EXECUTION ===
EXT="${SCRIPT##*.}" # Extract file extension to determine runtime

if [ "$EXT" = "py" ]; then
  python3 "$PATH_TO_SCRIPT$SCRIPT"
elif [ "$EXT" = "m" ]; then
  matlab -batch "$SCRIPT"
else
  echo "[ERROR] Unknown script type: $EXT"
  echo "[INFO] Rolling back to previous commit..."
  git reset --hard "$PREV_COMMIT"
  echo "[INFO] Rollback complete to $PREV_COMMIT"
  exit 1
fi

# === CHECK FOR FAILURE ===
if [ $? -ne 0 ]; then
  echo "[ERROR] Script failed to launch properly."
  echo "[INFO] Rolling back to previous commit..."
  git reset --hard "$PREV_COMMIT"
  echo "[INFO] Rollback complete to $PREV_COMMIT"
  exit 1
fi

echo "[INFO] Update and startup completed successfully for role: $ROLE"
echo "==========================================================="
