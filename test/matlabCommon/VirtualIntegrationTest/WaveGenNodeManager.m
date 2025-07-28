classdef WaveGenNodeManager < ExperimentManager
    % WaveGenNodeManager
    % Subclass representing a virtual wave generator (e.g., wave paddle)
    % - Accepts config and validates amplitude/frequency
    % - On RUN: generates a sine wave signal and publishes it in time
    % - On TEST: emits a few preview samples
    % - Publishes status, data, and log messages

    properties
        amplitude      % Peak amplitude of sine wave (cm)
        frequency      % Frequency of wave (Hz)
        duration       % Duration of wave generation (s)
        waveform       % Precomputed sine wave vector
        currentStep    % Simulation step index
        isGenerating   % Flag to emit waveform samples
    end

    methods

        % Constructor
        function obj = WaveGenNodeManager(cfg, comm, rest)
            % WaveGenNodeManager Constructor
            % Initializes actuator node for wave simulation and publication

            % Call superclass constructor
            obj@ExperimentManager(cfg, comm, rest);

            % Initialize flags and waveform
            obj.amplitude = 0.0;
            obj.frequency = 0.0;
            obj.duration = 0.0;
            obj.waveform = [];
            obj.currentStep = 1;
            obj.isGenerating = false;

            obj.log("INFO", "WaveGenNodeManager initialized.");
        end

        % Initialization
        function initializeHardware(obj, cfg)
            % initializeHardware - Prepares virtual actuator
            
            obj.waveform = [];
            obj.currentStep = 1;
            obj.isGenerating = false;
            obj.experimentData = [];

            fprintf("%s [INIT] Virtual wave generator initialized. \n", obj.FSMtag);
            obj.log("INFO", "WaveGenNode initialized and idle.");
        end

        % Configuration validator
        function isValid = configureHardware(obj, params)
            % configureHardware - Validates wave parameters and precomputes waveform.
        
            % Acceptable limits
            MAX_AMPLITUDE = 30.0;  % cm
            MAX_FREQUENCY = 2.3;   % Hz
        
            hasAmp = isfield(params, "amplitude") && isnumeric(params.amplitude) && params.amplitude > 0;
            hasFreq = isfield(params, "frequency") && isnumeric(params.frequency) && params.frequency > 0;
            hasDuration = isfield(params, "duration") && isnumeric(params.duration) && params.duration > 0;
        
            if ~hasAmp || ~hasFreq || ~hasDuration
                obj.log("WARN", "Missing or invalid amplitude/frequency/duration fields.");
                isValid = false;
                return;
            end
        
            % Validate against physical constraints
            if params.amplitude > MAX_AMPLITUDE || params.frequency > MAX_FREQUENCY || params.duration < 0
                obj.log("WARN", sprintf("WaveGen config rejected: amplitude > %.1f cm, frequency > %.1f Hz., or duration < 0", ...
                    MAX_AMPLITUDE, MAX_FREQUENCY));
                isValid = false;
                return;
            end
        
            % If valid: store parameters
            obj.amplitude = params.amplitude;
            obj.frequency = params.frequency;
            obj.duration = params.duration;
        
            % Regenerate waveform internally (based on fixed step size)
            dt = 0.01;         % sample step
            T = 0:dt:obj.duration;  % internal vector (or store in cfg later)
        
            obj.waveform = obj.amplitude * sin(2 * pi * obj.frequency * T);
            obj.currentStep = 1;
        
            obj.log("INFO", sprintf("WaveGen configured: %.2f cm, %.2f Hz, %.2f sec", ...
                obj.amplitude, obj.frequency, obj.duration));
            isValid = true;
        end


        % Run Handler
        function handleRun(obj, cmd)
            % handleRun - Starts waveform emission during experiment run

            fprintf("%s [RUN] handleRun() called: \n", obj.FSMtag);
            disp(cmd);

            obj.currentStep = 1;
            obj.isGenerating = true;
            obj.experimentData = [];
            obj.log("INFO", "WaveGen RUN started: publishing sine wave.");
        end

        % Test Handler
        function handleTest(obj, cmd)
            % handleTest - Emits a few preview samples (diagnostics)
            
            fprintf("%s [TEST] handleTest() called: \n", obj.FSMtag);
            disp(cmd);

            obj.currentStep = 1;
            obj.isGenerating = true;
            obj.log("INFO", "WaveGen test mode active. Emitting preview samples.");
        end

        function handleCalibrate(obj, cmd)
            % Will not include Calibration test for now
        end

        % Step Function
        function step(obj, t, final)
            % step - Emits waveform sample on each simulation tick
            % Only emits during TESTINGACTUATOR or RUNNING
        
            if ~obj.isGenerating || isempty(obj.waveform)
                return;
            end
        
            % Check if we've exhausted the waveform
            if obj.currentStep > length(obj.waveform)
                obj.isGenerating = false;
                switch obj.state
                    case State.RUNNING
                        obj.transition(State.POSTPROC);
                        obj.log("INFO", "WaveGen finished waveform. Transitioned to POSTPROC.");
                    case State.TESTINGACTUATOR
                        obj.transition(State.IDLE);
                        obj.log("INFO", "WaveGen actuator test complete. Returning to IDLE.");
                    otherwise
                        obj.log("WARN", "Waveform exhausted from unexpected state: " + string(obj.state));
                        obj.transition(State.ERROR);
                end
                return;
            end
        
            % Get current sample value
            waveValue = obj.waveform(obj.currentStep);
        
            % Only publish during RUNNING
            if obj.state == State.RUNNING
                msg = struct( ...
                    "type", "wave_height", ...
                    "value", waveValue, ...
                    "units", "cm", ...
                    "timestamp", datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS') ...
                );
                obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(msg));
                fprintf("%s [STEP] t=%.2fs: Wave Output: %.3f cm\n", obj.FSMtag, t, waveValue);

                obj.experimentData = [obj.experimentData; msg];
            elseif obj.state == State.TESTINGACTUATOR
                fprintf("%s [PREVIEW] t=%.2fs : Wave Sample: %.3f cm\n", obj.FSMtag, t, waveValue);
            end
        
            obj.currentStep = obj.currentStep + 1;
        
            % Handle forced finalization
            if final
                obj.isGenerating = false;
                switch obj.state
                    case State.RUNNING
                        obj.transition(State.POSTPROC);
                        obj.log("INFO", "WaveGen transitioned to POSTPROC after final step.");
                    case State.TESTINGACTUATOR
                        obj.transition(State.IDLE);
                        obj.log("INFO", "WaveGen actuator test complete. Returning to IDLE.");
                    otherwise
                        obj.log("WARN", "Final step issued from invalid state: " + string(obj.state));
                        obj.transition(State.ERROR);
                end
            end
        end

        % Stop Handler
        function stopHardware(obj)
            % stopHardware - Ends waveform emission and resets step counter

            obj.isGenerating = false;
            obj.currentStep = 1;
            obj.log("INFO", "WaveGen stopped. Output halted.");
            fprintf("%s [STOP] WaveGenNode: Emission halted.\n", obj.FSMtag);
        end

        % Shutdown Handler
        function shutdownHardware(obj)
            % shutdownHardware - Cleanup procedure
            
            obj.isGenerating = false;
            obj.waveform = [];
            obj.currentStep = 1;
            obj.experimentData = [];
            obj.log("INFO", "WaveGenNode cleared.");
        end
    end
end
