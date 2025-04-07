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
import socket
import json
import threading
import time

# Initialize MQTT
mq = MQTTManager("test_node", broker=MQTT_BROKER_IP)

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

def handle_discovery_request(client, userdata, message):
    """
    When a discovery request is received, respond with node details.
    """
    print("[test_node] Discovery request received!")

    node_info = {
    "node_id": "test_node",
    "ip_address": get_local_ip(),
    "role": "test_node",
    "capabilities": ["sensor", "actuator"]
}
    
def get_node_info():
    return {
        "node_id": "test_node",
        "ip_address": get_local_ip(),
        "role": "test_node",
        "capabilities": ["sensor", "actuator"]
    }

def send_periodic_heartbeat():
    while True:
        node_info = get_node_info()
        mq.publish("lab/discovery/response", json.dumps(node_info))
        print("[test_node] Sent periodic heartbeat.")
        time.sleep(HEARTBEAT_PUBLISH_INTERVAL)  # Adjust interval as desired

    mq.publish("lab/discovery/response", json.dumps(node_info))
    print("[test_node] Sent discovery response.")

if __name__ == "__main__":
    mq.connect()
    mq.subscribe("lab/discovery/request", handle_discovery_request)

    # Start periodic heartbeat thread
    heartbeat_thread = threading.Thread(target=send_periodic_heartbeat, daemon=True)
    heartbeat_thread.start()

    print("[test_node] Listening for discovery requests...")
    input("Press Enter to exit...\n")
    mq.disconnect()

    mq.disconnect()
