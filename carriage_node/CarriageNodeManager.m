classdef CarriageNodeManager < ExperimentManager
    % CarriageNodeManager
    %
    % Force sensor node for the tow tank carriage computer.
    % Reads a 6-axis ATI Gamma IP68 load cell via NI-DAQ USB-6218, plus
    % a sync pulse channel and three GoBilda laser distance sensors
    % (heave, pitch, roll). hasSensor = true, hasActuator = false.
    %
    % Channel layout — order added to DAQ session = column index in read():
    %   Col 1-6  : ai0-ai5  — ATI strain gauges SG0-SG5
    %   Col 7    : ai7      — Sync pulse
    %   Col 8    : ai17     — GoBilda heave distance sensor
    %   Col 9    : ai18     — GoBilda pitch distance sensor
    %   Col 10   : ai19     — GoBilda roll distance sensor
    %
    % Calibration (force bias):
    %   {"cmd":"Calibrate","params":{"target":"force_bias"}}
    %   → 1-second read with test body ALREADY ATTACHED
    %   → saves biasVoltages (1x6) to calibrationGains.mat
    %   The manufacturer RunTimeMatrix is NEVER recalibrated.
    %
    % Calibration (motion sensors, interactive per session):
    %   {"cmd":"Calibrate","params":{"target":"motion_sensors",
    %                                "channel":"heave","knownValue_mm":2.5}}
    %   Repeat for each known position on each channel (heave/pitch/roll).
    %   {"cmd":"Calibrate","params":{"target":"motion_sensors","finished":true}}
    %   → fits spline lookup tables, saves motionCalibration.mat
    %
    % Run:
    %   Acquires raw 10-channel data for the experiment duration.
    %   enterPostProc applies: bias subtraction, RunTimeMatrix multiplication,
    %   Cheby2 low-pass filter, and motion sensor spline calibration.
    %
    % Required file (create once by running createRunTimeMatrix.m):
    %   carriage_node/carriageNodeRunTimeMatrix.mat  (variable: RunTimeMatrix)

    properties
        % Manufacturer decoupling matrix — loaded at startup, never recalibrated
        runTimeMatrix       % 6x6 double, maps SG voltages → Fx,Fy,Fz,Mx,My,Mz

        % Force bias — measured 1-second read with test body attached
        biasVoltages        % 1x6 double, one offset per SG channel

        % Motion sensor spline calibration (filled by handleCalibrate)
        motionCalib         % struct: .heave/.pitch/.roll, each with .V and .D arrays

        % Accumulation buffer during motion calibration session
        motionCalibBuffer   % struct: .heave/.pitch/.roll, each Nx2 [V, knownValue]

        % Acquisition state
        isCollecting        % logical
        duration            % seconds, set by Configure
        sampleRate          % Hz, from hardware config (or Configure override)

        % Raw DAQ output from handleRun — processed in enterPostProc
        rawData             % MATLAB timetable returned by read(daqSession, ...)

        % Hardware
        daqSession          % NI-DAQ session object
    end

    methods

        function obj = CarriageNodeManager(cfg, comm, rest)
            % Constructor — ExperimentManager base calls initializeHardware first,
            % then returns here for calibration file loading.
            obj@ExperimentManager(cfg, comm, rest);

            obj.isCollecting      = false;
            obj.rawData           = [];
            obj.motionCalibBuffer = struct('heave', [], 'pitch', [], 'roll', []);
            obj.motionCalib       = struct();

            % Load force bias if previously saved
            if isfile('calibrationGains.mat')
                loaded = load('calibrationGains.mat', 'biasVoltages');
                if isfield(loaded, 'biasVoltages')
                    obj.biasVoltages = loaded.biasVoltages;
                    obj.log("INFO", sprintf("Force bias loaded: [%s]", ...
                        strjoin(arrayfun(@(v) sprintf("%.5f", v), obj.biasVoltages, 'UniformOutput', false), ', ')));
                end
            else
                obj.log("WARN", "No force bias file found. Run force_bias calibration before first experiment.");
            end

            % Load motion calibration if previously saved
            if isfile('motionCalibration.mat')
                mc = load('motionCalibration.mat', 'motionCalib');
                obj.motionCalib = mc.motionCalib;
                obj.log("INFO", "Motion calibration loaded.");
            else
                obj.log("WARN", "No motion calibration found. Run motion_sensors calibration before first experiment.");
            end

            obj.log("INFO", "CarriageNodeManager initialized.");
        end

        function initializeHardware(obj, cfg)
            % initializeHardware
            % Creates the NI-DAQ session and adds all 10 input channels.
            % Channel add ORDER determines column indices in read() output:
            %   1-6: ai0-ai5 (SG0-SG5), 7: ai7 (sync), 8: ai17, 9: ai18, 10: ai19
            %
            % Also loads the manufacturer RunTimeMatrix from the .mat file
            % specified in cfg.hardware.runTimeMatrixFile.
            %
            % Required cfg.hardware fields:
            %   daqDevice        — NI device ID (e.g. 'Dev1')
            %   sampleRate       — DAQ scan rate in Hz (50 per original code)
            %   forceChannels    — cell array of 6 SG channel IDs ["ai0".."ai5"]
            %   syncChannel      — sync pulse channel ("ai7")
            %   heaveChannel     — heave sensor channel ("ai17")
            %   pitchChannel     — pitch sensor channel ("ai18")
            %   rollChannel      — roll sensor channel ("ai19")
            %   runTimeMatrixFile — path to .mat with variable RunTimeMatrix

            obj.experimentData = [];
            obj.rawData        = [];
            obj.isCollecting   = false;
            obj.sampleRate     = cfg.hardware.sampleRate;

            % Load manufacturer RunTimeMatrix
            rtmFile = cfg.hardware.runTimeMatrixFile;
            if ~isfile(rtmFile)
                error('CarriageNodeManager: RunTimeMatrix file not found: %s\nRun carriage_node/createRunTimeMatrix.m first.', rtmFile);
            end
            loaded = load(rtmFile, 'RunTimeMatrix');
            obj.runTimeMatrix = loaded.RunTimeMatrix;
            obj.log("INFO", sprintf("RunTimeMatrix loaded from %s", rtmFile));

            % Create NI-DAQ session
            obj.daqSession      = daq("ni");
            obj.daqSession.Rate = obj.sampleRate;

            % Add channels in fixed order — do NOT reorder without updating enterPostProc
            for k = 1:numel(cfg.hardware.forceChannels)
                addinput(obj.daqSession, cfg.hardware.daqDevice, cfg.hardware.forceChannels{k}, "Voltage");
            end
            addinput(obj.daqSession, cfg.hardware.daqDevice, cfg.hardware.syncChannel,  "Voltage");
            addinput(obj.daqSession, cfg.hardware.daqDevice, cfg.hardware.heaveChannel, "Voltage");
            addinput(obj.daqSession, cfg.hardware.daqDevice, cfg.hardware.pitchChannel, "Voltage");
            addinput(obj.daqSession, cfg.hardware.daqDevice, cfg.hardware.rollChannel,  "Voltage");

            obj.log("INFO", sprintf("DAQ session ready: 10 channels at %d Hz.", obj.sampleRate));
        end

        function isValid = configureHardware(obj, params)
            % configureHardware
            % Validates Configure params. Force sensor only requires duration.
            % Optional: params.sampleRate overrides the hardware config rate.

            hasDuration = isfield(params, 'duration') && isnumeric(params.duration) && params.duration > 0;
            if ~hasDuration
                obj.log("WARN", "configureHardware: missing or invalid duration.");
                isValid = false;
                return;
            end

            % Allow the control node to override sample rate at configure time
            if isfield(params, 'sampleRate') && isnumeric(params.sampleRate) && params.sampleRate > 0
                obj.daqSession.Rate = params.sampleRate;
                obj.sampleRate = params.sampleRate;
                obj.log("INFO", sprintf("Sample rate overridden to %d Hz by Configure command.", params.sampleRate));
            end

            obj.log("INFO", sprintf("Carriage config valid: duration=%.1f s, sampleRate=%d Hz.", ...
                params.duration, obj.sampleRate));
            isValid = true;
        end

        function setupCurrentExperiment(obj)
            setupCurrentExperiment@ExperimentManager(obj);
            obj.rawData        = [];
            obj.experimentData = [];
            obj.isCollecting   = false;

            if isfield(obj.experimentSpec.params, 'experiments')
                currentParams = obj.experimentSpec.params.experiments(obj.currentExperimentIndex);
            else
                currentParams = obj.experimentSpec.params;
            end

            obj.duration = currentParams.duration;
            obj.log("INFO", sprintf("Carriage experiment ready: duration=%.1f s.", obj.duration));
        end

        function handleCalibrate(obj, cmd)
            % handleCalibrate
            % Routes by cmd.params.target:
            %
            % "force_bias"
            %   Reads 1 second of data with the test body already attached.
            %   Takes the mean voltage of each of the 6 SG channels as the bias.
            %   Saves biasVoltages (1x6) to calibrationGains.mat.
            %   This matches the biasData block in the original .m code.
            %
            % "motion_sensors"
            %   Interactive point-by-point calibration for heave, pitch, roll.
            %   Each command with {channel, knownValue_mm} reads one 1-second
            %   voltage sample and stores the (V, knownValue_mm) pair.
            %   Final command with {finished:true} fits spline lookup tables
            %   and saves motionCalibration.mat.
            %   channel must be "heave", "pitch", or "roll".

            try
                target = string(cmd.params.target);

                if target == "force_bias"
                    obj.log("INFO", "Calibrating force bias — reading 1 s with test body attached...");
                    biasData = read(obj.daqSession, seconds(1));
                    biasArr  = mean(table2array(biasData), 1);  % 1x10 mean voltages
                    obj.biasVoltages = biasArr(1:6);            % cols 1-6 = SG0-SG5
                    biasVoltages = obj.biasVoltages;
                    save("calibrationGains.mat", "biasVoltages");
                    obj.log("INFO", sprintf("Force bias saved: [%s]", ...
                        strjoin(arrayfun(@(v) sprintf("%.5f", v), obj.biasVoltages, 'UniformOutput', false), ', ')));
                    obj.transition(State.IDLE);

                elseif target == "motion_sensors"
                    if isfield(cmd.params, 'finished') && cmd.params.finished

                        % Fit spline lookup for each channel that has enough data
                        validChannels = ["heave", "pitch", "roll"];
                        fitted = 0;
                        for ch = validChannels
                            buf = obj.motionCalibBuffer.(ch);
                            if size(buf, 1) >= 2
                                [sortedV, idx] = sort(buf(:, 1));
                                obj.motionCalib.(ch) = struct('V', sortedV, 'D', buf(idx, 2));
                                fitted = fitted + 1;
                                obj.log("INFO", sprintf("Motion calib fit: %s (%d points).", ch, size(buf,1)));
                            elseif ~isempty(buf)
                                obj.log("WARN", sprintf("Motion calib: %s has only 1 point (need ≥2). Skipped.", ch));
                            end
                        end

                        if fitted > 0
                            motionCalib = obj.motionCalib;
                            save("motionCalibration.mat", "motionCalib");
                            obj.log("INFO", sprintf("motionCalibration.mat saved (%d channels).", fitted));
                        else
                            obj.log("WARN", "Motion calibration: no channels had enough data. Nothing saved.");
                        end

                        obj.motionCalibBuffer = struct('heave', [], 'pitch', [], 'roll', []);
                        obj.transition(State.IDLE);

                    else
                        % Collect one calibration point for a named motion channel
                        channel    = string(cmd.params.channel);
                        knownValue = cmd.params.knownValue_mm;

                        % Fixed column indices in the DAQ read output
                        colMap = struct('heave', 8, 'pitch', 9, 'roll', 10);
                        if ~isfield(colMap, channel)
                            obj.log("ERROR", sprintf("Unknown motion channel: '%s'. Must be heave, pitch, or roll.", channel));
                            return;
                        end
                        colIdx = colMap.(channel);

                        rawRead = read(obj.daqSession, seconds(1));
                        rawArr  = mean(table2array(rawRead), 1);   % 1x10
                        V       = rawArr(colIdx);

                        obj.motionCalibBuffer.(channel) = [obj.motionCalibBuffer.(channel); V, knownValue];
                        nPts = size(obj.motionCalibBuffer.(channel), 1);
                        obj.log("INFO", sprintf("Motion calib point: %s  V=%.4f  knownValue=%.2f  (%d pts total).", ...
                            channel, V, knownValue, nPts));
                    end

                else
                    obj.log("ERROR", sprintf("handleCalibrate: unknown target '%s'. Use 'force_bias' or 'motion_sensors'.", target));
                end

            catch ME
                obj.log("ERROR", sprintf("handleCalibrate exception: %s", ME.message));
                rethrow(ME);
            end
        end

        function handleTest(obj, cmd)
            % handleTest
            % Streams live RunTimeMatrix-decoupled force readings while in TESTINGSENSOR.
            % Publishes one struct per scan to carriageNode/data.
            % Runs until the FSM state changes (e.g. a Reset command is received).

            obj.log("INFO", "handleTest: streaming live force readings. Send Reset to stop.");

            if isempty(obj.biasVoltages)
                obj.log("WARN", "No force bias loaded — using zero bias. Results uncorrected.");
                bias = zeros(1, 6);
            else
                bias = obj.biasVoltages;
            end

            while obj.state == State.TESTINGSENSOR
                rawRead = read(obj.daqSession, 1);     % 1 scan
                rawArr  = table2array(rawRead);         % 1x10
                SG_corrected = rawArr(1:6) - bias;      % bias subtraction
                FT = obj.runTimeMatrix * SG_corrected'; % 6x1 → Fx,Fy,Fz,Mx,My,Mz
                reading = struct( ...
                    'type',      'force', ...
                    'Fx',        FT(1), ...
                    'Fy',        FT(2), ...
                    'Fz',        FT(3), ...
                    'Mx',        FT(4), ...
                    'My',        FT(5), ...
                    'Mz',        FT(6), ...
                    'units',     'lb_lbin', ...
                    'timestamp', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')));
                obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
            end
        end

        function handleRun(obj, cmd)
            % handleRun
            % Reads raw 10-channel DAQ data for the experiment duration.
            % No processing is done here — all bias subtraction, RunTimeMatrix
            % multiplication, filtering, and motion calibration happen in
            % enterPostProc so that raw data is always preserved.

            obj.isCollecting = true;
            obj.log("INFO", sprintf("handleRun: acquiring %.1f s at %d Hz...", ...
                obj.duration, obj.sampleRate));

            obj.rawData = read(obj.daqSession, seconds(obj.duration));

            obj.isCollecting = false;
            obj.log("INFO", "handleRun: acquisition complete.");
            obj.transition(State.POSTPROC);
        end

        function enterPostProc(obj)
            % enterPostProc (override)
            % Processing pipeline applied to raw DAQ data:
            %   1. table2array conversion
            %   2. Bias subtraction on SG channels (cols 1-6)
            %   3. RunTimeMatrix multiplication → Fx,Fy,Fz,Mx,My,Mz
            %   4. Zero-phase Cheby2 low-pass filter on force+sync channels
            %   5. Spline calibration on heave/pitch/roll voltages (cols 8-10)
            %   6. Build output struct array, assign to obj.experimentData
            %   7. Call base class enterPostProc for CSV save + REST POST

            obj.log("INFO", "enterPostProc: processing raw force and motion data.");

            if isempty(obj.rawData)
                obj.log("WARN", "enterPostProc: rawData is empty. Skipping processing.");
                enterPostProc@ExperimentManager(obj);
                return;
            end

            raw      = table2array(obj.rawData);    % nSamples x 10
            nSamples = size(raw, 1);
            nTime    = (0 : 1/obj.sampleRate : (nSamples-1)/obj.sampleRate)';

            % --- 1. Bias subtraction on SG channels (cols 1-6) ---
            if ~isempty(obj.biasVoltages)
                STG = raw(:, 1:6) - obj.biasVoltages;   % broadcast 1x6 bias across rows
            else
                obj.log("WARN", "enterPostProc: no force bias — SG data uncorrected.");
                STG = raw(:, 1:6);
            end

            % --- 2. RunTimeMatrix decoupling ---
            % (RunTimeMatrix * STG')' gives nSamples x 6: [Fx, Fy, Fz, Mx, My, Mz]
            % Output units match the ATI sensor spec: lb and lb-in.
            FT = (obj.runTimeMatrix * STG')';

            % --- 3. Zero-phase Cheby2 low-pass filter ---
            % Stopband 3 Hz, 60 dB attenuation. SampleRate matches dq.Rate=50 Hz.
            % NOTE: original .m code has SampleRate=25 in designfilt which appears
            % to be a leftover from before dq.Rate was changed from 25 to 50.
            % Using the actual DAQ rate here. If you changed sampleRate via
            % Configure, the correct rate is used automatically.
            d1 = designfilt('lowpassiir', ...
                'FilterOrder',         12, ...
                'StopbandFrequency',   3, ...
                'StopbandAttenuation', 60, ...
                'SampleRate',          obj.sampleRate, ...
                'DesignMethod',        'cheby2');

            Fx   = filtfilt(d1, FT(:, 1));
            Fy   = filtfilt(d1, FT(:, 2));
            Fz   = filtfilt(d1, FT(:, 3));
            Mx   = FT(:, 4);   % moments not filtered in original code
            My   = FT(:, 5);
            Mz   = FT(:, 6);
            Sync = filtfilt(d1, raw(:, 7));

            % --- 4. Motion sensor calibration (cols 8-10) ---
            heaveRaw = raw(:, 8);
            pitchRaw = raw(:, 9);
            rollRaw  = raw(:, 10);

            if ~isempty(fieldnames(obj.motionCalib)) && isfield(obj.motionCalib, 'heave')
                Heave_mm  = interp1(obj.motionCalib.heave.V, obj.motionCalib.heave.D, heaveRaw, 'spline', 'extrap');
                Pitch_deg = interp1(obj.motionCalib.pitch.V, obj.motionCalib.pitch.D, pitchRaw, 'spline', 'extrap');
                Roll_deg  = interp1(obj.motionCalib.roll.V,  obj.motionCalib.roll.D,  rollRaw,  'spline', 'extrap');
            else
                obj.log("WARN", "enterPostProc: no motion calibration — storing raw voltages for heave/pitch/roll.");
                Heave_mm  = heaveRaw;
                Pitch_deg = pitchRaw;
                Roll_deg  = rollRaw;
            end

            % --- 5. Build output struct array for base class CSV/REST ---
            obj.experimentData = struct( ...
                'nTime',     num2cell(nTime), ...
                'Fx',        num2cell(Fx), ...
                'Fy',        num2cell(Fy), ...
                'Fz',        num2cell(Fz), ...
                'Mx',        num2cell(Mx), ...
                'My',        num2cell(My), ...
                'Mz',        num2cell(Mz), ...
                'Heave_mm',  num2cell(Heave_mm), ...
                'Pitch_deg', num2cell(Pitch_deg), ...
                'Roll_deg',  num2cell(Roll_deg), ...
                'Sync',      num2cell(Sync));

            obj.log("INFO", sprintf("enterPostProc: %d samples processed → Fx,Fy,Fz,Mx,My,Mz,Heave,Pitch,Roll,Sync.", nSamples));

            % Hand off to base class: saves CSV, POSTs to REST, handles state transition
            enterPostProc@ExperimentManager(obj);
        end

        function stopHardware(obj)
            obj.isCollecting = false;
            obj.log("INFO", "stopHardware: halting DAQ acquisition.");
            try
                stop(obj.daqSession);
            catch ME
                obj.log("WARN", sprintf("stopHardware DAQ stop error: %s", ME.message));
            end
        end

        function shutdownHardware(obj)
            obj.isCollecting   = false;
            obj.experimentData = [];
            obj.rawData        = [];
            obj.log("INFO", "shutdownHardware: releasing DAQ resources.");
            try
                stop(obj.daqSession);
                delete(obj.daqSession);
            catch ME
                obj.log("WARN", sprintf("shutdownHardware DAQ release error: %s", ME.message));
            end
        end

    end
end
