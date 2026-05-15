# updater/

Deployment automation for the Lab Framework.

---

## Files

| File | Purpose |
|------|---------|
| `pull_and_deploy.sh` | Core launcher — pulls latest code, runs health check, starts all nodes |
| `health_check.py` | Pre-launch sanity checks — exits non-zero to trigger rollback on failure |

---

## pull_and_deploy.sh

### What it does (each loop iteration)
1. Kills any nodes left running from the previous iteration
2. `git fetch --all && git reset --hard origin/<branch>` — overwrites local tree with latest remote
3. Runs `health_check.py` — on failure, rolls back to the previous commit and continues with old code
4. Optionally launches Mosquitto (`launchMosquitto: true` in `manifest.json`)
5. Launches all nodes listed under the machine profile in `manifest.json`
6. Waits on the **lead process** (Python preferred; MATLAB fallback):
   - exit `0`  → clean shutdown, launcher exits
   - exit `42` → update requested, loop repeats (re-pull + relaunch)
   - other     → unexpected crash, launcher exits with warning

### Usage
```bash
# Run from repo root
bash updater/pull_and_deploy.sh
```

### Prerequisites
- `config/node_role.txt` must exist and contain a valid profile name (e.g. `master_computer`)
- `config/<profile>.json` must exist (gitignored — copy from `config/templates/` and fill in)
- Python must be on PATH as `python` (not `python3` — Windows Git Bash convention)
- Mosquitto system service must be **disabled** if `launchMosquitto: true` to avoid port conflicts:
  ```powershell
  net stop mosquitto
  sc config mosquitto start= disabled
  ```

### Mosquitto port conflict warning
The Windows Mosquitto system service binds port 1883 on all interfaces at startup.
If it is running, a manual `mosquitto -c network/mosquitto.conf` launch will fail to bind 1883
and will silently skip the WebSocket listener on 9001. The browser then connects to an orphaned
WebSocket broker that never receives any node messages. Symptom: web UI shows "Connected to broker"
but System tab shows no nodes and the live data chart never updates.

Always verify both ports are owned by the same PID:
```powershell
netstat -ano | findstr ":1883 "
netstat -ano | findstr ":9001 "
```

---

## health_check.py

Runs automatically before each node launch. Checks:
1. `paho-mqtt` and `requests` are importable
2. `config/manifest.json` and `config/node_role.txt` exist
3. Both files are valid JSON / readable
4. `node_role.txt` references a profile that exists in `manifest.json`
5. The machine config file (`config/<profile>.json`) exists and is valid JSON

Add new checks at the bottom of the file as the codebase grows.

---

## ⚠ Known issue: `git reset --hard` discards uncommitted local changes

`pull_and_deploy.sh` uses `git reset --hard origin/<branch>` to ensure a clean deployment.
**This will silently wipe any uncommitted local edits**, including in-progress bug fixes.

### TODO: add git stash around the reset

The block below should be added around the reset in `pull_and_deploy.sh` once tested.
It stashes local changes before pulling and restores them afterwards so local work survives
a deploy loop restart:

```bash
# --- Stash local changes before reset (preserves in-progress work) ---
# STASH_MSG="pre-deploy-stash-$(date +%s)"
# HAS_CHANGES=$(git status --porcelain)
# if [ -n "$HAS_CHANGES" ]; then
#   echo "[INFO] Stashing local changes as '$STASH_MSG'..."
#   git stash push -m "$STASH_MSG"
# fi

git fetch --all
git reset --hard origin/$CURRENT_BRANCH

# --- Restore stash if one was created ---
# if [ -n "$HAS_CHANGES" ]; then
#   echo "[INFO] Restoring stashed changes..."
#   git stash pop
#   if [ $? -ne 0 ]; then
#     echo "[WARN] Stash pop had conflicts — resolve manually with: git stash show -p"
#   fi
# fi
```

> **Note:** stash + reset is only useful during active development.
> In production (where the working tree should always match the remote) this is unnecessary.
> Enable it per-machine or gate it on an environment variable if needed.
