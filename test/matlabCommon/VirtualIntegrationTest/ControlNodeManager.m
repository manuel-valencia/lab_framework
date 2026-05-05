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

        % coordinatedNodes — cell array of node-ID strings that receive a
        % 'RunValid' command when an INTER_RUN_READY event is observed from
        % any subscribed node.  Populate after construction:
        %   ctrl.coordinatedNodes = {'waveGenNode01', 'probeNode01'};
        coordinatedNodes    % cell array of node ID strings
    end

    methods

        % Constructor
        function obj = ControlNodeManager(cfg, comm, rest)
            obj@ExperimentManager(cfg, comm, rest);
            obj.stateCounter = 0;
            obj.hasCalibrated = false;
            obj.hasRunStarted = false;
            obj.hasRunEnded = false;
            obj.coordinatedNodes = {};   % populate before starting experiment

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
            % Log every received message (mirrors base-class behaviour).
            fprintf("%s %s \u2192 %s\n", obj.FSMtag, topic, jsonencode(msg));

            % React to inter-run readiness events published by coordinated
            % nodes.  When any subscribed node signals INTER_RUN_READY, send
            % RunValid to all entries in coordinatedNodes so every node
            % proceeds to the next sub-experiment in lock-step.
            if isstruct(msg) && isfield(msg, 'state')
                switch string(msg.state)
                    case "INTER_RUN_READY"
                        nextIdx = "?";
                        if isfield(msg, 'nextExpIndex')
                            nextIdx = num2str(msg.nextExpIndex);
                        end
                        nextName = "";
                        if isfield(msg, 'nextExpName')
                            nextName = sprintf(" ('%s')", msg.nextExpName);
                        end
                        obj.log("INFO", sprintf( ...
                            "[COORD] INTER_RUN_READY from %s \u2014 sending RunValid to %d coordinated node(s) for sub-experiment %s%s.", ...
                            topic, numel(obj.coordinatedNodes), nextIdx, nextName));
                        for i = 1:numel(obj.coordinatedNodes)
                            obj.publishCmd(obj.coordinatedNodes{i}, 'RunValid');
                        end

                    case "INTER_RUN_TIMEOUT"
                        obj.log("WARN", sprintf( ...
                            "[COORD] INTER_RUN_TIMEOUT from %s \u2014 check node status before proceeding.", ...
                            topic));
                        % Policy: let the node continue (it uses its own onTimeout config).
                        % Override here if the control node should take a different action.
                end
            end
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
