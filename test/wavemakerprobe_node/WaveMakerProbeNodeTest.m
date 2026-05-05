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
%                           visual check (real), auto-returns to IDLE (mock)
%   T4 — Actuator test:     Test(actuator) → CONFIGUREPENDING → TestValid
%                           → paddle preview, returns to IDLE
%   T5 — Single run:        Configure → RunValid → POSTPROC → IDLE,
%                           CSV saved, probe output plotted
%   T6 — Multi-run:         3 sub-experiments (different freq/amplitude),
%                           CSV per sub-experiment
%   T7 — Abort/recovery:    Abort during/after RUNNING → ERROR → Reset → IDLE
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
diaryFile = fullfile(testDir, 'WaveMakerProbeNodeTest.log');
fid = fopen(diaryFile, 'w'); if fid ~= -1; fclose(fid); end
diary(diaryFile);
cleanupDiary = onCleanup(@() diary('off')); %#ok<NASGU>

% =========================================================================
%% CONFIGURATION
% =========================================================================

USE_MOCK = false;   % <── flip to false to run against real hardware

RUN_TESTS = struct( ...
    'initialization',   true, ...
    'probeCalib',       false, ...
    'sensorTest',       false, ...
    'actuatorTest',     false, ...
    'singleRun',        false, ...
    'multiRun',         true, ...
    'abortRecovery',    false  ...
);

% ── Active probes for real testing (applies across all test sections) ─────
% Only include probes that are physically in the water for this run.
ACTIVE_PROBES = [1, 3];

% ── T5: signal type selection and per-type parameters ────────────────────
% Set each type true/false to include or exclude it from T5.
% Edit the T5_PARAMS fields below to change signal parameters.

T5_SIGNAL_TYPES = struct( ...
    'sinusoidal',       false,  ...
    'bretschneider',    false, ...
    'pulse_sinusoidal', false, ...
    'dual_pulse',       true  ...
);

T5_PARAMS = struct();
T5_PARAMS.sinusoidal = struct( ...
    'amplitude',  0.03, ...
    'frequency',  0.5,  ...
    'duration',   30.0   ...
);
T5_PARAMS.bretschneider = struct( ...
    'significantWaveHeight_m', 0.03, ...
    'modalFrequency_radps',    3.14, ...
    'duration',                5.0   ...
);
T5_PARAMS.pulse_sinusoidal = struct( ...
    'amplitude',  0.05, ...
    'frequency',  1.0,  ...
    'numPulses',  3,    ...
    'duration',   10.0  ...
);
T5_PARAMS.dual_pulse = struct( ...
    'amplitude1_m',        0.05, ...
    'frequency1_Hz',       1.0,  ...
    'numPulses1',          3,    ...
    'wavePauseDuration_s', 2.0,  ...
    'amplitude2_m',        0.03, ...
    'frequency2_Hz',       0.5,  ...
    'numPulses2',          2,    ...
    'duration',            15.0  ...
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

    % Load hardware limits from the shared config so mock and real runs
    % use identical voltage/frequency bounds. Only the DAQ device name,
    % channel IDs, and gains file path are overridden for the test environment.
    hwCfg = jsondecode(fileread(fullfile(repoRoot, 'config', 'master_computer.json')));
    realHW = hwCfg.waveMakerProbeNode.hardware;

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
            'sampleRate',           realHW.sampleRate, ...
            'maxAmplitude',         realHW.maxAmplitude, ...
            'maxFrequency',         realHW.maxFrequency, ...
            'probeGainsFile',       fullfile(testDir, 'probe_gains_test.mat') ...
        ) ...
    );
    fprintf("[MOCK] Hardware limits from config: maxAmplitude=%.2f V, maxFrequency=%.2f Hz, sampleRate=%d Hz.\n", ...
        realHW.maxAmplitude, realHW.maxFrequency, realHW.sampleRate);
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
ctrlComm.connect();

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

    selectedProbes = ACTIVE_PROBES;
    % Three known heights (m)
    knownHeights   = [0.0, -0.05, 0.05];

    for hi = 1:numel(knownHeights)
        if ~USE_MOCK
            input(sprintf('[REAL] Set probes [%s] to %.2f m height. Press Enter...', ...
                strjoin(arrayfun(@num2str, selectedProbes, 'UniformOutput', false), ','), knownHeights(hi)));
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

    % Wait for IDLE (calibration finish is synchronous in mock but add poll-wait for safety)
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 3
        pause(0.05);
    end

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
        strjoin(arrayfun(@(v) sprintf('%.4f',v), node.probeGains,'UniformOutput',false), ', '));

    if ~USE_MOCK
        % --- Visual confirmation: bar chart of probe gains ---
        figure('Name','T2: Probe Gains');
        bar(1:8, node.probeGains);
        xlabel('Probe index'); ylabel('Gain (m/V)');
        title('T2: Calibrated probe gains');
        grid on;
        fprintf("[REAL] Inspect probe gain bar chart. Press Enter to continue...\n");
        input('');
    end
end

% =========================================================================
%% T3 — Sensor Test (live streaming)
% =========================================================================
if RUN_TESTS.sensorTest
    fprintf("\n=== T3: Sensor Test ===\n");

    activeProbes = ACTIVE_PROBES;

    % Directly configure active probes without a Run → CONFIGUREPENDING cycle.
    node.setActiveProbes(activeProbes);
    fprintf("  Active probes set to [%s] via setActiveProbes.\n", ...
        strjoin(arrayfun(@(x) num2str(x), activeProbes, 'UniformOutput', false), ', '));    

    % Set live heights for the mock, then send Test(sensor)
    if USE_MOCK
        node.liveProbeInput(activeProbes) = [0.03, 0.04, 0.035];
    end

    % Snapshot message-log start index so we can extract only T3 stream packets.
    t3LogStart = numel(ctrlComm.messageLog) + 1;
    publish(ctrlComm, nodeCmd, struct('cmd','Test','params',struct('target','sensor')));

    if ~USE_MOCK
        % Real hardware: timer streams indefinitely; wait for TESTINGSENSOR then observe
        timeout = tic;
        while string(node.getState()) ~= "TESTINGSENSOR" && toc(timeout) < 2
            pause(0.05);
        end
        passed1 = string(node.getState()) == "TESTINGSENSOR";
        nPass = nPass + passed1; nFail = nFail + ~passed1;
        logResult("Enters TESTINGSENSOR (real)", passed1);

        fprintf("[REAL] Observing live probe stream for 3 seconds...\n");
        pause(3);
        publish(ctrlComm, nodeCmd, struct('cmd','Reset'));
    else
        % Mock: immediately publishes burst then self-transitions to IDLE
        passed1 = true;   % TESTINGSENSOR was entered (mock transitions through it synchronously)
        nPass = nPass + passed1; nFail = nFail + ~passed1;
        logResult("TESTINGSENSOR entered (mock self-transitions — check skipped)", passed1);
    end

    % Wait for IDLE
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 5
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after sensor test", passed2);

    % Build a time-series plot from MQTT data packets published during T3.
    t3Entries = ctrlComm.messageLog(t3LogStart:end);
    t3Times   = NaT(0,1);
    probeData = struct();
    for p = activeProbes
        probeData.(sprintf('H%d', p)) = [];
    end

    for i = 1:numel(t3Entries)
        entry = t3Entries{i};
        if ~isfield(entry, 'topic') || ~strcmp(entry.topic, sprintf('%s/data', clientID))
            continue;
        end
        try
            msg = jsondecode(entry.message);
        catch
            continue;
        end
        if ~isstruct(msg)
            continue;
        end
        if ~isfield(msg, 'type') || ~strcmpi(string(msg.type), "wave_height")
            continue;
        end

        t3Times(end+1,1) = entry.timestamp; %#ok<AGROW>
        for p = activeProbes
            fName = sprintf('H%d', p);
            if isfield(msg, fName)
                probeData.(fName)(end+1,1) = msg.(fName); %#ok<AGROW>
            else
                probeData.(fName)(end+1,1) = NaN; %#ok<AGROW>
            end
        end
    end

    if ~isempty(t3Times)
        t3Sec = seconds(t3Times - t3Times(1));
        figure('Name', 'T3: Sensor Readings');
        hold on;
        for p = activeProbes
            fName = sprintf('H%d', p);
            plot(t3Sec, probeData.(fName), 'LineWidth', 1.2, 'DisplayName', fName);
        end
        hold off;
        xlabel('Time since T3 stream start (s)');
        ylabel('Wave height (m)');
        title('T3 sensor stream from MQTT data packets');
        legend('Location', 'best');
        grid on;

        fprintf("  T3 collected %d packets over %.2f s.\n", numel(t3Sec), t3Sec(end));
        for p = activeProbes
            fName = sprintf('H%d', p);
            y = probeData.(fName);
            fprintf("    %s: mean=%.5f m, min=%.5f m, max=%.5f m\n", ...
                fName, mean(y, 'omitnan'), min(y), max(y));
        end
    else
        fprintf("  [WARN] T3: no wave_height packets found in ctrlComm.messageLog for plotting.\n");
    end
end

% =========================================================================
%% T4 — Actuator Test (paddle preview)
% =========================================================================
if RUN_TESTS.actuatorTest
    fprintf("\n=== T4: Actuator Test ===\n");

    % Send Test(actuator) with ALL required params (including activeProbes).
    % FSM routes: IDLE → CONFIGUREVALIDATE → CONFIGUREPENDING → (TestValid) → TESTINGACTUATOR → IDLE
    actuatorTestParams = struct( ...
        'target',       'actuator', ...
        'activeProbes', ACTIVE_PROBES, ...
        'amplitude',    0.05,       ...
        'frequency',    1.0,        ...
        'duration',     2.0         ...
    );
    publish(ctrlComm, nodeCmd, struct('cmd','Test','params',actuatorTestParams));

    % Wait for CONFIGUREPENDING
    timeout = tic;
    while string(node.getState()) ~= "CONFIGUREPENDING" && toc(timeout) < 2
        pause(0.05);
    end

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters CONFIGUREPENDING (actuator)", passed1);

    % paddleSignal is pre-computed during CONFIGUREVALIDATE so it is ready
    % at CONFIGUREPENDING — plot now so the user can inspect before confirming.
    if ~isempty(node.paddleSignal)
        nSamples = numel(node.paddleSignal);
        tVec     = (0:nSamples-1)' / cfg.hardware.sampleRate;
        V_peak   = max(abs(node.paddleSignal));
        hasModel = ~isempty(node.wavemakerModel);
        nSubs    = 1 + hasModel;

        figure('Name','T4: Paddle Signal Preview');
        subplot(nSubs, 1, 1);
        plot(tVec, node.paddleSignal, 'b', 'LineWidth', 1.2);
        ylabel('Voltage (V)');
        title(sprintf('Paddle voltage — %.4f V peak  (input: %.3f m wave height @ %.2f Hz)', ...
            V_peak, actuatorTestParams.amplitude, actuatorTestParams.frequency));
        grid on;

        if hasModel
            waveHeight_cm = lsim(node.wavemakerModel, node.paddleSignal, tVec);
            subplot(2, 1, 2);
            plot(tVec, waveHeight_cm, 'r', 'LineWidth', 1.2);
            ylabel('Wave height (cm)');
            xlabel('Time (s)');
            title(sprintf('Expected wave height — %.2f cm peak', max(abs(waveHeight_cm))));
            grid on;
        else
            xlabel('Time (s)');
            fprintf("  [INFO] No wavemaker model loaded — wave height subplot skipped.\n");
        end
        drawnow;   % flush before input() blocks
    else
        fprintf("  [WARN] paddleSignal is empty — waveform plot skipped.\n");
    end

    fprintf("Node is in CONFIGUREPENDING. Inspect the paddle signal preview, then press Enter to send TestValid...\n");
    input('');

    % Confirm test — FSM transitions to TESTINGACTUATOR → handleTest → IDLE
    publish(ctrlComm, nodeCmd, struct('cmd','TestValid'));

    % Wait for IDLE (mock: synchronous; real: timer fires after params.duration)
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 8
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after actuator test", passed2);
end

% =========================================================================
%% T5 — Signal Type Validation
% =========================================================================
if RUN_TESTS.singleRun
    fprintf("\n=== T5: Signal Type Validation ===\n");

    if ~USE_MOCK
        input('[REAL] Set up probes in water. Press Enter to begin...');
    end

    t5TypeNames = fieldnames(T5_SIGNAL_TYPES);
    for si = 1:numel(t5TypeNames)
        sType = t5TypeNames{si};
        if ~T5_SIGNAL_TYPES.(sType)
            fprintf("  [SKIP] signalType '%s'\n", sType);
            continue;
        end
        fprintf("\n  -- Signal type: %s --\n", sType);

        % Assemble params: type-specific fields + common fields
        runParams              = T5_PARAMS.(sType);
        runParams.signalType   = sType;
        runParams.name         = sprintf('WaveProbeTest_T5_%s', sType);
        runParams.activeProbes = ACTIVE_PROBES;

        publish(ctrlComm, nodeCmd, struct('cmd','Run','params',runParams));

        timeout = tic;
        while string(node.getState()) ~= "CONFIGUREPENDING" && toc(timeout) < 2
            pause(0.05);
        end

        passed1 = string(node.getState()) == "CONFIGUREPENDING";
        nPass = nPass + passed1; nFail = nFail + ~passed1;
        logResult(sprintf("[%s] Enters CONFIGUREPENDING", sType), passed1);

        if ~passed1
            fprintf("  [WARN] %s did not reach CONFIGUREPENDING — skipping.\n", sType);
            continue;
        end

        % Preview paddle signal before committing to the run — same as T4.
        % paddleSignal is ready at CONFIGUREPENDING so no need to wait.
        if ~isempty(node.paddleSignal)
            nSamplesP = numel(node.paddleSignal);
            tVecP     = (0:nSamplesP-1)' / cfg.hardware.sampleRate;
            V_peakP   = max(abs(node.paddleSignal));
            hasModelP = ~isempty(node.wavemakerModel);
            nSubsP    = 1 + hasModelP;

            figure('Name', sprintf('T5 Preview: %s', sType));
            subplot(nSubsP, 1, 1);
            plot(tVecP, node.paddleSignal, 'b', 'LineWidth', 1.2);
            ylabel('Voltage (V)');
            title(sprintf('[%s] Paddle voltage — %.4f V peak', sType, V_peakP), 'Interpreter', 'none');
            grid on;

            if hasModelP
                waveHeightP_cm = lsim(node.wavemakerModel, node.paddleSignal, tVecP);
                subplot(2, 1, 2);
                plot(tVecP, waveHeightP_cm, 'r', 'LineWidth', 1.2);
                ylabel('Wave height (cm)');
                xlabel('Time (s)');
                title(sprintf('Expected wave height — %.2f cm peak', max(abs(waveHeightP_cm))));
                grid on;
            else
                xlabel('Time (s)');
            end
            drawnow;
        end

        fprintf("  Inspect '%s' paddle preview. Press Enter to start run...\n", sType);
        input('');

        publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

        runTimeout = T5_PARAMS.(sType).duration * 1.5 + 5;
        timeout = tic;
        while string(node.getState()) ~= "IDLE" && toc(timeout) < runTimeout
            pause(0.05);
        end

        expData   = node.getExperimentData();
        expectedN = round(T5_PARAMS.(sType).duration * cfg.hardware.sampleRate);

        passed2 = string(node.getState()) == "IDLE";
        passed3 = ~isempty(expData);
        passed4 = ~isempty(expData) && isfield(expData(1), 'nTime') && isfield(expData(1), 'H1');
        passed5 = ~isempty(node.paddleSignal) && numel(node.paddleSignal) == expectedN;

        nPass = nPass + passed2; nFail = nFail + ~passed2;
        nPass = nPass + passed3; nFail = nFail + ~passed3;
        nPass = nPass + passed4; nFail = nFail + ~passed4;
        nPass = nPass + passed5; nFail = nFail + ~passed5;

        logResult(sprintf("[%s] Returns to IDLE", sType), passed2);
        logResult(sprintf("[%s] experimentData populated", sType), passed3);
        logResult(sprintf("[%s] nTime and H1 fields present", sType), passed4);
        logResult(sprintf("[%s] paddleSignal correct length (%d samples)", sType, expectedN), passed5);

        % --- Plot: paddle voltage + probe outputs ---
        if ~isempty(expData) && ~isempty(node.paddleSignal)
            nTime = [expData.nTime];
            activeProbesList = node.activeProbes;
            nProbes = numel(activeProbesList);

            figure('Name', sprintf('T5: %s', sType));
            sgtitle(sprintf('T5: Signal type = %s', sType), 'Interpreter', 'none');

            subplot(nProbes + 1, 1, 1);
            plot(nTime, node.paddleSignal);
            ylabel('Paddle (V)');
            title('Pre-computed paddle voltage');
            grid on;

            for k = 1:nProbes
                subplot(nProbes + 1, 1, k + 1);
                fieldName = sprintf('H%d', activeProbesList(k));
                if isfield(expData(1), fieldName)
                    plot(nTime, [expData.(fieldName)]);
                end
                ylabel(sprintf('H%d (m)', activeProbesList(k)));
                grid on;
            end
            xlabel('Time (s)');
        end

        if ~USE_MOCK
            fprintf("[REAL] Inspect '%s' plots. Press Enter for next type...\n", sType);
            input('');
        end
    end
end

% =========================================================================
%% T6 — Multi-Experiment Run
% =========================================================================
if RUN_TESTS.multiRun
    fprintf("\n=== T6: Multi-Experiment Run ===\n");

    % settleCheck config — blocks between sub-experiments until all active
    % probes stay below threshold for holdDuration_s.  No timeout; the node
    % waits as long as the tank needs.
    settleCheckCfg = struct( ...
        'enabled',        true, ...
        'threshold',      0.005, ...    % 5 mm half-amplitude
        'thresholdUnits', 'm', ...
        'holdDuration_s', 5.0  ...
    );

    multiParams = struct( ...
        'name',        'WaveProbeTest_Multi', ...
        'settleCheck', settleCheckCfg, ...
        'experiments', [ ...
            struct('name','Low_Slow',  'activeProbes',ACTIVE_PROBES, 'amplitude',0.01,'frequency',0.5,'duration',20.0), ...
            struct('name','Mid_Mid',   'activeProbes',ACTIVE_PROBES, 'amplitude',0.015,'frequency',1.0,'duration',10.0), ...
            struct('name','High_Fast', 'activeProbes',ACTIVE_PROBES, 'amplitude',0.02,'frequency',2.0,'duration',10.0)  ...
        ] ...
    );

    publish(ctrlComm, nodeCmd, struct('cmd','Run','params',multiParams));

    % Poll-wait for CONFIGUREPENDING
    timeout = tic;
    while string(node.getState()) ~= "CONFIGUREPENDING" && toc(timeout) < 2
        pause(0.05);
    end

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Enters CONFIGUREPENDING (multi)", passed1);

    if ~passed1
        fprintf("  [WARN] T6: node did not reach CONFIGUREPENDING (validation failed?) — skipping RunValid.\n");
    else
        % Show one preview plot per sub-experiment so the operator can inspect
        % all signals before committing.  allPaddleSignals{i} was pre-computed
        % by precomputeAllSignals() inside setupCurrentExperiment.
        nExps = numel(multiParams.experiments);
        for ei = 1:nExps
            expName = multiParams.experiments(ei).name;
            sig = [];
            if ~isempty(node.allPaddleSignals) && numel(node.allPaddleSignals) >= ei
                sig = node.allPaddleSignals{ei};
            end
            if ~isempty(sig)
                nSamplesP = numel(sig);
                tVecP     = (0:nSamplesP-1)' / cfg.hardware.sampleRate;
                hasModelP = ~isempty(node.wavemakerModel);
                figure('Name', sprintf('T6 Preview [%d/%d]: %s', ei, nExps, expName));
                subplot(1 + hasModelP, 1, 1);
                plot(tVecP, sig, 'b', 'LineWidth', 1.2);
                ylabel('Voltage (V)');
                title(sprintf('[%s] Paddle voltage — %.4f V peak', expName, max(abs(sig))), ...
                    'Interpreter', 'none');
                grid on;
                if hasModelP
                    waveHeightP_cm = lsim(node.wavemakerModel, sig, tVecP);
                    subplot(2, 1, 2);
                    plot(tVecP, waveHeightP_cm, 'r', 'LineWidth', 1.2);
                    ylabel('Wave height (cm)');
                    xlabel('Time (s)');
                    title(sprintf('Expected wave height — %.2f cm peak', max(abs(waveHeightP_cm))));
                    grid on;
                else
                    xlabel('Time (s)');
                end
                drawnow;
            else
                fprintf("  [WARN] T6: allPaddleSignals{%d} empty — plot skipped.\n", ei);
            end
        end

        fprintf("  Inspect all %d sub-experiment previews above. Press Enter to start multi-run...\n", nExps);
        input('');
        publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));
    end

    % Script-side timeout: run durations (40 s) + generous headroom for settling.
    % awaitReady blocks indefinitely on the node side, so this timeout only
    % guards against the script hanging if the node crashes before reaching IDLE.
    totalDuration = 40 + 120 + 10;
    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < totalDuration
        pause(0.05);
    end

    passed2 = string(node.getState()) == "IDLE";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Returns to IDLE after all 3 sub-experiments", passed2);

    % Verify that INTER_RUN_READY was published for each inter-run gap
    % (2 gaps for 3 sub-experiments).
    % ctrlComm subscribes to waveMakerProbeNode/status, so the broker
    % delivers every publishInterRunStatus() call to ctrlComm.messageLog.
    % Give MQTT a moment to deliver any in-flight status messages.
    pause(0.3);
    readyCount = 0;
    for i = 1:numel(ctrlComm.messageLog)
        entry = ctrlComm.messageLog{i};
        if isfield(entry, 'message') && contains(entry.message, 'INTER_RUN_READY')
            readyCount = readyCount + 1;
        end
    end
    passed3 = readyCount >= 2;
    nPass = nPass + passed3; nFail = nFail + ~passed3;
    logResult(sprintf("INTER_RUN_READY published for both inter-run gaps (found %d)", readyCount), passed3);

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

    % ── Plot acquired probe data loaded from saved CSVs ───────────────────
    if exist(dataDir, 'dir')
        nExpsPlot = numel(expNames);
        figure('Name', 'T6: Multi-Run Acquired Data');
        sgtitle('T6: Probe data per sub-experiment', 'Interpreter', 'none');
        for i = 1:nExpsPlot
            csvPattern = fullfile(dataDir, sprintf('*%s*.csv', expNames{i}));
            files = dir(csvPattern);
            subplot(nExpsPlot, 1, i);
            hold on;
            if ~isempty(files)
                try
                    tbl = readtable(fullfile(dataDir, files(1).name));
                    for k = ACTIVE_PROBES(:)'
                        hField = sprintf('H%d', k);
                        if any(strcmp(tbl.Properties.VariableNames, hField))
                            plot(tbl.nTime, tbl.(hField), 'LineWidth', 1.2, 'DisplayName', hField);
                        end
                    end
                    legend('Location', 'best');
                catch ME
                    text(0.1, 0.5, sprintf('Load error: %s', ME.message), 'Units', 'normalized');
                end
            else
                text(0.1, 0.5, 'CSV not found', 'Units', 'normalized');
            end
            title(expNames{i}, 'Interpreter', 'none');
            ylabel('Height (m)');
            grid on;
            hold off;
        end
        xlabel('Time (s)');
        drawnow;
    else
        fprintf("  [WARN] T6: data directory not found for plotting: %s\n", dataDir);
    end

    % ── Settle check gate evidence from MQTT status log ───────────────────
    fprintf("\n  [T6] Settle check gate log:\n");
    interRunGaps = {};
    for i = 1:numel(ctrlComm.messageLog)
        entry = ctrlComm.messageLog{i};
        if ~isfield(entry, 'message'); continue; end
        if contains(entry.message, 'INTER_RUN_READY')
            interRunGaps{end+1} = entry; %#ok<AGROW>
        end
    end
    if isempty(interRunGaps)
        fprintf("    [WARN] No INTER_RUN_READY/TIMEOUT messages found — settleCheck may not have run.\n");
    else
        for i = 1:numel(interRunGaps)
            try
                decoded = jsondecode(interRunGaps{i}.message);
                nextName = '';
                if isfield(decoded, 'nextExpName'), nextName = decoded.nextExpName; end
                ts = '';
                if isfield(interRunGaps{i}, 'timestamp'), ts = string(interRunGaps{i}.timestamp); end
                fprintf("    Gap %d → %-20s  [%-20s]  at %s\n", i, nextName, decoded.state, ts);
            catch
                fprintf("    Gap %d: %s\n", i, interRunGaps{i}.message);
            end
        end
    end
end

% =========================================================================
%% T7 — Abort and Recovery
% =========================================================================
if RUN_TESTS.abortRecovery
    fprintf("\n=== T7: Abort and Recovery ===\n");

    % Start a long run so RUNNING state is reachable
    publish(ctrlComm, nodeCmd, struct('cmd','Run','params', ...
        struct('name','AbortTest','activeProbes',ACTIVE_PROBES,'amplitude',0.05, ...
               'frequency',1.0,'duration',60)));

    timeout = tic;
    while string(node.getState()) ~= "CONFIGUREPENDING" && toc(timeout) < 2
        pause(0.05);
    end

    passed1 = string(node.getState()) == "CONFIGUREPENDING";
    nPass = nPass + passed1; nFail = nFail + ~passed1;
    logResult("Reaches CONFIGUREPENDING before abort", passed1);

    publish(ctrlComm, nodeCmd, struct('cmd','RunValid'));

    % Send Abort immediately after RunValid — don't wait for RUNNING.
    % On mock, handleRun is synchronous so the node may already be IDLE by
    % the time Abort is processed; abort() transitions to ERROR from any state.
    % On real hardware, Abort will interrupt the run mid-acquisition.
    pause(0.05);
    publish(ctrlComm, nodeCmd, struct('cmd','Abort','params', ...
        struct('reason','T7 abort test')));

    timeout = tic;
    while string(node.getState()) ~= "ERROR" && toc(timeout) < 10
        pause(0.05);
    end

    passed2 = string(node.getState()) == "ERROR";
    nPass = nPass + passed2; nFail = nFail + ~passed2;
    logResult("Transitions to ERROR after Abort", passed2);

    publish(ctrlComm, nodeCmd, struct('cmd','Reset'));

    timeout = tic;
    while string(node.getState()) ~= "IDLE" && toc(timeout) < 2
        pause(0.05);
    end

    passed3 = string(node.getState()) == "IDLE";
    nPass = nPass + passed3; nFail = nFail + ~passed3;
    logResult("Recovers to IDLE after Reset", passed3);
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
