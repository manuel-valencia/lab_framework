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

def handle_heartbeat(client, userdata, message):
    print("[RECEIVED HEARTBEAT]", message.payload.decode())
    mq.reset_heartbeat_timer()

mq = MQTTManager("test_node", broker="192.168.X.Y")  # Use master_node IP as broker
mq.connect()
mq.subscribe("lab/heartbeat", handle_heartbeat)
mq.enable_heartbeat_monitor(timeout_seconds=2)

print("[test_node] Listening for heartbeat...")
input("Press Enter to exit...\n")
mq.disconnect()
