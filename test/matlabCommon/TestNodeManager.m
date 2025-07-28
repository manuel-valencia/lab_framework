classdef TestNodeManager < ExperimentManager
    %TestNodeManager Mock implementation of ExperimentManager for testing FSM
    %
    %   No hardware logic, just print statements to verify state flow.

    methods
        function initializeHardware(obj, cfg)
            disp("[INIT] Mock hardware initialized.");
            disp("[DEBUG] biasTable:");
            disp(obj.biasTable);
        end

        function handleCalibrate(obj, cmd)
            %HANDLECALIBRATE Simulates calibration behavior by capturing reference points
            % and computing a simple bias offset added to each sensor.
        
            disp("[ACTION] handleCalibrate() called with:");
            disp(cmd);
        
            persistent heightLog
            if isempty(heightLog)
                heightLog = [];
            end
        
            % Handle multi-step calibration
            if isfield(cmd.params, "finished") && cmd.params.finished == true
                if isempty(heightLog)
                    warning("[CALIBRATION] No data to finalize calibration.");
                    % Still clear state and return to IDLE without applying any changes
                    obj.transition(State.IDLE);
                    heightLog = [];  % ensure persistent variable is reset
                    return;
                end
        
                avgHeight = mean(heightLog);
                fprintf("[CALIBRATION] Applying bias offset of %.3f\n", avgHeight);
        
                % Update biasTable
                sensorKeys = fieldnames(obj.biasTable);
                for i = 1:numel(sensorKeys)
                    key = sensorKeys{i};
                    obj.biasTable.(key) = obj.biasTable.(key) + avgHeight;
                end
        
                % Save gains
                biasTable = obj.biasTable; %#ok<NASGU>
                save("calibrationGains.mat", "biasTable");
                disp("[CALIBRATION] Gains saved to calibrationGains.mat");
        
                % Clear persistent log
                heightLog = [];
                obj.transition(State.IDLE);
                return;
            end
        
            % Handle a step
            if isfield(cmd.params, "height")
                h = cmd.params.height;
                heightLog(end+1) = h;
                fprintf("[CALIBRATION] Captured height = %.3f\n", h);
            else
                error("[CALIBRATION] Invalid parameters: expected 'height' or 'finished' in cmd.params.");
            end
        end

        function handleTest(obj, cmd)
            disp("[ACTION] handleTest() called with:");
            disp(cmd);
        end

        function handleRun(obj, cmd)
            disp("[ACTION] handleRun() called with:");
            disp(cmd);
            
            % Simulate experiment finishing → transition to POSTPROC
            obj.transition(State.POSTPROC);
        end

        function isValid = configureHardware(obj, params)
            disp("[ACTION] configureHardware() validating:");
            disp(params);
        
            hasAmp = isfield(params, "amplitude") && isnumeric(params.amplitude) && params.amplitude > 0;
            hasWave = isfield(params, "waveType") && (ischar(params.waveType) || isstring(params.waveType));
        
            isValid = hasAmp && hasWave;
        end


        function stopHardware(obj)
            disp("[STOP] Hardware Stopped safely / IDLE.");
        end

        function shutdownHardware(obj)
            disp("[Shutdown] Hardware shutdown safetly.");
        end
    end
end
