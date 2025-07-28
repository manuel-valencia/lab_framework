% =========================================================================
% node.m
%
% Top‑level, headless node for MATLAB-based control in Tow‑Tank Framework.
%
% USAGE (from a bash script or systemd service)
%   matlab -batch "node('config/my_node_config.json')"
%
% * cfgFile is a JSON file that holds MQTT credentials, hardware
%   parameters, and safety limits (see documentation).
%
% * All shared MATLAB framework code lives in matlabCommon/.
%
% * The node writes a timestamped log file to logs/.
%
% =========================================================================
function node(cfgFile)
    arguments
        cfgFile (1,1) string  % e.g. "config/my_node_config.json"
    end

    %% 0.  Bootstrap – path & logging
    repoRoot = fileparts(mfilename('fullpath'));      % repo/node_scafolding_matlab/...
    addpath(genpath(fullfile(repoRoot, '..', 'matlabCommon')));
    logDir   = fullfile(repoRoot, "logs");
    if ~isfolder(logDir); mkdir(logDir); end

    ts = char(datetime("now",'Format','yyyyMMdd-HHmmss'));
    diary(fullfile(logDir, "node_" + ts + ".txt"));
    cleanupDiary = onCleanup(@() diary('off'));

    disp("[INFO] Node booting…  " + ts);
    dbstop if error

    %% 1. Load configuration
    cfg = jsondecode(fileread(cfgFile));
    disp("[INFO] Configuration loaded from " + cfgFile);

    %% 2. Initialize communication and FSM manager
    comm = CommClient(cfg.mqtt);
    mgr = MyNodeManager(cfg, comm);

    %% 3. Wire MQTT commands to state machine
    comm.onCommand(@mgr.handleCommand);

    %% 4. Ensure graceful shutdown
    finalizer = onCleanup(@() shutdownNode(comm, mgr));

    %% 5. Main blocking loop
    disp("[INFO] Entering main loop …  Ctrl‑C to quit.");
    while comm.isOpen
        pause(0.001);
    end
    disp("[INFO] Main loop exited – clean shutdown.");
end

% ----------------------------------------------------------------------------

function shutdownNode(comm, mgr)
    %SHUTDOWNNODE  Cleanup hardware and close MQTT connection
    try
        mgr.abort("Shutdown request");
    catch ME
        warning("Manager abort failed: %s", '%s', ME.message);
    end

    try
        comm.close();
    catch ME
        warning("Comm close failed: %s", '%s', ME.message);
    end
end
