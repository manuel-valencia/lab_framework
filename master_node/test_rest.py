"""
master_node/test_rest.py

Purpose:
- Simulates the master node acting as a REST API client.
- Sends GET and POST requests to a node running the REST server.
- Tests endpoints: status, metadata, and configuration.

Usage:
- Ensure the target node is running `test_rest_server.py`.
- Set the correct IP address of the target node in the config file.

Note:
- Depends on common/rest_client.py utilities.
- Requires `requests` library (`pip install requests`).
"""
try:
    from common.config import REST_TARGET_IP
    from common.rest_client import send_get, send_post
except ModuleNotFoundError:
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import REST_TARGET_IP
    from common.rest_client import send_get, send_post

print(f"[master_node] Testing REST API on node at IP: {REST_TARGET_IP}")

# Test GET /status endpoint
print("\n[TEST] GET /status")
status = send_get(REST_TARGET_IP, "/status")
print("Response:", status)

# Test GET /metadata endpoint
print("\n[TEST] GET /metadata")
metadata = send_get(REST_TARGET_IP, "/metadata")
print("Response:", metadata)

# Test POST /configure endpoint with test data
print("\n[TEST] POST /configure")
config = {"test_param": 42, "mode": "test"}
response = send_post(REST_TARGET_IP, "/configure", data=config)
print("Response:", response)

print("\n[master_node] REST test completed.")
