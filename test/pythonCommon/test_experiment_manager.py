"""
test_experiment_manager.py

Standalone pytest for ExperimentManager state machine.
Includes mock test node implementation and comprehensive FSM testing.

This test verifies:
- State transitions and FSM logic
- Command handling and validation
- Hardware capability gating
- Multi-step calibration workflow
- Error handling and recovery
- Configuration validation
"""

import json
import os
import sys
import tempfile
from typing import Dict, Any
from unittest.mock import Mock, MagicMock

import pytest

# Add the parent directory to sys.path to import our modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))

from pythonCommon.ExperimentManager import ExperimentManager, State


class MockNodeManager(ExperimentManager):
    """
    Mock implementation of ExperimentManager for testing FSM.
    No hardware logic, just print statements to verify state flow.
    """
    
    def __init__(self, cfg: Dict[str, Any], comm, rest):
        self.height_log = []  # For calibration testing
        super().__init__(cfg, comm, rest)
    
    def initialize_hardware(self, cfg: Dict[str, Any]) -> None:
        """Mock hardware initialization"""
        print("[INIT] Mock hardware initialized.")
        print(f"[DEBUG] bias_table: {self.bias_table}")
    
    def handle_calibrate(self, cmd: Dict[str, Any]) -> None:
        """
        Simulates calibration behavior by capturing reference points
        and computing a simple bias offset added to each sensor.
        """
        print(f"[ACTION] handle_calibrate() called with: {cmd}")
        
        # Handle multi-step calibration
        if cmd.get("params", {}).get("finished") is True:
            if not self.height_log:
                print("[WARN] [CALIBRATION] No data to finalize calibration.")
                # Still clear state and return to IDLE without applying any changes
                self.transition(State.IDLE)
                self.height_log = []  # Reset log
                return
            
            avg_height = sum(self.height_log) / len(self.height_log)
            print(f"[CALIBRATION] Applying bias offset of {avg_height:.3f}")
            
            # Update bias_table
            for key in self.bias_table:
                self.bias_table[key] = self.bias_table[key] + avg_height
            
            # Save gains (mock)
            print("[CALIBRATION] Gains saved to calibrationGains.pkl")
            
            # Clear log
            self.height_log = []
            self.transition(State.IDLE)
            return
        
        # Handle a step
        if "height" in cmd.get("params", {}):
            height = cmd["params"]["height"]
            self.height_log.append(height)
            print(f"[CALIBRATION] Captured height = {height:.3f}")
        else:
            raise ValueError("[CALIBRATION] Invalid parameters: expected 'height' or 'finished' in cmd.params.")
    
    def handle_test(self, cmd: Dict[str, Any]) -> None:
        """Mock test handler"""
        print(f"[ACTION] handle_test() called with: {cmd}")
    
    def handle_run(self, cmd: Dict[str, Any]) -> None:
        """Mock run handler that simulates experiment finishing"""
        print(f"[ACTION] handle_run() called with: {cmd}")
        
        # Simulate experiment finishing → transition to POSTPROC
        self.transition(State.POSTPROC)
    
    def configure_hardware(self, params: Dict[str, Any]) -> bool:
        """Mock hardware configuration validation"""
        print(f"[ACTION] configure_hardware() validating: {params}")
        
        has_amp = ("amplitude" in params and 
                  isinstance(params["amplitude"], (int, float)) and 
                  params["amplitude"] > 0)
        has_wave = ("waveType" in params and 
                   isinstance(params["waveType"], str))
        
        is_valid = has_amp and has_wave
        print(f"[VALIDATION] Result: {is_valid} (amp={has_amp}, wave={has_wave})")
        return is_valid
    
    def stop_hardware(self) -> None:
        """Mock hardware stop"""
        print("[STOP] Hardware stopped safely / IDLE.")
    
    def shutdown_hardware(self) -> None:
        """Mock hardware shutdown"""
        print("[SHUTDOWN] Hardware shutdown safely.")


class TestExperimentManager:
    """Test suite for ExperimentManager FSM functionality"""
    
    @pytest.fixture
    def setup_manager(self):
        """Setup test manager with mock communication clients"""
        # Mock configuration
        cfg = {
            'clientID': 'TestNode',
            'hardware': {
                'hasSensor': True,
                'hasActuator': True
            }
        }
        
        # Mock CommClient
        mock_comm = Mock()
        mock_comm.client_id = cfg['clientID']
        mock_comm.connect = Mock()
        mock_comm.disconnect = Mock()
        mock_comm.comm_publish = Mock()
        mock_comm.get_full_topic = Mock(side_effect=lambda suffix: f"TestNode/{suffix}")
        mock_comm.message_log = []
        
        # Mock RestClient
        mock_rest = Mock()
        mock_rest.check_health = Mock(return_value=True)
        mock_rest.send_data = Mock(return_value={"status": "success"})
        
        # Create test manager
        with tempfile.TemporaryDirectory() as temp_dir:
            original_cwd = os.getcwd()
            os.chdir(temp_dir)
            try:
                mgr = MockNodeManager(cfg, mock_comm, mock_rest)
                yield mgr, mock_comm, mock_rest
            finally:
                os.chdir(original_cwd)
    
    def run_test_case(self, mgr, cmd_struct, expected_state, title=""):
        """Helper to run a test case and verify state"""
        print(f"\n=== TEST: {title} ===")
        try:
            mgr.handle_command(cmd_struct)
        except Exception as e:
            print(f"❌ Exception caught during '{title}': {e}")
            raise
        
        current_state = mgr.get_state()
        print(f"[ASSERT] Current state: {current_state}")
        assert current_state == expected_state, f"Expected {expected_state}, got {current_state}"
        print(f"✅ Passed: {title}")
        return current_state
    
    def test_calibration_workflow(self, setup_manager):
        """Test multi-step calibration process"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test calibration with 2 steps
        self.run_test_case(mgr, 
            {"cmd": "Calibrate", "params": {"height": 0.1}}, 
            "CALIBRATING", "Calibrate Step 1")
        
        self.run_test_case(mgr,
            {"cmd": "Calibrate", "params": {"height": 0.3}}, 
            "CALIBRATING", "Calibrate Step 2")
        
        self.run_test_case(mgr,
            {"cmd": "Calibrate", "params": {"finished": True}}, 
            "IDLE", "Calibrate Finish")
    
    def test_sensor_diagnostics(self, setup_manager):
        """Test sensor testing workflow"""
        mgr, mock_comm, mock_rest = setup_manager
        
        self.run_test_case(mgr,
            {"cmd": "Test", "params": {"target": "sensor"}}, 
            "TESTINGSENSOR", "Sensor Test")
        
        self.run_test_case(mgr,
            {"cmd": "Reset"}, 
            "IDLE", "Reset after sensor test")
    
    def test_actuator_testing(self, setup_manager):
        """Test actuator testing workflow"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Configure for actuator test
        self.run_test_case(mgr,
            {"cmd": "Run", "params": {"waveType": "sin", "amplitude": 0.05}}, 
            "CONFIGUREPENDING", "Run Configure for actuator test")
        
        self.run_test_case(mgr,
            {"cmd": "TestValid"}, 
            "TESTINGACTUATOR", "Test Actuator")
        
        self.run_test_case(mgr,
            {"cmd": "Reset"}, 
            "IDLE", "Reset after actuator test")
    
    def test_full_experiment_run(self, setup_manager):
        """Test complete experiment execution"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Configure experiment
        self.run_test_case(mgr,
            {"cmd": "Run", "params": {"waveType": "sin", "amplitude": 0.1}}, 
            "CONFIGUREPENDING", "Run Validate")
        
        # Execute experiment
        self.run_test_case(mgr,
            {"cmd": "RunValid"}, 
            "IDLE", "RunValid executes (should go through RUNNING->POSTPROC->DONE->IDLE)")
    
    def test_error_handling(self, setup_manager):
        """Test error conditions and recovery"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test malformed calibration command - should transition to ERROR, not raise
        mgr.handle_command({"cmd": "Calibrate", "params": {"unknownField": 123}})
        
        # Should be in ERROR state after exception
        assert mgr.get_state() == "ERROR"
        
        # Test recovery from error
        self.run_test_case(mgr,
            {"cmd": "Reset"}, 
            "IDLE", "Reset from error")
    
    def test_abort_functionality(self, setup_manager):
        """Test abort command from active states"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Start calibration
        self.run_test_case(mgr,
            {"cmd": "Calibrate", "params": {"height": 0.1}}, 
            "CALIBRATING", "Start Calibrating for abort test")
        
        # Abort
        self.run_test_case(mgr,
            {"cmd": "Abort"}, 
            "ERROR", "Abort from calibrating")
        
        # Reset
        self.run_test_case(mgr,
            {"cmd": "Reset"}, 
            "IDLE", "Reset from error after abort")
    
    def test_invalid_state_transitions(self, setup_manager):
        """Test invalid command sequences"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test RunValid from wrong state
        self.run_test_case(mgr,
            {"cmd": "RunValid"}, 
            "ERROR", "Invalid RunValid from IDLE")
        
        self.run_test_case(mgr,
            {"cmd": "Reset"}, 
            "IDLE", "Reset from error (Invalid cmd)")
    
    def test_invalid_configuration(self, setup_manager):
        """Test configuration validation"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test invalid parameters (missing waveType)
        self.run_test_case(mgr,
            {"cmd": "Run", "params": {"amplitude": -1}}, 
            "IDLE", "Invalid Run parameters")
    
    def test_repeated_reset(self, setup_manager):
        """Test that reset works from IDLE state"""
        mgr, mock_comm, mock_rest = setup_manager
        
        self.run_test_case(mgr,
            {"cmd": "Reset"}, 
            "IDLE", "Reset from IDLE (should remain IDLE)")
    
    def test_command_validation(self, setup_manager):
        """Test command structure validation"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test invalid command structure
        mgr.handle_command({"invalid": "structure"})
        # Should log error but not change state
        assert mgr.get_state() == "IDLE"
        
        # Test unknown command
        mgr.handle_command({"cmd": "UnknownCommand"})
        # Should log error but not change state
        assert mgr.get_state() == "IDLE"
        
        # Test JSON string command
        mgr.handle_command('{"cmd": "Reset"}')
        assert mgr.get_state() == "IDLE"
        
        # Test invalid JSON string
        mgr.handle_command('invalid json')
        # Should log error but not change state
        assert mgr.get_state() == "IDLE"
    
    def test_hardware_capability_gating(self, setup_manager):
        """Test that hardware capabilities are properly checked"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test with sensor capability disabled
        mgr.has_sensor = False
        
        # Should transition to ERROR state, not raise exception
        mgr.handle_command({"cmd": "Calibrate", "params": {"height": 0.1}})
        assert mgr.get_state() == "ERROR"
        
        # Reset capability and state for other tests
        mgr.has_sensor = True
        mgr.transition(State.IDLE)  # Reset state after error
        
        # Test with actuator capability disabled
        mgr.has_actuator = False
        
        # Configure first
        mgr.handle_command({"cmd": "Run", "params": {"waveType": "sin", "amplitude": 0.1}})
        assert mgr.get_state() == "CONFIGUREPENDING"
        
        # Should transition to ERROR state, not raise exception
        mgr.handle_command({"cmd": "TestValid"})
        assert mgr.get_state() == "ERROR"
    
    def test_state_history_tracking(self, setup_manager):
        """Test that state history is properly tracked"""
        mgr, mock_comm, mock_rest = setup_manager
        
        initial_history_length = len(mgr.history)
        
        # Perform some state transitions
        mgr.handle_command({"cmd": "Calibrate", "params": {"height": 0.1}})
        mgr.handle_command({"cmd": "Reset"})
        
        # Check that history was updated
        assert len(mgr.history) > initial_history_length
        assert "CALIBRATING" in mgr.history
        assert "IDLE" in mgr.history
    
    def test_logging_functionality(self, setup_manager):
        """Test logging and FSM log functionality"""
        mgr, mock_comm, mock_rest = setup_manager
        
        initial_log_length = len(mgr.fsm_log)
        
        # Generate some log entries
        mgr.log("INFO", "Test message")
        mgr.log("WARN", "Test warning")
        
        # Check that logs were added
        assert len(mgr.fsm_log) > initial_log_length
        
        # Check that MQTT publish was called
        assert mock_comm.comm_publish.called
    
    def test_experiment_data_handling(self, setup_manager):
        """Test experiment data management"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Add some mock experiment data
        mgr.experiment_data = [
            {"time": 1.0, "value": 10.5},
            {"time": 2.0, "value": 11.2}
        ]
        
        # Test data sending functionality
        mgr._send_exp_data(mgr.experiment_data, "test_experiment")
        
        # Check that REST client was called
        mock_rest.send_data.assert_called_once()
    
    def test_message_callback_routing(self, setup_manager):
        """Test MQTT message callback routing"""
        mgr, mock_comm, mock_rest = setup_manager
        
        # Test valid command message
        test_msg = {"cmd": "Reset"}
        mgr.on_message_callback("TestNode/cmd", test_msg)
        assert mgr.get_state() == "IDLE"
        
        # Test JSON string message
        mgr.on_message_callback("TestNode/cmd", '{"cmd": "Reset"}')
        assert mgr.get_state() == "IDLE"
        
        # Test invalid JSON
        mgr.on_message_callback("TestNode/cmd", "invalid json")
        # Should not crash, just log error
        
        # Test non-command message
        mgr.on_message_callback("TestNode/data", {"data": "not a command"})
        # Should not crash, just ignore


if __name__ == "__main__":
    # Run tests directly if script is executed
    pytest.main([__file__, "-v"])
