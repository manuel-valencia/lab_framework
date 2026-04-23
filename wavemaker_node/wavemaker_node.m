% =========================================================================
% wavemaker_node.m
%
% Top‑level, headless wave maker node for MATLAB-based control in Tow‑Tank Framework.
%
% USAGE (from a bash script or systemd service)
%   matlab -batch "wavemaker_node('config/wavemaker_config.json')"
%
% * cfgFile is a JSON file that holds MQTT credentials, wave maker hardware
%   parameters, and safety limits (see documentation).
%
% * All shared MATLAB framework code lives in matlabCommon/.
%
% * The node writes a timestamped log file to logs/.
%
% =========================================================================
function wavemaker_node(cfgFile)
    arguments
        cfgFile (1,1) string  % e.g. "config/wavemaker_config.json"
    end
    
    % WAVE MAKER CONFIGURATION FILE FORMAT:
    % Your JSON config file should contain at minimum:
    % {
    %   "clientID": "waveMakerNode",
    %   "brokerAddress": "localhost",
    %   "brokerPort": 1883,
    %   "restPort": 5000,
    %   "hardware": {
    %     "hasSensor": true,
    %     "hasActuator": true,
    %     "maxAmplitude": 0.1,
    %     "maxFrequency": 2.0,
    %     "paddleController": "servo_type_here",
    %     "positionSensor": "encoder_type_here"
    %   },
    %   "verbose": true
    % }
    % See matlabCommon/README.md for complete configuration reference.

    %% 0.  Bootstrap – path & logging
    repoRoot = fileparts(mfilename('fullpath'));      % repo/wavemaker_node/...
    addpath(genpath(fullfile(repoRoot, '..', 'matlabCommon')));
    logDir   = fullfile(repoRoot, "logs");
    if ~isfolder(logDir); mkdir(logDir); end

    ts = char(datetime("now",'Format','yyyyMMdd-HHmmss'));
    diary(fullfile(logDir, "wavemaker_node_" + ts + ".txt"));
    cleanupDiary = onCleanup(@() diary('off'));

    disp("[INFO] Wave Maker Node booting…  " + ts);
    dbstop if error

    %% 1. Load configuration
    cfg = jsondecode(fileread(cfgFile));
    disp("[INFO] Wave maker configuration loaded from " + cfgFile);
    
    % Validate required configuration fields
    requiredFields = ["clientID", "brokerAddress"];
    for field = requiredFields
        if ~isfield(cfg, field)
            error("[ERROR] Missing required configuration field: %s", field);
        end
    end
    
    % Validate wave maker specific hardware configuration
    if isfield(cfg, "hardware")
        if ~isfield(cfg.hardware, "hasActuator") || ~cfg.hardware.hasActuator
            error("[ERROR] Wave maker node requires hasActuator = true in hardware configuration");
        end
    else
        error("[ERROR] Missing hardware configuration section");
    end

    %% 2. Initialize communication and FSM manager
    comm = CommClient(cfg);        % MQTT client for real-time commands and status
    rest = RestClient(cfg);        % REST client for large data transfers
    mgr = WaveMakerNodeManager(cfg, comm, rest);

    %% 3. Wire MQTT commands to state machine
    % Set the callback to route incoming MQTT messages to the FSM
    comm.onMessageCallback = @mgr.onMessageCallback;

    %% 4. Ensure graceful shutdown
    finalizer = onCleanup(@() shutdownWaveMakerNode(comm, mgr));

    %% 5. Main blocking loop
    disp("[INFO] Wave maker entering main loop …  Ctrl‑C to quit.");
    while comm.isOpen
        pause(0.001);
    end
    disp("[INFO] Wave maker main loop exited – clean shutdown.");
end

% ----------------------------------------------------------------------------

function shutdownWaveMakerNode(comm, mgr)
    %SHUTDOWNWAVEMAKERNODE  Cleanup wave maker hardware and close MQTT connection
    try
        mgr.abort("Wave maker shutdown request");
    catch ME
        warning("Wave maker manager abort failed: %s", ME.message);
    end

    try
        comm.close();
    catch ME
        warning("Wave maker comm close failed: %s", ME.message);
    end
end