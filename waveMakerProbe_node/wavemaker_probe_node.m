% =========================================================================
% wavemaker_probe_node.m
%
% Top-level headless launcher for the combined wave paddle + wave probe node.
% Runs on the master computer alongside the control node.
%
% USAGE (called by updater/pull_and_deploy.sh):
%   matlab -batch "wavemaker_probe_node('config/master_computer.json', 'master_computer')"
%
% The config file is the machine-level JSON (see config/master_computer.json.example).
% The profile key selects the waveMakerProbeNode section from that file.
%
% All shared MATLAB framework code lives in matlabCommon/.
% Writes a timestamped log file to logs/.
% =========================================================================
function wavemaker_probe_node(cfgFile, profile)
    arguments
        cfgFile (1,1) string   % e.g. "config/master_computer.json"
        profile (1,1) string   % e.g. "master_computer"
    end

    %% 0. Bootstrap — paths and logging
    repoRoot = fileparts(mfilename('fullpath'));
    addpath(genpath(fullfile(repoRoot, '..', 'matlabCommon')));

    logDir = fullfile(repoRoot, '..', 'logs');
    if ~isfolder(logDir); mkdir(logDir); end

    ts = char(datetime("now", 'Format', 'yyyyMMdd-HHmmss'));
    diary(fullfile(logDir, "wavemaker_probe_node_" + ts + ".txt"));
    cleanupDiary = onCleanup(@() diary('off'));

    fprintf("[INFO] WaveMakerProbeNode booting...  %s\n", ts);

    %% 1. Load configuration
    machineConfig = jsondecode(fileread(cfgFile));
    fprintf("[INFO] Loaded machine config from %s (profile: %s)\n", cfgFile, profile);

    if ~isfield(machineConfig, 'waveMakerProbeNode')
        error("[ERROR] Config file is missing 'waveMakerProbeNode' section.");
    end

    % Merge top-level broker settings with node-specific settings
    cfg = machineConfig.waveMakerProbeNode;
    if ~isfield(cfg, 'brokerAddress');  cfg.brokerAddress = machineConfig.brokerAddress;  end
    if ~isfield(cfg, 'brokerPort');     cfg.brokerPort    = machineConfig.brokerPort;     end
    if ~isfield(cfg, 'restPort');       cfg.restPort      = machineConfig.restPort;       end
    if ~isfield(cfg, 'verbose');        cfg.verbose       = machineConfig.verbose;        end

    %% 2. Validate required fields
    requiredFields = ["clientID", "brokerAddress", "hardware"];
    for field = requiredFields
        if ~isfield(cfg, field)
            error("[ERROR] Missing required config field: %s", field);
        end
    end

    if ~isfield(cfg.hardware, 'hasActuator') || ~cfg.hardware.hasActuator
        error("[ERROR] waveMakerProbeNode requires hardware.hasActuator = true.");
    end
    if ~isfield(cfg.hardware, 'hasSensor') || ~cfg.hardware.hasSensor
        error("[ERROR] waveMakerProbeNode requires hardware.hasSensor = true.");
    end

    %% 3. Initialise communication and FSM manager
    comm = CommClient(cfg);
    rest = RestClient(cfg);
    mgr  = WaveMakerProbeNodeManager(cfg, comm, rest);

    %% 4. Wire MQTT message callback
    comm.onMessageCallback = @(topic, msg) mgr.onMessageCallback(topic, msg);

    %% 5. Graceful shutdown on exit
    finalizer = onCleanup(@() shutdownNode(comm, mgr));

    %% 6. Main event loop — blocks here; all work is done in MQTT callbacks
    fprintf("[INFO] WaveMakerProbeNode online. Waiting for commands...\n");
    while comm.connected
        pause(0.001);
    end
    fprintf("[INFO] WaveMakerProbeNode: broker connection lost. Shutting down.\n");
end

% -------------------------------------------------------------------------
function shutdownNode(comm, mgr)
    try
        mgr.shutdown();
    catch ME
        warning(ME.identifier, '%s', ME.message);
    end
    try
        comm.disconnect();
    catch ME
        warning(ME.identifier, '%s', ME.message);
    end
end
