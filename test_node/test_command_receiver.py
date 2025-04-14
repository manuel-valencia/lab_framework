"""
test_node/test_command_receiver.py

Test node script to:
- Connect to MQTT broker
- Subscribe to its command topic
- Process incoming commands (simulate calibration)
- Send structured responses back to the master node

Usage:
- Start the MQTT broker on the master node
- Run this script on the test node
- Test node will listen for commands and respond accordingly
"""

import socket
import time
import json
import threading
from datetime import datetime

# Import constants
try:
    from common.config import *
    from common.mqtt_manager import MQTTManager
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import *
    from common.mqtt_manager import MQTTManager

# =============================================================================
# Utility Functions
# =============================================================================

def get_local_ip():
    """Returns local IP address of this node."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

def get_node_info():
    """Returns node metadata."""
    return {
        "node_id": "test_node",
        "ip_address": get_local_ip(),
        "role": "test_node",
        "capabilities": ["sensor", "actuator"]
    }

# =============================================================================
# MQTT Initialization
# =============================================================================

mq = MQTTManager("test_node", broker=MQTT_BROKER_IP)

# =============================================================================
# Command Handler
# =============================================================================

def handle_command(client, userdata, message):
    """
    Handles incoming commands from the master node.
    Simulates command execution and sends response.
    """
    payload = message.payload.decode()
    reception_time = time.time()

    print(f"[test_node] Command received: {payload}")

    try:
        command_data = json.loads(payload)
        command = command_data.get(FIELD_COMMAND)
        params = command_data.get(FIELD_PARAMS, {})
        node_id = command_data.get(FIELD_NODE_ID)
        session_id = command_data.get(FIELD_SESSION_ID, DEFAULT_SESSION_ID)
        command_timestamp = command_data.get(FIELD_TIMESTAMP)

        # Start timing for simulated response
        start_time = time.time()

        # Simulate command execution
        if command == COMMAND_CALIBRATE:
            print("[test_node] Simulating calibration...")
            time.sleep(0.2)  # Simulate calibration duration
            status = STATUS_SUCCESS
            details = "Calibration completed successfully."
        else:
            print(f"[test_node] Unknown command: {command}")
            status = STATUS_ERROR
            details = f"Unknown command: {command}"

        # Measure response time in ms
        response_time_ms = round((time.time() - start_time) * 1000, 2)

        # Build response message
        response = {
            FIELD_STATUS: status,
            FIELD_COMMAND: command,
            FIELD_NODE_ID: node_id,
            FIELD_DETAILS: details,
            FIELD_TIMESTAMP: reception_time,
            FIELD_RESPONSE_TIME_MS: response_time_ms
        }

        # Publish response
        mq.publish(RESPONSE_TOPIC, json.dumps(response))
        print(f"[test_node] Sent response: {response}")

    except Exception as e:
        print(f"[test_node] Error processing command: {e}")

# =============================================================================
# Periodic Heartbeat Sender
# =============================================================================

def send_periodic_heartbeat():
    """Sends periodic heartbeat messages to announce node presence."""
    while True:
        node_info = get_node_info()
        mq.publish(DISCOVERY_RESPONSE_TOPIC, json.dumps(node_info))
        print("[test_node] Sent periodic heartbeat.")
        time.sleep(HEARTBEAT_PUBLISH_INTERVAL)

# =============================================================================
# Main Execution
# =============================================================================

if __name__ == "__main__":
    # Connect to MQTT broker
    mq.connect()

    # Subscribe to the node's command topic
    command_topic = f"{COMMAND_TOPIC}/test_node"
    mq.subscribe(command_topic, handle_command)
    print(f"[test_node] Subscribed to command topic: {command_topic}")

    # Start periodic heartbeat thread
    heartbeat_thread = threading.Thread(target=send_periodic_heartbeat, daemon=True)
    heartbeat_thread.start()

    print("[test_node] Listening for commands and sending heartbeats...")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("[test_node] Shutdown signal received. Disconnecting...")
        mq.disconnect()
