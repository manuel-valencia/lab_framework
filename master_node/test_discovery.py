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

# Initialize registry and MQTT manager
registry = NodeRegistry()
mq = MQTTManager("master_node", broker=MQTT_BROKER_IP)

def handle_discovery_response(client, userdata, message):
    """
    Callback function to process discovery responses from nodes.
    Updates the node registry with node details.
    """
    payload = message.payload.decode()
    print(f"[master_node] Discovery response received: {payload}")

    try:
        node_info = json.loads(payload)
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
    Runs in a separate thread.
    """
    def monitor():
        while True:
            registry.check_for_offline_nodes(timeout_seconds=NODE_TIMEOUT_SECONDS)
            time.sleep(1)  # Check every second
    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    print(f"[master_node] Offline monitor started (timeout = {NODE_TIMEOUT_SECONDS}s)")

if __name__ == "__main__":
    # Connect to MQTT broker and subscribe to discovery responses
    mq.connect()
    mq.subscribe("lab/discovery/response", handle_discovery_response)

    # Start offline monitor thread
    start_offline_monitor()

    # Start discovery broadcast
    start_discovery()

    print("[master_node] Waiting for node responses and monitoring activity...")
    try:
        # Main thread stays alive
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("[master_node] Shutting down gracefully.")
        mq.disconnect()
