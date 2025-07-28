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
    %
    % Example:
    %   mgr = MyNodeManager(cfg, comm);
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
        state   State       % Current FSM state
        history string      % Record of all transitions (for debugging/logging)

        actuatorClass       % Handle to actuator class (optional)
        probeArray          % Handle to DAQ or sensor class (optional)
        biasTable           % Calibration bias per sensor
        experimentSpec      % Latest parsed experiment command struct
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
        function obj = ExperimentManager(cfg, comm)
            % Constructor: Initializes hardware, loads calibration data, and sets state to IDLE.
            %   cfg  - Configuration struct (includes mqtt topics and hardware flags)
            %   comm - CommClient interface instance
            arguments
                cfg struct
                comm
            end
            obj.cfg = cfg;
            obj.comm = comm;
            obj.state = State.BOOT;
            obj.history = "BOOT";

            % Will load calibrationGains.mat table if available in same
            % node folder
            try
                S = load("calibrationGains.mat");
                obj.biasTable = S.biasTable;
                disp("[INFO] Loaded previous calibration gains.");
            catch
                disp("[WARN] No previous calibrationGains.mat found.");
            end
            % Runs initializeHardware function defined by dev and moves to
            try
                obj.comm.connect();
            catch ME
                error("Comm Did Not Connect!!!: %s", ME.message);
            end
            % IDLE
            obj.initializeHardware(cfg);
            obj.transition(State.IDLE);
        end

        function handleCommand(obj, cmd)
            % handleCommand: Main dispatcher for command execution and state transitions.
            %   cmd - Struct containing at least a 'cmd' field with supported command name
            if ~isstruct(cmd) || ~isfield(cmd,"cmd")
                obj.comm.publish(obj.cfg.mqtt.topics.error, ...
                    struct("msg","Invalid command structure."));
                return;
            end

            cmdName = string(cmd.cmd);
            if ~ismember(cmdName, obj.validCommands)
                obj.comm.publish(obj.cfg.mqtt.topics.error, ...
                    struct("msg","Unknown command: " + cmdName));
                return;
            end

            try
                switch cmdName
                    case "Calibrate"
                        obj.transition(State.CALIBRATING);
                        obj.handleCalibrate(cmd);

                    case "Test"
                        if isfield(cmd, "target") && cmd.target == "sensor"
                            obj.transition(State.TESTINGSENSOR);
                        else
                            obj.transition(State.TESTINGACTUATOR);
                        end
                        obj.handleTest(cmd);

                    case "Run"
                        obj.experimentSpec = cmd;
                        obj.transition(State.CONFIGUREVALIDATE);

                    case "TestValid"
                        obj.transition(State.TESTINGACTUATOR);
                        obj.handleTest(cmd);

                    case "RunValid"
                        if obj.state ~= State.CONFIGUREPENDING
                            warning("[FSM] Invalid RunValid from state: %s", string(obj.state));
                            obj.comm.publish(obj.cfg.mqtt.topics.error, ...
                                struct("msg", "RunValid only valid from CONFIGUREPENDING"));
                            obj.transition(State.ERROR);
                            return;
                        end
                        obj.transition(State.RUNNING);
                        obj.handleRun(cmd);

                    case "Reset"
                        obj.transition(State.IDLE);

                    case "Abort"
                        obj.abort("User request via command.");
                end
            catch ME
                obj.comm.publish(obj.cfg.mqtt.topics.error, struct( ...
                    "msg", "Command handler error", ...
                    "cmd", cmdName, ...
                    "stack", string({ME.stack.file}), ...
                    "err", ME.message));
                obj.transition(State.ERROR);
            end
        end

        function abort(obj, reason)
            % abort: Handles user-initiated aborts by publishing error state.
            %   reason - Description for the abort cause
            disp("[ABORT] " + reason);
            obj.comm.publish(obj.cfg.mqtt.topics.status, ...
                struct("state","ABORT", "reason",reason, ...
                       "time", datetime("now")));
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
        
            timestamp = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
            logMsg = struct( ...
                "level", level, ...
                "msg", msg, ...
                "timestamp", string(timestamp) ...
            );
        
            try
                jsonMsg = jsonencode(logMsg);
                obj.comm.commPublish(obj.comm.getFullTopic("log"), jsonMsg);
            catch ME
                warning("Log publish failed: %s %s", msg, ME.message);
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
                warning("[FSM] Invalid transition: %s → %s", string(obj.state), string(newState));
                obj.transition(State.ERROR);
                return;
            end
            prev = obj.state;
            obj.exitState(prev);
            obj.state = newState;
            obj.history(end+1) = string(newState);
            disp("[STATE] " + string(prev) + " → " + string(newState));
            obj.enterState(newState);
        end

        function tf = isValidTransition(obj, fromState, toState)
            % Determines if a transition is allowed between two FSM states
            %   fromState - Current state (State enum)
            %   toState   - Desired state (State enum)
            %   tf        - Boolean result (true if allowed)
            valid = struct( ...
                'BOOT',              [State.IDLE], ...
                'IDLE',              [State.CALIBRATING, State.TESTINGSENSOR, State.TESTINGACTUATOR, State.CONFIGUREVALIDATE], ...
                'CALIBRATING',       [State.CALIBRATING], ...
                'TESTINGSENSOR',     [State.IDLE], ...
                'CONFIGUREVALIDATE', [State.CONFIGUREPENDING, State.IDLE], ...
                'CONFIGUREPENDING',  [State.TESTINGACTUATOR, State.RUNNING], ...
                'TESTINGACTUATOR',   [State.IDLE], ...
                'RUNNING',           [State.POSTPROC], ...
                'POSTPROC',          [State.DONE], ...
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
            obj.comm.commPublish(obj.comm.getFullTopic("status"), jsonencode(struct("state", string(s))));
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
            disp("[ENTER STATE] " + string(s));
        end

        function exitState(obj, s)
            % Logic executed before leaving a state
            %   s - Old state being exited (enum value of State)
            switch s
                case State.RUNNING,        obj.exitRunning();
                case State.CALIBRATING,    obj.exitCalibrating();
                case State.TESTINGSENSOR,  obj.exitTestingSensor();
            end
            disp("[EXIT STATE] " + string(s));
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
            if ~obj.cfg.hardware.hasSensor
                error("[FSM] Cannot calibrate: node lacks sensor capability.");
            end
            disp("[CALIBRATION] Starting sensor calibration.");
        end

        function enterTestingSensor(obj)
            % Called when entering TESTINGSENSOR state
            if ~obj.cfg.hardware.hasSensor
                error("[FSM] Cannot test sensor: node lacks sensor capability.");
            end
            disp("[TEST] Live sensor diagnostics.");
        end

        function enterTestingActuator(obj)
            % Called when entering TESTINGACTUATOR state
            if ~obj.cfg.hardware.hasActuator
                error("[FSM] Cannot test actuator: node lacks actuator capability.");
            end
            disp("[TEST] Actuator validation.");
        end

        function enterConfigureValidate(obj)
            % Called on CONFIGUREVALIDATE; verifies parameters and proceeds
            isValid = obj.configureHardware(obj.experimentSpec.params);
            if isValid
                obj.transition(State.CONFIGUREPENDING);
            else
                obj.comm.publish(obj.cfg.mqtt.topics.error, ...
                    struct("msg", "Invalid configuration parameters."));
                obj.transition(State.IDLE);
            end
        end

        function enterConfigurePending(obj)
            % Called when entering CONFIGUREPENDING
            disp("[CONFIGURE] Awaiting user confirmation.");
        end

        function enterRunning(obj)
            % Called when entering RUNNING state
            disp("[RUNNING] Executing experiment.");
        end

        function enterPostProc(obj)
            % Post-processing step before DONE
            disp("[POSTPROC] Processing results.");
            pause(0.05);
            obj.transition(State.DONE);
        end

        function enterDone(obj)
            % Wraps up after experiment completes
            disp("[DONE] Experiment complete.");
            obj.transition(State.IDLE);
        end

        function enterError(obj)
            % Failsafe entry into ERROR state
            disp("[ERROR] System faulted.");
        end

        function exitCalibrating(obj)
            % Cleanup before leaving CALIBRATING
            disp("[EXIT] Calibration complete.");
        end

        function exitTestingSensor(obj)
            % Cleanup before leaving TESTINGSENSOR
            disp("[EXIT] Stopping sensor diagnostics.");
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
