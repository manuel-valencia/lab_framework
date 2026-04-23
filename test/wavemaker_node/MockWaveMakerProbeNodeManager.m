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
            obj.log("INFO", "MockWaveMakerProbeNodeManager active — DAQ I/O is synthetic.");
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
        % ------------------------------------------------------------------
        function V = generateSyntheticProbeResponse(obj, paddleSignal, nSamples)
            V = obj.noiseSigma * randn(nSamples, 8);
            for k = obj.activeProbes
                % Response: reverse-apply the stored gain so the forward
                % gain multiply in handleRun recovers the paddle signal.
                if obj.probeGains(k) ~= 0
                    V(:, k) = paddleSignal / obj.probeGains(k) + obj.noiseSigma * randn(nSamples, 1);
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
                    strjoin(arrayfun(@(v) sprintf("%.4f",v), meanVoltages,'UniformOutput',false), ', ')));

            catch ME
                obj.log("ERROR", sprintf("Mock handleCalibrate exception: %s", ME.message));
                rethrow(ME);
            end
        end

        % ------------------------------------------------------------------
        % Override handleTest — inject synthetic data instead of DAQ
        % ------------------------------------------------------------------
        function handleTest(obj, cmd)
            target = string(cmd.params.target);
            obj.log("INFO", sprintf("Mock handleTest: target=%s.", target));

            if target == "sensor"
                if isempty(obj.activeProbes)
                    obj.log("WARN", "Mock handleTest (sensor): no activeProbes set. Send Configure first.");
                    obj.transition(State.IDLE);
                    return;
                end

                obj.log("INFO", "Mock streaming synthetic probe readings. Send Reset to stop.");
                while obj.state == State.TESTINGSENSOR
                    heights = obj.liveProbeInput .* obj.probeGains;
                    reading = struct('type','wave_height','units','m', ...
                        'timestamp',string(datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS')));
                    for k = obj.activeProbes
                        reading.(sprintf('H%d',k)) = heights(k);
                    end
                    obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
                    pause(0.05);
                end

            else  % actuator
                params = cmd.params;
                nSamples     = round(params.duration * obj.sampleRate);
                T            = (0:nSamples-1)' / obj.sampleRate;
                paddleSignal = params.amplitude * sin(2*pi*params.frequency*T);

                obj.log("INFO", sprintf("Mock actuator test: %.3f m @ %.2f Hz for %.1f s.", ...
                    params.amplitude, params.frequency, params.duration));

                % No real DAQ — just simulate briefly then return
                maxV = max(abs(paddleSignal));
                obj.log("INFO", sprintf("Mock paddle signal: peak = %.4f m, samples = %d.", maxV, nSamples));
                pause(min(params.duration * 0.1, 0.5));   % brief pause to simulate test

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

            if isfield(obj.experimentSpec.params, 'experiments')
                p = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
            else
                p = obj.experimentSpec.params;
            end

            nSamples     = round(obj.duration * obj.sampleRate);
            T            = (0 : nSamples-1)' / obj.sampleRate;
            paddleSignal = p.amplitude * sin(2*pi*p.frequency*T);

            obj.log("INFO", sprintf("Mock handleRun: %.3f m @ %.2f Hz, %d samples.", ...
                p.amplitude, p.frequency, nSamples));

            % Generate synthetic probe voltages
            rawArr = obj.generateSyntheticProbeResponse(paddleSignal, nSamples);

            obj.isGenerating = false;

            % ── Below is identical to the real handleRun pipeline ──

            % Apply gains
            heightData = rawArr .* obj.probeGains;

            % Mean-center (DC offset removal)
            heightData = heightData - mean(heightData, 1);

            % Build struct array for active probes + time
            fields = [{'nTime'}, arrayfun(@(x) sprintf('H%d',x), obj.activeProbes, 'UniformOutput', false)];
            values = [{num2cell(T)}];
            for k = obj.activeProbes
                values{end+1} = num2cell(heightData(:, k)); %#ok<AGROW>
            end
            args = [fields; values];
            obj.experimentData = struct(args{:});

            obj.isCollecting = false;
            obj.log("INFO", sprintf("Mock handleRun: complete. %d samples, probes [%s].", ...
                nSamples, strjoin(arrayfun(@(x) sprintf("H%d",x), obj.activeProbes,'UniformOutput',false), ',')));
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
end
