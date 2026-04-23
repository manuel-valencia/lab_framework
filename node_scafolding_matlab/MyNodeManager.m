classdef MyNodeManager < ExperimentManager
    %MYNODEMANAGER  Node-specific subclass of ExperimentManager
    %
    % This class implements command-specific behaviors (e.g., Run, Calibrate)
    % that are unique to this node's hardware or test protocol.
    %
    % REQUIRED: You must implement ALL abstract methods below for your specific
    % hardware setup. Each method contains placeholder error messages - replace
    % with your actual hardware control code.

    methods
        function obj = MyNodeManager(cfg, comm, rest)
            % Constructor: Initialize the node manager with communication clients
            obj@ExperimentManager(cfg, comm, rest);  % call superclass constructor
        end

        function initializeHardware(obj, cfg)
            % Initialize your specific hardware (sensors, actuators, DAQ cards, etc.)
            % This runs once when the node starts up.
            %
            % EXAMPLES:
            % - Setup DAQ channels and sampling rates
            % - Initialize sensor communication (serial, ethernet, etc.)
            % - Configure actuator controllers
            % - Load hardware-specific calibration files
            % - Test basic hardware connectivity
            %
            % INPUTS:
            %   cfg - Configuration struct with hardware parameters
            
            error('[ERROR] Hardware initialization not implemented! Add code to setup your sensors, actuators, and DAQ systems here.');
            
            % TEMPLATE - Replace with your hardware setup:
            % obj.myDAQ = daq("ni");  % Example: National Instruments DAQ
            % obj.mySensor = serialport("COM3", 9600);  % Example: Serial sensor
            % disp('[MyNode] Hardware initialized successfully');
        end

        function handleCalibrate(obj, cmd)
            % Perform sensor calibration routine to remove bias and establish baselines
            % This typically involves collecting reference measurements at known conditions.
            %
            % TYPICAL WORKFLOW:
            % 1. Collect sensor readings at reference conditions (e.g., zero load, still water)
            % 2. Average measurements to compute bias values
            % 3. Store bias corrections in obj.biasTable
            % 4. Save calibration data to file for future use
            %
            % INPUTS:
            %   cmd - Command struct with calibration parameters (e.g., duration, samples)
            
            disp('[MyNode] Running calibration with params:');
            disp(cmd.params);
            
            error('[ERROR] Sensor calibration not implemented! Add code to collect bias measurements and compute sensor corrections.');
            
            % TEMPLATE - Replace with your calibration routine:
            % if isfield(cmd.params, "finished") && cmd.params.finished
            %     % Finalize calibration
            %     obj.biasTable.sensor1 = mean(obj.calibrationData);
            %     save("calibrationGains.mat", "biasTable");
            %     obj.transition(State.IDLE);
            % else
            %     % Collect calibration point
            %     reading = readSensor(obj.mySensor);
            %     obj.calibrationData(end+1) = reading;
            % end
        end

        function handleTest(obj, cmd)
            % Test sensor or actuator functionality for diagnostics and validation
            % This runs live diagnostics without full experiment execution.
            %
            % SENSOR TESTING:
            % - Stream live sensor data for monitoring
            % - Check signal quality and noise levels
            % - Verify sensor response to stimuli
            %
            % ACTUATOR TESTING:
            % - Move actuators through range of motion
            % - Test control responsiveness
            % - Verify safety limits and emergency stops
            %
            % INPUTS:
            %   cmd - Command struct with test parameters (target: "sensor" or "actuator")
            
            disp('[MyNode] Handling test command for: ' + string(cmd.params.target));
            
            if strcmp(cmd.params.target, "sensor")
                error('[ERROR] Sensor testing not implemented! Add code to stream live sensor data for diagnostics.');
                % TEMPLATE:
                % while obj.state == State.TESTINGSENSOR
                %     data = readSensor(obj.mySensor);
                %     obj.comm.commPublish(obj.comm.getFullTopic("data"), jsonencode(data));
                %     pause(0.1);
                % end
            else
                error('[ERROR] Actuator testing not implemented! Add code to test actuator movement and control.');
                % TEMPLATE:
                % obj.myActuator.moveTo(cmd.params.testPosition);
                % obj.transition(State.IDLE);
            end
        end

        function handleRun(obj, cmd)
            % Execute the main experiment using validated configuration parameters
            % This is the core experiment execution - run your data collection or control sequence.
            %
            % TYPICAL WORKFLOW:
            % 1. Apply experiment configuration (already validated in configureHardware)
            % 2. Start data collection/actuator control
            % 3. Monitor experiment progress
            % 4. Store data in obj.experimentData
            % 5. Transition to POSTPROC when complete
            %
            % INPUTS:
            %   cmd - Command struct with experiment parameters
            
            disp('[MyNode] Handling custom RUN logic');
            
            error('[ERROR] Experiment execution not implemented! Add code to run your data collection or actuator control sequence.');
            
            % TEMPLATE - Replace with your experiment logic:
            % experimentParams = obj.experimentSpec.params;
            % startTime = tic;
            % while toc(startTime) < experimentParams.duration
            %     % Collect data
            %     data = struct('time', toc(startTime), 'value', readSensor(obj.mySensor));
            %     obj.experimentData(end+1) = data;
            %     
            %     % Control actuators
            %     controlSignal = computeControl(data.value, experimentParams);
            %     obj.myActuator.setOutput(controlSignal);
            %     
            %     pause(0.01);  % Control loop timing
            % end
            % obj.transition(State.POSTPROC);
        end

        function isValid = configureHardware(obj, params)
            % Validate experiment parameters against hardware capabilities and constraints
            % This ensures the requested experiment is safe and feasible before execution.
            %
            % VALIDATION CHECKS:
            % - Parameter ranges within hardware limits
            % - Required sensors/actuators are available
            % - Safety constraints are satisfied
            % - Experiment duration is reasonable
            %
            % INPUTS:
            %   params - Experiment parameter struct to validate
            %
            % OUTPUTS:
            %   isValid - true if configuration is valid and safe
            
            disp('[MyNode] Validating configuration parameters:');
            disp(params);
            
            error('[ERROR] Configuration validation not implemented! Add code to check if experiment parameters are safe and feasible.');
            
            % TEMPLATE - Replace with your validation logic:
            % isValid = true;
            % if isfield(params, "amplitude") && params.amplitude > obj.maxAmplitude
            %     warning('Amplitude exceeds hardware limits');
            %     isValid = false;
            % end
            % if isfield(params, "frequency") && params.frequency > obj.maxFrequency
            %     warning('Frequency exceeds hardware limits');
            %     isValid = false;
            % end
        end

        function stopHardware(obj)
            % Safely stop all hardware operations (called during state transitions)
            % This should immediately halt data collection and actuator movement.
            %
            % SAFETY CRITICAL:
            % - Stop all actuator motion
            % - Disable control outputs
            % - Stop data acquisition
            % - Return systems to safe idle state
            
            error('[ERROR] Hardware stop not implemented! Add code to safely halt all sensors and actuators.');
            
            % TEMPLATE - Replace with your stop sequence:
            % obj.myActuator.stop();
            % stop(obj.myDAQ);
            % disp('[MyNode] Hardware stopped safely');
        end

        function shutdownHardware(obj)
            % Complete hardware shutdown for node termination (called on exit)
            % This should fully disconnect and clean up all hardware resources.
            %
            % SHUTDOWN SEQUENCE:
            % - Close communication ports (serial, ethernet, etc.)
            % - Release DAQ resources
            % - Save any final data or logs
            % - Return actuators to safe park position
            
            error('[ERROR] Hardware shutdown not implemented! Add code to properly disconnect and clean up all hardware.');
            
            % TEMPLATE - Replace with your shutdown sequence:
            % delete(obj.mySensor);  % Close serial port
            % clear obj.myDAQ;       % Release DAQ
            % obj.myActuator.park(); % Move to safe position
            % disp('[MyNode] Hardware shutdown complete');
        end
    end
end
