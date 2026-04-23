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

# Add repo root to path so pythonCommon is importable
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

from pythonCommon.CommClient import CommClient
from pythonCommon.RestClient import RestClient


def setup_logging(log_dir: str) -> logging.Logger:
    os.makedirs(log_dir, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    log_file = os.path.join(log_dir, f"control_node_{ts}.log")

    logger = logging.getLogger("control_node")
    logger.setLevel(logging.DEBUG)

    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")

    fh = logging.FileHandler(log_file)
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    sh = logging.StreamHandler(sys.stdout)
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

        # Initialise CommClient and RestClient
        self.comm = CommClient(cfg)
        self.rest = RestClient(cfg)

        # Wire incoming message callback
        self.cfg['onMessageCallback'] = self._on_message

    def connect(self):
        """Connect to the MQTT broker."""
        self.comm.connect()
        self.logger.info("ControlNode connected to broker at %s:%d",
                         self.cfg.get('brokerAddress', 'localhost'),
                         self.cfg.get('brokerPort', 1883))

    def send_command(self, node_id: str, cmd: dict):
        """
        Publish a structured command to a peripheral node's /cmd topic.

        Args:
            node_id: The clientID of the target node (e.g. 'waveMakerProbeNode').
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
        entry["node_id"]           = node_id
        entry["last_seen"]         = now
        entry["last_seen_readable"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
        entry["status"]            = "online"

        if isinstance(payload, dict):
            if "state" in payload:
                entry["state"] = payload["state"]
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

    logger = setup_logging(os.path.join(REPO_ROOT, "logs"))
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
