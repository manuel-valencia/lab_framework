classdef (Abstract) ExperimentManager < handle
    %EXPERIMENTMANAGER  Abstract state machine controller for Tow Tank nodes.
    %
    % This class defines a generic state-driven experiment framework for hardware
    % nodes in automated laboratory systems. Nodes can represent either data
    % collectors (sensors), actuators, or hybrid devices.
    %
    % Responsibilities:
    %   - Handle MQTT-based commands (e.g., "Calibrate", "Run", "Reset")
    %   - Manage state transitions between experiment phases
    %   - Publish structured status updates
    %   - Delegate hardware behavior to subclass implementations
    %   - Send and retrieve experiment data via REST API (RestClient)
    %
    % Example:
    %   mgr = MyNodeManager(cfg, comm, rest);
    %   comm.onCommand(@mgr.handleCommand);
    %
    % Required subclass implementations include:
    %   - initializeHardware
    %   - stopHardware, shutdownHardware
    %   - handleCalibrate, handleTest, handleRun
    %   - configureHardware

    %==================================================================
    %% Protected Properties
    %==================================================================
    properties (Access = protected)
        cfg                 % Configuration structure (includes mqtt, hardware flags, etc.)
        comm                % CommClient instance for publish/subscribe messaging
        rest                % RestClient instance for REST API communication
        state   State       % Current FSM state
        history string      % Record of all transitions (for debugging/logging)
        FSMLog = {};        % Stores FSM log for debugging/logging

        hasSensor logical = false   % Sets if has sensor capabilities
        experimentData              % Struct array of data collected during RUN
        hasActuator logical = false % Sets if has actuator capabilities 
        biasTable                   % Calibration bias per sensor
        experimentSpec              % Latest parsed experiment command struct
        currentExperimentIndex      % Index of the current experiment in multi-experiment mode
        FSMtag                      % Precomputed logging FSMtag, e.g., '[FSM:clientID]'
        cmd                         % Command string for current operation
    end

    %==================================================================
    %% Public Constants
    %==================================================================
    properties (Constant)
        % Supported command keywords
        validCommands = ["Calibrate", "Test", "Run", "TestValid", ...
                         "RunValid", "Reset", "Abort"];
    end

    %==================================================================
    %% Public Methods
    %==================================================================
    methods
        function obj = ExperimentManager(cfg, comm, rest)
            % Constructor: Initializes hardware, loads calibration data, and sets state to IDLE.
            %   cfg  - Configuration struct (includes mqtt topics and hardware flags)
            %   comm - CommClient interface instance (for MQTT messaging)
            %   rest - RestClient interface instance (for REST API)
            arguments
                cfg struct
                comm
                rest
            end
            obj.cfg = cfg;
            obj.comm = comm;
            obj.rest = rest;
            obj.state = State.BOOT;
            obj.history = "BOOT";

            obj.FSMtag = sprintf('[FSM:%s]', obj.comm.clientID);

            % Cache capability flags locally (if provided)
            if isfield(cfg, "hardware")
                hw = cfg.hardware;
                if isfield(hw, "hasSensor")
                    obj.hasSensor = hw.hasSensor;
                end
                if isfield(hw, "hasActuator")
                    obj.hasActuator = hw.hasActuator;
                end
            end

            % Will load calibrationGains.mat table if available in same node folder
            try
                localGainPath = fullfile(pwd, "calibrationGains.mat");
                S = load(localGainPath);
                obj.biasTable = S.biasTable;
                fprintf("%s Loaded previous calibration gains from: %s \n", obj.FSMtag, localGainPath);
            catch
                % Initialize empty bias table when no file found
                fprintf("[WARN] %s No previous calibrationGains.mat found. \n", obj.FSMtag);
                obj.biasTable = struct();
            end

            % Checks if CommClient is connected
            try
                obj.comm.connect();
            catch ME
                error("%s Comm Did Not Connect!!!: %s", obj.FSMtag, ME.message);
            end

            % Check if REST server is online
            try
                if ~obj.rest.checkHealth()
                    error("%s REST Server is not online or did not respond to /health.", obj.FSMtag);
                end
            catch ME
                error("%s REST Server health check failed: %s", obj.FSMtag, ME.message);
            end

            % Runs initializeHardware function defined by dev and moves toIDLE
            obj.initializeHardware(cfg);
            obj.transition(State.IDLE);
        end

        function handleCommand(obj, cmd)
            % handleCommand: Main dispatcher for command execution and state transitions.
            %   cmd - Struct containing at least a 'cmd' field with supported command name
            if ~isstruct(cmd) || ~isfield(cmd,"cmd")
                obj.log("ERROR", "Invalid command structure.")
                return;
            end

            cmdName = string(cmd.cmd);
            if ~ismember(cmdName, obj.validCommands)
                obj.log("ERROR", "Unknown command: " + cmdName)
                return;
            end

            try
                obj.cmd = cmd;
                switch cmdName
                    case "Calibrate"
                        obj.transition(State.CALIBRATING);
                        % obj.handleCalibrate(cmd);

                    case "Test"
                        if isfield(cmd, "params") && isfield(cmd.params, "target")
                            if cmd.params.target == "sensor"
                                obj.transition(State.TESTINGSENSOR);
                                % obj.handleTest(cmd);
                            else
                                obj.experimentSpec = cmd;
                                obj.transition(State.CONFIGUREVALIDATE);
                            end
                        else
                            obj.log("ERROR", "Missing 'target' in Test command.");
                            obj.transition(State.ERROR);
                        end

                    case "Run"
                        obj.experimentSpec = cmd;
                        obj.transition(State.CONFIGUREVALIDATE);

                    case "TestValid"
                        obj.transition(State.TESTINGACTUATOR);
                        % obj.handleTest(cmd);

                    case "RunValid"
                        if obj.state ~= State.CONFIGUREPENDING
                            warning("%s Invalid RunValid from state: %s", obj.FSMtag, string(obj.state));
                            obj.log("WARN", "Invalid RunValid from state: " + string(obj.state));
                            obj.transition(State.ERROR);
                            return;
                        end
                        obj.transition(State.RUNNING);
                        
                    case "Reset"
                        obj.transition(State.IDLE);

                    case "Abort"
                        obj.abort("User request via command.");
                end
                
            catch ME
                % errMsg = sprintf("%s Command handler error: %s | cmd=%s | stack=%s", ...
                %                     obj.FSMtag, ME.message, cmdName, strjoin(string({ME.stack.file}), ", "));
                % obj.log("ERROR", errMsg);
                % obj.transition(State.ERROR);
                errMsg = sprintf("Command handler error:\n  → message: %s\n  → cmd: %s\n  → stack:\n%s", ...
                                    ME.message, cmdName, getReport(ME, 'extended', 'hyperlinks', 'off'));
                obj.log("ERROR", errMsg);  % This may still fail if log() uses obj.FSMtag internally
                obj.transition(State.ERROR);
            end
        end

        function abort(obj, reason)
            % abort: Handles user-initiated aborts by publishing error state.
            %   reason - Description for the abort cause
            fprintf("[ABORT] %s: %s \n", obj.FSMtag, reason);
            abortMsg = struct( ...
                "state", "ABORT", ...
                "reason", reason, ...
                "timestamp", string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')) ...
            );
            obj.comm.commPublish(obj.comm.getFullTopic("status"), jsonencode(abortMsg));
            try
                obj.stopHardware();
            catch
            end
            obj.transition(State.ERROR);
        end

        function s = getState(obj)
            % getState: Returns current FSM state as string.
            %   s - Current state (string)
            s = string(obj.state);
        end

        function biasTable = getBiasTable(obj)
            % getBiasTable: Returns current sensor bias table.
            %   biasTable - Struct of sensor biases
            biasTable = obj.biasTable;
        end

        function log(obj, level, msg)
            % log - Unified logging method for nodes.
            % Sends to CommClient's /log topic and stores in messageLog buffer.
        
            if nargin < 2
                level = "INFO";
            end
        
            timestamp = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS');
            logMsg = struct( ...
                "level", level, ...
                "msg", msg, ...
                "timestamp", string(timestamp) ...
            );
        
            try
                jsonMsg = jsonencode(logMsg);
                obj.comm.commPublish(obj.comm.getFullTopic("log"), jsonMsg);
                obj.FSMLog{end+1} = jsonMsg;
            catch ME
                warning("%s Log publish failed: %s %s", obj.FSMtag, msg, ME.message);
            end
        end

        function onMessageCallback(obj, topic, msg)
            % onMessageCallback - Generic MQTT message handler for FSM-based nodes.
            % Supports command messages from any subscribed topic.
            %
            % Nodes can override this for custom topic handling (e.g., wave data).
            %
            % Example behavior:
            %   - Decodes JSON
            %   - Looks for a 'cmd' field
            %   - Dispatches via handleCommand()
        
            % --- Decode JSON payload ---
            try
                if ischar(msg) || isstring(msg)
                    msg = jsondecode(msg);
                end
            catch decodeErr
                warning("%s [msgCallback] JSON decode failed from topic '%s': %s", ...
                    obj.FSMtag, topic, decodeErr.message);
                obj.log("WARN", sprintf("JSON decode error from topic '%s': %s", topic, decodeErr.message));
                return;
            end
        
            % --- Route valid commands ---
            if isstruct(msg) && isfield(msg, "cmd")
                fprintf("%s [msgCallback] Dispatching command '%s' from topic '%s'\n", ...
                    obj.FSMtag, string(msg.cmd), topic);
                obj.handleCommand(msg);
            else
                obj.log("WARN", sprintf("Malformed /cmd message from topic '%s' (missing 'cmd').", topic));
                fprintf("%s [msgCallback] Ignored non-command message from topic: %s\n", obj.FSMtag, topic);
            end
        end

        function shutdown(obj)
            % shutdown - Unified shutdown routine for all node types.
            % Stores MQTT logs, FSM history, and disconnects client.
            
            % Step 1: Call user-defined hardware shutdown
            obj.shutdownHardware();
        
            % Step 2: Create per-node log folder
            logDir = sprintf('%sLogs', obj.cfg.clientID);
            if ~exist(logDir, 'dir')
                mkdir(logDir);
            end
        
            % Step 3: Save CommClient MQTT message log
            logPath = fullfile(logDir, sprintf('%s_commLog.jsonl', obj.cfg.clientID));
            if isprop(obj.comm, 'messageLog') && ~isempty(obj.comm.messageLog)
                try
                    fid = fopen(logPath, 'w');
                    for i = 1:numel(obj.comm.messageLog)
                        fprintf(fid, '%s\n', jsonencode(obj.comm.messageLog{i}));
                    end
                    fclose(fid);
                    obj.log("INFO", "CommClient message log saved.");
                catch ME
                    warning('%s [SHUTDOWN] Failed to save CommClient log: %s', obj.FSMtag, ME.message);
                end
            else
                obj.log("INFO", "No CommClient message log to save.");
            end

            % Step 4: Gracefully disconnect CommClient
            obj.comm.disconnect();
            obj.log("INFO", "CommClient disconnected.");
        
            % Step 4: Save FSM state transition history and FSMLog
            historyPath = fullfile(logDir, sprintf('%s_fsmHistory.log', obj.cfg.clientID));
            try
                fid = fopen(historyPath, 'w');
                if fid ~= -1
                    fprintf(fid, "%s\n", obj.history{:});
                    fclose(fid);
                    obj.log("INFO", sprintf("FSM history saved to %s", historyPath));
                else
                    warning("%s [SHUTDOWN] Failed to open FSM history file.", obj.FSMtag);
                end
            catch ME
                warning("%s [SHUTDOWN] Failed to write FSM history: %s", obj.FSMtag, ME.message);
            end

            FSMLogPath = fullfile(logDir, sprintf('%s_fsmLog.jsonl', obj.cfg.clientID));
            if isprop(obj, 'FSMLog') && ~isempty(obj.FSMLog)
                try
                    fid = fopen(FSMLogPath, 'w');
                    for i = 1:numel(obj.FSMLog)
                        fprintf(fid, '%s\n', jsonencode(obj.FSMLog{i}));
                    end
                    fclose(fid);
                    obj.log("INFO", "FSM message log saved.");
                catch ME
                    warning('%s [SHUTDOWN] Failed to save FSM log: %s', obj.FSMtag, ME.message);
                end
            else
                obj.log("INFO", "No FSM message log to save.");
            end
        
            fprintf("%s [SHUTDOWN] Node shutdown complete.\n", obj.FSMtag);
        end

        function setupCurrentExperiment(obj)
            % setupCurrentExperiment - Prepares the current experiment parameters.
            % This method should be called after configureHardware() to set up
            % the current experiment's parameters and precompute any necessary data.
            %
            % It can be overridden by subclasses to implement specific setup logic.

            if isfield(obj.experimentSpec.params, 'experiments')
                % Multi-experiment mode
                currentParams = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
                totalExperiments = length(obj.experimentSpec.params.experiments);
                
                % Logging for multi-experiment context
                if isfield(currentParams, 'name')
                    obj.log("INFO", sprintf("Setting up experiment %d/%d: '%s'", ...
                        obj.currentExperimentIndex, totalExperiments, currentParams.name));
                else
                    obj.log("INFO", sprintf("Setting up experiment %d/%d (unnamed)", ...
                        obj.currentExperimentIndex, totalExperiments));
                end
                
                obj.log("INFO", sprintf("Experiment %d parameters: %s", ...
                    obj.currentExperimentIndex, jsonencode(currentParams)));
            else
                % Single experiment mode
                currentParams = obj.experimentSpec.params;
                
                if isfield(currentParams, 'name')
                    obj.log("INFO", sprintf("Setting up single experiment: '%s'", currentParams.name));
                else
                    obj.log("INFO", "Setting up single experiment (unnamed)");
                end
                
                obj.log("INFO", sprintf("Experiment parameters: %s", jsonencode(currentParams)));
            end
        end


    end

    %==================================================================
    %% Protected State Machine Core
    %==================================================================
    methods (Access = protected)
        function transition(obj, newState)
            % Handles state transitions, verifies legality before switching
            %   newState - Enum value of type State
            if ~obj.isValidTransition(obj.state, newState)
                warning("%s Invalid transition: %s → %s", obj.FSMtag, string(obj.state), string(newState));
                obj.transition(State.ERROR);
                return;
            end
            prev = obj.state;
            obj.exitState(prev);
            obj.state = newState;
            obj.history(end+1) = string(newState);
            fprintf("%s [STATE] %s → %s \n", obj.FSMtag, string(prev), string(newState));
            obj.enterState(newState);
        end

        function tf = isValidTransition(~, fromState, toState)
            % Determines if a transition is allowed between two FSM states
            %   fromState - Current state (State enum)
            %   toState   - Desired state (State enum)
            %   tf        - Boolean result (true if allowed)
            valid = struct( ...
                'BOOT',              [State.IDLE], ...
                'IDLE',              [State.CALIBRATING, State.TESTINGSENSOR, State.CONFIGUREVALIDATE], ...
                'CALIBRATING',       [State.CALIBRATING], ...
                'TESTINGSENSOR',     [State.IDLE], ...
                'CONFIGUREVALIDATE', [State.CONFIGUREPENDING, State.IDLE], ...
                'CONFIGUREPENDING',  [State.TESTINGACTUATOR, State.RUNNING], ...
                'TESTINGACTUATOR',   [State.IDLE], ...
                'RUNNING',           [State.POSTPROC], ...
                'POSTPROC',          [State.DONE, State.RUNNING], ...
                'DONE',              [State.IDLE], ...
                'ERROR',             [State.IDLE] ...
            );
            key = char(fromState);
            if isfield(valid, key)
                allowedStates = [valid.(key), State.IDLE, State.ERROR];
                tf = any(toState == allowedStates);
            else
                tf = false;
            end
        end

        function enterState(obj, s)
            % Logic executed upon entering a new state
            %   s - New state (enum value of State)
            fprintf("%s [ENTER STATE] %s \n", obj.FSMtag, string(s));
            statusMsg = struct("state", string(s), "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS'));
            obj.comm.commPublish(obj.comm.getFullTopic("status"), jsonencode(statusMsg));
            switch s
                case State.IDLE,               obj.enterIdle();
                case State.CALIBRATING,        obj.enterCalibrating();
                case State.TESTINGSENSOR,      obj.enterTestingSensor();
                case State.CONFIGUREVALIDATE,  obj.enterConfigureValidate();
                case State.CONFIGUREPENDING,   obj.enterConfigurePending();
                case State.TESTINGACTUATOR,    obj.enterTestingActuator();
                case State.RUNNING,            obj.enterRunning();
                case State.POSTPROC,           obj.enterPostProc();
                case State.DONE,               obj.enterDone();
                case State.ERROR,              obj.enterError();
            end
        end

        function exitState(obj, s)
            % Logic executed before leaving a state
            %   s - Old state being exited (enum value of State)
            switch s
                case State.RUNNING,        obj.exitRunning();
                case State.CALIBRATING,    obj.exitCalibrating();
                case State.TESTINGSENSOR,  obj.exitTestingSensor();
            end
            fprintf("%s [EXIT STATE] %s \n", obj.FSMtag, string(s));
        end

        %--------------------------------------------------------------
        % Individual State Entry/Exit Implementations
        %--------------------------------------------------------------
        function enterIdle(obj)
            % Called on entry into the IDLE state
            obj.stopHardware();
        end

        function enterCalibrating(obj)
            % Called when entering CALIBRATING state
            if ~obj.hasSensor
                error("%s Cannot calibrate: node lacks sensor capability.", obj.FSMtag);
            end
            fprintf("%s [CALIBRATION] Starting sensor calibration. \n", obj.FSMtag);
            obj.handleCalibrate(obj.cmd);
        end

        function enterTestingSensor(obj)
            % Called when entering TESTINGSENSOR state
            if ~obj.hasSensor
                error("%s Cannot test sensor: node lacks sensor capability.", obj.FSMtag);
            end
            fprintf("%s [TEST] Live sensor diagnostics. \n", obj.FSMtag);
            obj.handleTest(obj.cmd);
        end

        function enterTestingActuator(obj)
            % Called when entering TESTINGACTUATOR state
            if ~obj.hasActuator
                error("%s Cannot test actuator: node lacks actuator capability.", obj.FSMtag);
            end
            fprintf("%s [TEST] Actuator validation. \n", obj.FSMtag);
            obj.handleTest(obj.cmd);
        end

        function enterConfigureValidate(obj)
            % Called on CONFIGUREVALIDATE; verifies parameters and proceeds
            % Check if multi-experiment mode
            if isfield(obj.experimentSpec.params, 'experiments') && ~isempty(obj.experimentSpec.params.experiments)
                experiments = obj.experimentSpec.params.experiments;
                % Validate all experiments before setup
                for i = 1:length(experiments)
                    isValid = obj.configureHardware(experiments(i));
                    if ~isValid
                        obj.log("WARN", sprintf("Invalid experiment parameters in experiment %d.", i));
                        obj.transition(State.IDLE);
                        return;
                    end
                end
                % All experiments are valid, proceed to setup first experiment
                obj.currentExperimentIndex = 1;
                try
                    obj.setupCurrentExperiment();
                    obj.transition(State.CONFIGUREPENDING);
                catch ME
                    obj.log("ERROR", sprintf("Multi-experiment setup failed: %s", ME.message));
                    obj.transition(State.IDLE);
                end
            else
                % Single experiment mode
                isValid = obj.configureHardware(obj.experimentSpec.params);
                if isValid
                    obj.currentExperimentIndex = 1;
                    try
                        obj.setupCurrentExperiment();
                        obj.transition(State.CONFIGUREPENDING);
                    catch ME
                        obj.log("ERROR", sprintf("Single experiment setup failed: %s", ME.message));
                        obj.transition(State.IDLE);
                    end
                else
                    obj.log("WARN", "Invalid configuration parameters.");
                    obj.transition(State.IDLE);
                end
            end
        end

        function enterConfigurePending(obj)
            % Called when entering CONFIGUREPENDING
            fprintf("%s [CONFIGURE] Awaiting user confirmation. \n", obj.FSMtag);
        end

        function enterRunning(obj)
            % Called when entering RUNNING state
            fprintf("%s [RUNNING] Executing experiment. \n", obj.FSMtag);
            obj.handleRun(obj.cmd);
        end

        function enterPostProc(obj)
            % enterPostProc - Handles default post-processing behavior for a node.
            %
            % This function collects experiment data after an experiment run. If data
            % exists in obj.experimentData, it attempts to store it as a CSV (if homogeneous),
            % otherwise falls back to newline-delimited JSON (JSONL). The saved file is tagged
            % using the experiment name (if available) or a timestamp to prevent overwrites.
            %
            % This method can be overridden by subclasses to implement node-specific
            % post-processing workflows.

            fprintf("%s [POSTPROC] Processing experiment data.\n", obj.FSMtag);

            if ~isempty(obj.experimentData)
                % Always use clientID for base directory
                baseDir = sprintf('%sData', obj.cfg.clientID);
                
                if isfield(obj.experimentSpec.params, 'experiments')
                    % Multi-experiment: create subfolder within clientIDData
                    if isfield(obj.experimentSpec.params, 'name')
                        subFolderName = matlab.lang.makeValidName(obj.experimentSpec.params.name);
                    else
                        subFolderName = sprintf('MultiExperiment_%s', datestr(now, 'yyyymmdd_HHMMSS')); %#ok<TNOW1,DATST>
                    end
                    outDir = fullfile(baseDir, subFolderName);
                    
                    % Get current experiment name for file tag
                    tag = obj.getExperimentTag();
                else
                    % Single experiment: use base directory directly
                    outDir = baseDir;
                    tag = obj.getExperimentTag();
                end
                
                if ~exist(outDir, 'dir')
                    mkdir(outDir);
                end
                
                tag = matlab.lang.makeValidName(tag);
                
                % Save current experiment data
                try
                    T = struct2table(obj.experimentData);
                    csvPath = fullfile(outDir, sprintf('%s_data_%s.csv', obj.cfg.clientID, tag));
                    writetable(T, csvPath);
                    obj.log("INFO", sprintf("Experiment data saved to CSV: %s", csvPath));
                catch ME
                    % Fallback: save as JSONL
                    jsonlPath = fullfile(outDir, sprintf('%s_data_%s.jsonl', obj.cfg.clientID, tag));
                    try
                        fid = fopen(jsonlPath, 'w');
                        for i = 1:numel(obj.experimentData)
                            fprintf(fid, '%s\n', jsonencode(obj.experimentData(i)));
                        end
                        fclose(fid);
                        obj.log("INFO", sprintf("Experiment data saved as JSONL: %s", jsonlPath));
                    catch innerME
                        obj.log("ERROR", sprintf("Failed to save experiment data: %s", innerME.message));
                    end
                end
            end
            
            % Check if more experiments remain
            if isfield(obj.experimentSpec.params, 'experiments') && ...
               obj.currentExperimentIndex < length(obj.experimentSpec.params.experiments)
                % Multi-experiment mode: setup next experiment
                try
                    obj.sendExpData(obj.experimentData, tag);  % Send data to REST server
                    obj.currentExperimentIndex = obj.currentExperimentIndex + 1;
                    obj.setupCurrentExperiment();
                    obj.transition(State.RUNNING);
                catch ME
                    obj.log("ERROR", sprintf("Setup for next experiment failed: %s", ME.message));
                    obj.transition(State.ERROR);
                end
            else
                % All experiments complete
                obj.transition(State.DONE);
            end
        end

        function enterDone(obj)
            % Wraps up after experiment completes
            fprintf("%s [DONE] Experiment complete. \n", obj.FSMtag);

            % --- Send experiment data to REST server ---
            tag = obj.getExperimentTag();
            obj.sendExpData(obj.experimentData, tag);

            obj.transition(State.IDLE);
        end

        function sendExpData(obj, experimentData, tag)
            % sendExpData - Helper function to send experiment data to REST server
            % Arguments:
            %   experimentData - struct array or table of experiment data
            %   tag - Optional tag for the experiment (default: timestamp)
            
            if isempty(experimentData)
                obj.log("INFO", "No experiment data to send to REST server.");
                return;
            end

            % Handle optional tag parameter
            if nargin < 3 || isempty(tag)
                tag = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
            end
            
            tag = matlab.lang.makeValidName(tag);
            
            try
                % Send data (table or struct array) to REST server
                resp = obj.rest.sendData(experimentData, 'experimentName', tag);
                if isstruct(resp) && isfield(resp, "status") && resp.status == "error"
                    obj.log("ERROR", sprintf("REST POST failed: %s", resp.message));
                else
                    obj.log("INFO", sprintf("Experiment data sent to REST server: %s", tag));
                end
            catch ME
                obj.log("ERROR", sprintf("REST POST exception: %s", ME.message));
            end
        end

        function tag = getExperimentTag(obj)
            % getExperimentTag - Helper function to determine experiment tag for file naming and REST API
            % Returns:
            %   tag - string, experiment name or timestamp fallback
            
            if isfield(obj.experimentSpec.params, 'experiments')
                % Multi-experiment mode: use current experiment name
                currentParams = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
                if isfield(currentParams, 'name')
                    tag = currentParams.name;
                else
                    if isfield(obj.experimentSpec.params, 'name')
                        tag = sprintf("%s_%d", obj.experimentSpec.params.name, obj.currentExperimentIndex);
                    else
                        tag = sprintf('experiment_%d_%s', obj.currentExperimentIndex, datestr(now, 'yyyymmdd_HHMMSS'));
                    end
                end
            else
                % Single experiment mode: use overall experiment name
                if isfield(obj.experimentSpec.params, 'name')
                    tag = obj.experimentSpec.params.name;
                else
                    tag = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<TNOW1,DATST>
                end
            end
            
            tag = matlab.lang.makeValidName(tag);
        end

        function enterError(obj)
            % Failsafe entry into ERROR state
            fprintf("%s [ERROR] System faulted. \n", obj.FSMtag);
        end

        function exitCalibrating(obj)
            % Cleanup before leaving CALIBRATING
            fprintf("%s [EXIT] Calibration complete. \n", obj.FSMtag);
        end

        function exitTestingSensor(obj)
            % Cleanup before leaving TESTINGSENSOR
            fprintf("%s [EXIT] Stopping sensor diagnostics. \n", obj.FSMtag);
            obj.stopHardware();
        end

        function exitRunning(obj)
            % Cleanup before leaving RUNNING state
            obj.stopHardware();
        end
    end

    %==================================================================
    %% Abstract Interfaces (to be implemented by subclasses)
    %==================================================================
    methods (Abstract)
        initializeHardware(obj, cfg)
        handleCalibrate(obj, cmd)
        handleTest(obj, cmd)
        handleRun(obj, cmd)
        configureHardware(obj, params)
        stopHardware(obj)
        shutdownHardware(obj)
    end
end
