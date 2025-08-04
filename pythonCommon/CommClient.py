"""
CommClient - Handles MQTT communication for distributed experiment nodes.

This class manages MQTT client setup, topic subscriptions, message publishing,
and message logging. It is designed to be used by all experiment nodes in
the automation framework and follows a standardized topic structure:
  <clientID>/cmd     - receive experiment commands (JSON)
  <clientID>/status  - publish node status and heartbeat
  <clientID>/data    - publish experimental data
  <clientID>/log     - publish structured logs and debug messages

Usage:
    config = {
        'clientID': 'node1',
        'brokerAddress': 'localhost',
        'brokerPort': 1883
    }
    client = CommClient(config)
    client.connect()
    client.comm_publish('node1/log', 'Hello')
"""

import json
import logging
import threading
import time
from collections import deque
from datetime import datetime
from typing import Dict, List, Callable, Any, Union

import paho.mqtt.client as mqtt


class CommClient:
    """
    MQTT communication client for distributed experiment nodes.
    
    Provides standardized MQTT communication with automatic topic management,
    message logging, heartbeat functionality, and configurable callbacks.
    """

    def __init__(self, config: Dict[str, Any]):
        """
        Initialize CommClient with configuration.
        
        Args:
            config: Configuration dictionary with required 'clientID' and optional parameters:
                - clientID (str): Unique identifier for this node
                - brokerAddress (str): MQTT broker address (default: 'localhost')
                - brokerPort (int): MQTT broker port (default: 1883)
                - onMessageCallback (callable): Optional message handler function
                - subscriptions (list): Custom subscription topics
                - publications (list): Custom publication topics  
                - heartbeatInterval (float): Seconds between heartbeats (0 disables)
                - keepAliveDuration (float): MQTT keepalive duration in seconds
                - verbose (bool): Enable debug output
                - timeout (float): Connection timeout in seconds
        
        Raises:
            ValueError: If clientID is missing or invalid
            TypeError: If callback is not callable
        """
        # Initialize essential attributes first to avoid destructor issues
        self.mqtt_client = None
        self._connected = False
        self._connection_lock = threading.Lock()
        self.message_log = deque(maxlen=1000)
        self._heartbeat_timer = None
        self._heartbeat_stop_event = threading.Event()
        self.last_heartbeat = None
        
        # Validate required fields
        if 'clientID' not in config or not config['clientID']:
            raise ValueError("clientID is required")
        
        self.client_id = config['clientID']
        self.tag = f"[Comm:{self.client_id}]"
        
        # Connection settings
        self.broker_address = config.get('brokerAddress', 'localhost')
        self.broker_port = config.get('brokerPort', 1883)
        self.keep_alive_duration = config.get('keepAliveDuration', 60)
        self.timeout = config.get('timeout', 30.0)
        
        # Message handling
        self.on_message_callback = None
        if 'onMessageCallback' in config:
            if not callable(config['onMessageCallback']):
                raise TypeError(f"{self.tag} onMessageCallback must be callable")
            self.on_message_callback = config['onMessageCallback']
        
        # Topic configuration
        self._setup_topics(config)
        
        # Heartbeat configuration
        self.heartbeat_interval = config.get('heartbeatInterval', 0)
        
        # Debug settings
        self.verbose = config.get('verbose', False)
        
        # Setup logging
        self.logger = logging.getLogger(f"CommClient.{self.client_id}")
        if self.verbose:
            self.logger.setLevel(logging.DEBUG)
            if not self.logger.handlers:
                handler = logging.StreamHandler()
                formatter = logging.Formatter(
                    f'{self.tag} %(levelname)s: %(message)s'
                )
                handler.setFormatter(formatter)
                self.logger.addHandler(handler)
        
        if self.verbose:
            self.logger.info(f"Initialized for clientID: {self.client_id}")
            self.logger.info(f"Broker: {self.broker_address}:{self.broker_port}")
            self.logger.info(f"Subscribed topics: {', '.join(self.subscriptions)}")
            self.logger.info(f"Publication topics: {', '.join(self.publications)}")

    def _setup_topics(self, config: Dict[str, Any]):
        """Setup subscription and publication topics with defaults."""
        # Default topic structure
        self.default_topics = {
            'cmd': f"{self.client_id}/cmd",
            'status': f"{self.client_id}/status", 
            'data': f"{self.client_id}/data",
            'log': f"{self.client_id}/log"
        }
        
        # Handle custom subscriptions
        if 'subscriptions' in config and config['subscriptions']:
            if not isinstance(config['subscriptions'], (list, tuple)):
                raise TypeError(f"{self.tag} subscriptions must be a list or tuple")
            self.subscriptions = list(config['subscriptions'])
        else:
            self.subscriptions = [self.default_topics['cmd']]
        
        # Handle custom publications
        if 'publications' in config and config['publications']:
            if not isinstance(config['publications'], (list, tuple)):
                raise TypeError(f"{self.tag} publications must be a list or tuple")
            self.publications = list(config['publications'])
        else:
            self.publications = [
                self.default_topics['status'],
                self.default_topics['data'],
                self.default_topics['log']
            ]

    def __del__(self):
        """Destructor to ensure cleanup on object deletion."""
        try:
            self.disconnect()
            if hasattr(self, 'verbose') and self.verbose and hasattr(self, 'logger'):
                self.logger.info("Object deleted and resources released")
        except Exception:
            # Silently ignore cleanup errors in destructor
            pass

    def connect(self):
        """
        Establish MQTT client connection to the broker.
        
        Creates MQTT client, connects to broker, subscribes to topics,
        and starts heartbeat timer if configured.
        
        Raises:
            ConnectionError: If connection fails
            Exception: For other MQTT-related errors
        """
        with self._connection_lock:
            if self._connected:
                if self.verbose:
                    self.logger.warning("Already connected")
                return
            
            try:
                if self.verbose:
                    self.logger.info(f"Attempting to connect to MQTT broker at {self.broker_address}:{self.broker_port}")
                
                # Create MQTT client
                self.mqtt_client = mqtt.Client(self.client_id)
                
                # Set up callbacks
                self.mqtt_client.on_connect = self._on_connect
                self.mqtt_client.on_disconnect = self._on_disconnect
                self.mqtt_client.on_message = self._on_message
                self.mqtt_client.on_subscribe = self._on_subscribe
                self.mqtt_client.on_publish = self._on_publish
                
                # Connect to broker
                self.mqtt_client.connect(
                    self.broker_address, 
                    self.broker_port, 
                    self.keep_alive_duration
                )
                
                # Start network loop in background
                self.mqtt_client.loop_start()
                
                # Wait for connection (with timeout)
                start_time = time.time()
                while not self._connected and (time.time() - start_time) < self.timeout:
                    time.sleep(0.1)
                
                if not self._connected:
                    raise ConnectionError(f"{self.tag} Connection timeout after {self.timeout} seconds")
                
                # Subscribe to initial topics
                for topic in self.subscriptions:
                    result, _ = self.mqtt_client.subscribe(topic)
                    if result != mqtt.MQTT_ERR_SUCCESS:
                        raise Exception(f"{self.tag} Failed to subscribe to {topic}")
                    
                    if self.verbose:
                        self.logger.info(f"Subscribed to topic: {topic}")
                
                # Start heartbeat timer if configured
                if self.heartbeat_interval > 0:
                    self._start_heartbeat_timer()
                
                if self.verbose:
                    self.logger.info("Successfully connected and subscribed")
                    
            except Exception as e:
                if self.verbose:
                    self.logger.error(f"ERROR during connection: {str(e)}")
                self._cleanup_connection()
                raise

    def disconnect(self):
        """
        Cleanly disconnect from MQTT broker and cleanup resources.
        
        Stops heartbeat timer, unsubscribes from topics, disconnects client,
        and releases all resources.
        """
        if not hasattr(self, '_connection_lock'):
            return
            
        with self._connection_lock:
            if not getattr(self, '_connected', False):
                return
            
            try:
                # Stop heartbeat timer
                self._stop_heartbeat_timer()
                
                # Disconnect MQTT client
                if self.mqtt_client:
                    self.mqtt_client.loop_stop()
                    self.mqtt_client.disconnect()
                    
                self._cleanup_connection()
                
                if getattr(self, 'verbose', False) and hasattr(self, 'logger'):
                    self.logger.info("Disconnected from broker and cleaned up")
                    
            except Exception as e:
                if hasattr(self, 'logger'):
                    self.logger.warning(f"Error while disconnecting: {str(e)}")

    def _cleanup_connection(self):
        """Internal method to clean up connection state."""
        self._connected = False
        self.mqtt_client = None

    def _on_connect(self, client, userdata, flags, rc):
        """Callback for successful MQTT connection."""
        if rc == 0:
            self._connected = True
            if self.verbose:
                self.logger.info("MQTT connection established")
        else:
            error_msg = f"MQTT connection failed with code {rc}"
            if self.verbose:
                self.logger.error(error_msg)
            raise ConnectionError(error_msg)

    def _on_disconnect(self, client, userdata, rc):
        """Callback for MQTT disconnection."""
        self._connected = False
        if self.verbose:
            if rc == 0:
                self.logger.info("MQTT disconnected normally")
            else:
                self.logger.warning(f"MQTT disconnected unexpectedly with code {rc}")

    def _on_message(self, client, userdata, msg):
        """Callback for received MQTT messages."""
        topic = msg.topic
        message = msg.payload.decode('utf-8')
        self.handle_message(topic, message)

    def _on_subscribe(self, client, userdata, mid, granted_qos):
        """Callback for successful subscription."""
        if self.verbose:
            self.logger.debug(f"Subscription confirmed with QoS {granted_qos}")

    def _on_publish(self, client, userdata, mid):
        """Callback for successful message publication."""
        if self.verbose:
            self.logger.debug(f"Message published with mid {mid}")

    def comm_publish(self, topic: str, payload: Union[str, dict]):
        """
        Publish a message to the specified topic via MQTT.
        
        Args:
            topic: Topic to publish to
            payload: Message payload (string or dict that will be JSON encoded)
        
        Raises:
            ConnectionError: If not connected to broker
            Exception: For other publish errors
        """
        if not self._connected or not self.mqtt_client:
            raise ConnectionError(f"{self.tag} MQTT client is not connected. Call connect() first.")
        
        try:
            # Convert dict payload to JSON string
            if isinstance(payload, dict):
                payload = json.dumps(payload)
            elif not isinstance(payload, str):
                payload = str(payload)
            
            # Publish message
            result = self.mqtt_client.publish(topic, payload)
            
            if result.rc != mqtt.MQTT_ERR_SUCCESS:
                raise Exception(f"Failed to publish to {topic}: error code {result.rc}")
            
            if self.verbose:
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                self.logger.info(f"→ \"{topic}\": {payload} [{timestamp}]")
                
        except Exception as e:
            if self.verbose:
                self.logger.error(f"ERROR during publish to topic \"{topic}\": {str(e)}")
            raise

    def send_heartbeat(self):
        """
        Construct and publish heartbeat JSON to <clientID>/status.
        
        Sends a standardized heartbeat message with timestamp and state info.
        """
        if not self._connected or not self.mqtt_client:
            if self.verbose:
                self.logger.warning("Skipped heartbeat: MQTT client is not connected")
            return
        
        payload = {
            'clientID': self.client_id,
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3],
            'state': 'READY'
        }
        
        topic = self.get_full_topic('status')
        
        try:
            self.comm_publish(topic, payload)
            self.last_heartbeat = datetime.now()
            
            if self.verbose:
                self.logger.info(f"Heartbeat sent to {topic}")
                
        except Exception as e:
            self.logger.error(f"Failed to send heartbeat: {str(e)}")

    def comm_subscribe(self, topic: str):
        """
        Dynamically subscribe to a topic and update internal list.
        
        Args:
            topic: Topic to subscribe to
            
        Raises:
            ConnectionError: If not connected to broker
            Exception: For subscription errors
        """
        if not self._connected or not self.mqtt_client:
            raise ConnectionError(f"{self.tag} MQTT client is not connected")
        
        if topic in self.subscriptions:
            if self.verbose:
                self.logger.info(f"Topic \"{topic}\" already subscribed")
            return
        
        result, _ = self.mqtt_client.subscribe(topic)
        if result != mqtt.MQTT_ERR_SUCCESS:
            raise Exception(f"Failed to subscribe to {topic}")
        
        self.subscriptions.append(topic)
        
        if self.verbose:
            self.logger.info(f"Successfully subscribed to topic: {topic}")

    def comm_unsubscribe(self, topic: str):
        """
        Unsubscribe from a topic and remove it from the list.
        
        Args:
            topic: Topic to unsubscribe from
            
        Raises:
            ConnectionError: If not connected to broker
            Exception: For unsubscription errors
        """
        if not self._connected or not self.mqtt_client:
            raise ConnectionError(f"{self.tag} MQTT client is not connected")
        
        if topic not in self.subscriptions:
            if self.verbose:
                self.logger.info(f"Topic \"{topic}\" is not currently subscribed")
            return
        
        result, _ = self.mqtt_client.unsubscribe(topic)
        if result != mqtt.MQTT_ERR_SUCCESS:
            raise Exception(f"Failed to unsubscribe from {topic}")
        
        self.subscriptions.remove(topic)
        
        if self.verbose:
            self.logger.info(f"Successfully unsubscribed from topic: {topic}")

    def handle_message(self, topic: str, message: str):
        """
        Log incoming message and optionally route it via user-defined callback.
        
        Used as message handler for MQTT client. Logs all messages and forwards
        to callback if configured.
        
        Args:
            topic: Topic the message was received on
            message: Message content
        """
        # Log message first
        self.add_to_log(topic, message)
        
        # Print to console if verbose
        if self.verbose:
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            self.logger.info(f"← \"{topic}\": {message} [{timestamp}]")
        
        # Forward to callback handler if defined
        if self.on_message_callback:
            try:
                self.on_message_callback(topic, message)
            except Exception as e:
                self.logger.warning(f"Error in onMessageCallback: {str(e)}")

    def get_full_topic(self, suffix: str) -> str:
        """
        Return full MQTT topic with node-scoped prefix.
        
        Args:
            suffix: Topic suffix (e.g., 'log', 'status', 'data', 'cmd')
            
        Returns:
            Full topic string (e.g., 'clientID/log')
            
        Raises:
            TypeError: If suffix is not a string
        """
        if not isinstance(suffix, str):
            raise TypeError(f"{self.tag} Suffix must be a string")
        
        topic = f"{self.client_id}/{suffix}"
        return topic

    def add_to_log(self, topic: str, message: str):
        """
        Store topic-message pair in messageLog with timestamp.
        
        Maintains a ring buffer of the last 1000 entries.
        
        Args:
            topic: Message topic
            message: Message content
            
        Raises:
            ValueError: If topic or message is empty
        """
        if not topic or not message:
            raise ValueError(f"{self.tag} Topic and message are required to log an entry")
        
        entry = {
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3],
            'topic': topic,
            'message': message
        }
        
        self.message_log.append(entry)

    def _start_heartbeat_timer(self):
        """Start the heartbeat timer in a separate thread."""
        if self.heartbeat_interval <= 0:
            return
        
        self._heartbeat_stop_event.clear()
        
        def heartbeat_loop():
            while not self._heartbeat_stop_event.wait(self.heartbeat_interval):
                if self._connected:
                    self.send_heartbeat()
                else:
                    break
        
        self._heartbeat_timer = threading.Thread(target=heartbeat_loop, daemon=True)
        self._heartbeat_timer.start()
        
        if self.verbose:
            self.logger.info(f"Heartbeat timer started with interval {self.heartbeat_interval} sec")

    def _stop_heartbeat_timer(self):
        """Stop the heartbeat timer."""
        if self._heartbeat_timer and self._heartbeat_timer.is_alive():
            self._heartbeat_stop_event.set()
            self._heartbeat_timer.join(timeout=1.0)
            self._heartbeat_timer = None
            
            if self.verbose:
                self.logger.info("Heartbeat timer stopped")

    @property
    def connected(self) -> bool:
        """Check if client is currently connected to broker."""
        return self._connected

    def get_message_log(self) -> List[Dict[str, str]]:
        """
        Get copy of current message log.
        
        Returns:
            List of message entries with timestamp, topic, and message
        """
        return list(self.message_log)

    def clear_message_log(self):
        """Clear the message log."""
        self.message_log.clear()
        if self.verbose:
            self.logger.info("Message log cleared")
