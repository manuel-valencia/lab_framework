# Lab Framework

A modular and scalable software system for automating hydrodynamic experiments in educational and research settings.

This project enables CI/CD-style deployment and real-time control of experimental systems across multiple lab computers (nodes), including the Master Workstation, Carriage Laptop, and Wave Maker node.

---

## 🚀 Project Status

**Current Version**: `v0.0`  
**Target Version for Deployment**: `v1.0` (End of Semester)

This is the initial scaffold. Major features like MQTT/REST communication, node discovery, calibration routines, and experiment execution will follow in upcoming versions.

---

## 🧠 System Overview

Each lab node pulls its logic from a central Git repository. Node behavior is determined by its role (`master_node`, `carriage_node`, or `wavemaker_node`), which is set locally. The update process:

1. Pulls the latest code from the `main` branch
2. Detects the role of the node
3. Launches the appropriate startup script (Python or MATLAB)
4. Logs all actions and rolls back on failure

---

## 📂 Directory Structure

```
lab_framework/
├── common/            # Shared code (e.g., interfaces, MQTT handlers)
├── master_node/       # Master control and experiment orchestration
├── carriage_node/     # Force sensor and data collection logic
├── wavemaker_node/    # Wave paddle and waveform generator logic
├── config/            # Per-node settings and startup map
├── updater/           # Deployment script for CI/CD
├── tests/             # Unit and integration tests (planned)
└── README.md          # This file
```

---

## ⚙️ Configuration

### `config/node_role.txt`
Manually set this on each machine to match its hardware role:

```
carriage_node
```

Valid roles:
- `master_node`
- `carriage_node`
- `wavemaker_node`

---

### `config/manifest.json`

Maps each node role to the folder and startup script to execute:

```json
{
  "carriage_node": {
    "path": "carriage_node/",
    "startup_script": "main.py"
  },
  "master_node": {
    "path": "master_node/",
    "startup_script": "main.py"
  },
  "wavemaker_node": {
    "path": "wavemaker_node/",
    "startup_script": "main.py"
  }
}
```

See `config/README.md` for a full explanation.

---

## 🔁 Updating and Deploying Code

Each node uses the following update script:

```bash
bash updater/pull_and_deploy.sh
```

This script will:
- Pull the latest `main` branch
- Clean all untracked files
- Lookup the node's role
- Launch the corresponding script
- Log activity to `/var/log/lab_framework_update.log`
- Roll back to the previous Git commit if the script fails

---

## 📦 Local Setup (Dev or Prod Node)

1. Clone the repository:
```bash
git clone https://github.com/YOUR_REPO/lab_framework.git
cd lab_framework
```

2. Set the node role:
```bash
echo "carriage_node" > config/node_role.txt
```

3. Run the updater:
```bash
bash updater/pull_and_deploy.sh
```

---

## 🔧 Developer Notes

- Always test your code on a separate `dev` branch.
- Production updates should be pushed to `main` after validation.
- Code should be modular per-node and share logic through the `common/` folder.
- Document all changes and add test coverage in `/tests`.

---

## 📅 Roadmap

| Version | Milestone                        |
|---------|----------------------------------|
| v0.0    | Project scaffold + deploy logic  |
| v0.1    | MQTT + REST communication        |
| v0.2    | Node registry + discovery        |
| v0.3    | Calibration & validation routines|
| ...     | ...                              |
| v1.0    | Full deployment and validation   |

---

## 👤 Author

Manuel Alejandro Valencia  
MIT Sea Grant | EECS '26
