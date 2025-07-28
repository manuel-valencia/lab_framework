classdef RestClient < handle
    % RESTCLIENT
    % This class provides a lightweight HTTP interface for experiment nodes
    % to POST data to and optionally GET data from a central REST server.
    %
    % Designed for use in conjunction with CommClient for MQTT messaging.
    % Intended primarily for use in `enterDone()` of ExperimentManager.
    %
    % Configuration:
    %   - brokerAddress: IP or hostname of REST server (e.g., 'localhost')
    %   - port: optional port (default 5000)
    %
    % Primary Usage:
    %   - POST experiment data using POST /data/<clientID>
    %   - GET data for aggregation (optional, used by master nodes)
    %
    % Dependencies:
    %   - MATLAB's Web Access Toolbox (for webwrite, webread)
    %   - JSON-formatted experiment data or CSV string

    properties
        clientID        % Node's unique identifier
        baseURL         % Base URL of REST server (e.g., 'http://localhost:5000')
        postEndpoint    % Full URL for POST, derived from clientID
        verbose = false % Optional verbosity
        tag             % Optional log prefix (e.g., '[REST:waveGenNode]')
        timeout = 15    % Default timeout in seconds
    end

    methods (Access = public)

        function obj = RestClient(cfg)
            % Constructor: Takes same config as CommClient / ExperimentManager
            % Fields:
            %   cfg.clientID        : string (required)
            %   cfg.brokerAddress   : IP or hostname (optional, default 'localhost')
            %   cfg.restPort        : integer (optional, default 5000)

            % Validate
            if ~isfield(cfg, 'clientID')
                error('RestClient requires clientID.');
            end

            % Parse host and port
            addr = "localhost";
            port = 5000;

            if isfield(cfg, "brokerAddress"), addr = cfg.brokerAddress; end
            if isfield(cfg, "restPort"), port = cfg.restPort; end

            obj.clientID = cfg.clientID;
            obj.baseURL = sprintf("http://%s:%d", addr, port);
            obj.postEndpoint = sprintf("%s/data/%s", obj.baseURL, obj.clientID);
            obj.tag = sprintf("[REST:%s]", obj.clientID);

            if isfield(cfg, "verbose"), obj.verbose = cfg.verbose; end
            if isfield(cfg, "timeout"), obj.timeout = cfg.timeout; end

            if obj.verbose
                fprintf("%s Initialized with endpoint: %s\n", obj.tag, obj.postEndpoint);
            end
        end

        function response = sendData(obj, data, varargin)
            % sendData - Sends experiment data to REST server.
            % Arguments:
            %   data: either a table (CSV) or struct array (JSON)
            % Optional name-value:
            %   'experimentName' - string for filename prefix
            %   'format' - 'csv' or 'jsonl' (default determined automatically)

            % Detect format
            format = "jsonl";
            if istable(data)
                format = "csv";
            end

            % Handle optional parameters
            p = inputParser;
            addParameter(p, 'experimentName', []);
            addParameter(p, 'format', format);
            parse(p, varargin{:});
            experimentName = p.Results.experimentName;
            format = p.Results.format;

            % --- Construct target URL ---
            url = obj.postEndpoint;
            if ~isempty(experimentName)
                url = url + "?experimentName=" + experimentName;
            end

            try
                if format == "csv"
                    payload = obj.convertToCSV(data);
                    opts = weboptions("MediaType", "text/csv", "Timeout", obj.timeout);
                    response = webwrite(url, payload, opts);
                else
                    payloadStruct = struct("data", data);
                    if ~isempty(experimentName)
                        payloadStruct.experimentName = experimentName;
                    end
                    opts = weboptions("MediaType", "application/json", "Timeout", obj.timeout);
                    response = webwrite(url, payloadStruct, opts);
                end
                if obj.verbose
                    fprintf("%s POST success: %s\n", obj.tag, response.saved);
                end
            catch ME
                warning("%s POST failed: %s", obj.tag, ME.message);
                response = struct("status", "error", "message", ME.message);
            end
        end

        function result = fetchData(obj, varargin)
            % fetchData - Retrieves experiment data from REST server
            % Optional arguments:
            %   'clientID' - node whose data to fetch (default: this RestClient's clientID)
            %   'experimentName' - name to fetch
            %   'format' - 'jsonl' or 'csv' (default 'jsonl')
            %   'latest' - true/false

            format = "jsonl";
            experimentName = "";
            latest = false;
            clientID = obj.clientID; %#ok<*PROPLC>

            p = inputParser;
            addParameter(p, 'clientID', clientID);
            addParameter(p, 'experimentName', experimentName);
            addParameter(p, 'format', format);
            addParameter(p, 'latest', latest);
            parse(p, varargin{:});

            clientID = p.Results.clientID;
            query = "";
            if p.Results.latest
                query = "?latest=true";
            elseif ~isempty(p.Results.experimentName)
                query = "?experimentName=" + p.Results.experimentName + "&format=" + p.Results.format;
            end

            url = sprintf("%s/data/%s%s", obj.baseURL, clientID, query);

            try
                result = webread(url);
                if isfield(result, "csv")
                    result = result.csv; % Return raw CSV string directly
                elseif isfield(result, "data")
                    result = result.data; % For JSON/JSONL
                end
                if obj.verbose
                    fprintf("%s GET success: format=%s\n", obj.tag, p.Results.format);
                end
            catch ME
                warning("%s GET failed: %s", obj.tag, ME.message);
                result = struct("status", "error", "message", ME.message);
            end
        end

        function status = checkHealth(obj)
            % checkHealth - Checks if the REST server is online by calling /health
            url = obj.baseURL + "/health";
            try
                resp = webread(url, weboptions("Timeout", obj.timeout));
                if isfield(resp, "status") && strcmpi(resp.status, "online")
                    status = true;
                else
                    status = false;
                end
            catch
                status = false;
            end
        end

    end


    methods (Static, Access = public)

        function csvStr = convertToCSV(tbl)
            % Converts MATLAB table to CSV string for POST
            if ~istable(tbl), error("Input must be a table."); end
            tempName = tempname + ".csv";
            writetable(tbl, tempName);
            fid = fopen(tempName, 'r');
            csvStr = fread(fid, '*char')';
            fclose(fid);
            delete(tempName);
        end

    end

end

