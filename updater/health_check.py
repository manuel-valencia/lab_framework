"""
health_check.py
---------------
Basic pre-launch sanity checks run by pull_and_deploy.sh before starting nodes.
Exits with code 0 on success, non-zero on failure (triggers rollback in deploy script).

Add more checks here as the codebase grows.
"""

import sys
import os
import json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def check(condition, message):
    if not condition:
        print(f"[HEALTH FAIL] {message}")
        sys.exit(1)
    print(f"[HEALTH OK]   {message}")


# --- 1. Python imports ---
try:
    import paho.mqtt.client
    check(True, "paho-mqtt importable")
except ImportError:
    check(False, "paho-mqtt not installed — run: pip install paho-mqtt")

try:
    import requests
    check(True, "requests importable")
except ImportError:
    check(False, "requests not installed — run: pip install requests")

# --- 2. Required files exist ---
check(os.path.isfile(os.path.join(ROOT, "config", "manifest.json")), "config/manifest.json exists")
check(os.path.isfile(os.path.join(ROOT, "config", "node_role.txt")), "config/node_role.txt exists")

# --- 3. manifest.json is valid JSON ---
try:
    with open(os.path.join(ROOT, "config", "manifest.json")) as f:
        manifest = json.load(f)
    check(True, "config/manifest.json is valid JSON")
except json.JSONDecodeError as e:
    check(False, f"config/manifest.json is malformed: {e}")

# --- 4. node_role.txt references a known profile ---
with open(os.path.join(ROOT, "config", "node_role.txt")) as f:
    profile = f.read().strip()
check(profile in manifest, f"Profile '{profile}' exists in manifest.json")

# --- 5. Machine config file exists ---
config_file = os.path.join(ROOT, "config", f"{profile}.json")
check(os.path.isfile(config_file), f"config/{profile}.json exists")

# --- 6. Machine config is valid JSON ---
try:
    with open(config_file) as f:
        machine_cfg = json.load(f)
    check(True, f"config/{profile}.json is valid JSON")
except json.JSONDecodeError as e:
    check(False, f"config/{profile}.json is malformed: {e}")

print("[HEALTH] All checks passed.")
