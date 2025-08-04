% NodeManagerTestScript.m
% Local test harness for ExperimentManager FSM using TestNodeManager
% No MQTT required; simulates commands and prints transitions and assertions

clear; clc;
addpath(genpath(fullfile(fileparts(mfilename('fullpath')), '..', 'matlabCommon')));

% --- Setup Configuration (mock)
cfg = struct();
cfg.mqtt.topics.status = "status";
cfg.mqtt.topics.error = "error";
cfg.hardware = struct();
cfg.hardware.hasSensor = true;
cfg.hardware.hasActuator = true;
cfg.clientID = "TestNode";

% --- Create Mock CommClient with no-op publish and Mock RestClient
mockComm = struct();
mockComm.commPublish = @(topic, data) fprintf("[MQTT] %s → %s\n", topic, jsonencode(data));
mockComm.isOpen = true;
mockComm.close = @() disp("[MQTT] Connection closed.");
mockComm.connect = @() disp("[MQTT] Connected");
mockComm.clientID = cfg.clientID;
mockComm.getFullTopic = @(string) sprintf("TestNode/%s", string);


mockRest = struct();
mockRest.checkHealth = @() true;
mockRest.clientID = cfg.clientID;

% --- Instantiate Test Manager
mgr = TestNodeManager(cfg, mockComm, mockRest);

% --- Helpers
function runTestCase(title, cmdStruct, mgr, expectedState)
    fprintf("\n=== TEST: %s ===\n", title);
    try
        mgr.handleCommand(cmdStruct);
    catch ME
        warning("❌ Exception caught during '%s': %s", title, ME.message);
    end
    pause(0.1); % allow state to settle
    currentState = string(mgr.getState());
    fprintf("[ASSERT] Current state: %s\n", currentState);
    if currentState ~= expectedState
        warning("❌ State mismatch! Expected %s, got %s", expectedState, currentState);
    else
        fprintf("✅ Passed: %s\n", title);
    end
end

% --- Test 1: Calibrate with 2 steps
runTestCase("Calibrate Step 1", struct("cmd", "Calibrate", "params", struct("height", 0.1)), mgr, "CALIBRATING");
runTestCase("Calibrate Step 2", struct("cmd", "Calibrate", "params", struct("height", 0.3)), mgr, "CALIBRATING");
runTestCase("Calibrate Finish", struct("cmd", "Calibrate", "params", struct("finished", true)), mgr, "IDLE");

% --- Test 2: Sensor diagnostics
runTestCase("Sensor Test", struct("cmd", "Test", "params", struct("target", "sensor")), mgr, "TESTINGSENSOR");
runTestCase("Reset after sensor test", struct("cmd", "Reset"), mgr, "IDLE");

% --- Test 3: Run configuration and actuator test
runTestCase("Run Configure", struct("cmd", "Run", ...
    "params", struct("waveType", "sin", "amplitude", 0.05)), mgr, "CONFIGUREPENDING");
runTestCase("Test Actuator", struct("cmd", "TestValid"), mgr, "TESTINGACTUATOR");
runTestCase("Reset after actuator test", struct("cmd", "Reset"), mgr, "IDLE");

% --- Test 4: Full experiment run
runTestCase("Run Validate", struct("cmd", "Run", ...
    "params", struct("waveType", "sin", "amplitude", 0.1)), mgr, "CONFIGUREPENDING");
runTestCase("RunValid executes", struct("cmd", "RunValid"), mgr, "IDLE");

% --- Test 5: Force error with malformed calibration
badCmd = struct("cmd", "Calibrate", "params", struct("unknownField", 123));
runTestCase("Malformed Calibration Input", badCmd, mgr, "ERROR");

% --- Test 6: Reset from error
runTestCase("Reset from error", struct("cmd", "Reset"), mgr, "IDLE");

% --- Test 7: Abort from active states
runTestCase("Abort from Calibrating", struct("cmd", "Calibrate", "params", struct("height", 0.1)), mgr, "CALIBRATING");
runTestCase("Abort", struct("cmd", "Abort"), mgr, "ERROR");
runTestCase("Reset from error (Abort)", struct("cmd", "Reset"), mgr, "IDLE");

% --- Test 8: Illegal command in wrong state
runTestCase("Invalid RunValid from IDLE", struct("cmd", "RunValid"), mgr, "ERROR");
runTestCase("Reset from error (Invalid cmd)", struct("cmd", "Reset"), mgr, "IDLE");

% --- Test 9: Repeated Reset
runTestCase("Reset from IDLE again", struct("cmd", "Reset"), mgr, "IDLE");

% --- Test 10: Run with invalid parameters
badParams = struct("cmd", "Run", "params", struct("amplitude", -1)); % missing waveType
runTestCase("Invalid Run parameters", badParams, mgr, "IDLE");

cfgSensorOnly = cfg; cfgSensorOnly.hardware.hasActuator = false;
cfgActuatorOnly = cfg; cfgActuatorOnly.hardware.hasSensor = false;



fprintf("\n=== CLEANUP ===\n");
if mockComm.isOpen
    mockComm.close();
end
disp("✅ All tests complete and connection closed.");