"""
test_master_node/experiment_runner.py

Master node script to automate experiment execution:
- Discovers nodes and maintains live registry
- Executes multi-step experiment command sequences
- Waits for node responses between steps
- Logs progress and updates registry
"""

import time
import threading
import json
from datetime import datetime
import os

# Import all constants from config (clean and efficient for constants-only module)
try:
    from common.config import *
    from common.mqtt_manager import MQTTManager
    from common.node_registry import NodeRegistry
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import *
    from common.mqtt_manager import MQTTManager
    from common.node_registry import NodeRegistry

# =============================================================================
# Setup
# =============================================================================

# Ensure log directory exists
os.makedirs("logs", exist_ok=True)
LOG_FILE_PATH = "logs/experiment_runner.log"

# Initialize registry and MQTT manager
registry = NodeRegistry()
mq = MQTTManager("master_node", broker=MQTT_BROKER_IP)

# Response tracking for synchronous wait
pending_responses = {}

# =============================================================================
# Logging Utility
# =============================================================================

def log_event(event):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"[{timestamp}] {event}"
    print(entry)
    with open(LOG_FILE_PATH, "a") as log_file:
        log_file.write(entry + "\n")

# =============================================================================
# MQTT Handlers
# =============================================================================

def handle_discovery_response(client, userdata, message):
    payload = message.payload.decode()
    try:
        node_info = json.loads(payload)
        node_id = node_info.get("node_id")

        node = registry.get_node(node_id)
        was_offline = node and node.status == "offline"

        registry.add_or_update_node(
            node_id=node_id,
            ip_address=node_info.get("ip_address"),
            role=node_info.get("role"),
            capabilities=node_info.get("capabilities")
        )

        if was_offline:
            log_event(f"Node {node_id} recovered and marked ONLINE.")

    except Exception as e:
        log_event(f"Error processing discovery response: {e}")

def handle_command_response(client, userdata, message):
    payload = message.payload.decode()
    reception_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    try:
        response = json.loads(payload)
        node_id = response.get(FIELD_NODE_ID)
        status = response.get(FIELD_STATUS)
        command = response.get(FIELD_COMMAND)
        details = response.get(FIELD_DETAILS)
        response_time = response.get(FIELD_RESPONSE_TIME_MS, "N/A")

        log_event(f"Response from {node_id} | Command: {command} | Status: {status} | Details: {details} | Response Time: {response_time} ms")

        node = registry.get_node(node_id)
        if node:
            node.status = "calibrated" if (command == COMMAND_CALIBRATE and status == STATUS_SUCCESS) else node.status
            node.history.append({
                "timestamp": reception_time,
                "command": command,
                "status": status,
                "details": details,
                "response_time_ms": response_time
            })
            registry.save_registry()

        # Mark response as received
        if node_id in pending_responses:
            pending_responses[node_id] = True

    except Exception as e:
        log_event(f"Error processing command response: {e}")

# =============================================================================
# Experiment Runner
# =============================================================================

def send_command(target_node_id, command_type, params=None):
    if params is None:
        params = {}

    command_message = {
        FIELD_COMMAND: command_type,
        FIELD_PARAMS: params,
        FIELD_NODE_ID: target_node_id,
        FIELD_SESSION_ID: DEFAULT_SESSION_ID,
        FIELD_TIMESTAMP: time.time()
    }

    topic = f"{COMMAND_TOPIC}/{target_node_id}"
    mq.publish(topic, json.dumps(command_message))
    log_event(f"Sent command to {target_node_id}: {command_message}")

def wait_for_response(node_id, timeout=10):
    pending_responses[node_id] = False
    start_time = time.time()
    while time.time() - start_time < timeout:
        if pending_responses[node_id]:
            return True
        time.sleep(0.1)
    log_event(f"Timeout waiting for response from {node_id}")
    return False

def run_experiment():
    log_event("=== Starting experiment sequence ===")

    target_node = "test_node"  # For now, target our test node

    # Step 1: Calibrate
    send_command(target_node, COMMAND_CALIBRATE, {"calibration_type": "full"})
    if not wait_for_response(target_node):
        return log_event("Experiment aborted: calibration failed or timed out.")

    # Step 2: Validate (future expansion)
    send_command(target_node, COMMAND_VALIDATE, {})
    if not wait_for_response(target_node):
        return log_event("Experiment aborted: validation failed or timed out.")

    # Step 3: Force test run
    send_command(target_node, "run_force_test", {
        "sampling_rate": 1000,
        "duration_seconds": 30,
        "bias_offset": True
    })
    if not wait_for_response(target_node):
        return log_event("Experiment aborted: force test failed or timed out.")

    # Step 4: Wave test run
    send_command(target_node, "run_wave_test", {
        "wave_type": "sinusoidal",
        "frequency_hz": 0.5,
        "amplitude_cm": 5,
        "duration_seconds": 30
    })
    if not wait_for_response(target_node):
        return log_event("Experiment aborted: wave test failed or timed out.")

    log_event("=== Experiment sequence complete ===")

# =============================================================================
# Node Monitoring
# =============================================================================

def start_offline_monitor():
    def monitor():
        while True:
            registry.check_for_offline_nodes(timeout_seconds=NODE_TIMEOUT_SECONDS)
            time.sleep(1)

    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    log_event(f"Offline monitor started (timeout = {NODE_TIMEOUT_SECONDS}s)")

# =============================================================================
# Main Execution
# =============================================================================

if __name__ == "__main__":
    mq.connect()
    mq.subscribe(DISCOVERY_RESPONSE_TOPIC, handle_discovery_response)
    mq.subscribe(RESPONSE_TOPIC, handle_command_response)

    start_offline_monitor()

    mq.publish(DISCOVERY_REQUEST_TOPIC, "Who is online?")
    log_event("Waiting for node responses and monitoring activity...")

    try:
        time.sleep(5)  # Allow discovery

        run_experiment()

        while True:
            time.sleep(1)

    except KeyboardInterrupt:
        log_event("Shutdown signal received. Disconnecting...")
        mq.disconnect()
