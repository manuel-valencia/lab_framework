# control_node

MQTT command dispatcher and web UI host for the master computer. Subscribes to all peripheral node topics, maintains a live node registry, and exposes a REST API that the operator dashboard uses to monitor nodes and send commands.

## Contents

| File | Role |
|---|---|
| `main.py` | `ControlNode` class and `main()` entry point |
| `logs/` | Per-session log files written at runtime (not git-tracked) |

---

## How it works

`ControlNode` is not an `ExperimentManager` subclass and has no FSM. It is a lightweight broker-facing process that:

1. Loads `config/node_registry.json` (persisted state from previous sessions) and seeds node capabilities from `config/manifest.json`
2. Connects to the MQTT broker via `CommClient` and subscribes to all `+/status`, `+/data`, and `+/log` topics
3. Updates the node registry on every `/status` message and marks nodes offline after 60 seconds of silence
4. Starts a Flask web server (default port 8080) that serves the operator dashboard and a REST API
5. Exposes `send_command(node_id, cmd)` for programmatic command dispatch

The operator dashboard (`network/webapp/index.html`) connects to the same MQTT broker over WebSocket for real-time updates and calls the REST API to load templates and send commands.

---

## REST API

All routes are served by the embedded Flask server on the configured `webPort` (default 8080).

| Method | Route | Description |
|---|---|---|
| `GET` | `/` | Serves `network/webapp/index.html` |
| `GET` | `/api/nodes` | Returns the live node registry with online/offline status |
| `GET` | `/api/templates` | Lists all `.json` files in `config/templates/` |
| `GET` | `/api/templates/<name>` | Returns the JSON content of a specific template |
| `GET` | `/api/calibration-profiles` | Returns `config/calibration_profiles.json` |
| `GET` | `/api/actuator-profiles` | Returns `config/actuator_profiles.json` |
| `POST` | `/api/command/<node_id>` | Publishes a command to `<node_id>/cmd` over MQTT |
| `POST` | `/api/broadcast` | Publishes a command to `controlNode/cmd` (all subscribers) |

`POST /api/command/<node_id>` and `POST /api/broadcast` both require a JSON body with at least a `"cmd"` field:

```json
{"cmd": "Run", "params": {"name": "run_01"}}
```

---

## Node registry

The registry maps each `nodeId` to a live status entry. It is loaded from and persisted to `config/node_registry.json` on every update.

| Field | Source | Description |
|---|---|---|
| `node_id` | Status message | Node's `clientID` |
| `status` | Derived | `"online"` or `"offline"` |
| `state` | Status message | Current FSM state string (e.g. `"IDLE"`, `"RUNNING"`) |
| `last_seen` | Derived | Unix timestamp of the last received message |
| `last_seen_readable` | Derived | Human-readable timestamp |
| `ip` | Status message | Node IP address (from heartbeat, if present) |
| `hasSensor` | `manifest.json` | Whether the node has sensor capability |
| `hasActuator` | `manifest.json` | Whether the node has actuator capability |

State strings not in the known FSM set are rejected with a warning — the registry entry is not updated with unknown values.

---

## Configuration

`main.py` reads the `"controlNode"` section of the machine config file passed as the first CLI argument. Top-level broker fields are merged in as defaults.

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `str` | **Required** | Identity of the control node on the broker (e.g. `"controlNode"`). |
| `brokerAddress` | `str` | `'localhost'` | Hostname or IP of the MQTT broker. |
| `brokerPort` | `int` | `1883` | MQTT broker port. |
| `restPort` | `int` | `5000` | Port of the REST data server (`network/RestServer.py`). |
| `webPort` | `int` | `8080` | Port the embedded Flask web UI listens on. |
| `verbose` | `bool` | `False` | Verbose MQTT output. |

Example `controlNode` section inside `config/master_computer.json`:

```json
"controlNode": {
    "clientID": "controlNode",
    "webPort": 8080
}
```

---

## Running

Called by `updater/pull_and_deploy.sh` automatically on startup. To run manually:

```bash
python3 control_node/main.py config/master_computer.json master_computer
```

The second argument (`master_computer`) is the active profile name. It is logged at startup for reference.

The process runs until interrupted (Ctrl-C or SIGTERM). On shutdown it saves the registry and disconnects from the broker cleanly.

---

## Dependencies

`control_node` depends on `pythonCommon` (CommClient, RestClient) and Flask. Install all required packages from the repo root:

```bash
pip install -r pythonCommon/requirements.txt
```

Flask is listed in `pythonCommon/requirements.txt`. No additional installs are needed beyond that file.

The MQTT broker must be running before this process starts. The default config expects the broker on `localhost:1883` (see `network/mosquitto.conf`).

---

## Known limitations

- `profile` is accepted as a CLI argument and logged, but the registry is seeded from all profiles in `manifest.json` regardless. All known nodes appear in the dashboard independent of which profile is active.
- The embedded Flask server uses Werkzeug's development mode. It is adequate for single-operator lab use but is not hardened for public network exposure.
