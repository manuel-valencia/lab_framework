import time
try:
    from common.rest_client import send_get, send_post
except ModuleNotFoundError:
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.rest_client import send_get, send_post

JETSON_IP = "192.168.X.Y"  # Replace with actual Jetson IP!

print(f"[master_node] Testing REST API on Jetson ({JETSON_IP})")

# Test GET /status
print("\n[TEST] GET /status")
status = send_get(JETSON_IP, "/status")
print("Response:", status)

# Test GET /metadata
print("\n[TEST] GET /metadata")
metadata = send_get(JETSON_IP, "/metadata")
print("Response:", metadata)

# Test POST /configure
print("\n[TEST] POST /configure")
config = {"test_param": 42, "mode": "test"}
response = send_post(JETSON_IP, "/configure", data=config)
print("Response:", response)

print("\n[master_node] REST test completed.")
