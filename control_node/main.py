"""
control_node/main.py
--------------------
Python command dispatcher for the lab framework master computer.

Connects to the MQTT broker and subscribes to all peripheral node topics
(status, data, log). Maintains a live node registry so the operator (or
future UI) can see which nodes are online and what their capabilities are.

Exposes send_command(node_id, cmd_dict) for issuing structured commands to
any node. This is the programmatic entry point for experiment orchestration.

Usage (called by updater/pull_and_deploy.sh):
    python3 control_node/main.py config/master_computer.json master_computer

See config/master_computer.json.example for the required config structure.
"""

import sys
import os
import json
import time
import signal
import logging
import threading

# Add repo root to path so pythonCommon is importable
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

from flask import Flask, request, jsonify, send_from_directory
from pythonCommon.CommClient import CommClient
from pythonCommon.RestClient import RestClient

WEBAPP_DIR    = os.path.join(REPO_ROOT, "network", "webapp")
TEMPLATES_DIR = os.path.join(REPO_ROOT, "config", "templates")

# Valid FSM state names. Status messages carrying any other state string are
# rejected. Update this set whenever a new state is added to State.m / State enum.
_VALID_STATES = frozenset({
    'BOOT', 'IDLE', 'CALIBRATING', 'TESTINGSENSOR',
    'CONFIGUREVALIDATE', 'CONFIGUREPENDING', 'TESTINGACTUATOR',
    'RUNNING', 'POSTPROC', 'DONE', 'ERROR', 'UPDATING'
})


def setup_logging(log_dir: str) -> logging.Logger:
    os.makedirs(log_dir, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    log_file = os.path.join(log_dir, f"control_node_{ts}.log")

    logger = logging.getLogger("control_node")
    logger.setLevel(logging.DEBUG)
    logger.propagate = False  # prevent duplicate lines via root logger

    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")

    fh = logging.FileHandler(log_file, encoding='utf-8')
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    sh = logging.StreamHandler(open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1, closefd=False))
    sh.setFormatter(fmt)
    logger.addHandler(sh)

    return logger


class ControlNode:
    """
    Lightweight orchestrator for the lab experiment framework.

    Subscribes to all peripheral node topics and maintains a registry of
    online nodes. Provides send_command() for experiment orchestration.
    No FSM — the control node drives the experiment directly by publishing
    structured command dicts to peripheral node /cmd topics.
    """

    def __init__(self, cfg: dict, logger: logging.Logger):
        self.cfg = cfg
        self.logger = logger
        self.node_registry: dict = {}   # node_id -> {status, capabilities, last_seen}
        self._running = True

        # Load existing registry if present
        registry_path = os.path.join(REPO_ROOT, "config", "node_registry.json")
        if os.path.isfile(registry_path):
            with open(registry_path) as f:
                self.node_registry = json.load(f)
            self.logger.info("Loaded existing node registry (%d nodes)", len(self.node_registry))

        # Seed node capabilities from manifest (source of truth)
        manifest_path = os.path.join(REPO_ROOT, "config", "manifest.json")
        if os.path.isfile(manifest_path):
            with open(manifest_path) as f:
                manifest = json.load(f)
            for profile_data in manifest.values():
                for node_def in profile_data.get("nodes", []):
                    nid = node_def.get("nodeId")
                    if not nid:
                        continue
                    if nid not in self.node_registry:
                        self.node_registry[nid] = {"status": "offline"}
                    entry = self.node_registry[nid]
                    # Always refresh from manifest — it is the canonical source
                    if "hasSensor" in node_def:
                        entry["hasSensor"] = node_def["hasSensor"]
                    if "hasActuator" in node_def:
                        entry["hasActuator"] = node_def["hasActuator"]

        # Initialise CommClient and RestClient — callback must be set BEFORE construction
        # so CommClient reads it at init time when it stores config['onMessageCallback']
        self.cfg['onMessageCallback'] = self._on_message
        self.comm = CommClient(cfg)
        self.rest = RestClient(cfg)

    def connect(self):
        """Connect to the MQTT broker and start the web UI server."""
        self.comm.connect()
        self.logger.info("ControlNode connected to broker at %s:%d",
                         self.cfg.get('brokerAddress', 'localhost'),
                         self.cfg.get('brokerPort', 1883))
        self._start_offline_monitor()
        self._start_web_server()

    NODE_TIMEOUT_SECS  = 60    # mark offline after 1 min of silence
    MONITOR_PERIOD_SECS = 30   # how often the monitor thread wakes

    def _start_offline_monitor(self):
        """Background thread that marks nodes offline after NODE_TIMEOUT_SECS of silence."""
        def monitor():
            while self._running:
                time.sleep(self.MONITOR_PERIOD_SECS)
                now = time.time()
                changed = False
                for node_id, entry in list(self.node_registry.items()):
                    last = entry.get("last_seen")
                    if last and (now - last) > self.NODE_TIMEOUT_SECS:
                        if entry.get("status") != "offline":
                            entry["status"] = "offline"
                            self.logger.info(
                                "Node timed out (no heartbeat for %.0f min): %s",
                                self.NODE_TIMEOUT_SECS / 60, node_id)
                            changed = True
                if changed:
                    self._save_registry()

        t = threading.Thread(target=monitor, name="offline-monitor", daemon=True)
        t.start()

    def _start_web_server(self):
        """
        Starts the lab experiment web UI on port 8080 in a background daemon thread.

        Routes:
          GET  /                        — serves network/webapp/index.html
          GET  /api/nodes               — live node registry (in-memory)
          GET  /api/templates           — list available experiment templates
          GET  /api/templates/<name>    — return a specific template's JSON
          POST /api/command/<node_id>   — send a command to a node via MQTT

        The thread is a daemon so it is automatically killed when the main
        process exits. use_reloader=False prevents Werkzeug from forking a
        child process (which would conflict with the MQTT loop).
        """
        web = Flask(__name__, static_folder=WEBAPP_DIR)

        # Suppress Werkzeug request logs to keep ControlNode logs readable
        logging.getLogger("werkzeug").setLevel(logging.ERROR)

        @web.route("/")
        def index():
            return send_from_directory(WEBAPP_DIR, "index.html")

        @web.route("/api/nodes")
        def api_nodes():
            # Annotate each entry with a live `online` flag before serving
            now = time.time()
            result = {}
            for node_id, entry in self.node_registry.items():
                e = dict(entry)
                last = e.get("last_seen")
                e["online"] = bool(last and (now - last) < self.NODE_TIMEOUT_SECS)
                result[node_id] = e
            return jsonify(result)

        @web.route("/api/templates")
        def api_templates():
            if not os.path.isdir(TEMPLATES_DIR):
                return jsonify([])
            names = [
                f for f in os.listdir(TEMPLATES_DIR)
                if f.endswith(".json")
            ]
            return jsonify(sorted(names))

        @web.route("/api/templates/<name>")
        def api_template(name):
            # Basename-only to prevent path traversal
            safe = os.path.basename(name)
            path = os.path.join(TEMPLATES_DIR, safe)
            if not os.path.isfile(path):
                return jsonify({"error": f"Template '{safe}' not found"}), 404
            with open(path) as f:
                return jsonify(json.load(f))

        @web.route("/api/calibration-profiles")
        def api_calibration_profiles():
            profiles_path = os.path.join(REPO_ROOT, "config", "calibration_profiles.json")
            if not os.path.isfile(profiles_path):
                return jsonify({}), 404
            with open(profiles_path) as f:
                return jsonify(json.load(f))

        @web.route("/api/actuator-profiles")
        def api_actuator_profiles():
            profiles_path = os.path.join(REPO_ROOT, "config", "actuator_profiles.json")
            if not os.path.isfile(profiles_path):
                return jsonify({}), 404
            with open(profiles_path) as f:
                return jsonify(json.load(f))

        @web.route("/api/command/<node_id>", methods=["POST"])
        def api_command(node_id):
            body = request.get_json(silent=True)
            if not body or "cmd" not in body:
                return jsonify({"error": "Request body must be JSON with a 'cmd' field"}), 400
            self.send_command(node_id, body)
            return jsonify({"status": "sent", "node": node_id, "cmd": body["cmd"]})

        @web.route("/api/broadcast", methods=["POST"])
        def api_broadcast():
            body = request.get_json(silent=True)
            if not body or "cmd" not in body:
                return jsonify({"error": "Request body must be JSON with a 'cmd' field"}), 400
            self.comm.comm_publish("controlNode/cmd", json.dumps(body))
            self.logger.info("Broadcast via controlNode/cmd: %s", body.get("cmd"))
            return jsonify({"status": "broadcast", "cmd": body["cmd"]})

        port = self.cfg.get("webPort", 8080)
        t = threading.Thread(
            target=lambda: web.run(host="0.0.0.0", port=port,
                                   use_reloader=False, threaded=True),
            name="web-server",
            daemon=True
        )
        t.start()
        self.logger.info("Web UI available at http://0.0.0.0:%d", port)

    def send_command(self, node_id: str, cmd: dict):
        """
        Publish a structured command to a peripheral node's /cmd topic.

        Args:
            node_id: The clientID of the target node (e.g. 'sensorNode1').
            cmd:     Command dict, e.g. {"cmd": "Run", "params": {...}}.
        """
        topic = f"{node_id}/cmd"
        payload = json.dumps(cmd)
        self.comm.comm_publish(topic, payload)
        self.logger.info("Sent command to %s: %s", topic, cmd.get('cmd', '?'))

    def _on_message(self, topic: str, msg: str):
        """
        Handles all incoming MQTT messages from peripheral nodes.

        Routes messages by topic suffix:
          /status  — updates node registry
          /data    — logs receipt (data is stored server-side via REST)
          /log     — forwards to local logger
        """
        try:
            parts = topic.split("/")
            if len(parts) < 2:
                return

            node_id = parts[0]
            suffix = parts[1]

            # Decode payload
            try:
                payload = json.loads(msg) if isinstance(msg, str) else msg
            except json.JSONDecodeError:
                payload = {"raw": msg}

            if suffix == "status":
                self._handle_status(node_id, payload)
            elif suffix == "data":
                self.logger.debug("[%s/data] received %d-char payload", node_id, len(str(msg)))
            elif suffix == "log":
                level = payload.get("level", "INFO") if isinstance(payload, dict) else "INFO"
                text  = payload.get("msg", str(payload)) if isinstance(payload, dict) else str(payload)
                self.logger.info("[%s/log] [%s] %s", node_id, level, text)

        except Exception as e:
            self.logger.warning("_on_message error on topic %s: %s", topic, e)

    def _handle_status(self, node_id: str, payload: dict):
        """Updates the node registry when a status message arrives."""
        now = time.time()

        if node_id not in self.node_registry:
            self.node_registry[node_id] = {}
            self.logger.info("New node online: %s", node_id)

        entry = self.node_registry[node_id]
        entry["node_id"]            = node_id
        entry["last_seen"]          = now
        entry["last_seen_readable"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
        entry["status"]             = "online"

        if isinstance(payload, dict):
            if "state" in payload:
                state = payload["state"]
                if state in _VALID_STATES:
                    entry["state"] = state
                else:
                    self.logger.warning("[%s] ignoring invalid state '%s' — not in FSM", node_id, state)
            if "ip" in payload:
                entry["ip"] = payload["ip"]
            if "capabilities" in payload:
                entry["capabilities"] = payload["capabilities"]

        self._save_registry()
        self.logger.info("[%s] status: %s", node_id, entry.get("state", "unknown"))

    def _save_registry(self):
        """Persists the node registry to config/node_registry.json."""
        registry_path = os.path.join(REPO_ROOT, "config", "node_registry.json")
        try:
            with open(registry_path, "w") as f:
                json.dump(self.node_registry, f, indent=4)
        except IOError as e:
            self.logger.warning("Failed to save node registry: %s", e)

    def run(self):
        """Main blocking loop. Handles graceful shutdown on SIGINT/SIGTERM."""
        signal.signal(signal.SIGINT,  self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

        self.logger.info("ControlNode running. Press Ctrl-C to stop.")
        while self._running and self.comm.connected:
            time.sleep(0.1)
        self.logger.info("ControlNode shutting down.")

    def shutdown(self):
        """Disconnect from broker and persist registry."""
        self._running = False
        self._save_registry()
        try:
            self.comm.disconnect()
        except Exception as e:
            self.logger.warning("Disconnect error: %s", e)
        self.logger.info("ControlNode disconnected.")

    def _handle_signal(self, signum, frame):
        self.logger.info("Received signal %d — initiating shutdown.", signum)
        self._running = False


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 control_node/main.py <config_file> <profile>")
        sys.exit(1)

    cfg_file = sys.argv[1]
    profile  = sys.argv[2]

    logger = setup_logging(os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    logger.info("ControlNode starting (profile: %s)", profile)

    # Load machine config and extract controlNode section
    with open(cfg_file) as f:
        machine_cfg = json.load(f)

    if "controlNode" not in machine_cfg:
        logger.error("Config file is missing 'controlNode' section.")
        sys.exit(1)

    cfg = machine_cfg["controlNode"]
    # Merge top-level broker settings
    cfg.setdefault("brokerAddress", machine_cfg.get("brokerAddress", "localhost"))
    cfg.setdefault("brokerPort",    machine_cfg.get("brokerPort", 1883))
    cfg.setdefault("restPort",      machine_cfg.get("restPort", 5000))
    cfg.setdefault("verbose",       machine_cfg.get("verbose", False))

    node = ControlNode(cfg, logger)
    try:
        node.connect()
        node.run()
    finally:
        node.shutdown()


if __name__ == "__main__":
    main()
