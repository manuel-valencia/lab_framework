% VirtualIntegrationTest.m
% ========================================================================
% Simulated full virtual experiment framework integration on localhost
% Nodes: WaveGenNode, ProbeNode, ControlNode
% ========================================================================

% TEST OBJECTIVES
% This script validates the end-to-end integration of the node architecture
% under a realistic lab-style experiment simulation. All components run in a
% single MATLAB process without hardware, using simulated sensor-actuator logic.
% Nodes communicate via MQTT and Rest Server (make sure both are set up!!!)
% and execute finite-state logic as defined by the ExperimentManager framework.

% Test Outputs:
% - VirtualIntegrationTest.log (diary log)
% - Single and Multi-Experiment Data plots
% - From PPVLog.m using log file:
%       - Figures for FSM state transitions (State Transitions for probenode/wavegenode.jpg)
%       - Communication metrics summary (CommMetrics.txt)

%% ------------------------ TEST SEQUENCE ------------------------------
% 1. Initialization:
%    - Instantiate and initialize: WaveGenNode, ProbeNode, ControlNode
%    - Confirm all nodes are in IDLE
%
% 2. Calibration Phase:
%    - ControlNode sends 2 calibration heights to ProbeNode
%    - Sends finalization command with `finished=true`
%    - ProbeNode stores average bias and returns to IDLE
%
% 3. Probe Sensor Test:
%    - ControlNode triggers `TESTINGSENSOR` state on ProbeNode
%    - ProbeNode returns noisy live data for a short duration
%    - Returns to IDLE once Reset command is received
%
% 4. Wave Generator Actuator Test:
%    - ControlNode sends test actuator command with valid config
%    - WaveGenNode validates config and transitions to CONFIGUREPENDING
%    - Test ends and WaveGenNode returns to IDLE
%
% 5. Full Experiment Run:
%    - ControlNode sends `Run` command to both WaveGenNode and ProbeNode
%    - WaveGenNode simulates sine wave output
%    - ProbeNode captures noisy waveform samples
%    - On completion, all nodes return to IDLE and data is logged
%
% 6. Multi-Experiment Sequence Tests:
%    - Define experimentConfig with 3 sub-experiments (different names, amplitudes, frequencies, durations)
%    - Execute experiments sequentially with proper state management between runs
%    - Validate individual experiment data collection and storage
%    - Nodes combine and aggregate data from all three runs
%    - Verify REST API data upload for each experiment with combined dataset
%
% 7. Abort Tests:
%    - Test abort functionality from control node sending abort message
%    - Test abort functionality from peripheral nodes sending abort cmd
%    - Validate proper state transitions to ERROR and recovery to IDLE
%    - Reset nodes between each test to ensure clean state transitions
%    - Three separate tests: ControlNode abort, WaveGenNode abort, ProbeNode abort
%
% End. Cleanup:
%    - All MQTT clients disconnected
%    - Output data saved (e.g., wave + probe data)

%% Test
%% Section 1: Setup and Common Config

clc; clear;
addpath(genpath(fullfile(fileparts(mfilename('fullpath')), '..', 'matlabCommon')));

% Clear previous diary contents
diaryFile = 'VirtualIntegrationTest.log';
fid = fopen(diaryFile, 'w');  % Open in write mode (truncates file)
if fid ~= -1
    fclose(fid);  % Immediately close
end

% Start logging all console output to file
diary(diaryFile);
logCleanup = onCleanup(@() diary('off'));

% Simulation Parameters
stepDt = 0.01;

% MQTT Mock Configuration (localhost)
brokerAddress = 'localhost';
brokerPort = 1883;

% Node IDs
waveGenID = 'waveGenNode';
probeID = 'probeNode';
controlID = 'controlNode';

% Shared Topics (per architecture spec)
topics = @(id) struct( ...
    'cmd',    sprintf('%s/cmd', id), ...
    'status', sprintf('%s/status', id), ...
    'data',   sprintf('%s/data', id), ...
    'log',    sprintf('%s/log', id));

% Node Capabilities and Subscriptions
% ------------------------------------
% Describes each node's role and MQTT topics of interest

nodeDefs = struct();

% Wave Generator Node
nodeDefs.waveGenNode.role = 'actuator';
nodeDefs.waveGenNode.publishes = {
    topics(waveGenID).status, ...
    topics(waveGenID).data, ...
    topics(waveGenID).log
};
nodeDefs.waveGenNode.subscribes = {
    topics(waveGenID).cmd, ...       % Direct control
    topics(controlID).cmd           % Listen for broadcast/emergency commands
};

% Probe Sensor Node
nodeDefs.probeNode.role = 'sensor';
nodeDefs.probeNode.publishes = {
    topics(probeID).status, ...
    topics(probeID).data, ...
    topics(probeID).log
};
nodeDefs.probeNode.subscribes = {
    topics(probeID).cmd, ...         % Direct control
    topics(waveGenID).data, ...      % Simulated wave field input
    topics(controlID).cmd            % Listen for broadcast/emergency commands
};

% Control Node (Coordinator)
nodeDefs.controlNode.role = 'controller';
nodeDefs.controlNode.publishes = {
    topics(controlID).status, ...
    topics(controlID).cmd, ...       % Own control interface
    topics(controlID).log, ...       % Self-logging
    topics(probeID).cmd, ...         % To control probe
    topics(waveGenID).cmd            % To control wave generator
};
nodeDefs.controlNode.subscribes = {
    topics(probeID).data, ...
    topics(waveGenID).data, ...
    topics(probeID).status, ...
    topics(waveGenID).status, ...
    topics(probeID).log, ...
    topics(waveGenID).log
};

% Node Configs (for constructor injection)
cfgWave = struct( ...
    'clientID', waveGenID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort', brokerPort, ...
    'subscriptions', {nodeDefs.waveGenNode.subscribes}, ...
    'publications', {nodeDefs.waveGenNode.publishes}, ...
    'verbose', true, ...
    'hardware', struct('hasSensor', false, 'hasActuator', true), ...
    'dt', stepDt ...
);

cfgProbe = struct( ...
    'clientID', probeID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort', brokerPort, ...
    'subscriptions', {nodeDefs.probeNode.subscribes}, ...
    'publications', {nodeDefs.probeNode.publishes}, ...
    'verbose', true, ...
    'hardware', struct('hasSensor', true, 'hasActuator', false), ...
    'dt', stepDt ...
);

cfgControl = struct( ...
    'clientID', controlID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort', brokerPort, ...
    'subscriptions', {nodeDefs.controlNode.subscribes}, ...
    'publications', {nodeDefs.controlNode.publishes}, ...
    'verbose', true, ...
    'hardware', struct('hasSensor', false, 'hasActuator', false), ...
    'dt', stepDt ...
);


%% Section 2: Subclass Definitions

% These subclasses were defined in the folder outside this script due to
% matlab constraints on classdefintions.

%% Section 3: Node Initialization

% --- Create CommClients ---
waveComm = CommClient(cfgWave);
probeComm = CommClient(cfgProbe);
ctrlComm  = CommClient(cfgControl);

% --- Create RestClients ---
waveRest = RestClient(cfgWave);
probeRest = RestClient(cfgProbe);
ctrlRest  = RestClient(cfgControl);

% --- Instantiate Nodes ---
waveNode = WaveGenNodeManager(cfgWave, waveComm, waveRest);
probeNode = ProbeNodeManager(cfgProbe, probeComm, probeRest);
ctrlNode  = ControlNodeManager(cfgControl, ctrlComm, ctrlRest);

% --- Register onMessageCallbacks AFTER instantiation ---
% Ensure callbacks point to valid objects
probeComm.onMessageCallback = @(topic, msg) probeNode.onMessageCallback(topic, msg);
ctrlComm.onMessageCallback = @(topic, msg) ctrlNode.onMessageCallback(topic, msg);
waveComm.onMessageCallback = @(topic, msg) waveNode.onMessageCallback(topic, msg);

% --- Topic Subscription Verification ---
fprintf("\n=== TOPIC REGISTRATION CHECK ===\n");

nodeClients = {waveComm, probeComm, ctrlComm};
nodeNames   = {"WaveGen Node", "Probe Node", "Control Node"};

for i = 1:length(nodeClients)
    fprintf("[%s]\n", nodeNames{i});
    
    % Subscribed topics
    subs = nodeClients{i}.subscriptions;
    if isempty(subs)
        fprintf("  Subscribed Topics: <none>\n");
    else
        fprintf("  Subscribed Topics:\n");
        for s = 1:length(subs)
            fprintf("    - %s\n", subs{s});
        end
    end

    % Published topics
    pubs = nodeClients{i}.publications;
    if isempty(pubs)
        fprintf("  Published Topics: <none>\n");
    else
        fprintf("  Published Topics:\n");
        for p = 1:length(pubs)
            fprintf("    - %s\n", pubs{p});
        end
    end
end

% --- Check initial state ---
fprintf("\n=== INITIALIZATION TEST ===\n");

nodes = {waveNode, probeNode, ctrlNode};
names = {"WaveGenNode", "ProbeNode", "ControlNode"};
for i = 1:length(nodes)
    s = string(nodes{i}.getState());
    fprintf("[ASSERT] %s initialized in state: %s\n", names{i}, s);
    if s ~= "IDLE"
        warning("❌ State mismatch for %s! Expected IDLE.", names{i});
    else
        fprintf("✅ %s is ready in IDLE.\n", names{i});
    end
end

fprintf("\nAll nodes initialized and communication clients connected.\n");

%% Section 4: Calibration Test (Voltage-Depth Linear Model)
fprintf("\n=== CALIBRATION TEST ===\n");

% Set known simulated wave levels (which act as "voltages" from the probe)
probeNode.liveInput = 0.05;  % Simulated analog voltage for depth 5 cm
pause(0.05);  % Ensure the probe registers this liveInput

calibCmd1 = struct("cmd", "Calibrate", "params", struct("depth", 5.0), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(calibCmd1));
pause(0.1);

probeNode.liveInput = 0.20;  % Simulated analog voltage for depth 20 cm
pause(0.05);  % Allow system to reflect the new value

calibCmd2 = struct("cmd", "Calibrate", "params", struct("depth", 20.0), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(calibCmd2));
pause(0.1);

% Finalize calibration (fit model, store slope/intercept)
calibFinal = struct("cmd", "Calibrate", "params", struct("finished", true), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(calibFinal));
pause(0.2);  % Allow time for transition to IDLE

% Assert final state
state = string(probeNode.getState());
fprintf("[ASSERT] ProbeNode final state: %s\n", state);
if state == "IDLE"
    fprintf("✅ ProbeNode successfully calibrated and returned to IDLE.\n");
else
    warning("❌ ProbeNode calibration did not complete correctly.");
end

% Print learned calibration
fprintf("[RESULT] Learned slope: %.4f, intercept: %.4f\n", ...
    probeNode.gainSlope, probeNode.gainIntercept);

%% Section 5: Sensor Diagnostics Test (TESTINGSENSOR)
fprintf("\n=== SENSOR DIAGNOSTICS TEST ===\n");

% Send command to enter sensor test mode
testCmd = struct("cmd", "Test", "params", struct("target", "sensor"), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(testCmd));
pause(0.1);  % Let the FSM transition

% Verify ProbeNode entered TESTINGSENSOR state
testingState = string(probeNode.getState());
fprintf("[ASSERT] ProbeNode state after Test command: %s\n", testingState);
if testingState == "TESTINGSENSOR"
    fprintf("✅ ProbeNode correctly entered TESTINGSENSOR.\n");
else
    warning("❌ ProbeNode failed to enter TESTINGSENSOR.");
end

% Define experiment parameters for this test section
testAmplitude = 1.0;
testFreqHz = 1.0;
testDuration = 0.3;

% Run sensor test with state-based monitoring
fprintf("Running sensor test for %.2f seconds...\n", testDuration);

stepCount = 0;
maxSteps = ceil(testDuration / stepDt) + 10; % Based on test duration with small buffer

while stepCount < maxSteps

    % Get current node state
    probeState = string(probeNode.getState());

    % Check if still in testing state
    if probeState == "TESTINGSENSOR"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Simulate wave input to probe from waveGenNode
        probeNode.liveInput = testAmplitude * sin(2*pi*testFreqHz * t);

        % Call step to emit measurement
        probeNode.step(t);
    else
        % Node has transitioned out of testing state
        fprintf("ProbeNode transitioned from TESTINGSENSOR to %s at step %d\n", probeState, stepCount);
        break;
    end

    pause(stepDt);  % real-time pacing
end

% Send Reset command to return ProbeNode to IDLE
resetCmd = struct("cmd", "Reset", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(resetCmd));
pause(0.1);  % Allow time for transition

% Final state verification
finalState = string(probeNode.getState());
fprintf("[ASSERT] ProbeNode state after diagnostics: %s\n", finalState);
if finalState == "IDLE"
    fprintf("✅ Sensor test completed and returned to IDLE.\n");
else
    warning("❌ Sensor diagnostics test failed to return to IDLE.");
end

%% Section 6: Wave Generator Actuator Test
fprintf("\n=== ACTUATOR TEST (WaveGenNode) ===\n");

% Step 1: Send Test command with valid configuration (amplitude + frequency + duration)
actuatorConfig = struct(...
    "cmd", "Test", ...
    "params", struct(...
        "target", "actuator", ...
        "amplitude", 1.0, ...
        "frequency", 1.0, ...
        "duration", 1.0), ...
    "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));  % seconds

ctrlComm.commPublish(topics(waveGenID).cmd, jsonencode(actuatorConfig));
pause(0.2);  % Allow state transition to CONFIGUREPENDING

% Step 2: Confirm state = CONFIGUREPENDING
state = string(waveNode.getState());
fprintf("[ASSERT] WaveGenNode entered: %s\n", state);
if state ~= "CONFIGUREPENDING"
    warning("❌ WaveGenNode failed to enter CONFIGUREPENDING.");
else
    fprintf("✅ WaveGenNode correctly entered CONFIGUREPENDING.\n");
end

% Step 3: Send TestValid to enter TESTINGACTUATOR and begin waveform generation
ctrlComm.commPublish(topics(waveGenID).cmd, jsonencode(struct("cmd", "TestValid", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'))));
pause(0.1);

% Step 4: Run loop with state-based termination
fprintf("Running actuator test for %.2f seconds...\n", actuatorConfig.params.duration);

stepCount = 0;
maxSteps = 10000; % Safety limit to prevent infinite loops

while stepCount < maxSteps

    % Get current node state
    waveState = string(waveNode.getState());

    % Check if node has returned to IDLE (test complete)
    if waveState == "IDLE"
        fprintf("✅ Actuator test completed! Node returned to IDLE after %d steps\n", stepCount);
        break;
    end

    % Only step if node is actively testing
    if waveState == "TESTINGACTUATOR"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Execute step
        waveNode.step(t);
    else
        % Node is transitioning
        fprintf("Node transitioning: Wave=%s at step %d\n", waveState, stepCount);
    end

    pause(stepDt);
end

% Step 5: Assert final state = IDLE
state = string(waveNode.getState());
fprintf("[ASSERT] WaveGenNode state after actuator test: %s\n", state);
if state == "IDLE"
    fprintf("✅ Actuator test completed and returned to IDLE.\n");
else
    warning("❌ Actuator test did not complete correctly.");
end

%% Section 7: Full Experiment Run
fprintf("\n=== FULL EXPERIMENT RUN ===\n");

% Define experiment config
experimentConfig = struct( ...
    "amplitude", 1.0, ...
    "frequency", 1.5, ...
    "duration", 2.0);  % full sim time

% Step 1: Send Run command to both nodes
runCmd = struct("cmd", "Run", "params", experimentConfig, "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(runCmd));
pause(0.2);  % Allow both nodes to process configuration

% Step 2: Verify CONFIGUREPENDING state
waveState = string(waveNode.getState());
probeState = string(probeNode.getState());
fprintf("[ASSERT] WaveGenNode CONFIGUREPENDING: %s\n", waveState);
fprintf("[ASSERT] ProbeNode CONFIGUREPENDING: %s\n", probeState);

if waveState ~= "CONFIGUREPENDING" || probeState ~= "CONFIGUREPENDING"
    warning("❌ One or more nodes failed to enter CONFIGUREPENDING.");
else
    fprintf("✅ Both nodes entered CONFIGUREPENDING.");
end

% Step 3: Send RunValid to both nodes
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(struct("cmd", "RunValid", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'))));
pause(0.1);

% Step 4: Experiment run loop
fprintf("Running virtual experiment for %.2f seconds...\n", experimentConfig.duration);

stepCount = 0;
maxSteps = 10000; % Safety limit to prevent infinite loops

while stepCount < maxSteps

    % Get current node states
    waveState = string(waveNode.getState());
    probeState = string(probeNode.getState());

    % Check if both nodes have returned to IDLE (experiment complete)
    if waveState == "IDLE" && probeState == "IDLE"
        fprintf("✅ Experiment completed! Nodes returned to IDLE after %d steps\n", stepCount);
        break;
    end

    % Only feed data if nodes are actively running
    if waveState == "RUNNING" && probeState == "RUNNING"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Execute steps with proper wave value coupling
        waveValue = waveNode.step(t);
        probeNode.liveInput = waveValue;
        probeNode.step(t);
    else
        % Nodes are transitioning - still call step but don't feed data
        fprintf("Nodes transitioning: Wave=%s, Probe=%s at step %d\n", waveState, probeState, stepCount);
    end

    pause(stepDt);
end

% Step 5: Confirm nodes return to IDLE after run
waveFinal = string(waveNode.getState());
probeFinal = string(probeNode.getState());

fprintf("[ASSERT] WaveGenNode final state: %s\n", waveFinal);
fprintf("[ASSERT] ProbeNode final state: %s\n", probeFinal);

if waveFinal == "IDLE" && probeFinal == "IDLE"
    fprintf("✅ Full experiment completed. All nodes returned to IDLE.\n");
else
    warning("❌ Experiment did not end cleanly.");
end

% --- Retrieve and plot experiment data from REST server ---

% Retrieve probe data (most recent)
try
    probeDataResp = ctrlRest.fetchData('clientID', 'probeNode', 'latest', true, 'format', 'csv');
    if isstruct(probeDataResp)
        probeTable = struct2table(probeDataResp);
        probeTable.timestamp = datetime(probeTable.timestamp);
    else
        warning('Unexpected probe data format from REST server.');
        probeTable = [];
    end
catch ME
    warning('Failed to retrieve probe data from REST server: %s', '%s', ME.message);
    probeTable = [];
end

% Retrieve wave data (most recent)
try
    waveDataResp = ctrlRest.fetchData('clientID', 'waveGenNode', 'latest', true, 'format', 'csv');
    if isstruct(waveDataResp)
        waveTable = struct2table(waveDataResp);
        waveTable.timestamp = datetime(waveTable.timestamp);
    else
        warning('Unexpected wave data format from REST server.');
        waveTable = [];
    end
catch ME
    warning('Failed to retrieve wave data from REST server: %s', '%s', ME.message);
    waveTable = [];
end

% --- Plot the retrieved data ---
figure('Name', "Single Experiment Run");
sgtitle("Single Experiment Run", 'FontSize', 14, 'FontWeight', 'bold');
if ~isempty(waveTable)
    subplot(2,1,1);
    plot(waveTable.timestamp, waveTable.value);
    title('WaveGenNode Data');
    xlabel('Time (s)');
    ylabel('Wave Signal');
end
if ~isempty(probeTable)
    subplot(2,1,2);
    plot(probeTable.timestamp, probeTable.value);
    title('ProbeNode Data');
    xlabel('Time (s)');
    ylabel('Probe Signal');
end

%% Section 8: Multi-Experiment Sequence Tests
fprintf("\n=== MULTI-EXPERIMENT SEQUENCE TESTS ===\n");

% Define multi-experiment config with 3 sub-experiments
multiExperimentConfig = struct( ...
    "name", "MultiExperimentTest", ...
    "experiments", [ ...
        struct( ...
            "name", "LowFreq_HighAmplitude", ...
            "amplitude", 2.0, ...
            "frequency", 0.5, ...
            "duration", 2.0), ...
        struct( ...
            "name", "MidFreq_MidAmplitude", ...
            "amplitude", 1.5, ...
            "frequency", 1.5, ...
            "duration", 0.5), ...
        struct( ...
            "name", "HighFreq_LowAmplitude", ...
            "amplitude", 0.8, ...
            "frequency", 2.3, ...
            "duration", 1.0) ...
    ] ...
);

% Step 1: Send Run command with multi-experiment config to both nodes
runCmd = struct("cmd", "Run", "params", multiExperimentConfig, "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(runCmd));
pause(0.2);  % Allow both nodes to process configuration

% Step 2: Verify CONFIGUREPENDING state
waveState = string(waveNode.getState());
probeState = string(probeNode.getState());
fprintf("[ASSERT] WaveGenNode CONFIGUREPENDING: %s\n", waveState);
fprintf("[ASSERT] ProbeNode CONFIGUREPENDING: %s\n", probeState);

if waveState ~= "CONFIGUREPENDING" || probeState ~= "CONFIGUREPENDING"
    warning("❌ One or more nodes failed to enter CONFIGUREPENDING for multi-experiment.");
else
    fprintf("✅ Both nodes entered CONFIGUREPENDING for multi-experiment sequence.");
end

% Step 3: Send RunValid to both nodes
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(struct("cmd", "RunValid", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'))));
pause(0.2);

% Step 4: Verify Running state
waveState = string(waveNode.getState());
probeState = string(probeNode.getState());
fprintf("[ASSERT] WaveGenNode RUNNING: %s\n", waveState);
fprintf("[ASSERT] ProbeNode RUNNING: %s\n", probeState);

if waveState ~= "RUNNING" || probeState ~= "RUNNING"
    warning("❌ One or more nodes failed to enter RUNNING for multi-experiment.");
else
    fprintf("✅ Both nodes entered RUNNING for multi-experiment sequence.");
end

% Step 5: Multi-experiment execution handled by ExperimentManager
fprintf("Running multi-experiment sequence with %d experiments...\n", length(multiExperimentConfig.experiments));

% Note: The actual execution loop will be handled internally by ExperimentManager
% based on the multi-experiment config structure. The nodes will manage:
% - Sequential execution of each experiment
% - State transitions between experiments
% - Data collection and aggregation
% - Proper cleanup between runs

stepCount = 0;
maxSteps = 10000; % Safety limit to prevent infinite loops

while stepCount < maxSteps

    % Get current node states
    waveState = string(waveNode.getState());
    probeState = string(probeNode.getState());

    % Check if both nodes have returned to IDLE (all experiments complete)
    if waveState == "IDLE" && probeState == "IDLE"
        fprintf("✅ All experiments completed! Nodes returned to IDLE after %d steps\n", stepCount);
        break;
    end

    % Only feed data if nodes are actively running
    if waveState == "RUNNING" && probeState == "RUNNING"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Execute steps
        waveValue = waveNode.step(t);
        probeNode.liveInput = waveValue;
        probeNode.step(t);
    else
        % Nodes are transitioning - still call step but don't feed data
        fprintf("Nodes transitioning: Wave=%s, Probe=%s at step %d\n", waveState, probeState, stepCount);
    end

    pause(stepDt);
end

% Step 6: Confirm nodes return to IDLE after multi-experiment run
waveFinal = string(waveNode.getState());
probeFinal = string(probeNode.getState());

fprintf("[ASSERT] WaveGenNode final state: %s\n", waveFinal);
fprintf("[ASSERT] ProbeNode final state: %s\n", probeFinal);

if waveFinal == "IDLE" && probeFinal == "IDLE"
    fprintf("✅ Multi-experiment sequence completed. All nodes returned to IDLE.\n");
else
    warning("❌ Multi-experiment sequence did not end cleanly.");
end

% --- Retrieve and plot experiment data from all three experiments ---

% Experiment names from your config
expNames = ["LowFreq_HighAmplitude", "MidFreq_MidAmplitude", "HighFreq_LowAmplitude"];
nodeIDs = ["probeNode", "waveGenNode"];
nodeNames = ["probe", "waveGen"];

% Initialize storage
expData = struct();

% Fetch data for each experiment
for i = 1:length(expNames)
    expName = expNames(i);
    fprintf("Fetching data for experiment: %s\n", expName);

    for j = 1:length(nodeIDs)
        nodeID = nodeIDs(j);
        try
            % Fetch specific experiment data
            resp = ctrlRest.fetchData('clientID', char(nodeID), 'experimentName', char(expName), 'format', 'jsonl');

            if isstruct(resp)
                % Struct format
                expData.(nodeID).(expName) = struct2table(resp);
            else
                warning('Unexpected format for %s/%s', nodeID, expName);
                expData.(nodeID).(expName) = [];
            end

            % Convert timestamps if needed
            if ~isempty(expData.(nodeID).(expName)) && istable(expData.(nodeID).(expName))
                tbl = expData.(nodeID).(expName);
                if ismember('timestamp', tbl.Properties.VariableNames)
                    if iscell(tbl.timestamp) || isstring(tbl.timestamp) || ischar(tbl.timestamp)
                        try
                            tbl.timestamp = datetime(tbl.timestamp);
                        catch
                            % Keep original if conversion fails
                        end
                    end
                    expData.(nodeID).(expName) = tbl;
                end
            end

        catch ME
            warning('Failed to fetch %s/%s: %s', nodeID, expName, ME.message);
            expData.(nodeID).(expName) = [];
        end
    end
end

% Plot each experiment in separate figures
for i = 1:length(expNames)
    expName = expNames(i);

    figure('Name', sprintf('Experiment %d: %s', i, expName), 'Position', [100+i*50, 100+i*50, 800, 600]);

    for j = 1:length(nodeIDs)
        nodeID = nodeIDs(j);

        subplot(2, 1, j);

        if isfield(expData, nodeID) && isfield(expData.(nodeID), expName) && ~isempty(expData.(nodeID).(expName))
            tbl = expData.(nodeID).(expName);
            if istable(tbl) && ismember('value', tbl.Properties.VariableNames)
                if ismember('timestamp', tbl.Properties.VariableNames)
                    plot(tbl.timestamp, tbl.value);
                    xlabel('Time');
                else
                    plot(tbl.value, 'LineWidth', 1.5);
                    xlabel('Sample Index');
                end
                ylabel('Value');
                title(sprintf('%s Data - %s', nodeNames(j), strrep(char(expName), '_', ' ')));
                grid on;
            else
                text(0.5, 0.5, sprintf('No valid data for %s', nodeNames(j)), 'HorizontalAlignment', 'center');
                title(sprintf('%s Data - %s (No Data)', nodeNames(j), strrep(char(expName), '_', ' ')));
            end
        else
            text(0.5, 0.5, sprintf('No data retrieved for %s', nodeNames(j)), 'HorizontalAlignment', 'center');
            title(sprintf('%s Data - %s (No Data)', nodeNames(j), strrep(char(expName), '_', ' ')));
        end
    end

    sgtitle(sprintf('Experiment %d: %s', i, strrep(char(expName), '_', ' ')), 'FontSize', 14, 'FontWeight', 'bold');
end

fprintf("✅ Data retrieval and plotting complete for all experiments!\n");

fprintf("✅ Multi-experiment sequence tests completed!\n");

%% Section 9: Abort Tests
fprintf("\n=== ABORT TESTS ===\n");

% Test abort functionality from different sources:
% 1. Control node sending abort message to peripheral nodes
% 2. WaveGenNode sending abort command internally
% 3. ProbeNode sending abort command internally
% Each test validates proper state transitions to ERROR and recovery to IDLE

%% Test 9.1: Control Node Abort Test
fprintf("\n--- Test 9.1: Control Node Abort ---\n");

% Step 1: Start a normal experiment run to have nodes in active state
experimentConfig = struct( ...
    "amplitude", 1.0, ...
    "frequency", 2.0, ...
    "duration", 10.0);  % Long duration so we can abort during execution

runCmd = struct("cmd", "Run", "params", experimentConfig, "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(runCmd));
pause(0.2);
drawnow;

% Step 2: Verify nodes are in CONFIGUREPENDING state
waveState = string(waveNode.getState());
probeState = string(probeNode.getState());
fprintf("[ASSERT] WaveGenNode CONFIGUREPENDING: %s\n", waveState);
fprintf("[ASSERT] ProbeNode CONFIGUREPENDING: %s\n", probeState);

if waveState == "CONFIGUREPENDING" && probeState == "CONFIGUREPENDING"
    fprintf("✅ Both nodes in CONFIGUREPENDING state.\n");
else
    warning("❌ Nodes not in expected CONFIGUREPENDING state for abort test.");
end

% Step 3: Send RunValid to get nodes into RUNNING state
sendTime = datestr(datetime('now'), 'yyyy-mm-dd HH:MM:SS.FFF'); %#ok<DATST>
fprintf("[SEND:%s] RunValid command -> %s at %s\n", controlID, topics(controlID).cmd, sendTime);
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(struct("cmd", "RunValid", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'))));
pause(0.2);

% Step 4: Verify nodes are in RUNNING state
waveState = string(waveNode.getState());
probeState = string(probeNode.getState());
fprintf("[ASSERT] WaveGenNode RUNNING: %s\n", waveState);
fprintf("[ASSERT] ProbeNode RUNNING: %s\n", probeState);

if waveState == "RUNNING" && probeState == "RUNNING"
    fprintf("✅ Both nodes in RUNNING state, ready for abort test.\n");
else
    warning("❌ Nodes not in expected RUNNING state for abort test.");
end

% Step 5: Let experiment run briefly, then send abort from control node
stepCount = 0;
maxStepsBeforeAbort = 50; % Run for ~0.5 seconds before aborting

while stepCount < maxStepsBeforeAbort
    % Get current node states
    waveState = string(waveNode.getState());
    probeState = string(probeNode.getState());

    % Only feed data if nodes are actively running
    if waveState == "RUNNING" && probeState == "RUNNING"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Execute steps
        waveValue = waveNode.step(t);
        probeNode.liveInput = waveValue;
        probeNode.step(t);
    else
        % If nodes aren't running, break early
        break;
    end

    pause(stepDt);
end

fprintf("Experiment ran for %d steps, now sending abort...\n", stepCount);

% Step 6: Send abort command from control node
abortCmd = struct("cmd", "Abort", "params", struct("reason", "Control node initiated abort test"), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
sendTime = datestr(datetime('now'), 'yyyy-mm-dd HH:MM:SS.FFF'); %#ok<DATST>
fprintf("[SEND:%s] Abort command -> %s at %s\n", controlID, topics(controlID).cmd, sendTime);
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(abortCmd));
pause(0.2);

% Step 7: Verify nodes transition to ERROR state
waveStateFinal = string(waveNode.getState());
probeStateFinal = string(probeNode.getState());
fprintf("[ASSERT] WaveGenNode after abort: %s\n", waveStateFinal);
fprintf("[ASSERT] ProbeNode after abort: %s\n", probeStateFinal);

if waveStateFinal == "ERROR" && probeStateFinal == "ERROR"
    fprintf("✅ Control node abort successful - both nodes in ERROR state.\n");
else
    warning("❌ Abort failed - nodes not in expected ERROR state.");
end

% Step 8: Reset nodes back to IDLE for next test
resetCmd = struct("cmd", "Reset", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
sendTime = datestr(datetime('now'), 'yyyy-mm-dd HH:MM:SS.FFF'); %#ok<DATST>
fprintf("[SEND:%s] Reset command -> %s at %s\n", controlID, topics(controlID).cmd, sendTime);
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(resetCmd));
pause(0.2);

waveStateReset = string(waveNode.getState());
probeStateReset = string(probeNode.getState());
ctrlStateReset = string(ctrlNode.getState());
fprintf("[ASSERT] WaveGenNode after reset: %s\n", waveStateReset);
fprintf("[ASSERT] ProbeNode after reset: %s\n", probeStateReset);
fprintf("[ASSERT] ControlNode after reset: %s\n", ctrlStateReset);

if waveStateReset == "IDLE" && probeStateReset == "IDLE" && ctrlStateReset == "IDLE"
    fprintf("✅ Reset successful - all nodes back to IDLE.\n");
else
    warning("❌ Reset failed - not all nodes back to IDLE state.");
end

%% Test 9.2: WaveGenNode Self-Abort Test
fprintf("\n--- Test 9.2: WaveGenNode Self-Abort ---\n");

% Step 1: Start WaveGenNode in TESTINGACTUATOR state
actuatorConfig = struct(...
    "cmd", "Test", ...
    "params", struct(...
        "target", "actuator", ...
        "amplitude", 1.0, ...
        "frequency", 1.0, ...
        "duration", 10.0), ...
    "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));  % Long duration so we can abort during execution

ctrlComm.commPublish(topics(waveGenID).cmd, jsonencode(actuatorConfig));
pause(0.2);

% Step 2: Verify WaveGenNode is in CONFIGUREPENDING state
waveState = string(waveNode.getState());
fprintf("[ASSERT] WaveGenNode CONFIGUREPENDING: %s\n", waveState);

if waveState == "CONFIGUREPENDING"
    fprintf("✅ WaveGenNode in CONFIGUREPENDING state.\n");
else
    warning("❌ WaveGenNode not in expected CONFIGUREPENDING state for self-abort test.");
end

% Step 3: Send TestValid to get WaveGenNode into TESTINGACTUATOR state
ctrlComm.commPublish(topics(waveGenID).cmd, jsonencode(struct("cmd", "TestValid", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'))));
pause(0.2);

% Step 4: Verify WaveGenNode is in TESTINGACTUATOR state
waveState = string(waveNode.getState());
fprintf("[ASSERT] WaveGenNode TESTINGACTUATOR: %s\n", waveState);

if waveState == "TESTINGACTUATOR"
    fprintf("✅ WaveGenNode in TESTINGACTUATOR state, ready for self-abort test.\n");
else
    warning("❌ WaveGenNode not in expected TESTINGACTUATOR state for self-abort test.");
end

% Step 5: Let WaveGenNode run briefly, then trigger internal abort
stepCount = 0;
maxStepsBeforeAbort = 30; % Run for ~0.3 seconds before self-aborting

while stepCount < maxStepsBeforeAbort
    % Get current node state
    waveState = string(waveNode.getState());

    % Only step if node is actively testing
    if waveState == "TESTINGACTUATOR"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Execute step
        waveNode.step(t);
    else
        % If node isn't testing, break early
        break;
    end

    pause(stepDt);
end

fprintf("WaveGenNode ran for %d steps, now triggering internal abort...\n", stepCount);

% Step 6: Simulate internal error condition - call abort() method directly
waveNode.abort("Internal actuator malfunction detected during self-test");
pause(0.2);

% Step 7: Verify WaveGenNode transitions to ERROR state
waveStateFinal = string(waveNode.getState());
probeStateFinal = string(probeNode.getState());
ctrlStateFinal = string(ctrlNode.getState());

fprintf("[ASSERT] WaveGenNode after self-abort: %s\n", waveStateFinal);
fprintf("[ASSERT] ProbeNode after WaveGen self-abort: %s\n", probeStateFinal);
fprintf("[ASSERT] ControlNode after WaveGen self-abort: %s\n", ctrlStateFinal);

if waveStateFinal == "ERROR"
    fprintf("✅ WaveGenNode self-abort successful - node in ERROR state.\n");
else
    warning("❌ WaveGenNode self-abort failed - node not in expected ERROR state.");
end

if probeStateFinal == "IDLE" && ctrlStateFinal == "IDLE"
    fprintf("✅ Other nodes unaffected - remain in IDLE state.\n");
else
    warning("❌ Other nodes affected by WaveGenNode self-abort - not in expected IDLE state.");
end

% Step 8: Reset WaveGenNode back to IDLE for next test
resetCmd = struct("cmd", "Reset", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(waveGenID).cmd, jsonencode(resetCmd));
pause(0.2);

waveStateReset = string(waveNode.getState());
probeStateReset = string(probeNode.getState());
ctrlStateReset = string(ctrlNode.getState());

fprintf("[ASSERT] WaveGenNode after reset: %s\n", waveStateReset);
fprintf("[ASSERT] ProbeNode after reset: %s\n", probeStateReset);
fprintf("[ASSERT] ControlNode after reset: %s\n", ctrlStateReset);

if waveStateReset == "IDLE" && probeStateReset == "IDLE" && ctrlStateReset == "IDLE"
    fprintf("✅ Reset successful - all nodes back to IDLE.\n");
else
    warning("❌ Reset failed - not all nodes back to IDLE state.");
end

%% Test 9.3: ProbeNode Self-Abort Test  
fprintf("\n--- Test 9.3: ProbeNode Self-Abort ---\n");

% Step 1: Start ProbeNode in TESTINGSENSOR state
testCmd = struct("cmd", "Test", "params", struct("target", "sensor"), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(testCmd));
pause(0.2);

% Step 2: Verify ProbeNode is in TESTINGSENSOR state
probeState = string(probeNode.getState());
fprintf("[ASSERT] ProbeNode TESTINGSENSOR: %s\n", probeState);

if probeState == "TESTINGSENSOR"
    fprintf("✅ ProbeNode in TESTINGSENSOR state, ready for self-abort test.\n");
else
    warning("❌ ProbeNode not in expected TESTINGSENSOR state for self-abort test.");
end

% Step 3: Let ProbeNode run briefly, then trigger internal abort
stepCount = 0;
maxStepsBeforeAbort = 25; % Run for ~0.25 seconds before self-aborting

while stepCount < maxStepsBeforeAbort
    % Get current node state
    probeState = string(probeNode.getState());

    % Only step if node is actively testing
    if probeState == "TESTINGSENSOR"
        stepCount = stepCount + 1;
        t = (stepCount - 1) * stepDt;

        % Simulate wave input to probe
        probeNode.liveInput = 1.0 * sin(2*pi*1.0 * t);

        % Execute step
        probeNode.step(t);
    else
        % If node isn't testing, break early
        break;
    end

    pause(stepDt);
end

fprintf("ProbeNode ran for %d steps, now triggering internal abort...\n", stepCount);

% Step 4: Simulate internal error condition - call abort() method directly
probeNode.abort("Sensor calibration drift detected - readings unreliable");
pause(0.2);

% Step 5: Verify ProbeNode transitions to ERROR state
probeStateFinal = string(probeNode.getState());
waveStateFinal = string(waveNode.getState());
ctrlStateFinal = string(ctrlNode.getState());

fprintf("[ASSERT] ProbeNode after self-abort: %s\n", probeStateFinal);
fprintf("[ASSERT] WaveGenNode after Probe self-abort: %s\n", waveStateFinal);
fprintf("[ASSERT] ControlNode after Probe self-abort: %s\n", ctrlStateFinal);

if probeStateFinal == "ERROR"
    fprintf("✅ ProbeNode self-abort successful - node in ERROR state.\n");
else
    warning("❌ ProbeNode self-abort failed - node not in expected ERROR state.");
end

if waveStateFinal == "IDLE" && ctrlStateFinal == "IDLE"
    fprintf("✅ Other nodes unaffected - remain in IDLE state.\n");
else
    warning("❌ Other nodes affected by ProbeNode self-abort - not in expected IDLE state.");
end

% Step 6: Reset ProbeNode back to IDLE for cleanup
resetCmd = struct("cmd", "Reset", "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(resetCmd));
pause(0.2);

probeStateReset = string(probeNode.getState());
waveStateReset = string(waveNode.getState());
ctrlStateReset = string(ctrlNode.getState());

fprintf("[ASSERT] ProbeNode after reset: %s\n", probeStateReset);
fprintf("[ASSERT] WaveGenNode after reset: %s\n", waveStateReset);
fprintf("[ASSERT] ControlNode after reset: %s\n", ctrlStateReset);

if probeStateReset == "IDLE" && waveStateReset == "IDLE" && ctrlStateReset == "IDLE"
    fprintf("✅ Reset successful - all nodes back to IDLE.\n");
else
    warning("❌ Reset failed - not all nodes back to IDLE state.");
end

fprintf("✅ Abort tests completed!\n");

%% Section End: Clean up
fprintf("\n=== FINAL CLEANUP ===\n");
fprintf("[SHUTDOWN] Calling shutdown for ProbeNode...\n");
probeNode.shutdown();

fprintf("[SHUTDOWN] Calling shutdown for WaveGenNode...\n");
waveNode.shutdown();

fprintf("[SHUTDOWN] Calling shutdown for ControlNode...\n");
ctrlNode.shutdown();

fprintf("[CLEANUP] All nodes shut down successfully.\n");
fprintf("[CLEANUP] VirtualIntegrationTest completed.\n");

% Final diary flush
diary('off');
fprintf("✅ Complete log saved to: %s\n", diaryFile);