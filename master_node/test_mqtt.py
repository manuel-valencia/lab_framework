import time
import socket

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

try:
    from common.mqtt_manager import MQTTManager
except ModuleNotFoundError:
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.mqtt_manager import MQTTManager

# Show the IP for the test node to use
print(f"[master_node] Detected IP address: {get_local_ip()}")

mq = MQTTManager("master_node", broker="localhost")
mq.connect()

try:
    while True:
        print("[master_node] Sending heartbeat...")
        mq.publish("lab/heartbeat", "PING from master_node")
        time.sleep(1)
except KeyboardInterrupt:
    print("[master_node] Stopping heartbeat.")
    mq.disconnect()
