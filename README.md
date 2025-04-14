# Lab Framework

A modular and scalable software system for automating hydrodynamic experiments in educational and research settings.

This project enables CI/CD-style deployment and real-time control of experimental systems across multiple lab computers (nodes), including the Master Workstation, Carriage Laptop, and Wave Maker node.

---

## 🚀 Project Status

**Current Version**: `v0.4`  
**Target Version for Deployment**: `v1.0` (End of Semester)

Major features completed in v0.4:
- ✅ MQTT-based real-time communication (heartbeats, commands, responses)
- ✅ Dynamic node registry and heartbeat monitoring
- ✅ Structured command protocol and command-response loop
- ✅ Per-node command history stored in registry
- ✅ Global log file for system diagnostics (`logs/command_responses.log`)
- ✅ Robust CI/CD deploy script (`pull_and_deploy.sh`)
- ✅ Clean operator terminal output (heartbeat prints suppressed)

Upcoming features in v0.5:
- 🎛️ Experiment automation loops (multi-command orchestration)
- 🧩 Node validation commands and expanded behaviors
- 📋 Session handling and experiment tracking
- 🗄️ Registry live printouts and operator visibility

---

## 🧠 System Overview

The framework operates across distributed nodes, with the **master node** serving as the control hub.

- **MQTT Broker:** Runs on the master node
- **Master Node:**
  - Monitors node heartbeats and status
  - Sends structured commands to nodes
  - Logs all responses and updates node registry
- **Node (Test Node):**
  - Sends heartbeats
  - Listens for commands (e.g., calibrate)
  - Executes simulated action and responds with structured response

### Communication:
- ✅ MQTT: Heartbeats, commands, responses, future data streaming
- ⚙️ REST: Reserved for future configuration management, logging queries, and operator panels (planned)

---

## 📂 Directory Structure

```
lab_framework/
├── common/              # Shared code (MQTT manager, node registry, config)
├── master_node/         # master node (will be cleaned)
├── test_master_node/    # Test master node with full command-response loop
├── test_node/           # Test node for command simulation
├── carriage_node/       # Force sensor and data collection logic (future)
├── wavemaker_node/      # Wave paddle and waveform generator logic (future)
├── config/              # Per-node settings, manifest, and node registry
├── updater/             # Deployment script for CI/CD
├── logs/                # Global logs (responses, system events)
├── tests/               # Unit and integration tests (planned)
└── README.md            # This file
```

---

## ⚙️ Configuration

### `config/node_role.txt`
Set this manually on each machine to match its role:

```
test_node
```

Valid roles:
- `master_node`
- `carriage_node`
- `wavemaker_node`
- `test_node` (current dev)

> ⚠️ This file is local and not tracked by Git. Set per machine.

---

### `config/manifest.json`
Maps each role to its startup script:

```json
{
  "master_node": {
    "path": "master_node/",
    "startup_script": "main.py"
  },
  "test_master_node": {
    "path": "test_master_node/",
    "startup_script": "test_discovery.py"
  },
  "carriage_node": {
    "path": "carriage_node/",
    "startup_script": "main.py"
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
---

### `common/config.py`
Central constants:
- MQTT broker IP and port
- Heartbeat intervals and timeouts
- Command and response topics
- Command types
- Standard schema fields (command, params, node_id, timestamp, etc.)
- Status values (success, error)
- Optional error codes scaffolded for future use

---

## 🔁 Runtime Behavior

- **Heartbeats:** Sent periodically from each node to master
- **Node Status:** Master tracks node online/offline and recovery
- **Commands:** Master sends commands to nodes dynamically
- **Responses:** Nodes respond with execution status and response time
- **Registry:** Auto-updated with node status and command history
- **Logs:** Global command response log in `logs/command_responses.log`

---

## 🗂️ Logs and Registry

- ✅ **Per-node history:** Tracked in `config/node_registry.json`
- ✅ **Global system log:** All command responses logged in `logs/command_responses.log`
- 🧩 (Planned) Session tracking for full experiment lifecycle

---

## 📦 Setup & Deployment

1. Clone the repository:
```bash
git clone https://github.com/YOUR_REPO/lab_framework.git
cd lab_framework
```

2. Set the node role:
```bash
echo "test_node" > config/node_role.txt
```

3. Install dependencies:
```bash
pip install flask requests paho-mqtt
```

4. Ensure MQTT broker is running on the master node:
```bash
mosquitto -c "path/to/mosquitto.conf"
```

5. Deploy code and run node script:
```bash
bash updater/pull_and_deploy.sh
```

---

## 🧩 System Requirements

- ✅ Python 3.x
- ✅ `paho-mqtt` library
- ✅ Mosquitto MQTT broker
- ✅ Local network for node communication

Optional:
- Future: RESTful API for operator dashboards and configuration management.

---

## 📅 Roadmap

| Version | Milestone                        |
|---------|----------------------------------|
| v0.0    | Project scaffold + deploy logic  |
| v0.1    | ✅ MQTT + REST base communication |
| v0.2    | ✅ Node registry + discovery     |
| v0.3    | ✅ Proactive heartbeats + live registry |
| v0.4    | ✅ Full command-response loop + logging |
| v0.5    | Experiment automation loop |
| v1.0    | Full deployment and operator system |

---

## 👤 Author

Manuel Alejandro Valencia  
MIT Sea Grant | EECS '26

---
