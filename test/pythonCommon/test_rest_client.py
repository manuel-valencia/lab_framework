"""
test_rest_client.py

Comprehensive pytest test suite for RestClient functionality.
Tests constructor, send_data, fetch_data, check_health, and error handling.
Assumes REST server may or may not be running on localhost:5000.

To run these tests:
    pytest test_rest_client.py -v
    
To run with coverage:
    pytest test_rest_client.py --cov=RestClient -v
"""

import sys
import os
import pytest
import pandas as pd
import json
from unittest.mock import patch, Mock
import requests

# Try to import RestClient, add path if needed
try:
    from RestClient import RestClient
except ImportError:
    # Add the pythonCommon directory to the path
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'pythonCommon'))
    try:
        from RestClient import RestClient
    except ImportError as e:
        pytest.skip(f"Could not import RestClient: {e}", allow_module_level=True)


class TestRestClientConstructor:
    """Test RestClient constructor functionality."""
    
    def test_constructor_basic_config(self):
        """Test 1: Constructor with basic configuration."""
        cfg = {'clientID': 'testRestNode'}
        client = RestClient(cfg)
        
        assert client.clientID == 'testRestNode'
        assert client.base_url == 'http://localhost:5000'
        assert client.post_endpoint == 'http://localhost:5000/data/testRestNode'
        assert client.tag == '[REST:testRestNode]'
        assert client.timeout == 15
        assert client.verbose == False
    
    def test_constructor_full_config_override(self):
        """Test 2: Constructor with full configuration override."""
        cfg = {
            'clientID': 'advancedNode',
            'brokerAddress': 'test.server.com',
            'restPort': 8080,
            'verbose': True,
            'timeout': 30
        }
        client = RestClient(cfg)
        
        assert client.clientID == 'advancedNode'
        assert client.base_url == 'http://test.server.com:8080'
        assert client.post_endpoint == 'http://test.server.com:8080/data/advancedNode'
        assert client.verbose == True
        assert client.timeout == 30
    
    def test_constructor_missing_clientID(self):
        """Test 3: Constructor error handling - missing clientID."""
        cfg = {'brokerAddress': 'localhost'}  # Missing clientID
        
        with pytest.raises(ValueError, match='RestClient requires clientID'):
            RestClient(cfg)


class TestRestClientHealthCheck:
    """Test RestClient health check functionality."""
    
    def setup_method(self):
        """Setup for each test method."""
        self.cfg = {'clientID': 'healthTestNode', 'verbose': True}
        self.client = RestClient(self.cfg)
    
    def test_check_health_server_online(self):
        """Test 4: checkHealth with server potentially online (mocked)."""
        # Convert to mocked test instead of integration test
        with patch('requests.get') as mock_get:
            mock_response = Mock()
            mock_response.raise_for_status.return_value = None
            mock_response.json.return_value = {'status': 'online'}
            mock_get.return_value = mock_response
            
            is_online = self.client.check_health()
            assert is_online == True
            print("Health check mocked as online")
    
    def test_check_health_server_offline(self):
        """Test 5: checkHealth with server definitely offline."""
        cfg_offline = {
            'clientID': 'offlineTestNode',
            'brokerAddress': 'nonexistent.server.invalid',
            'timeout': 1  # Short timeout for faster test
        }
        client_offline = RestClient(cfg_offline)
        
        is_offline = not client_offline.check_health()
        assert is_offline  # Should be offline for invalid server
    
    @patch('requests.get')
    def test_check_health_mocked_online(self, mock_get):
        """Test checkHealth with mocked online response."""
        # Mock successful response
        mock_response = Mock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {'status': 'online'}
        mock_get.return_value = mock_response
        
        result = self.client.check_health()
        assert result == True
    
    @patch('requests.get')
    def test_check_health_mocked_offline(self, mock_get):
        """Test checkHealth with mocked offline response."""
        # Mock request exception
        mock_get.side_effect = requests.exceptions.RequestException("Connection failed")
        
        result = self.client.check_health()
        assert result == False


class TestRestClientDataTransfer:
    """Test RestClient data sending and fetching functionality."""
    
    def setup_method(self):
        """Setup for each test method."""
        self.cfg = {'clientID': 'dataTestNode', 'verbose': True}
        self.client = RestClient(self.cfg)
        
        # Test data matching MATLAB test structure
        self.test_data_list = [
            {'timestamp': '2025-08-04T18:45:00.000Z', 'value': 42.5, 'sensor': 'test'},
            {'timestamp': '2025-08-04T18:45:01.000Z', 'value': 24.1, 'sensor': 'test2'}
        ]
        
        self.test_dataframe = pd.DataFrame([
            {'ID': 1, 'Value': 10.1, 'Label': 'A'},
            {'ID': 2, 'Value': 20.2, 'Label': 'B'},
            {'ID': 3, 'Value': 30.3, 'Label': 'C'}
        ])
    
    @patch('requests.post')
    def test_send_data_json_format(self, mock_post):
        """Test 6: sendData with JSON data (mocked)."""
        # Mock successful response
        mock_response = Mock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {'status': 'success', 'saved': 'data saved'}
        mock_post.return_value = mock_response
        
        response = self.client.send_data(self.test_data_list, experiment_name='JSONTest')
        
        assert response['status'] == 'success'
        assert 'saved' in response
        
        # Verify the request was made correctly
        mock_post.assert_called_once()
        call_args = mock_post.call_args
        assert 'data' in call_args.kwargs['json']
        assert call_args.kwargs['json']['experimentName'] == 'JSONTest'
    
    @patch('requests.post')
    def test_send_data_csv_format(self, mock_post):
        """Test 7: sendData with CSV table data (mocked)."""
        # Mock successful response
        mock_response = Mock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {'status': 'success', 'saved': 'CSV saved'}
        mock_post.return_value = mock_response
        
        response = self.client.send_data(self.test_dataframe, experiment_name='CSVTest', format_type='csv')
        
        assert response['status'] == 'success'
        
        # Verify the request was made with CSV content type
        mock_post.assert_called_once()
        call_args = mock_post.call_args
        assert call_args.kwargs['headers']['Content-Type'] == 'text/csv'
    
    @patch('requests.post')
    def test_send_data_network_error(self, mock_post):
        """Test sendData with network error."""
        # Mock network error
        mock_post.side_effect = requests.exceptions.RequestException("Network error")
        
        response = self.client.send_data(self.test_data_list)
        
        assert response['status'] == 'error'
        assert 'Network error' in response['message']
    
    @patch('requests.get')
    def test_fetch_data_basic_retrieval(self, mock_get):
        """Test 8: fetchData basic retrieval (mocked)."""
        # Mock successful response
        mock_response = Mock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {'data': [{'test': 'data'}]}
        mock_get.return_value = mock_response
        
        result = self.client.fetch_data(clientID='jsonTestNode', latest=True)
        
        assert result == [{'test': 'data'}]
        
        # Verify correct URL and parameters
        mock_get.assert_called_once()
        call_args = mock_get.call_args
        assert 'jsonTestNode' in call_args.args[0]
        assert call_args.kwargs['params']['latest'] == 'true'
    
    @patch('requests.get')
    def test_fetch_data_with_parameters(self, mock_get):
        """Test 9: fetchData with specific parameters (mocked)."""
        # Mock successful response with CSV data
        mock_response = Mock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {'csv': 'ID,Value,Label\n1,10.1,A\n2,20.2,B'}
        mock_get.return_value = mock_response
        
        result = self.client.fetch_data(
            clientID='csvTestNode', 
            experiment_name='CSVTest', 
            format_type='csv'
        )
        
        assert 'ID,Value,Label' in result
        
        # Verify correct parameters
        mock_get.assert_called_once()
        call_args = mock_get.call_args
        params = call_args.kwargs['params']
        assert params['experimentName'] == 'CSVTest'
        assert params['format'] == 'csv'
    
    @patch('requests.get')
    def test_fetch_data_network_error(self, mock_get):
        """Test fetchData with network error."""
        # Mock network error
        mock_get.side_effect = requests.exceptions.RequestException("Network error")
        
        result = self.client.fetch_data()
        
        assert result['status'] == 'error'
        assert 'Network error' in result['message']
    
    def test_send_data_json_unit_test(self):
        """Unit test: sendData with JSON data (mocked only)."""
        with patch('requests.post') as mock_post:
            # Mock successful response
            mock_response = Mock()
            mock_response.raise_for_status.return_value = None
            mock_response.json.return_value = {'status': 'success', 'saved': 'data saved'}
            mock_post.return_value = mock_response
            
            response = self.client.send_data(self.test_data_list, experiment_name='PytestJSONTest')
            
            assert response['status'] == 'success'
            assert 'saved' in response
            print("JSON data send test completed (mocked)")
    
    def test_send_data_csv_unit_test(self):
        """Unit test: sendData with CSV data (mocked only)."""
        with patch('requests.post') as mock_post:
            # Mock successful response
            mock_response = Mock()
            mock_response.raise_for_status.return_value = None
            mock_response.json.return_value = {'status': 'success', 'saved': 'CSV saved'}
            mock_post.return_value = mock_response
            
            response = self.client.send_data(self.test_dataframe, experiment_name='PytestCSVTest')
            
            assert response['status'] == 'success'
            print("CSV data send test completed (mocked)")


class TestRestClientUtilities:
    """Test RestClient utility functions."""
    
    def test_convert_to_csv_list_of_dicts(self):
        """Test 10: convertToCSV static method with list of dicts."""
        test_data = [
            {'Index': 1, 'Value': 3.14, 'Code': 'X'},
            {'Index': 2, 'Value': 2.71, 'Code': 'Y'}
        ]
        
        csv_string = RestClient.convert_to_csv(test_data)
        
        assert isinstance(csv_string, str)
        assert 'Index' in csv_string
        assert 'Value' in csv_string
        assert 'Code' in csv_string
        assert '3.14' in csv_string
        assert '2.71' in csv_string
    
    def test_convert_to_csv_single_dict(self):
        """Test convertToCSV with single dictionary."""
        test_data = {'Index': 1, 'Value': 3.14, 'Code': 'X'}
        
        csv_string = RestClient.convert_to_csv(test_data)
        
        assert isinstance(csv_string, str)
        assert 'Index' in csv_string
        assert '3.14' in csv_string
    
    def test_convert_to_csv_error_handling(self):
        """Test 11: convertToCSV error handling."""
        # Test with list of non-dictionaries
        bad_data = [1, 2, 3]  # List of numbers, not dictionaries
        
        with pytest.raises(ValueError, match='All items in list must be dictionaries'):
            RestClient.convert_to_csv(bad_data)
        
        # Test with non-list, non-dict
        with pytest.raises(ValueError, match='Data must be a dictionary or list of dictionaries'):
            RestClient.convert_to_csv("invalid_string")
        
        # Test with mixed types in list
        mixed_data = [{'a': 1}, "not_a_dict", {'b': 2}]
        with pytest.raises(ValueError, match='All items in list must be dictionaries'):
            RestClient.convert_to_csv(mixed_data)
    
    def test_convert_to_csv_empty_data(self):
        """Test convertToCSV with empty data."""
        with pytest.raises(ValueError, match='Cannot convert empty list to CSV'):
            RestClient.convert_to_csv([])


class TestRestClientTimeout:
    """Test RestClient timeout behavior."""
    
    def test_timeout_behavior(self):
        """Test 12: Timeout behavior."""
        cfg = {
            'clientID': 'timeoutTestNode',
            'brokerAddress': '192.0.2.0',  # RFC5737 test address (should timeout)
            'timeout': 1  # Very short timeout
        }
        client = RestClient(cfg)
        
        import time
        start_time = time.time()
        is_online = client.check_health()
        elapsed = time.time() - start_time
        
        assert not is_online  # Should be offline
        assert elapsed < 5    # Should timeout quickly
        print(f"Timeout test completed in {elapsed:.2f} seconds")


class TestRestClientEdgeCases:
    """Test edge cases and additional scenarios."""
    
    def setup_method(self):
        """Setup for each test method."""
        self.cfg = {'clientID': 'edgeCaseTestNode'}
        self.client = RestClient(self.cfg)
    
    def test_send_data_auto_format_detection(self):
        """Test automatic format detection."""
        # Test with DataFrame (should auto-detect as CSV)
        df = pd.DataFrame([{'a': 1, 'b': 2}])
        with patch('requests.post') as mock_post:
            mock_response = Mock()
            mock_response.raise_for_status.return_value = None
            mock_response.json.return_value = {'status': 'success'}
            mock_post.return_value = mock_response
            
            self.client.send_data(df)  # No format specified
            
            # Should call CSV method based on content type
            call_args = mock_post.call_args
            assert call_args.kwargs['headers']['Content-Type'] == 'text/csv'
    
    def test_fetch_data_default_clientID(self):
        """Test fetchData using default clientID."""
        with patch('requests.get') as mock_get:
            mock_response = Mock()
            mock_response.raise_for_status.return_value = None
            mock_response.json.return_value = {'data': 'test'}
            mock_get.return_value = mock_response
            
            # Call without specifying clientID (should use self.clientID)
            self.client.fetch_data(latest=True)
            
            call_args = mock_get.call_args
            assert 'edgeCaseTestNode' in call_args.args[0]
    
    @patch('requests.post')
    def test_send_data_json_response_fallback(self, mock_post):
        """Test handling of non-JSON response from server."""
        # Mock response that doesn't have JSON
        mock_response = Mock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.side_effect = json.JSONDecodeError("No JSON", "", 0)
        mock_response.text = "Data saved successfully"
        mock_post.return_value = mock_response
        
        test_data = [{'test': 'data'}]
        response = self.client.send_data(test_data)
        
        assert response['status'] == 'success'
        assert response['saved'] == "Data saved successfully"


if __name__ == "__main__":
    # Run tests when script is executed directly
    pytest.main([__file__, '-v', '--tb=short'])
