#!/bin/bash

# =============================================================================
# pull_and_deploy.sh
#
# Description:
# - Core deployment script for the Lab Framework.
# - Pulls latest code from the current Git branch.
# - Preserves node_role.txt and environment-specific files.
# - Uses Python (not jq) to parse manifest.json.
# - Launches the appropriate node script based on config.
#
# Usage:
# bash updater/pull_and_deploy.sh
#
# =============================================================================

echo "[INFO] $(date) :: STARTING UPDATE"

# Preserve the current commit hash in case rollback is needed
PREVIOUS_COMMIT=$(git rev-parse HEAD)
echo "[INFO] Previous commit: $PREVIOUS_COMMIT"

echo "[INFO] Pulling latest code from remote..."
git fetch --all

# Detect current branch dynamically
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "[INFO] Pulling latest code from branch: $CURRENT_BRANCH"

# Pull latest and hard reset to remote branch
git reset --hard origin/$CURRENT_BRANCH

# Clean untracked files, but preserve node_role.txt
#git clean -fd -e config/node_role.txt

# Check node role file exists
if [ ! -f config/node_role.txt ]; then
  echo "[ERROR] config/node_role.txt not found! Cannot determine node role."
  echo "[INFO] Rolling back to previous commit..."
  git reset --hard $PREVIOUS_COMMIT
  exit 1
fi

# Read node role
ROLE=$(cat config/node_role.txt)
echo "[INFO] Detected role: $ROLE"

# Use Python to parse manifest.json and get the script path and name
SCRIPT=$(python3 -c "import json; print(json.load(open('config/manifest.json'))['$ROLE']['startup_script'])")
PATH_TO_SCRIPT=$(python3 -c "import json; print(json.load(open('config/manifest.json'))['$ROLE']['path'])")

echo "[INFO] Launching: $PATH_TO_SCRIPT$SCRIPT"

# Determine script extension and launch accordingly
EXT="${SCRIPT##*.}"
if [ "$EXT" = "py" ]; then
  python3 "$PATH_TO_SCRIPT$SCRIPT"
elif [ "$EXT" = "m" ]; then
  matlab -batch "$SCRIPT"
else
  echo "[ERROR] Unknown script type: $EXT"
  echo "[INFO] Rolling back to previous commit..."
  git reset --hard $PREVIOUS_COMMIT
  exit 1
fi
