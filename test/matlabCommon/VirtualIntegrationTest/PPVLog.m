% This code is to parse through the VirtualIntegrationTest.Log file and
% extract figures for state transition analysis as well as get
% communication metrics that are printed out in the command window

clear; clc;

% Load and parse log file
logLines = readlines('VirtualIntegrationTest.log');

% === FSM STATE TRANSITION ANALYSIS ===
fsmLines = logLines(contains(logLines, '[FSM:') & contains(logLines, '[STATE]'));
nodeTokens = regexp(fsmLines, '\[FSM:(.*?)\]\s+\[STATE\]\s+(\w+)\s+→\s+(\w+)', 'tokens');

% Create FSM transition structures
fsmTransitions = cellfun(@(x) struct('node', x{1}{1}, 'from', x{1}{2}, 'to', x{1}{3}), ...
    nodeTokens, 'UniformOutput', false);
nodes = unique(cellfun(@(x) x.node, fsmTransitions, 'UniformOutput', false));

% Plot state transition graphs
for i = 1:length(nodes)
    thisNode = nodes{i};
    nodeTrans = fsmTransitions(strcmp(thisNode, cellfun(@(x) x.node, fsmTransitions, 'UniformOutput', false)));
    
    fromStates = cellfun(@(x) x.from, nodeTrans, 'UniformOutput', false);
    toStates = cellfun(@(x) x.to, nodeTrans, 'UniformOutput', false);
    
    G = digraph(fromStates, toStates);
    figure('Name', thisNode, 'NumberTitle', 'off');
    plot(G, 'Layout', 'layered', 'NodeLabel', G.Nodes.Name, 'EdgeColor', 'k', ...
        'ArrowSize', 10, 'LineWidth', 1.5);
    title(sprintf('State Transitions for %s', thisNode), 'Interpreter', 'none');
end

% === COMMUNICATION METRICS ANALYSIS ===
% Parse MQTT communication lines
commLines = logLines(contains(logLines, '[Comm:') & (contains(logLines, '→') | contains(logLines, '←')));
entries = arrayfun(@parseMQTTLogLine, commLines, 'UniformOutput', false);
entries = [entries{~cellfun(@isempty, entries)}];

if isempty(entries)
    fprintf('No communication entries found.\n');
    return;
end

% Categorize entries
commands = entries(contains({entries.topic}, '/cmd'));
responses = entries(contains({entries.topic}, '/status'));

% Add message type classifications
for i = 1:length(commands)
    commands(i).type = sprintf('command_%s', commands(i).direction);
end
for i = 1:length(responses)
    responses(i).type = sprintf('status_%s', responses(i).direction);
end

% Calculate latencies
commandLatencies = calculateLatencies(commands, 'command_send', 'command_receive');
responseLatencies = calculateLatencies(responses, 'status_send', 'status_receive');
roundTripLatencies = calculateRoundTripLatencies(commands, responses);

% Display results
displayResults(commandLatencies, responseLatencies, roundTripLatencies, commands, responses);


function entry = parseMQTTLogLine(line)
    % Parse MQTT communication log line: [Comm:nodeID] → "topic": message [timestamp]
    entry = [];
    
    % Parse communication pattern
    commPattern = '\[Comm:(\w+)\]\s*([→←])\s*"([^"]+)":\s*(.+?)\s*\[([^\]]+)\]';
    tokens = regexp(line, commPattern, 'tokens', 'once');
    if isempty(tokens), return; end
    
    % Extract components
    entry.nodeID = tokens{1};
    if strcmp(tokens{2}, '→')
        entry.direction = 'send';
    elseif strcmp(tokens{2}, '←')
        entry.direction = 'receive';
    else
        return;
    end
    entry.topic = tokens{3};
    entry.message = tokens{4};
    
    % Parse timestamps
    entry.processingTimestamp = parseTimestamp(tokens{5});
    entry.messageTimestamp = parseEmbeddedTimestamp(entry.message);
    entry.logTimestamp = parseLogTimestamp(line);
    entry.rawLine = line;
end

function latencies = calculateLatencies(entries, sendType, receiveType)
    % Calculate latencies between matching send/receive pairs
    latencies = [];
    sends = entries(strcmp({entries.type}, sendType));
    receives = entries(strcmp({entries.type}, receiveType));
    
    for i = 1:length(sends)
        send = sends(i);
        if isnat(send.messageTimestamp), continue; end
        
        % Match by both timestamp AND message content for accuracy
        timestampMatches = receives([receives.messageTimestamp] == send.messageTimestamp);
        if isempty(timestampMatches), continue; end
        
        % Further filter by message content to ensure we're matching the same command
        contentMatches = timestampMatches([]); % Initialize empty struct array with same structure
        for j = 1:length(timestampMatches)
            recv = timestampMatches(j);
            % Compare message content (should be identical for send/receive pairs)
            if strcmp(send.message, recv.message)
                if isempty(contentMatches)
                    contentMatches = recv;
                else
                    contentMatches(end+1) = recv; %#ok<AGROW>
                end
            end
        end
        
        if isempty(contentMatches), continue; end
        
        receive = contentMatches(1);  % Take first content match
        if ~isnat(send.processingTimestamp) && ~isnat(receive.processingTimestamp)
            latency = milliseconds(receive.processingTimestamp - send.processingTimestamp);
        else
            latency = milliseconds(receive.logTimestamp - send.logTimestamp);
        end
        latencies(end+1) = latency;
    end
end

function latencies = calculateRoundTripLatencies(commands, responses)
    % Calculate round-trip latencies (command send → related status receive)
    latencies = [];
    commandSends = commands(strcmp({commands.type}, 'command_send'));
    statusReceives = responses(strcmp({responses.type}, 'status_receive'));
    
    for i = 1:length(commandSends)
        send = commandSends(i);
        if ~isnat(send.processingTimestamp)
            sendTime = send.processingTimestamp;
        else
            sendTime = send.logTimestamp;
        end
        
        % Extract target node from command topic (e.g., "probeNode/cmd" -> "probeNode")
        cmdParts = split(send.topic, '/');
        if length(cmdParts) < 2, continue; end
        targetNode = cmdParts{1};
        
        % Find status responses from the same target node after command send
        sameNodeResponses = statusReceives(contains({statusReceives.topic}, targetNode));
        
        % Filter to responses that occur after the command
        laterIndices = [];
        for j = 1:length(sameNodeResponses)
            respTime = sameNodeResponses(j).processingTimestamp;
            if isnat(respTime)
                respTime = sameNodeResponses(j).logTimestamp;
            end
            
            if respTime > sendTime
                laterIndices(end+1) = j; %#ok<AGROW>
            end
        end
        
        if ~isempty(laterIndices)
            % Take the first status response from target node after command
            receive = sameNodeResponses(laterIndices(1));
            if ~isnat(receive.processingTimestamp)
                receiveTime = receive.processingTimestamp;
            else
                receiveTime = receive.logTimestamp;
            end
            
            latency = milliseconds(receiveTime - sendTime);
            % Add sanity check - round-trip shouldn't exceed reasonable bounds (e.g., 10 seconds)
            if latency < 10000  % Less than 10 seconds
                latencies(end+1) = latency;
            end
        end
    end
end

function displayResults(commandLatencies, responseLatencies, roundTripLatencies, commands, responses)
    % Display communication metrics summary
    fprintf('\n=== Communication Metrics Summary ===\n');
    
    printLatencyStats('Command Latencies (send→receive)', commandLatencies);
    printLatencyStats('Response Latencies (status send→receive)', responseLatencies);
    printLatencyStats('Round-trip Latencies (command→status response)', roundTripLatencies);
    
    fprintf('\n=== Debug Information ===\n');
    fprintf('Found %d command entries, %d response entries\n', length(commands), length(responses));
    
    % More detailed breakdown
    commandSends = commands(strcmp({commands.type}, 'command_send'));
    commandReceives = commands(strcmp({commands.type}, 'command_receive'));
    statusSends = responses(strcmp({responses.type}, 'status_send'));
    statusReceives = responses(strcmp({responses.type}, 'status_receive'));
    
    fprintf('  Command sends: %d, receives: %d\n', length(commandSends), length(commandReceives));
    fprintf('  Status sends: %d, receives: %d\n', length(statusSends), length(statusReceives));
    
    if ~isempty(commands)
        fprintf('\nSample command entries:\n');
        printSampleEntries(commands, 3);
    end
    
    if ~isempty(responses)
        fprintf('\nSample response entries:\n');
        printSampleEntries(responses, 3);
    end
end

function printLatencyStats(title, latencies)
    % Print statistics for a latency array
    fprintf('\n%s:\n', title);
    if isempty(latencies)
        fprintf('  No latencies found\n');
        return;
    end
    
    fprintf('  Count: %d, Mean: %.2f ms, Std: %.2f ms\n', ...
            length(latencies), mean(latencies), std(latencies));
    fprintf('  Min: %.2f ms, Max: %.2f ms\n', min(latencies), max(latencies));
    fprintf('  Values: [%s] ms\n', join(string(latencies), ', '));
end

function printSampleEntries(entries, count)
    % Print sample entries for debugging
    for i = 1:min(count, length(entries))
        entry = entries(i);
        fprintf('  %s: %s %s -> %s\n', entry.type, entry.nodeID, entry.direction, entry.topic);
        
        times = [formatTime(entry.logTimestamp), formatTime(entry.messageTimestamp), ...
                 formatTime(entry.processingTimestamp)];
        fprintf('    logTime: %s, msgTime: %s, procTime: %s\n', times(1), times(2), times(3));
    end
end

function ts = parseTimestamp(str)
    % Parse timestamp string with fallback
    ts = NaT;
    if isempty(str), return; end
    try
        ts = datetime(str, 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSSS');
    catch
        try
            ts = datetime(str, 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSS');
        catch
            % Fallback for different precision - return NaT
        end
    end
end

function ts = parseEmbeddedTimestamp(message)
    % Parse timestamp from JSON message
    ts = NaT;
    try
        msgStruct = jsondecode(message);
        if isstruct(msgStruct) && isfield(msgStruct, 'timestamp')
            try
                ts = datetime(msgStruct.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSSS');
            catch
                ts = datetime(msgStruct.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSS');
            end
        end
    catch
        % Not JSON or no timestamp field
    end
end

function ts = parseLogTimestamp(line)
    % Parse timestamp from start of log line
    pattern = '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)';
    match = regexp(line, pattern, 'tokens', 'once');
    
    if ~isempty(match)
        try
            ts = datetime(match{1}, 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSSS');
        catch
            try
                ts = datetime(match{1}, 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSS');
            catch
                ts = datetime('now');
            end
        end
    else
        ts = datetime('now');
    end
end

function str = formatTime(ts)
    % Format timestamp for display
    if isnat(ts)
        str = "NaT";
    else
        str = string(datetime(ts, 'Format', 'yyyy-MM-dd HH:mm:ss.SSS'));
    end
end