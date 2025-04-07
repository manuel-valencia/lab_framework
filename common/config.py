"""
common/config.py

Shared constants and configurations for lab framework nodes.
Modify these values to change node behavior and networking.

Usage:
    from common.config import MQTT_BROKER_IP, HEARTBEAT_PUBLISH_INTERVAL
"""

# MQTT broker settings
MQTT_BROKER_IP = "10.31.153.83"  # Set this to your broker IP
MQTT_PORT = 1883

# Heartbeat settings (in seconds)
HEARTBEAT_PUBLISH_INTERVAL = 0.1   # Interval between master node heartbeats
HEARTBEAT_TIMEOUT = 0.2            # Max time to wait before triggering timeout

# REST target node IP (node running Flask server)
REST_TARGET_IP = "10.29.251.171"