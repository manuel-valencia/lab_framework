function labdata2mat(inputFile, outputFile)
% LABDATA2MAT  Convert a lab data CSV or JSONL file to a MATLAB .mat file.
%
%   labdata2mat(inputFile)
%       Reads inputFile and saves a .mat file to the same directory with the
%       same base name (extension replaced with .mat).
%
%   labdata2mat(inputFile, outputFile)
%       Saves to outputFile instead.
%
% Supported formats:
%   .csv   — comma-separated values with a header row
%   .jsonl — newline-delimited JSON (one JSON object per line)
%
% The data is saved as a MATLAB table variable named 'data'.
%
% Examples:
%   % Convert the most recent carriageNode run:
%   labdata2mat('carriageNodeData/carriageNode_data_force_run_001.csv')
%
%   % Convert a JSONL file to a specific output path:
%   labdata2mat('carriageNodeData/carriageNode_data_force_run_001.jsonl', ...
%               'results/force_run_001.mat')
%
% After loading the saved .mat file the table is available as:
%   d = load('force_run_001.mat');
%   d.data        % MATLAB table with named columns
%   d.data.Fx     % column vector for Fx, etc.

    if nargin < 1 || isempty(inputFile)
        error('labdata2mat: inputFile argument is required.');
    end

    % Default output path: same directory and base name, .mat extension
    if nargin < 2 || isempty(outputFile)
        [d, n, ~] = fileparts(inputFile);
        if isempty(d)
            outputFile = [n '.mat'];
        else
            outputFile = fullfile(d, [n '.mat']);
        end
    end

    if ~isfile(inputFile)
        error('labdata2mat: file not found: %s', inputFile);
    end

    [~, ~, ext] = fileparts(inputFile);
    ext = lower(ext);

    switch ext
        case '.csv'
            data = readtable(inputFile, 'TextType', 'string');

        case '.jsonl'
            fid   = fopen(inputFile, 'r', 'n', 'UTF-8');
            if fid < 0
                error('labdata2mat: cannot open file: %s', inputFile);
            end
            rows = {};
            while ~feof(fid)
                line = strtrim(fgetl(fid));
                if ischar(line) && ~isempty(line)
                    rows{end+1} = jsondecode(line); %#ok<AGROW>
                end
            end
            fclose(fid);
            if isempty(rows)
                error('labdata2mat: no data found in %s', inputFile);
            end
            data = struct2table([rows{:}]);

        otherwise
            error('labdata2mat: unsupported extension ''%s''. Use .csv or .jsonl.', ext);
    end

    % Ensure output directory exists
    [outDir, ~, ~] = fileparts(outputFile);
    if ~isempty(outDir) && ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    save(outputFile, 'data');
    fprintf('labdata2mat: saved %d rows x %d columns to %s\n', ...
        height(data), width(data), outputFile);
end
