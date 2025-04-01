import time
from common.mqtt_manager import MQTTManager

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
