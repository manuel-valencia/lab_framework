% =========================================================================
% node.m
%
% Top-level headless launcher for a MATLAB node.
% Copy this file into your node folder and rename it to match your node.
%
% USAGE (called by updater/pull_and_deploy.sh):
%   matlab -batch "node('config/<profile>.json', '<profile>')"
%
% The config file is the machine-level JSON for the computer this node runs on.
% The profile key selects the node-specific section from that file.
%
% All shared MATLAB framework code lives in matlabCommon/.
% Writes a timestamped log file to logs/.
% =========================================================================
function node(cfgFile, profile)
    arguments
        cfgFile (1,1) string   % e.g. "config/my_computer.json"
        profile (1,1) string   % e.g. "my_computer"
    end

    %% 0. Bootstrap — paths and logging
    repoRoot = fileparts(mfilename('fullpath'));
    addpath(genpath(fullfile(repoRoot, '..', 'matlabCommon')));

    logDir = fullfile(repoRoot, '..', 'logs');
    if ~isfolder(logDir); mkdir(logDir); end

    ts = char(datetime("now", 'Format', 'yyyyMMdd-HHmmss'));
    diary(fullfile(logDir, "node_" + ts + ".txt"));
    cleanupDiary = onCleanup(@() diary('off'));

    fprintf("[INFO] Node booting...  %s\n", ts);

    %% 1. Load configuration
    % Replace 'myNode' with the key name for this node's section in the
    % machine config JSON (e.g. 'carriageNode', 'waveMakerProbeNode').
    NODE_SECTION = 'myNode';

    machineConfig = jsondecode(fileread(cfgFile));
    fprintf("[INFO] Loaded machine config from %s (profile: %s)\n", cfgFile, profile);

    if ~isfield(machineConfig, NODE_SECTION)
        error("[ERROR] Config file is missing '%s' section.", NODE_SECTION);
    end

    % Merge top-level broker settings with node-specific settings
    cfg = machineConfig.(NODE_SECTION);
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

    % Uncomment and adapt depending on whether this node has a sensor,
    % an actuator, or both:
    %
    % if ~isfield(cfg.hardware, 'hasSensor') || ~cfg.hardware.hasSensor
    %     error("[ERROR] myNode requires hardware.hasSensor = true.");
    % end
    % if ~isfield(cfg.hardware, 'hasActuator') || ~cfg.hardware.hasActuator
    %     error("[ERROR] myNode requires hardware.hasActuator = true.");
    % end

    %% 3. Initialise communication and FSM manager
    comm = CommClient(cfg);
    rest = RestClient(cfg);
    mgr  = MyNodeManager(cfg, comm, rest);

    %% 4. Wire MQTT message callback
    comm.onMessageCallback = @(topic, msg) mgr.onMessageCallback(topic, msg);

    %% 5. Graceful shutdown on exit
    finalizer = onCleanup(@() shutdownNode(comm, mgr));

    %% 6. Main event loop — blocks here; all work is done in MQTT callbacks
    fprintf("[INFO] Node online. Waiting for commands...\n");
    while ~isempty(comm.mqttClient) && comm.mqttClient.Connected
        pause(0.1);
    end
    fprintf("[INFO] Node: broker connection lost. Shutting down.\n");
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
