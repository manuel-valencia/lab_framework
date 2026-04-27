% =========================================================================
% carriage_node.m
%
% Top-level headless launcher for the carriage force sensor node.
% Runs on the carriage computer.
%
% USAGE (called by updater/pull_and_deploy.sh):
%   matlab -batch "carriage_node('config/carriage_computer.json', 'carriage_computer')"
%
% The config file is the machine-level JSON (see config/carriage_computer.json.example).
% The profile key selects the carriageNode section from that file.
%
% All shared MATLAB framework code lives in matlabCommon/.
% Writes a timestamped log file to logs/.
% =========================================================================
function carriage_node(cfgFile, profile)
    arguments
        cfgFile (1,1) string   % e.g. "config/carriage_computer.json"
        profile (1,1) string   % e.g. "carriage_computer"
    end

    %% 0. Bootstrap — paths and logging
    repoRoot = fileparts(mfilename('fullpath'));
    addpath(genpath(fullfile(repoRoot, '..', 'matlabCommon')));

    logDir = fullfile(repoRoot, '..', 'logs');
    if ~isfolder(logDir); mkdir(logDir); end

    ts = char(datetime("now", 'Format', 'yyyyMMdd-HHmmss'));
    diary(fullfile(logDir, "carriage_node_" + ts + ".txt"));
    cleanupDiary = onCleanup(@() diary('off'));

    fprintf("[INFO] CarriageNode booting...  %s\n", ts);

    %% 1. Load configuration
    machineConfig = jsondecode(fileread(cfgFile));
    fprintf("[INFO] Loaded machine config from %s (profile: %s)\n", cfgFile, profile);

    if ~isfield(machineConfig, 'carriageNode')
        error("[ERROR] Config file is missing 'carriageNode' section.");
    end

    % Merge top-level broker settings with node-specific settings
    cfg = machineConfig.carriageNode;
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

    if ~isfield(cfg.hardware, 'hasSensor') || ~cfg.hardware.hasSensor
        error("[ERROR] carriageNode requires hardware.hasSensor = true.");
    end

    %% 3. Initialise communication and FSM manager
    comm = CommClient(cfg);
    rest = RestClient(cfg);
    mgr  = CarriageNodeManager(cfg, comm, rest);

    %% 4. Wire MQTT message callback
    comm.onMessageCallback = @(topic, msg) mgr.onMessageCallback(topic, msg);

    %% 5. Publish IP address once so the web UI can display it
    try
        localIP = char(java.net.InetAddress.getLocalHost().getHostAddress());
    catch
        localIP = 'unknown';
    end
    ipStatus = struct('state', 'IDLE', 'ip', localIP, ...
        'timestamp', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS')));
    comm.commPublish(comm.getFullTopic('status'), jsonencode(ipStatus));
    fprintf("[INFO] CarriageNode IP: %s\n", localIP);

    %% 6. Graceful shutdown on exit
    finalizer = onCleanup(@() shutdownNode(comm, mgr));

    %% 7. Main event loop — blocks here; all work is done in MQTT callbacks
    fprintf("[INFO] CarriageNode online. Waiting for commands...\n");
    while ~isempty(comm.mqttClient) && comm.mqttClient.Connected
        pause(0.001);
    end
    fprintf("[INFO] CarriageNode: broker connection lost. Shutting down.\n");
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
