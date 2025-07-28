% VirtualIntegrationTest.m
% ========================================================================
% Simulated full virtual experiment framework integration on localhost
% Nodes: WaveGenNode, ProbeNode, ControlNode
% ========================================================================

% TEST OBJECTIVES
% This script validates the end-to-end integration of the node architecture
% under a realistic lab-style experiment simulation. All components run in a
% single MATLAB process without hardware, using simulated sensor-actuator logic.
% Nodes communicate via MQTT and execute finite-state logic as defined by the
% ExperimentManager framework.

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
%    - Returns to IDLE
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
% 6. Cleanup:
%    - All MQTT clients disconnected
%    - Output data saved (e.g., wave + probe data)

%% Test
%% Section 1: Setup and Common Config

clc; clear;
addpath(genpath(fullfile(fileparts(mfilename('fullpath')), '..', 'matlabCommon')));

% Clear previous diary contents
fid = fopen('VirtualIntegrationTest.log', 'w');  % Open in write mode (truncates file)
fclose(fid);  % Immediately close

% Start logging all console output to file
diaryFile = 'VirtualIntegrationTest.log';
diary(diaryFile);
disp("[LOGGING] Console output captured in: " + diaryFile);

% Ensure log is finalized on error or exit
logCleanup = onCleanup(@() diary('off'));

% Simulation Parameters
simConfig.totalSteps = 1000;
simConfig.dt = 0.01;  % seconds per step
simConfig.timeVec = (0:simConfig.dt:(simConfig.totalSteps-1)*simConfig.dt)';
simConfig.freqHz = 1.0; % test waveform frequency
simConfig.amplitude = 1.0; % cm

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
    'hardware', struct('hasSensor', false, 'hasActuator', true) ...
);

cfgProbe = struct( ...
    'clientID', probeID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort', brokerPort, ...
    'subscriptions', {nodeDefs.probeNode.subscribes}, ...
    'publications', {nodeDefs.probeNode.publishes}, ...
    'verbose', true, ...
    'hardware', struct('hasSensor', true, 'hasActuator', false) ...
);

cfgControl = struct( ...
    'clientID', controlID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort', brokerPort, ...
    'subscriptions', {nodeDefs.controlNode.subscribes}, ...
    'publications', {nodeDefs.controlNode.publishes}, ...
    'verbose', true, ...
    'hardware', struct('hasSensor', false, 'hasActuator', false) ...
);

% Data buffers (for logging results)
waveLog = [];  % stores generated wave signal
probeLog = []; % stores measured noisy data


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

calibCmd1 = struct("cmd", "Calibrate", "params", struct("depth", 5.0));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(calibCmd1));
pause(0.1);

probeNode.liveInput = 0.20;  % Simulated analog voltage for depth 20 cm
pause(0.05);  % Allow system to reflect the new value

calibCmd2 = struct("cmd", "Calibrate", "params", struct("depth", 20.0));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(calibCmd2));
pause(0.1);

% Finalize calibration (fit model, store slope/intercept)
calibFinal = struct("cmd", "Calibrate", "params", struct("finished", true));
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
testCmd = struct("cmd", "Test", "params", struct("target", "sensor"));
ctrlComm.commPublish(topics(probeID).cmd, jsonencode(testCmd));
pause(0.1);  % Let the FSM transition

% Run live steps for a short time (simulate experiment runtime)
testDuration = 1.0;  % seconds
testSteps = floor(testDuration / simConfig.dt);

for k = 1:testSteps
    t = simConfig.timeVec(k);
    
    % Simulate wave input to probe from waveGenNode
    probeNode.liveInput = simConfig.amplitude * sin(2*pi*simConfig.freqHz * t);
    
    % Call step to emit measurement
    isFinal = (k == testSteps);  % last step triggers cleanup
    probeNode.step(t, isFinal);
    
    pause(simConfig.dt);  % real-time pacing
end

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
        "duration", 2.0));  % seconds

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

% Step 3: Send TestValid to enter TESTINGACTUATOR and begin waveform generation (with suppressed output)
ctrlComm.commPublish(topics(waveGenID).cmd, jsonencode(struct("cmd", "TestValid")));
pause(0.1);

% Step 4: Run loop to execute steps (simulate tick-based progression)
for k = 1:round(2.0 / simConfig.dt)
    tNow = simConfig.timeVec(k);
    finalStep = (k == round(2.0 / simConfig.dt));
    waveNode.step(tNow, finalStep);
    pause(simConfig.dt);
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
    "frequency", 1.0, ...
    "duration", simConfig.totalSteps * simConfig.dt);  % full sim time

% Step 1: Send Run command to both nodes
runCmd = struct("cmd", "Run", "params", experimentConfig);
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
ctrlComm.commPublish(topics(controlID).cmd, jsonencode(struct("cmd", "RunValid")));
pause(0.1);

% Step 4: Time-marched experiment loop
fprintf("Running virtual experiment for %.2f seconds...\n", experimentConfig.duration);

for k = 1:simConfig.totalSteps
    t = simConfig.timeVec(k);

    % WaveGenNode generates wave sample
    waveNode.step(t, k == simConfig.totalSteps);

    % ProbeNode receives wave value as liveInput (simulated from WaveGenNode waveform)
    probeNode.liveInput = simConfig.amplitude * sin(2 * pi * simConfig.freqHz * t);
    probeNode.step(t, k == simConfig.totalSteps);

    pause(simConfig.dt);
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
    if ischar(probeDataResp)
        probeTable = readtable(string2file(probeDataResp));
    elseif isstruct(probeDataResp) && isfield(probeDataResp, 'csv')
        probeTable = readtable(string2file(probeDataResp.csv));
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
    if ischar(waveDataResp)
        waveTable = readtable(string2file(waveDataResp));
    elseif isstruct(waveDataResp) && isfield(waveDataResp, 'csv')
        waveTable = readtable(string2file(waveDataResp.csv));
    else
        warning('Unexpected wave data format from REST server.');
        waveTable = [];
    end
catch ME
    warning('Failed to retrieve wave data from REST server: %s', '%s', ME.message);
    waveTable = [];
end

% --- Plot the retrieved data ---
figure;
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

%% Section: Clean up
fprintf("[SHUTDOWN] Calling shutdown for ProbeNode...\n");
probeNode.shutdown();

fprintf("[SHUTDOWN] Calling shutdown for WaveGenNode...\n");
waveNode.shutdown();

fprintf("[SHUTDOWN] Calling shutdown for ControlNode...\n");
ctrlNode.shutdown();

function fname = string2file(str)
    fname = [tempname, '.csv'];
    fid = fopen(fname, 'w');
    fwrite(fid, str);
    fclose(fid);
end