# Configuration

All runtime configuration for the framework lives here. No node reads values that are hardcoded in its source — everything from broker addresses to DAQ channel names to calibration wizard prompts comes from these files. This makes it straightforward to adapt the system to a different lab, a different machine layout, or different hardware without touching any node code.

---

## Files at a glance

| File | Tracked by git | Purpose |
|---|---|---|
| `node_role.txt` | No | Sets the machine profile (which config block to load) |
| `manifest.json` | Yes | Maps each profile to the nodes it should run |
| `<profile>.json` | No | Machine-local config: broker, hardware, MQTT topics |
| `calibration_profiles.json` | Yes | Calibration wizard structure per node |
| `actuator_profiles.json` | Yes | Actuator test form fields per node |
| `node_registry.json` | Yes | Reserved for future dynamic node discovery |
| `templates/` | Yes | Example experiment specs ready to send to the control node |

---

## `node_role.txt`

A single line of text identifying the profile of the current machine. The deploy script and node launchers read this at startup to determine which section of `manifest.json` and which `<profile>.json` to load.

```
master_computer
```

The value must match a top-level key in `manifest.json` exactly (case-sensitive). This file is not git-tracked — it must be created manually on each machine after cloning. One file, one machine, one profile.

---

## `manifest.json`

Defines what runs on each machine profile. The deploy script (`updater/pull_and_deploy.sh`) reads this to know which node launchers to start.

```json
{
  "master_computer": {
    "launchMosquitto": false,
    "nodes": [
      {
        "nodeId": "sensorActuatorNode",
        "path": "my_node/",
        "startup_script": "my_node.m",
        "hasSensor": true,
        "hasActuator": true
      },
      {
        "path": "control_node/",
        "startup_script": "main.py"
      }
    ]
  },
  "peripheral_computer": {
    "launchMosquitto": false,
    "nodes": [
      {
        "nodeId": "sensorNode",
        "path": "sensor_node/",
        "startup_script": "sensor_node.m",
        "hasSensor": true,
        "hasActuator": false
      }
    ]
  }
}
```

| Field | Type | Description |
|---|---|---|
| `launchMosquitto` | bool | If true, the deploy script starts the Mosquitto broker on this machine |
| `nodes[].nodeId` | string | Must match the top-level key for this node in `<profile>.json` |
| `nodes[].path` | string | Path to the node folder, relative to the repo root |
| `nodes[].startup_script` | string | The script the deploy tool launches (`.m` or `.py`) |
| `nodes[].hasSensor` | bool | Passed to the node at launch — tells the ExperimentManager to expect sensor data |
| `nodes[].hasActuator` | bool | Passed to the node at launch — tells the ExperimentManager to expect an actuator output |

The control node entry does not need `nodeId`, `hasSensor`, or `hasActuator` — it is a pure orchestrator.

---

## `<profile>.json` (machine-local, not git-tracked)

The most important file for adapting the framework to a new lab. One file per machine, named after its profile. Contains everything that varies between physical machines: broker address, DAQ device names, channel assignments, sample rates, and hardware limits.

These files are gitignored. Each machine creates its own copy when setting up. The file has two parts: top-level connection settings and one section per node running on that machine.

### Top-level fields

| Field | Type | Example | Description |
|---|---|---|---|
| `brokerAddress` | string | `"192.168.1.10"` | IP of the MQTT broker. Use `"localhost"` on the machine running the broker |
| `brokerPort` | int | `1883` | Standard MQTT TCP port |
| `restPort` | int | `5000` | Port the REST data server is listening on |
| `verbose` | bool | `true` | If true, nodes log all state transitions and MQTT traffic to console |

### Per-node section

Each node running on this machine gets a section keyed by its `nodeId` from `manifest.json`.

```json
{
  "brokerAddress": "192.168.1.10",
  "brokerPort": 1883,
  "restPort": 5000,
  "verbose": true,

  "sensorNode": {
    "clientID": "sensorNode",
    "subscriptions": [
      "sensorNode/cmd",
      "controlNode/cmd"
    ],
    "publications": [
      "sensorNode/status",
      "sensorNode/data",
      "sensorNode/log"
    ],
    "hardware": {
      "hasSensor": true,
      "hasActuator": false,
      "daqDevice": "Dev1",
      "inputChannels": ["ai0", "ai1", "ai2"],
      "sampleRate": 100
    }
  }
}
```

| Field | Type | Description |
|---|---|---|
| `clientID` | string | MQTT client identifier — must be unique across all nodes on the broker |
| `subscriptions` | string[] | Topics this node listens to. At minimum: `<nodeId>/cmd` and `controlNode/cmd` |
| `publications` | string[] | Topics this node publishes on. Typically: `<nodeId>/status`, `/data`, `/log` |
| `hardware.hasSensor` | bool | Enables the sensor FSM path (Calibrate, TestSensor, Run acquisition) |
| `hardware.hasActuator` | bool | Enables the actuator FSM path (TestActuator, signal output during Run) |
| `hardware.daqDevice` | string | NI-DAQ device ID as it appears in NI MAX (e.g. `"Dev1"`) |
| `hardware.sampleRate` | int | DAQ acquisition rate in Hz |

Additional hardware fields are node-specific. Common examples:

| Field | Used by | Description |
|---|---|---|
| `allProbeChannels` | wave probe node | Cell array of 8 analog input channel IDs |
| `paddleOutputChannel` | wave maker node | Analog output channel ID for the paddle drive signal |
| `maxAmplitude` | wave maker node | Maximum DAQ output voltage (V) — hard limit enforced at Configure |
| `maxFrequency` | wave maker node | Maximum signal frequency (Hz) — enforced for all signal types except Bretschneider |
| `probeGainsFile` | wave probe node | Path to the probe gains `.mat` file written after calibration |
| `forceChannels` | force sensor node | Channel IDs for the 6-axis load cell (one per axis) |
| `syncChannel` | force sensor node | Channel ID for the external sync pulse input |
| `runTimeMatrixFile` | force sensor node | Path to the calibration matrix `.mat` file |

---

## `calibration_profiles.json`

Describes the calibration wizard for each node. The control node reads this file to know what prompts to show the operator and what MQTT commands to send during a Calibrate session. Adding a new node with a calibration procedure means adding a section here — no changes to control node code.

Each node entry contains a `phases` array. Each phase drives one calibration flow:

```json
{
  "myNode": {
    "label": "My Node — Sensor Calibration",
    "phases": [
      {
        "id": "gain_cal",
        "label": "Sensor Gain Calibration",
        "intro": ["Place sensor at a known reference point.", "Enter at least 3 points then type 'done'."],
        "setupPrompts": [
          {
            "key": "selectedChannels",
            "type": "int_array",
            "min": 1,
            "max": 4,
            "prompt": "Channel indices to calibrate (e.g. 1,2,3):"
          }
        ],
        "pointPrompts": [
          {
            "key": "knownValue",
            "type": "number",
            "prompt": "Known reference value (units):",
            "unit": "mm"
          }
        ],
        "minPoints": 3,
        "hardMinPoints": 2,
        "pointCommandTemplate": { "cmd": "Calibrate", "params": {} },
        "finishCommand": { "cmd": "Calibrate", "params": { "finished": true } },
        "finishKeyword": "done"
      }
    ]
  }
}
```

| Field | Type | Description |
|---|---|---|
| `phases[].id` | string | Internal identifier for this calibration phase |
| `phases[].intro` | string[] | Lines printed to the operator at the start of this phase |
| `phases[].setupPrompts` | object[] | One-time prompts collected before point collection begins (e.g. which channels to calibrate) |
| `phases[].pointPrompts` | object[] | Prompts collected at each calibration point |
| `phases[].minPoints` | int | Recommended minimum number of calibration points |
| `phases[].hardMinPoints` | int | Absolute minimum — fewer points causes the calibration to abort |
| `phases[].pointCommandTemplate` | object | MQTT command skeleton sent for each collected point |
| `phases[].finishCommand` | object | MQTT command sent when the operator types `finishKeyword` |

---

## `actuator_profiles.json`

Describes the actuator test signal types available for each node. The dashboard reads this file to build the actuator test form dynamically — adding a new signal type or a new actuator node means editing this file only.

```json
{
  "myActuatorNode": {
    "label": "My Node — Actuator Test",
    "signalTypes": [
      {
        "id": "sinusoidal",
        "label": "Sinusoidal",
        "fields": [
          { "key": "duration",   "type": "number", "label": "Duration",   "unit": "s", "default": 30,   "min": 1, "required": true },
          { "key": "amplitude",  "type": "number", "label": "Amplitude",  "unit": "m", "default": 0.02, "min": 0, "required": true },
          { "key": "frequency",  "type": "number", "label": "Frequency",  "unit": "Hz","default": 0.5,  "min": 0, "required": true }
        ]
      }
    ]
  }
}
```

| Field | Type | Description |
|---|---|---|
| `signalTypes[].id` | string | Identifier sent in the Configure command as `signalType` |
| `signalTypes[].label` | string | Display name shown in the dashboard form |
| `signalTypes[].fields[].key` | string | Parameter name sent in the Configure command params |
| `signalTypes[].fields[].type` | string | Input type: `number`, `int`, `int_array` |
| `signalTypes[].fields[].default` | number | Pre-filled value in the dashboard form |
| `signalTypes[].fields[].min` | number | Minimum accepted value (client-side validation) |
| `signalTypes[].fields[].required` | bool | Whether the field must be non-empty before submitting |

---

## `node_registry.json`

Reserved for future dynamic node discovery. Currently empty (`{}`). Do not remove the file.

---

## `templates/`

Ready-to-use experiment spec JSON files. The operator pastes one of these into the dashboard's experiment form (or the control node CLI) to define what a run or multi-run sequence should do. The `_description` and `_nodeType` fields are for human reference only — they are not parsed by any node.

| File | Target node | What it does |
|---|---|---|
| `single_run_example.json` | carriageNode | Acquires all force, sync, and motion channels for `duration` seconds |
| `single_run_force_only.json` | carriageNode | Same acquisition but strips motion channels from output via `outputChannels` |
| `single_run_force_sensor.json` | carriageNode | Identical to `single_run_example.json` — kept as a named alias |
| `wave_maker_and_probes.json` | waveMakerProbeNode | Drives the wave paddle and records probe heights simultaneously |
| `wave_probes_collect.json` | waveMakerProbeNode | Records probe heights only — paddle outputs 0 V throughout |
| `single_run_experiment_full.json` | both nodes | Coordinates simultaneous carriage and wave maker acquisition |
| `multi_run_example.json` | carriageNode | Three-speed sweep — each run at a different carriage speed |

### Common fields across templates

| Field | Type | Description |
|---|---|---|
| `name` | string | Run label used in file names and REST data keys |
| `duration` | number | Acquisition duration in seconds |
| `sampleRate` | int | Requested sample rate in Hz (must match or be below `hardware.sampleRate`) |
| `outputChannels` | string[] | If present, only these columns are saved and uploaded. Omit to keep all channels |
| `signalType` | string | Wave signal type: `sinusoidal`, `bretschneider`, `pulse_sinusoidal`, `dual_pulse` |
| `amplitude` | number | Wave height in metres (0 for probe-only runs) |
| `frequency` | number | Signal frequency in Hz (0 for probe-only runs) |
| `activeProbes` | int[] | 1-based probe indices to record (e.g. `[1, 2, 3]`) |

For multi-run specs, the top-level object wraps an array of per-run param objects. Each entry follows the same field conventions as a single-run spec.

---

## Adding a new node or machine

1. Create the node folder and implement the `ExperimentManager` subclass.
2. Add an entry to `manifest.json` under the relevant profile (or create a new profile).
3. Add a section to the machine-local `<profile>.json` with the node's `clientID`, MQTT topics, and `hardware` block.
4. If the node has a sensor calibration procedure, add a phase entry to `calibration_profiles.json`.
5. If the node has an actuator, add its signal types to `actuator_profiles.json`.
6. Add one or more experiment spec templates to `templates/` so operators have a starting point.

No changes to any existing node code are required.
