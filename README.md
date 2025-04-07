# Lab Framework

A modular and scalable software system for automating hydrodynamic experiments in 
educational and research settings.

This project enables CI/CD-style deployment and real-time control of experimental 
systems across multiple lab computers (nodes), including the Master Workstation, 
Carriage Laptop, and Wave Maker node.

---

## 🚀 Project Status

**Current Version**: `v0.1`  
**Target Version for Deployment**: `v1.0` (End of Semester)

Major features completed:
- ✅ MQTT-based real-time communication
- ✅ REST-based structured command exchange
- ✅ Deadman switch for heartbeat monitoring

Upcoming features:
- 🔄 Node discovery and introspection
- 🎛️ Calibration and validation routines
- 🧩 Experiment configuration and execution flow
- ⚙️ System-wide logging and diagnostics

---

## 🧠 System Overview

Each lab node pulls its logic from a central Git repository. Node behavior 
is determined by its role (`master_node`, `carriage_node`, or `wavemaker_node`), 
which is set locally. The update process:

1. Pulls the latest code from the `main` branch
2. Detects the role of the node
3. Launches the appropriate startup script (Python or MATLAB)
4. Logs all actions and rolls back on failure

**Communication architecture:**
- **MQTT:** Real-time low-latency messaging (heartbeat, status updates)
- **REST:** Structured API for commands, configuration, and data queries
- Nodes operate independently but synchronize via MQTT and REST protocols.

---

## 📂 Directory Structure

```
lab_framework/
├── common/            # Shared code (e.g., interfaces, MQTT/REST handlers)
├── master_node/       # Master control and experiment orchestration
├── carriage_node/     # Force sensor and data collection logic
├── wavemaker_node/    # Wave paddle and waveform generator logic
├── test_node/         # Development/testing node for new features
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
- `test_node` (development/testing)

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
  },
  "test_node": {
    "path": "test_node/",
    "startup_script": "test_mqtt.py"
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

# REST target node IP (for REST client tests)
REST_TARGET_IP = "192.168.X.Y"
```

Update this file to adjust broker address, heartbeat timings, and REST targets.

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

3. Configure `common/config.py`:
- Set the correct broker IP address
- Adjust heartbeat intervals as needed
- Set REST target node IP for testing

4. Install required dependencies (see below).

5. Run the updater:
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
Install Mosquitto (on broker node, e.g., test_node):
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
- Verify broker node’s IP address.
- Disable or configure firewalls to allow traffic on port 1883 (MQTT) 
  and 5000 (REST).

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
| v0.1    | ✅ MQTT + REST communication     |
| v0.2    | Node registry + discovery        |
| v0.3    | Calibration & validation routines|
| ...     | ...                              |
| v1.0    | Full deployment and validation   |

---

## 👤 Author

Manuel Alejandro Valencia  
MIT Sea Grant | EECS '26
