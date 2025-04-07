"""
test_node/test_mqtt.py

Purpose:
- Simulate a test node in the lab framework.
- Subscribes to heartbeat messages sent over MQTT.
- Uses deadman timer to monitor heartbeat continuity and print warnings if lost.

Usage:
- Ensure the MQTT broker is running and the master node is publishing heartbeats.
- Update the broker IP to the machine hosting the MQTT broker.

Note:
- This node listens for 'lab/heartbeat' messages.
- When heartbeat is received, it resets the deadman timer.
- If no heartbeat is received within the timeout, an unsafe state warning is printed.
"""

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

# Attempt to import MQTTManager from the common package
try:
    from common.config import MQTT_BROKER_IP, HEARTBEAT_TIMEOUT
    from common.mqtt_manager import MQTTManager
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import MQTT_BROKER_IP, HEARTBEAT_TIMEOUT
    from common.mqtt_manager import MQTTManager

def handle_heartbeat(client, userdata, message):
    """
    Callback function triggered when a heartbeat message is received.
    Resets the heartbeat timer to indicate system activity.
    """
    print("[RECEIVED HEARTBEAT]", message.payload.decode())
    mq.reset_heartbeat_timer()

# Initialize MQTT client for the test node
mq = MQTTManager("test_node", broker=MQTT_BROKER_IP)  # Replace with broker IP address
mq.connect()

# Subscribe to heartbeat topic and assign the callback
mq.subscribe("lab/heartbeat", handle_heartbeat)

# Start monitoring for heartbeat loss (deadman timer)
mq.enable_heartbeat_monitor(timeout_seconds=HEARTBEAT_TIMEOUT)

print("[test_node] Listening for heartbeat...")
input("Press Enter to exit...\n")

# Clean up connection on script termination
mq.disconnect()
