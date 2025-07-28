classdef MyNodeManager < ExperimentManager
    %MYNODEMANAGER  Node-specific subclass of ExperimentManager
    %
    % This class implements command-specific behaviors (e.g., Run, Calibrate)
    % that are unique to this node's hardware or test protocol.

    methods
        function obj = MyNodeManager(cfg, comm)
            obj@ExperimentManager(cfg, comm);  % call superclass constructor
        end

        function handleRun(obj, cmd)
            % Example override for 'Run' command
            disp('[MyNode] Handling custom RUN logic');
            % Example:
            % obj.actuatorClass.sendProfile(cmd.params);
            % obj.transition(obj.State.RUNNING);
        end

        function handleCalibrate(obj, cmd)
            % Custom calibration routine
            disp('[MyNode] Running calibration with params:');
            disp(cmd.params);
            % Example:
            % obj.probeArray.collectBias(cmd.params);
            % Save to .mat file
            % obj.biasTable = computeBiasFromData(...);
            % save("calibrationGains.mat", "biasTable");
        end
    end
end
