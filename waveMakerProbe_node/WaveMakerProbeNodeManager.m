classdef WaveMakerProbeNodeManager < ExperimentManager
    % WaveMakerProbeNodeManager
    %
    % Combined wave paddle actuator + wave probe sensor node.
    % Controls the wave paddle via NI-DAQ analog output (ao0) and acquires
    % data from up to 8 wave probe channels (ai0-ai7) simultaneously.
    % Both hasSensor and hasActuator must be true in the hardware config.
    %
    % All 8 probe channels are always added to the DAQ session at startup.
    % The subset of active probes (which are actually in the water) is
    % specified by the control node in the Configure command via activeProbes
    % (1-based indices). Only active probe channels are calibrated and saved.
    %
    % Calibration (probe gains):
    %   Multiple height points, one command per point:
    %     {"cmd":"Calibrate","params":{"selectedProbes":[1,2,3],
    %                                  "knownHeight_m":0.05}}
    %   Final command:
    %     {"cmd":"Calibrate","params":{"finished":true}}
    %   → polyfit(voltages, heights, 1) per selected probe
    %   → saves probe_gains.mat (1x8 gains vector)
    %   Non-selected probes keep their previous gain (default 1.0).
    %
    % Run:
    %   Generates sinusoidal paddle signal from Configure params
    %   (amplitude, frequency, duration). Uses preload + start("repeatoutput")
    %   + read pattern from original code. Applies gains and mean-centers
    %   active probe data, then stores in experimentData for base class CSV/REST.
    %
    % Required config fields (hardware section):
    %   daqDevice, allProbeChannels (8 IDs), paddleOutputChannel,
    %   sampleRate (100 Hz per original code), maxAmplitude, maxFrequency,
    %   probeGainsFile (path to probe_gains.mat)

    properties
        % Probe calibration — one gain (slope) per channel, 1x8 vector
        % gain(i) from: polyfit(voltage_array, height_array, 1) → take slope only
        % Default 1.0 (identity) until calibrated. Saved in probe_gains.mat.
        probeGains          % 1x8 double

        % Active probes selected for this experiment (1-based indices, e.g. [1 3 5])
        % Set by Configure command. Only these channels are calibrated and saved.
        activeProbes        % integer array

        % Calibration accumulation buffers
        calibSelectedProbes % which probes are being calibrated this session
        calibHeights_m      % Nx1: known heights collected so far
        calibVoltages       % NxP: mean voltages per selected probe per point

        % Acquisition state
        isCollecting        % logical
        isGenerating        % logical
        duration            % seconds, set by Configure
        sampleRate          % Hz, from hardware config (100 per original code)

        % Hardware
        daqSession          % NI-DAQ session object
        paddleChannel       % output channel ID (from config)
    end

    methods

        function obj = WaveMakerProbeNodeManager(cfg, comm, rest)
            % Constructor — ExperimentManager base calls initializeHardware first.
            obj@ExperimentManager(cfg, comm, rest);

            obj.probeGains    = ones(1, 8);   % identity until calibrated
            obj.activeProbes  = [];
            obj.isCollecting  = false;
            obj.isGenerating  = false;
            obj.calibSelectedProbes = [];
            obj.calibHeights_m      = [];
            obj.calibVoltages       = [];

            % Load probe gains if previously saved
            gainsFile = cfg.hardware.probeGainsFile;
            if isfile(gainsFile)
                loaded = load(gainsFile, 'gains');
                if isfield(loaded, 'gains') && numel(loaded.gains) == 8
                    obj.probeGains = loaded.gains;
                    obj.log("INFO", sprintf("Probe gains loaded: [%s]", ...
                        strjoin(arrayfun(@(v) sprintf("%.4f", v), obj.probeGains, 'UniformOutput', false), ', ')));
                end
            else
                obj.log("WARN", "No probe_gains.mat found. Using identity gains (1.0) until calibrated.");
            end

            obj.log("INFO", "WaveMakerProbeNodeManager initialized.");
        end

        function initializeHardware(obj, cfg)
            % initializeHardware
            % Adds all 8 probe input channels (ai0-ai7) and the paddle output
            % channel (ao0) to the DAQ session at 100 Hz.
            % All 8 channels are always added regardless of activeProbes —
            % activeProbes is a runtime Configure parameter, not a DAQ concern.
            %
            % Required cfg.hardware fields:
            %   daqDevice           — NI device ID (e.g. 'Dev1')
            %   allProbeChannels    — cell array of 8 channel IDs (ai0-ai7)
            %   paddleOutputChannel — analog output channel ID (ao0)
            %   sampleRate          — DAQ rate in Hz (100 per original code)

            obj.experimentData = [];
            obj.isCollecting   = false;
            obj.isGenerating   = false;
            obj.sampleRate     = cfg.hardware.sampleRate;
            obj.paddleChannel  = cfg.hardware.paddleOutputChannel;

            obj.daqSession      = daq("ni");
            obj.daqSession.Rate = obj.sampleRate;

            % Add all 8 probe input channels (fixed order = column indices in read())
            for k = 1:numel(cfg.hardware.allProbeChannels)
                addinput(obj.daqSession, cfg.hardware.daqDevice, cfg.hardware.allProbeChannels{k}, "Voltage");
            end

            % Add paddle analog output channel
            addoutput(obj.daqSession, cfg.hardware.daqDevice, obj.paddleChannel, "Voltage");

            obj.log("INFO", sprintf("DAQ session ready: 8 probe inputs + 1 paddle output at %d Hz.", obj.sampleRate));
        end

        function isValid = configureHardware(obj, params)
            % configureHardware
            % Validates Configure params: activeProbes array, amplitude,
            % frequency, and duration. Stores activeProbes for use in Run.

            MAX_AMPLITUDE = obj.cfg.hardware.maxAmplitude;
            MAX_FREQUENCY = obj.cfg.hardware.maxFrequency;

            hasProbes   = isfield(params, 'activeProbes') && isnumeric(params.activeProbes) ...
                          && ~isempty(params.activeProbes) ...
                          && all(params.activeProbes >= 1 & params.activeProbes <= 8);
            hasAmp      = isfield(params, 'amplitude') && isnumeric(params.amplitude) && params.amplitude > 0;
            hasFreq     = isfield(params, 'frequency') && isnumeric(params.frequency) && params.frequency > 0;
            hasDuration = isfield(params, 'duration')  && isnumeric(params.duration)  && params.duration  > 0;

            if ~hasProbes
                obj.log("WARN", "configureHardware: activeProbes must be a non-empty array with indices 1-8.");
                isValid = false; return;
            end
            if ~hasAmp || ~hasFreq || ~hasDuration
                obj.log("WARN", "configureHardware: missing amplitude, frequency, or duration.");
                isValid = false; return;
            end
            if params.amplitude > MAX_AMPLITUDE
                obj.log("WARN", sprintf("Amplitude %.3f m exceeds limit %.3f m.", params.amplitude, MAX_AMPLITUDE));
                isValid = false; return;
            end
            if params.frequency > MAX_FREQUENCY
                obj.log("WARN", sprintf("Frequency %.2f Hz exceeds limit %.2f Hz.", params.frequency, MAX_FREQUENCY));
                isValid = false; return;
            end

            obj.log("INFO", sprintf("Config valid: probes=[%s], %.3f m, %.2f Hz, %.1f s.", ...
                strjoin(arrayfun(@(x) num2str(x), params.activeProbes, 'UniformOutput', false), ','), ...
                params.amplitude, params.frequency, params.duration));
            isValid = true;
        end

        function setupCurrentExperiment(obj)
            setupCurrentExperiment@ExperimentManager(obj);
            obj.experimentData = [];
            obj.isCollecting   = false;
            obj.isGenerating   = false;

            if isfield(obj.experimentSpec.params, 'experiments')
                currentParams = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
            else
                currentParams = obj.experimentSpec.params;
            end

            obj.duration = currentParams.duration;

            % Set activeProbes here (not in configureHardware) so multi-experiment
            % validation loops do not overwrite it before each experiment runs.
            if isfield(currentParams, 'activeProbes')
                obj.activeProbes = currentParams.activeProbes;
            end

            obj.log("INFO", sprintf("WaveMakerProbe experiment ready: duration=%.1f s, probes=[%s].", ...
                obj.duration, ...
                strjoin(arrayfun(@(x) num2str(x), obj.activeProbes, 'UniformOutput', false), ',')));
        end

        function handleCalibrate(obj, cmd)
            % handleCalibrate
            % Multi-point linear calibration per selected probe channel.
            %
            % Each non-finished command must include:
            %   params.selectedProbes   — 1-based probe indices (e.g. [1 3 5])
            %   params.knownHeight_m    — known water height in metres
            % The selectedProbes value from the first call is locked in for
            % the session; subsequent calls may omit it.
            %
            % Final command:
            %   params.finished = true
            % → polyfit(voltages, heights, 1) per selected probe (slope only)
            % → updates obj.probeGains for those channels
            % → saves probe_gains.mat (1x8 gains vector, unselected probes unchanged)
            %
            % This matches the Part 2 calibration loop in the original .m code.

            try
                if isfield(cmd.params, 'finished') && cmd.params.finished

                    if isempty(obj.calibHeights_m) || size(obj.calibHeights_m, 1) < 2
                        obj.log("WARN", "Calibration finished with fewer than 2 points. Need at least 2.");
                        obj.calibHeights_m = []; obj.calibVoltages = []; obj.calibSelectedProbes = [];
                        obj.transition(State.IDLE);
                        return;
                    end

                    for k = 1:numel(obj.calibSelectedProbes)
                        probeIdx = obj.calibSelectedProbes(k);
                        V = obj.calibVoltages(:, k);
                        H = obj.calibHeights_m;
                        p = polyfit(V, H, 1);          % polyfit(voltage, height, 1)
                        obj.probeGains(probeIdx) = p(1);  % slope only; mean-centering handles DC
                        obj.log("INFO", sprintf("Probe H%d calibrated: gain=%.4f (intercept=%.4f discarded).", ...
                            probeIdx, p(1), p(2)));
                    end

                    gains = obj.probeGains;
                    gainsFile = obj.cfg.hardware.probeGainsFile;
                    save(gainsFile, 'gains');
                    obj.log("INFO", sprintf("probe_gains.mat saved: [%s]", ...
                        strjoin(arrayfun(@(v) sprintf("%.4f", v), obj.probeGains, 'UniformOutput', false), ', ')));

                    obj.calibHeights_m = []; obj.calibVoltages = []; obj.calibSelectedProbes = [];
                    obj.transition(State.IDLE);

                else
                    % Collect one calibration point
                    knownHeight = cmd.params.knownHeight_m;

                    % Lock in selectedProbes on first call
                    if isempty(obj.calibSelectedProbes)
                        if ~isfield(cmd.params, 'selectedProbes')
                            obj.log("ERROR", "First calibrate command must include params.selectedProbes.");
                            return;
                        end
                        sp = cmd.params.selectedProbes;
                        if any(sp < 1 | sp > 8)
                            obj.log("ERROR", "selectedProbes must be indices 1-8.");
                            return;
                        end
                        obj.calibSelectedProbes = sp;
                        obj.log("INFO", sprintf("Calibrating probes: [%s]", ...
                            strjoin(arrayfun(@(x) sprintf("H%d",x), sp, 'UniformOutput', false), ', ')));
                    end

                    % Read 1 second, take mean voltage per channel
                    rawRead = read(obj.daqSession, seconds(1));
                    rawArr  = mean(rawRead.Variables, 1);   % 1x8

                    % Extract only selected probe columns
                    meanVoltages = rawArr(obj.calibSelectedProbes);

                    obj.calibHeights_m = [obj.calibHeights_m; knownHeight];
                    obj.calibVoltages  = [obj.calibVoltages;  meanVoltages];

                    nPts = size(obj.calibHeights_m, 1);
                    obj.log("INFO", sprintf("Calib point %d: height=%.4f m, voltages=[%s].", ...
                        nPts, knownHeight, ...
                        strjoin(arrayfun(@(v) sprintf("%.4f",v), meanVoltages, 'UniformOutput', false), ', ')));
                end

            catch ME
                obj.log("ERROR", sprintf("handleCalibrate exception: %s", ME.message));
                rethrow(ME);
            end
        end

        function handleTest(obj, cmd)
            % handleTest
            % Routes by cmd.params.target:
            %   "sensor"   — streams live probe readings while in TESTINGSENSOR
            %   "actuator" — runs a short sinusoidal paddle preview while in TESTINGACTUATOR

            target = string(cmd.params.target);
            obj.log("INFO", sprintf("handleTest: target=%s.", target));

            if target == "sensor"
                if isempty(obj.activeProbes)
                    obj.log("WARN", "handleTest (sensor): no activeProbes set. Send Configure first.");
                    obj.transition(State.IDLE);
                    return;
                end

                obj.log("INFO", "Streaming probe readings. Send Reset to stop.");
                while obj.state == State.TESTINGSENSOR
                    rawRead = read(obj.daqSession, 1);   % 1 scan
                    rawArr  = rawRead.Variables;          % 1x8

                    heights = rawArr .* obj.probeGains;   % apply gains
                    reading = struct('type', 'wave_height', 'units', 'm', ...
                        'timestamp', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')));
                    for k = obj.activeProbes
                        reading.(sprintf('H%d', k)) = heights(k);
                    end
                    obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
                end

            else  % actuator
                params = cmd.params;
                nSamples     = round(params.duration * obj.sampleRate);
                T            = (0 : nSamples-1)' / obj.sampleRate;
                paddleSignal = params.amplitude * sin(2*pi*params.frequency*T);

                obj.log("INFO", sprintf("Actuator test: %.3f m @ %.2f Hz for %.1f s.", ...
                    params.amplitude, params.frequency, params.duration));

                preload(obj.daqSession, paddleSignal);
                start(obj.daqSession, "repeatoutput");
                pause(params.duration);
                stop(obj.daqSession);

                obj.log("INFO", "Actuator test complete.");
                obj.transition(State.IDLE);
            end
        end

        function handleRun(obj, cmd)
            % handleRun
            % Generates a sinusoidal paddle signal and simultaneously acquires
            % all 8 probe channels. Applies gains and mean-centers active probes.
            % Uses preload + start("repeatoutput") + read pattern from original code.

            obj.isCollecting  = true;
            obj.isGenerating  = true;

            if isfield(obj.experimentSpec.params, 'experiments')
                p = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
            else
                p = obj.experimentSpec.params;
            end

            nSamples     = round(obj.duration * obj.sampleRate);
            T            = (0 : nSamples-1)' / obj.sampleRate;          % Nx1 column vector
            paddleSignal = p.amplitude * sin(2*pi*p.frequency*T);        % Nx1 column vector

            obj.log("INFO", sprintf("handleRun: %.3f m @ %.2f Hz for %.1f s (%d samples).", ...
                p.amplitude, p.frequency, obj.duration, nSamples));

            % Preload paddle output, start simultaneous output+acquisition, read probes
            preload(obj.daqSession, paddleSignal);
            start(obj.daqSession, "repeatoutput");
            rawData = read(obj.daqSession, seconds(obj.duration));
            stop(obj.daqSession);

            obj.isGenerating = false;

            % Apply gains: height(i) = voltage(i) * probeGains(i)
            rawArr     = rawData.Variables;                  % nSamples x 8
            heightData = rawArr .* obj.probeGains;           % broadcast 1x8 gains

            % Mean-center each channel (removes DC offset, matches original code)
            heightData = heightData - mean(heightData, 1);

            % Build output struct array for active probes + time column
            fields = [{'nTime'}, arrayfun(@(x) sprintf('H%d',x), obj.activeProbes, 'UniformOutput', false)];
            values = [{num2cell(T)}];
            for k = obj.activeProbes
                values{end+1} = num2cell(heightData(:, k)); %#ok<AGROW>
            end
            args = [fields; values];
            obj.experimentData = struct(args{:});

            obj.isCollecting = false;
            obj.log("INFO", sprintf("handleRun: complete. Stored %d samples for probes [%s].", ...
                nSamples, strjoin(arrayfun(@(x) sprintf("H%d",x), obj.activeProbes, 'UniformOutput', false), ',')));
            obj.transition(State.POSTPROC);
        end

        function stopHardware(obj)
            obj.isCollecting = false;
            obj.isGenerating = false;
            obj.log("INFO", "stopHardware: halting DAQ and zeroing paddle output.");
            try
                stop(obj.daqSession);
                write(obj.daqSession, 0);   % safe-zero paddle
            catch ME
                obj.log("WARN", sprintf("stopHardware DAQ error: %s", ME.message));
            end
        end

        function shutdownHardware(obj)
            obj.isCollecting   = false;
            obj.isGenerating   = false;
            obj.experimentData = [];
            obj.log("INFO", "shutdownHardware: releasing DAQ resources.");
            try
                stop(obj.daqSession);
                write(obj.daqSession, 0);
                delete(obj.daqSession);
            catch ME
                obj.log("WARN", sprintf("shutdownHardware DAQ release error: %s", ME.message));
            end
        end

    end
end
