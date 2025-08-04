# Lab Framework

A modular and scalable software system for automating hydrodynamic experiments in educational and research settings.

This project enables CI/CD-style deployment and real-time control of experimental systems across multiple lab computers (nodes), including the Master Workstation, Carriage Laptop, and Wave Maker node.

---

## 🚀 Project Status

**Current Version**: `v0.5`  
**Target Version for Deployment**: `v1.0` (End of Semester)

Major features completed in v0.5:
- ✅ MQTT-based real-time communication (heartbeats, commands, responses)
- ✅ REST API server for large data transfers and health monitoring
- ✅ Complete Python framework (`pythonCommon/`) with FSM-based node control
- ✅ MATLAB framework (`matlabCommon/`) for legacy system integration
- ✅ Comprehensive test suite (58+ tests) validating all core functionality
- ✅ Node scaffolding templates for rapid development (`node_scafolding_python/`, `node_scafolding_matlab/`)
- ✅ Advanced state management with 11-state FSM (BOOT, IDLE, CALIBRATING, RUNNING, etc.)
- ✅ Structured command protocol supporting experiment automation workflows

Upcoming features in v0.6:
- 🎛️ Updated CI/CD deployment system for new architecture
- 🧩 Live operator dashboards and real-time monitoring
- 📋 Session handling and experiment tracking
- 🗄️ Enhanced registry management and node validation

---

## 🧠 System Overview

The framework operates across distributed nodes using a sophisticated architecture combining MQTT communication and REST API data transfer.

### Core Architecture:
- **MQTT Broker:** Runs on the master node for real-time communication
- **REST Server:** Handles large data transfers and health monitoring (`network/RestServer.py`)
- **Master Node:** Orchestrates experiments using FSM-based control logic
- **Experiment Nodes:** Run autonomous state machines with sensor/actuator control

### Node Framework:
Each node implements a finite state machine with 11 states:
- **BOOT** → **IDLE** → **CALIBRATING** → **TESTINGSENSOR/TESTINGACTUATOR** → **RUNNING** → **POSTPROC** → **DONE**
- Error handling via **ERROR** state with recovery capabilities
- Configuration validation through **CONFIGUREVALIDATE** → **CONFIGUREPENDING** workflow

### Communication:
- ✅ **MQTT**: Real-time commands, heartbeats, status updates, and logging
- ✅ **REST**: Large dataset transfers, health checks, and data retrieval
- ✅ **Hybrid**: Seamless integration of both protocols for optimal performance

---

## 📂 Directory Structure

```
lab_framework/
├── pythonCommon/        # Core Python framework (CommClient, RestClient, ExperimentManager)
├── matlabCommon/        # MATLAB framework equivalent (CommClient, RestClient, ExperimentManager, State)
├── node_scafolding_python/  # Python node development templates
├── node_scafolding_matlab/  # MATLAB node development templates
├── network/             # REST server implementation and MQTT configuration
├── test/                # Comprehensive test suite (58+ tests)
├── master_node/         # Master node implementation
├── carriage_node/       # Force sensor and data collection logic
├── wavemaker_node/      # Wave paddle and waveform generator logic
├── config/              # Node registry, manifest, and configuration files
├── updater/             # CI/CD deployment scripts (legacy - needs update)
├── logs/                # System logs and experiment data
└── README.md            # This file
```

> 📋 **Note**: The `pythonCommon/` and `matlabCommon/` folders contain the core reusable frameworks. See their respective README files for detailed documentation and usage examples.

---

## ⚙️ Configuration

### Node Development
The framework provides scaffolding templates for rapid node development:
- **Python nodes**: Use templates in `node_scafolding_python/` 
- **MATLAB nodes**: Use templates in `node_scafolding_matlab/`
- **Documentation**: See `pythonCommon/README.md` and `matlabCommon/README.md` for detailed API references

### `config/node_role.txt`
Set this manually on each machine to match its role:

```
carriage_node
```

Valid roles:
- `master_node`
- `carriage_node`
- `wavemaker_node`

> ⚠️ This file is local and not tracked by Git. Set per machine.

### `config/manifest.json`
Maps each role to its startup script and defines node capabilities.

---

## 🔁 Runtime Behavior

### Finite State Machine Control
Each node operates using an 11-state FSM managing the complete experiment lifecycle:

**Primary States:**
- **BOOT** → **IDLE**: Node initialization and connection establishment
- **CALIBRATING**: Sensor bias collection and hardware calibration
- **TESTINGSENSOR** / **TESTINGACTUATOR**: Hardware validation and diagnostics
- **CONFIGUREVALIDATE** → **CONFIGUREPENDING**: Experiment configuration validation
- **RUNNING** → **POSTPROC** → **DONE**: Active experiment execution and data processing
- **ERROR**: Fault handling with recovery capabilities

### Communication Patterns
- **MQTT**: Real-time command dispatch, heartbeats, state transitions, and logging
- **REST**: Large dataset uploads/downloads, health monitoring, and data persistence
- **Registry**: Dynamic node tracking in `config/node_registry.json`
- **Logging**: Comprehensive system logs in `logs/` directory

---

## 🗂️ Logs and Registry

- ✅ **Node Registry:** Dynamic tracking in `config/node_registry.json`
- ✅ **System Logs:** Comprehensive logging in `logs/` directory
- ✅ **Experiment Data:** REST API persistence for large datasets
- ✅ **State History:** FSM transition logging for debugging and analysis
- ✅ **Test Validation:** 58+ automated tests ensuring system reliability

---

## 📦 Setup & Deployment

### Quick Start

1. **Clone the repository:**
```bash
git clone https://github.com/YOUR_REPO/lab_framework.git
cd lab_framework
```

2. **Install Python dependencies:**
```bash
pip install paho-mqtt requests pandas pytest pytest-mock
```

3. **Set the node role:**
```bash
echo "carriage_node" > config/node_role.txt
```

4. **Start MQTT broker (master node only):**
```bash
mosquitto -c network/mosquitto.conf
```

5. **Run tests to verify installation:**
```bash
python -m pytest test/ -v
```

6. **Start REST server (if needed):**
```bash
python network/RestServer.py
```

### Development Setup
- **Python nodes**: See `node_scafolding_python/` and `pythonCommon/README.md`
- **MATLAB nodes**: See `node_scafolding_matlab/` and `matlabCommon/README.md`

> ⚠️ **Note**: The updater script (`updater/pull_and_deploy.sh`) is currently out of date and node initialization has been restructured. The CI/CD deployment concept remains valid and will be updated in future versions. The framework has been tested and validated through comprehensive test suites.

---

## 🧩 System Requirements

### Core Requirements
- ✅ **Python 3.7+** (recommended: Python 3.9+)
- ✅ **MQTT Broker** (Mosquitto) for real-time communication
- ✅ **Local Network** for distributed node communication

### Python Dependencies
- ✅ **paho-mqtt** - MQTT client library
- ✅ **requests** - HTTP/REST API communication
- ✅ **pandas** - Data manipulation and analysis
- ✅ **pytest** - Testing framework (development)

### Optional
- **MATLAB R2020b+** for MATLAB-based nodes
- **REST API Dashboard** for operator interfaces (future development)

---

## 📅 Roadmap

| Version | Milestone                        |
|---------|----------------------------------|
| v0.1    | ✅ Project scaffold + deploy logic |
| v0.2    | ✅ MQTT + REST base communication |
| v0.3    | ✅ Node registry + discovery     |
| v0.4    | ✅ Command-response loop + logging |
| v0.5    | ✅ **Complete Python + MATLAB frameworks with FSM control** |
| v0.6    | Updated CI/CD deployment + operator dashboards |
| v1.0    | Full production deployment and operator system |

---

## 👤 Author

Manuel Alejandro Valencia  
MIT Sea Grant | EECS '26

---
