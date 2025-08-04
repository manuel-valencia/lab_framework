# Python Common Utilities

## Overview

The pythonCommon folder contains core reusable Python classes and architecture documentation for distributed experimentation nodes. These modules abstract MQTT communication, REST API data transfer, experiment control logic, and node state handling to streamline the development of automation nodes in the experimental framework.

This package is designed to be integrated into node-level scripts where the combination of `CommClient.py`, `RestClient.py`, and `ExperimentManager.py` enables flexible, modular, and robust control.

---

## 📁 Contents

### `CommClient.py`
Handles MQTT-based communication for distributed nodes. Provides functions for connection management, message publishing/subscription, heartbeat handling, and message logging. Designed for actuator, sensor, and control/master nodes.

#### Key Functions
- `connect()`: Connects to the MQTT broker and subscribes to relevant topics.
- `disconnect()`: Stops the heartbeat timer (if running), disconnects from the broker, and cleans up resources.
- `comm_publish(topic, payload)`: Publishes a message to a specified topic.
- `comm_subscribe(topic)`: Subscribes to a new topic at runtime and registers the default callback.
- `comm_unsubscribe(topic)`: Unsubscribes from a given topic and updates the internal subscription list.
- `send_heartbeat()`: Publishes a periodic status message.
- `handle_message(topic, msg)`: Internal callback that logs incoming messages and routes them to user-defined callbacks.
- `add_to_log(topic, msg)`: Saves a message into the capped internal log (max 1000 entries).
- `get_full_topic(suffix)`: Returns the full topic path, e.g., `clientID/log`.

#### Configuration Fields
| Field                  | Type              | Default Value                                    | Description                                                       |
| ---------------------- | ----------------- | ------------------------------------------------ | ----------------------------------------------------------------- |
| `clientID`             | `str`             | **Required**                                     | Unique node identifier for MQTT topic resolution.                 |
| `brokerAddress`        | `str`             | `'localhost'`                                    | Hostname or IP address of MQTT broker.                            |
| `brokerPort`           | `int`             | `1883`                                           | MQTT broker port for message publishing and subscription.         |
| `subscriptions`        | `List[str]`       | `[clientID/cmd]`                                 | Topics this node subscribes to via MQTT (incoming commands).      |
| `publications`         | `List[str]`       | `[clientID/status, clientID/data, clientID/log]` | Topics this node publishes to via MQTT (status, data, logs).      |
| `onMessageCallback`    | `Callable`        | `None`                                           | Optional callback for routing inbound MQTT messages to handlers.  |
| `heartbeatInterval`    | `float`           | `0` (disabled)                                   | Interval in seconds between automatic status pings to the broker. |
| `keepAliveDuration`    | `int`             | `60`                                             | MQTT keep-alive timeout duration to maintain broker connection.   |
| `verbose`              | `bool`            | `False`                                          | Enables verbose logging and debugging messages to stdout.         |

#### Usage Examples

**Minimal Node:**
```python
config = {
    'clientID': 'sensorNode1',
    'verbose': True
}
client = CommClient(config)
client.connect()
```

**Node with heartbeat and command callback:**

```python
def message_handler(topic, msg):
    print(f'Received: {msg}')

config = {
    'clientID': 'actuator1',
    'heartbeatInterval': 5,
    'onMessageCallback': message_handler,
    'verbose': True
}
client = CommClient(config)
client.connect()
```
---
### `RestClient.py`
Provides a lightweight HTTP interface for experiment nodes to POST data to and GET data from a central REST server. Designed for use in conjunction with CommClient for MQTT messaging and primarily used for transferring large experiment datasets that exceed MQTT message limits.

#### Key Functions
- `send_data(data, **kwargs)`: Sends experiment data to REST server as CSV or JSONL format.
- `fetch_data(**kwargs)`: Retrieves experiment data from REST server with various filtering options.
- `check_health()`: Checks if the REST server is online by calling the /health endpoint.
- `convert_to_csv(tbl)`: Static method that converts pandas DataFrame to CSV string for POST requests.

#### Configuration Fields
| Field                  | Type              | Default Value                                    | Description                                                       |
| ---------------------- | ----------------- | ------------------------------------------------ | ----------------------------------------------------------------- |
| `clientID`             | `str`             | **Required**                                     | Unique node identifier for REST API endpoint resolution.          |
| `brokerAddress`        | `str`             | `'localhost'`                                    | Hostname or IP address of REST server.                            |
| `restPort`             | `int`             | `5000`                                           | REST server port for HTTP API access.                             |
| `verbose`              | `bool`            | `False`                                          | Enables verbose logging and debugging messages to stdout.         |
| `timeout`              | `int`             | `15`                                             | HTTP request timeout duration in seconds.                         |

#### Usage Examples

**Basic Data Posting:**
```python
config = {
    'clientID': 'sensorNode1',
    'verbose': True
}
rest_client = RestClient(config)

# Send DataFrame data as CSV
response = rest_client.send_data(dataframe, experiment_name='test1')

# Send list of dicts as JSONL
response = rest_client.send_data(data_list, experiment_name='test2', format='jsonl')
```

**Data Retrieval:**
```python
config = {'clientID': 'masterNode'}
rest_client = RestClient(config)

# Get latest data from a specific node
latest_data = rest_client.fetch_data(clientID='sensorNode1', latest=True)

# Get specific experiment data
exp_data = rest_client.fetch_data(clientID='waveGenNode', experiment_name='wave_test_1', format='csv')
```

**Health Check:**
```python
config = {'clientID': 'healthChecker'}
rest_client = RestClient(config)

if rest_client.check_health():
    print('REST server is online')
else:
    print('REST server is offline')
```

---
### `ExperimentManager.py`
Abstract class defining the high-level logic controller for a node. Intended to be subclassed/inherited by developers to define how commands are handled. Provides integration with `CommClient` for inbound MQTT messages and `RestClient` for data transfer, while maintaining internal state using the `State` enumeration.

#### State Enumeration
The `State` enum defines the finite set of states for the automation framework:

| State              | Value | Description                                                                 |
|-------------------|-------|-----------------------------------------------------------------------------|
| `BOOT`            | 0     | Initial state entered immediately after node instantiation. Hardware and software are initializing. No communication is assumed. |
| `IDLE`            | 1     | Default wait state where the node is connected to the broker and ready to receive commands, but no configuration or calibration has been issued. |
| `CALIBRATING`     | 2     | The node is executing a calibration routine (e.g., bias collection, baseline alignment). |
| `TESTINGSENSOR`   | 3     | The node is posting live sensor data for diagnostics or validation. |
| `CONFIGUREVALIDATE` | 4   | The node is validating a received experiment configuration file against hardware constraints or experiment bounds and will send confirmation plots or error message if constraints are not met.|
| `CONFIGUREPENDING`| 5     | A valid configuration was received but is pending user validation before running experimental equipment. |
| `TESTINGACTUATOR` | 6     | The node is testing actuator functionality, motion response, or limits as a pre-check before full execution. |
| `RUNNING`         | 7     | Active experiment state. The node is executing its assigned role (e.g., force collection, motion control, wave generation). |
| `POSTPROC`        | 8     | Post-processing state for computing derived values, saving results, or finalizing logs before next experiment. |
| `DONE`            | 9     | The node has completed its task and will send collected data over to user and reset equipment if needed. |
| `ERROR`           | 10    | Fault state indicating failure during operation. The node should halt safely, log the fault, and await recovery instruction. |

#### 🏗️ Constructor

```python
mgr = ExperimentManager(cfg, comm, rest)
```

**Parameters:**
- `cfg` - Configuration dict (includes MQTT topics and hardware flags)
- `comm` - CommClient instance for MQTT messaging  
- `rest` - RestClient instance for REST API communication

**Example:**
```python
# Setup configuration
cfg = {
    'clientID': 'sensorNode1',
    'hardware': {'hasSensor': True}
}

# Create communication clients
comm = CommClient(cfg)
rest = RestClient(cfg)

# Create node manager
mgr = MySensorManager(cfg, comm, rest)
```

#### ⚙️ Subclass Implementation Requirements

Developers extending `ExperimentManager` **must** implement the following methods:

| Function              | Purpose                                                                 |
|-----------------------|-------------------------------------------------------------------------|
| `initialize_hardware` | Initializes node-specific sensors/actuators using the passed config.    |
| `handle_calibrate`    | Handles sensor calibration logic when in the `CALIBRATING` state.       |
| `handle_test`         | Executes testing logic for sensors or actuators, depending on command. |
| `handle_run`          | Begins the main experiment routine using configuration parameters.      |
| `configure_hardware`  | Validates and applies experiment configuration. Returns `True` if successful. |
| `stop_hardware`       | Called during state exits to halt actuators or terminate readings.      |
| `shutdown_hardware`   | Called only on full shutdown or object deletion (optional cleanup).     |

#### 🧰 Developer-Accessible Public Methods

| Method                 | Purpose                                                                                     |
|------------------------|---------------------------------------------------------------------------------------------|
| `handle_command(cmd)`  | Central entry point to route structured command JSON to the appropriate FSM transition.     |
| `abort(reason)`        | Forces transition to `ERROR`, logs message, and calls `stop_hardware`.                      |
| `get_state()`          | Returns the current FSM state as a string.                                                  |
| `get_bias_table()`     | Returns the last loaded or computed sensor bias table.                                      |
| `log(level, msg)`      | Unified logging method that publishes to MQTT /log topic and stores internally.             |
| `on_message_callback(topic, msg)` | Generic MQTT message handler that decodes JSON and routes commands to handle_command. |
| `shutdown()`           | Unified shutdown routine that saves logs, FSM history, and disconnects clients.             |
| `setup_current_experiment()` | Prepares current experiment parameters (can be overridden by subclasses).               |

#### 🔐 Protected FSM/Internal Utilities

| Method                  | Functionality                                                                 |
|--------------------------|-------------------------------------------------------------------------------|
| `transition(new_state)` | Validates and applies FSM state transitions. Logs state entry/exit messages. |
| `_is_valid_transition(from_state, to_state)` | Returns `True` if the requested state transition is permitted.          |
| `_enter_state(state)`   | Publishes MQTT status and triggers state-specific entry logic.               |
| `_exit_state(state)`    | Calls cleanup logic before exiting special states like `RUNNING`, etc.       |

Each FSM state has a corresponding `_enter_<state>` and some have an `_exit_<state>` method. These can be extended in subclasses if finer control is needed, although the default base class implementations are typically sufficient for:

- Logging
- Command gating
- Internal signaling

#### 🧩 Configuration Input Structure

The `cfg` dict passed into the ExperimentManager constructor should include:

| Field                  | Description                                                                      |
|------------------------|----------------------------------------------------------------------------------|
| `clientID`             | **Required** - Unique node identifier used for logging and data file naming.     |
| `hardware.hasSensor`   | Boolean flag to indicate sensor presence. Used for gatekeeping calibration/test. |
| `hardware.hasActuator` | Boolean flag to indicate actuator presence. Used for gating actuator operations. |

#### handle_command() Overview

The `handle_command()` method routes incoming MQTT messages to the correct logic handler based on their `cmd` field. It validates inputs, manages state transitions, and invokes command-specific subclass methods.

##### ✅ Supported Commands

Below is a list of supported Commands and their effects. All commands must have the proper fields for the node to be able to properly handle the commands. However params list can be extended for node application and other fields can be added (i.e. timestamp) besides cmd and params without error.

###### 1. `cmd = "Calibrate"`
**Expected Format:**
```python
{"cmd": "Calibrate", "params": {"depth": 5.0}}
{"cmd": "Calibrate", "params": {"finished": True}}
```

**State Transitions:**
```
IDLE → CALIBRATING (repeated)
```

**Notes:**
- Collects and finalizes calibration points.
- `finished=True` triggers slope/intercept fitting and returns to IDLE.

---

###### 2. `cmd = "Test"`
**Expected Format:**
```python
{"cmd": "Test", "params": {"target": "sensor"}}
{"cmd": "Test", "params": {"target": "actuator"}}
```

**State Transitions:**
```
IDLE → TESTINGSENSOR (if target == "sensor")
IDLE → CONFIGUREVALIDATE (if target != "sensor")
```

**Notes:**
- Enables sensor/actuator diagnostics.
- For sensor testing, goes directly to TESTINGSENSOR state.
- For actuator testing, saves experiment_spec and validates configuration first.
- Behavior is subclass-dependent.

---

###### 3. `cmd = "Run"`
**Expected Format:**
```python
{"cmd": "Run", "params": {...}}
```

**State Transitions:**
```
IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING (if valid)
```

**Notes:**
- Saves `experiment_spec = cmd`.
- Waits for RunValid confirmation.

---

###### 4. `cmd = "TestValid"`
**Expected Format:**
```python
{"cmd": "TestValid", "params": {...}}
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
```python
{"cmd": "RunValid"}
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
```python
{"cmd": "Reset"}
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
```python
{"cmd": "Abort"}
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
| `Calibrate`   | `cmd`, `params` or `finished` | IDLE → CALIBRATING (repeated)       | `handle_calibrate` | For collecting or finalizing calibration |
| `Test`        | `cmd`, `params.target`        | IDLE → TESTINGSENSOR or IDLE → CONFIGUREVALIDATE | `handle_test`     | Sensor/actuator diagnostics              |
| `Run`         | `cmd`, `params`               | IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING | `handle_run`      | Requires config validation               |
| `TestValid`   | `cmd`, `params` (optional)    | CONFIGUREPENDING → TESTINGACTUATOR  | `handle_test`     | For config preview                       |
| `RunValid`    | `cmd`                         | CONFIGUREPENDING → RUNNING          | `handle_run`      | Final execution start                    |
| `Reset`       | `cmd`                         | ANY → IDLE                          | —                | Hard stop                                |
| `Abort`       | `cmd`                         | ANY → ERROR                         | `abort(reason)`  | Emergency abort                          |

---

## 🧩 Complete Configuration Reference

The following table provides a comprehensive reference of all configuration fields used across the pythonCommon classes. When creating a node, you typically need to provide a subset of these fields depending on which classes you're using.

| Field                  | Used By           | Type              | Default Value                                    | Description                                                       |
| ---------------------- | ----------------- | ----------------- | ------------------------------------------------ | ----------------------------------------------------------------- |
| `clientID`             | All Classes       | `str`             | **Required**                                     | Unique node identifier used across all components.                |
| `brokerAddress`        | CommClient, RestClient | `str`        | `'localhost'`                                    | Hostname or IP address of MQTT broker and REST server.           |
| `brokerPort`           | CommClient        | `int`             | `1883`                                           | MQTT broker port for message publishing and subscription.         |
| `restPort`             | RestClient        | `int`             | `5000`                                           | REST server port for HTTP API access.                             |
| `subscriptions`        | CommClient        | `List[str]`       | `[clientID/cmd]`                                 | Topics this node subscribes to via MQTT (incoming commands).      |
| `publications`         | CommClient        | `List[str]`       | `[clientID/status, clientID/data, clientID/log]` | Topics this node publishes to via MQTT (status, data, logs).      |
| `onMessageCallback`    | CommClient        | `Callable`        | `None`                                           | Optional callback for routing inbound MQTT messages to handlers.  |
| `heartbeatInterval`    | CommClient        | `float`           | `0` (disabled)                                   | Interval in seconds between automatic status pings to the broker. |
| `keepAliveDuration`    | CommClient        | `int`             | `60`                                             | MQTT keep-alive timeout duration to maintain broker connection.   |
| `verbose`              | CommClient, RestClient | `bool`        | `False`                                          | Enables verbose logging and debugging messages to stdout.         |
| `timeout`              | RestClient        | `int`             | `15`                                             | HTTP request timeout duration in seconds.                         |
| `hardware.hasSensor`   | ExperimentManager | `bool`            | `False`                                          | Boolean flag to indicate sensor presence. Used for gatekeeping calibration/test. |
| `hardware.hasActuator` | ExperimentManager | `bool`            | `False`                                          | Boolean flag to indicate actuator presence. Used for gating actuator operations. |

### Example Complete Configuration

```python
# Complete configuration for a sensor+actuator node
cfg = {
    'clientID': 'hybridNode1',
    'brokerAddress': 'lab-server.local',
    'brokerPort': 1883,
    'restPort': 5000,
    'verbose': True,
    'heartbeatInterval': 10,
    'timeout': 30,
    'hardware': {
        'hasSensor': True,
        'hasActuator': True
    }
}

# Create all components
comm = CommClient(cfg)
rest = RestClient(cfg)
mgr = MyHybridManager(cfg, comm, rest)
```

---

## 🧪 Testing

The `test_comm_client.py`, `test_rest_client.py`, and `test_experiment_manager.py` in the `test/pythonCommon` folder provide comprehensive validation of all major methods for the classes in this package. Each test script is standalone and includes both positive and negative test cases.

- **test_comm_client.py** - Tests MQTT communication, subscriptions, heartbeats, and message handling
- **test_rest_client.py** - Tests REST API data posting, retrieval, health checks, and error handling  
- **test_experiment_manager.py** - Tests ExperimentManager FSM logic using MockNodeManager implementation

### Running Tests
```bash
# Run all tests
python -m pytest test/pythonCommon/ -v

# Run specific test file
python -m pytest test/pythonCommon/test_experiment_manager.py -v

# Run with verbose output
python -m pytest test/pythonCommon/ -v -s
```

---

## 🧰 Developer Notes

- `CommClient` is designed to be thread-safe and event-driven.
- `on_message_callback` generic function is provided in the ExperimentManager class but can be overridden for improved functionality if needed. (This goes for enter_state functions as well but be careful to test properly before deploying).
- Heartbeats are optional but recommended for monitoring.
- All message routing is done via function callbacks. Developers are encouraged to keep `CommClient` generic and place application logic in `ExperimentManager`.
- `RestClient` handles large data transfers that exceed MQTT message limits.
- Both `CommClient` and `RestClient` must be instantiated before creating an `ExperimentManager` instance.
- More notes on using these classes together will be present in the `node_scaffolding_python` folder.

---

## 📌 Dependencies

### Required External Libraries
```bash
# Install all required dependencies
pip install paho-mqtt requests pandas pytest pytest-mock
```

**External dependencies (not included in Python 3.7+):**
- `paho-mqtt` - MQTT client library for distributed communication
- `requests` - HTTP library for REST API interactions  
- `pandas` - Data manipulation and analysis library
- `pytest` - Testing framework (for development/testing)
- `pytest-mock` - Mock library for pytest (for development/testing)

**Built-in Python modules used:**
- Standard library: `json`, `logging`, `threading`, `time`, `os`, `pickle`, `traceback`, `io`, `re`
- Type system: `typing`, `abc`, `enum`, `collections`, `datetime`

### Python Version Requirements
- **Minimum:** Python 3.7+
- **Recommended:** Python 3.9+
---
