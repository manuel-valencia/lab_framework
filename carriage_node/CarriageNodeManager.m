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
    %   → saves biasVoltages (1x6) to carriageCalibration.mat
    %   Force bias is also collected automatically before every Test and Run.
    %   The manufacturer RunTimeMatrix is NEVER recalibrated.
    %
    % Calibration (motion sensors, interactive per session):
    %   {"cmd":"Calibrate","params":{"target":"motion_sensors",
    %                                "channel":"heave","knownValue_mm":2.5}}
    %   Repeat for each known position on each channel (heave/pitch/roll).
    %   {"cmd":"Calibrate","params":{"target":"motion_sensors","finished":true}}
    %   → fits spline lookup tables, saves carriageCalibration.mat
    %
    % Run:
    %   Acquires raw 10-channel data for the experiment duration.
    %   enterPostProc applies: bias subtraction, RunTimeMatrix multiplication,
    %   Cheby2 low-pass filter, and motion sensor spline calibration.
    %
    % Required file (create once by running createRunTimeMatrix.m):
    %   carriage_node/carriageNodeRunTimeMatrix.mat  (variable: RunTimeMatrix)
    %   This is the manufacturer decoupling matrix for the ATI sensor.

    properties
        % Manufacturer decoupling matrix — loaded at startup, never recalibrated
        runTimeMatrix       % 6x6 double, maps SG voltages → Fx,Fy,Fz,Mx,My,Mz

        % Force bias — measured 1-second read with test body attached
        biasVoltages        % 1x6 double, one offset per SG channel
        calibrationFile     % Full path to carriageCalibration.mat

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
        streamListener      % DataAvailable listener handle for Test streaming
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

            % Calibration file and log folder.
            % calibrationFile follows cfg.hardware.calibrationFile when provided,
            % otherwise defaults to this class folder so the mock subclass can
            % override it to test/carriage_node/.
            nodeDir = fileparts(mfilename('fullpath'));
            if isfield(cfg, 'hardware') && isfield(cfg.hardware, 'calibrationFile') && ~isempty(cfg.hardware.calibrationFile)
                obj.calibrationFile = cfg.hardware.calibrationFile;
            else
                obj.calibrationFile = fullfile(nodeDir, 'carriageCalibration.mat');
            end
            obj.logDir          = fullfile(nodeDir, 'carriageNodeLogs');

            % Load saved calibration (force bias + motion sensors) from single file.
            % Legacy fallback: if carriageCalibration.mat is missing but
            % calibrationGains.mat exists in the same folder, try that file.
            calibPath = obj.calibrationFile;
            legacyCalibPath = fullfile(fileparts(obj.calibrationFile), 'calibrationGains.mat');
            if ~isfile(calibPath) && isfile(legacyCalibPath)
                calibPath = legacyCalibPath;
                obj.log("WARN", sprintf("Primary calibration file not found, falling back to legacy file: %s", legacyCalibPath));
            end

            if isfile(calibPath)
                loaded = load(calibPath);
                if isfield(loaded, 'biasVoltages')
                    obj.biasVoltages = loaded.biasVoltages;
                    obj.log("INFO", sprintf("Force bias loaded: [%s]", ...
                        strjoin(arrayfun(@(v) sprintf('%.5f', v), obj.biasVoltages, 'UniformOutput', false), ', ')));
                elseif isfield(loaded, 'gains') && isnumeric(loaded.gains) && numel(loaded.gains) >= 6
                    % Best-effort compatibility for older calibrationGains.mat formats.
                    obj.biasVoltages = loaded.gains(1:6);
                    obj.log("WARN", "Loaded legacy 'gains' field as biasVoltages(1:6). Please migrate to carriageCalibration.mat format.");
                else
                    obj.log("WARN", sprintf("Calibration file found but contains no biasVoltages-compatible field: %s", calibPath));
                end
                if isfield(loaded, 'motionCalib')
                    obj.motionCalib = loaded.motionCalib;
                    obj.log("INFO", "Motion calibration loaded.");
                else
                    obj.log("WARN", sprintf("Calibration file contains no motionCalib: %s. Run motion_sensors calibration.", calibPath));
                end
            else
                obj.log("WARN", sprintf("No calibration file found at %s. Run force_bias and motion_sensors calibration before first experiment.", obj.calibrationFile));
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
            %   Saves biasVoltages (1x6) to carriageCalibration.mat.
            %   This matches the biasData block in the original .m code.
            %
            % "motion_sensors"
            %   Interactive point-by-point calibration for heave, pitch, roll.
            %   Each command with {channel, knownValue_mm} reads one 1-second
            %   voltage sample and stores the (V, knownValue_mm) pair.
            %   Final command with {finished:true} fits spline lookup tables
            %   and saves carriageCalibration.mat.
            %   channel must be "heave", "pitch", or "roll".

            try
                target = string(cmd.params.target);

                if target == "force_bias"
                    obj.collectForceBias();
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
                            obj.saveCarriageCalibration();
                            obj.log("INFO", sprintf("carriageCalibration.mat saved (%d motion channels).", fitted));
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

        function handleTest(obj, cmd) %#ok<INUSD>
            % handleTest
            % Collects a fresh force bias then attaches a DataAvailable listener
            % to the DAQ session. The hardware pushes data to onDataAvailableTest
            % every time NotifyWhenDataAvailableExceeds samples arrive — no
            % blocking read() in the hot path, no timer re-entrancy.
            % handleTest returns immediately; streaming stops when the FSM
            % leaves TESTINGSENSOR (Reset command) via stopHardware.

            obj.log("INFO", "handleTest: collecting fresh force bias before streaming...");

            % Delete any existing stream listener and stop DAQ before the
            % blocking read() in collectForceBias.
            obj.teardownStreamListener();
            try
                if obj.daqSession.Running
                    stop(obj.daqSession);
                end
            catch; end
            pause(0.1);   % let NI hardware fully flush and go idle

            obj.collectForceBias();
            obj.log("INFO", "handleTest: starting sensor stream. Send Reset to stop.");

            bias      = obj.biasVoltages;
            blockSize = 5;   % fire every 5 scans → 10 Hz at 50 Hz sample rate

            % Use DataAvailable event: hardware pushes evt.Data when
            % NotifyWhenDataAvailableExceeds samples are buffered.
            % No read() call in the callback — eliminates re-entrancy.
            obj.daqSession.NotifyWhenDataAvailableExceeds = blockSize;
            obj.streamListener = addlistener(obj.daqSession, 'DataAvailable', ...
                @(~, evt) obj.onDataAvailableTest(evt, bias));

            try
                start(obj.daqSession, "continuous");
            catch ME
                obj.log("WARN", sprintf("handleTest: failed to start DAQ acquisition: %s", ME.message));
                obj.teardownStreamListener();
            end
        end

        function onDataAvailableTest(obj, evt, bias)
            % onDataAvailableTest — DataAvailable callback for Test streaming.
            % Data is pushed by the hardware; no read() call needed.
            % Self-stops when the FSM leaves TESTINGSENSOR.
            if obj.state ~= State.TESTINGSENSOR
                obj.teardownStreamListener();
                try; stop(obj.daqSession); catch; end
                return;
            end
            try
                rawArr       = mean(evt.Data{:,:}, 1);   % mean block → 1x10
                SG_corrected = rawArr(1:6) - bias;
                FT           = obj.runTimeMatrix * SG_corrected';
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
            catch ME
                obj.log("WARN", sprintf("onDataAvailableTest error: %s", ME.message));
            end
        end

        function handleRun(obj, cmd)
            % handleRun
            % Collects a fresh force bias (water ingress between runs), then reads
            % raw 10-channel DAQ data for the experiment duration.
            % All further processing happens in enterPostProc.

            obj.log("INFO", "handleRun: collecting fresh force bias before acquisition...");
            obj.collectForceBias();

            obj.isCollecting = true;
            obj.log("INFO", sprintf("handleRun: acquiring %.1f s at %d Hz...", ...
                obj.duration, obj.sampleRate));

            % Read in short chunks so Abort can be processed between reads.
            % A single read(..., seconds(duration)) blocks command handling for
            % the entire run and delays Abort until acquisition completes.
            targetScans = max(1, round(obj.duration * obj.sampleRate));
            chunkScans  = max(1, round(0.25 * obj.sampleRate));  % ~250 ms chunks
            scansRead   = 0;
            rawAccum    = [];

            while scansRead < targetScans
                if obj.abortRequested || obj.state ~= State.RUNNING
                    obj.isCollecting = false;
                    obj.rawData = [];
                    obj.log("WARN", sprintf("handleRun: acquisition aborted at %d/%d scans.", scansRead, targetScans));
                    return;
                end

                nToRead = min(chunkScans, targetScans - scansRead);
                chunk = read(obj.daqSession, nToRead);

                if isempty(rawAccum)
                    rawAccum = chunk;
                else
                    rawAccum = [rawAccum; chunk]; %#ok<AGROW>
                end

                scansRead = height(rawAccum);
            end

            obj.rawData = rawAccum;
            obj.isCollecting = false;
            obj.log("INFO", "handleRun: acquisition complete.");
            obj.transition(State.POSTPROC);
        end

    end

    methods (Access = protected)

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

        function collectForceBias(obj)
            % collectForceBias
            % Reads 1 second of DAQ data and stores the mean SG voltages (cols 1-6)
            % as the force bias. Saves to carriageCalibration.mat alongside any
            % existing motion calibration data.
            % Called automatically before every Test and Run, and by handleCalibrate
            % when target == "force_bias".
            obj.log("INFO", "collectForceBias: reading 1 s with test body attached...");
            % Ensure DAQ is stopped before a blocking read() — a running
            % continuous session would otherwise cause a re-entrancy conflict.
            try
                if obj.daqSession.Running; stop(obj.daqSession); end
            catch; end
            biasData         = read(obj.daqSession, seconds(1));
            biasArr          = mean(table2array(biasData), 1);  % 1x10 mean voltages
            obj.biasVoltages = biasArr(1:6);                    % cols 1-6 = SG0-SG5
            obj.saveCarriageCalibration();
            obj.log("INFO", sprintf("Force bias collected: [%s]", ...
                strjoin(arrayfun(@(v) sprintf('%.5f', v), obj.biasVoltages, 'UniformOutput', false), ', ')));
        end

        function saveCarriageCalibration(obj)
            % saveCarriageCalibration
            % Saves both biasVoltages and motionCalib into a single
            % carriageCalibration.mat file so all calibration state is co-located.
            biasVoltages = obj.biasVoltages; %#ok<PROPLC>
            motionCalib  = obj.motionCalib;
            save(obj.calibrationFile, "biasVoltages", "motionCalib");
        end

    end

    methods (Access = public)

        function stopHardware(obj)
            obj.isCollecting = false;
            obj.log("INFO", "stopHardware: halting DAQ acquisition.");

            % Delete the DataAvailable listener first so no further callbacks
            % fire after this point.
            obj.teardownStreamListener();

            try
                if ~isempty(obj.daqSession)
                    stop(obj.daqSession);
                end
            catch ME
                obj.log("WARN", sprintf("stopHardware DAQ stop error: %s", ME.message));
            end

            % If recovering from ERROR, NI hardware buffers may be corrupt.
            % Delete and recreate the entire session to fully reset driver state.
            if obj.prevState == State.ERROR
                try
                    delete(obj.daqSession);
                catch; end
                try
                    obj.initializeHardware(obj.cfg);
                    obj.log("INFO", "stopHardware: DAQ session recreated after ERROR recovery.");
                catch ME
                    obj.log("ERROR", sprintf("stopHardware: DAQ reinit failed: %s", ME.message));
                end
            end
        end

        function shutdownHardware(obj)
            obj.isCollecting   = false;
            obj.experimentData = [];
            obj.rawData        = [];
            obj.log("INFO", "shutdownHardware: releasing DAQ resources.");
            obj.teardownStreamListener();
            try
                stop(obj.daqSession);
                delete(obj.daqSession);
            catch ME
                obj.log("WARN", sprintf("shutdownHardware DAQ release error: %s", ME.message));
            end
        end

    end

    methods (Access = private)

        function teardownStreamListener(obj)
            % teardownStreamListener — safely delete the DataAvailable listener.
            % Must be called before stop()/delete() on the DAQ session to avoid
            % 'Invalid or deleted object' warnings from orphaned callbacks.
            if ~isempty(obj.streamListener) && isvalid(obj.streamListener)
                delete(obj.streamListener);
            end
            obj.streamListener = [];
        end

    end
end
