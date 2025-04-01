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
