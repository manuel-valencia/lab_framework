
# Lab Framework

A modular and scalable software system for automating hydrodynamic experiments in educational and research settings.

This project enables CI/CD-style deployment and real-time control of experimental systems across multiple lab computers (nodes), including the Master Workstation, Carriage Laptop, and Wave Maker node.

---

## 🚀 Project Status

**Current Version**: `v0.3`  
**Target Version for Deployment**: `v1.0` (End of Semester)

Major features completed:
- ✅ MQTT-based real-time communication
- ✅ REST-based structured command exchange
- ✅ Deadman switch for heartbeat monitoring
- ✅ Dynamic node discovery and registry management
- ✅ Node role-based auto-deploy via pull_and_deploy.sh (Python-based, no jq dependency)

Upcoming features:
- 🎛️ Calibration and validation routines
- 🧩 Experiment configuration and execution flow
- ⚙️ System-wide logging and diagnostics
- 🗄️ Persistent configuration management

---

## 🧠 System Overview

Each lab node pulls its logic from a central Git repository. Node behavior is determined by its role (`master_node`, `carriage_node`, `wavemaker_node`, or `test_node`), which is set locally. The update process:

1. Pulls the latest code from the current Git branch
2. Detects the role of the node
3. Launches the appropriate startup script (Python or MATLAB)
4. Logs all actions and rolls back on failure

**Communication architecture:**
- **MQTT:** Real-time low-latency messaging (heartbeat, status updates, node discovery)
  - Nodes proactively announce their status.
  - Master node maintains a live node registry.
  - Fully dynamic: nodes can join, leave, and rejoin the network without manual reconfiguration.

- **REST:** Structured API for commands, configuration, and data queries
  - Not used for discovery in v0.3, reserved for future command/control.

---

## 📂 Directory Structure

```
lab_framework/
├── common/              # Shared code (MQTT manager, node registry, config)
├── master_node/         # Master control and experiment orchestration (legacy)
├── test_master_node/    # Test master node for discovery and registry flow
├── test_node/           # Development/testing node with proactive heartbeats
├── carriage_node/       # Force sensor and data collection logic (future)
├── wavemaker_node/      # Wave paddle and waveform generator logic (future)
├── config/              # Per-node settings, manifest, and node registry
├── updater/             # Deployment script for CI/CD
├── tests/               # Unit and integration tests (planned)
└── README.md            # This file
```

---

## ⚙️ Configuration

### `config/node_role.txt`
Manually set this on each machine to match its hardware role:

```
master_node
```

Valid roles:
- `master_node`
- `carriage_node`
- `wavemaker_node`
- `test_node` (development/testing)

> 🔧 **Important:** This file is local and not tracked by Git. You must set it manually per node.

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
    "path": "test_master_node/",
    "startup_script": "test_discovery.py"
  },
  "wavemaker_node": {
    "path": "wavemaker_node/",
    "startup_script": "main.py"
  },
  "test_node": {
    "path": "test_node/",
    "startup_script": "test_discovery.py"
  }
}
```

See `config/README.md` for a full explanation.

---

### `common/config.py`

Centralized settings for node communication and behavior:

```python
# MQTT broker settings
MQTT_BROKER_IP = "192.168.X.Y"
MQTT_PORT = 1883

# Heartbeat settings (in seconds)
HEARTBEAT_PUBLISH_INTERVAL = 0.1
HEARTBEAT_TIMEOUT = 0.2

# Node registry timeout (offline threshold, in seconds)
NODE_TIMEOUT_SECONDS = 5
```

Update this file to adjust broker address, heartbeat timings, and timeouts.

---

## 🔁 Updating and Deploying Code

Each node uses the following update script:

```bash
bash updater/pull_and_deploy.sh
```

This script will:
- Pull the latest branch (auto-detects current working branch)
- Clean untracked files, but **preserves `config/node_role.txt`**
- Lookup the node's role via `node_role.txt`
- Parse `manifest.json` using Python (no jq dependency)
- Launch the corresponding script based on node role
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
echo "test_node" > config/node_role.txt
```

3. Configure `common/config.py`:
- Set the correct broker IP address (use the master node IP)
- Adjust heartbeat intervals and timeouts as needed

4. Install required dependencies:
```bash
pip install flask requests paho-mqtt
```

5. Ensure the MQTT broker is running on the master node:
```bash
mosquitto -c "path/to/mosquitto.conf"
```

6. Run the updater:
```bash
bash updater/pull_and_deploy.sh
```

---

## 🧩 System Requirements & Setup Checklist

### Python Dependencies:
```bash
pip install flask requests paho-mqtt
```

### MQTT Broker:
Install Mosquitto (broker runs on master node):
```bash
# On Ubuntu:
sudo apt-get install mosquitto mosquitto-clients

# On Windows:
Download from https://mosquitto.org/download/ and run:
mosquitto -c "path\to\mosquitto.conf"
```

### Mosquitto Configuration (minimum):
```
listener 1883
allow_anonymous true
```

### Network:
- Ensure all nodes are on the same local network.
- Use a tool (e.g., IP scanner) or configure nodes to find the master node IP.
- Disable or configure firewalls to allow traffic on port 1883 (MQTT).

---

## 🔧 Developer Notes

- Always work in the `dev` branch until validated.
- Production updates should be pushed to `main` only after full testing.
- Code is modular: per-node logic lives in its respective folder.
- Node registry is auto-saved in `config/node_registry.json`.
- All configuration lives in `config/` or `common/config.py`.
- `pull_and_deploy.sh` auto-launches the correct script per node.

---

## 📅 Roadmap

| Version | Milestone                        |
|---------|----------------------------------|
| v0.0    | Project scaffold + deploy logic  |
| v0.1    | ✅ MQTT + REST communication     |
| v0.2    | ✅ Node registry + discovery     |
| v0.3    | ✅ Proactive heartbeats + live registry |
| v0.4    | Calibration & validation routines|
| ...     | ...                              |
| v1.0    | Full deployment and validation   |

---

## 👤 Author

Manuel Alejandro Valencia  
MIT Sea Grant | EECS '26
