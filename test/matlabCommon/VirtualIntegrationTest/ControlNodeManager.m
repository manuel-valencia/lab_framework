classdef ControlNodeManager < ExperimentManager
    % ControlNodeManager
    % Orchestrates the full experiment by publishing commands to other nodes
    % - Sends calibration, test, and run commands to probeNode and waveGenNode
    % - Tracks progression and expected responses
    % - Logs inter-node activity

    properties
        stateCounter   % Tracks simulation phase progression
        hasCalibrated  % Flag to indicate calibration completed
        hasRunStarted  % Flag to indicate run has begun
        hasRunEnded    % Flag to indicate end of experiment
    end

    methods

        % Constructor
        function obj = ControlNodeManager(cfg, comm, rest)
            obj@ExperimentManager(cfg, comm, rest);
            obj.stateCounter = 0;
            obj.hasCalibrated = false;
            obj.hasRunStarted = false;
            obj.hasRunEnded = false;

            obj.log("INFO", "ControlNodeManager initialized.");
        end

        % Initialization
        function initializeHardware(obj, cfg)
            fprintf("%s [INIT] ControlNode is ready to coordinate experiment.\n", obj.FSMtag);
            obj.log("INFO", "Control node initialized and awaiting trigger.");
        end

        % Configuration — not needed, always valid
        function isValid = configureHardware(obj, params)
            isValid = true;
            obj.log("INFO", "Control node does not require config validation.");
        end

        % Not used directly — but could be triggered remotely
        function handleRun(obj, cmd)
            fprintf("%s [RUN] ControlNode handleRun() triggered.\n", obj.FSMtag);
            obj.log("INFO", "Control received RUN trigger. Starting coordination.");
        end

        function handleTest(obj, cmd)
            obj.log("INFO", "Control node test command received.");
        end

        function handleCalibrate(obj, cmd)
            obj.log("INFO", "Control node calibration command received.");
        end

        % Publish helper
        function publishCmd(obj, nodeID, cmdName, params)
            topic = sprintf("%s/cmd", nodeID);
            payload = struct("cmd", cmdName);
            if nargin >= 4
                payload.params = params;
            end
            obj.comm.commPublish(topic, payload);

            fprintf("%s Sent %s → %s\n", obj.FSMtag, cmdName, topic);
        end

        % Optional MQTT listener
        function onMessageCallback(obj, topic, msg)
            % Extend base callback
            fprintf("%s %s → %s\n", obj.FSMtag, topic, jsonencode(msg));
            %onMessageCallback@ExperimentManager(obj, topic, msg); % call superclass default
        end

        % Shutdown/stop cleanup
        function stopHardware(obj)
            obj.log("INFO", "Control node STOP issued.");
        end

        function shutdownHardware(obj)
            obj.log("INFO", "Control node cleared.");
        end
    end
end
