"""
common/mqtt_manager.py

Manages MQTT connectivity, messaging, and safety heartbeat monitoring for lab nodes.

This module provides:
- A class interface for connecting to an MQTT broker
- Subscription and publishing methods
- Default connection/disconnection/reconnect behavior
- Deadman timeout logic for detecting missed heartbeats

Each node (master, carriage, wave) should instantiate this class and:
1. Connect to the broker
2. Subscribe to 'lab/heartbeat'
3. Call reset_heartbeat_timer() upon receiving a heartbeat
4. Use enable_heartbeat_monitor(timeout_seconds) to trigger fail-safes

Heartbeat timeout currently triggers a soft "UNSAFE" state.
Override `on_heartbeat_timeout()` to implement actuator shutdown.

Future support:
- Emergency stop callbacks
- Message logging
- QoS-level tuning
"""

import time
import threading
import paho.mqtt.client as mqtt


class MQTTManager:
    """
    Handles MQTT connection, subscriptions, and publishing for lab framework nodes.
    Also handles callbacks and deadman logic to ensure lab safety.
    """

    def __init__(self, node_name, broker="localhost", port=1883):
        """
        Initializes the MQTTManager.

        Args:
            node_name (str): Unique client ID for this node (used in MQTT)
            broker (str): Address of the MQTT broker
            port (int): Port for the MQTT broker (default: 1883)
        """
        self.node_name = node_name
        self.broker = broker
        self.port = port
        self.client = mqtt.Client(client_id=node_name)

        # Register built-in callbacks
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message

        # Optional: Notify others if this node goes offline unexpectedly
        self.client.will_set(f"lab/node/{node_name}/status", "OFFLINE", retain=True)

        # Heartbeat monitoring
        self.heartbeat_timeout = None
        self.last_heartbeat_time = None
        self._heartbeat_monitor_active = False

    def connect(self):
        """
        Attempts to connect to the broker and starts the MQTT loop.
        Retries until successful.
        """
        while True:
            try:
                print(f"[MQTT] Connecting to {self.broker}:{self.port}...")
                self.client.connect(self.broker, self.port)
                self.client.loop_start()
                break
            except Exception as e:
                print(f"[MQTT] Connection failed: {e}")
                print("[MQTT] Retrying in 2 seconds...")
                time.sleep(2)

    def disconnect(self):
        """
        Gracefully stops the client loop and disconnects from the broker.
        """
        self.client.loop_stop()
        self.client.disconnect()
        print("[MQTT] Disconnected cleanly.")

    def subscribe(self, topic, callback):
        """
        Subscribes to a topic and assigns a callback function.

        Args:
            topic (str): MQTT topic string
            callback (function): Function to handle received messages
        """
        self.client.subscribe(topic)
        self.client.message_callback_add(topic, callback)
        print(f"[MQTT] Subscribed to {topic}")

    def publish(self, topic, payload):
        """
        Publishes a message to a topic.

        Args:
            topic (str): MQTT topic to publish to
            payload (str): Message to send
        """
        result = self.client.publish(topic, payload)
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            print(f"[MQTT] Publish failed: {mqtt.error_string(result.rc)}")

    # ======================
    # Callback Definitions
    # ======================

    def on_connect(self, client, userdata, flags, rc):
        """
        Called when the client connects to the broker.

        rc = 0 means success; otherwise connection failed.
        """
        if rc == 0:
            print(f"[MQTT] Connected successfully as '{self.node_name}'")
            self.publish(f"lab/node/{self.node_name}/status", "ONLINE")
        else:
            print(f"[MQTT] Failed to connect: {mqtt.connack_string(rc)}")

    def on_disconnect(self, client, userdata, rc):
        """
        Called when the client disconnects. Tries to reconnect if not intentional.
        """
        print(f"[MQTT] Disconnected with code {rc}")
        while rc != 0:
            try:
                print("[MQTT] Attempting to reconnect...")
                rc = client.reconnect()
                time.sleep(2)
            except Exception as e:
                print(f"[MQTT] Reconnect failed: {e}")
                time.sleep(5)

    def on_message(self, client, userdata, message):
        """
        Fallback handler for unassigned topics.
        """
        print(f"[MQTT] Unhandled message on {message.topic}: {message.payload.decode()}")

    # ===========================
    # Heartbeat / Deadman Logic
    # ===========================

    def enable_heartbeat_monitor(self, timeout_seconds=10):
        """
        Starts a background thread to monitor heartbeat timeout.

        Args:
            timeout_seconds (int): How long to wait before triggering timeout
        """
        self.heartbeat_timeout = timeout_seconds
        self.last_heartbeat_time = time.time()
        self._heartbeat_monitor_active = True

        thread = threading.Thread(target=self._heartbeat_watcher, daemon=True)
        thread.start()

    def reset_heartbeat_timer(self):
        """
        Resets the heartbeat timer. Should be called when heartbeat is received.
        """
        self.last_heartbeat_time = time.time()

    def _heartbeat_watcher(self):
        """
        Internal thread that monitors heartbeat intervals.
        Triggers a timeout if the interval exceeds the threshold.
        """
        while self._heartbeat_monitor_active:
            time.sleep(0.01)  # Check every 10 ms
            if self.last_heartbeat_time is None:
                continue
            elapsed = time.time() - self.last_heartbeat_time
            if elapsed > self.heartbeat_timeout:
                print(f"[WARNING] Heartbeat timeout after {elapsed:.3f} seconds.")
                self.on_heartbeat_timeout()
                self._heartbeat_monitor_active = False

    def on_heartbeat_timeout(self):
        """
        Called when heartbeat is missed for too long.
        Override in node script if needed.
        """
        print(f"[MQTT] {self.node_name} entering UNSAFE state due to heartbeat timeout.")
        self.publish(f"lab/node/{self.node_name}/status", "UNSAFE")