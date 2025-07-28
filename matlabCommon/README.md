# MATLAB Common Utilities

## Overview

The matlabCommon folder contains core reusable MATLAB classes and architecture documentation for distributed experimentation nodes. These modules abstract MQTT communication, experiment control logic, and node state handling to streamline the development of automation nodes in the experimental framework.

This package is designed to be integrated into node-level scripts where the combination of `CommClient.m`, `ExperimentManager.m`, and `State.m` enables flexible, modular, and robust control.

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
- `addToLog(topic, msg)`: Saves a message into the capped internal log (max 100 entries).
- `getFullTopic(suffix)`: Returns the full topic path, e.g., `clientID/log`.

#### `cfg` or Constructor Fields
| Field              | Type             | Default Value         | Description |
|-------------------|------------------|------------------------|-------------|
| `clientID`         | `string`         | **Required**           | Unique node identifier. |
| `brokerAddress`    | `string`         | `'localhost'`          | MQTT broker hostname or IP. |
| `brokerPort`       | `int`            | `1883`                 | MQTT broker port. |
| `subscriptions`    | `cell array`     | `{clientID/cmd}`       | Topics to subscribe to on connect. |
| `publications`     | `cell array`     | `{clientID/status, clientID/data, clientID/log}` | Topics allowed for publication. |
| `onMessageCallback`| `function_handle`| `[]`                   | Custom callback for routing received messages. |
| `heartbeatInterval`| `double`         | `0` (disabled)         | Seconds between automatic heartbeat publications. |
| `keepAliveDuration`| `duration`       | `seconds(60)`          | MQTT keepalive duration for broker health. |
| `verbose`          | `logical`        | `false`                | Enables debug/trace printouts. |

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

### [`ExperimentManager.m`](ExperimentManager.m)
Abstract class defining the high-level logic controller for a node. Intended to be subclassed/inherited by devs to define how commands are handled. Provides integration with `CommClient` for inbound messages and maintains internal state using `State.m`.

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

The `cfg` struct passed into the constructor should include:

| Field                  | Description                                                                      |
|------------------------|----------------------------------------------------------------------------------|
| `mqtt.topics.*`        | MQTT topic mappings for `status`, `log`, and `error`. Used by `CommClient`.     |
| `hardware.hasSensor`   | Boolean flag to indicate sensor presence. Used for gatekeeping calibration/test. |
| `hardware.hasActuator` | Boolean flag to indicate actuator presence. Used for gating actuator operations. |

#### handleCommand() Overview

The `handleCommand()` method routes incoming MQTT messages to the correct logic handler based on their `cmd` field. It validates inputs, manages state transitions, and invokes command-specific subclass methods.

##### ✅ Supported Commands

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
IDLE → TESTINGACTUATOR (otherwise)
```

**Notes:**
- Enables sensor/actuator diagnostics.
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
| `Calibrate`   | `cmd`, `params.depth` or `finished` | IDLE → CALIBRATING (repeated)       | `handleCalibrate` | For collecting or finalizing calibration |
| `Test`        | `cmd`, `params.target`        | IDLE → TESTINGSENSOR or CONFIGUREVALIDATE → CONFIGUREPENDING | `handleTest`     | Sensor/actuator diagnostics              |
| `Run`         | `cmd`, `params`               | IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING | `handleRun`      | Requires config validation               |
| `TestValid`   | `cmd`, `params` (optional)    | CONFIGUREPENDING → TESTINGACTUATOR  | `handleTest`     | For config preview                       |
| `RunValid`    | `cmd`                         | CONFIGUREPENDING → RUNNING          | `handleRun`      | Final execution start                    |
| `Reset`       | `cmd`                         | ANY → IDLE                          | —                | Hard stop                                |
| `Abort`       | `cmd`                         | ANY → ERROR                         | `abort(reason)`  | Emergency abort                          |

---

## 🧪 Testing

The `CommClientTestScript.m` and `NodeManagerTestScipt.m` in the root folder tests provides a comprehensive validation of all major methods for the files in this folder. Reference the `README.md` in that folder for more information.

---

## 🧰 Developer Notes

- `CommClient` is designed to be thread-safe and event-driven.
- `onMessageCallback` should be passed in as there is currently no functionallity here except logging messages
- Heartbeats are optional but recommended for monitoring.
- All message routing is done via function handles. Developers are encouraged to keep `CommClient` generic and place application logic in `ExperimentManager`.
- More notes on using both of these files will be present in the node_scafolding_matlab folder

---

## 📌 Dependencies

- MATLAB R2021b or later recommended
- Industrial Communication Toolbox

---