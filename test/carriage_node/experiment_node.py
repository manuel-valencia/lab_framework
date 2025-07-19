"""
test_node/experiment_node.py

Test node script to:
- Connect to MQTT broker
- Subscribe to experiment command topics
- Simulate force sensor and wave maker experiments
- Send structured responses back to the master node
- Maintain clean and concise terminal output
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
    Simulates experiment steps and sends response.
    """
    payload = message.payload.decode()
    reception_time = time.time()

    try:
        command_data = json.loads(payload)
        command = command_data.get(FIELD_COMMAND)
        params = command_data.get(FIELD_PARAMS, {})
        node_id = command_data.get(FIELD_NODE_ID)
        session_id = command_data.get(FIELD_SESSION_ID, DEFAULT_SESSION_ID)

        print(f"[test_node] Received command: {command}")

        # Simulate command execution
        start_time = time.time()
        status = STATUS_SUCCESS
        details = ""

        if command == COMMAND_CALIBRATE:
            print("[test_node] Simulating calibration...")
            time.sleep(0.5)  # Simulate calibration time
            details = "Calibration completed successfully."

        elif command == COMMAND_VALIDATE:
            print("[test_node] Simulating validation...")
            time.sleep(0.3)
            details = "Validation completed successfully."

        elif command == "run_force_test":
            print(f"[test_node] Simulating force test with params: {params}")
            duration = params.get("duration_seconds", 5)
            time.sleep(duration * 0.1)  # Simulate faster-than-real-time for test
            details = f"Force test completed, simulated {duration} seconds."

        elif command == "run_wave_test":
            print(f"[test_node] Simulating wave test with params: {params}")
            duration = params.get("duration_seconds", 5)
            time.sleep(duration * 0.1)
            details = f"Wave test completed, simulated {duration} seconds."

        else:
            print(f"[test_node] Unknown command: {command}")
            status = STATUS_ERROR
            details = f"Unknown command: {command}"

        # Calculate simulated response time in ms
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
        time.sleep(HEARTBEAT_PUBLISH_INTERVAL)

# =============================================================================
# Main Execution
# =============================================================================

if __name__ == "__main__":
    # Connect to MQTT broker
    mq.connect()

    # Subscribe to this node's command topic
    command_topic = f"{COMMAND_TOPIC}/test_node"
    mq.subscribe(command_topic, handle_command)

    # Start periodic heartbeat thread
    heartbeat_thread = threading.Thread(target=send_periodic_heartbeat, daemon=True)
    heartbeat_thread.start()

    print("[test_node] Ready and listening for commands...")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("[test_node] Shutdown signal received. Disconnecting...")
        mq.disconnect()
