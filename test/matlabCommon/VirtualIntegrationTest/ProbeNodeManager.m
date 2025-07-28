classdef ProbeNodeManager < ExperimentManager
    % ProbeNodeManager
    % Subclass representing a virtual wave probe that:
    % - Receives /cmd messages for calibration, testing, and run
    % - Listens to waveGenNode/data for synthetic wave input
    % - Adds noise and bias, logs measurements to /data
    % - Implements a simple calibration logic using user input
    % - Publishes status, data, and log messages

    properties
        gainSlope         % a: slope from linear fit (depth = a * voltage + b)
        gainIntercept     % b: intercept from linear fit
        noiseSigma       % Standard deviation of simulated sensor noise
        liveInput        % Latest wave field value received from waveGenNode
        isCollecting     % Flag used during running mode

        voltageDepthLog = [] % Store calibration data between calls
    end

    methods

        % Constructor
        function obj = ProbeNodeManager(cfg, comm, rest)
            % ProbeNodeManager Constructor
            % Initializes virtual probe node for wave sensing and simulation
            
            % Call superclass constructor (loads biasTable, calls initializeHardware)
            obj@ExperimentManager(cfg, comm, rest);
        
            % --- Node-specific initialization ---
            
            % Initialize the live wave input (value last received from waveGenNode/data)
            obj.liveInput = 0.0;
        
            % Default bias unless overridden by calibration file
            if ~isempty(obj.biasTable) && ...
               isfield(obj.biasTable, "slope") && ...
               isfield(obj.biasTable, "intercept")
            
                obj.gainSlope = obj.biasTable.slope;
                obj.gainIntercept = obj.biasTable.intercept;
                obj.log("INFO", sprintf("Loaded calibration: depth = %.3f × voltage + %.3f", ...
                                        obj.gainSlope, obj.gainIntercept));
            else
                % No calibration data found — fall back to identity model
                obj.gainSlope = 1.0;
                obj.gainIntercept = 0.0;
                obj.log("WARN", "No calibration model found. Using default linear model.");
            end
        
            % Initialize simulated noise model
            obj.noiseSigma = 0.001;  % cm (adjustable)
            
            % Flag to track whether we are collecting data (RUN state)
            obj.isCollecting = false;
        
            % Log successful creation
            obj.log("INFO", "ProbeNodeManager initialized.");
        end

        % Initialization
        function initializeHardware(obj, ~)
            % initializeHardware - Initializes virtual probe simulation environment.
            %
            % Called once from superclass constructor after loading calibration gains.
            % Responsible for setting up internal state and confirming bias status.
        
            fprintf("%s [INIT] Virtual probe hardware initialized. \n", obj.FSMtag);
        
            % Ensure buffer is empty at initialization
            obj.experimentData = [];
        
            % Log calibration load result
            try
                obj.log("INFO", sprintf("Probe initialized with bias table: depth = %.3f × voltage + %.3f", obj.biasTable.slope, obj.biasTable.intercept));
            catch
                obj.log("INFO", sprintf("Probe initialized without bias table"));
            end
            
        end

        % Configuration validator
        function isValid = configureHardware(obj, ~)
            % configureHardware - Validates configuration for virtual probe.
            %
            % For this is a sensor, no specific parameters are required to configure,
            % but we report the maximum detectable wave height for documentation purposes.
        
            fprintf("[CONFIG] ProbeNode accepts all config params. Max wave height measurable: 20.0 cm \n");
        
            % Always return true since this sensor does not require configuration
            isValid = true;
        
            % Optional logging for consistency
            obj.log("INFO", "ProbeNode configured (no constraints). Max measurable height: 20.0 cm");
        end

        % Calibration Handler
        function handleCalibrate(obj, cmd)
            % handleCalibrate - Collects (voltage, depth) calibration pairs and fits linear model.
            % Each call with a "depth" param logs the current voltage reading at that known depth.
            % On "finished", fits a line and saves gains.
        
            try
                fprintf("%s [CALIBRATION] handleCalibrate() called.\n", obj.FSMtag);
                disp(cmd);
            
                % Finalization
                if isfield(cmd.params, "finished") && cmd.params.finished == true
                    if isempty(obj.voltageDepthLog)
                        warning("%s [CALIBRATION] No data to finalize calibration.", obj.FSMtag);
                        obj.log("WARN", "Calibration ended without any points.");
                        obj.transition(State.IDLE);
                        obj.voltageDepthLog = [];
                        return;
                    end
            
                    % Fit linear model: depth = a * voltage + b
                    V = obj.voltageDepthLog(:,1);  % voltages
                    D = obj.voltageDepthLog(:,2);  % known depths
            
                    coeffs = polyfit(V, D, 1);  % [slope, intercept]
                    obj.gainSlope = coeffs(1);
                    obj.gainIntercept = coeffs(2);
            
                    % Save into biasTable for this node
                    obj.biasTable = struct( ...
                        "slope", obj.gainSlope, ...
                        "intercept", obj.gainIntercept ...
                    );
                    biasTable = obj.biasTable;
                    save("calibrationGains.mat", "biasTable");
            
                    fprintf("%s [CALIBRATION] Fitted: depth = %.3f × voltage + %.3f\n", ...
                        obj.FSMtag, obj.gainSlope, obj.gainIntercept);
                    obj.log("INFO", sprintf("Calibration model saved: depth = %.3f*V + %.3f", ...
                        obj.gainSlope, obj.gainIntercept));
            
                    obj.voltageDepthLog = [];  % clear persistent buffer
                    obj.transition(State.IDLE);
                    return;
                end
            
                % Handle single point
                if isfield(cmd.params, "depth")
                    % Simulated analog voltage = liveInput + noise
                    rawVoltage = obj.liveInput + obj.noiseSigma * randn();
                    knownDepth = cmd.params.depth;
            
                    obj.voltageDepthLog(end+1, :) = [rawVoltage, knownDepth];
            
                    fprintf("%s [CALIBRATION] Sampled V=%.3f V at depth=%.3f cm\n", ...
                        obj.FSMtag, rawVoltage, knownDepth);
                    obj.log("INFO", sprintf("Captured point: V=%.3f, depth=%.3f", ...
                        rawVoltage, knownDepth));
            
                    %obj.transition(State.CALIBRATING);
                else
                    obj.log("ERROR", "Malformed calibration: missing 'depth' or 'finished'.");
                    error("%s [CALIBRATION] Expected field 'depth' or 'finished' in cmd.params.", obj.FSMtag);
                end
            
            catch ME
                warning('%s [CALIBRATION ERROR] %s', obj.FSMtag, ME.message);
                disp(getReport(ME, 'extended'));
            end
        end


        % Run Experiment Handler
        function handleRun(obj, cmd)
            % handleRun - Starts data collection for the virtual probe during experiment run.
            % Assumes the node is already transitioned into RUNNING state externally.
        
            fprintf("%s [RUN] handleRun() called: \n", obj.FSMtag);
            disp(cmd);
        
            obj.isCollecting = true;  % Enable sampling logic in .step()

            obj.experimentData = [];
        
            obj.log("INFO", "ProbeNode RUN started: beginning wave height data collection.");
        
            % Node remains in RUNNING; transition to POSTPROC will occur after run duration externally
        end

        % Test Mode Handler
        function handleTest(obj, cmd)
            % handleTest - Initiates test mode for virtual probe sensor.
            % Emits diagnostic samples (biased, noisy wave readings).
            
            fprintf("%s [TEST] handleTest() called: \n", obj.FSMtag);
            disp(cmd);
        
            % Set flag to allow step() to emit test readings
            obj.isCollecting = true;
        
            obj.log("INFO", "ProbeNode test mode active. Emitting simulated readings.");
        end

        function onMessageCallback(obj, topic, msg)
            % Extend base callback for probe sensor + keep generic cmd support
            if strcmp(topic, "waveGenNode/data")
                % --- Decode msg if it's a JSON string ---
                try
                    if ischar(msg) || isstring(msg)
                        msg = jsondecode(msg);
                    end
                catch decodeErr
                    warning("%s [msgCallback] Failed to decode JSON message from %s: %s", obj.FSMtag, topic, decodeErr.message);
                    obj.log("WARN", sprintf("JSON decode error from topic %s: %s", topic, decodeErr.message));
                    return;
                end
                % --- Handle wave input ---
                if isstruct(msg) && isfield(msg, "value")
                    obj.liveInput = msg.value;
                    fprintf("%s [msgCallback] Updated liveInput: %.3f cm from %s\n", obj.FSMtag, msg.value, topic);
                else
                    warning("%s [msgCallback] Malformed waveGenNode/data message.", obj.FSMtag);
                    obj.log("WARN", "waveGenNode/data missing 'value' field.");
                end

            else
                onMessageCallback@ExperimentManager(obj, topic, msg);  % call superclass default
            end
        end


        % Loop Step Function
        function step(obj, t, final)
            % step - Executes one virtual sensing step if probe is collecting.
            % Applies linear calibration and noise, logs and publishes the result.
        
            if ~obj.isCollecting
                return;  % No action outside of active phases
            end
        
            % Simulate raw analog sensor input
            voltage = obj.liveInput;
            noise = obj.noiseSigma * randn();
        
            % Apply calibrated transformation (depth = a * V + b)
            depth = obj.gainSlope * voltage + obj.gainIntercept + noise;
        
            % Construct data packet
            reading = struct( ...
                "type", "wave_height", ...
                "value", depth, ...
                "units", "cm", ...
                "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS') ...
            );
        
            % Append to data buffer
            obj.experimentData = [obj.experimentData; reading];
        
            % Publish to /data
            obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
        
            % Print (optional)
            fprintf("%s [STEP] t=%.2fs : Measured Depth: %.3f cm (raw=%.3f V)\n", ...
                obj.FSMtag, t, depth, voltage);
        
            % Last data entry and will transition to new state
            if final
                obj.isCollecting = false;
            
                switch obj.state
                    case State.TESTINGSENSOR
                        obj.transition(State.IDLE);
                        obj.log("INFO", "ProbeNode test complete. Returning to IDLE.");
                    case State.RUNNING
                        obj.transition(State.POSTPROC);
                        obj.log("INFO", "Transitioned to POSTPROC after experiment run.");
                    otherwise
                        obj.log("WARN", "step(final=true) called from unexpected state: " + string(obj.state));
                        obj.transition(State.ERROR);
                end
            end
        end

        % Stop Handler
        function stopHardware(obj)
            % stopHardware - Halts virtual data collection and resets probe flags.
            
            obj.isCollecting = false;
            obj.log("INFO", "ProbeNode stopped. Data collection halted.");
            fprintf("%s [STOP] ProbeNode: Data collection halted and system is idle. \n", obj.FSMtag);
        end

        % Shutdown Handler
        function shutdownHardware(obj)
            % shutdownHardware - Final shutdown and cleanup for ProbeNode
            % Expected to be called within shutdown which saves logs and
            % disconnects CommClient.m
        
            obj.isCollecting = false;
            obj.experimentData = [];
            obj.voltageDepthLog = [];
            obj.log("INFO", "Sensor buffers cleared.");
        end
    end
end
