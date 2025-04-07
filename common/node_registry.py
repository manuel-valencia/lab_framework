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

import time

class Node:
    """Represents a single node in the system."""
    def __init__(self, node_id, ip_address, role, capabilities=None):
        self.node_id = node_id
        self.ip_address = ip_address
        self.role = role
        self.capabilities = capabilities or []
        self.last_seen = time.time()
        self.status = "online"

    def update_last_seen(self):
        """Update the last seen timestamp to now."""
        self.last_seen = time.time()

    def mark_offline(self):
        """Mark the node as offline."""
        self.status = "offline"

    def to_dict(self):
        """Convert node details to a dictionary (for logging or exporting)."""
        return {
            "node_id": self.node_id,
            "ip_address": self.ip_address,
            "role": self.role,
            "capabilities": self.capabilities,
            "last_seen": self.last_seen,
            "status": self.status
        }


class NodeRegistry:
    """Registry that tracks all known nodes in the system."""
    def __init__(self):
        self.nodes = {}

    def add_or_update_node(self, node_id, ip_address, role, capabilities=None):
        """
        Add a new node or update an existing one.
        If the node already exists, update its details and timestamp.
        """
        if node_id in self.nodes:
            node = self.nodes[node_id]
            node.ip_address = ip_address
            node.role = role
            node.capabilities = capabilities or node.capabilities
            node.update_last_seen()
        else:
            node = Node(node_id, ip_address, role, capabilities)
            self.nodes[node_id] = node
        print(f"[NodeRegistry] Node added/updated: {node.to_dict()}")

    def mark_node_offline(self, node_id):
        """Mark a node as offline if it exists."""
        if node_id in self.nodes:
            self.nodes[node_id].mark_offline()
            print(f"[NodeRegistry] Node marked offline: {node_id}")

    def get_node(self, node_id):
        """Retrieve node information by node ID."""
        return self.nodes.get(node_id)

    def list_nodes(self):
        """List all nodes in the registry as dictionaries."""
        return [node.to_dict() for node in self.nodes.values()]

    def print_registry(self):
        """Print the current state of the node registry."""
        print("\n[NodeRegistry] Current Nodes:")
        for node in self.nodes.values():
            print(node.to_dict())

# # Example usage (for testing only)
# if __name__ == "__main__":
#     registry = NodeRegistry()
#     registry.add_or_update_node("node_1", "192.168.1.10", "test_node", ["sensor1", "actuator1"])
#     time.sleep(1)
#     registry.add_or_update_node("node_1", "192.168.1.10", "test_node", ["sensor1", "actuator1", "sensor2"])
#     registry.mark_node_offline("node_1")
#     registry.print_registry()
