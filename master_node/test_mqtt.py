"""
master_node/test_mqtt.py

Purpose:
- Simulate the master control node in the lab framework.
- Sends periodic heartbeat messages over MQTT to maintain system synchronization.
- Displays the IP address for other nodes to connect to this master.

Usage:
- Ensure MQTT broker is running and accessible to the network.
- Run this script to begin heartbeat publishing.

Note:
- This script does not listen for messages; it only publishes.
- Use with test nodes subscribing to 'lab/heartbeat'.
"""

import time
import socket

def get_local_ip():
    """
    Returns the local IP address of the current machine.
    Useful for displaying connection info for other nodes.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Use dummy connection to obtain outbound IP address
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

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

# Display local IP for easy reference
print(f"[master_node] Detected IP address: {get_local_ip()}")

# Initialize MQTT client for the master node
mq = MQTTManager("master_node", broker=MQTT_BROKER_IP)
mq.connect()

try:
    while True:
        # Publish heartbeat message on the shared topic
        print("[master_node] Sending heartbeat...")
        mq.publish("lab/heartbeat", "PING from master_node")
        time.sleep(HEARTBEAT_PUBLISH_INTERVAL)  # Wait .1 second before sending next heartbeat
except KeyboardInterrupt:
    # Clean up connection on script termination
    print("[master_node] Stopping heartbeat.")
    mq.disconnect()
