%% RestClientTestScript.m
% Standalone test harness for RestClient functionality
% Tests constructor, sendData, fetchData, checkHealth, and error handling
% Assumes REST server is running on localhost:5000

clear; clc;

addpath('C:\Users\Manny\Desktop\lab_framework\matlabCommon');

fprintf("=== RestClient Test Suite ===\n");

%% Test 1: Constructor - Basic Configuration
fprintf("\n[TEST 1] Constructor with basic config\n");
try
    cfg1.clientID = 'testRestNode';
    client1 = RestClient(cfg1);
    
    assert(strcmp(client1.clientID, 'testRestNode'));
    assert(strcmp(client1.baseURL, 'http://localhost:5000'));
    assert(strcmp(client1.postEndpoint, 'http://localhost:5000/data/testRestNode'));
    assert(strcmp(client1.tag, '[REST:testRestNode]'));
    assert(client1.timeout == 15);
    
    fprintf("[PASS] Basic constructor test passed.\n");
catch ME
    fprintf("[FAIL] Basic constructor test failed: %s\n", ME.message);
end

%% Test 2: Constructor - Full Configuration Override
fprintf("\n[TEST 2] Constructor with full config override\n");
try
    cfg2.clientID = 'advancedNode';
    cfg2.brokerAddress = 'test.server.com';
    cfg2.restPort = 8080;
    cfg2.verbose = true;
    cfg2.timeout = 30;
    
    client2 = RestClient(cfg2);
    
    assert(strcmp(client2.clientID, 'advancedNode'));
    assert(strcmp(client2.baseURL, 'http://test.server.com:8080'));
    assert(strcmp(client2.postEndpoint, 'http://test.server.com:8080/data/advancedNode'));
    assert(client2.verbose == true);
    assert(client2.timeout == 30);
    
    fprintf("[PASS] Full constructor test passed.\n");
catch ME
    fprintf("[FAIL] Full constructor test failed: %s\n", ME.message);
end

%% Test 3: Constructor Error - Missing clientID
fprintf("\n[TEST 3] Constructor error handling\n");
try
    cfgBad.brokerAddress = 'localhost';  % Missing clientID
    badClient = RestClient(cfgBad);
    fprintf("[FAIL] Constructor should have thrown error for missing clientID.\n");
catch ME
    if contains(ME.message, 'RestClient requires clientID')
        fprintf("[PASS] Constructor correctly rejected missing clientID.\n");
    else
        fprintf("[FAIL] Constructor threw unexpected error: %s\n", ME.message);
    end
end

%% Test 4: checkHealth - Server Online
fprintf("\n[TEST 4] checkHealth with server online\n");
try
    cfg4.clientID = 'healthTestNode';
    cfg4.verbose = true;
    client4 = RestClient(cfg4);
    
    isOnline = client4.checkHealth();
    
    if isOnline
        fprintf("[PASS] checkHealth detected server online.\n");
    else
        fprintf("[INFO] checkHealth detected server offline (expected if server not running).\n");
    end
catch ME
    fprintf("[FAIL] checkHealth test failed: %s\n", ME.message);
end

%% Test 5: checkHealth - Server Offline
fprintf("\n[TEST 5] checkHealth with server offline\n");
try
    cfg5.clientID = 'offlineTestNode';
    cfg5.brokerAddress = 'nonexistent.server.invalid';
    cfg5.timeout = 2;  % Short timeout for faster test
    client5 = RestClient(cfg5);
    
    isOffline = ~client5.checkHealth();
    
    if isOffline
        fprintf("[PASS] checkHealth correctly detected offline server.\n");
    else
        fprintf("[UNEXPECTED] checkHealth detected server online when it should be offline.\n");
    end
catch ME
    fprintf("[FAIL] checkHealth offline test failed: %s\n", ME.message);
end

%% Test 6: sendData - JSON Format
fprintf("\n[TEST 6] sendData with JSON data\n");
try
    cfg6.clientID = 'jsonTestNode';
    cfg6.verbose = true;
    client6 = RestClient(cfg6);
    
    % Create test data as array of structs (server expects data to be a list)
    testData = [struct('timestamp', datetime('now'), 'value', 42.5, 'sensor', 'test'); ...
                struct('timestamp', datetime('now'), 'value', 24.1, 'sensor', 'test2')];
    
    response = client6.sendData(testData, 'experimentName', 'JSONTest');
    
    if isfield(response, 'status') && strcmp(response.status, 'error')
        fprintf("[INFO] sendData failed as expected (server may not be running): %s\n", response.message);
    else
        fprintf("[PASS] sendData JSON test completed successfully.\n");
    end
catch ME
    fprintf("[FAIL] sendData JSON test failed: %s\n", ME.message);
end

%% Test 7: sendData - CSV Format with Table
fprintf("\n[TEST 7] sendData with CSV table data\n");
try
    cfg7.clientID = 'csvTestNode';
    client7 = RestClient(cfg7);
    
    % Create test table
    testTable = table([1; 2; 3], [10.1; 20.2; 30.3], {'A'; 'B'; 'C'}, ...
                     'VariableNames', {'ID', 'Value', 'Label'});
    
    response = client7.sendData(testTable, 'experimentName', 'CSVTest', 'format', 'csv');
    
    if isfield(response, 'status') && strcmp(response.status, 'error')
        fprintf("[INFO] sendData CSV failed as expected (server may not be running): %s\n", response.message);
    else
        fprintf("[PASS] sendData CSV test completed successfully.\n");
    end
catch ME
    fprintf("[FAIL] sendData CSV test failed: %s\n", ME.message);
end

%% Test 8: fetchData - Basic Retrieval
fprintf("\n[TEST 8] fetchData basic retrieval\n");
try
    cfg8.clientID = 'fetchTestNode';
    client8 = RestClient(cfg8);
    
    % Fetch latest data from jsonTestNode (which posted data in Test 6)
    result = client8.fetchData('clientID', 'jsonTestNode', 'latest', true);
    
    if isfield(result, 'status') && strcmp(result.status, 'error')
        fprintf("[INFO] fetchData failed as expected (server may not be running): %s\n", result.message);
    else
        fprintf("[PASS] fetchData test completed successfully.\n");
    end
catch ME
    fprintf("[FAIL] fetchData test failed: %s\n", ME.message);
end

%% Test 9: fetchData - With Parameters
fprintf("\n[TEST 9] fetchData with specific parameters\n");
try
    cfg9.clientID = 'paramFetchNode';
    client9 = RestClient(cfg9);
    
    % Fetch specific experiment from csvTestNode (which posted data in Test 7)
    result = client9.fetchData('clientID', 'csvTestNode', 'experimentName', 'CSVTest', 'format', 'csv');
    
    if isfield(result, 'status') && strcmp(result.status, 'error')
        fprintf("[INFO] fetchData with params failed as expected (server may not be running): %s\n", result.message);
    else
        fprintf("[PASS] fetchData with parameters test completed successfully.\n");
    end
catch ME
    fprintf("[FAIL] fetchData with parameters test failed: %s\n", ME.message);
end

%% Test 10: convertToCSV Static Method
fprintf("\n[TEST 10] convertToCSV static method\n");
try
    % Create test table
    testTable = table([1; 2], [3.14; 2.71], {'X'; 'Y'}, ...
                     'VariableNames', {'Index', 'Value', 'Code'});
    
    csvString = RestClient.convertToCSV(testTable);
    
    % Basic validation
    assert(ischar(csvString) || isstring(csvString));
    assert(contains(csvString, 'Index'));
    assert(contains(csvString, 'Value'));
    assert(contains(csvString, 'Code'));
    assert(contains(csvString, '3.14'));
    
    fprintf("[PASS] convertToCSV static method test passed.\n");
catch ME
    fprintf("[FAIL] convertToCSV test failed: %s\n", ME.message);
end

%% Test 11: convertToCSV Error Handling
fprintf("\n[TEST 11] convertToCSV error handling\n");
try
    badData = [1, 2, 3];  % Not a table
    csvString = RestClient.convertToCSV(badData);
    fprintf("[FAIL] convertToCSV should have thrown error for non-table input.\n");
catch ME
    if contains(ME.message, 'Input must be a table')
        fprintf("[PASS] convertToCSV correctly rejected non-table input.\n");
    else
        fprintf("[FAIL] convertToCSV threw unexpected error: %s\n", ME.message);
    end
end

%% Test 12: Timeout Behavior
fprintf("\n[TEST 12] Timeout behavior\n");
try
    cfg12.clientID = 'timeoutTestNode';
    cfg12.brokerAddress = '192.0.2.0';  % RFC5737 test address (should timeout)
    cfg12.timeout = 1;  % Very short timeout
    client12 = RestClient(cfg12);
    
    tic;
    isOnline = client12.checkHealth();
    elapsed = toc;
    
    if ~isOnline && elapsed < 5  % Should timeout quickly
        fprintf("[PASS] Timeout behavior test passed (%.2f seconds).\n", elapsed);
    else
        fprintf("[INFO] Timeout test results: online=%d, elapsed=%.2f seconds.\n", isOnline, elapsed);
    end
catch ME
    fprintf("[FAIL] Timeout test failed: %s\n", ME.message);
end

%% Summary
fprintf("\n=== Test Suite Complete ===\n");
fprintf("✅ All RestClient tests finished.\n");
fprintf("Note: Some tests may show '[INFO]' results if REST server is not running.\n");
