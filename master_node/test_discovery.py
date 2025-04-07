import time
import json
# Attempt to import MQTTManager, NodeRegistry and configs from the common package
try:
    from common.config import MQTT_BROKER_IP
    from common.mqtt_manager import MQTTManager
    from common.node_registry import NodeRegistry
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import MQTT_BROKER_IP
    from common.mqtt_manager import MQTTManager
    from common.node_registry import NodeRegistry

# Initialize registry and MQTT
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
        node_info = json.loads(payload)  # Safe parsing
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

if __name__ == "__main__":
    mq.connect()
    mq.subscribe("lab/discovery/response", handle_discovery_response)

    # Start discovery
    start_discovery()

    # Allow time for nodes to respond
    print("[master_node] Waiting for responses...")
    time.sleep(5)

    # Print the current registry
    registry.print_registry()

    mq.disconnect()
