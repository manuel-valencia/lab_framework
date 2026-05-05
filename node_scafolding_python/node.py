"""
node.py

Top-level headless launcher for a Python node.
Copy this file into your node folder and rename it to match your node.

USAGE (called by updater/pull_and_deploy.sh):
    python3 node.py config/<profile>.json <profile>

The config file is the machine-level JSON for the computer this node runs on.
The profile key selects the node-specific section from that file.

All shared Python framework code lives in pythonCommon/.
"""

import sys
import os
import json
import time
import signal

# Add repo root to path so pythonCommon is importable
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

from pythonCommon.CommClient import CommClient
from pythonCommon.RestClient import RestClient
from MyNodeManager import MyNodeManager


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 node.py <config_file> <profile>")
        sys.exit(1)

    cfg_file = sys.argv[1]
    profile  = sys.argv[2]

    # ── 1. Load configuration ─────────────────────────────────────────────────
    # Replace 'myNode' with the key name for this node's section in the
    # machine config JSON (e.g. 'carriageNode', 'waveMakerProbeNode').
    NODE_SECTION = "myNode"

    with open(cfg_file) as f:
        machine_cfg = json.load(f)

    print(f"[INFO] Loaded machine config from {cfg_file} (profile: {profile})")

    if NODE_SECTION not in machine_cfg:
        print(f"[ERROR] Config file is missing '{NODE_SECTION}' section.")
        sys.exit(1)

    # Merge top-level broker settings with node-specific settings
    cfg = machine_cfg[NODE_SECTION]
    cfg.setdefault("brokerAddress", machine_cfg.get("brokerAddress", "localhost"))
    cfg.setdefault("brokerPort",    machine_cfg.get("brokerPort", 1883))
    cfg.setdefault("restPort",      machine_cfg.get("restPort", 5000))
    cfg.setdefault("verbose",       machine_cfg.get("verbose", False))

    # ── 2. Validate required fields ───────────────────────────────────────────
    for field in ("clientID", "brokerAddress", "hardware"):
        if field not in cfg:
            print(f"[ERROR] Missing required config field: {field}")
            sys.exit(1)

    # Uncomment and adapt depending on whether this node has a sensor,
    # an actuator, or both:
    #
    # if not cfg["hardware"].get("hasSensor"):
    #     print("[ERROR] myNode requires hardware.hasSensor = true.")
    #     sys.exit(1)
    # if not cfg["hardware"].get("hasActuator"):
    #     print("[ERROR] myNode requires hardware.hasActuator = true.")
    #     sys.exit(1)

    # ── 3. Initialise communication and FSM manager ───────────────────────────
    comm = CommClient(cfg)
    rest = RestClient(cfg)
    mgr  = MyNodeManager(cfg, comm, rest)

    # ── 4. Wire MQTT message callback ─────────────────────────────────────────
    comm.on_message_callback = mgr.on_message_callback

    # ── 5. Graceful shutdown on SIGINT / SIGTERM ──────────────────────────────
    def shutdown_handler(signum, frame):
        print(f"\n[INFO] Signal {signum} received — shutting down.")
        try:
            mgr.shutdown()
        except Exception as e:
            print(f"[WARN] Manager shutdown error: {e}")
        try:
            comm.disconnect()
        except Exception as e:
            print(f"[WARN] Comm disconnect error: {e}")
        sys.exit(0)

    signal.signal(signal.SIGINT,  shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    # ── 6. Main event loop — blocks here; all work is done in MQTT callbacks ──
    print("[INFO] Node online. Waiting for commands...")
    while comm.connected:
        time.sleep(0.1)
    print("[INFO] Node: broker connection lost. Shutting down.")
    shutdown_handler(0, None)


if __name__ == "__main__":
    main()
