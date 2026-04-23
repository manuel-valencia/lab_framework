% =========================================================================
% CarriageNodeTest.m
%
% Test script for CarriageNodeManager (and MockCarriageNodeManager).
%
% SET USE_MOCK = true  to run against synthetic data (no hardware needed).
%                      Validates FSM routing, calibration math, filter
%                      pipeline, and motion spline — on any computer.
%
% SET USE_MOCK = false to run against the real NI-DAQ hardware.
%                      All MQTT command sections are identical; hardware
%                      sections pause for user prompts instead.
%
% TEST OBJECTIVES
% ---------------
%   T1 — Initialization:   node boots to IDLE, hardware initializes
%   T2 — Force bias calib: Calibrate(force_bias) → biasVoltages saved,
%                          returns to IDLE
%   T3 — Motion calib:     Multi-point Calibrate(motion_sensors) per
%                          channel → spline fit saved, returns to IDLE
%   T4 — Sensor test:      Test(sensor) → streams Fx/Fy/Fz live,
%                          visual check, Reset → IDLE
%   T5 — Single run:       Configure → RunValid → POSTPROC → IDLE,
%                          CSV saved, output plotted
%   T6 — Multi-run:        3 sub-experiments sequentially, CSV per run
%   T7 — Abort/recovery:   Abort during RUNNING → ERROR → Reset → IDLE
%
% PREREQUISITES (USE_MOCK = false)
% ---------------------------------
%   - Mosquitto broker running (network/mosquitto.conf)
%   - REST server running     (python network/RestServer.py)
%   - config/carriage_computer.json filled in
%   - carriageNodeRunTimeMatrix.mat created (run createRunTimeMatrix.m)
%   - NI-DAQ USB-6218 connected, wiring per channel layout in header
%
% PREREQUISITES (USE_MOCK = true)
% --------------------------------
%   - Mosquitto broker running
%   - REST server running
%   - carriageNodeRunTimeMatrix.mat recommended (uses identity if absent)
%
% USAGE
%   Run all tests:        just run the script
%   Run selected tests:   set RUN_TESTS.sectionName = false for any to skip
% =========================================================================

clc; clear;

% ── ADD PATHS ─────────────────────────────────────────────────────────────
testDir  = fileparts(mfilename('fullpath'));
repoRoot = fullfile(testDir, '..', '..');
addpath(genpath(fullfile(repoRoot, 'matlabCommon')));
addpath(genpath(fullfile(repoRoot, 'carriage_node')));
addpath(genpath(testDir));

% ── DIARY ─────────────────────────────────────────────────────────────────
ts = char(datetime('now','Format','yyyyMMdd-HHmmss'));
diaryFile = fullfile(testDir, sprintf('CarriageNodeTest_%s.log', ts));
fid = fopen(diaryFile, 'w'); if fid ~= -1; fclose(fid); end
diary(diaryFile);
cleanupDiary = onCleanup(@() diary('off')); %#ok<NASGU>

% =========================================================================
%% CONFIGURATION
% =========================================================================

USE_MOCK = true;   % <── flip to false to run against real hardware

RUN_TESTS = struct( ...
    'initialization',   true, ...
    'forceCalib',       true, ...
    'motionCalib',      true, ...
    'sensorTest',       true, ...
    'singleRun',        true, ...
    'multiRun',         true, ...
    'abortRecovery',    true  ...
);

% Counters for final summary
nPass = 0;
nFail = 0;

% Helper: log pass/fail
function logResult(label, passed)
    if passed
        fprintf("  ✅ PASS — %s\n", label);
    else
        fprintf("  ❌ FAIL — %s\n", label);
    end
end

% =========================================================================
%% SECTION 1 — Setup
% =========================================================================
fprintf("\n=== SECTION 1: Setup ===\n");

brokerAddress = 'localhost';
brokerPort    = 1883;
clientID      = 'carriageNode';
controlID     = 'controlNode';

if USE_MOCK
    fprintf("[MOCK] Building inline test config (no hardware).\n");

    % Minimal hardware config — no real DAQ device needed for mock
    cfg = struct( ...
        'clientID',     clientID, ...
        'brokerAddress', brokerAddress, ...
        'brokerPort',    brokerPort, ...
        'restPort',      5000, ...
        'verbose',       true, ...
        'subscriptions', {{'carriageNode/cmd'}}, ...
        'publications',  {{'carriageNode/status','carriageNode/data','carriageNode/log'}}, ...
        'hardware', struct( ...
            'hasSensor',          true, ...
            'hasActuator',        false, ...
            'daqDevice',          'Dev1', ...
            'forceChannels',      {{'ai0','ai1','ai2','ai3','ai4','ai5'}}, ...
            'syncChannel',        'ai7', ...
            'heaveChannel',       'ai17', ...
            'pitchChannel',       'ai18', ...
            'rollChannel',        'ai19', ...
            'sampleRate',         50, ...
            'runTimeMatrixFile',  fullfile(repoRoot, 'carriage_node', 'carriageNodeRunTimeMatrix.mat') ...
        ) ...
    );
else
    fprintf("[REAL] Loading config/carriage_computer.json.\n");
    machineConfig = jsondecode(fileread(fullfile(repoRoot, 'config', 'carriage_computer.json')));
    cfg           = machineConfig.carriageNode;
    cfg.brokerAddress = machineConfig.brokerAddress;
    cfg.brokerPort    = machineConfig.brokerPort;
    cfg.restPort      = machineConfig.restPort;
    cfg.verbose       = machineConfig.verbose;
end

% Build a minimal control-side config to publish commands
cfgCtrl = struct( ...
    'clientID',     controlID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort',    brokerPort, ...
    'restPort',      5000, ...
    'verbose',       false, ...
    'subscriptions', {{'carriageNode/status','carriageNode/data'}}, ...
    'publications',  {{'carriageNode/cmd'}} ...
);

% Create comm/rest clients
nodeComm = CommClient(cfg);
nodeRest = RestClient(cfg);
ctrlComm = CommClient(cfgCtrl);
ctrlRest = RestClient(cfgCtrl);  %#ok<NASGU>

% Instantiate node
if USE_MOCK
    node = MockCarriageNodeManager(cfg, nodeComm, nodeRest);
    % Set desired synthetic signal levels
    node.syntheticFT     = [1.0, 0.5, 10.0, 0.1, 0.2, 0.05];  % lb / lb-in
    node.syntheticMotion = [5.0, 2.0, 1.0];                     % mm
    node.noiseSigma      = 0.0005;
else
    node = CarriageNodeManager(cfg, nodeComm, nodeRest);
end

% Register callback
nodeComm.onMessageCallback = @(topic, msg) node.onMessageCallback(topic, msg);

% Helper to publish a command
nodeCmd = sprintf('%s/cmd', clientID);
function publish(comm, topic, s)
    comm.commPublish(topic, jsonencode(s));
    pause(0.15);
end

fprintf("Setup complete.\n");

% =========================================================================
%% T1 — Initialization
% =========================================================================
if RUN_TESTS.initialization
    fprintf("\n=== T1: Initialization ===\n");

    passed = string(node.getState()) == "IDLE";
    nPass = nPass + passed; nFail = nFail + ~passed;
    logResult(sprintf("Node boots to IDLE (actual: %s)", node.getState()), passed);
end

% =========================================================================
%% T2 — Force Bias Calibration
% =========================================================================
if RUN_TESTS.forceCalib
    fprintf("\n=== T2: Force Bias Calibration ===\n");

    if ~USE_MOCK
        input('[REAL] Attach test body to carriage. Press Enter to collect 1-second bias...');
    else
        fprintf("[MOCK] Using synthetic SG voltages (no user action required).\n");
    end

    publish(ctrlComm, nodeCmd, struct('cmd','Calibrate','params',struct('target','force_bias')));

    passed1 = string(node.getState()) == "IDLE";
    passed2 = isfile('calibrationGains.mat');
    passed3 = ~isempty(node.biasVoltages) && numel(node.biasVoltages) == 6;

    nPass = nPass + passed1; nFail = nFail + ~passed1;
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    nPass = nPass + passed3; nFail = nFail + ~passed3;

    logResult("Returns to IDLE after force_bias", passed1);
    logResult("calibrationGains.mat created", passed2);
    logResult("biasVoltages populated (1×6)", passed3);

    if passed3
        fprintf("  biasVoltages: [%s]\n", ...
            strjoin(arrayfun(@(v) sprintf("%.5f",v), node.biasVoltages,'UniformOutput',false), ', '));
    end
end

% =========================================================================
%% T3 — Motion Sensor Calibration
% =========================================================================
if RUN_TESTS.motionCalib
    fprintf("\n=== T3: Motion Sensor Calibration ===\n");

    channels = {'heave','pitch','roll'};
    % Two known positions per channel (mm)
    knownPositions = [2.5, 7.5;   % heave
                      1.0, 4.0;   % pitch
                      0.5, 3.0];  % roll

    for ci = 1:3
        ch = channels{ci};
        for pi_ = 1:2
            if ~USE_MOCK
                input(sprintf('[REAL] Move carriage to %s = %.1f mm. Press Enter...', ch, knownPositions(ci,pi_)));
            end
            publish(ctrlComm, nodeCmd, struct('cmd','Calibrate','params',struct( ...
                'target','motion_sensors', ...
                'channel', ch, ...
                'knownValue_mm', knownPositions(ci, pi_))));
        end
    end

    % Finalize
    publish(ctrlComm, nodeCmd, struct('cmd','Calibrate','params',struct( ...
        'target','motion_sensors','finished',true)));

    passed1 = string(node.getState()) == "IDLE";
    passed2 = isfile('motionCalibration.mat');
    passed3 = ~isempty(fieldnames(node.motionCalib)) && ...
              isfield(node.motionCalib,'heave') && ...
              isfield(node.motionCalib,'pitch') && ...
              isfield(node.motionCalib,'roll');

    nPass = nPass + passed1; nFail = nFail + ~passed1;
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    nPass = nPass + passed3; nFail = nFail + ~passed3;

    logResult("Returns to IDLE after motion calib", passed1);
    logResult("motionCalibration.mat created", passed2);
    logResult("motionCalib has heave/pitch/roll fields", passed3);
end

% =========================================================================
%% T4 — Sensor Test (live streaming)
% =========================================================================
if RUN_TESTS.sensorTest
    fprintf("\n=== T4: Sensor Test (streaming) ===\n");

    publish(ctrlComm, nodeCmd, struct('cmd','Test','params',struct('target','sensor')));

    passed1 = string(node.getState()) == "TESTINGSENSOR";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters TESTINGSENSOR", passed1);

    if ~USE_MOCK
        fprintf("[REAL] Observing live force data for 3 seconds...\n");
    else
        fprintf("[MOCK] Streaming synthetic force readings for 0.5 s...\n");
    end
    pause(0.5);   % allow a few published readings to accumulate

    % Reset back to IDLE
    publish(ctrlComm, nodeCmd, struct('cmd','Reset'));

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after Reset", passed2);
end

% =========================================================================
%% T5 — Single Run + Post-Processing
% =========================================================================
if RUN_TESTS.singleRun
    fprintf("\n=== T5: Single Run ===\n");

    if ~USE_MOCK
        input('[REAL] Position carriage for experiment. Press Enter to configure...');
    end

    experimentParams = struct( ...
        'name',     'CarriageTest_Single', ...
        'duration', 2.0, ...
        'frequency', 1.0 ...
    );

    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',experimentParams));

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters CONFIGUREPENDING after Run", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

    % Wait for IDLE (RUNNING → POSTPROC → DONE → IDLE)
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 15
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    passed3 = ~isempty(node.experimentData);
    passed4 = isfield(node.experimentData(1), 'Fx') && isfield(node.experimentData(1), 'Fz');
    passed5 = isfield(node.experimentData(1), 'Heave_mm') && isfield(node.experimentData(1), 'Sync');

    nPass = nPass + passed2; nFail = nFail + ~passed2;
    nPass = nPass + passed3; nFail = nFail + ~passed3;
    nPass = nPass + passed4; nFail = nFail + ~passed4;
    nPass = nPass + passed5; nFail = nFail + ~passed5;

    logResult("Returns to IDLE (RUNNING→POSTPROC→DONE→IDLE)", passed2);
    logResult("experimentData populated", passed3);
    logResult("Force fields present (Fx, Fz)", passed4);
    logResult("Motion and Sync fields present", passed5);

    % --- Plot output ---
    if ~isempty(node.experimentData)
        nTime    = [node.experimentData.nTime];
        Fx       = [node.experimentData.Fx];
        Fz       = [node.experimentData.Fz];
        Heave    = [node.experimentData.Heave_mm];
        Sync     = [node.experimentData.Sync];

        figure('Name','T5: Single Run Output');
        sgtitle('T5: Carriage Node Single Run');
        subplot(3,1,1); plot(nTime,Fx,'b',nTime,Fz,'r');
        legend('Fx','Fz'); ylabel('lb'); title('Force (filtered)'); grid on;
        subplot(3,1,2); plot(nTime,Heave,'g');
        ylabel('mm'); title('Heave (spline calibrated)'); grid on;
        subplot(3,1,3); plot(nTime,Sync,'k');
        ylabel('V'); title('Sync (filtered)'); grid on;
        xlabel('Time (s)');
    end
end

% =========================================================================
%% T6 — Multi-Experiment Run
% =========================================================================
if RUN_TESTS.multiRun
    fprintf("\n=== T6: Multi-Experiment Run ===\n");

    multiParams = struct( ...
        'name', 'CarriageTest_Multi', ...
        'experiments', [ ...
            struct('name','Slow_LongRun',  'duration', 2.0, 'frequency', 0.5), ...
            struct('name','Fast_ShortRun', 'duration', 1.0, 'frequency', 2.0), ...
            struct('name','Mid_MidRun',    'duration', 1.5, 'frequency', 1.0)  ...
        ] ...
    );

    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',multiParams));

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters CONFIGUREPENDING (multi)", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

    % Wait — 3 experiments, generous timeout
    totalDuration = 2.0 + 1.0 + 1.5 + 3.0;   % experiment time + processing headroom
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < totalDuration
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after all 3 sub-experiments", passed2);

    % Check that CSV files were created for each sub-experiment
    dataDir = fullfile(pwd, 'carriageNodeData', 'CarriageTest_Multi');
    expNames = {'Slow_LongRun','Fast_ShortRun','Mid_MidRun'};
    for i = 1:numel(expNames)
        csvPattern = fullfile(dataDir, sprintf('*%s*.csv', expNames{i}));
        files = dir(csvPattern);
        passed = ~isempty(files);
        nPass = nPass + passed; nFail = nFail + ~passed;
        logResult(sprintf("CSV saved for sub-experiment '%s'", expNames{i}), passed);
    end
end

% =========================================================================
%% T7 — Abort and Recovery
% =========================================================================
if RUN_TESTS.abortRecovery
    fprintf("\n=== T7: Abort and Recovery ===\n");

    % Start a long run so RUNNING state is reachable
    publish(ctrlComm, nodeCmd, struct('cmd','Run','params', ...
        struct('name','AbortTest','duration',60,'frequency',1)));

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Reaches CONFIGUREPENDING before abort", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

    % Wait for RUNNING, then abort
    timeout = tic;
    while string(node.getState()) ~= "RUNNING" && toc(timeout) < 3
        pause(0.05);
    end

    passed2 = string(node.getState()) == "RUNNING";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Enters RUNNING state", passed2);

    publish(ctrlComm, nodeCmd, struct('cmd','Abort','params', ...
        struct('reason','T7 abort test')));

    passed3 = string(node.getState()) == "ERROR";
    nPass = nPass + passed3; nFail = nFail + ~passed3;
    logResult("Transitions to ERROR after Abort", passed3);

    publish(ctrlComm, nodeCmd, struct('cmd','Reset'));

    passed4 = string(node.getState()) == "IDLE";
    nPass = nPass + passed4; nFail = nFail + ~passed4;
    logResult("Recovers to IDLE after Reset", passed4);
end

% =========================================================================
%% Cleanup & Summary
% =========================================================================
fprintf("\n=== SUMMARY ===\n");
fprintf("  PASS: %d\n", nPass);
fprintf("  FAIL: %d\n", nFail);
fprintf("  Total: %d\n", nPass + nFail);
if nFail == 0
    fprintf("  ✅ All tests passed.\n");
else
    fprintf("  ❌ %d test(s) failed — review output above.\n", nFail);
end

try
    node.shutdown();
catch ME
    warning(ME.identifier, '%s', ME.message);
end
try
    ctrlComm.disconnect();
catch ME
    warning(ME.identifier, '%s', ME.message);
end

fprintf("\nLog saved to: %s\n", diaryFile);
