"""
common/config.py

Shared constants used across all lab nodes.
Includes MQTT and REST settings for communication.

Import these directly in other modules:
    from common.config import MQTT_BROKER, MQTT_PORT

Note: For dynamic experiment settings, use a separate JSON/YAML config later.
"""

# MQTT settings
MQTT_BROKER = "localhost"
MQTT_PORT = 1883

# REST API settings
REST_PORT = 5000