# network

Shared network infrastructure for the lab framework. Contains the MQTT broker configuration, the REST data server, and the operator dashboard.

## Contents

| File / Folder | Role |
|---|---|
| `mosquitto.conf` | Mosquitto MQTT broker configuration |
| `RestServer.py` | Flask REST server for experiment data upload and retrieval |
| `webapp/index.html` | Operator dashboard (browser UI) |
| `tempRestData/` | Runtime data directory — created automatically, not git-tracked |

---

## mosquitto.conf

Configures the Mosquitto broker on the master computer. Two listeners are active:

| Port | Protocol | Used by |
|---|---|---|
| `1883` | MQTT (TCP) | Python and MATLAB nodes |
| `9001` | MQTT over WebSocket | Browser dashboard (MQTT.js) |

Authentication is disabled (`allow_anonymous true`). This is appropriate for an isolated lab LAN and simplifies node setup. If the network is shared, enable password authentication via Mosquitto's `password_file` option.

To start the broker manually:

```bash
mosquitto -c network/mosquitto.conf
```

The `updater/pull_and_deploy.sh` script handles broker startup on the master computer automatically.

---

## RestServer.py

Flask server for large data transfers that would exceed MQTT payload limits. Peripheral nodes upload experiment data here after post-processing (typically at the end of the `POSTPROC` state), and the control node or dashboard retrieves it on demand.

Data is stored under `network/tempRestData/<clientID>/` as timestamped files. The directory persists across server restarts so data is not lost if the server crashes mid-session. Use `POST /data/clear` to wipe data between sessions.

### API endpoints

| Method | Route | Description |
|---|---|---|
| `POST` | `/data/<clientID>` | Upload experiment data from a node. Accepts `application/json` (JSONL) or `text/csv`. |
| `GET` | `/data/<clientID>` | Retrieve data for a node. Supports `experimentName`, `format`, and `latest` query params. |
| `GET` | `/data` | List all clients with stored data, grouped by `clientID`. |
| `GET` | `/health` | Returns server status, uptime, client count, and total file count. |
| `POST` | `/api/convert/mat` | Converts tabular JSON data to a binary `.mat` file (requires `scipy`). |
| `POST` | `/data/clear` | Deletes all stored data. Requires `{"confirm": "CLEAR_ALL_DATA"}` in the body. |

CORS is enabled on all routes so the browser dashboard can call the server directly.

### Running

```bash
python3 network/RestServer.py
```

The server binds to `0.0.0.0:5000` so it is reachable from any device on the LAN. Port 5000 must be open on the host firewall. The `updater/pull_and_deploy.sh` script starts this automatically on the master computer.

### Dependencies

```bash
pip install flask
pip install scipy  # optional — only required for the /api/convert/mat endpoint
```

### Data storage format

Uploaded files are saved as `<experimentName>_<YYYYMMDD>_<HHMMSS>.<ext>` under `tempRestData/<clientID>/`. The timestamp suffix prevents overwrites when the same experiment name is reused across sessions.

---

## webapp/index.html

Browser-based operator dashboard. Served by `control_node/main.py` on port 8080 (default). Connects directly to the MQTT broker over WebSocket (port 9001) for real-time updates and calls the REST server for data retrieval and template loading.

No build step is required — all dependencies (Alpine.js, Chart.js, MQTT.js) are loaded from CDN.

### Tabs

| Tab | Description |
|---|---|
| System | Live node grid showing online/offline status and current FSM state for all discovered nodes |
| Control | Per-node command buttons, live sensor data plot, calibration terminal, broadcast controls |
| Experiment | Structured experiment setup forms, template browser, run sequencing |
| Data | Fetch and plot stored experiment data from the REST server |
| Logs | Streaming log feed from all nodes via MQTT `/log` topics |

### What is generic

The System, Control, and Logs tabs are fully generic. They work with any node that follows the MQTT topic and FSM state conventions of this framework. The live plot in the Control tab renders whatever numeric channels a node publishes on its `/data` topic.

### What is tow-tank specific

The Experiment tab contains logic specific to the tow tank facility and is not portable as-is:

- The page title and header read "Tow Tank Control".
- The experiment form types `carriageNode`, `waveMakerProbeNode`, `fullRun`, and `multiFullRun` are hard-coded in the `EXP_FORMS` JavaScript object, as are their form fields.
- The `fullRun` and `multiFullRun` orchestration flows hard-code the node IDs `carriageNode` and `waveMakerProbeNode` and manage their FSM states in tandem.
- Hardware-specific controls are embedded directly: laser motion channels (heave, pitch, roll), wave probe index selectors (1-8), wave maker paddle mode, and force output column names (Fx, Fy, Fz, Mx, My, Mz).
- Wave signal type definitions (sinusoidal, pulse, Bretschneider) are hard-coded in the JavaScript.

### Generalizing the dashboard

The dashboard could be made generic with relatively little effort. The `EXP_FORMS` object and the multi-node orchestration logic are the only tow-tank-specific sections. Replacing `EXP_FORMS` with a configuration file (e.g., a `config/dashboard.json` that defines available experiment types, participating node IDs, and form fields) would decouple the dashboard from this facility entirely. The orchestration logic for multi-node runs would similarly move to a config-driven loop rather than hard-coded node name references.

---

## Known limitations

- `RestServer.py` uses Flask's built-in development server. It is adequate for single-operator lab use on an isolated LAN but is not hardened for concurrent access or public network exposure.
- Data stored in `tempRestData/` has no automatic expiry. Files accumulate across sessions and must be cleared manually via `POST /data/clear` or by restarting the server after deleting the directory.
- The MQTT broker has no authentication (`allow_anonymous true`). Any device on the same network can publish and subscribe to all topics.
