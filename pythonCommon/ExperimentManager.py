"""
ExperimentManager.py

Abstract state machine controller for laboratory experiment nodes.

This class defines a generic state-driven experiment framework for hardware
nodes in automated laboratory systems. Nodes can represent either data
collectors (sensors), actuators, or hybrid devices.

Responsibilities:
  - Handle MQTT-based commands (e.g., "Calibrate", "Run", "Reset")
  - Manage state transitions between experiment phases
  - Publish structured status updates
  - Delegate hardware behavior to subclass implementations
  - Send and retrieve experiment data via REST API (RestClient)

Example:
    cfg = {'clientID': 'sensorNode1', 'hardware': {'hasSensor': True}}
    comm = CommClient(cfg)
    rest = RestClient(cfg)
    mgr = MyNodeManager(cfg, comm, rest)

Required subclass implementations include:
  - initialize_hardware
  - stop_hardware, shutdown_hardware
  - handle_calibrate, handle_test, handle_run
  - configure_hardware
"""

import json
import logging
import os
import pickle
import traceback
from abc import ABC, abstractmethod
from datetime import datetime
from enum import IntEnum
from typing import Dict, List, Any, Optional, Union

import pandas as pd
import re

from .CommClient import CommClient
from .RestClient import RestClient


class State(IntEnum):
    """
    Finite state machine states for experiment automation framework.
    
    These states enable each node to track and transition through well-defined
    operational phases, ensuring coherent execution logic across all components.
    """
    BOOT = 0                # Initial state after node instantiation
    IDLE = 1                # Ready to receive commands
    CALIBRATING = 2         # Executing calibration routine
    TESTINGSENSOR = 3       # Live sensor diagnostics
    CONFIGUREVALIDATE = 4   # Validating experiment configuration
    CONFIGUREPENDING = 5    # Valid config pending user validation
    TESTINGACTUATOR = 6     # Testing actuator functionality
    RUNNING = 7             # Active experiment execution
    POSTPROC = 8            # Post-processing results
    DONE = 9                # Task completed, sending data
    ERROR = 10              # Fault state requiring recovery


class ExperimentManager(ABC):
    """
    Abstract state machine controller for experiment nodes.
    
    Provides integration with CommClient for inbound MQTT messages and
    RestClient for data transfer, while maintaining internal state using
    the State enumeration.
    """
    
    # Supported command keywords
    VALID_COMMANDS = [
        "Calibrate", "Test", "Run", "TestValid",
        "RunValid", "Reset", "Abort"
    ]
    
    def __init__(self, cfg: Dict[str, Any], comm: CommClient, rest: RestClient):
        """
        Constructor: Initializes hardware, loads calibration data, and sets state to IDLE.
        
        Args:
            cfg: Configuration dict (includes MQTT topics and hardware flags)
            comm: CommClient instance for MQTT messaging
            rest: RestClient instance for REST API communication
            
        Raises:
            ConnectionError: If MQTT connection or REST health check fails
            RuntimeError: If hardware initialization fails
        """
        self.cfg = cfg
        self.comm = comm
        self.rest = rest
        self.state = State.BOOT
        self.history = ["BOOT"]
        self.fsm_log = []
        
        # Hardware capability flags
        self.has_sensor = False
        self.has_actuator = False
        
        # Experiment management
        self.experiment_data = []
        self.bias_table = {}
        self.experiment_spec = None
        self.current_experiment_index = 0
        self.cmd = None
        
        # Logging setup
        self.fsm_tag = f"[FSM:{self.comm.client_id}]"
        
        # Cache capability flags locally (if provided)
        if "hardware" in cfg:
            hw = cfg["hardware"]
            self.has_sensor = hw.get("hasSensor", False)
            self.has_actuator = hw.get("hasActuator", False)
        
        # Load calibration gains if available
        try:
            local_gain_path = os.path.join(os.getcwd(), "calibrationGains.pkl")
            if os.path.exists(local_gain_path):
                with open(local_gain_path, 'rb') as f:
                    self.bias_table = pickle.load(f)
                print(f"{self.fsm_tag} Loaded previous calibration gains from: {local_gain_path}")
            else:
                print(f"[WARN] {self.fsm_tag} No previous calibrationGains.pkl found.")
                self.bias_table = {}
        except Exception as e:
            print(f"[WARN] {self.fsm_tag} Failed to load calibration gains: {e}")
            self.bias_table = {}
        
        # Check MQTT connection
        try:
            self.comm.connect()
        except Exception as e:
            raise ConnectionError(f"{self.fsm_tag} Comm Did Not Connect!!!: {e}")
        
        # Check REST server health
        try:
            if not self.rest.check_health():
                raise ConnectionError(f"{self.fsm_tag} REST Server is not online or did not respond to /health.")
        except Exception as e:
            raise ConnectionError(f"{self.fsm_tag} REST Server health check failed: {e}")
        
        # Initialize hardware and transition to IDLE
        self.initialize_hardware(cfg)
        self.transition(State.IDLE)
    
    def handle_command(self, cmd: Union[Dict[str, Any], str]) -> None:
        """
        Main dispatcher for command execution and state transitions.
        
        Args:
            cmd: Dict containing at least a 'cmd' field with supported command name
        """
        # Handle string input by trying to parse as JSON
        if isinstance(cmd, str):
            try:
                cmd = json.loads(cmd)
            except json.JSONDecodeError:
                self.log("ERROR", "Invalid JSON command structure.")
                return
        
        if not isinstance(cmd, dict) or "cmd" not in cmd:
            self.log("ERROR", "Invalid command structure.")
            return
        
        cmd_name = cmd["cmd"]
        if cmd_name not in self.VALID_COMMANDS:
            self.log("ERROR", f"Unknown command: {cmd_name}")
            return
        
        try:
            self.cmd = cmd
            
            if cmd_name == "Calibrate":
                self.transition(State.CALIBRATING)
                
            elif cmd_name == "Test":
                if "params" in cmd and "target" in cmd["params"]:
                    if cmd["params"]["target"] == "sensor":
                        self.transition(State.TESTINGSENSOR)
                    else:
                        self.experiment_spec = cmd
                        self.transition(State.CONFIGUREVALIDATE)
                else:
                    self.log("ERROR", "Missing 'target' in Test command.")
                    self.transition(State.ERROR)
                    
            elif cmd_name == "Run":
                self.experiment_spec = cmd
                self.transition(State.CONFIGUREVALIDATE)
                
            elif cmd_name == "TestValid":
                self.transition(State.TESTINGACTUATOR)
                
            elif cmd_name == "RunValid":
                if self.state != State.CONFIGUREPENDING:
                    print(f"[WARN] {self.fsm_tag} Invalid RunValid from state: {self.state}")
                    self.log("WARN", f"Invalid RunValid from state: {self.state}")
                    self.transition(State.ERROR)
                    return
                self.transition(State.RUNNING)
                
            elif cmd_name == "Reset":
                self.transition(State.IDLE)
                
            elif cmd_name == "Abort":
                self.abort("User request via command.")
                
        except Exception as e:
            error_msg = (f"Command handler error:\n"
                        f"  → message: {str(e)}\n"
                        f"  → cmd: {cmd_name}\n"
                        f"  → stack:\n{traceback.format_exc()}")
            self.log("ERROR", error_msg)
            self.transition(State.ERROR)
    
    def abort(self, reason: str) -> None:
        """
        Handles user-initiated aborts by publishing error state.
        
        Args:
            reason: Description for the abort cause
        """
        print(f"[ABORT] {self.fsm_tag}: {reason}")
        abort_msg = {
            "state": "ABORT",
            "reason": reason,
            "timestamp": datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
        }
        self.comm.comm_publish(self.comm.get_full_topic("status"), json.dumps(abort_msg))
        try:
            self.stop_hardware()
        except Exception:
            pass
        self.transition(State.ERROR)
    
    def get_state(self) -> str:
        """
        Returns current FSM state as string.
        
        Returns:
            Current state name
        """
        return self.state.name
    
    def get_bias_table(self) -> Dict[str, Any]:
        """
        Returns current sensor bias table.
        
        Returns:
            Dict of sensor biases
        """
        return self.bias_table
    
    def log(self, level: str = "INFO", msg: str = "") -> None:
        """
        Unified logging method for nodes.
        Sends to CommClient's /log topic and stores in message log buffer.
        
        Args:
            level: Log level (INFO, WARN, ERROR, DEBUG)
            msg: Log message content
        """
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')
        log_msg = {
            "level": level,
            "msg": msg,
            "timestamp": timestamp
        }
        
        try:
            json_msg = json.dumps(log_msg)
            self.comm.comm_publish(self.comm.get_full_topic("log"), json_msg)
            self.fsm_log.append(json_msg)
        except Exception as e:
            print(f"[WARN] {self.fsm_tag} Log publish failed: {msg} {e}")
    
    def on_message_callback(self, topic: str, msg: Union[str, Dict[str, Any]]) -> None:
        """
        Generic MQTT message handler for FSM-based nodes.
        Supports command messages from any subscribed topic.
        
        Nodes can override this for custom topic handling (e.g., wave data).
        
        Args:
            topic: MQTT topic that received the message
            msg: Message payload (string or decoded dict)
        """
        # Decode JSON payload if needed
        try:
            if isinstance(msg, str):
                msg = json.loads(msg)
        except json.JSONDecodeError as e:
            print(f"[WARN] {self.fsm_tag} [msgCallback] JSON decode failed from topic '{topic}': {e}")
            self.log("WARN", f"JSON decode error from topic '{topic}': {e}")
            return
        
        # Route valid commands
        if isinstance(msg, dict) and "cmd" in msg:
            print(f"{self.fsm_tag} [msgCallback] Dispatching command '{msg['cmd']}' from topic '{topic}'")
            self.handle_command(msg)
        else:
            self.log("WARN", f"Malformed /cmd message from topic '{topic}' (missing 'cmd').")
            print(f"{self.fsm_tag} [msgCallback] Ignored non-command message from topic: {topic}")
    
    def shutdown(self) -> None:
        """
        Unified shutdown routine for all node types.
        Stores MQTT logs, FSM history, and disconnects client.
        """
        # Step 1: Call user-defined hardware shutdown
        self.shutdown_hardware()
        
        # Step 2: Create per-node log folder
        log_dir = f"{self.cfg['clientID']}Logs"
        if not os.path.exists(log_dir):
            os.makedirs(log_dir)
        
        # Step 3: Save CommClient MQTT message log
        log_path = os.path.join(log_dir, f"{self.cfg['clientID']}_commLog.jsonl")
        if hasattr(self.comm, 'message_log') and self.comm.message_log:
            try:
                with open(log_path, 'w') as f:
                    for msg in self.comm.message_log:
                        f.write(json.dumps(msg) + '\n')
                self.log("INFO", "CommClient message log saved.")
            except Exception as e:
                print(f"[WARN] {self.fsm_tag} [SHUTDOWN] Failed to save CommClient log: {e}")
        else:
            self.log("INFO", "No CommClient message log to save.")
        
        # Step 4: Gracefully disconnect CommClient
        self.comm.disconnect()
        self.log("INFO", "CommClient disconnected.")
        
        # Step 5: Save FSM state transition history
        history_path = os.path.join(log_dir, f"{self.cfg['clientID']}_fsmHistory.log")
        try:
            with open(history_path, 'w') as f:
                for state in self.history:
                    f.write(f"{state}\n")
            self.log("INFO", f"FSM history saved to {history_path}")
        except Exception as e:
            print(f"[WARN] {self.fsm_tag} [SHUTDOWN] Failed to write FSM history: {e}")
        
        # Step 6: Save FSM log
        fsm_log_path = os.path.join(log_dir, f"{self.cfg['clientID']}_fsmLog.jsonl")
        if self.fsm_log:
            try:
                with open(fsm_log_path, 'w') as f:
                    for log_entry in self.fsm_log:
                        f.write(log_entry + '\n')
                self.log("INFO", "FSM message log saved.")
            except Exception as e:
                print(f"[WARN] {self.fsm_tag} [SHUTDOWN] Failed to save FSM log: {e}")
        else:
            self.log("INFO", "No FSM message log to save.")
        
        print(f"{self.fsm_tag} [SHUTDOWN] Node shutdown complete.")
    
    def setup_current_experiment(self) -> None:
        """
        Prepares the current experiment parameters.
        This method should be called after configure_hardware() to set up
        the current experiment's parameters and precompute any necessary data.
        
        Can be overridden by subclasses to implement specific setup logic.
        """
        if ("experiments" in self.experiment_spec.get("params", {}) and 
            self.experiment_spec["params"]["experiments"]):
            # Multi-experiment mode
            current_params = self.experiment_spec["params"]["experiments"][self.current_experiment_index]
            total_experiments = len(self.experiment_spec["params"]["experiments"])
            
            # Logging for multi-experiment context
            if "name" in current_params:
                self.log("INFO", f"Setting up experiment {self.current_experiment_index + 1}/{total_experiments}: '{current_params['name']}'")
            else:
                self.log("INFO", f"Setting up experiment {self.current_experiment_index + 1}/{total_experiments} (unnamed)")
            
            self.log("INFO", f"Experiment {self.current_experiment_index + 1} parameters: {json.dumps(current_params)}")
        else:
            # Single experiment mode
            current_params = self.experiment_spec.get("params", {})
            
            if "name" in current_params:
                self.log("INFO", f"Setting up single experiment: '{current_params['name']}'")
            else:
                self.log("INFO", "Setting up single experiment (unnamed)")
            
            self.log("INFO", f"Experiment parameters: {json.dumps(current_params)}")
    
    # Protected State Machine Core
    def transition(self, new_state: State) -> None:
        """
        Handles state transitions, verifies legality before switching.
        
        Args:
            new_state: Target state to transition to
        """
        if not self._is_valid_transition(self.state, new_state):
            print(f"[WARN] {self.fsm_tag} Invalid transition: {self.state.name} → {new_state.name}")
            self.transition(State.ERROR)
            return
        
        prev = self.state
        self._exit_state(prev)
        self.state = new_state
        self.history.append(new_state.name)
        print(f"{self.fsm_tag} [STATE] {prev.name} → {new_state.name}")
        try:
            self._enter_state(new_state)
        except RuntimeError as e:
            self.log("ERROR", f"State entry failed: {e}")
            self.transition(State.ERROR)
    
    def _is_valid_transition(self, from_state: State, to_state: State) -> bool:
        """
        Determines if a transition is allowed between two FSM states.
        
        Args:
            from_state: Current state
            to_state: Desired state
            
        Returns:
            True if transition is allowed
        """
        valid_transitions = {
            State.BOOT: [State.IDLE],
            State.IDLE: [State.CALIBRATING, State.TESTINGSENSOR, State.CONFIGUREVALIDATE],
            State.CALIBRATING: [State.CALIBRATING],
            State.TESTINGSENSOR: [State.IDLE],
            State.CONFIGUREVALIDATE: [State.CONFIGUREPENDING, State.IDLE],
            State.CONFIGUREPENDING: [State.TESTINGACTUATOR, State.RUNNING],
            State.TESTINGACTUATOR: [State.IDLE],
            State.RUNNING: [State.POSTPROC],
            State.POSTPROC: [State.DONE, State.RUNNING],
            State.DONE: [State.IDLE],
            State.ERROR: [State.IDLE]
        }
        
        allowed_states = valid_transitions.get(from_state, [])
        # Always allow transitions to IDLE and ERROR from any state
        allowed_states.extend([State.IDLE, State.ERROR])
        
        return to_state in allowed_states
    
    def _enter_state(self, state: State) -> None:
        """
        Logic executed upon entering a new state.
        
        Args:
            state: New state being entered
        """
        print(f"{self.fsm_tag} [ENTER STATE] {state.name}")
        status_msg = {
            "state": state.name,
            "timestamp": datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')
        }
        self.comm.comm_publish(self.comm.get_full_topic("status"), json.dumps(status_msg))
        
        # Dictionary dispatch for state entry handlers
        state_handlers = {
            State.IDLE: self._enter_idle,
            State.CALIBRATING: self._enter_calibrating,
            State.TESTINGSENSOR: self._enter_testing_sensor,
            State.CONFIGUREVALIDATE: self._enter_configure_validate,
            State.CONFIGUREPENDING: self._enter_configure_pending,
            State.TESTINGACTUATOR: self._enter_testing_actuator,
            State.RUNNING: self._enter_running,
            State.POSTPROC: self._enter_post_proc,
            State.DONE: self._enter_done,
            State.ERROR: self._enter_error,
        }
        
        handler = state_handlers.get(state)
        if handler:
            handler()
        else:
            print(f"[WARN] {self.fsm_tag} No handler for state: {state.name}")
    
    def _exit_state(self, state: State) -> None:
        """
        Logic executed before leaving a state.
        
        Args:
            state: Old state being exited
        """
        if state == State.RUNNING:
            self._exit_running()
        elif state == State.CALIBRATING:
            self._exit_calibrating()
        elif state == State.TESTINGSENSOR:
            self._exit_testing_sensor()
        
        print(f"{self.fsm_tag} [EXIT STATE] {state.name}")
    
    # Individual State Entry/Exit Implementations
    def _enter_idle(self) -> None:
        """Called on entry into the IDLE state"""
        self.stop_hardware()
    
    def _enter_calibrating(self) -> None:
        """Called when entering CALIBRATING state"""
        if not self.has_sensor:
            raise RuntimeError(f"{self.fsm_tag} Cannot calibrate: node lacks sensor capability.")
        print(f"{self.fsm_tag} [CALIBRATION] Starting sensor calibration.")
        self.handle_calibrate(self.cmd)
    
    def _enter_testing_sensor(self) -> None:
        """Called when entering TESTINGSENSOR state"""
        if not self.has_sensor:
            raise RuntimeError(f"{self.fsm_tag} Cannot test sensor: node lacks sensor capability.")
        print(f"{self.fsm_tag} [TEST] Live sensor diagnostics.")
        self.handle_test(self.cmd)
    
    def _enter_testing_actuator(self) -> None:
        """Called when entering TESTINGACTUATOR state"""
        if not self.has_actuator:
            raise RuntimeError(f"{self.fsm_tag} Cannot test actuator: node lacks actuator capability.")
        print(f"{self.fsm_tag} [TEST] Actuator validation.")
        self.handle_test(self.cmd)
    
    def _enter_configure_validate(self) -> None:
        """Called on CONFIGUREVALIDATE; verifies parameters and proceeds"""
        # Check if multi-experiment mode
        if ("experiments" in self.experiment_spec.get("params", {}) and 
            self.experiment_spec["params"]["experiments"]):
            experiments = self.experiment_spec["params"]["experiments"]
            # Validate all experiments before setup
            for i, experiment in enumerate(experiments):
                is_valid = self.configure_hardware(experiment)
                if not is_valid:
                    self.log("WARN", f"Invalid experiment parameters in experiment {i + 1}.")
                    self.transition(State.IDLE)
                    return
            # All experiments are valid, proceed to setup first experiment
            self.current_experiment_index = 0
            try:
                self.setup_current_experiment()
                self.transition(State.CONFIGUREPENDING)
            except Exception as e:
                self.log("ERROR", f"Multi-experiment setup failed: {e}")
                self.transition(State.IDLE)
        else:
            # Single experiment mode
            is_valid = self.configure_hardware(self.experiment_spec.get("params", {}))
            if is_valid:
                self.current_experiment_index = 0
                try:
                    self.setup_current_experiment()
                    self.transition(State.CONFIGUREPENDING)
                except Exception as e:
                    self.log("ERROR", f"Single experiment setup failed: {e}")
                    self.transition(State.IDLE)
            else:
                self.log("WARN", "Invalid configuration parameters.")
                self.transition(State.IDLE)
    
    def _enter_configure_pending(self) -> None:
        """Called when entering CONFIGUREPENDING"""
        print(f"{self.fsm_tag} [CONFIGURE] Awaiting user confirmation.")
    
    def _enter_running(self) -> None:
        """Called when entering RUNNING state"""
        print(f"{self.fsm_tag} [RUNNING] Executing experiment.")
        self.handle_run(self.cmd)
    
    def _enter_post_proc(self) -> None:
        """
        Handles default post-processing behavior for a node.
        
        This function collects experiment data after an experiment run. If data
        exists in experiment_data, it attempts to store it as a CSV (if homogeneous),
        otherwise falls back to newline-delimited JSON (JSONL). The saved file is tagged
        using the experiment name (if available) or a timestamp to prevent overwrites.
        
        This method can be overridden by subclasses to implement node-specific
        post-processing workflows.
        """
        print(f"{self.fsm_tag} [POSTPROC] Processing experiment data.")
        
        if self.experiment_data:
            # Always use clientID for base directory
            base_dir = f"{self.cfg['clientID']}Data"
            
            if ("experiments" in self.experiment_spec.get("params", {}) and 
                self.experiment_spec["params"]["experiments"]):
                # Multi-experiment: create subfolder within clientIDData
                if "name" in self.experiment_spec.get("params", {}):
                    sub_folder_name = self._make_valid_name(self.experiment_spec["params"]["name"])
                else:
                    sub_folder_name = f"MultiExperiment_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
                out_dir = os.path.join(base_dir, sub_folder_name)
                
                # Get current experiment name for file tag
                tag = self._get_experiment_tag()
            else:
                # Single experiment: use base directory directly
                out_dir = base_dir
                tag = self._get_experiment_tag()
            
            if not os.path.exists(out_dir):
                os.makedirs(out_dir)
            
            tag = self._make_valid_name(tag)
            
            # Save current experiment data
            try:
                df = pd.DataFrame(self.experiment_data)
                csv_path = os.path.join(out_dir, f"{self.cfg['clientID']}_data_{tag}.csv")
                df.to_csv(csv_path, index=False)
                self.log("INFO", f"Experiment data saved to CSV: {csv_path}")
            except Exception as e:
                # Fallback: save as JSONL
                jsonl_path = os.path.join(out_dir, f"{self.cfg['clientID']}_data_{tag}.jsonl")
                try:
                    with open(jsonl_path, 'w') as f:
                        for item in self.experiment_data:
                            f.write(json.dumps(item) + '\n')
                    self.log("INFO", f"Experiment data saved as JSONL: {jsonl_path}")
                except Exception as inner_e:
                    self.log("ERROR", f"Failed to save experiment data: {inner_e}")
        
        # Check if more experiments remain
        if ("experiments" in self.experiment_spec.get("params", {}) and 
            self.current_experiment_index < len(self.experiment_spec["params"]["experiments"]) - 1):
            # Multi-experiment mode: setup next experiment
            try:
                tag = self._get_experiment_tag()
                self._send_exp_data(self.experiment_data, tag)  # Send data to REST server
                self.current_experiment_index += 1
                self.setup_current_experiment()
                self.transition(State.RUNNING)
            except Exception as e:
                self.log("ERROR", f"Setup for next experiment failed: {e}")
                self.transition(State.ERROR)
        else:
            # All experiments complete
            self.transition(State.DONE)
    
    def _enter_done(self) -> None:
        """Wraps up after experiment completes"""
        print(f"{self.fsm_tag} [DONE] Experiment complete.")
        
        # Send experiment data to REST server
        tag = self._get_experiment_tag()
        self._send_exp_data(self.experiment_data, tag)
        
        self.transition(State.IDLE)
    
    def _send_exp_data(self, experiment_data: List[Dict[str, Any]], tag: str = None) -> None:
        """
        Helper function to send experiment data to REST server.
        
        Args:
            experiment_data: List of experiment data records
            tag: Optional tag for the experiment (default: timestamp)
        """
        if not experiment_data:
            self.log("INFO", "No experiment data to send to REST server.")
            return
        
        # Handle optional tag parameter
        if not tag:
            tag = datetime.now().strftime('%Y%m%d_%H%M%S')
        
        tag = self._make_valid_name(tag)
        
        try:
            # Send data to REST server
            resp = self.rest.send_data(experiment_data, experiment_name=tag)
            if isinstance(resp, dict) and resp.get("status") == "error":
                self.log("ERROR", f"REST POST failed: {resp.get('message', 'Unknown error')}")
            else:
                self.log("INFO", f"Experiment data sent to REST server: {tag}")
        except Exception as e:
            self.log("ERROR", f"REST POST exception: {e}")
    
    def _get_experiment_tag(self) -> str:
        """
        Helper function to determine experiment tag for file naming and REST API.
        
        Returns:
            Experiment name or timestamp fallback
        """
        if ("experiments" in self.experiment_spec.get("params", {}) and 
            self.experiment_spec["params"]["experiments"]):
            # Multi-experiment mode: use current experiment name
            current_params = self.experiment_spec["params"]["experiments"][self.current_experiment_index]
            if "name" in current_params:
                tag = current_params["name"]
            else:
                if "name" in self.experiment_spec.get("params", {}):
                    tag = f"{self.experiment_spec['params']['name']}_{self.current_experiment_index + 1}"
                else:
                    tag = f"experiment_{self.current_experiment_index + 1}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        else:
            # Single experiment mode: use overall experiment name
            if "name" in self.experiment_spec.get("params", {}):
                tag = self.experiment_spec["params"]["name"]
            else:
                tag = datetime.now().strftime('%Y%m%d_%H%M%S')
        
        return self._make_valid_name(tag)
    
    def _make_valid_name(self, name: str) -> str:
        """
        Convert a string to a valid filename by replacing invalid characters.
        
        Args:
            name: Input name string
            
        Returns:
            Valid filename string
        """
        # Replace invalid filename characters with underscores
        return re.sub(r'[<>:"/\\|?*]', '_', str(name))
    
    def _enter_error(self) -> None:
        """Failsafe entry into ERROR state"""
        print(f"{self.fsm_tag} [ERROR] System faulted.")
    
    def _exit_calibrating(self) -> None:
        """Cleanup before leaving CALIBRATING"""
        print(f"{self.fsm_tag} [EXIT] Calibration complete.")
    
    def _exit_testing_sensor(self) -> None:
        """Cleanup before leaving TESTINGSENSOR"""
        print(f"{self.fsm_tag} [EXIT] Stopping sensor diagnostics.")
        self.stop_hardware()
    
    def _exit_running(self) -> None:
        """Cleanup before leaving RUNNING state"""
        self.stop_hardware()
    
    # Abstract Interfaces (to be implemented by subclasses)
    @abstractmethod
    def initialize_hardware(self, cfg: Dict[str, Any]) -> None:
        """Initialize node-specific hardware using the passed config."""
        pass
    
    @abstractmethod
    def handle_calibrate(self, cmd: Dict[str, Any]) -> None:
        """Handle sensor calibration logic when in the CALIBRATING state."""
        pass
    
    @abstractmethod
    def handle_test(self, cmd: Dict[str, Any]) -> None:
        """Execute testing logic for sensors or actuators, depending on command."""
        pass
    
    @abstractmethod
    def handle_run(self, cmd: Dict[str, Any]) -> None:
        """Begin the main experiment routine using configuration parameters."""
        pass
    
    @abstractmethod
    def configure_hardware(self, params: Dict[str, Any]) -> bool:
        """
        Validate and apply experiment configuration.
        
        Args:
            params: Experiment parameters to validate
            
        Returns:
            True if configuration is valid and applied successfully
        """
        pass
    
    @abstractmethod
    def stop_hardware(self) -> None:
        """Called during state exits to halt actuators or terminate readings."""
        pass
    
    @abstractmethod
    def shutdown_hardware(self) -> None:
        """Called only on full shutdown or object deletion (optional cleanup)."""
        pass
