# Configuration Folder

This folder contains configuration files that define the behavior and identity of each node in the lab automation framework. 
These files allow the system to remain modular and maintainable by separating logic from configuration.

---

## Files

### 1. `node_role.txt`
Defines the **machine profile** of the current computer.
This value determines which nodes are launched on this machine and which config block is loaded.

#### Examples:
Valid profiles (must match a key in `manifest.json`):
- `master_computer`
- `carriage_computer`

This file is **not tracked by git** and must be set manually on each machine. Add new profiles here and in
`manifest.json` if new machine roles are added to the system.

---

### 2. `manifest.json`
A central map of all known machine profiles. Each profile defines a list of nodes to launch, with the
path to their folder and their startup script. Parsed by `updater/pull_and_deploy.sh` at deploy time.

#### Structure:
```json
{
  "profile_name": {
    "nodes": [
      {
        "path": "node_folder/",
        "startup_script": "launcher.m or main.py"
      }
    ]
  }
}
```
Profile names are case and space sensitive — must match `node_role.txt` exactly.

---

### 3. `<profile>.json` (machine-local, not git-tracked)
Each machine has a single JSON config file named after its profile (e.g. `master_computer.json`,
`carriage_computer.json`). This file contains all machine-specific settings: broker IP, REST port,
hardware flags, NI-DAQ channel names, and per-node clientIDs.

These files are **gitignored**. Each machine fills in its own copy from the corresponding `.example` template:
- `master_computer.json.example` → copy to `master_computer.json` and fill in real values
- `carriage_computer.json.example` → copy to `carriage_computer.json` and fill in real values

The deploy script reads `node_role.txt` to determine which `<profile>.json` to load, then passes the
relevant section to each node launcher on startup.

---

## Usage Notes

These configuration files are read automatically by `updater/pull_and_deploy.sh`.
Incorrect entries may prevent the node from booting correctly.
