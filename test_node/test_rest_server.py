"""
test_node/test_rest_server.py

Purpose:
- Simulates a REST API server node in the lab framework.
- Provides endpoints for status reporting, metadata sharing, and configuration.
- Waits for requests from the master node and responds with JSON data.

Usage:
- Run this script on a node intended to be queried by the master node.
- Ensure that the host is set to '0.0.0.0' to allow external connections.

Exposed Endpoints:
- GET /status     → Reports node health status.
- GET /metadata   → Reports node metadata (sensors/actuators).
- POST /configure → Accepts configuration parameters (JSON).

Note:
- Flask must be installed (`pip install flask`).
"""

from flask import Flask, request, jsonify

# Initialize the Flask app
app = Flask(__name__)

@app.route('/status', methods=['GET'])
def status():
    """
    Endpoint to report node status.
    Called by master node to check if this node is operational.
    """
    return jsonify({"node": "test_node", "status": "OK", "message": "System nominal"})

@app.route('/metadata', methods=['GET'])
def metadata():
    """
    Endpoint to provide node metadata.
    Includes information about sensors and actuators available.
    """
    return jsonify({
        "node": "test_node",
        "sensors": ["camera", "imu"],
        "actuators": ["motor"]
    })

@app.route('/configure', methods=['POST'])
def configure():
    """
    Endpoint to accept configuration data.
    Master node sends parameters via POST request.
    """
    data = request.json  # Extract incoming JSON payload
    print(f"[test_node] Configuration received: {data}")
    return jsonify({"success": True, "received": data})

if __name__ == '__main__':
    # Run the Flask app on all available network interfaces
    app.run(host='0.0.0.0', port=5000)

