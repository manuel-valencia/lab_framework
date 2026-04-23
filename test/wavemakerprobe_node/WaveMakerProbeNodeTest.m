% =========================================================================
% WaveMakerProbeNodeTest.m
%
% Test script for WaveMakerProbeNodeManager (and MockWaveMakerProbeNodeManager).
%
% SET USE_MOCK = true  to run against synthetic data (no hardware needed).
%                      Validates FSM routing, calibration polyfit, gain
%                      apply, mean-centering, multi-experiment sequencing.
%
% SET USE_MOCK = false to run against the real NI-DAQ hardware.
%                      All MQTT command sections are identical; hardware
%                      sections pause for user prompts instead.
%
% TEST OBJECTIVES
% ---------------
%   T1 — Initialization:   node boots to IDLE, hardware initializes
%   T2 — Probe calibration: multi-point Calibrate per selectedProbes
%                           → polyfit gains saved, returns to IDLE
%   T3 — Sensor test:       Test(sensor) → streams live H1..HN readings,
%                           visual check, Reset → IDLE
%   T4 — Actuator test:     Test(actuator) → paddle preview, returns IDLE
%   T5 — Single run:        Configure → RunValid → POSTPROC → IDLE,
%                           CSV saved, probe output plotted
%   T6 — Multi-run:         3 sub-experiments (different freq/amplitude),
%                           CSV per sub-experiment
%   T7 — Abort/recovery:    Abort during RUNNING → ERROR → Reset → IDLE
%
% PREREQUISITES (USE_MOCK = false)
% ---------------------------------
%   - Mosquitto broker running (network/mosquitto.conf)
%   - REST server running     (python network/RestServer.py)
%   - config/master_computer.json filled in
%   - NI-DAQ device connected, wave probes wired to ai0-ai7, paddle to ao0
%
% PREREQUISITES (USE_MOCK = true)
% --------------------------------
%   - Mosquitto broker running
%   - REST server running
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
addpath(genpath(fullfile(repoRoot, 'waveMakerProbe_node')));
addpath(genpath(testDir));

% ── DIARY ─────────────────────────────────────────────────────────────────
ts = char(datetime('now','Format','yyyyMMdd-HHmmss'));
diaryFile = fullfile(testDir, sprintf('WaveMakerProbeNodeTest_%s.log', ts));
fid = fopen(diaryFile, 'w'); if fid ~= -1; fclose(fid); end
diary(diaryFile);
cleanupDiary = onCleanup(@() diary('off')); %#ok<NASGU>

% =========================================================================
%% CONFIGURATION
% =========================================================================

USE_MOCK = true;   % <── flip to false to run against real hardware

RUN_TESTS = struct( ...
    'initialization',   true, ...
    'probeCalib',       true, ...
    'sensorTest',       true, ...
    'actuatorTest',     true, ...
    'singleRun',        true, ...
    'multiRun',         true, ...
    'abortRecovery',    true  ...
);

% Counters for final summary
nPass = 0;
nFail = 0;

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

brokerAddress  = 'localhost';
brokerPort     = 1883;
clientID       = 'waveMakerProbeNode';
controlID      = 'controlNode';

if USE_MOCK
    fprintf("[MOCK] Building inline test config (no hardware).\n");

    cfg = struct( ...
        'clientID',     clientID, ...
        'brokerAddress', brokerAddress, ...
        'brokerPort',    brokerPort, ...
        'restPort',      5000, ...
        'verbose',       true, ...
        'subscriptions', {{'waveMakerProbeNode/cmd'}}, ...
        'publications',  {{'waveMakerProbeNode/status','waveMakerProbeNode/data','waveMakerProbeNode/log'}}, ...
        'hardware', struct( ...
            'hasSensor',            true, ...
            'hasActuator',          true, ...
            'daqDevice',            'Dev1', ...
            'allProbeChannels',     {{'ai0','ai1','ai2','ai3','ai4','ai5','ai6','ai7'}}, ...
            'paddleOutputChannel',  'ao0', ...
            'sampleRate',           100, ...
            'maxAmplitude',         0.3, ...
            'maxFrequency',         2.3, ...
            'probeGainsFile',       fullfile(testDir, 'probe_gains_test.mat') ...
        ) ...
    );
else
    fprintf("[REAL] Loading config/master_computer.json.\n");
    machineConfig = jsondecode(fileread(fullfile(repoRoot, 'config', 'master_computer.json')));
    cfg           = machineConfig.waveMakerProbeNode;
    cfg.brokerAddress = machineConfig.brokerAddress;
    cfg.brokerPort    = machineConfig.brokerPort;
    cfg.restPort      = machineConfig.restPort;
    cfg.verbose       = machineConfig.verbose;
end

% Control-side client
cfgCtrl = struct( ...
    'clientID',     controlID, ...
    'brokerAddress', brokerAddress, ...
    'brokerPort',    brokerPort, ...
    'restPort',      5000, ...
    'verbose',       false, ...
    'subscriptions', {{'waveMakerProbeNode/status','waveMakerProbeNode/data'}}, ...
    'publications',  {{'waveMakerProbeNode/cmd'}} ...
);

nodeComm = CommClient(cfg);
nodeRest = RestClient(cfg);
ctrlComm = CommClient(cfgCtrl);
ctrlRest = RestClient(cfgCtrl); %#ok<NASGU>

if USE_MOCK
    node = MockWaveMakerProbeNodeManager(cfg, nodeComm, nodeRest);
    node.noiseSigma = 0.001;
    % Default liveProbeInput (set per test section as needed)
    node.liveProbeInput = zeros(1, 8);
else
    node = WaveMakerProbeNodeManager(cfg, nodeComm, nodeRest);
end

nodeComm.onMessageCallback = @(topic, msg) node.onMessageCallback(topic, msg);

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
%% T2 — Probe Gain Calibration
% =========================================================================
if RUN_TESTS.probeCalib
    fprintf("\n=== T2: Probe Gain Calibration ===\n");

    selectedProbes = [1, 2, 3];
    % Three known heights (m)
    knownHeights   = [0.02, 0.05, 0.10];

    for hi = 1:numel(knownHeights)
        if ~USE_MOCK
            input(sprintf('[REAL] Set probes [1,2,3] to %.2f m height. Press Enter...', knownHeights(hi)));
        else
            % Set synthetic "water height" for active probes
            node.liveProbeInput(selectedProbes) = knownHeights(hi);
        end

        params = struct('knownHeight_m', knownHeights(hi));
        if hi == 1
            params.selectedProbes = selectedProbes;
        end
        publish(ctrlComm, nodeCmd, struct('cmd','Calibrate','params',params));
    end

    % Finalize
    publish(ctrlComm, nodeCmd, struct('cmd','Calibrate','params',struct('finished',true)));

    passed1 = string(node.getState()) == "IDLE";
    passed2 = isfile(cfg.hardware.probeGainsFile);
    passed3 = ~all(node.probeGains == 1.0);   % gains should have changed from default

    nPass = nPass + passed1; nFail = nFail + ~passed1;
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    nPass = nPass + passed3; nFail = nFail + ~passed3;

    logResult("Returns to IDLE after calibration", passed1);
    logResult("probe_gains.mat saved", passed2);
    logResult("probeGains updated from default 1.0", passed3);

    fprintf("  probeGains: [%s]\n", ...
        strjoin(arrayfun(@(v) sprintf("%.4f",v), node.probeGains,'UniformOutput',false), ', '));
end

% =========================================================================
%% T3 — Sensor Test (live streaming)
% =========================================================================
if RUN_TESTS.sensorTest
    fprintf("\n=== T3: Sensor Test ===\n");

    activeProbes = [1, 2, 3];
    configParams = struct( ...
        'activeProbes', activeProbes, ...
        'amplitude',    0.05, ...
        'frequency',    1.0,  ...
        'duration',     5.0   ...
    );
    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',configParams));

    if string(node.getState()) == "CONFIGUREPENDING"
        % Don't start the run — just use the configured state to test sensor test
        % Reset back to IDLE first, then send the Test command
        publish(ctrlComm, nodeCmd, struct('cmd','Reset'));
    end

    % Configure via Run→Reset to set activeProbes, then Test
    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',configParams));
    passed_cfg = string(node.getState()) == "CONFIGUREPENDING";
    publish(ctrlComm, nodeCmd, struct('cmd','Reset'));

    publish(ctrlComm, nodeCmd, struct('cmd','Test','params',struct('target','sensor')));

    passed1 = string(node.getState()) == "TESTINGSENSOR";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters TESTINGSENSOR", passed1);

    if USE_MOCK
        % Set some non-zero heights for visual check
        node.liveProbeInput(activeProbes) = [0.03, 0.04, 0.035];
        fprintf("[MOCK] Streaming synthetic probe data for 0.5 s...\n");
    else
        fprintf("[REAL] Observing live probe data for 3 seconds...\n");
    end
    pause(0.5);

    publish(ctrlComm, nodeCmd, struct('cmd','Reset'));

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after Reset", passed2);
end

% =========================================================================
%% T4 — Actuator Test (paddle preview)
% =========================================================================
if RUN_TESTS.actuatorTest
    fprintf("\n=== T4: Actuator Test ===\n");

    testParams = struct( ...
        'target',    'actuator', ...
        'amplitude', 0.05, ...
        'frequency', 1.0,  ...
        'duration',  2.0   ...
    );
    publish(ctrlComm, nodeCmd, struct('cmd','Run','params', struct( ...
        'activeProbes', [1,2,3], 'amplitude', 0.05, 'frequency', 1.0, 'duration', 5.0)));

    passed_cfg2 = string(node.getState()) == "CONFIGUREPENDING";
    if ~passed_cfg2
        fprintf("  [WARN] Node did not reach CONFIGUREPENDING — actuator test may fail.\n");
    end

    publish(ctrlComm, nodeCmd, struct('cmd','Reset'));  % clear pending config

    % Send Test(actuator) directly — FSM routes through CONFIGUREVALIDATE
    publish(ctrlComm, nodeCmd, struct('cmd','Test','params',testParams));

    % Wait for IDLE (actuator test is short)
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 5
        pause(0.05);
    end

    passed = string(node.getState()) == "IDLE";
    nPass = nPass + passed; nFail = nFail + ~passed;
    logResult("Returns to IDLE after actuator test", passed);
end

% =========================================================================
%% T5 — Single Run
% =========================================================================
if RUN_TESTS.singleRun
    fprintf("\n=== T5: Single Run ===\n");

    if ~USE_MOCK
        input('[REAL] Set up probes in water. Press Enter to begin...');
    end

    experimentParams = struct( ...
        'name',         'WaveProbeTest_Single', ...
        'activeProbes', [1, 2, 3], ...
        'amplitude',    0.05, ...
        'frequency',    1.0,  ...
        'duration',     2.0   ...
    );

    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',experimentParams));

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters CONFIGUREPENDING", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

    % Wait for IDLE
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 15
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    passed3 = ~isempty(node.experimentData);
    passed4 = isfield(node.experimentData(1), 'nTime') && isfield(node.experimentData(1), 'H1');

    nPass = nPass + passed2; nFail = nFail + ~passed2;
    nPass = nPass + passed3; nFail = nFail + ~passed3;
    nPass = nPass + passed4; nFail = nFail + ~passed4;

    logResult("Returns to IDLE (RUNNING→POSTPROC→DONE→IDLE)", passed2);
    logResult("experimentData populated", passed3);
    logResult("nTime and H1 fields present", passed4);

    % --- Plot output ---
    if ~isempty(node.experimentData)
        nTime = [node.experimentData.nTime];
        figure('Name','T5: Single Run Output');
        sgtitle('T5: WaveMakerProbe Single Run');
        activeProbesList = node.activeProbes;
        nProbes = numel(activeProbesList);
        for k = 1:nProbes
            subplot(nProbes, 1, k);
            fieldName = sprintf('H%d', activeProbesList(k));
            if isfield(node.experimentData(1), fieldName)
                Hk = [node.experimentData.(fieldName)];
                plot(nTime, Hk);
                ylabel(sprintf('H%d (m)', activeProbesList(k)));
                grid on;
            end
        end
        xlabel('Time (s)');
    end
end

% =========================================================================
%% T6 — Multi-Experiment Run
% =========================================================================
if RUN_TESTS.multiRun
    fprintf("\n=== T6: Multi-Experiment Run ===\n");

    multiParams = struct( ...
        'name', 'WaveProbeTest_Multi', ...
        'experiments', [ ...
            struct('name','Low_Slow',  'activeProbes',[1,2,3], 'amplitude',0.02,'frequency',0.5,'duration',1.5), ...
            struct('name','Mid_Mid',   'activeProbes',[1,2,3], 'amplitude',0.05,'frequency',1.0,'duration',1.0), ...
            struct('name','High_Fast', 'activeProbes',[1,2,3], 'amplitude',0.08,'frequency',2.0,'duration',1.0)  ...
        ] ...
    );

    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',multiParams));

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters CONFIGUREPENDING (multi)", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

    totalDuration = 1.5 + 1.0 + 1.0 + 3.0;
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < totalDuration
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after all 3 sub-experiments", passed2);

    % Check CSV files
    dataDir  = fullfile(pwd, 'waveMakerProbeNodeData', 'WaveProbeTest_Multi');
    expNames = {'Low_Slow','Mid_Mid','High_Fast'};
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

    publish(ctrlComm, nodeCmd, struct('cmd','Run','params', struct( ...
        'name','AbortTest','activeProbes',[1,2],'amplitude',0.05, ...
        'frequency',1.0,'duration',60)));

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Reaches CONFIGUREPENDING before abort", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

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
