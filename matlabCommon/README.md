# matlabCommon

Shared MATLAB classes used by all experiment nodes in the framework. Every node — sensor, actuator, or hybrid — uses this package.

## Contents

| File | Role |
|---|---|
| `State.m` | Enum defining the 11 FSM states |
| `CommClient.m` | MQTT communication layer |
| `RestClient.m` | HTTP REST data transfer |
| `ExperimentManager.m` | Abstract FSM controller; base class for every node |

All four files must be on the MATLAB path before any node can run.

---

## State.m

Defines the 11 states of the `ExperimentManager` state machine as an `int32` enum. The file includes inline documentation of all permitted transitions — read it directly for the full transition table.

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

`IDLE` and `ERROR` are implicit wildcard destinations — any state may transition to either.

---

## CommClient.m

Manages the MQTT connection for a node: connection lifecycle, topic subscriptions, message publishing, heartbeat, and an in-memory message log.

### Topic layout (defaults)

| Topic | Direction | Content |
|---|---|---|
| `<clientID>/cmd` | Inbound | Experiment command JSON |
| `<clientID>/status` | Outbound | FSM state updates and heartbeat |
| `<clientID>/data` | Outbound | Experiment data |
| `<clientID>/log` | Outbound | Structured log messages |

Default topics are built from `clientID` automatically. Override by setting `cfg.subscriptions` and `cfg.publications`.

### Constructor fields

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `string` | **Required** | Unique node identifier. Sets topic prefix and log tags. |
| `brokerAddress` | `string` | `'localhost'` | Hostname or IP of the MQTT broker. |
| `brokerPort` | `int` | `1883` | MQTT broker port. |
| `subscriptions` | `cell array` | `{clientID/cmd}` | Topics to subscribe to on connect. |
| `publications` | `cell array` | `{clientID/status, clientID/data, clientID/log}` | Topics this node publishes to. |
| `onMessageCallback` | `function_handle` | `[]` | Called with `(topic, msg)` for every inbound message. Set to `@mgr.onMessageCallback` when using with ExperimentManager. |
| `heartbeatInterval` | `double` | `0` (disabled) | Seconds between periodic heartbeat publishes. `0` disables the timer. |
| `keepAliveDuration` | `duration` | `seconds(60)` | MQTT keep-alive window. |
| `verbose` | `logical` | `false` | Prints all publish/subscribe activity to the console. |

### Methods

| Method | Description |
|---|---|
| `connect()` | Connects to broker, subscribes to all configured topics, starts heartbeat timer if configured. |
| `disconnect()` | Stops heartbeat timer, unsubscribes all topics, clears the MQTT client handle. |
| `commPublish(topic, payload)` | Publishes a string or JSON string to a topic. Throws if not connected. |
| `commSubscribe(topic)` | Dynamically subscribes to a new topic at runtime; no-op if already subscribed. |
| `commUnsubscribe(topic)` | Unsubscribes from a topic and removes it from the internal list. |
| `sendHeartbeat()` | Publishes `{clientID, timestamp, health: "READY", ip}` to `<clientID>/status`. Called automatically by the timer. |
| `handleMessage(topic, msg)` | Internal callback wired to every subscription. Logs the message and forwards to `onMessageCallback`. |
| `getFullTopic(suffix)` | Returns `'<clientID>/suffix'`. Used internally by ExperimentManager. |
| `addToLog(topic, msg)` | Appends `{timestamp, topic, message}` to `messageLog`. Capped at 1000 entries (FIFO). |

### Usage

```matlab
cfg.clientID = 'sensorNode1';
cfg.brokerAddress = '192.168.1.10';
cfg.heartbeatInterval = 5;
cfg.verbose = true;

comm = CommClient(cfg);
comm.onMessageCallback = @(topic, msg) disp(msg);
comm.connect();
```

When using with ExperimentManager, `onMessageCallback` is set to `@mgr.onMessageCallback` and `connect()` is called automatically by the ExperimentManager constructor — do not call it manually in that case.

---

## RestClient.m

Provides HTTP POST and GET for experiment data transfer between nodes and the central REST server (`network/RestServer.py`). Used for datasets that are too large for MQTT.

### Constructor fields

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `string` | **Required** | Node identifier. Sets the POST endpoint path. |
| `brokerAddress` | `string` | `'localhost'` | Hostname or IP of the REST server. |
| `restPort` | `int` | `5000` | REST server port. |
| `verbose` | `logical` | `false` | Prints POST/GET results to console. |
| `timeout` | `numeric` | `15` | HTTP request timeout in seconds. |

POST endpoint is built as: `http://<brokerAddress>:<restPort>/data/<clientID>`

### Methods

| Method | Description |
|---|---|
| `sendData(data, ...)` | POSTs a MATLAB table (as CSV) or struct array (as JSON) to the REST server. |
| `fetchData(...)` | GETs experiment data from the REST server with optional filtering. |
| `checkHealth()` | GETs `/health` and returns `true` if the server responds with `status: "online"`. |
| `convertToCSV(tbl)` | Static. Converts a MATLAB table to a CSV string. Used internally by `sendData`. |

### sendData options

```matlab
% Table is auto-detected as CSV; struct array as JSONL
restClient.sendData(dataTable, 'experimentName', 'run_01');
restClient.sendData(dataStruct, 'experimentName', 'run_02', 'format', 'jsonl');
```

On network failure, `sendData` returns `struct("status", "error", "message", ...)` rather than throwing.

### fetchData options

```matlab
% Get the most recent data stored for this node
result = restClient.fetchData('latest', true);

% Get a specific experiment by name
result = restClient.fetchData('experimentName', 'run_01', 'format', 'csv');

% Get data from a different node
result = restClient.fetchData('clientID', 'otherNode', 'latest', true);
```

### Health check

```matlab
if ~restClient.checkHealth()
    error('REST server is not reachable.');
end
```

The ExperimentManager constructor calls `checkHealth()` automatically and throws if the server is unreachable. A running `network/RestServer.py` is required before any node can start.

---

## ExperimentManager.m

Abstract FSM controller. Every node subclasses this and implements a fixed set of abstract methods for hardware interaction. The base class handles command routing, state transitions, logging, data saving, and shutdown.

### Subclassing

```matlab
classdef MyNodeManager < ExperimentManager
    methods
        function initializeHardware(obj, cfg)  ...  end
        function handleCalibrate(obj, cmd)     ...  end
        function handleTest(obj, cmd)          ...  end
        function handleRun(obj, cmd)           ...  end
        function tf = configureHardware(obj, params)  ...  end
        function stopHardware(obj)             ...  end
        function shutdownHardware(obj)         ...  end
    end
end
```

See `node_scafolding_matlab/` for a complete template.

### Required abstract methods

| Method | Signature | Contract |
|---|---|---|
| `initializeHardware` | `(obj, cfg)` | Called once by the constructor after MQTT and REST are connected. Set up DAQ sessions, open ports, etc. |
| `handleCalibrate` | `(obj, cmd)` | Called on entry to `CALIBRATING`. Must call `transition(State.IDLE)` when done. Multi-step flows may loop back to `CALIBRATING`. |
| `handleTest` | `(obj, cmd)` | Called on entry to `TESTINGSENSOR` or `TESTINGACTUATOR`. Behavior depends on `cmd.params.target`. |
| `handleRun` | `(obj, cmd)` | Called on entry to `RUNNING`. Must call `transition(State.POSTPROC)` on success. On abort: clear `rawData` and return. |
| `configureHardware` | `(obj, params) → logical` | Called by `enterConfigureValidate` for each sub-experiment. Return `true` if parameters are valid and hardware is configured. Return `false` to reject. |
| `stopHardware` | `(obj)` | Called on entry to `IDLE` and `ERROR`, and at exit from `RUNNING` and `TESTINGSENSOR`. Stop acquisitions and safe-state hardware. |
| `shutdownHardware` | `(obj)` | Called once at the start of `shutdown()`. Full cleanup: release sessions, close files, etc. |

### Optional overrideable methods

| Method | When to override |
|---|---|
| `setupCurrentExperiment()` | Add per-run setup (reset buffers, load run-specific params). Always call the base first: `setupCurrentExperiment@ExperimentManager(obj)`. |
| `enterPostProc()` | Add node-specific post-processing (filtering, decoupling, derived values). Always call the base last: `enterPostProc@ExperimentManager(obj)`. |
| `onMessageCallback(topic, msg)` | Override for nodes that subscribe to additional topics beyond `/cmd`. Default routes all messages to `handleCommand`. |
| `awaitReady(sc)` | Override to implement inter-run settling logic. Base returns `true` immediately. Called between sub-experiments when `settleCheck.enabled = true`. |

### Constructor

```matlab
mgr = MyNodeManager(cfg, comm, rest);
```

The constructor:
1. Stores `cfg`, `comm`, `rest`
2. Loads `calibrationGains.mat` from the current working directory if present (silent if absent)
3. Calls `comm.connect()` — do not call this separately
4. Calls `rest.checkHealth()` — throws if the REST server is unreachable
5. Calls `initializeHardware(cfg)`
6. Transitions to `IDLE`

### Public methods

| Method | Description |
|---|---|
| `handleCommand(cmd)` | Main command entry point. Routes a decoded command struct to the appropriate FSM transition. Normally called via `onMessageCallback`. |
| `abort(reason)` | Publishes an ERROR status, sets `abortRequested = true`, calls `stopHardware()`, and transitions to `ERROR`. |
| `log(level, msg)` | Publishes a structured log entry to `<clientID>/log` and appends to `FSMLog`. Also flushes to disk immediately. |
| `getState()` | Returns the current FSM state as a string. |
| `getBiasTable()` | Returns the current sensor bias table loaded or computed by `handleCalibrate`. |
| `getExperimentData()` | Returns `experimentData` from the last run. |
| `shutdown()` | Saves MQTT log, FSM log, and FSM history to `<clientID>Logs/`, then disconnects. |
| `flushLogs()` | Appends any unwritten `FSMLog` and `comm.messageLog` entries to disk in append mode. Called after every `log()` call. |

### handleCommand dispatch

All commands arrive as JSON on `<clientID>/cmd` and are decoded by `onMessageCallback` before reaching `handleCommand`.

| Command | Required fields | State transition | Notes |
|---|---|---|---|
| `Calibrate` | `cmd` | `IDLE → CALIBRATING` | May loop: `CALIBRATING → CALIBRATING` for multi-step flows |
| `Test` | `cmd`, `params.target` | `IDLE → TESTINGSENSOR` (sensor) or `IDLE → CONFIGUREVALIDATE` (actuator) | |
| `Run` | `cmd`, `params` | `IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING` | Waits for `RunValid` to proceed |
| `TestValid` | `cmd` | `CONFIGUREPENDING → TESTINGACTUATOR` | Uses params cached from the prior `Test` command |
| `RunValid` | `cmd` | `CONFIGUREPENDING → RUNNING` | |
| `Reset` | `cmd` | `ANY → IDLE` | Hard recovery |
| `Abort` | `cmd` | `ANY → ERROR` | Calls `abort()`; stops hardware immediately |
| `Update` | `cmd` | `IDLE → shutdown → exit(42)` | Only accepted from IDLE. Publishes `UPDATING` status, shuts down cleanly, then exits with code 42 so `pull_and_deploy.sh` can re-pull and relaunch. |

### Configuration struct

| Field | Type | Default | Description |
|---|---|---|---|
| `clientID` | `string` | **Required** | Unique node identifier. Used for MQTT topics, log filenames, and data directory names. |
| `hardware.hasSensor` | `logical` | `false` | Gates entry into `CALIBRATING` and `TESTINGSENSOR`. |
| `hardware.hasActuator` | `logical` | `false` | Gates entry into `TESTINGACTUATOR`. |
| `hardware.settleCheck` | `struct` | `{}` | Node-level inter-run settling defaults. See settleCheck below. |

### settleCheck

Controls the inter-run readiness gate in multi-experiment mode. Active between sub-experiments when `enabled = true`. Can be set at node level (`cfg.hardware.settleCheck`) or overridden per experiment run (`experimentSpec.params.settleCheck`). Run-level config takes priority.

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `logical` | `false` | Master switch. If false, `awaitReady` is skipped entirely. |
| `threshold` | `double` | — | Signal magnitude that counts as settled. Units are node-defined. |
| `thresholdUnits` | `string` | — | Human-readable unit label for log output. |
| `holdDuration_s` | `double` | — | Seconds the signal must remain below threshold before the next sub-experiment starts. |

`awaitReady()` blocks indefinitely until the node signals ready — there is no timeout. `INTER_RUN_READY` is always published after settling.

### Logging and log files

Every call to `log()` does three things:
1. Publishes a JSON entry to `<clientID>/log` over MQTT
2. Appends to the in-memory `FSMLog`
3. Flushes to disk immediately (append mode)

At `shutdown()`, the following files are written to `<clientID>Logs/`:

| File | Content |
|---|---|
| `<clientID>_fsmLog.jsonl` | All entries from `log()` |
| `<clientID>_commLog.jsonl` | All raw MQTT messages received by CommClient |
| `<clientID>_fsmHistory.log` | Ordered list of every state transition |

---

## Complete configuration reference

All fields accepted by any of the four classes. A node typically needs a subset.

| Field | Used by | Type | Default | Description |
|---|---|---|---|---|
| `clientID` | All | `string` | **Required** | Unique node identifier. |
| `brokerAddress` | CommClient, RestClient | `string` | `'localhost'` | Hostname or IP of the MQTT broker and REST server. |
| `brokerPort` | CommClient | `int` | `1883` | MQTT broker port. |
| `restPort` | RestClient | `int` | `5000` | REST server port. |
| `subscriptions` | CommClient | `cell array` | `{clientID/cmd}` | MQTT topics to subscribe to. |
| `publications` | CommClient | `cell array` | `{clientID/status, clientID/data, clientID/log}` | MQTT topics this node publishes to. |
| `onMessageCallback` | CommClient | `function_handle` | `[]` | Inbound message handler. |
| `heartbeatInterval` | CommClient | `double` | `0` | Heartbeat period in seconds. `0` disables it. |
| `keepAliveDuration` | CommClient | `duration` | `seconds(60)` | MQTT keep-alive window. |
| `verbose` | CommClient, RestClient | `logical` | `false` | Verbose console output. |
| `timeout` | RestClient | `numeric` | `15` | HTTP request timeout in seconds. |
| `hardware.hasSensor` | ExperimentManager | `logical` | `false` | Enables sensor states. |
| `hardware.hasActuator` | ExperimentManager | `logical` | `false` | Enables actuator states. |
| `hardware.settleCheck` | ExperimentManager | `struct` | `{}` | Inter-run settling config. |

### Example: sensor and actuator node

```matlab
cfg = struct();
cfg.clientID          = 'hybridNode1';
cfg.brokerAddress     = 'lab-server.local';
cfg.heartbeatInterval = 10;
cfg.verbose           = false;
cfg.hardware.hasSensor   = true;
cfg.hardware.hasActuator = true;

comm = CommClient(cfg);
comm.onMessageCallback = @(t, m) mgr.onMessageCallback(t, m);
rest = RestClient(cfg);
mgr  = MyHybridManager(cfg, comm, rest);
```

---

## Testing

`test/matlabCommon/` contains standalone test scripts for each class:

| Script | What it covers |
|---|---|
| `CommClientTestScript.m` | Connection, publish, subscribe, heartbeat, message log |
| `RestClientTestScript.m` | POST, GET, health check, error handling |
| `NodeManagerTestScript.m` | FSM transitions, command dispatch, abort, shutdown |

`TestNodeManager.m` is the mock subclass used by `NodeManagerTestScript.m`. `VirtualIntegrationTest/` contains a multi-node integration test.

---

## Dependencies

- MATLAB R2021b or later
- Industrial Communication Toolbox (for `mqttclient`)
- MATLAB Web Access (`webwrite`, `webread`) — included in base MATLAB
