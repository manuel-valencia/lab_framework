%% CommClientTestScript.m
% Validates CommClient functionality across construction, connection,
% publication, subscription management, logging, and heartbeats.

clear; clc;

addpath('C:\Users\Manny\Desktop\lab_framework\matlabCommon');

% Test 0: Full config with optional overrides
cfgFull.clientID = 'fullNode';
cfgFull.brokerAddress = 'test.mqtt.local';
cfgFull.brokerPort = 1885;
cfgFull.verbose = true;
cfgFull.subscriptions = {'fullNode/cmd', 'fullNode/debug'};
cfgFull.publications = {'fullNode/status', 'fullNode/data', 'fullNode/log', 'fullNode/metrics'};

fprintf("\n[TEST] Creating CommClient with full config override...\n");
fullClient = CommClient(cfgFull);
assert(strcmp(fullClient.clientID, 'fullNode'));
assert(isequal(fullClient.brokerAddress, 'test.mqtt.local'));
assert(fullClient.brokerPort == 1885);
assert(isequal(fullClient.subscriptions, cfgFull.subscriptions));
assert(isequal(fullClient.publications, cfgFull.publications));

% Test 1: Constructor minimum
cfg.clientID = 'testNode';
cfg.verbose = true;

fprintf("\n[TEST] Creating CommClient with basic config...\n");
client = CommClient(cfg);

assert(strcmp(client.clientID, 'testNode'));
assert(iscell(client.subscriptions) && ~isempty(client.subscriptions));
assert(iscell(client.publications) && ~isempty(client.publications));

fprintf("[PASS] Constructor tests passed.\n");

% Test 2: Connect to local broker
cfg2.clientID = 'connectTestNode';
cfg2.verbose = true;

fprintf("\n[TEST] Creating CommClient and connecting to local MQTT broker...\n");
client2 = CommClient(cfg2);
try
    client2.connect();
    assert(~isempty(client2.mqttClient) && client2.mqttClient.Connected);
    fprintf("[PASS] Connect test passed.\n");
catch ME
    fprintf("[FAIL] Connect test failed: %s\n", ME.message);
end

% Test 3: Publish test
try
    testMessage = sprintf('Test publish at %s', string(datetime('now','Format','HH:mm:ss')));
    client2.commPublish('connectTestNode/log', testMessage);
    fprintf("[PASS] Publish test passed.\n");
catch ME
    fprintf("[FAIL] Publish test failed: %s\n", ME.message);
end

% Test 4: Subscribe and Unsubscribe
newTopic = 'connectTestNode/debug';

fprintf("\n[TEST] Subscribing to new topic: %s\n", newTopic);
try
    client2.commSubscribe(newTopic);
    assert(any(strcmp(client2.subscriptions, newTopic)));
    fprintf("[PASS] commSubscribe added topic successfully.\n");
catch ME
    fprintf("[FAIL] commSubscribe failed: %s\n", ME.message);
end

fprintf("[TEST] Unsubscribing from topic: %s\n", newTopic);
try
    client2.commUnsubscribe(newTopic);
    assert(~any(strcmp(client2.subscriptions, newTopic)));
    fprintf("[PASS] commUnsubscribe removed topic successfully.\n");
catch ME
    fprintf("[FAIL] commUnsubscribe failed: %s\n", ME.message);
end

% Test 5: getFullTopic
fprintf("\n[TEST] getFullTopic with suffix 'log'\n");
try
    expectedTopic = 'connectTestNode/log';
    actualTopic = client2.getFullTopic('log');
    assert(strcmp(actualTopic, expectedTopic));
    fprintf("[PASS] getFullTopic returned correct topic: %s\n", actualTopic);
catch ME
    fprintf("[FAIL] getFullTopic test failed: %s\n", ME.message);
end

% Test 6: addToLog ring buffer
fprintf("\n[TEST] addToLog ring buffer behavior\n");
try
    for i = 1:105
        topic = sprintf('topic%d', i);
        msg = sprintf('Message %d', i);
        client2.addToLog(topic, msg);
    end
    assert(length(client2.messageLog) == 100);
    oldest = client2.messageLog{1};
    assert(strcmp(oldest.message, 'Message 6'));
    fprintf("[PASS] addToLog capped messageLog to 100 entries correctly.\n");
catch ME
    fprintf("[FAIL] addToLog test failed: %s\n", ME.message);
end

% Test 7: handleMessage
fprintf("\n[TEST] handleMessage behavior\n");
try
    testTopic = 'connectTestNode/cmd';
    testMessage = 'Unit test message';

    assignin('base', 'wasTriggered', false);
    client2.onMessageCallback = @(topic, msg) assignin('base', 'wasTriggered', true);

    client2.handleMessage(testTopic, testMessage);

    latest = client2.messageLog{end};
    assert(strcmp(latest.topic, testTopic));
    assert(strcmp(latest.message, testMessage));
    assert(evalin('base', 'wasTriggered') == true);

    fprintf("[PASS] handleMessage routed and logged correctly.\n");
catch ME
    fprintf("[FAIL] handleMessage test failed: %s\n", ME.message);
end

% Test 8: sendHeartbeat and Heartbeat timer
fprintf("\n[TEST] Heartbeat timer functionality\n");
cfg8.clientID = 'heartbeatTimerNode';
cfg8.verbose = false;
cfg8.heartbeatInterval = 2;

client8 = CommClient(cfg8);
client8.connect();

pause(5);  % wait for timer to fire at least twice
hb = client8.lastHeartbeat;

try
    assert(~isnat(hb), '[FAIL] Heartbeat timer did not trigger sendHeartbeat.');
    fprintf("[PASS] Heartbeat timer triggered sendHeartbeat: %s\n", string(hb));
catch ME
    fprintf("[FAIL] Heartbeat timer test failed: %s\n", ME.message);
end

client8.disconnect();  % cleanup

% Test 9: Destructor auto-disconnect check (indirect)
fprintf("\n[TEST] Destructor calls disconnect()\n");
try
    cfg9.clientID = 'deleteTestNode';
    cfg9.verbose = true;
    cfg9.heartbeatInterval = 1;

    client9 = CommClient(cfg9);
    client9.connect();

    pause(2);
    delete(client9);  % should trigger disconnect and cleanup

    fprintf("[PASS] delete() triggered disconnect() successfully.\n");
catch ME
    fprintf("[FAIL] Destructor test failed: %s\n", ME.message);
end

% Test 10: Invalid constructor field test
fprintf("\n[TEST] Constructor error handling for bad callback\n");
try
    cfg10.clientID = 'badNode';
    cfg10.onMessageCallback = 42;  % Invalid: not a function handle

    badClient = CommClient(cfg10);
    fprintf("[FAIL] Constructor accepted invalid callback.\n");
catch
    fprintf("[PASS] Constructor correctly rejected invalid callback.\n");
end

% Test 11: Inter-node Messaging between Master and Actuator
fprintf("\n[TEST] Inter-node messaging between Master and Actuator nodes\n");

% Callback trackers
masterReceivedFlag = false;
actuatorReceivedFlag = false;

% Callback functions to set flags when messages are received
function onMasterMessage(topic, msg)
    fprintf('[Test Callback] Master received message on %s: %s\n', topic, msg);
    assignin('base', 'masterReceivedFlag', true);
end

function onActuatorMessage(topic, msg)
    fprintf('[Test Callback] Actuator received message on %s: %s\n', topic, msg);
    assignin('base', 'actuatorReceivedFlag', true);
end

% Configuration setup
masterCfg.clientID = 'masterNode';
masterCfg.verbose = true;
masterCfg.subscriptions = {'actuatorNode/status'};
masterCfg.publications = {'masterNode/cmd'};
masterCfg.onMessageCallback = @onMasterMessage;

actuatorCfg.clientID = 'actuatorNode';
actuatorCfg.verbose = true;
actuatorCfg.subscriptions = {'masterNode/cmd'};
actuatorCfg.publications = {'actuatorNode/status'};
actuatorCfg.onMessageCallback = @onActuatorMessage;

% Create and connect clients
master = CommClient(masterCfg);
actuator = CommClient(actuatorCfg);

master.connect();
actuator.connect();
pause(1);  % Ensure subscriptions are established

% Publish messages between nodes
cmdMsg = jsonencode(struct("cmd", "move", "value", 1.0));
master.commPublish('masterNode/cmd', cmdMsg);
pause(1);

statusMsg = jsonencode(struct("status", "completed"));
actuator.commPublish('actuatorNode/status', statusMsg);
pause(1);

% Validate that callbacks were triggered
assert(evalin('base', 'actuatorReceivedFlag') == true, '[FAIL] Actuator did not receive the command.');
assert(evalin('base', 'masterReceivedFlag') == true, '[FAIL] Master did not receive the status update.');

fprintf("[PASS] Inter-node messaging test passed successfully.\n");

% Clean up
master.disconnect();
actuator.disconnect();
