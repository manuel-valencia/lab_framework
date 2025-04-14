"""
common/node_registry.py

Manages the registry of active nodes in the lab framework.
Tracks node metadata, roles, IP addresses, status, and capabilities.

Usage:
- Master node uses this to maintain an updated view of the network.
- Nodes responding to discovery messages will be added to this registry.

Future extensions:
- Persistent registry storage (save/load to JSON)
- Timestamping and pruning inactive nodes
- Role-based node queries
- Integration with heartbeat monitoring
"""
import json
import os
import time
from datetime import datetime
try:
    from common.config import NODE_TIMEOUT_SECONDS
except ModuleNotFoundError:
    # If common package not found, append project root to sys.path
    print("Adding path to file since python has issues recognizing common as package")
    import sys, os
    sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
    from common.config import NODE_TIMEOUT_SECONDS

class Node:
    """Represents a single node in the system."""
    def __init__(self, node_id, ip_address, role, capabilities=None):
        self.node_id = node_id
        self.ip_address = ip_address
        self.role = role
        self.capabilities = capabilities or []
        self.last_seen = time.time()
        self.status = "online"
        self.history = []  # List to track command history (dicts)


    def update_last_seen(self):
        """Update the last seen timestamp to now."""
        self.last_seen = time.time()

    def mark_offline(self):
        """Mark the node as offline."""
        self.status = "offline"

    def to_dict(self):
        """Convert node details to a dictionary (for logging or exporting)."""
        readable_time = datetime.fromtimestamp(self.last_seen).strftime("%Y-%m-%d %H:%M:%S")
        return {
            "node_id": self.node_id,
            "ip_address": self.ip_address,
            "role": self.role,
            "capabilities": self.capabilities,
            "last_seen": self.last_seen,
            "last_seen_readable": readable_time,
            "status": self.status,
            "history": self.history
        }


class NodeRegistry:
    def __init__(self, save_path="config/node_registry.json"):
        self.nodes = {}
        self.save_path = save_path
        self.load_registry()

    def load_registry(self):
        """Load node registry from JSON file if it exists."""
        if os.path.exists(self.save_path):
            try:
                with open(self.save_path, "r") as f:
                    data = json.load(f)
                    for node_id, node_data in data.items():
                        self.nodes[node_id] = Node(
                            node_id=node_data["node_id"],
                            ip_address=node_data["ip_address"],
                            role=node_data["role"],
                            capabilities=node_data["capabilities"]
                        )
                        self.nodes[node_id].last_seen = node_data.get("last_seen", time.time())
                        self.nodes[node_id].status = node_data.get("status", "online")
                print(f"[NodeRegistry] Loaded registry from {self.save_path}")
            except Exception as e:
                print(f"[NodeRegistry] Failed to load registry: {e}")

    def save_registry(self):
        """Save current node registry to JSON file."""
        try:
            with open(self.save_path, "w") as f:
                json.dump({node_id: node.to_dict() for node_id, node in self.nodes.items()}, f, indent=4)
            #print(f"[NodeRegistry] Saved registry to {self.save_path}")
        except Exception as e:
            print(f"[NodeRegistry] Failed to save registry: {e}")

    def print_registry(self):
        """Print the current state of the node registry."""
        print("\n[NodeRegistry] Current Nodes:")
        for node in self.nodes.values():
            print(node.to_dict())

    def get_node(self, node_id):
        """
        Retrieves a node by its node_id.
        Returns None if node does not exist.
        """
        return self.nodes.get(node_id)

    def add_or_update_node(self, node_id, ip_address, role, capabilities=None):
        if node_id in self.nodes:
            node = self.nodes[node_id]
            node.ip_address = ip_address
            node.role = role
            node.capabilities = capabilities or node.capabilities
            node.update_last_seen()
            if node.status == "offline":
                node.status = "online"
                print(f"[NodeRegistry] Node {node_id} recovered and marked ONLINE.")
        else:
            node = Node(node_id, ip_address, role, capabilities)
            self.nodes[node_id] = node
        #print(f"[NodeRegistry] Node added/updated: {node.to_dict()}")
        self.save_registry()  # Auto-save on each update

    def check_for_offline_nodes(self, timeout_seconds=NODE_TIMEOUT_SECONDS):
        """
        Check all nodes and mark them offline if they haven't been seen recently.
        """
        current_time = time.time()
        for node_id, node in self.nodes.items():
            if current_time - node.last_seen > timeout_seconds and node.status != "offline":
                node.mark_offline()
                print(f"[NodeRegistry] Node {node_id} marked offline due to timeout.")
        self.save_registry()

# # Example usage (for testing only)
# if __name__ == "__main__":
#     registry = NodeRegistry()
#     registry.add_or_update_node("node_1", "192.168.1.10", "test_node", ["sensor1", "actuator1"])
#     time.sleep(1)
#     registry.add_or_update_node("node_1", "192.168.1.10", "test_node", ["sensor1", "actuator1", "sensor2"])
#     registry.mark_node_offline("node_1")
#     registry.print_registry()
