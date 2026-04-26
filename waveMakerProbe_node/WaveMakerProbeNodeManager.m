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
        amplitude           % desired wave HEIGHT in metres (not volts), set by Configure
        frequency           % wave frequency in Hz, set by Configure
        sampleRate          % Hz, from hardware config (100 per original code)

        % Wavemaker transfer function model (loaded from wavemaker_model.mat).
        % Maps: paddle voltage (V) → wave height (cm).
        % Used in setupCurrentExperiment to convert the desired wave height
        % parameter (metres) into the DAQ output voltage command:
        %   U_amplitude_V = (amplitude_m * 100) / |H(j·2π·f)|
        wavemakerModel      % tf / ss / zpk object (or [] if file not found)

        % Pre-computed paddle VOLTAGE signal (Nx1, volts).
        % Built in setupCurrentExperiment with Hann-window taper applied.
        % Used directly by handleRun — no recomputation needed.
        paddleSignal        % double column vector (V)

        % Signal type for the current experiment (set by Configure command).
        % One of: 'sinusoidal', 'bretschneider', 'pulse_sinusoidal', 'dual_pulse'
        % Default: 'sinusoidal'.  See configureHardware for required params per type.
        signalType          % char / string

        % Signal-type-specific parameters (set by Configure command).
        % Contents depend on signalType — see configureHardware docstring.
        signalParams        % struct

        % Pre-computed paddle signals for all sub-experiments in multi-mode.
        % Populated by precomputeAllSignals() at CONFIGUREPENDING time.
        % allPaddleSignals{i} is the voltage signal (V, column vector) for experiment i.
        allPaddleSignals    % 1×N cell array (empty until multi-experiment configured)

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
            obj.amplitude    = 0;
            obj.frequency    = 0;
            obj.paddleSignal = [];
            obj.signalType   = 'sinusoidal';
            obj.signalParams = struct();
            obj.allPaddleSignals = {};

            nodeDir = fileparts(mfilename('fullpath'));
            obj.logDir = fullfile(nodeDir, 'waveMakerProbeNodeLogs');

            % Load wavemaker transfer function (voltage → wave height in cm).
            % Variable name inside the .mat file must be 'wavemaker_model'.
            wavemakerModelFile = fullfile(nodeDir, 'wavemaker_model.mat');
            if isfile(wavemakerModelFile)
                loaded = load(wavemakerModelFile, 'wavemaker_model');
                if isfield(loaded, 'wavemaker_model')
                    obj.wavemakerModel = loaded.wavemaker_model;
                    obj.log("INFO", "Wavemaker transfer function model loaded.");
                else
                    obj.wavemakerModel = [];
                    obj.log("WARN", "wavemaker_model.mat exists but 'wavemaker_model' variable not found.");
                end
            else
                obj.wavemakerModel = [];
                obj.log("WARN", "wavemaker_model.mat not found — amplitude will be sent as voltage (uncalibrated).");
            end

            % Load probe gains if previously saved.
            % Calibration always saves the full 1x8 vector: calibrated probes
            % get new gains, uncalibrated probes keep their existing value
            % (default 1.0). So a partial calibration (e.g. 3 probes) loads
            % correctly — the other 5 slots retain their prior values.
            gainsFile = cfg.hardware.probeGainsFile;
            if isfile(gainsFile)
                loaded = load(gainsFile, 'gains');
                if isfield(loaded, 'gains') && numel(loaded.gains) == 8
                    obj.probeGains = loaded.gains;
                    obj.log("INFO", sprintf("Probe gains loaded: [%s]", ...
                        strjoin(arrayfun(@(v) sprintf('%.4f', v), obj.probeGains, 'UniformOutput', false), ', ')));
                end
            else
                obj.log("WARN", "No probe_gains.mat found. Using identity gains (1.0) until calibrated.");
            end

            obj.log("INFO", "WaveMakerProbeNodeManager initialized.");
        end

        function setActiveProbes(obj, probeIndices)
            % setActiveProbes
            % Directly set which probe channels are active without going through
            % a full Run → CONFIGUREPENDING cycle. Useful when swapping probes
            % during bench testing or when building a UI that configures the
            % sensor independently of the actuator.
            %
            % Accepts a numeric array of 1-based probe indices (1–8).
            % The node does NOT need to be in any particular FSM state — the
            % method is callable from IDLE or CONFIGUREPENDING alike.
            %
            % Example:
            %   node.setActiveProbes([1 2 3]);   % activate probes 1, 2, 3
            %   node.setActiveProbes(1:8);        % activate all probes
            if ~isnumeric(probeIndices) || isempty(probeIndices) ...
                    || ~all(probeIndices >= 1 & probeIndices <= 8)
                obj.log("WARN", "setActiveProbes: input must be a non-empty numeric array with indices 1–8. No change made.");
                return;
            end
            obj.activeProbes = probeIndices(:)';   % always store as row vector
            obj.log("INFO", sprintf("Active probes set to [%s].", ...
                strjoin(arrayfun(@(x) num2str(x), obj.activeProbes, 'UniformOutput', false), ', ')));
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
            % Validates Configure params. Returns true if all are in range.
            %
            % Common required fields (all signal types):
            %   params.activeProbes  — 1-based probe indices (e.g. [1 3 5], max index 8)
            %   params.duration      — experiment duration in seconds (total, incl. zero-pad)
            %   params.signalType    — string, one of the types below (default: 'sinusoidal')
            %
            % Hardware limits (from cfg.hardware):
            %   maxAmplitude — max DAQ OUTPUT VOLTAGE in VOLTS (e.g. 1.2 V).
            %                  Limits the paddle signal amplitude, not the wave height directly.
            %                  The wavemaker model converts wave height → voltage for the check.
            %                  amplitude=0 or frequency=0 produces a flat zero signal (always passes).
            %   maxFrequency — max signal frequency in Hz (e.g. 2.5 Hz).
            %                  Applied to sinusoidal, pulse_sinusoidal, and dual_pulse.
            %                  Bretschneider is EXEMPT — PSD naturally bounds high-frequency energy.
            %
            % ── signalType: 'sinusoidal'  (default, mirrors MITestTank case 2) ──
            %   params.amplitude   — desired wave HEIGHT in METRES (converted to V via model)
            %   params.frequency   — frequency in Hz  (must be <= maxFrequency)
            %   Example: struct('activeProbes',[1 2 3],'signalType','sinusoidal',...
            %                   'amplitude',0.01,'frequency',1.0,'duration',60)
            %
            % ── signalType: 'bretschneider'  (mirrors case 1) ──
            %   params.significantWaveHeight_m  — Hs in metres
            %   params.modalFrequency_radps     — w_m in rad/s
            %   Example: struct('activeProbes',[1 2 3],'signalType','bretschneider',...
            %                   'significantWaveHeight_m',0.04,...
            %                   'modalFrequency_radps',3.14,'duration',120)
            %
            % ── signalType: 'pulse_sinusoidal'  (mirrors case 4) ──
            %   params.amplitude   — wave HEIGHT in metres
            %   params.frequency   — Hz  (must be <= maxFrequency)
            %   params.numPulses   — number of sinusoidal cycles (integer >= 1)
            %   (duration must accommodate pulse + zero-padding)
            %
            % ── signalType: 'dual_pulse'  (mirrors case 5) ──
            %   params.amplitude1_m        — first pulse wave height (m)
            %   params.frequency1_Hz       — first pulse frequency (Hz, <= maxFrequency)
            %   params.numPulses1          — cycles in first pulse
            %   params.wavePauseDuration_s — silence between pulses (s)
            %   params.amplitude2_m        — second pulse wave height (m)
            %   params.frequency2_Hz       — second pulse frequency (Hz, <= maxFrequency)
            %   params.numPulses2          — cycles in second pulse

            MAX_AMPLITUDE = obj.cfg.hardware.maxAmplitude;   % V  (DAQ output voltage limit)
            MAX_FREQUENCY = obj.cfg.hardware.maxFrequency;   % Hz (linear actuator limit)

            % --- Common checks (all signal types) ---
            hasProbes   = isfield(params, 'activeProbes') && isnumeric(params.activeProbes) ...
                          && ~isempty(params.activeProbes) ...
                          && all(params.activeProbes >= 1 & params.activeProbes <= 8);
            hasDuration = isfield(params, 'duration') && isnumeric(params.duration) && params.duration > 0;

            if ~hasProbes
                obj.log("WARN", "configureHardware: activeProbes must be a non-empty array with indices 1-8.");
                isValid = false; return;
            end
            if ~hasDuration
                obj.log("WARN", "configureHardware: duration missing or <= 0.");
                isValid = false; return;
            end

            % --- Signal type ---
            if isfield(params, 'signalType') && ~isempty(params.signalType)
                sType = string(params.signalType);
            else
                sType = "sinusoidal";   % backward-compatible default
            end

            probeStr = strjoin(arrayfun(@(x) num2str(x), params.activeProbes, 'UniformOutput', false), ',');

            switch sType
                case "sinusoidal"
                    if ~isfield(params,'amplitude') || ~isnumeric(params.amplitude) || params.amplitude < 0
                        obj.log("WARN", "sinusoidal: amplitude must be >= 0. This is wave HEIGHT in metres, not a voltage.");
                        isValid = false; return;
                    end
                    if ~isfield(params,'frequency') || ~isnumeric(params.frequency) || params.frequency < 0
                        obj.log("WARN", "sinusoidal: frequency must be >= 0 (Hz).");
                        isValid = false; return;
                    end
                    if params.frequency > MAX_FREQUENCY
                        obj.log("WARN", sprintf("sinusoidal: frequency %.2f Hz exceeds hardware limit %.2f Hz.", ...
                            params.frequency, MAX_FREQUENCY));
                        isValid = false; return;
                    end
                    % Voltage check: amplitude=0 or frequency=0 → U=0, always safe.
                    % Otherwise convert wave height → voltage via model and compare to MAX_AMPLITUDE.
                    U_amp = obj.heightToVoltage_V(params.amplitude, params.frequency);
                    if U_amp > MAX_AMPLITUDE
                        obj.log("WARN", sprintf( ...
                            "sinusoidal: amplitude %.4f m requires %.4f V paddle voltage, exceeding hardware limit %.4f V. " + ...
                            "Note: amplitude is wave height in METRES — if you meant %.4f V, reduce amplitude accordingly.", ...
                            params.amplitude, U_amp, MAX_AMPLITUDE, params.amplitude));
                        isValid = false; return;
                    end
                    obj.log("INFO", sprintf("Config valid [sinusoidal]: probes=[%s], %.4f m, %.2f Hz, %.1f s.", ...
                        probeStr, params.amplitude, params.frequency, params.duration));

                case "bretschneider"
                    % Bretschneider is exempt from maxFrequency — spectral content is
                    % bounded by the PSD shape (99% energy cut-off) not by maxFrequency.
                    % No voltage check either — random Rayleigh amplitudes can't be
                    % bounded ahead of synthesis. The DAQ output clamp provides the
                    % hard limit at runtime.
                    if ~isfield(params,'significantWaveHeight_m') || params.significantWaveHeight_m < 0
                        obj.log("WARN", "bretschneider: significantWaveHeight_m must be >= 0 (metres).");
                        isValid = false; return;
                    end
                    if ~isfield(params,'modalFrequency_radps') || params.modalFrequency_radps < 0
                        obj.log("WARN", "bretschneider: modalFrequency_radps must be >= 0 (rad/s).");
                        isValid = false; return;
                    end
                    obj.log("INFO", sprintf("Config valid [bretschneider]: probes=[%s], Hs=%.4f m, w_m=%.2f rad/s, %.1f s.", ...
                        probeStr, params.significantWaveHeight_m, params.modalFrequency_radps, params.duration));

                case "pulse_sinusoidal"
                    if ~isfield(params,'amplitude') || params.amplitude < 0
                        obj.log("WARN", "pulse_sinusoidal: amplitude must be >= 0. This is wave HEIGHT in metres, not a voltage.");
                        isValid = false; return;
                    end
                    if ~isfield(params,'frequency') || params.frequency < 0
                        obj.log("WARN", "pulse_sinusoidal: frequency must be >= 0 (Hz).");
                        isValid = false; return;
                    end
                    if ~isfield(params,'numPulses') || ~isnumeric(params.numPulses) ...
                            || params.numPulses < 1 || mod(params.numPulses,1) ~= 0
                        obj.log("WARN", "pulse_sinusoidal: numPulses must be a positive integer.");
                        isValid = false; return;
                    end
                    if params.frequency > MAX_FREQUENCY
                        obj.log("WARN", sprintf("pulse_sinusoidal: frequency %.2f Hz exceeds hardware limit %.2f Hz.", ...
                            params.frequency, MAX_FREQUENCY));
                        isValid = false; return;
                    end
                    U_amp = obj.heightToVoltage_V(params.amplitude, params.frequency);
                    if U_amp > MAX_AMPLITUDE
                        obj.log("WARN", sprintf( ...
                            "pulse_sinusoidal: amplitude %.4f m requires %.4f V paddle voltage, exceeding hardware limit %.4f V. " + ...
                            "Note: amplitude is wave height in METRES — if you meant %.4f V, reduce amplitude accordingly.", ...
                            params.amplitude, U_amp, MAX_AMPLITUDE, params.amplitude));
                        isValid = false; return;
                    end
                    obj.log("INFO", sprintf("Config valid [pulse_sinusoidal]: probes=[%s], %.4f m, %.2f Hz, %d pulses, %.1f s total.", ...
                        probeStr, params.amplitude, params.frequency, params.numPulses, params.duration));

                case "dual_pulse"
                    required = {'amplitude1_m','frequency1_Hz','numPulses1', ...
                                'wavePauseDuration_s','amplitude2_m','frequency2_Hz','numPulses2'};
                    for ri = 1:numel(required)
                        if ~isfield(params, required{ri})
                            obj.log("WARN", sprintf("dual_pulse: missing param '%s'.", required{ri}));
                            isValid = false; return;
                        end
                    end
                    if params.amplitude1_m < 0 || params.amplitude2_m < 0
                        obj.log("WARN", "dual_pulse: amplitudes must be >= 0. These are wave HEIGHTS in metres, not voltages.");
                        isValid = false; return;
                    end
                    if params.frequency1_Hz < 0 || params.frequency2_Hz < 0
                        obj.log("WARN", "dual_pulse: frequencies must be >= 0 (Hz).");
                        isValid = false; return;
                    end
                    if params.frequency1_Hz > MAX_FREQUENCY || params.frequency2_Hz > MAX_FREQUENCY
                        obj.log("WARN", sprintf("dual_pulse: frequency exceeds hardware limit %.2f Hz.", MAX_FREQUENCY));
                        isValid = false; return;
                    end
                    U1_amp = obj.heightToVoltage_V(params.amplitude1_m, params.frequency1_Hz);
                    U2_amp = obj.heightToVoltage_V(params.amplitude2_m, params.frequency2_Hz);
                    if U1_amp > MAX_AMPLITUDE || U2_amp > MAX_AMPLITUDE
                        obj.log("WARN", sprintf( ...
                            "dual_pulse: amplitudes [%.4f m, %.4f m] require paddle voltages [%.4f V, %.4f V], " + ...
                            "exceeding hardware limit %.4f V. Note: amplitudes are wave HEIGHT in METRES, not voltages.", ...
                            params.amplitude1_m, params.amplitude2_m, U1_amp, U2_amp, MAX_AMPLITUDE));
                        isValid = false; return;
                    end
                    obj.log("INFO", sprintf("Config valid [dual_pulse]: probes=[%s], [%.4f m %.2f Hz x%d] + pause %.1f s + [%.4f m %.2f Hz x%d], %.1f s total.", ...
                        probeStr, params.amplitude1_m, params.frequency1_Hz, params.numPulses1, ...
                        params.wavePauseDuration_s, params.amplitude2_m, params.frequency2_Hz, ...
                        params.numPulses2, params.duration));

                otherwise
                    obj.log("WARN", sprintf("configureHardware: unknown signalType '%s'. Use sinusoidal, bretschneider, pulse_sinusoidal, or dual_pulse.", sType));
                    isValid = false; return;
            end

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

            % Signal type (default: 'sinusoidal' for backward compatibility)
            if isfield(currentParams, 'signalType') && ~isempty(currentParams.signalType)
                obj.signalType = char(currentParams.signalType);
            else
                obj.signalType = 'sinusoidal';
            end

            % Build signalParams struct and mirror scalar props for legacy code paths.
            obj.signalParams = currentParams;   % pass-through: computeAndPreviewSignal reads what it needs
            % Also keep obj.amplitude / obj.frequency set for sinusoidal/pulse handleTest compatibility.
            if isfield(currentParams, 'amplitude'),  obj.amplitude  = currentParams.amplitude;  end
            if isfield(currentParams, 'frequency'),  obj.frequency  = currentParams.frequency;  end

            obj.log("INFO", sprintf("WaveMakerProbe experiment ready: type='%s', duration=%.1f s, probes=[%s].", ...
                obj.signalType, obj.duration, ...
                strjoin(arrayfun(@(x) num2str(x), obj.activeProbes, 'UniformOutput', false), ',')));

            % Pre-compute paddle voltage signal and send preview to REST.
            % The control node can fetch this after receiving CONFIGUREPENDING
            % to display U(t) and X(t) before sending RunValid.
            obj.computeAndPreviewSignal();

            % For multi-experiment runs, pre-compute signals for all sub-experiments
            % so they are available at CONFIGUREPENDING for operator preview.
            % Only done on first setup (index 1) to avoid redundant work.
            if isfield(obj.experimentSpec.params, 'experiments') && obj.currentExperimentIndex == 1
                obj.precomputeAllSignals();
            end
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
                        strjoin(arrayfun(@(v) sprintf('%.4f', v), obj.probeGains, 'UniformOutput', false), ', ')));

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
                            strjoin(arrayfun(@(x) sprintf('H%d',x), sp, 'UniformOutput', false), ', ')));
                    end

                    % Read 1 second, take mean voltage per channel.
                    % NI requires readwrite() when both AI and AO channels exist.
                    nScans = max(1, round(obj.sampleRate * 1.0));
                    rawRead = readwrite(obj.daqSession, zeros(nScans, 1));
                    rawArr  = mean(rawRead.Variables, 1);   % 1x8

                    % Extract only selected probe columns
                    meanVoltages = rawArr(obj.calibSelectedProbes);

                    obj.calibHeights_m = [obj.calibHeights_m; knownHeight];
                    obj.calibVoltages  = [obj.calibVoltages;  meanVoltages];

                    nPts = size(obj.calibHeights_m, 1);
                    obj.log("INFO", sprintf("Calib point %d: height=%.4f m, voltages=[%s].", ...
                        nPts, knownHeight, ...
                        strjoin(arrayfun(@(v) sprintf('%.4f',v), meanVoltages, 'UniformOutput', false), ', ')));
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

                blockSize = 5;
                % Start DAQ in background once so the session stays running.
                % streamOneBlock then calls read() which is non-blocking (pulls from
                % the live buffer), keeping the MATLAB thread free for MQTT messages.
                zeroBuf = zeros(obj.sampleRate, 1);   % 1-second zero output (repeats)
                preload(obj.daqSession, zeroBuf);
                start(obj.daqSession, "repeatoutput");
                t = timer('ExecutionMode', 'fixedRate', 'Period', 0.1, 'BusyMode', 'drop', ...
                           'TimerFcn', @(~,~) obj.streamOneBlock(blockSize));
                obj.log("INFO", "Probe stream timer started (period=0.1 s, 5-scan blocks). Send Reset to stop.");
                start(t);

            else  % actuator
                p = cmd.params;
                nSamples = round(p.duration * obj.sampleRate);
                % Use the exact precomputed preview signal so the plotted waveform
                % at CONFIGUREPENDING is identical to what is sent to DAQ.
                if isempty(obj.paddleSignal) || numel(obj.paddleSignal) ~= nSamples
                    error("WaveMakerProbeNodeManager:ActuatorSignalMissing", ...
                        "Actuator test requires the precomputed preview paddleSignal; signal is missing or stale. Re-run Configure/Test to regenerate preview before TestValid.");
                end

                cmdSignal = obj.paddleSignal;
                V_peak = max(abs(cmdSignal));
                obj.log("INFO", sprintf("Actuator test: commanding preview paddleSignal (peak %.4f V, %d samples, %.1f s).", ...
                    V_peak, nSamples, p.duration));

                preload(obj.daqSession, cmdSignal);
                start(obj.daqSession, "repeatoutput");
                tStop = timer('ExecutionMode', 'singleShot', 'StartDelay', p.duration, ...
                               'TimerFcn', @(~,~) obj.finishActuatorTest());
                obj.log("INFO", sprintf("Actuator test timer started (%.1f s).", p.duration));
                start(tStop);
            end
        end

        function precomputeAllSignals(obj)
            % precomputeAllSignals
            % Pre-computes and caches the paddle voltage signal for every
            % sub-experiment in a multi-experiment spec.
            % Called once in setupCurrentExperiment (index 1) so that
            % obj.allPaddleSignals{i} is ready at CONFIGUREPENDING for the
            % operator to review all signals before confirming with RunValid.
            %
            % Temporarily swaps signal-relevant properties (signalType,
            % signalParams, duration, activeProbes) for each sub-experiment,
            % calls computeAndPreviewSignal, then restores the original values.
            % obj.paddleSignal is restored to experiment 1's signal on exit.

            experiments = obj.experimentSpec.params.experiments;
            nExp = numel(experiments);
            obj.allPaddleSignals = cell(1, nExp);

            % Experiment 1 is already computed — capture it.
            obj.allPaddleSignals{1} = obj.paddleSignal;

            if nExp < 2
                return;
            end

            % Save current (experiment 1) state.
            savedSignalType   = obj.signalType;
            savedSignalParams = obj.signalParams;
            savedDuration     = obj.duration;
            savedActiveProbes = obj.activeProbes;
            savedAmplitude    = obj.amplitude;
            savedFrequency    = obj.frequency;

            for i = 2:nExp
                p = experiments(i);
                obj.duration     = p.duration;
                obj.signalParams = p;
                if isfield(p, 'signalType') && ~isempty(p.signalType)
                    obj.signalType = char(p.signalType);
                else
                    obj.signalType = 'sinusoidal';
                end
                if isfield(p, 'activeProbes'),  obj.activeProbes = p.activeProbes;  end
                if isfield(p, 'amplitude'),     obj.amplitude    = p.amplitude;     end
                if isfield(p, 'frequency'),     obj.frequency    = p.frequency;     end

                try
                    obj.computeAndPreviewSignal();
                    obj.allPaddleSignals{i} = obj.paddleSignal;
                catch ME
                    obj.log("WARN", sprintf("precomputeAllSignals: failed for experiment %d (%s): %s", ...
                        i, p.name, ME.message));
                    obj.allPaddleSignals{i} = [];
                end
            end

            % Restore experiment 1 state.
            obj.signalType   = savedSignalType;
            obj.signalParams = savedSignalParams;
            obj.duration     = savedDuration;
            obj.activeProbes = savedActiveProbes;
            obj.amplitude    = savedAmplitude;
            obj.frequency    = savedFrequency;
            obj.paddleSignal = obj.allPaddleSignals{1};

            obj.log("INFO", sprintf("precomputeAllSignals: cached %d signals for operator preview.", nExp));
        end

        function computeAndPreviewSignal(obj)
            % computeAndPreviewSignal
            % Builds paddle VOLTAGE signal U(t) and expected height X(t) for the
            % configured signal type, stores U in obj.paddleSignal (V), and POSTs
            % a preview packet to the REST server.
            %
            % Supported signal types (obj.signalType / obj.signalParams):
            %
            %   'sinusoidal'       — Fixed-frequency sinusoid.
            %     signalParams: amplitude (m), frequency (Hz)
            %     Mirrors MITestTank_RevKreeftests.m case 2.
            %
            %   'bretschneider'    — Irregular waves from Bretschneider PSD.
            %     signalParams: significantWaveHeight_m (m), modalFrequency_radps (rad/s)
            %     Rayleigh amplitudes, random phases.  No Statistics Toolbox needed.
            %     Mirrors case 1.
            %
            %   'pulse_sinusoidal' — Short sinusoidal burst, then zero-padded.
            %     signalParams: amplitude (m), frequency (Hz), numPulses (int)
            %     numPulses+1 cycles with Hann taper, rest is silence.
            %     Mirrors case 4.
            %
            %   'dual_pulse'       — Two sinusoidal bursts with a pause.
            %     signalParams: amplitude1_m, frequency1_Hz, numPulses1,
            %                   wavePauseDuration_s, amplitude2_m, frequency2_Hz, numPulses2
            %     Mirrors case 5.
            %
            % All types apply a Hann-window taper (first/last dq.Rate samples)
            % without requiring the Signal Processing Toolbox:
            %   hw(k) = 0.5·(1 - cos(2π·k / (2M-1)))  where M = sampleRate

            nSamples = round(obj.duration * obj.sampleRate);
            T = (0 : nSamples-1)' / obj.sampleRate;    % Nx1 time vector (s)

            % Hann taper M (1-second ramp, clamped to half-signal).
            % Passed to applyHannTaper for each synthesised signal.
            M = min(obj.sampleRate, floor(nSamples / 2));

            switch string(obj.signalType)

                % ── Case 2: Sinusoidal ────────────────────────────────────────────
                case 'sinusoidal'
                    A_m = obj.signalParams.amplitude;
                    f   = obj.signalParams.frequency;

                    X = A_m * sin(2*pi*f*T);

                    U_amp = obj.heightToVoltage_V(A_m, f);
                    U = U_amp * sin(2*pi*f*T);

                    U = obj.applyHannTaper(U, M);
                    X = obj.applyHannTaper(X, M);

                    obj.log("INFO", sprintf("Signal [sinusoidal]: %.4f V peak (%.4f m) @ %.2f Hz, %d samples.", ...
                        max(abs(U)), A_m, f, nSamples));

                % ── Case 1: Bretschneider ─────────────────────────────────────────
                case 'bretschneider'
                    Hs_m  = obj.signalParams.significantWaveHeight_m;
                    w_m   = obj.signalParams.modalFrequency_radps;
                    Hs_cm = Hs_m * 100;    % PSD and model are in cm

                    N  = nSamples;
                    dt = 1 / obj.sampleRate;
                    df = 1 / (N * dt);
                    dw = 2*pi * df;

                    fk = (0 : N/2-1) / (N * dt);   % positive freq axis (Hz), 1×(N/2)
                    wk = 2*pi * fk;                  % angular freq (rad/s)

                    % 99% energy cut-off frequency
                    w_lim = w_m / realpow(-4/5 * log(0.99), 1/4);
                    flim  = w_lim / (2*pi);
                    mask  = fk <= flim;
                    fk_f  = fk(mask);   % filtered freq (Hz), 1×nF
                    wk_f  = wk(mask);   % filtered angular freq (rad/s), 1×nF

                    % Rayleigh amplitude sigma^2 = PSD area increment
                    % psd_integrand = @(w) (Hs_cm/4)^2 * exp(-5/4*(w_m/w)^4)  [no toolbox]
                    psd_int = @(w) (Hs_cm/4)^2 .* exp(-5/4 .* (w_m ./ (w + (w==0))).^4) .* (w ~= 0);
                    sigma2  = psd_int(wk_f + dw) - psd_int(wk_f);
                    sigma   = sqrt(max(sigma2, 0));

                    % Rayleigh random amplitudes (manual — no Statistics Toolbox)
                    % Ak ~ Rayleigh(sigma):  Ak = sigma * sqrt(-2*log(U)),  U ~ Uniform(0,1)
                    Ak = sigma .* sqrt(-2 .* log(rand(size(sigma)) + eps));  % 1×nF (cm)

                    phi = 2*pi * rand(1, numel(fk_f));  % random phases, 1×nF

                    % Convert cm amplitudes → voltage using wavemaker model
                    if ~isempty(obj.wavemakerModel)
                        [mag, ~, ~] = bode(obj.wavemakerModel, wk_f);   % 1×1×nF for SISO
                        mag_vec = squeeze(double(mag));   % nF×1 or 1×nF → force column
                        mag_vec = mag_vec(:);              % nF×1  (cm/V)
                        Ak_V = Ak(:) ./ mag_vec;           % nF×1  (V)
                    else
                        Ak_V = Ak(:) / 100;   % cm → m used as V (fallback, no model)
                        obj.log("WARN", "computeAndPreviewSignal [bretschneider]: no model — using Ak_cm/100 as voltage.");
                    end

                    % Synthesise signals as sum of cosines  (nF×N outer product)
                    outer   = fk_f(:) * T(:)';           % nF × N
                    phi_col = phi(:);                     % nF × 1
                    U = sum(Ak_V        .* cos(2*pi*outer + phi_col), 1)';  % N×1 (V)
                    X = sum((Ak(:)/100) .* cos(2*pi*outer + phi_col), 1)';  % N×1 (m)

                    U = obj.applyHannTaper(U, M);
                    X = obj.applyHannTaper(X, M);

                    obj.log("INFO", sprintf("Signal [bretschneider]: Hs=%.4f m (%.1f cm), w_m=%.2f rad/s, flim=%.2f Hz, nF=%d, %d samples.", ...
                        Hs_m, Hs_cm, w_m, flim, numel(fk_f), nSamples));

                % ── Case 4: Pulse sinusoidal ──────────────────────────────────────
                case 'pulse_sinusoidal'
                    A_m     = obj.signalParams.amplitude;
                    f       = obj.signalParams.frequency;
                    nPulses = obj.signalParams.numPulses + 1;  % +1 ramp-up (matches original)

                    pulseSamples = round((nPulses / f) * obj.sampleRate);
                    tPulse = (0 : pulseSamples-1)' / obj.sampleRate;

                    U_amp = obj.heightToVoltage_V(A_m, f);

                    pulseU = U_amp * sin(2*pi*f*tPulse);  % V
                    pulseX = A_m   * sin(2*pi*f*tPulse);  % m

                    % Hann taper on pulse edges only (clamp M to pulse length)
                    Mp = min(M, floor(pulseSamples/2));
                    pulseU = obj.applyHannTaper(pulseU, Mp);
                    pulseX = obj.applyHannTaper(pulseX, Mp);

                    zeroPad = zeros(nSamples - pulseSamples, 1);
                    U = [pulseU; zeroPad];
                    X = [pulseX; zeroPad];

                    obj.log("INFO", sprintf("Signal [pulse_sinusoidal]: %.4f V (%.4f m) @ %.2f Hz, %d pulses, pulse=%d/%d samples.", ...
                        U_amp, A_m, f, nPulses-1, pulseSamples, nSamples));

                % ── Case 5: Dual pulse ────────────────────────────────────────────
                case 'dual_pulse'
                    A1_m     = obj.signalParams.amplitude1_m;
                    f1       = obj.signalParams.frequency1_Hz;
                    nPulses1 = obj.signalParams.numPulses1 + 1;
                    pauseDur = obj.signalParams.wavePauseDuration_s;
                    A2_m     = obj.signalParams.amplitude2_m;
                    f2       = obj.signalParams.frequency2_Hz;
                    nPulses2 = obj.signalParams.numPulses2 + 1;

                    p1Samples = round((nPulses1/f1) * obj.sampleRate);
                    pzSamples = round(pauseDur      * obj.sampleRate);
                    p2Samples = round((nPulses2/f2) * obj.sampleRate);
                    tP1 = (0 : p1Samples-1)' / obj.sampleRate;
                    tP2 = (0 : p2Samples-1)' / obj.sampleRate;

                    U1_amp = obj.heightToVoltage_V(A1_m, f1);
                    U2_amp = obj.heightToVoltage_V(A2_m, f2);

                    pulse1U = U1_amp * sin(2*pi*f1*tP1);
                    pulse1X = A1_m   * sin(2*pi*f1*tP1);
                    pulse2U = U2_amp * sin(2*pi*f2*tP2);
                    pulse2X = A2_m   * sin(2*pi*f2*tP2);

                    % Hann taper each pulse independently
                    Mp1 = min(M, floor(p1Samples/2));
                    pulse1U = obj.applyHannTaper(pulse1U, Mp1);
                    pulse1X = obj.applyHannTaper(pulse1X, Mp1);
                    Mp2 = min(M, floor(p2Samples/2));
                    pulse2U = obj.applyHannTaper(pulse2U, Mp2);
                    pulse2X = obj.applyHannTaper(pulse2X, Mp2);

                    pauseZ  = zeros(pzSamples, 1);
                    usedN   = p1Samples + pzSamples + p2Samples;
                    zeroPad = zeros(max(nSamples - usedN, 0), 1);
                    U = [pulse1U; pauseZ; pulse2U; zeroPad];
                    X = [pulse1X; pauseZ; pulse2X; zeroPad];
                    U = U(1:nSamples);   % trim if pulses exceed total duration
                    X = X(1:nSamples);

                    obj.log("INFO", sprintf("Signal [dual_pulse]: [%.4f V %.2f Hz x%d] + %.1f s pause + [%.4f V %.2f Hz x%d], %d samples.", ...
                        U1_amp, f1, nPulses1-1, pauseDur, U2_amp, f2, nPulses2-1, nSamples));

                otherwise
                    error("WaveMakerProbeNodeManager:unknownSignalType", ...
                        "Unknown signalType '%s'. Use sinusoidal, bretschneider, pulse_sinusoidal, or dual_pulse.", ...
                        obj.signalType);
            end

            obj.paddleSignal = U;

            % POST preview to REST — control node fetches after CONFIGUREPENDING.
            try
                tag = obj.getExperimentTag();
                previewTag = sprintf('preview_%s', matlab.lang.makeValidName(tag));
                previewData = struct( ...
                    'nTime',            num2cell(T), ...
                    'paddleVoltage_V',  num2cell(U), ...
                    'expectedHeight_m', num2cell(X));
                obj.rest.sendData(previewData, 'experimentName', previewTag);
                obj.log("INFO", sprintf("Signal preview posted to REST: %s", previewTag));
            catch ME
                obj.log("WARN", sprintf("Signal preview REST post failed: %s", ME.message));
            end
        end

        function streamOneBlock(obj, blockSize)
            % streamOneBlock — called by timer during TESTINGSENSOR.
            % Reads blockSize scans, averages, applies gains, publishes heights.
            % Stops all timers when state leaves TESTINGSENSOR.
            if obj.state ~= State.TESTINGSENSOR
                tList = timerfindall;
                for i = 1:numel(tList)
                    try; stop(tList(i)); delete(tList(i)); catch; end
                end
                return;
            end
            % Reset/stop paths can halt the DAQ before this timer callback runs.
            % In that race window, skip the block quietly.
            try
                if ~obj.daqSession.Running
                    return;
                end
            catch
                return;
            end
            try
                % Session is already running (started in handleTest before this timer).
                % read() pulls from the live buffer without blocking the MATLAB thread.
                rawRead = read(obj.daqSession, blockSize);
                rawArr  = mean(rawRead.Variables, 1);   % 1x8 mean
                heights = rawArr .* obj.probeGains;
                reading = struct('type','wave_height','units','m', ...
                    'timestamp', string(datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS')));
                for k = obj.activeProbes(:)'
                    reading.(sprintf('H%d', k)) = heights(k);
                end
                obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
            catch ME
                obj.log("WARN", sprintf("streamOneBlock error: %s", ME.message));
            end
        end

        function finishActuatorTest(obj)
            % finishActuatorTest — called by singleShot timer after actuator test duration.
            try; stop(obj.daqSession); write(obj.daqSession, 0); catch; end  % best-effort stop+zero
            obj.log("INFO", "Actuator test complete.");
            obj.transition(State.IDLE);
        end

        function handleRun(obj, cmd) %#ok<INUSD>
            % handleRun
            % Outputs the pre-computed paddle VOLTAGE signal (volts, computed
            % by setupCurrentExperiment using the wavemaker model) and
            % simultaneously acquires all 8 probe channels.
            % Applies gains and mean-centers active probes.

            obj.isCollecting   = true;
            obj.isGenerating   = true;
            obj.abortRequested = false;

            nSamples = round(obj.duration * obj.sampleRate);

            % paddleSignal is pre-computed in setupCurrentExperiment (volts).
            % Recompute only if it is missing or stale.
            if isempty(obj.paddleSignal) || numel(obj.paddleSignal) ~= nSamples
                obj.log("WARN", "handleRun: paddleSignal missing or wrong length — recomputing.");
                obj.computeAndPreviewSignal();
            end

            obj.log("INFO", sprintf("handleRun: type='%s', peak=%.4f V, %d samples (%.1f s @ %d Hz).", ...
                obj.signalType, max(abs(obj.paddleSignal)), nSamples, obj.duration, obj.sampleRate));

            % Background simultaneous output+acquisition with cooperative polling.
            % Small read windows + drawnow keep MATLAB responsive so Abort can be
            % processed during long runs (instead of only after full duration).
            preload(obj.daqSession, obj.paddleSignal);
            start(obj.daqSession, "repeatoutput");

            chunkSec = 0.20;   % 200 ms polling window
            tStart   = tic;
            rawArr   = [];
            didAbort = false;

            while toc(tStart) < obj.duration
                if obj.abortRequested || obj.state == State.ERROR || obj.state == State.IDLE
                    didAbort = true;
                    break;
                end

                tRemain = obj.duration - toc(tStart);
                thisSec = min(chunkSec, max(tRemain, 0));
                if thisSec <= 0
                    break;
                end

                try
                    blk = read(obj.daqSession, seconds(thisSec));
                    if ~isempty(blk) && istimetable(blk)
                        rawArr = [rawArr; blk.Variables]; %#ok<AGROW>
                    end
                catch ME
                    obj.log("WARN", sprintf("handleRun chunk read failed: %s", ME.message));
                    didAbort = true;
                    break;
                end

                drawnow limitrate;
            end

            try; stop(obj.daqSession); catch; end
            try; flush(obj.daqSession); catch; end
            try; write(obj.daqSession, 0); catch; end  % zero paddle immediately after run

            if didAbort
                obj.isGenerating = false;
                obj.isCollecting = false;
                obj.log("WARN", sprintf("handleRun aborted after %.2f s; paddle output halted.", toc(tStart)));
                return;
            end

            obj.isGenerating = false;

            % Apply gains: height(i) = voltage(i) * probeGains(i)
            if isempty(rawArr)
                obj.log("ERROR", "handleRun completed with no acquired data.");
                obj.isCollecting = false;
                obj.transition(State.ERROR);
                return;
            end
            heightData = rawArr .* obj.probeGains;           % broadcast 1x8 gains

            % Mean-center each channel (removes DC offset, matches original code)
            heightData = heightData - mean(heightData, 1);

            % Build output struct array for active probes + time column
            fields = [{'nTime'}, arrayfun(@(x) sprintf('H%d',x), obj.activeProbes(:)', 'UniformOutput', false)];
            nAcq = size(rawArr, 1);
            T = (0:nAcq-1)' / obj.sampleRate;
            values = [{num2cell(T)}];
            for k = obj.activeProbes(:)'
                values{end+1} = num2cell(heightData(:, k)); %#ok<AGROW>
            end
            args = [fields; values];
            obj.experimentData = struct(args{:});

            obj.isCollecting = false;
            obj.log("INFO", sprintf("handleRun: complete. Stored %d samples for probes [%s].", ...
                nSamples, strjoin(arrayfun(@(x) sprintf('H%d',x), obj.activeProbes, 'UniformOutput', false), ',')));
            obj.transition(State.POSTPROC);
        end

        function stopHardware(obj)
            obj.isCollecting = false;
            obj.isGenerating = false;
            obj.log("INFO", "stopHardware: halting DAQ and zeroing paddle output.");
            try
                stop(obj.daqSession);
                    flush(obj.daqSession);        % discard any unread background scans
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
                    flush(obj.daqSession);        % discard any unread background scans
                    write(obj.daqSession, 0);
                delete(obj.daqSession);
            catch ME
                obj.log("WARN", sprintf("shutdownHardware DAQ release error: %s", ME.message));
            end
        end

    end

    methods (Access = protected)

        function ready = awaitReady(obj, sc)
            % awaitReady — wave-probe readiness check.
            %
            % Reads the DAQ in rolling windows and computes the half-amplitude
            % (max - min) / 2 for each active probe within each window.
            % Loops indefinitely until ALL active probes stay below sc.threshold
            % for the full sc.holdDuration_s, then returns true.
            %
            % Window sizing: at least 2 complete periods of the last-run
            % experiment (so a still-active wave never aliases into calm),
            % clamped to a minimum of 3 s and a maximum of 10 s.
            %
            % NOTE: this method runs synchronously on the MQTT callback thread.
            % Incoming MQTT messages are queued by the broker and processed
            % after awaitReady returns.  This is consistent with the rest of
            % the framework (handleRun is also synchronous).
            %
            % On the mock, awaitReady is overridden with a synthetic decaying
            % signal so the algorithm is exercised in tests without hardware.

            ready      = true;
            threshold  = sc.threshold;
            holdNeeded = sc.holdDuration_s;

            % Ensure the DAQ session is stopped and paddle is zeroed before
            % reading probe channels.  handleRun already calls stop+write(0),
            % but this guard covers any edge-case where awaitReady is entered
            % while the session is still running (e.g., very fast experiments).
            try
                if obj.daqSession.Running
                    stop(obj.daqSession);
                end
                write(obj.daqSession, 0);   % safe-zero paddle output
            catch
                % Session may not support write when not started — ignore
            end

            % Window: cover >=2 full periods of the last experiment.
            lastFreq = 0;
            if ~isempty(obj.signalParams) && isfield(obj.signalParams, 'frequency')
                lastFreq = obj.signalParams.frequency;
            end
            if lastFreq > 0
                winSec = max(2 / lastFreq, 3);
            else
                winSec = 3;
            end
            winSec    = min(winSec, 10);
            winSamples = round(winSec * obj.sampleRate);

            probes     = obj.activeProbes(:)';
            holdSec    = 0;
            tStart     = tic;

            obj.log("INFO", sprintf( ...
                "[awaitReady] Waiting for settle: threshold=%.4f %s, hold=%.1f s, " + ...
                "window=%.1f s, probes=[%s].", ...
                threshold, sc.thresholdUnits, holdNeeded, winSec, ...
                strjoin(arrayfun(@(x) num2str(x), probes, 'UniformOutput', false), ',')));

            % Start background session once: output zeros (paddle safe), acquire probes.
            % read() inside the loop pulls from the live buffer without per-call overhead.
            zeroBufAR = zeros(winSamples, 1);
            preload(obj.daqSession, zeroBufAR);
            start(obj.daqSession, "repeatoutput");

            while true
                % Read one window of DAQ data from all 8 channels.
                try
                    rawBlock = read(obj.daqSession, winSamples);   % winSamples × 8
                    rawArr   = rawBlock.Variables;
                catch ME
                    obj.log("WARN", sprintf("[awaitReady] DAQ read error: %s — stopping settle wait.", ME.message));
                    break;
                end

                % Apply gains to get physical units, then check each active probe.
                heightBlock = rawArr .* obj.probeGains;   % winSamples × 8

                allBelow = true;
                for k = probes
                    col       = heightBlock(:, k);
                    halfAmp   = (max(col) - min(col)) / 2;
                    if halfAmp >= threshold
                        allBelow = false;
                        break;
                    end
                end

                if allBelow
                    holdSec = holdSec + winSec;
                    obj.log("INFO", sprintf("[awaitReady] Below threshold — hold %.1f / %.1f s.", holdSec, holdNeeded));
                    if holdSec >= holdNeeded
                        obj.log("INFO", sprintf("[awaitReady] Ready confirmed after %.1f s.", toc(tStart)));
                        try; stop(obj.daqSession); write(obj.daqSession, 0); catch; end
                        return;
                    end
                else
                    if holdSec > 0
                        obj.log("INFO", sprintf("[awaitReady] Activity detected — reset hold counter (was %.1f s).", holdSec));
                    end
                    holdSec = 0;
                end
            end

            try; stop(obj.daqSession); write(obj.daqSession, 0); catch; end
        end

    end

    methods (Access = protected)

        function sig = applyHannTaper(~, sig, M)
            % applyHannTaper
            % Applies a symmetric Hann-window fade-in/fade-out to the first and
            % last M samples of sig. No Signal Processing Toolbox required.
            % M is typically obj.sampleRate (1 second) clamped to floor(N/2).
            if M < 1 || numel(sig) < 2*M; return; end
            k  = (0 : 2*M-1)';
            hw = 0.5 * (1 - cos(2*pi*k / (2*M-1)));
            sig(1:M)         = sig(1:M)         .* hw(1:M);
            sig(end-M+1:end) = sig(end-M+1:end) .* hw(M+1:end);
        end

        function U_amp = heightToVoltage_V(obj, A_m_metres, freq_Hz)
            % heightToVoltage_V
            % Converts desired wave height (metres) to required DAQ output
            % voltage (V) using the wavemaker transfer function model.
            % Returns A_m_metres directly if model unavailable (fallback).
            % Returns 0 if A_m_metres==0 or freq_Hz==0 (zero signal).
            if A_m_metres == 0 || freq_Hz == 0
                U_amp = 0;
                return;
            end
            if isempty(obj.wavemakerModel)
                U_amp = A_m_metres;
                obj.log("WARN", "heightToVoltage_V: no wavemaker model — using amplitude as voltage (uncalibrated).");
                return;
            end
            [mag, ~, ~] = bode(obj.wavemakerModel, 2*pi*freq_Hz);
            U_amp = (A_m_metres * 100) / squeeze(double(mag));   % cm / (cm/V) = V
        end

    end
end
