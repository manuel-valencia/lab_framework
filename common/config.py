"""
common/config.py

Shared constants and configurations for lab framework nodes.
Modify these values to change node behavior, communication, and system behavior.

Usage:
    from common.config import *
"""

# =============================================================================
# Network Configuration
# =============================================================================

# MQTT broker settings
MQTT_BROKER_IP = "10.29.219.193"  # Master node IP running the MQTT broker
MQTT_PORT = 1883                 # Default MQTT port

# REST target node IP (optional, node running Flask server)
REST_TARGET_IP = "10.29.251.171"

# =============================================================================
# Heartbeat & Registry Configuration
# =============================================================================

# Heartbeat settings (in seconds)
HEARTBEAT_PUBLISH_INTERVAL = 0.1   # Interval between node heartbeats
HEARTBEAT_TIMEOUT = 0.2            # Time before marking node heartbeat lost

# Registry node timeout threshold (in seconds)
NODE_TIMEOUT_SECONDS = 5           # Time before marking node as offline

# =============================================================================
# MQTT Topics
# =============================================================================

COMMAND_TOPIC = "lab/commands"                # Master to node commands
RESPONSE_TOPIC = "lab/commands/response"      # Node to master responses

DISCOVERY_REQUEST_TOPIC = "lab/discovery/request"
DISCOVERY_RESPONSE_TOPIC = "lab/discovery/response"

HEARTBEAT_TOPIC = "lab/heartbeat"             # Heartbeat messages

# =============================================================================
# Command Types
# =============================================================================

COMMAND_CALIBRATE = "calibrate"
COMMAND_VALIDATE = "validate"
COMMAND_START_TEST = "start_test"
COMMAND_STOP_TEST = "stop_test"

# Optional future commands
COMMAND_SHUTDOWN = "shutdown"
COMMAND_STATUS_CHECK = "status_check"

# =============================================================================
# Standard Command / Response Schema Fields
# =============================================================================

# Command payload fields (Master → Node)
FIELD_COMMAND = "command"
FIELD_PARAMS = "params"
FIELD_NODE_ID = "node_id"
FIELD_TIMESTAMP = "timestamp"
FIELD_SESSION_ID = "session_id"

# Response payload fields (Node → Master)
FIELD_STATUS = "status"
FIELD_DETAILS = "details"
FIELD_RESPONSE_TIME_MS = "response_time_ms"
FIELD_ERROR_CODE = "error_code"

# =============================================================================
# Status Values
# =============================================================================

STATUS_SUCCESS = "success"
STATUS_ERROR = "error"
STATUS_WARNING = "warning"

# =============================================================================
# Error Codes (optional, future use)
# =============================================================================

ERROR_GENERIC = 1
ERROR_INVALID_COMMAND = 2
ERROR_TIMEOUT = 3
ERROR_EXECUTION_FAILED = 4

# =============================================================================
# Miscellaneous
# =============================================================================

# Default session ID (can be overwritten for experiments)
DEFAULT_SESSION_ID = "default_session"

# =============================================================================
# End of config
# =============================================================================
