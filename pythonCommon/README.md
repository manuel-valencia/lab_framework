# pythonCommon

Shared Python classes used by all experiment nodes in the framework. Every node - sensor, actuator, or hybrid - uses this package.

## Contents

| File | Role |
|---|---|
| `CommClient.py` | MQTT communication layer |
| `RestClient.py` | HTTP REST data transfer |
| `ExperimentManager.py` | Abstract FSM controller; base class for every node (includes `State` enum) |

All three files must be importable before any node can run. Install dependencies with `pip install -r requirements.txt`.

---

## CommClient.py

Manages the MQTT connection for a node: connection lifecycle, topic subscriptions, message publishing, heartbeat, and an in-memory message log.

### Topic layout (defaults)

| Topic | Direction | Content |
|---|---|---|
| `<clientID>/cmd` | Inbound | Experiment command JSON |
| `<clientID>/status` | Outbound | FSM state updates and heartbeat |
| `<clientID>/data` | Outbound | Experiment data |
| `<clientID>/log` | Outbound | Structured log messages |

Default topics are built from `clientID` automatically. Override by setting `cfg['subscriptions']` and `cfg['publications']`.

### Constructor fields

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `str` | **Required** | Unique node identifier. Sets topic prefix and log tags. |
| `brokerAddress` | `str` | `'localhost'` | Hostname or IP of the MQTT broker. |
| `brokerPort` | `int` | `1883` | MQTT broker port. |
| `subscriptions` | `list[str]` | `[clientID/cmd]` | Topics to subscribe to on connect. |
| `publications` | `list[str]` | `[clientID/status, clientID/data, clientID/log]` | Topics this node publishes to. |
| `onMessageCallback` | `Callable` | `None` | Called with `(topic, msg)` for every inbound message. Set to `mgr.on_message_callback` when using with ExperimentManager. |
| `heartbeatInterval` | `float` | `0` (disabled) | Seconds between periodic heartbeat publishes. `0` disables the timer. |
| `keepAliveDuration` | `int` | `60` | MQTT keep-alive window in seconds. |
| `verbose` | `bool` | `False` | Prints all publish/subscribe activity to the console. |

### Methods

| Method | Description |
|---|---|
| `connect()` | Connects to broker, subscribes to all configured topics, starts heartbeat timer if configured. |
| `disconnect()` | Stops heartbeat timer, unsubscribes all topics, clears the MQTT client handle. |
| `comm_publish(topic, payload)` | Publishes a string or JSON-serializable dict to a topic. |
| `comm_subscribe(topic)` | Dynamically subscribes to a new topic at runtime; no-op if already subscribed. |
| `comm_unsubscribe(topic)` | Unsubscribes from a topic and removes it from the internal list. |
| `send_heartbeat()` | Publishes `{clientID, timestamp, health: "READY", ip}` to `<clientID>/status`. Called automatically by the timer. |
| `handle_message(topic, msg)` | Internal callback wired to every subscription. Logs the message and forwards to `onMessageCallback`. |
| `get_full_topic(suffix)` | Returns `'<clientID>/suffix'`. Used internally by ExperimentManager. |
| `add_to_log(topic, msg)` | Appends `{timestamp, topic, message}` to `message_log`. Capped at 1000 entries (FIFO). |

### Usage

```python
cfg = {
    'clientID': 'sensorNode1',
    'brokerAddress': '192.168.1.10',
    'heartbeatInterval': 5,
    'verbose': True
}

comm = CommClient(cfg)
comm.connect()
```

When using with ExperimentManager, `onMessageCallback` is set to `mgr.on_message_callback` and `connect()` is called automatically by the ExperimentManager constructor - do not call it manually in that case.

---

## RestClient.py

Provides HTTP POST and GET for experiment data transfer between nodes and the central REST server (`network/RestServer.py`). Used for datasets that are too large for MQTT.

### Constructor fields

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `str` | **Required** | Node identifier. Sets the POST endpoint path. |
| `brokerAddress` | `str` | `'localhost'` | Hostname or IP of the REST server. |
| `restPort` | `int` | `5000` | REST server port. |
| `verbose` | `bool` | `False` | Prints POST/GET results to console. |
| `timeout` | `int` | `15` | HTTP request timeout in seconds. |

POST endpoint is built as: `http://<brokerAddress>:<restPort>/data/<clientID>`

### Methods

| Method | Description |
|---|---|
| `send_data(data, **kwargs)` | POSTs a pandas DataFrame (as CSV) or list of dicts (as JSONL) to the REST server. |
| `fetch_data(**kwargs)` | GETs experiment data from the REST server with optional filtering. |
| `check_health()` | GETs `/health` and returns `True` if the server responds with `status: "online"`. |
| `convert_to_csv(tbl)` | Static. Converts a pandas DataFrame to a CSV string. Used internally by `send_data`. |

### send_data options

```python
# DataFrame is auto-detected as CSV; list of dicts as JSONL
rest_client.send_data(data_frame, experiment_name='run_01')
rest_client.send_data(data_list, experiment_name='run_02', format='jsonl')
```

On network failure, `send_data` returns `{'status': 'error', 'message': ...}` rather than throwing.

### fetch_data options

```python
# Get the most recent data stored for this node
result = rest_client.fetch_data(latest=True)

# Get a specific experiment by name
result = rest_client.fetch_data(experiment_name='run_01', format='csv')

# Get data from a different node
result = rest_client.fetch_data(clientID='otherNode', latest=True)
```

### Health check

```python
if not rest_client.check_health():
    raise ConnectionError('REST server is not reachable.')
```

The ExperimentManager constructor calls `check_health()` automatically and raises if the server is unreachable. A running `network/RestServer.py` is required before any node can start.

---

## ExperimentManager.py

Abstract FSM controller. Every node subclasses this and implements a fixed set of abstract methods for hardware interaction. The base class handles command routing, state transitions, logging, data saving, and shutdown.

The `State` enum is defined in this file and is imported automatically when subclassing `ExperimentManager`.

### State enum

| State | Integer | Role |
|---|---|---|
| `BOOT` | 0 | Startup, before hardware initialization |
| `IDLE` | 1 | Ready and waiting for commands |
| `CALIBRATING` | 2 | Executing sensor calibration |
| `TESTINGSENSOR` | 3 | Live sensor diagnostics |
| `CONFIGUREVALIDATE` | 4 | Validating all experiment parameters before accepting any |
| `CONFIGUREPENDING` | 5 | Valid config received, awaiting confirmation to run |
| `TESTINGACTUATOR` | 6 | Actuator pre-run validation |
| `RUNNING` | 7 | Experiment in progress |
| `POSTPROC` | 8 | Saving data locally and to REST; loops back to RUNNING for each sub-experiment |
| `DONE` | 9 | All experiments complete; transitions to IDLE |
| `ERROR` | 10 | Fault state; reachable from any state |

`IDLE` and `ERROR` are implicit wildcard destinations - any state may transition to either.

### Subclassing

```python
from pythonCommon.ExperimentManager import ExperimentManager, State

class MyNodeManager(ExperimentManager):
    def initialize_hardware(self, cfg):           ...
    def handle_calibrate(self, cmd):              ...
    def handle_test(self, cmd):                   ...
    def handle_run(self, cmd):                    ...
    def configure_hardware(self, params) -> bool: ...
    def stop_hardware(self):                      ...
    def shutdown_hardware(self):                  ...
```

See `node_scafolding_python/` for a complete template.

### Required abstract methods

| Method | Signature | Contract |
|---|---|---|
| `initialize_hardware` | `(self, cfg)` | Called once by the constructor after MQTT and REST are connected. Set up DAQ sessions, open ports, etc. |
| `handle_calibrate` | `(self, cmd)` | Called on entry to `CALIBRATING`. Must call `self.transition(State.IDLE)` when done. Multi-step flows may loop back to `CALIBRATING`. |
| `handle_test` | `(self, cmd)` | Called on entry to `TESTINGSENSOR` or `TESTINGACTUATOR`. Behavior depends on `cmd['params']['target']`. |
| `handle_run` | `(self, cmd)` | Called on entry to `RUNNING`. Must reset `self.experiment_data = []` before appending new records, then call `self.transition(State.POSTPROC)` on success. On abort: clear data and return. |
| `configure_hardware` | `(self, params) -> bool` | Called by `_enter_configure_validate` for each sub-experiment. Return `True` if parameters are valid and hardware is configured. Return `False` to reject. |
| `stop_hardware` | `(self)` | Called on entry to `IDLE` and `ERROR`, and at exit from `RUNNING` and `TESTINGSENSOR`. Stop acquisitions and safe-state hardware. |
| `shutdown_hardware` | `(self)` | Called once at the start of `shutdown()`. Full cleanup: release sessions, close files, etc. |

### Optional overrideable methods

| Method | When to override |
|---|---|
| `setup_current_experiment()` | Add per-run setup (reset buffers, load run-specific params). Always call the base first: `super().setup_current_experiment()`. |
| `_enter_post_proc()` | Add node-specific post-processing (filtering, decoupling, derived values). Always call the base last: `super()._enter_post_proc()`. |
| `on_message_callback(topic, msg)` | Override for nodes that subscribe to additional topics beyond `/cmd`. Default routes all messages to `handle_command`. |
| `await_ready(sc)` | Override to implement inter-run settling logic. Base returns `True` immediately. Called between sub-experiments when `settleCheck['enabled'] = True`. |

### Constructor

```python
mgr = MyNodeManager(cfg, comm, rest)
```

The constructor:
1. Stores `cfg`, `comm`, `rest`
2. Loads `calibrationGains.pkl` from the current working directory if present (silent if absent)
3. Calls `comm.connect()` - do not call this separately
4. Calls `rest.check_health()` - raises if the REST server is unreachable
5. Calls `initialize_hardware(cfg)`
6. Transitions to `IDLE`

### Public methods

| Method | Description |
|---|---|
| `handle_command(cmd)` | Main command entry point. Routes a decoded command dict to the appropriate FSM transition. Normally called via `on_message_callback`. |
| `abort(reason)` | Publishes an ERROR status, sets `abort_requested = True`, calls `stop_hardware()`, and transitions to `ERROR`. |
| `log(level, msg)` | Publishes a structured log entry to `<clientID>/log` and appends to `fsm_log`. Written to disk at shutdown. |
| `get_state()` | Returns the current FSM state as a string. |
| `get_bias_table()` | Returns the current sensor bias table loaded or computed by `handle_calibrate`. |
| `get_experiment_data()` | Returns `experiment_data` from the last run. |
| `shutdown()` | Saves MQTT log, FSM log, and FSM history to `<clientID>Logs/`, then disconnects. |
| `on_message_callback(topic, msg)` | Default MQTT message handler. Decodes JSON and routes valid commands to `handle_command`. Override for additional topic handling. |
| `setup_current_experiment()` | Logs current experiment parameters before each run. Called automatically by the framework. |

### handle_command dispatch

All commands arrive as JSON on `<clientID>/cmd` and are decoded by `on_message_callback` before reaching `handle_command`.

| Command | Required fields | State transition | Notes |
|---|---|---|---|
| `Calibrate` | `cmd` | `IDLE -> CALIBRATING` | May loop: `CALIBRATING -> CALIBRATING` for multi-step flows |
| `Test` | `cmd`, `params['target']` | `IDLE -> TESTINGSENSOR` (sensor) or `IDLE -> CONFIGUREVALIDATE` (actuator) | |
| `Run` | `cmd`, `params` | `IDLE -> CONFIGUREVALIDATE -> CONFIGUREPENDING` | Waits for `RunValid` to proceed |
| `TestValid` | `cmd` | `CONFIGUREPENDING -> TESTINGACTUATOR` | Uses params cached from the prior `Test` command |
| `RunValid` | `cmd` | `CONFIGUREPENDING -> RUNNING` | |
| `Reset` | `cmd` | `ANY -> IDLE` | Hard recovery |
| `Abort` | `cmd` | `ANY -> ERROR` | Calls `abort()`; stops hardware immediately |
| `Update` | `cmd` | `IDLE -> shutdown -> exit(42)` | Only accepted from IDLE. Publishes `UPDATING` status, shuts down cleanly, then exits with code 42 so `pull_and_deploy.sh` can re-pull and relaunch. |

### Configuration dict

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `str` | **Required** | Unique node identifier. Used for MQTT topics, log filenames, and data directory names. |
| `hardware['hasSensor']` | `bool` | `False` | Gates entry into `CALIBRATING` and `TESTINGSENSOR`. |
| `hardware['hasActuator']` | `bool` | `False` | Gates entry into `TESTINGACTUATOR`. |
| `hardware['settleCheck']` | `dict` | `{}` | Node-level inter-run settling defaults. See settleCheck below. |

### settleCheck

Controls the inter-run readiness gate in multi-experiment mode. Active between sub-experiments when `enabled = True`. Can be set at node level (`cfg['hardware']['settleCheck']`) or overridden per experiment run (`experiment_spec['params']['settleCheck']`). Run-level config takes priority.

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `False` | Master switch. If `False`, `await_ready` is skipped entirely. |
| `threshold` | `float` | -- | Signal magnitude that counts as settled. Units are node-defined. |
| `thresholdUnits` | `str` | -- | Human-readable unit label for log output. |
| `holdDuration_s` | `float` | -- | Seconds the signal must remain below threshold before the next sub-experiment starts. |

`await_ready()` in the base class returns `True` immediately (no-op). `INTER_RUN_READY` is published after settling.

### Logging and log files

Every call to `log()` publishes to MQTT and appends to the in-memory `fsm_log`. At `shutdown()`, the following files are written to `<clientID>Logs/`:

| File | Content |
|---|---|
| `<clientID>_fsmLog.jsonl` | All entries from `log()` |
| `<clientID>_commLog.jsonl` | All raw MQTT messages received by CommClient |
| `<clientID>_fsmHistory.log` | Ordered list of every state transition |

---

## Complete configuration reference

All fields accepted by any of the three classes. A node typically needs a subset.

| Field | Used by | Type | Default | Description |
|---|---|---|---|---|
| `clientID` | All | `str` | **Required** | Unique node identifier. |
| `brokerAddress` | CommClient, RestClient | `str` | `'localhost'` | Hostname or IP of the MQTT broker and REST server. |
| `brokerPort` | CommClient | `int` | `1883` | MQTT broker port. |
| `restPort` | RestClient | `int` | `5000` | REST server port. |
| `subscriptions` | CommClient | `list[str]` | `[clientID/cmd]` | MQTT topics to subscribe to. |
| `publications` | CommClient | `list[str]` | `[clientID/status, clientID/data, clientID/log]` | MQTT topics this node publishes to. |
| `onMessageCallback` | CommClient | `Callable` | `None` | Inbound message handler. |
| `heartbeatInterval` | CommClient | `float` | `0` | Heartbeat period in seconds. `0` disables it. |
| `keepAliveDuration` | CommClient | `int` | `60` | MQTT keep-alive window in seconds. |
| `verbose` | CommClient, RestClient | `bool` | `False` | Verbose console output. |
| `timeout` | RestClient | `int` | `15` | HTTP request timeout in seconds. |
| `hardware['hasSensor']` | ExperimentManager | `bool` | `False` | Enables sensor states. |
| `hardware['hasActuator']` | ExperimentManager | `bool` | `False` | Enables actuator states. |
| `hardware['settleCheck']` | ExperimentManager | `dict` | `{}` | Inter-run settling config. |

### Example: sensor and actuator node

```python
cfg = {
    'clientID': 'hybridNode1',
    'brokerAddress': 'lab-server.local',
    'brokerPort': 1883,
    'restPort': 5000,
    'heartbeatInterval': 10,
    'verbose': False,
    'hardware': {
        'hasSensor': True,
        'hasActuator': True
    }
}

comm = CommClient(cfg)
rest = RestClient(cfg)
mgr  = MyHybridManager(cfg, comm, rest)
```

---

## Testing

`test/pythonCommon/` contains standalone test scripts for each class:

| Script | What it covers |
|---|---|
| `test_comm_client.py` | Connection, publish, subscribe, heartbeat, message log |
| `test_rest_client.py` | POST, GET, health check, error handling |
| `test_experiment_manager.py` | FSM transitions, command dispatch, abort, shutdown |

Run with pytest from the repository root:

```bash
python -m pytest test/pythonCommon/ -v
```

---

## Dependencies

- Python 3.9 or later
- `paho-mqtt` - MQTT client library
- `requests` - HTTP library for REST API interactions
- `pandas` - data manipulation for CSV export
- `flask` - required by `network/RestServer.py` (not imported by pythonCommon directly)
- `scipy` - available for subclass use in post-processing

Install all at once:

```bash
pip install -r pythonCommon/requirements.txt
```