classdef MockCarriageNodeManager < CarriageNodeManager
    % MockCarriageNodeManager
    %
    % Test double for CarriageNodeManager. Overrides all NI-DAQ I/O with
    % deterministic synthetic data so that FSM routing, calibration math
    % (bias, spline), and the full enterPostProc pipeline (RunTimeMatrix
    % decoupling, Cheby2 filter, motion spline) can be verified without
    % physical hardware.
    %
    % Synthetic signal model
    % ----------------------
    % SG channels (cols 1-6):
    %   syntheticFT  — desired Fx,Fy,Fz,Mx,My,Mz in lb/lb-in (set by test)
    %   Inverse RunTimeMatrix maps FT → SG voltages so that the forward
    %   RunTimeMatrix in enterPostProc recovers the original values.
    %   biasVoltages are added so bias-subtraction cancels them exactly.
    %   Gaussian noise is added at amplitude noiseSigma.
    %
    % Motion channels (cols 8-10):
    %   syntheticMotion — [heave_mm, pitch_mm, roll_mm] (set by test)
    %   A fake spline calibration is inserted so interp1 maps the
    %   synthetic voltage back to the known mm value.
    %
    % Sync channel (col 7): sine at experiment frequency (or 1 Hz default).
    %
    % Usage
    % -----
    %   mock = MockCarriageNodeManager(cfg, comm, rest);
    %   mock.syntheticFT     = [1, 0.5, 10, 0.1, 0.2, 0.05];  % lb / lb-in
    %   mock.syntheticMotion = [5, 1, 0.5];                     % mm
    %   mock.noiseSigma      = 0.0005;                          % volts

    properties
        % Desired force/torque output in lb / lb-in  (1x6)
        % The inverse RunTimeMatrix converts these to SG voltages that the
        % forward pipeline will reconstruct back to these values.
        syntheticFT     = [1.0, 0.5, 10.0, 0.1, 0.2, 0.05]

        % Desired motion sensor readings in mm (1x3: [heave, pitch, roll])
        syntheticMotion = [5.0, 1.0, 0.5]

        % Voltage noise standard deviation added to all synthetic channels
        noiseSigma = 0.0005
    end

    methods

        function obj = MockCarriageNodeManager(cfg, comm, rest)
            obj@CarriageNodeManager(cfg, comm, rest);
            obj.log("INFO", "MockCarriageNodeManager active — DAQ I/O is synthetic.");
        end

        % ------------------------------------------------------------------
        % Override initializeHardware: skip daq("ni"), wire mock calibration
        % ------------------------------------------------------------------
        function initializeHardware(obj, cfg)
            obj.experimentData = [];
            obj.rawData        = [];
            obj.isCollecting   = false;
            obj.sampleRate     = cfg.hardware.sampleRate;

            % Load RunTimeMatrix if the file exists; use a scaled identity
            % placeholder otherwise (tests pipeline shape, not lab values).
            rtmFile = cfg.hardware.runTimeMatrixFile;
            if isfile(rtmFile)
                loaded = load(rtmFile, 'RunTimeMatrix');
                obj.runTimeMatrix = loaded.RunTimeMatrix;
                obj.log("INFO", sprintf("Mock: RunTimeMatrix loaded from %s", rtmFile));
            else
                obj.runTimeMatrix = eye(6) * 0.1;
                obj.log("WARN", "Mock: RunTimeMatrix file not found — using scaled identity. Pipeline shape test only.");
            end

            % No real DAQ session needed
            obj.daqSession = [];
            obj.log("INFO", sprintf("Mock: hardware initialized at %d Hz (no DAQ).", obj.sampleRate));
        end

        % ------------------------------------------------------------------
        % generateSyntheticTimetable — core mock helper
        % ------------------------------------------------------------------
        function tt = generateSyntheticTimetable(obj, nSamples, freqHz)
            % Returns an nSamples×10 timetable matching the real channel layout.
            % freqHz: optional frequency for sync/motion signals (default 1).
            if nargin < 3 || isempty(freqHz); freqHz = 1.0; end

            dt = 1 / obj.sampleRate;
            t  = (0 : nSamples-1)' * dt;   % Nx1

            % SG voltages: invert RunTimeMatrix to get voltages that produce syntheticFT
            % runTimeMatrix * SG' = FT  →  SG = (runTimeMatrix \ FT')'
            if ~isempty(obj.biasVoltages)
                bv = obj.biasVoltages;
            else
                bv = zeros(1, 6);
            end

            try
                SG_clean = (obj.runTimeMatrix \ obj.syntheticFT')'; % 1x6 DC component
            catch
                SG_clean = zeros(1, 6);
            end

            % Replicate across rows + add bias + noise
            SG = repmat(SG_clean + bv, nSamples, 1) + obj.noiseSigma * randn(nSamples, 6);

            % Sync: sine at freqHz
            sync = 0.5 * sin(2*pi*freqHz*t);

            % Motion channels: constant voltage derived from a simple linear mapping.
            % The mock inserts a two-point spline so interp1 gives syntheticMotion back.
            % Voltage = syntheticMotion_mm * 0.01  (arbitrary but invertible scale)
            motionV = repmat(obj.syntheticMotion * 0.01, nSamples, 1) ...
                      + obj.noiseSigma * randn(nSamples, 3);

            data = [SG, sync, motionV];   % nSamples x 10

            % Build timetable with the same Time variable that read() produces
            Time = seconds(t);
            tt = array2timetable(data, 'RowTimes', Time, ...
                'VariableNames', {'SG0','SG1','SG2','SG3','SG4','SG5', ...
                                  'Sync','Heave','Pitch','Roll'});

            % Install a simple linear spline calibration so enterPostProc
            % can map the synthetic voltages back to the known mm values.
            % Two anchor points: 0 V → 0 mm,  voltageAtSynth → syntheticMotion_mm
            channels = {'heave','pitch','roll'};
            for k = 1:3
                vSynth = obj.syntheticMotion(k) * 0.01;
                obj.motionCalib.(channels{k}) = struct( ...
                    'V', [0; vSynth], ...
                    'D', [0; obj.syntheticMotion(k)] );
            end
        end

        % ------------------------------------------------------------------
        % Override handleCalibrate — inject synthetic data instead of DAQ
        % ------------------------------------------------------------------
        function handleCalibrate(obj, cmd)
            target = string(cmd.params.target);

            if target == "force_bias"
                % Generate 1 s of data (sampleRate samples)
                tt = obj.generateSyntheticTimetable(obj.sampleRate);
                biasArr = mean(table2array(tt), 1);   % 1x10
                obj.biasVoltages = biasArr(1:6);
                biasVoltages = obj.biasVoltages; %#ok<NASGU>
                save("calibrationGains.mat", "biasVoltages");
                obj.log("INFO", sprintf("Mock force_bias saved: [%s]", ...
                    strjoin(arrayfun(@(v) sprintf("%.5f",v), obj.biasVoltages, 'UniformOutput', false), ', ')));
                obj.transition(State.IDLE);

            elseif target == "motion_sensors"
                if isfield(cmd.params, 'finished') && cmd.params.finished
                    % Delegate spline fitting to the real code path
                    handleCalibrate@CarriageNodeManager(obj, cmd);
                else
                    % Inject synthetic voltage for the named channel
                    channel    = string(cmd.params.channel);
                    knownValue = cmd.params.knownValue_mm;

                    colMap = struct('heave', 8, 'pitch', 9, 'roll', 10);
                    if ~isfield(colMap, channel)
                        obj.log("ERROR", sprintf("Unknown motion channel: '%s'.", channel));
                        return;
                    end
                    colIdx = colMap.(channel);

                    % Synthetic mean voltage for this channel
                    motionColOffset = colIdx - 7;   % 1=heave, 2=pitch, 3=roll
                    V = obj.syntheticMotion(motionColOffset) * 0.01;

                    obj.motionCalibBuffer.(channel) = [obj.motionCalibBuffer.(channel); V, knownValue];
                    nPts = size(obj.motionCalibBuffer.(channel), 1);
                    obj.log("INFO", sprintf("Mock motion calib: %s  V=%.4f  knownValue=%.2f  (%d pts).", ...
                        channel, V, knownValue, nPts));
                end

            else
                handleCalibrate@CarriageNodeManager(obj, cmd);
            end
        end

        % ------------------------------------------------------------------
        % Override handleTest — inject synthetic data for the read(1) call
        % ------------------------------------------------------------------
        function handleTest(obj, cmd) %#ok<INUSD>
            obj.log("INFO", "Mock handleTest: streaming synthetic force readings. Send Reset to stop.");

            if isempty(obj.biasVoltages)
                bias = zeros(1, 6);
            else
                bias = obj.biasVoltages;
            end

            while obj.state == State.TESTINGSENSOR
                tt     = obj.generateSyntheticTimetable(1);
                rawArr = table2array(tt);              % 1x10
                SG_corrected = rawArr(1:6) - bias;
                FT = obj.runTimeMatrix * SG_corrected';
                reading = struct( ...
                    'type',      'force', ...
                    'Fx',        FT(1), ...
                    'Fy',        FT(2), ...
                    'Fz',        FT(3), ...
                    'Mx',        FT(4), ...
                    'My',        FT(5), ...
                    'Mz',        FT(6), ...
                    'units',     'lb_lbin', ...
                    'timestamp', string(datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS')));
                obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
                pause(1 / obj.sampleRate);   % pace to nominal sample rate
            end
        end

        % ------------------------------------------------------------------
        % Override handleRun — synthetic rawData, then real enterPostProc
        % ------------------------------------------------------------------
        function handleRun(obj, cmd) %#ok<INUSD>
            obj.isCollecting = true;
            nSamples = round(obj.duration * obj.sampleRate);

            if isfield(obj.experimentSpec.params, 'experiments')
                p = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
            else
                p = obj.experimentSpec.params;
            end
            freqHz = p.frequency;

            obj.log("INFO", sprintf("Mock handleRun: generating %d samples at %d Hz.", nSamples, obj.sampleRate));
            obj.rawData = obj.generateSyntheticTimetable(nSamples, freqHz);

            obj.isCollecting = false;
            obj.log("INFO", "Mock handleRun: synthetic acquisition complete — entering post-processing.");
            obj.transition(State.POSTPROC);   % real enterPostProc runs on obj.rawData
        end

        % ------------------------------------------------------------------
        % Override stopHardware / shutdownHardware — no DAQ to touch
        % ------------------------------------------------------------------
        function stopHardware(obj)
            obj.isCollecting = false;
            obj.log("INFO", "Mock stopHardware: no-op.");
        end

        function shutdownHardware(obj)
            obj.isCollecting   = false;
            obj.experimentData = [];
            obj.rawData        = [];
            obj.log("INFO", "Mock shutdownHardware: no-op.");
        end

    end
end
