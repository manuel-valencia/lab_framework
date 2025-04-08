"""
test_master_node/test_discovery.py

This script runs the master node logic for dynamic node discovery and registry maintenance.

Functionality:
- Acts as the control node for discovery and registry management.
- Connects to MQTT broker (assumed to be running on the master node).
- Broadcasts discovery requests to all nodes.
- Listens for discovery responses from nodes and updates the central node registry.
- Monitors node status (online/offline) in real-time based on heartbeat and registry timestamps.

Usage:
- Start MQTT broker on the master node.
- Run this script to initiate discovery and monitoring.
- Nodes that respond will be dynamically registered.
- Nodes that stop responding will be marked offline after timeout.
- Supports dynamic re-joining: nodes coming back online will be marked as online.

Note:
- Configuration values such as broker IP and timeout are loaded from `common/config.py`.
- Node registry is auto-saved to `config/node_registry.json`.

"""

import time
import threading
import json

# Attempt to import MQTTManager, NodeRegistry and configs from the common package
try:
    from common.config import MQTT_BROKER_IP, NODE_TIMEOUT_SECONDS
    from common.mqtt_manager import MQTTManager
    from common.node_registry import NodeRegistry
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import MQTT_BROKER_IP, NODE_TIMEOUT_SECONDS
    from common.mqtt_manager import MQTTManager
    from common.node_registry import NodeRegistry

# Initialize the node registry to track active nodes
registry = NodeRegistry()

# Initialize the MQTT client for the master node
mq = MQTTManager("master_node", broker=MQTT_BROKER_IP)

def handle_discovery_response(client, userdata, message):
    """
    Callback function to process discovery responses from nodes.
    Updates the node registry with node details.
    """
    payload = message.payload.decode()
    print(f"[master_node] Discovery response received: {payload}")

    try:
        # Parse the incoming JSON payload
        node_info = json.loads(payload)

        # Update the node registry with the node's details
        registry.add_or_update_node(
            node_id=node_info.get("node_id"),
            ip_address=node_info.get("ip_address"),
            role=node_info.get("role"),
            capabilities=node_info.get("capabilities")
        )
    except Exception as e:
        print(f"[master_node] Error processing discovery response: {e}")

def start_discovery():
    """
    Broadcasts discovery request to all nodes via MQTT.
    """
    print("[master_node] Broadcasting discovery request...")
    mq.publish("lab/discovery/request", "Who is online?")

def start_offline_monitor():
    """
    Periodically checks for offline nodes in the registry.
    Runs in a separate daemon thread to avoid blocking main execution.
    """
    def monitor():
        while True:
            registry.check_for_offline_nodes(timeout_seconds=NODE_TIMEOUT_SECONDS)
            time.sleep(1)  # Check every second

    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    print(f"[master_node] Offline monitor started (timeout = {NODE_TIMEOUT_SECONDS}s)")

if __name__ == "__main__":
    # Connect to MQTT broker and subscribe to discovery response topic
    mq.connect()
    mq.subscribe("lab/discovery/response", handle_discovery_response)

    # Start background thread to monitor node status
    start_offline_monitor()

    # Perform initial discovery broadcast
    start_discovery()

    print("[master_node] Waiting for node responses and monitoring activity...")

    try:
        # Keep the main thread alive indefinitely
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        # Graceful shutdown on Ctrl+C
        print("[master_node] Shutting down gracefully.")
        mq.disconnect()
