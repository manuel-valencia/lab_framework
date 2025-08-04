classdef CommClient < handle
    % COMMCLIENT - Handles MQTT communication for distributed experiment nodes.
    % 
    % This class manages MQTT client setup, topic subscriptions, message publishing,
    % and message logging. It is designed to be used by all experiment nodes in
    % the automation framework and follows a standardized topic structure:
    %   <clientID>/cmd     - receive experiment commands (JSON)
    %   <clientID>/status  - publish node status and heartbeat
    %   <clientID>/data    - publish experimental data
    %   <clientID>/log     - publish structured logs and debug messages
    %
    % Usage:
    %   client = CommClient(config);
    %   client.connect();
    %   client.publish('<clientID>/log', 'Hello');
    %

    properties
        clientID            % Required: unique string identifying this node
        brokerAddress = 'localhost'; % Default broker address
        brokerPort = 1883;           % Default MQTT port
        mqttClient          % MATLAB MQTT client object

        subscriptions       % Cell array of topics to subscribe to
        publications        % Cell array of topics this node will publish to

        messageLog = {};    % Stores the last 1000 received messages
        lastHeartbeat = NaT;% Last heartbeat timestamp

        defaultTopics       % Struct containing default MQTT topics for this client:
                            %   .cmd    - Command topic (e.g., '<clientID>/cmd')
                            %   .status - Status/heartbeat topic (e.g., '<clientID>/status')
                            %   .data   - Data publication topic (e.g., '<clientID>/data')
                            %   .log    - Log/debug topic (e.g., '<clientID>/log')
        onMessageCallback   % Optional external callback for message dispatching

        heartbeatTimer      % MATLAB timer object for periodic heartbeat
        heartbeatInterval = 0;          % seconds between status updates (user-specified, 0 disables heartbeat)
        keepAliveDuration = seconds(60);% MQTT connection keepalive (broker stability)

        verbose = false     % Enables debug/verbose output if true
        tag                 % Precomputed logging tag, e.g., '[Comm:clientID]'
    end

    methods
        % --- Constructor ---
        function obj = CommClient(cfg)
            % Validate required fields
            if ~isfield(cfg, 'clientID')
                error('CommClient:MissingClientID', 'clientID is required');
            end
            obj.clientID = cfg.clientID;

            obj.tag = sprintf('[Comm:%s]', obj.clientID);

            % Optional overrides
            if isfield(cfg, 'brokerAddress')
                obj.brokerAddress = cfg.brokerAddress;
            end
            if isfield(cfg, 'brokerPort')
                obj.brokerPort = cfg.brokerPort;
            end
            if isfield(cfg, 'onMessageCallback')
                if isa(cfg.onMessageCallback, 'function_handle')
                    obj.onMessageCallback = cfg.onMessageCallback;
                else
                    error('CommClient:InvalidCallback', '%s onMessageCallback must be a function handle.', obj.tag);
                end
            end
            if isfield(cfg, 'verbose')
                obj.verbose = cfg.verbose;
            end

            % If custom subscriptions and publications are provided and non-empty, use them
            hasCustomSubs = isfield(cfg, 'subscriptions') && ~isempty(cfg.subscriptions);
            hasCustomPubs = isfield(cfg, 'publications') && ~isempty(cfg.publications);

            if hasCustomSubs
                if ~(iscellstr(cfg.subscriptions) || isstring(cfg.subscriptions))
                    error('CommClient:InvalidSubscriptions', '%s subscriptions must be a cell array or string array.', obj.tag);
                end
                obj.subscriptions = cfg.subscriptions;
            end
            if hasCustomPubs
                if ~(iscellstr(cfg.publications) || isstring(cfg.publications))
                    error('CommClient:InvalidPublications', '%s publications must be a cell array or string array.', obj.tag);
                end
                obj.publications = cfg.publications;
            end

            % Construct default topic layout
            cid = obj.clientID;
            obj.defaultTopics.cmd = [cid '/cmd'];
            obj.defaultTopics.status = [cid '/status'];
            obj.defaultTopics.data = [cid '/data'];
            obj.defaultTopics.log = [cid '/log'];

            % If not overridden, use defaults
            if ~hasCustomSubs
                obj.subscriptions = {obj.defaultTopics.cmd};
            end
            if ~hasCustomPubs
                obj.publications = {obj.defaultTopics.status, obj.defaultTopics.data, obj.defaultTopics.log};
            end

            if isfield(cfg, 'heartbeatInterval') && isnumeric(cfg.heartbeatInterval)
                obj.heartbeatInterval = cfg.heartbeatInterval;
            end
            if isfield(cfg, 'keepAliveDuration') && (isnumeric(cfg.keepAliveDuration) || isduration(cfg.keepAliveDuration))
                obj.keepAliveDuration = cfg.keepAliveDuration;
            end

            if obj.verbose
                fprintf('%s Initialized for clientID: %s\n', obj.tag, obj.clientID);
                fprintf('%s Broker: %s:%d\n', obj.tag, obj.brokerAddress, obj.brokerPort);
                fprintf('%s Subscribed topics: %s\n', obj.tag, strjoin(obj.subscriptions, ', '));
                fprintf('%s Publication topics: %s\n', obj.tag, strjoin(obj.publications, ', '));
            end
        end

        % --- Destructor ---
        function delete(obj)
            % DELETE - Destructor to ensure cleanup on object deletion
            obj.disconnect();
            if obj.verbose
                fprintf('%s Object deleted and resources released.\n', obj.tag);
            end
        end

        % --- Connection Management ---
        function connect(obj)
            % CONNECT - Establish MQTT client connection to the broker.
            % If verbose is enabled, this method will print each major step.

            try
                if obj.verbose
                    fprintf('%s connect() method reached.', obj.tag);
                    fprintf('%s Attempting to connect to MQTT broker at %s:%d\n', obj.tag, obj.brokerAddress, obj.brokerPort);
                end

                % Build broker URI
                uri = sprintf('tcp://%s', obj.brokerAddress);

                % Create the MQTT client with name-value pairs
                obj.mqttClient = mqttclient(uri, ClientID=obj.clientID, Port=obj.brokerPort, KeepAliveDuration=obj.keepAliveDuration);

                % Subscribe to initial topics
                for i = 1:length(obj.subscriptions)
                    topic = obj.subscriptions{i};
                    subscribe(obj.mqttClient, topic, Callback=@(topic, message) obj.handleMessage(topic, char(message)));
                    if obj.verbose
                        fprintf('%s Subscribed to topic: %s\n', obj.tag, topic);
                    end
                end

                % Start heartbeat timer if configured
                if obj.heartbeatInterval > 0
                    obj.heartbeatTimer = timer(...
                        'ExecutionMode', 'fixedRate', ...
                        'Period', obj.heartbeatInterval, ...
                        'TimerFcn', @(~,~) obj.sendHeartbeat());
                    start(obj.heartbeatTimer);
                    if obj.verbose
                        fprintf('%s Heartbeat timer started with interval %.1f sec\n', obj.tag, obj.heartbeatInterval);
                    end
                end

                if obj.verbose && obj.mqttClient.Connected
                    fprintf('%s Successfully connected and subscribed.\n', obj.tag);
                end

            catch ME
                if obj.verbose
                    fprintf('%s ERROR during connection: %s\n', obj.tag, ME.message);
                end
                rethrow(ME);
            end
        end

        function disconnect(obj)
            % DISCONNECT - Cleanly unsubscribes and disconnects MQTT client
            if ~isempty(obj.mqttClient) && obj.mqttClient.Connected
                try
                    if ~isempty(obj.heartbeatTimer) && isvalid(obj.heartbeatTimer)
                        stop(obj.heartbeatTimer);
                        obj.heartbeatTimer.TimerFcn = '';  % prevent race condition
                        delete(obj.heartbeatTimer);
                        obj.heartbeatTimer = [];
                    end

                    clear obj.mqttClient;

                    if obj.verbose
                        fprintf('%s Disconnected from broker and cleaned up.\n', obj.tag);
                    end
                catch ME
                    warning('CommClient:DisconnectWarning', '%s Error while disconnecting: %s', obj.tag, ME.message);
                end
            end
        end

        % --- Publish Helpers ---
        function commPublish(obj, topic, payload)
            % COMMPUBLISH - Publishes a message to the specified topic via MQTT.
            % Inputs:
            %   topic   - String: topic to publish to
            %   payload - String or JSON string to send

            if isempty(obj.mqttClient) || ~obj.mqttClient.Connected
                error('CommClient:NotConnected', '%s MQTT client is not connected. Call connect() first.', obj.tag);
            end

            try
                write(obj.mqttClient, topic, payload);
                if obj.verbose
                    fprintf('%s → "%s": %s [%s]\n', obj.tag, topic, payload, string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS')));
                end
            catch ME
                if obj.verbose
                    fprintf('%s ERROR during publish to topic "%s": %s\n', obj.tag, topic, ME.message);
                end
                rethrow(ME);
            end
        end

        function sendHeartbeat(obj)
            % SENDHEARTBEAT - Constructs and publishes heartbeat JSON to <clientID>/status

            if isempty(obj.mqttClient) || ~obj.mqttClient.Connected
                if obj.verbose
                    fprintf('%s Skipped heartbeat: MQTT client is not connected.\n', obj.tag);
                end
                return;
            end

            payloadStruct.clientID = obj.clientID;
            payloadStruct.timestamp = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
            payloadStruct.state = 'READY';

            jsonPayload = jsonencode(payloadStruct);
            topic = obj.getFullTopic('status');

            obj.commPublish(topic, jsonPayload);
            obj.lastHeartbeat = datetime('now');

            if obj.verbose
                fprintf('%s Heartbeat sent to %s\n', obj.tag, topic);
            end
        end

        % --- Subscribe Helpers ---
        function commSubscribe(obj, topic)
            % COMMSUBSCRIBE - Dynamically subscribes to a topic and updates internal list.
            if isempty(obj.mqttClient) || ~obj.mqttClient.Connected
                error('CommClient:NotConnected', '%s MQTT client is not connected.', obj.tag);
            end

            if any(strcmp(obj.subscriptions, topic))
                if obj.verbose
                    fprintf('%s Topic "%s" already subscribed.\n', obj.tag, topic);
                end
                return;
            end

            subscribe(obj.mqttClient, topic, Callback=@(topic, message) obj.handleMessage(topic, char(message)));
            obj.subscriptions{end+1} = topic;

            if obj.verbose
                fprintf('%s Successfully subscribed to topic: %s\n', obj.tag, topic);
            end
        end

        function commUnsubscribe(obj, topic)
            % COMMUNSUBSCRIBE - Unsubscribes from a topic and removes it from the list.
            if isempty(obj.mqttClient) || ~obj.mqttClient.Connected
                error('CommClient:NotConnected', '%s MQTT client is not connected.', obj.tag);
            end

            if ~any(strcmp(obj.subscriptions, topic))
                if obj.verbose
                    fprintf('%s Topic "%s" is not currently subscribed.\n', obj.tag, topic);
                end
                return;
            end

            unsubscribe(obj.mqttClient, Topic=topic);
            obj.subscriptions(strcmp(obj.subscriptions, topic)) = [];

            if obj.verbose
                fprintf('%s Successfully unsubscribed from topic: %s\n', obj.tag, topic);
            end
        end

        function handleMessage(obj, topic, msg)
            % HANDLEMESSAGE - Logs the incoming message and optionally routes it
            % via user-defined callback. Used as message handler for MQTT client.

            % Log message first
            obj.addToLog(topic, msg);

            % Print to console if verbose
            if obj.verbose
                fprintf('%s ← "%s": %s [%s]\n', obj.tag, topic, msg, string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS')));
            end

            % Forward to callback handler if defined
            if ~isempty(obj.onMessageCallback)
                try
                    obj.onMessageCallback(topic, msg);
                catch callbackErr
                    warning('CommClient:CallbackError', '%s Error in onMessageCallback: %s', obj.tag, callbackErr.message);
                end
            end
        end

        % --- Utilities ---
        function topic = getFullTopic(obj, suffix)
            % GETFULLTOPIC - Returns full MQTT topic with node-scoped prefix.
            % Example: getFullTopic('log') => 'clientID/log'

            if ~ischar(suffix) && ~isstring(suffix)
                error('CommClient:InvalidSuffix', '%s Suffix must be a string or character array.', obj.tag);
            end

            topic = sprintf('%s/%s', obj.clientID, char(suffix));

            % if obj.verbose
            %     fprintf('%s getFullTopic generated: %s\n', obj.tag, topic);
            % end
        end

        function addToLog(obj, topic, msg)
            % ADDTOLOG - Stores topic-message pair in messageLog with timestamp.
            % Keeps only the last 1000 entries (FIFO ring buffer logic).

            if nargin < 3 || isempty(topic) || isempty(msg)
                error('CommClient:InvalidLogEntry', '%s Topic and message are required to log an entry.', obj.tag);
            end

            entry.timestamp = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSSS');
            entry.topic = topic;
            entry.message = msg;

            obj.messageLog{end+1} = entry;

            if numel(obj.messageLog) > 1000
                obj.messageLog(1) = [];
            end

            % if obj.verbose
            %     fprintf('%s Logged message on topic "%s" at %s\n', obj.tag, topic, string(entry.timestamp));
            % end
        end
    end
end