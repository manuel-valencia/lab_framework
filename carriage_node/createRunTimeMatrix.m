% createRunTimeMatrix.m
%
% Run this script ONCE on the carriage computer to generate the
% carriageNodeRunTimeMatrix.mat file required by CarriageNodeManager.
%
% ATI FT40786 Gamma IP68 (15 lb / 25 lb-in variant) calibration matrix
% for the Parsons / MIT tow tank force sensor.
%
% Source: ATI document, sensor serial FT40786. This is the hardware-tied
% runtime matrix — it decouples 6 strain gauge voltages into Fx, Fy, Fz,
% Mx, My, Mz. Do NOT modify these values.
%
% Output units: lb and lb-in (standard ATI convention for this sensor).
%
% Usage:
%   cd to repo root, then:
%   matlab -batch "run('carriage_node/createRunTimeMatrix.m')"
%   OR open in MATLAB and press Run.

RunTimeMatrix = [-0.00751  -0.01075   0.01007  -1.88444  -0.01816   1.91358; ...
                  0.01636   2.27292   0.00229  -1.09130   0.01014  -1.09647; ...
                  3.33501   0.04129   3.40147  -0.00003   3.44372  -0.01632; ...
                  0.03934   2.05079  -3.85455  -0.96095   3.90735  -1.02076; ...
                  4.35119   0.02231  -2.23195   1.72541  -2.25515  -1.70294; ...
                 -0.02308  -2.43778   0.01657  -2.37319   0.01761  -2.40509];

outFile = fullfile(fileparts(mfilename('fullpath')), 'carriageNodeRunTimeMatrix.mat');
save(outFile, 'RunTimeMatrix');
fprintf('RunTimeMatrix saved to: %s\n', outFile);
fprintf('Size: %dx%d\n', size(RunTimeMatrix));
