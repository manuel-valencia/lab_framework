"""
test_master_node/test_command_w_discovery.py

Master node logic for:
- Dynamic node discovery and registry maintenance
- Monitoring node status (online/offline)
- Sending structured commands to nodes
- Receiving responses from nodes and logging status

Usage:
- Ensure MQTT broker is running on the master node.
- Run this script after starting test nodes.
- Master node will discover nodes and send test commands.
- Responses from nodes are received and logged.

"""

import time
import threading
import json
import os
from datetime import datetime

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

# Make sure logs folder/file exists
os.makedirs("logs", exist_ok=True)
LOG_FILE_PATH = "logs/command_responses.log"

# Initialize registry and MQTT manager
registry = NodeRegistry()
mq = MQTTManager("master_node", broker=MQTT_BROKER_IP)

# =============================================================================
# Discovery Response Handler
# =============================================================================

def handle_discovery_response(client, userdata, message):
    """
    Process discovery responses from nodes and update registry.
    """
    payload = message.payload.decode()
    #print(f"[master_node] Discovery response received: {payload}")

    try:
        node_info = json.loads(payload)
        node_id = node_info.get("node_id")

        # Determine if node was previously offline
        node = registry.get_node(node_id)
        was_offline = node and node.status == "offline"

        # Update registry
        registry.add_or_update_node(
            node_id=node_info.get("node_id"),
            ip_address=node_info.get("ip_address"),
            role=node_info.get("role"),
            capabilities=node_info.get("capabilities")
        )

        # # Print only if node was recovered (came back online)
        # if was_offline:
        #     print(f"[master_node] Node {node_id} recovered and marked ONLINE.")

    except Exception as e:
        print(f"[master_node] Error processing discovery response: {e}")

# =============================================================================
# Node Response Handler
# =============================================================================

def handle_command_response(client, userdata, message):
    """
    Process responses from nodes after executing commands.
    Logs response and updates registry status.
    """
    payload = message.payload.decode()

    # Add timestamp at reception
    reception_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print(f"[master_node] Command response received at {reception_time}: {payload}")

    try:
        response = json.loads(payload)
        node_id = response.get(FIELD_NODE_ID)
        status = response.get(FIELD_STATUS)
        command = response.get(FIELD_COMMAND)
        details = response.get(FIELD_DETAILS)
        response_time = response.get(FIELD_RESPONSE_TIME_MS, "N/A")

        # Log the response
        print(f"[master_node] Node: {node_id} | Command: {command} | Status: {status} | Details: {details} | Response Time: {response_time} ms")
        # Append to global log file
        with open(LOG_FILE_PATH, "a") as log_file:
            log_entry = {
                "reception_time": reception_time,
                "response": response
            }
            log_file.write(json.dumps(log_entry) + "\n")

        # Update node status in the registry if applicable and node history
        node = registry.get_node(node_id)
        if node:
            # Append to node history
            node.history.append({
                "timestamp": reception_time,
                "command": command,
                "status": status,
                "details": details,
                "response_time_ms": response_time
            })

            if command == COMMAND_CALIBRATE and status == STATUS_SUCCESS:
                node.status = "calibrated"
                print(f"[master_node] Registry updated: Node {node_id} marked as CALIBRATED.")
                registry.save_registry()  # Save updated registry
            elif status == STATUS_ERROR:
                node.status = "error"
                print(f"[master_node] Registry updated: Node {node_id} marked as ERROR.")
                registry.save_registry()
        else:
            print(f"[master_node] Warning: Node {node_id} not found in registry during response handling.")

    except Exception as e:
        print(f"[master_node] Error processing command response: {e}")


# =============================================================================
# Command Sender
# =============================================================================

def send_command(target_node_id, command_type, params=None, session_id=DEFAULT_SESSION_ID):
    """
    Sends a structured command to a specific node.

    Args:
        target_node_id (str): Node identifier to send the command to.
        command_type (str): Command type (e.g., 'calibrate', 'validate').
        params (dict, optional): Command-specific parameters.
        session_id (str, optional): Session identifier.
    """
    if params is None:
        params = {}

    command_message = {
        FIELD_COMMAND: command_type,
        FIELD_PARAMS: params,
        FIELD_NODE_ID: target_node_id,
        FIELD_SESSION_ID: session_id,
        FIELD_TIMESTAMP: time.time()
    }

    topic = f"{COMMAND_TOPIC}/{target_node_id}"
    mq.publish(topic, json.dumps(command_message))
    print(f"[master_node] Sent command to {target_node_id} on topic {topic}: {command_message}")

# =============================================================================
# Offline Node Monitor
# =============================================================================

def start_offline_monitor():
    """
    Checks for offline nodes at regular intervals.
    """
    def monitor():
        while True:
            registry.check_for_offline_nodes(timeout_seconds=NODE_TIMEOUT_SECONDS)
            time.sleep(1)

    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    print(f"[master_node] Offline monitor started (timeout = {NODE_TIMEOUT_SECONDS}s)")

# =============================================================================
# Main Execution
# =============================================================================

if __name__ == "__main__":
    # Connect to MQTT and subscribe to discovery responses
    mq.connect()
    mq.subscribe(DISCOVERY_RESPONSE_TOPIC, handle_discovery_response)
    mq.subscribe(RESPONSE_TOPIC, handle_command_response)

    # Start monitoring for node timeouts
    start_offline_monitor()

    # Broadcast initial discovery request
    mq.publish(DISCOVERY_REQUEST_TOPIC, "Who is online?")
    print("[master_node] Waiting for node responses and monitoring activity...")

    try:
        # Test: Send a command manually after startup delay
        time.sleep(5)  # Allow nodes to register first

        # Example: send calibration command to 'test_node'
        send_command("test_node", COMMAND_CALIBRATE, {"calibration_type": "quick"})

        # Keep main thread alive
        while True:
            time.sleep(1)

    except KeyboardInterrupt:
        print("[master_node] Shutdown signal received. Disconnecting...")
        mq.disconnect()
