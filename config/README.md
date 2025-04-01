# Configuration Folder

This folder contains configuration files that define the behavior and identity of each node in the lab automation framework. 
These files allow the system to remain modular and maintainable by separating logic from configuration.

---

## Files

### 1. `node_role.txt`
Defines the **role** or **identity** of the current node.  
This value determines which node-specific code and startup routine to execute.

#### Examples:
Valid roles include:
- `master_node`
- `carriage_node`
- `wavemaker_node`
- `test_node`

This file should be manually updated during setup of each lab computer and example list should be expanded
if more nodes are added to the system.

---

### 2. `manifest.json`
A central map of all known roles and the corresponding code paths and startup scripts.  
This file is parsed by the updater script to determine which module each node should run.

#### Structure:
```json
{
  "role_name": {
    "path": "relative/path/to/code/",
    "startup_script": "entrypoint_file.py or .m"
  }
}
```
Make sure examples list in README.md matches the central map of all known roles. Case and space sensative.

---
## Usage Notes

These configuration files are read automatically by the pull_and_deploy.sh script.
Incorrect entries may prevent the node from booting correctly.