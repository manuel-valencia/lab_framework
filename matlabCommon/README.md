# MATLAB Common Utilities

## Overview

The matlabCommon folder contains core reusable MATLAB classes and architecture documentation for distributed experimentation nodes. These modules abstract MQTT communication, REST API data transfer, experiment control logic, and node state handling to streamline the development of automation nodes in the experimental framework.

This package is designed to be integrated into node-level scripts where the combination of `CommClient.m`, `RestClient.m`, `ExperimentManager.m`, and `State.m` enables flexible, modular, and robust control.

---

## 📁 Contents

### `CommClient.m`
Handles MQTT-based communication for distributed nodes. Provides functions for connection management, message publishing/subscription, heartbeat handling, and message logging. Designed for actuator, sensor, and control/master nodes.

#### Key Functions
- `connect()`: Connects to the MQTT broker and subscribes to relevant topics.
- `disconnect()`: Stops the heartbeat timer (if running), disconnects from the broker, and cleans up resources.
- `commPublish(topic, payload)`: Publishes a message to a specified topic.
- `commSubscribe(topic)`: Subscribes to a new topic at runtime and registers the default callback.
- `commUnsubscribe(topic)`: Unsubscribes from a given topic and updates the internal subscription list.
- `sendHeartbeat()`: Publishes a periodic status message.
- `handleMessage(topic, msg)`: Internal callback that logs incoming messages and routes them to user-defined callbacks.
- `addToLog(topic, msg)`: Saves a message into the capped internal log (max 1000 entries).
- `getFullTopic(suffix)`: Returns the full topic path, e.g., `clientID/log`.

#### `cfg` or Constructor Fields
| Field                  | Type              | Default Value                                    | Description                                                       |
| ---------------------- | ----------------- | ------------------------------------------------ | ----------------------------------------------------------------- |
| `clientID`             | `string`          | **Required**                                     | Unique node identifier for MQTT topic resolution.                 |
| `brokerAddress`        | `string`          | `'localhost'`                                    | Hostname or IP address of MQTT broker.                            |
| `brokerPort`           | `int`             | `1883`                                           | MQTT broker port for message publishing and subscription.         |
| `subscriptions`        | `cell array`      | `{clientID/cmd}`                                 | Topics this node subscribes to via MQTT (incoming commands).      |
| `publications`         | `cell array`      | `{clientID/status, clientID/data, clientID/log}` | Topics this node publishes to via MQTT (status, data, logs).      |
| `onMessageCallback`    | `function_handle` | `[]`                                             | Optional callback for routing inbound MQTT messages to handlers.  |
| `heartbeatInterval`    | `double`          | `0` (disabled)                                   | Interval in seconds between automatic status pings to the broker. |
| `keepAliveDuration`    | `duration`        | `seconds(60)`                                    | MQTT keep-alive timeout duration to maintain broker connection.   |
| `verbose`              | `logical`         | `false`                                          | Enables verbose logging and debugging messages to stdout.         |

#### Usage Examples

**Minimal Node:**
```matlab
cfg.clientID = 'sensorNode1';
cfg.verbose = true;
client = CommClient(cfg);
client.connect();
```

**Node with heartbeat and command callback:**

```matlab
cfg.clientID = 'actuator1';
cfg.heartbeatInterval = 5;
cfg.onMessageCallback = @(topic, msg) disp(['Received: ', msg]);
cfg.verbose = true;
client = CommClient(cfg);
client.connect();
```
---
### `RestClient.m`
Provides a lightweight HTTP interface for experiment nodes to POST data to and GET data from a central REST server. Designed for use in conjunction with CommClient for MQTT messaging and primarily used for transferring large experiment datasets that exceed MQTT message limits.

#### Key Functions
- `sendData(data, varargin)`: Sends experiment data to REST server as CSV or JSONL format.
- `fetchData(varargin)`: Retrieves experiment data from REST server with various filtering options.
- `checkHealth()`: Checks if the REST server is online by calling the /health endpoint.
- `convertToCSV(tbl)`: Static method that converts MATLAB table to CSV string for POST requests.

#### `cfg` or Constructor Fields
| Field                  | Type              | Default Value                                    | Description                                                       |
| ---------------------- | ----------------- | ------------------------------------------------ | ----------------------------------------------------------------- |
| `clientID`             | `string`          | **Required**                                     | Unique node identifier for REST API endpoint resolution.          |
| `brokerAddress`        | `string`          | `'localhost'`                                    | Hostname or IP address of REST server.                            |
| `restPort`             | `int`             | `5000`                                           | REST server port for HTTP API access.                             |
| `verbose`              | `logical`         | `false`                                          | Enables verbose logging and debugging messages to stdout.         |
| `timeout`              | `numeric`         | `15`                                             | HTTP request timeout duration in seconds.                         |

#### Usage Examples

**Basic Data Posting:**
```matlab
cfg.clientID = 'sensorNode1';
cfg.verbose = true;
restClient = RestClient(cfg);

% Send table data as CSV
response = restClient.sendData(dataTable, 'experimentName', 'test1');

% Send struct array as JSONL
response = restClient.sendData(dataStruct, 'experimentName', 'test2', 'format', 'jsonl');
```

**Data Retrieval:**
```matlab
cfg.clientID = 'masterNode';
restClient = RestClient(cfg);

% Get latest data from a specific node
latestData = restClient.fetchData('clientID', 'sensorNode1', 'latest', true);

% Get specific experiment data
expData = restClient.fetchData('clientID', 'waveGenNode', 'experimentName', 'wave_test_1', 'format', 'csv');
```

**Health Check:**
```matlab
cfg.clientID = 'healthChecker';
restClient = RestClient(cfg);

if restClient.checkHealth()
    fprintf('REST server is online\n');
else
    fprintf('REST server is offline\n');
end
```

---
### `State.m`
This file defines a finite set of enumerated states for the automation framework. They will be the canonical states used by the ExperimentManager to coordinate the behavior of each node. This enumeration enables each node to track and transition through well-defined operational phases, ensuring that all components in the system—whether master or peripheral nodes—maintain coherent execution logic. It supports both system coordination and logging/telemetry clarity.

#### Defined States and Their Responsibilities
| State              | Integer | Description                                                                 |
|-------------------|---------|-----------------------------------------------------------------------------|
| `BOOT`            | 0       | Initial state entered immediately after node instantiation. Hardware and software are initializing. No communication is assumed. |
| `IDLE`            | 1       | Default wait state where the node is connected to the broker and ready to receive commands, but no configuration or calibration has been issued. |
| `CALIBRATING`     | 2       | The node is executing a calibration routine (e.g., bias collection, baseline alignment). |
| `TESTINGSENSOR`   | 3       | The node is posting live sensor data for diagnostics or validation. |
| `CONFIGUREVALIDATE` | 4     | The node is validating a received experiment configuration file against hardware constraints or experiment bounds and will send confirmation plots or error message if constraints are not met.|
| `CONFIGUREPENDING`| 5       | A valid configuration was received but is pending user validation before running experimental equipment. |
| `TESTINGACTUATOR` | 6       | The node is testing actuator functionality, motion response, or limits as a pre-check before full execution. |
| `RUNNING`         | 7       | Active experiment state. The node is executing its assigned role (e.g., force collection, motion control, wave generation). |
| `POSTPROC`        | 8       | Post-processing state for computing derived values, saving results, or finalizing logs before next experiment. |
| `DONE`            | 9       | The node has completed its task and will send collected data over to user and reset equipment if needed. |
| `ERROR`           | 10      | Fault state indicating failure during operation. The node should halt safely, log the fault, and await recovery instruction. |

---

### `ExperimentManager.m`
Abstract class defining the high-level logic controller for a node. Intended to be subclassed/inherited by devs to define how commands are handled. Provides integration with `CommClient` for inbound MQTT messages and `RestClient` for data transfer, while maintaining internal state using `State.m`.

#### 🏗️ Constructor

```matlab
obj = ExperimentManager(cfg, comm, rest)
```

**Parameters:**
- `cfg` - Configuration struct (includes MQTT topics and hardware flags)
- `comm` - CommClient instance for MQTT messaging  
- `rest` - RestClient instance for REST API communication

**Example:**
```matlab
% Setup configuration
cfg.clientID = 'sensorNode1';
cfg.hardware.hasSensor = true;

% Create communication clients
comm = CommClient(cfg);
rest = RestClient(cfg);

% Create node manager
mgr = MySensorManager(cfg, comm, rest);
```

#### ⚙️ Subclass Implementation Requirements

Developers extending `ExperimentManager` **must** implement the following methods:

| Function              | Purpose                                                                 |
|-----------------------|-------------------------------------------------------------------------|
| `initializeHardware`  | Initializes node-specific sensors/actuators using the passed config.    |
| `handleCalibrate`     | Handles sensor calibration logic when in the `CALIBRATING` state.       |
| `handleTest`          | Executes testing logic for sensors or actuators, depending on command. |
| `handleRun`           | Begins the main experiment routine using configuration parameters.      |
| `configureHardware`   | Validates and applies experiment configuration (`cmd.params`). Returns `true` if successful. |
| `stopHardware`        | Called during state exits to halt actuators or terminate readings.      |
| `shutdownHardware`    | Called only on full shutdown or object deletion (optional cleanup).     |

#### 🧰 Developer-Accessible Public Methods

| Method                 | Purpose                                                                                     |
|------------------------|---------------------------------------------------------------------------------------------|
| `handleCommand(cmd)`   | Central entry point to route structured command JSON to the appropriate FSM transition.     |
| `abort(reason)`        | Forces transition to `ERROR`, logs message, and calls `stopHardware`.                       |
| `getState()`           | Returns the current FSM state as a string.                                                  |
| `getBiasTable()`       | Returns the last loaded or computed sensor bias table.                                      |
| `log(level, msg)`      | Unified logging method that publishes to MQTT /log topic and stores internally.             |
| `onMessageCallback(topic, msg)` | Generic MQTT message handler that decodes JSON and routes commands to handleCommand. |
| `shutdown()`           | Unified shutdown routine that saves logs, FSM history, and disconnects clients.             |
| `setupCurrentExperiment()` | Prepares current experiment parameters (can be overridden by subclasses).               |

#### 🔐 Protected FSM/Internal Utilities

| Method                  | Functionality                                                                 |
|--------------------------|-------------------------------------------------------------------------------|
| `transition(newState)`  | Validates and applies FSM state transitions. Logs state entry/exit messages. |
| `isValidTransition(from, to)` | Returns `true` if the requested state transition is permitted.          |
| `enterState(s)`         | Publishes MQTT status and triggers state-specific entry logic.               |
| `exitState(s)`          | Calls cleanup logic before exiting special states like `RUNNING`, etc.       |

Each FSM state has a corresponding `enter<State>` and some have an `exit<State>` method. These can be extended in subclasses if finer control is needed, although the default base class implementations are typically sufficient for:

- Logging
- Command gating
- Internal signaling

#### 🧩 Configuration Input Structure

The `cfg` struct passed into the ExperimentManager constructor should include:

| Field                  | Description                                                                      |
|------------------------|----------------------------------------------------------------------------------|
| `clientID`             | **Required** - Unique node identifier used for logging and data file naming.     |
| `hardware.hasSensor`   | Boolean flag to indicate sensor presence. Used for gatekeeping calibration/test. |
| `hardware.hasActuator` | Boolean flag to indicate actuator presence. Used for gating actuator operations. |

#### handleCommand() Overview

The `handleCommand()` method routes incoming MQTT messages to the correct logic handler based on their `cmd` field. It validates inputs, manages state transitions, and invokes command-specific subclass methods.

##### ✅ Supported Commands

Below is a list of supported Commands and their effects. All commands must have the proper fields for the node to be able to properly handle the commands. However params list can be extended for node application and other fields can be added (i.e. timestamp) besides cmd and params without error.

###### 1. `cmd = "Calibrate"`
**Expected Format:**
```matlab
struct("cmd", "Calibrate", "params", struct("depth", 5.0))
struct("cmd", "Calibrate", "params", struct("finished", true))
```

**State Transitions:**
```
IDLE → CALIBRATING (repeated)
```

**Notes:**
- Collects and finalizes calibration points.
- `finished=true` triggers slope/intercept fitting and returns to IDLE.

---

###### 2. `cmd = "Test"`
**Expected Format:**
```matlab
struct("cmd", "Test", "params", struct("target", "sensor"))
struct("cmd", "Test", "params", struct("target", "actuator"))
```

**State Transitions:**
```
IDLE → TESTINGSENSOR (if target == "sensor")
IDLE → CONFIGUREVALIDATE (if target != "sensor")
```

**Notes:**
- Enables sensor/actuator diagnostics.
- For sensor testing, goes directly to TESTINGSENSOR state.
- For actuator testing, saves experimentSpec and validates configuration first.
- Behavior is subclass-dependent.

---

###### 3. `cmd = "Run"`
**Expected Format:**
```matlab
struct("cmd", "Run", "params", struct(...))
```

**State Transitions:**
```
IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING (if valid)
```

**Notes:**
- Saves `experimentSpec = cmd`.
- Waits for RunValid confirmation.

---

###### 4. `cmd = "TestValid"`
**Expected Format:**
```matlab
struct("cmd", "TestValid", "params", struct(...))
```

**State Transitions:**
```
CONFIGUREPENDING → TESTINGACTUATOR
```

**Notes:**
- Optionally test actuator after validating Run configuration.

---

###### 5. `cmd = "RunValid"`
**Expected Format:**
```matlab
struct("cmd", "RunValid")
```

**State Transitions:**
```
CONFIGUREPENDING → RUNNING
```

**Notes:**
- Final approval for Run execution.
- Only valid if already in CONFIGUREPENDING.

---

###### 6. `cmd = "Reset"`
**Expected Format:**
```matlab
struct("cmd", "Reset")
```

**State Transitions:**
```
ANY → IDLE
```

**Notes:**
- Hard reset.
- Used for recovery from errors or after test.

---

###### 7. `cmd = "Abort"`
**Expected Format:**
```matlab
struct("cmd", "Abort")
```

**State Transitions:**
```
ANY → ERROR
```

**Notes:**
- Emergency stop.
- Logs reason, stops hardware, transitions to ERROR.

---

##### 📌 Summary Table

| Command       | Required Fields              | Transition(s)                       | Handler         | Notes                                    |
|---------------|-------------------------------|-------------------------------------|------------------|------------------------------------------|
| `Calibrate`   | `cmd`, `params` or `finished` | IDLE → CALIBRATING (repeated)       | `handleCalibrate` | For collecting or finalizing calibration |
| `Test`        | `cmd`, `params.target`        | IDLE → TESTINGSENSOR or IDLE → CONFIGUREVALIDATE | `handleTest`     | Sensor/actuator diagnostics              |
| `Run`         | `cmd`, `params`               | IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING | `handleRun`      | Requires config validation               |
| `TestValid`   | `cmd`, `params` (optional)    | CONFIGUREPENDING → TESTINGACTUATOR  | `handleTest`     | For config preview                       |
| `RunValid`    | `cmd`                         | CONFIGUREPENDING → RUNNING          | `handleRun`      | Final execution start                    |
| `Reset`       | `cmd`                         | ANY → IDLE                          | —                | Hard stop                                |
| `Abort`       | `cmd`                         | ANY → ERROR                         | `abort(reason)`  | Emergency abort                          |

---

## 🧩 Complete Configuration Reference

The following table provides a comprehensive reference of all configuration fields used across the matlabCommon classes. When creating a node, you typically need to provide a subset of these fields depending on which classes you're using.

| Field                  | Used By           | Type              | Default Value                                    | Description                                                       |
| ---------------------- | ----------------- | ----------------- | ------------------------------------------------ | ----------------------------------------------------------------- |
| `clientID`             | All Classes       | `string`          | **Required**                                     | Unique node identifier used across all components.                |
| `brokerAddress`        | CommClient, RestClient | `string`     | `'localhost'`                                    | Hostname or IP address of MQTT broker and REST server.           |
| `brokerPort`           | CommClient        | `int`             | `1883`                                           | MQTT broker port for message publishing and subscription.         |
| `restPort`             | RestClient        | `int`             | `5000`                                           | REST server port for HTTP API access.                             |
| `subscriptions`        | CommClient        | `cell array`      | `{clientID/cmd}`                                 | Topics this node subscribes to via MQTT (incoming commands).      |
| `publications`         | CommClient        | `cell array`      | `{clientID/status, clientID/data, clientID/log}` | Topics this node publishes to via MQTT (status, data, logs).      |
| `onMessageCallback`    | CommClient        | `function_handle` | `[]`                                             | Optional callback for routing inbound MQTT messages to handlers.  |
| `heartbeatInterval`    | CommClient        | `double`          | `0` (disabled)                                   | Interval in seconds between automatic status pings to the broker. |
| `keepAliveDuration`    | CommClient        | `duration`        | `seconds(60)`                                    | MQTT keep-alive timeout duration to maintain broker connection.   |
| `verbose`              | CommClient, RestClient | `logical`     | `false`                                          | Enables verbose logging and debugging messages to stdout.         |
| `timeout`              | RestClient        | `numeric`         | `15`                                             | HTTP request timeout duration in seconds.                         |
| `hardware.hasSensor`   | ExperimentManager | `logical`         | `false`                                          | Boolean flag to indicate sensor presence. Used for gatekeeping calibration/test. |
| `hardware.hasActuator` | ExperimentManager | `logical`         | `false`                                          | Boolean flag to indicate actuator presence. Used for gating actuator operations. |

### Example Complete Configuration

```matlab
% Complete configuration for a sensor+actuator node
cfg = struct();
cfg.clientID = 'hybridNode1';
cfg.brokerAddress = 'lab-server.local';
cfg.brokerPort = 1883;
cfg.restPort = 5000;
cfg.verbose = true;
cfg.heartbeatInterval = 10;
cfg.timeout = 30;
cfg.hardware.hasSensor = true;
cfg.hardware.hasActuator = true;

% Create all components
comm = CommClient(cfg);
rest = RestClient(cfg);
mgr = MyHybridManager(cfg, comm, rest);
```

---

## 🧪 Testing

The `CommClientTestScript.m`, `RestClientTestScript.m`, and `NodeManagerTestScript.m` in the `test/matlabCommon` folder provide comprehensive validation of all major methods for the classes in this package. Each test script is standalone and includes both positive and negative test cases.

- **CommClientTestScript.m** - Tests MQTT communication, subscriptions, heartbeats, and message handling
- **RestClientTestScript.m** - Tests REST API data posting, retrieval, health checks, and error handling  
- **NodeManagerTestScript.m** - Tests ExperimentManager FSM logic using TestNodeManager mock implementation

---

## 🧰 Developer Notes

- `CommClient` is designed to be thread-safe and event-driven.
- `onMessageCallback` generic function is provided in the ExperimentManager.m class but can be overwritten for improved functionality if need. (This goes for enterState functions as well but be careful to test properly before deploying).
- Heartbeats are optional but recommended for monitoring.
- All message routing is done via function handles. Developers are encouraged to keep `CommClient` generic and place application logic in `ExperimentManager`.
- `RestClient` handles large data transfers that exceed MQTT message limits.
- Both `CommClient` and `RestClient` must be instantiated before creating an `ExperimentManager` instance.
- More notes on using these classes together will be present in the `node_scafolding_matlab` folder.

---

## 📌 Dependencies

- MATLAB R2021b or later recommended
- Industrial Communication Toolbox

---