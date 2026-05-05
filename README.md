# Lab Framework

A modular, distributed framework for running automated multi-computer experiments in a physical lab.

The framework handles MQTT communication, hardware DAQ control, calibration workflows, data collection, and operator dashboards — so a new node can be added by writing a single class and editing a config file, not by touching the communication layer or the dashboard.

---

## 🚦 Project Status — v1.0

The core system is working and has been validated with real hardware across two physical computers. Both MATLAB nodes (wave probe + paddle, force/motion sensor) and the Python control node are operational. The FSM, MQTT protocol, REST data pipeline, and operator dashboard all function end-to-end.

**What's complete:**
- ✅ 11-state FSM framework (MATLAB + Python, parallel implementations)
- ✅ MQTT communication layer — commands, status, heartbeats, logging
- ✅ REST data server — experiment data upload, retrieval, preview
- ✅ Operator dashboard — real-time monitoring, calibration wizard, experiment form, live charts
- ✅ Wave probe + paddle node (sinusoidal, Bretschneider, pulse, dual-pulse signals)
- ✅ Force/motion sensor node (6-axis load cell + 3-axis laser sensors)
- ✅ Python control node — orchestrates multi-node, multi-run experiments
- ✅ Config-driven calibration and actuator test wizards
- ✅ Experiment spec templates for common run types
- ✅ Node scaffolding for MATLAB and Python
- ✅ Test suite for Python framework and both MATLAB nodes

**What's still needed before this is a fully general-purpose framework:**
- 🔲 More extensive hardware-in-the-loop testing across varied experiment types
- 🔲 Expanded test coverage for edge cases and failure modes
- 🔲 Generalized webapp — current dashboard has some tow-tank-specific wiring that should become config-driven
- 🔲 Python linting (flake8 / ruff) and MATLAB linting integrated as GitHub Actions
- 🔲 Automated CI on pull requests (pytest, linting, config validation)

---

## 🧠 How the system works

The framework distributes an experiment across two or more computers. Each computer runs one or more **nodes** — autonomous processes that own a piece of hardware (sensors, actuators, or both) and manage it through a finite state machine. A **control node** running on the master computer orchestrates the sequence across all nodes.

```
Master Computer                          Peripheral Computer(s)
┌────────────────────────────┐           ┌──────────────────────────┐
│  control_node/             │           │  sensor_node/            │
│  (Python, orchestrator)    │  MQTT ←→  │  (MATLAB, NI-DAQ)        │
│                            │           └──────────────────────────┘
│  actuator_sensor_node/     │
│  (MATLAB, NI-DAQ)          │
└────────────────────────────┘
         │  REST (HTTP)
         ▼
  network/RestServer.py       ←→  network/webapp/index.html
  (Flask, stores CSV data)         (Operator dashboard)
```

**MQTT** carries real-time traffic: commands, state transitions, heartbeats, log messages, and live sensor readings. The broker runs on the master computer.

**REST** carries bulk data: experiment results are POSTed as CSV rows and fetched by the dashboard for display and download.

**The dashboard** connects directly to both — MQTT over WebSocket for live updates, REST for data retrieval.

---

## 🗂️ Repository layout

```
lab_framework/
├── matlabCommon/           # Shared MATLAB framework (CommClient, RestClient, ExperimentManager, State)
├── pythonCommon/           # Shared Python framework (same four components)
├── control_node/           # Python orchestration node — runs on master computer
├── carriage_node/          # MATLAB force/motion sensor node — runs on carriage computer
├── waveMakerProbe_node/    # MATLAB wave paddle + probe node — runs on master computer
├── network/                # MQTT broker config, REST server, operator dashboard
├── config/                 # All runtime configuration (manifest, machine configs, profiles, templates)
├── node_scafolding_matlab/ # Starter template for a new MATLAB node
├── node_scafolding_python/ # Starter template for a new Python node
├── test/                   # Test suites (pytest for Python, MATLAB test classes for MATLAB nodes)
├── updater/                # Deploy and health-check scripts
└── logs/                   # Runtime logs (not git-tracked)
```

Each folder with significant logic has its own README. Start there when working on a specific component.

---

## ⚙️ Node architecture

Every node — whether MATLAB or Python — follows the same pattern:

1. A **launcher script** (`node.m` or `main.py`) reads the machine config, builds the comm and REST clients, instantiates the manager, and enters an event loop.
2. A **manager class** subclasses `ExperimentManager` and implements hardware-specific methods:

| Method | When it runs |
|---|---|
| `initializeHardware` | Once at BOOT — create DAQ session, open serial port, etc. |
| `handleCalibrate` | In CALIBRATING — collect calibration data point by point |
| `handleTest` | In TESTINGSENSOR or TESTINGACTUATOR — verify hardware is live |
| `configureHardware` | At CONFIGUREVALIDATE — validate experiment parameters |
| `handleRun` | In RUNNING — execute acquisition and/or output |
| `stopHardware` | On abort or reset — safe-stop all outputs |
| `shutdownHardware` | On clean exit — release hardware resources |

The base class handles all FSM transitions, MQTT messaging, REST data upload, and multi-experiment sequencing. A node author only implements these seven methods.

See `matlabCommon/README.md` and `pythonCommon/README.md` for the full API reference.

---

## 🔄 Finite state machine

All nodes share the same 11-state FSM:

```
                          ┌──────────────────────────────────────────────┐
                          │                                              ↓
BOOT → IDLE ──→ CALIBRATING ──→ IDLE                                  ERROR
         │                                                                ↑
         ├──→ TESTINGSENSOR ──→ IDLE                     (any state → ERROR)
         │
         ├──→ TESTINGACTUATOR ──→ IDLE
         │
         └──→ CONFIGUREVALIDATE ──→ CONFIGUREPENDING ──→ TESTINGACTUATOR ──→ IDLE
                                                     │
                                                     └──→ RUNNING ──→ POSTPROC ──→ DONE ──→ IDLE
                                                                          │
                                                                          └──→ RUNNING  (next sub-experiment)
```

Permitted transitions:

| From | To |
|---|---|
| `BOOT` | `IDLE` |
| `IDLE` | `CALIBRATING`, `TESTINGSENSOR`, `TESTINGACTUATOR`, `CONFIGUREVALIDATE` |
| `CALIBRATING` | `CALIBRATING` (multi-step loop), `IDLE` |
| `TESTINGSENSOR` | `IDLE` |
| `TESTINGACTUATOR` | `IDLE` |
| `CONFIGUREVALIDATE` | `CONFIGUREPENDING`, `IDLE` |
| `CONFIGUREPENDING` | `TESTINGACTUATOR`, `RUNNING` |
| `RUNNING` | `POSTPROC` |
| `POSTPROC` | `RUNNING` (next sub-experiment), `DONE` |
| `DONE` | `IDLE` |
| `ERROR` | `IDLE` |

Any state can transition to `ERROR` (on hardware fault) or to `IDLE` (on `Reset` or `Abort`). State transitions are triggered by MQTT commands (`Calibrate`, `Test`, `Configure`, `TestValid`, `RunValid`, `Abort`, `Reset`). The control node sends these in sequence; the operator can also send them manually from the dashboard.

---

## 🚀 Getting started

### Prerequisites

**All machines:**
- Git
- A local network connecting all machines (static IPs recommended)

**Master computer (runs broker, REST server, control node, and any master-side MATLAB node):**
- Python 3.9+
- Mosquitto MQTT broker — download from [mosquitto.org/download](https://mosquitto.org/download/). Install the binary but **disable the system service** to avoid port conflicts with the deploy script (`sc config mosquitto start= disabled && net stop mosquitto` on Windows). The deploy script starts Mosquitto directly from `network/mosquitto.conf`.
- MATLAB R2022a+ with the Data Acquisition Toolbox (if running a MATLAB node on this machine)
- NI-DAQmx driver (if running a MATLAB DAQ node on this machine)

**Peripheral computers (run peripheral MATLAB nodes):**
- MATLAB R2022a+ with the Data Acquisition Toolbox
- NI-DAQmx driver

**Python dependencies** (install once on any machine running Python code):
```bash
pip install -r pythonCommon/requirements.txt
```
This installs: `paho-mqtt`, `flask`, `requests`, `pandas`, `scipy`, `pytest`, `pytest-cov`, `black`, `flake8`.

### First-time setup

**1. Clone the repository on every machine that will run a node.**

```bash
git clone <your-repo-url> lab_framework
cd lab_framework
```

**2. Install Python dependencies.**

```bash
pip install -r pythonCommon/requirements.txt
```

**3. Set the machine role.**

```bash
echo "master_computer" > config/node_role.txt   # on the master machine
echo "carriage_computer" > config/node_role.txt  # on each peripheral machine
```

Role names must match a key in `config/manifest.json`.

**4. Create the machine config file.**

Copy and edit the appropriate example from `config/`:

```bash
cp config/master_computer.json config/master_computer.json  # already present
# Edit brokerAddress, daqDevice, channel names to match your hardware
```

See `config/README.md` for a full field-by-field reference.

**5. Start the MQTT broker (master machine only).**

Make sure Mosquitto is installed (see Prerequisites above) and the system service is stopped, then:

```bash
mosquitto -c network/mosquitto.conf
```

This starts two listeners: TCP on port 1883 (for nodes) and WebSocket on port 9001 (for the dashboard). Both are configured in `network/mosquitto.conf`.

**6. Start the REST server (master machine only).**

```bash
python network/RestServer.py
```

**7. Open the dashboard.**

Open `network/webapp/index.html` in a browser. Set the broker and REST addresses to the master computer's IP.

**8. Launch the nodes.**

On the master machine, run the MATLAB node and the control node:
```bash
# In MATLAB:
run('waveMakerProbe_node/wavemaker_probe_node.m')

# In a terminal:
python control_node/main.py
```

On each peripheral machine:
```bash
# In MATLAB:
run('carriage_node/carriage_node.m')
```

Nodes boot, connect to the broker, and report IDLE. The control node begins sending heartbeats. The dashboard shows all nodes as online.

---

## 🧪 Running the tests

Python tests use pytest:

```bash
python -m pytest test/pythonCommon/ -v
python -m pytest test/network/ -v
```

MATLAB tests use the MATLAB test runner — open and run the test classes in `test/matlabCommon/` and `test/wavemakerprobe_node/` and `test/carriage_node/`.

---

## 🔁 Deploy script and CI/CD

`updater/pull_and_deploy.sh` is a self-updating deployment launcher. Run it once on each machine at lab startup instead of launching nodes manually. It handles:

- **Git pull** — fetches and hard-resets to the latest code on the current branch before each launch cycle
- **Health check** — runs `updater/health_check.py` before starting nodes; rolls back to the previous commit if the check fails
- **Mosquitto** — starts the broker from `network/mosquitto.conf` on machines where `launchMosquitto: true` in `manifest.json`
- **Node launch** — reads `manifest.json` for the current profile and launches each node (MATLAB via `matlab -batch`, Python directly)
- **Self-update loop** — if a node exits with code 42, the script kills all background processes, re-pulls, and relaunches automatically. This lets a running node trigger a code update over MQTT without remote access.

```bash
bash updater/pull_and_deploy.sh
```

The script must be run from the repository root. It reads `config/node_role.txt` to determine which profile to launch.

`updater/health_check.py` is the pre-launch gate. It currently checks that Python dependencies are importable, that `manifest.json` and `node_role.txt` exist and are valid, and that the machine config file is present. Add more checks here as the codebase grows.

### GitHub Actions (planned)

The following CI checks are planned as GitHub Actions but not yet configured:

- `pytest` on push/PR for `test/pythonCommon/` and `test/network/`
- `flake8` / `ruff` linting for all Python files
- JSON schema validation for `manifest.json`, `calibration_profiles.json`, and `actuator_profiles.json`
- MATLAB linting via MATLAB's built-in code analyzer (when a self-hosted runner is available)

---

## 🔌 Adding a new node

1. Copy the scaffolding from `node_scafolding_matlab/` or `node_scafolding_python/`.
2. Implement the seven hardware methods in your manager class.
3. Add the node to `config/manifest.json` under the relevant machine profile.
4. Add a section for it in the machine-local `<profile>.json` with its MQTT topics and hardware config.
5. If it has a calibration procedure, add a phase to `config/calibration_profiles.json`.
6. If it has an actuator, add its signal types to `config/actuator_profiles.json`.
7. Add an experiment spec template to `config/templates/`.

No changes to the control node, the dashboard, or the framework code are needed for steps 1–7.

See `config/README.md` and the scaffolding READMEs for detailed guidance.

---

## 👤 Author

Manuel Alejandro Valencia  
MIT Sea Grant | EECS '26


