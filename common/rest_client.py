"""
common/rest_client.py

Provides helper functions for sending REST API requests (GET and POST) 
between lab nodes. Used by the master node to query or configure other nodes.

Usage:
    from common.rest_client import send_get, send_post

    data = send_get("192.168.1.42", "/status")
    response = send_post("192.168.1.42", "/configure", data={"gain": 5})

Notes:
- Assumes all nodes expose a REST interface on port 5000 by default.
- Extend this later to support authentication or timeouts if needed.
"""

import requests

def send_get(ip, endpoint="/status", port=5000):
    """
    Sends a GET request to the specified node.

    Args:
        ip (str): IP address of the target node
        endpoint (str): REST endpoint to query (default: /status)
        port (int): Port for REST server (default: 5000)

    Returns:
        dict: Parsed JSON response or error info
    """
    url = f"http://{ip}:{port}{endpoint}"
    try:
        response = requests.get(url, timeout=2)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"[REST] GET {url} failed: {e}")
        return {"error": str(e)}


def send_post(ip, endpoint="/configure", data=None, port=5000):
    """
    Sends a POST request with a JSON payload to the target node.

    Args:
        ip (str): IP address of the target node
        endpoint (str): REST endpoint to call (default: /configure)
        data (dict): Data payload to send in JSON format
        port (int): Port for REST server (default: 5000)

    Returns:
        dict: Parsed JSON response or error info
    """
    url = f"http://{ip}:{port}{endpoint}"
    try:
        response = requests.post(url, json=data, timeout=2)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"[REST] POST {url} failed: {e}")
        return {"error": str(e)}
