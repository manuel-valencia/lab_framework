classdef MyNodeManager < ExperimentManager
    % MyNodeManager
    %
    % Replace this header with a description of what hardware this node owns,
    % what hasSensor / hasActuator flags it requires, and the interface used
    % (NI-DAQ analog voltage, GPIO digital/PWM, serial port, etc.).
    %
    % One node per physical hardware interface:
    %   A single NI-DAQ device (e.g. Dev1) cannot be shared between two nodes —
    %   MATLAB only allows one daq() session per device at a time. If you need to
    %   read from multiple sensors AND drive an actuator that all connect to the
    %   same device, they must all live in one node class (with hasSensor=true AND
    %   hasActuator=true). Only split into separate nodes if they use separate
    %   physical devices (e.g. Dev1 for force, Dev2 for motion).
    %   The same applies to serial ports and GPIO interfaces.
    %
    % Calibration:
    %   Describe what Calibrate commands this node accepts and what they produce.
    %   (e.g. bias collection, gain fitting, lookup table construction)
    %
    % Run:
    %   Describe what handleRun does and what post-processing enterPostProc applies.
    %
    % Required cfg.hardware fields:
    %   List the fields this node reads from the hardware section of its config JSON.

    properties
        % Hardware interface — replace or extend based on your hardware type:
        %   NI-DAQ analog:  daqSession = daq("ni");  sampleRate from cfg
        %   Arduino GPIO:   device = arduino(port, board);  e.g. arduino("COM3","Uno")
        %   Raspberry Pi:   device = raspi();  for GPIO digital/PWM output
        %   Serial device:  device = serialport(port, baudRate);
        %   Custom driver:  any handle object — just store it here and clean it up in shutdownHardware
        device              % hardware interface object (DAQ session, arduino, raspi, serialport, etc.)
        sampleRate          % Hz — for DAQ nodes; set from cfg.hardware.sampleRate
        isCollecting        % logical — true while a data collection loop is active

        % Calibration
        calibrationFile     % full path to the .mat file that persists calibration state
        biasValues          % 1×N double — per-channel DC offset, subtracted before processing

        % Experiment state (set by configureHardware / setupCurrentExperiment)
        duration            % seconds

        % Post-processing output — assigned in enterPostProc, consumed by base class
        rawData             % collected data (format depends on interface: timetable for DAQ, array for GPIO/serial)
        outputChannels      % cell array of field names to keep; empty = keep all

        % Streaming (NI-DAQ only — not needed for GPIO/serial polling loops)
        streamListener      % logical — true while ScansAvailableFcn is active
    end

    methods

        function obj = MyNodeManager(cfg, comm, rest)
            % Constructor — ExperimentManager base calls initializeHardware before returning.
            obj@ExperimentManager(cfg, comm, rest);

            obj.isCollecting   = false;
            obj.rawData        = [];
            obj.outputChannels = {};
            obj.biasValues     = [];
            obj.streamListener = false;

            nodeDir = fileparts(mfilename('fullpath'));
            obj.logDir          = fullfile(nodeDir, 'myNodeLogs');
            obj.calibrationFile = fullfile(nodeDir, 'myNodeCalibration.mat');

            % Load saved calibration if it exists.
            if isfile(obj.calibrationFile)
                loaded = load(obj.calibrationFile);
                if isfield(loaded, 'biasValues')
                    obj.biasValues = loaded.biasValues;
                    obj.log("INFO", "Calibration loaded.");
                end
            else
                obj.log("WARN", "No calibration file found. Run calibration before first experiment.");
            end

            obj.log("INFO", "MyNodeManager initialized.");
        end

        function initializeHardware(obj, cfg)
            % initializeHardware
            % Open and configure the hardware interface for this node.
            % Choose the pattern below that matches your hardware type.
            %
            % Load any required model or lookup files here (not in the constructor)
            % so that re-init after an ERROR recovery state also reloads them.

            obj.isCollecting = false;

            % ── Option A: NI-DAQ analog voltage (most common for lab DAQ boards) ─────
            %
            % IMPORTANT: two nodes cannot share one physical DAQ device.
            % MATLAB allows only one daq() session per device ID at a time.
            % If multiple sensors and actuators connect to the same device,
            % add all of their channels to THIS node (hasSensor=true, hasActuator=true).
            %
            % Channel add ORDER is fixed — it determines column indices in read()/readwrite()
            % output. Do not reorder channels without updating enterPostProc and any
            % column index constants.
            %
            % When BOTH AI and AO channels exist on the same session, use readwrite()
            % everywhere instead of read() — MATLAB errors if you call read() alone
            % when an AO channel is present.
            %
            %   obj.sampleRate   = cfg.hardware.sampleRate;
            %   obj.device       = daq("ni");
            %   obj.device.Rate  = obj.sampleRate;
            %   addinput(obj.device,  cfg.hardware.daqDevice, cfg.hardware.sensorChannel,  "Voltage");
            %   addoutput(obj.device, cfg.hardware.daqDevice, cfg.hardware.outputChannel, "Voltage");
            %   obj.log("INFO", sprintf("NI-DAQ session ready at %d Hz.", obj.sampleRate));

            % ── Option B: Arduino GPIO (digital/PWM read and write) ───────────────────
            %
            % The MATLAB Support Package for Arduino Hardware is required.
            % Two nodes cannot share one Arduino object — same rule as DAQ.
            %
            %   obj.device = arduino(cfg.hardware.port, cfg.hardware.board);
            %   % e.g. arduino("COM3", "Uno") or arduino("/dev/ttyUSB0", "Mega2560")
            %
            % Reading a digital pin (sensor):
            %   val = readDigitalPin(obj.device, cfg.hardware.sensorPin);  % 0 or 1
            %
            % Writing a digital pin (actuator on/off):
            %   writeDigitalPin(obj.device, cfg.hardware.outputPin, 1);
            %
            % PWM output (e.g. motor speed, 0.0–1.0 duty cycle):
            %   writePWMDutyCycle(obj.device, cfg.hardware.pwmPin, 0.5);
            %
            % Analog read (ADC, 0–5 V mapped to 0.0–5.0):
            %   val = readVoltage(obj.device, cfg.hardware.analogPin);
            %
            % For a polling loop at a known rate, track time with tic/toc:
            %   obj.sampleRate = cfg.hardware.sampleRate;
            %   % In handleRun, poll at 1/sampleRate intervals
            %   obj.log("INFO", "Arduino GPIO interface ready.");

            % ── Option C: Raspberry Pi GPIO ───────────────────────────────────────────
            %
            % The MATLAB Support Package for Raspberry Pi Hardware is required.
            %
            %   obj.device = raspi();
            %
            % Digital read:
            %   val = readDigitalPin(obj.device, cfg.hardware.sensorPin);
            %
            % Digital write:
            %   writeDigitalPin(obj.device, cfg.hardware.outputPin, 1);
            %
            % PWM (via pigpio):
            %   writePWMFrequency(obj.device, cfg.hardware.pwmPin, 1000);   % Hz
            %   writePWMDutyCycle(obj.device, cfg.hardware.pwmPin, 0.5);
            %
            %   obj.log("INFO", "Raspberry Pi GPIO interface ready.");

            % ── Option D: Serial port device ─────────────────────────────────────────
            %
            % Use for microcontrollers, instruments, or any device with a COM/tty port.
            %
            %   obj.device = serialport(cfg.hardware.port, cfg.hardware.baudRate);
            %   configureTerminator(obj.device, "LF");
            %
            % Reading a line (sensor returning ASCII):
            %   line = readline(obj.device);
            %   val  = str2double(strtrim(line));
            %
            % Writing a command (actuator control):
            %   writeline(obj.device, "SET 100");
            %
            %   obj.sampleRate = cfg.hardware.sampleRate;  % polling rate
            %   obj.log("INFO", sprintf("Serial port %s ready.", cfg.hardware.port));

            error("MyNodeManager:NotImplemented", "initializeHardware not implemented.");
        end

        function isValid = configureHardware(obj, params)
            % configureHardware
            % Validates Configure params against hardware limits.
            % Return false (with a WARN log) on any failed check; return true when all pass.
            % Do NOT transition state here — the base class handles that.
            %
            % Required params fields (define based on your experiment type):
            %   params.duration  — experiment duration in seconds (required by all nodes)
            %
            % Optional overrides (common pattern):
            %   params.sampleRate — override hardware config rate at configure time

            if ~isfield(params, 'duration') || ~isnumeric(params.duration) || params.duration <= 0
                obj.log("WARN", "configureHardware: duration missing or invalid.");
                isValid = false;
                return;
            end

            % Optional: allow control node to override sample rate per experiment.
            % Only applies to NI-DAQ nodes. For GPIO/serial nodes, remove this block.
            % if isfield(params, 'sampleRate') && isnumeric(params.sampleRate) && params.sampleRate > 0
            %     obj.device.Rate = params.sampleRate;
            %     obj.sampleRate  = params.sampleRate;
            %     obj.log("INFO", sprintf("Sample rate overridden to %d Hz.", params.sampleRate));
            % end

            % Optional: restrict which output columns are saved to CSV / REST.
            if isfield(params, 'outputChannels') && ~isempty(params.outputChannels)
                obj.outputChannels = cellstr(params.outputChannels);
            else
                obj.outputChannels = {};
            end

            % Add your hardware-limit checks here. Pattern:
            %   if params.myParam > MAX_VALUE
            %       obj.log("WARN", sprintf("myParam %.2f exceeds limit %.2f.", params.myParam, MAX_VALUE));
            %       isValid = false; return;
            %   end

            obj.log("INFO", sprintf("Config valid: duration=%.1f s.", params.duration));
            isValid = true;
        end

        function handleCalibrate(obj, cmd) %#ok<INUSD>
            % handleCalibrate
            % Common pattern: route by cmd.params.target, collect point-by-point,
            % finalize on params.finished = true.
            %
            % Bias collection example (1-second blocking read, NI-DAQ):
            %   biasData     = read(obj.device, seconds(1));   % timetable
            %   biasArr      = mean(table2array(biasData), 1); % 1×nCh mean voltages
            %   obj.biasValues = biasArr(1:N);
            %   save(obj.calibrationFile, 'biasValues');
            %   obj.transition(State.IDLE);
            %
            % If the DAQ session has both AI and AO channels, use readwrite() instead of read():
            %   rawRead = readwrite(obj.device, zeros(nScans, 1));  % zero AO output while reading
            %   biasArr = mean(rawRead.Variables, 1);
            %
            % Bias collection example (GPIO/serial polling):
            %   N = round(obj.sampleRate * 1.0);  % 1-second worth of samples
            %   buf = zeros(N, 1);
            %   for k = 1:N
            %       buf(k) = readVoltage(obj.device, cfg.hardware.analogPin);
            %       pause(1 / obj.sampleRate);
            %   end
            %   obj.biasValues = mean(buf);
            %   save(obj.calibrationFile, 'biasValues');
            %   obj.transition(State.IDLE);
            %
            % Point-by-point calibration example (any interface):
            %   obj.calibBuffer = [obj.calibBuffer; knownValue, measuredVoltage];
            %   if isfield(cmd.params, 'finished') && cmd.params.finished
            %       gains = polyfit(obj.calibBuffer(:,2), obj.calibBuffer(:,1), 1);
            %       save(obj.calibrationFile, 'gains');
            %       obj.transition(State.IDLE);
            %   end

            error("MyNodeManager:NotImplemented", "handleCalibrate not implemented.");
        end

        function handleTest(obj, cmd) %#ok<INUSD>
            % handleTest
            % Use ScansAvailableFcn for DAQ streaming — do NOT use a blocking while loop.
            % A blocking loop inside handleTest prevents the MQTT callback from
            % processing a Reset command, leaving the node stuck in TESTINGSENSOR.
            %
            % NI-DAQ sensor streaming pattern:
            %   blockSize = 5;   % fire every N scans (e.g. 5 @ 50 Hz → 10 Hz publish rate)
            %   obj.device.ScansAvailableFcnCount = blockSize;
            %   obj.device.ScansAvailableFcn = @(src, ~) obj.onDataAvailable(src, blockSize);
            %   obj.streamListener = true;
            %   start(obj.device, "continuous");
            %   % handleTest returns immediately; streaming continues in the background.
            %   % The callback self-stops when FSM leaves TESTINGSENSOR — see teardownStreamListener.
            %
            % NI-DAQ actuator test pattern (preload + timer):
            %   preload(obj.device, outputSignal);
            %   start(obj.device, "repeatoutput");
            %   tStop = timer('ExecutionMode', 'singleShot', 'StartDelay', duration, ...
            %                  'TimerFcn', @(~,~) obj.finishActuatorTest());
            %   start(tStop);
            %
            % If the DAQ session has both AI and AO channels, preload zeros before any
            % read() or readwrite() call — the AO channel always needs queued data.
            %
            % GPIO / serial streaming pattern (uses a background timer instead of ScansAvailableFcn):
            %   obj.streamListener = true;
            %   t = timer('ExecutionMode', 'fixedRate', 'Period', 1/obj.sampleRate, ...
            %              'TimerFcn', @(~,~) obj.onDataAvailable());
            %   start(t);
            %   % In onDataAvailable, check obj.state and stop the timer when FSM exits TESTINGSENSOR.

            error("MyNodeManager:NotImplemented", "handleTest not implemented.");
        end

        function handleRun(obj, cmd) %#ok<INUSD>
            % handleRun
            % Read in short chunks so the Abort command can be processed between reads.
            % A single read(..., seconds(duration)) blocks for the full duration and
            % delays Abort handling until acquisition is complete.
            %
            % NI-DAQ chunked acquisition:
            %   targetScans = round(obj.duration * obj.sampleRate);
            %   chunkScans  = round(0.25 * obj.sampleRate);   % ~250 ms chunks
            %   scansRead   = 0;
            %   rawAccum    = [];
            %   while scansRead < targetScans
            %       if obj.abortRequested || obj.state ~= State.RUNNING
            %           obj.isCollecting = false;
            %           obj.rawData = [];
            %           return;
            %       end
            %       nToRead = min(chunkScans, targetScans - scansRead);
            %       chunk   = read(obj.device, nToRead);   % use readwrite() if AO present
            %       rawAccum = [rawAccum; chunk];           %#ok<AGROW>
            %       scansRead = height(rawAccum);
            %   end
            %   obj.rawData = rawAccum;
            %   obj.transition(State.POSTPROC);   % enterPostProc runs next
            %
            % For actuator + sensor DAQ nodes: preload the output signal before the loop,
            % then use readwrite() inside the loop to keep the AO channel fed.
            %
            % GPIO / serial polling loop (abort-safe, same structure as DAQ):
            %   targetSamples = round(obj.duration * obj.sampleRate);
            %   rawAccum      = zeros(targetSamples, 1);
            %   tNext         = tic;
            %   for k = 1:targetSamples
            %       if obj.abortRequested || obj.state ~= State.RUNNING
            %           obj.isCollecting = false;
            %           obj.rawData = [];
            %           return;
            %       end
            %       rawAccum(k) = readVoltage(obj.device, cfg.hardware.analogPin);
            %       pause(max(0, 1/obj.sampleRate - toc(tNext)));   % drift-corrected wait
            %       tNext = tic;
            %   end
            %   obj.rawData = rawAccum;
            %   obj.transition(State.POSTPROC);

            error("MyNodeManager:NotImplemented", "handleRun not implemented.");
        end

        function stopHardware(obj)
            % stopHardware
            % Called on Abort or Reset from any active state.
            % Safe-stop outputs and halt data collection. For DAQ nodes, always
            % tear down the stream listener before stopping the session so no
            % callbacks fire after the session is halted.
            obj.isCollecting = false;
            obj.log("INFO", "stopHardware: halting hardware interface.");

            % NI-DAQ pattern:
            %   obj.teardownStreamListener();
            %   try
            %       if ~isempty(obj.device) && obj.device.Running
            %           stop(obj.device);
            %       end
            %   catch ME
            %       obj.log("WARN", sprintf("stopHardware stop error: %s", ME.message));
            %   end
            %   % After ERROR recovery, NI hardware buffers may be corrupt.
            %   % Delete and recreate the full session to reset driver state.
            %   if obj.prevState == State.ERROR
            %       try; delete(obj.device); catch; end
            %       try
            %           obj.initializeHardware(obj.cfg);
            %           obj.log("INFO", "stopHardware: interface recreated after ERROR recovery.");
            %       catch ME
            %           obj.log("ERROR", sprintf("stopHardware: reinit failed: %s", ME.message));
            %       end
            %   end

            % Arduino / Raspberry Pi GPIO pattern:
            %   writeDigitalPin(obj.device, cfg.hardware.outputPin, 0);   % drive outputs low
            %   % No session to stop — just zero all outputs here.

            % Serial port pattern:
            %   writeline(obj.device, "STOP");   % send stop command to device firmware

            error("MyNodeManager:NotImplemented", "stopHardware not implemented.");
        end

        function shutdownHardware(obj)
            % shutdownHardware
            % Called on clean node exit. Release all hardware resources so MATLAB
            % does not hold the interface open after the node terminates.
            obj.isCollecting   = false;
            obj.experimentData = [];
            obj.rawData        = [];
            obj.log("INFO", "shutdownHardware: releasing hardware interface.");

            % NI-DAQ pattern:
            %   obj.teardownStreamListener();
            %   try
            %       stop(obj.device);
            %       delete(obj.device);
            %   catch ME
            %       obj.log("WARN", sprintf("shutdownHardware release error: %s", ME.message));
            %   end

            % Arduino / Raspberry Pi GPIO pattern:
            %   try
            %       writeDigitalPin(obj.device, cfg.hardware.outputPin, 0);
            %       clear obj.device;   % release the connection
            %   catch ME
            %       obj.log("WARN", sprintf("shutdownHardware release error: %s", ME.message));
            %   end

            % Serial port pattern:
            %   try
            %       writeline(obj.device, "STOP");
            %       clear obj.device;   % closes the port
            %   catch ME
            %       obj.log("WARN", sprintf("shutdownHardware release error: %s", ME.message));
            %   end

            error("MyNodeManager:NotImplemented", "shutdownHardware not implemented.");
        end

    end

    methods (Access = protected)

        function enterPostProc(obj)
            % enterPostProc (optional override)
            % Called automatically by the base class when the FSM enters POSTPROC.
            % Override here to apply signal processing to obj.rawData before the
            % base class saves the CSV and POSTs to REST.
            %
            % Typical pipeline:
            %   1. raw = table2array(obj.rawData);         % nSamples × nChannels
            %   2. Apply bias subtraction, calibration matrix, filtering
            %   3. Build obj.experimentData as a struct array with one field per output column
            %   4. Apply outputChannels filter (see CarriageNodeManager.enterPostProc for pattern)
            %   5. Call enterPostProc@ExperimentManager(obj) — MUST be last line
            %
            % If you do not need custom post-processing, delete this method entirely
            % and the base class will handle CSV save + REST POST directly from
            % whatever is already in obj.experimentData at the end of handleRun.

            % Replace with your processing, then always end with:
            enterPostProc@ExperimentManager(obj);
        end

        function onDataAvailable(obj, src, blockSize)
            % onDataAvailable — ScansAvailableFcn callback for NI-DAQ sensor streaming.
            % Self-stops when the FSM leaves TESTINGSENSOR.
            % For GPIO/serial nodes, use a timer-based equivalent (see handleTest).
            if obj.state ~= State.TESTINGSENSOR
                obj.teardownStreamListener();
                try
                    stop(src);
                catch
                end
                return;
            end
            try
                rawBlock = read(src, blockSize);               % timetable: blockSize × nCh
                rawArr   = mean(table2array(rawBlock), 1);     % 1×nCh mean

                % Build your reading struct and publish to MQTT:
                reading = struct('value', rawArr(1), ...
                    'timestamp', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')));
                obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(reading));
            catch ME
                obj.log("WARN", sprintf("onDataAvailable error: %s", ME.message));
            end
        end

        function teardownStreamListener(obj)
            % teardownStreamListener
            % Clears ScansAvailableFcn and resets the streamListener flag.
            % This is the NI-DAQ pattern. For GPIO/serial timer-based streaming,
            % replace this with: stop(obj.streamTimer); delete(obj.streamTimer);
            if ~obj.streamListener
                return;
            end
            try
                obj.device.ScansAvailableFcn = [];
            catch
            end
            obj.streamListener = false;
        end

    end
end
