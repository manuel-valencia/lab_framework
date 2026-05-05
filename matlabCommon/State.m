% State - FSM state enumeration for experiment nodes.
%
% Defines the 11 states of the ExperimentManager state machine.
% IDLE and ERROR are implicit wildcard destinations — any state may
% transition to them regardless of the permitted-transition table.
%
% Permitted transitions (in addition to -> IDLE and -> ERROR from any state):
%
%   BOOT              -> IDLE
%   IDLE              -> CALIBRATING | TESTINGSENSOR | CONFIGUREVALIDATE
%   CALIBRATING       -> CALIBRATING  (multi-step calibration loop)
%   TESTINGSENSOR     -> IDLE
%   CONFIGUREVALIDATE -> CONFIGUREPENDING | IDLE
%   CONFIGUREPENDING  -> TESTINGACTUATOR | RUNNING
%   TESTINGACTUATOR   -> IDLE
%   RUNNING           -> POSTPROC
%   POSTPROC          -> RUNNING (next sub-experiment) | DONE
%   DONE              -> IDLE
%   ERROR             -> IDLE
classdef (Enumeration) State < int32
    enumeration
        BOOT              (0)   % Startup state before hardware initialization
        IDLE              (1)   % Initialized, waiting for command; entry clears abortRequested
        CALIBRATING       (2)   % Executing handleCalibrate(); may loop until calibration completes
        TESTINGSENSOR     (3)   % Executing handleTest() for live sensor diagnostics; stopHardware() on exit
        CONFIGUREVALIDATE (4)   % Validating all sub-experiment parameters (fail-fast before any setup)
        CONFIGUREPENDING  (5)   % Parameters confirmed, awaiting RUN command
        TESTINGACTUATOR   (6)   % Executing handleTest() for actuator validation before a run
        RUNNING           (7)   % Executing handleRun(); must transition to POSTPROC on success
        POSTPROC          (8)   % Saving data locally and to REST; loops to RUNNING for each sub-experiment
        DONE              (9)   % All experiments complete; sends data to REST then returns to IDLE
        ERROR             (10)  % Fault state; entry calls stopHardware(); reachable from any state
    end
end