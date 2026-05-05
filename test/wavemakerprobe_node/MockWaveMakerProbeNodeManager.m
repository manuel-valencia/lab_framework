classdef MockWaveMakerProbeNodeManager < WaveMakerProbeNodeManager
    % MockWaveMakerProbeNodeManager
    %
    % Test double for WaveMakerProbeNodeManager. Overrides all NI-DAQ I/O
    % with deterministic synthetic data so that FSM routing, probe gain
    % calibration (polyfit), and the full handleRun pipeline (gain apply,
    % mean-centering, struct build) can be verified without hardware.
    %
    % Synthetic signal model
    % ----------------------
    % For each active probe channel i:
    %   voltage(t) = (paddleAmplitude * sin(2π*paddleFrequency*t)) / probeGains(i)
    %                + DC_offset + noise
    %   → after gain apply + mean-center, output should approximate the
    %     original paddle waveform.
    %
    % For inactive channels: noise only.
    %
    % Calibration:
    %   liveProbeInput (1×8) is the externally-set "water height" in metres.
    %   Mock converts it to a voltage via: V = height / defaultGain (1.0).
    %   The real polyfit then recovers gain ≈ 1.0 (or whatever the test sets).
    %
    % Usage
    % -----
    %   mock = MockWaveMakerProbeNodeManager(cfg, comm, rest);
    %   mock.liveProbeInput = [0.05, 0.05, 0.05, 0, 0, 0, 0, 0]; % m per probe
    %   mock.noiseSigma     = 0.001;

    properties
        % Externally-set "water height" per probe (1×8, metres)
        % Used during calibration point collection.
        liveProbeInput = zeros(1, 8)

        % Noise standard deviation added to all channels (volts)
        noiseSigma = 0.001
    end

    methods

        function obj = MockWaveMakerProbeNodeManager(cfg, comm, rest)
            obj@WaveMakerProbeNodeManager(cfg, comm, rest);
            testDir = fileparts(mfilename('fullpath'));
            obj.logDir = fullfile(testDir, 'waveMakerProbeNodeLogs');
            obj.log("INFO", "MockWaveMakerProbeNodeManager active — DAQ I/O is synthetic.");
        end

        % ------------------------------------------------------------------
        % Override computeAndPreviewSignal: run full signal synthesis but
        % skip the REST POST.  In production, sendData() is called inside
        % this method and blocks the MQTT callback for up to 15 s (the
        % webwrite timeout), freezing the entire MATLAB event loop. The
        % mock doesn't need the preview posted anywhere — the test script
        % reads obj.paddleSignal directly — so we call the parent to build
        % the signal, then simply omit the upload.
        % ------------------------------------------------------------------
        function computeAndPreviewSignal(obj)
            origTimeout = obj.rest.timeout;
            obj.rest.timeout = 0.5;   % fail fast — 0.5 s max, not 15 s
            try
                computeAndPreviewSignal@WaveMakerProbeNodeManager(obj);
            catch
                % Signal was still built; REST failure is expected in tests.
            end
            obj.rest.timeout = origTimeout;
        end

        % ------------------------------------------------------------------
        % Override initializeHardware: skip daq("ni")
        % ------------------------------------------------------------------
        function initializeHardware(obj, cfg)
            obj.experimentData = [];
            obj.isCollecting   = false;
            obj.isGenerating   = false;
            obj.sampleRate     = cfg.hardware.sampleRate;
            obj.paddleChannel  = cfg.hardware.paddleOutputChannel;

            % No real DAQ session
            obj.daqSession = [];
            obj.log("INFO", sprintf("Mock: hardware initialized at %d Hz (no DAQ).", obj.sampleRate));
        end

        % ------------------------------------------------------------------
        % generateSyntheticProbeResponse
        % Returns nSamples×8 double. Active probes respond to paddleSignal;
        % inactive probes are noise only.
        %
        % Aesthetic propagation delay: each probe index k is shifted right
        % by k*0.5 seconds (probe 1 → 0.5 s, probe 2 → 1.0 s, etc.) to
        % simulate the wave travelling down the tank past successive probes.
        % The leading zeros act as "wave hasn't arrived yet" — mock only.
        % ------------------------------------------------------------------
        function V = generateSyntheticProbeResponse(obj, paddleSignal, nSamples)
            V = obj.noiseSigma * randn(nSamples, 8);
            for k = obj.activeProbes(:)'
                % Response: reverse-apply the stored gain so the forward
                % gain multiply in handleRun recovers the paddle signal.
                if obj.probeGains(k) ~= 0
                    % Propagation delay: probe k arrives k*0.5 s later.
                    delaySamples = min(round(k * 0.5 * obj.sampleRate), nSamples);
                    signalBase   = paddleSignal(1 : nSamples - delaySamples) / obj.probeGains(k);
                    delayed      = [zeros(delaySamples, 1); signalBase];
                    V(:, k) = delayed + obj.noiseSigma * randn(nSamples, 1);
                end
            end
        end

        % ------------------------------------------------------------------
        % Override handleCalibrate — inject synthetic voltage from liveProbeInput
        % ------------------------------------------------------------------
        function handleCalibrate(obj, cmd)
            if isfield(cmd.params, 'finished') && cmd.params.finished
                % Delegate the polyfit + save to real code
                handleCalibrate@WaveMakerProbeNodeManager(obj, cmd);
                return;
            end

            try
                knownHeight = cmd.params.knownHeight_m;

                % Lock in selectedProbes on first call (same logic as real code)
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
                end

                % Synthetic voltage: height / gain (so polyfit recovers gain ≈ 1 unless set differently)
                mockVoltages = obj.liveProbeInput ./ max(obj.probeGains, 1e-6) ...
                               + obj.noiseSigma * randn(1, 8);
                meanVoltages = mockVoltages(obj.calibSelectedProbes);

                obj.calibHeights_m = [obj.calibHeights_m; knownHeight];
                obj.calibVoltages  = [obj.calibVoltages;  meanVoltages];

                nPts = size(obj.calibHeights_m, 1);
                obj.log("INFO", sprintf("Mock calib point %d: height=%.4f m, V=[%s].", ...
                    nPts, knownHeight, ...
                    strjoin(arrayfun(@(v) sprintf('%.4f',v), meanVoltages,'UniformOutput',false), ', ')));

            catch ME
                obj.log("ERROR", sprintf("Mock handleCalibrate exception: %s", ME.message));
                rethrow(ME);
            end
        end

        % ------------------------------------------------------------------
        % Override handleTest — inject synthetic data instead of DAQ
        % ------------------------------------------------------------------
        function handleTest(obj, cmd)
            % When the FSM arrives here via the TestValid path, obj.cmd is the
            % TestValid struct (no params field). Recover the original Test
            % command params from obj.experimentSpec, which was stored when
            % the initial Test(actuator,...) command was received.
            if isfield(cmd, 'params') && isfield(cmd.params, 'target')
                target = string(cmd.params.target);
                params = cmd.params;
            else
                target = "actuator";   % TestValid can only come from actuator path
                params = obj.experimentSpec.params;
            end
            obj.log("INFO", sprintf("Mock handleTest: target=%s.", target));

            if target == "sensor"
                if isempty(obj.activeProbes)
                    obj.log("WARN", "Mock handleTest (sensor): no activeProbes set. Send Configure first.");
                    obj.transition(State.IDLE);
                    return;
                end

                obj.log("INFO", "Mock streaming synthetic probe readings. Send Reset to stop.");
                nStream = round(obj.sampleRate * 0.5);   % 50 samples at 100 Hz = 0.5 s burst
                obj.log("INFO", sprintf("Mock handleTest(sensor): publishing %d synthetic readings then IDLE.", nStream));
                heights = obj.liveProbeInput .* obj.probeGains;
                for k = 1:nStream
                    reading = struct('type','wave_height','units','m', ...
                        'timestamp',string(datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS')));
                    for ki = obj.activeProbes
                        reading.(sprintf('H%d',ki)) = heights(ki);
                    end
                    obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
                end
                obj.transition(State.IDLE);

            else  % actuator
                nSamples = round(params.duration * obj.sampleRate);
                T        = (0:nSamples-1)' / obj.sampleRate;

                % Use heightToVoltage_V — consistent with real handleTest.
                % Mock has no model, so returns amplitude as voltage (uncalibrated).
                U_amp        = obj.heightToVoltage_V(params.amplitude, params.frequency);
                paddleSignal = U_amp * sin(2*pi*params.frequency*T);

                obj.log("INFO", sprintf("Mock actuator test: %.4f V (%.3f m) @ %.2f Hz for %.1f s.", ...
                    U_amp, params.amplitude, params.frequency, params.duration));

                % No real DAQ — log and return immediately
                obj.log("INFO", sprintf("Mock paddle signal: peak = %.4f V, samples = %d.", max(abs(paddleSignal)), nSamples));
                obj.log("INFO", "Mock actuator test complete.");
                obj.transition(State.IDLE);
            end
        end

        % ------------------------------------------------------------------
        % Override handleRun — synthetic probe response, real pipeline
        % ------------------------------------------------------------------
        function handleRun(obj, cmd) %#ok<INUSD>
            obj.isCollecting = true;
            obj.isGenerating = true;

            nSamples = round(obj.duration * obj.sampleRate);
            T        = (0 : nSamples-1)' / obj.sampleRate;

            % Use the pre-computed paddle signal built by setupCurrentExperiment.
            % This exercises computeAndPreviewSignal for all signal types and
            % avoids re-implementing signal generation in the mock.
            if isempty(obj.paddleSignal) || numel(obj.paddleSignal) ~= nSamples
                obj.log("WARN", "Mock handleRun: paddleSignal missing or stale — recomputing.");
                obj.computeAndPreviewSignal();
            end

            obj.log("INFO", sprintf("Mock handleRun: type='%s', peak=%.4f, %d samples.", ...
                obj.signalType, max(abs(obj.paddleSignal)), nSamples));

            % Generate synthetic probe voltages driven by the paddle signal.
            % generateSyntheticProbeResponse reverse-applies probeGains so that
            % the forward gain multiply in the pipeline below recovers the signal.
            rawArr = obj.generateSyntheticProbeResponse(obj.paddleSignal, nSamples);

            obj.isGenerating = false;

            % ── Below is identical to the real handleRun pipeline ──

            % Apply gains
            heightData = rawArr .* obj.probeGains;

            % Mean-center (DC offset removal)
            heightData = heightData - mean(heightData, 1);

            % Build struct array for active probes + time
            fields = [{'nTime'}, arrayfun(@(x) sprintf('H%d',x), obj.activeProbes(:)', 'UniformOutput', false)];
            values = [{num2cell(T)}];
            for k = obj.activeProbes(:)'
                values{end+1} = num2cell(heightData(:, k)); %#ok<AGROW>
            end
            args = [fields; values];
            obj.experimentData = struct(args{:});

            obj.isCollecting = false;
            obj.log("INFO", sprintf("Mock handleRun: complete. %d samples, probes [%s].", ...
                nSamples, strjoin(arrayfun(@(x) sprintf('H%d',x), obj.activeProbes,'UniformOutput',false), ',')));
            obj.transition(State.POSTPROC);
        end

        % ------------------------------------------------------------------
        % Override stopHardware / shutdownHardware — no DAQ to touch
        % ------------------------------------------------------------------
        function stopHardware(obj)
            obj.isCollecting = false;
            obj.isGenerating = false;
            obj.log("INFO", "Mock stopHardware: no-op.");
        end

        function shutdownHardware(obj)
            obj.isCollecting   = false;
            obj.isGenerating   = false;
            obj.experimentData = [];
            obj.log("INFO", "Mock shutdownHardware: no-op.");
        end

    end

    methods (Access = protected)

        % ------------------------------------------------------------------
        % Override awaitReady — synthetic decaying-wave settle check.
        %
        % Generates a decaying sinusoidal signal at the last experiment's
        % frequency and amplitude, then runs the identical sliding-window
        % half-amplitude algorithm used by the real node.  This validates
        % the detection logic without requiring physical hardware or real
        % time delays.
        %
        % The mock signal decays with time constant tau = 2 s so it settles
        % in ~6 s regardless of sc.holdDuration_s (test is fast).
        % ------------------------------------------------------------------
        function ready = awaitReady(obj, sc)
            threshold  = sc.threshold;
            holdNeeded = sc.holdDuration_s;

            % Last-experiment frequency and amplitude for the synthetic signal.
            lastFreq = 0;
            lastAmp  = 0;
            if ~isempty(obj.signalParams) && isfield(obj.signalParams, 'frequency')
                lastFreq = obj.signalParams.frequency;
            end
            if ~isempty(obj.signalParams) && isfield(obj.signalParams, 'amplitude')
                lastAmp  = obj.signalParams.amplitude;
            end
            if lastFreq <= 0;  lastFreq = 1;   end
            if lastAmp  <= 0;  lastAmp  = 0.05; end

            % Window: same rule as real node (>=2 periods, 3–10 s)
            if lastFreq > 0
                winSec = max(2 / lastFreq, 3);
            else
                winSec = 3;
            end
            winSec     = min(winSec, 10);
            winSamples = round(winSec * obj.sampleRate);

            tau        = 2.0;   % decay time constant (s) — signal settles in ~3τ
            probes     = obj.activeProbes(:)';
            holdSec    = 0;
            tSim       = 0;     % simulated elapsed time (s)

            obj.log("INFO", sprintf( ...
                "[Mock awaitReady] Simulating settle: threshold=%.4f %s, hold=%.1f s, " + ...
                "freq=%.2f Hz, amp=%.3f, window=%.1f s.", ...
                threshold, sc.thresholdUnits, holdNeeded, lastFreq, lastAmp, winSec));

            while tSim < sc.timeout_s
                % Build one window of synthetic decaying signal.
                T     = (0 : winSamples-1)' / obj.sampleRate;
                decay = exp(-(tSim + T) / tau);
                sig   = lastAmp * sin(2*pi*lastFreq*T) .* decay;  % m (true height)

                allBelow = true;
                for k = probes
                    % Reverse-apply gain so the forward multiply recovers sig.
                    g   = obj.probeGains(k);
                    if g == 0; g = 1; end
                    col = sig / g;            % voltage analogue
                    col = col * g;            % apply gain (cancels, keeps units as 'm')
                    halfAmp = (max(col) - min(col)) / 2;
                    if halfAmp >= threshold
                        allBelow = false;
                        break;
                    end
                end

                tSim = tSim + winSec;

                if allBelow
                    holdSec = holdSec + winSec;
                    obj.log("INFO", sprintf("[Mock awaitReady] Below threshold — hold %.1f / %.1f s.", holdSec, holdNeeded));
                    if holdSec >= holdNeeded
                        ready = true;
                        obj.log("INFO", sprintf("[Mock awaitReady] Ready confirmed at simulated t=%.1f s.", tSim));
                        return;
                    end
                else
                    if holdSec > 0
                        obj.log("INFO", sprintf("[Mock awaitReady] Activity detected — reset hold (was %.1f s).", holdSec));
                    end
                    holdSec = 0;
                end
            end

            obj.log("WARN", sprintf("[Mock awaitReady] Timed out at simulated t=%.0f s.", tSim));
            ready = false;
        end

    end
end
