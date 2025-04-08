"""
test_node/test_discovery.py

This script runs the test node logic for proactive announcements and participation in the node registry.

Functionality:
- Connects to the MQTT broker hosted on the master node.
- Subscribes to discovery requests from the master node.
- Proactively sends periodic heartbeat announcements containing node details.
- Replies to discovery requests from the master node.
- Helps maintain up-to-date node status in the master node's registry.

Usage:
- Ensure the MQTT broker is running on the master node.
- Run this script to simulate a node participating in the system.
- This script will periodically broadcast its presence to the master node.
- On shutdown, the master node will mark this node offline after a timeout.

Note:
- Configuration values such as broker IP and heartbeat interval are loaded from `common/config.py`.
"""

import socket
import json
import threading
import time

# Attempt to import MQTTManager and configs from the common package
try:
    from common.config import MQTT_BROKER_IP, HEARTBEAT_PUBLISH_INTERVAL
    from common.mqtt_manager import MQTTManager
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import MQTT_BROKER_IP, HEARTBEAT_PUBLISH_INTERVAL
    from common.mqtt_manager import MQTTManager

# Initialize MQTT client
mq = MQTTManager("test_node", broker=MQTT_BROKER_IP)

def get_local_ip():
    """Returns local IP address of this node."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Using Google's DNS to determine outbound IP
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

def get_node_info():
    """
    Builds the node information dictionary.
    """
    return {
        "node_id": "test_node",
        "ip_address": get_local_ip(),
        "role": "test_node",
        "capabilities": ["sensor", "actuator"]
    }

def handle_discovery_request(client, userdata, message):
    """
    Callback function: respond to discovery requests from the master node.
    """
    print("[test_node] Discovery request received!")

    node_info = get_node_info()
    mq.publish("lab/discovery/response", json.dumps(node_info))
    print("[test_node] Sent discovery response.")

def send_periodic_heartbeat():
    """
    Periodically send heartbeat messages to announce node status.
    Runs in a separate daemon thread.
    """
    while True:
        node_info = get_node_info()
        mq.publish("lab/discovery/response", json.dumps(node_info))
        print("[test_node] Sent periodic heartbeat.")
        time.sleep(HEARTBEAT_PUBLISH_INTERVAL)

if __name__ == "__main__":
    # Connect to MQTT broker
    mq.connect()

    # Subscribe to discovery requests from the master node
    mq.subscribe("lab/discovery/request", handle_discovery_request)

    # Start periodic heartbeat thread
    heartbeat_thread = threading.Thread(target=send_periodic_heartbeat, daemon=True)
    heartbeat_thread.start()

    print("[test_node] Listening for discovery requests and sending heartbeats...")
    try:
        # Keep the main thread alive
        input("Press Enter to exit...\n")
    except KeyboardInterrupt:
        print("[test_node] Shutdown signal received.")

    # Graceful disconnect
    mq.disconnect()
