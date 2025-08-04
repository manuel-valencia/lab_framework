"""
RestClient.py

This class provides a lightweight HTTP interface for experiment nodes
to POST data to and optionally GET data from a central REST server.

Designed for use in conjunction with CommClient for MQTT messaging.
Intended primarily for use in experiment completion workflows.

Configuration:
  - brokerAddress: IP or hostname of REST server (e.g., 'localhost')
  - restPort: optional port (default 5000)

Primary Usage:
  - POST experiment data using POST /data/<clientID>
  - GET data for aggregation (optional, used by master nodes)

Dependencies:
  - requests library for HTTP operations
  - pandas for CSV handling
  - JSON for data serialization
"""

import requests
import json
import pandas as pd
import io
import logging
from typing import Union, Dict, List, Any, Optional
# import time


class RestClient:
    """
    RestClient provides HTTP interface for experiment data transfer.
    
    This class handles communication with a central REST server for
    posting experiment data and retrieving stored results.
    """
    
    def __init__(self, cfg: Dict[str, Any]):
        """
        Constructor: Takes same config structure as CommClient / ExperimentManager
        
        Args:
            cfg (dict): Configuration dictionary containing:
                - clientID (str): Required - unique node identifier
                - brokerAddress (str): Optional - IP/hostname (default: 'localhost')
                - restPort (int): Optional - port number (default: 5000)
                - verbose (bool): Optional - enable debug output (default: False)
                - timeout (int): Optional - HTTP timeout in seconds (default: 15)
        
        Raises:
            ValueError: If clientID is not provided in config
        """
        # Validate required fields
        if 'clientID' not in cfg:
            raise ValueError('RestClient requires clientID in configuration.')
        
        # Parse configuration with defaults (matching MATLAB defaults)
        self.clientID = cfg['clientID']
        self.brokerAddress = cfg.get('brokerAddress', 'localhost')
        self.restPort = cfg.get('restPort', 5000)
        self.verbose = cfg.get('verbose', False)
        self.timeout = cfg.get('timeout', 15)
        
        # Build URLs
        self.base_url = f"http://{self.brokerAddress}:{self.restPort}"
        self.post_endpoint = f"{self.base_url}/data/{self.clientID}"
        self.tag = f"[REST:{self.clientID}]"
        
        # Setup logging if verbose
        if self.verbose:
            logging.basicConfig(level=logging.INFO)
            self.logger = logging.getLogger(__name__)
            self.logger.info(f"{self.tag} Initialized with endpoint: {self.post_endpoint}")
        else:
            self.logger = logging.getLogger(__name__)
            self.logger.setLevel(logging.WARNING)
    
    def send_data(self, data: Union[pd.DataFrame, List[Dict], Dict], 
                  experiment_name: Optional[str] = None, 
                  format_type: Optional[str] = None) -> Dict[str, Any]:
        """
        Sends experiment data to REST server.
        
        Args:
            data: Either a pandas DataFrame (CSV) or list of dicts/single dict (JSON)
            experiment_name (str, optional): Experiment name for filename prefix
            format_type (str, optional): 'csv' or 'jsonl' (auto-detected if not specified)
        
        Returns:
            dict: Response from server or error information
        """
        # Auto-detect format if not specified
        if format_type is None:
            if isinstance(data, pd.DataFrame):
                format_type = 'csv'
            else:
                format_type = 'jsonl'
        
        # Construct target URL
        url = self.post_endpoint
        params = {}
        if experiment_name:
            params['experimentName'] = experiment_name
        
        try:
            if format_type == 'csv':
                response = self._send_csv_data(url, data, params)
            else:
                response = self._send_json_data(url, data, params, experiment_name)
            
            if self.verbose and 'saved' in response:
                self.logger.info(f"{self.tag} POST success: {response['saved']}")
            
            return response
            
        except requests.exceptions.RequestException as e:
            error_msg = f"POST failed: {str(e)}"
            self.logger.warning(f"{self.tag} {error_msg}")
            return {"status": "error", "message": error_msg}
        except Exception as e:
            error_msg = f"Unexpected error: {str(e)}"
            self.logger.warning(f"{self.tag} {error_msg}")
            return {"status": "error", "message": error_msg}
    
    def _send_csv_data(self, url: str, data: pd.DataFrame, params: Dict) -> Dict[str, Any]:
        """Send DataFrame as CSV data."""
        if not isinstance(data, pd.DataFrame):
            raise ValueError("Data must be a pandas DataFrame for CSV format")
        
        # Convert DataFrame to CSV string
        csv_buffer = io.StringIO()
        data.to_csv(csv_buffer, index=False)
        csv_string = csv_buffer.getvalue()
        
        headers = {'Content-Type': 'text/csv'}
        response = requests.post(url, data=csv_string, headers=headers, 
                               params=params, timeout=self.timeout)
        response.raise_for_status()
        
        # Handle both JSON and text responses
        try:
            return response.json()
        except json.JSONDecodeError:
            return {"status": "success", "saved": response.text}
    
    def _send_json_data(self, url: str, data: Union[List, Dict], 
                       params: Dict, experiment_name: Optional[str]) -> Dict[str, Any]:
        """Send data as JSON."""
        # Prepare payload
        payload = {"data": data}
        if experiment_name:
            payload["experimentName"] = experiment_name
        
        headers = {'Content-Type': 'application/json'}
        response = requests.post(url, json=payload, headers=headers, 
                               params=params, timeout=self.timeout)
        response.raise_for_status()
        
        # Handle both JSON and text responses
        try:
            return response.json()
        except json.JSONDecodeError:
            return {"status": "success", "saved": response.text}
    
    def fetch_data(self, clientID: Optional[str] = None, 
                   experiment_name: Optional[str] = None,
                   format_type: str = 'jsonl', 
                   latest: bool = False) -> Union[Dict, List, str, None]:
        """
        Retrieves experiment data from REST server.
        
        Args:
            clientID (str, optional): Node whose data to fetch (default: this client's ID)
            experiment_name (str, optional): Specific experiment name to fetch
            format_type (str): 'jsonl' or 'csv' (default: 'jsonl')
            latest (bool): If True, fetch latest data (default: False)
        
        Returns:
            Retrieved data or None if error occurred
        """
        # Use this client's ID if none specified
        if clientID is None:
            clientID = self.clientID
        
        # Build query parameters
        params = {}
        if latest:
            params['latest'] = 'true'
        elif experiment_name:
            params['experimentName'] = experiment_name
            params['format'] = format_type
        
        # Construct URL
        url = f"{self.base_url}/data/{clientID}"
        
        try:
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()
            
            result = response.json()

            if self.verbose:
                self.logger.info(f"{self.tag} GET success: format={format_type}")
            
            # Extract the actual data based on response format
            if 'csv' in result:
                return result['csv']  # Return raw CSV string
            elif 'data' in result:
                return result['data']  # Return JSON/JSONL data
            else:
                return result  # Return entire response
            
        except requests.exceptions.RequestException as e:
            error_msg = f"GET failed: {str(e)}"
            self.logger.warning(f"{self.tag} {error_msg}")
            return {"status": "error", "message": error_msg}
        except Exception as e:
            error_msg = f"Unexpected error: {str(e)}"
            self.logger.warning(f"{self.tag} {error_msg}")
            return {"status": "error", "message": error_msg}
    
    def check_health(self) -> bool:
        """
        Checks if the REST server is online by calling /health endpoint.
        
        Returns:
            bool: True if server is online, False otherwise
        """
        url = f"{self.base_url}/health"
        
        try:
            response = requests.get(url, timeout=self.timeout)
            response.raise_for_status()
            
            data = response.json()
            return data.get('status', '').lower() == 'online'
            
        except (requests.exceptions.RequestException, json.JSONDecodeError, KeyError):
            return False
    
    @staticmethod
    def convert_to_csv(data: Union[List[Dict], Dict]) -> str:
        """
        Converts list of dictionaries or single dictionary to CSV string.
        
        Args:
            data: List of dictionaries or single dictionary
            
        Returns:
            str: CSV formatted string
            
        Raises:
            ValueError: If data cannot be converted to DataFrame
        """
        # Validate input types first
        if not isinstance(data, (dict, list)):
            raise ValueError("Data must be a dictionary or list of dictionaries")
        
        if isinstance(data, list):
            if len(data) == 0:
                raise ValueError("Cannot convert empty list to CSV")
            
            # Check that all items in list are dictionaries
            for i, item in enumerate(data):
                if not isinstance(item, dict):
                    raise ValueError(f"All items in list must be dictionaries, but item {i} is {type(item).__name__}")
        
        try:
            if isinstance(data, dict):
                # Single dictionary - convert to list
                df = pd.DataFrame([data])
            else:
                # List of dictionaries
                df = pd.DataFrame(data)
            
            # Convert to CSV string
            csv_buffer = io.StringIO()
            df.to_csv(csv_buffer, index=False)
            return csv_buffer.getvalue()
            
        except Exception as e:
            raise ValueError(f"Failed to convert data to CSV: {str(e)}")


# Example usage and testing
if __name__ == "__main__":
    # Example configuration
    config = {
        'clientID': 'testNode1',
        'brokerAddress': 'localhost',
        'restPort': 5000,
        'verbose': True,
        'timeout': 30
    }
    
    # Create RestClient instance
    rest_client = RestClient(config)
    
    # Test health check
    print("Testing health check...")
    is_healthy = rest_client.check_health()
    print(f"Server health: {'Online' if is_healthy else 'Offline'}")
    
    # Test data conversion
    print("\nTesting CSV conversion...")
    test_data = [
        {'time': 1.0, 'value': 10.5, 'sensor': 'temp1'},
        {'time': 2.0, 'value': 11.2, 'sensor': 'temp1'},
        {'time': 3.0, 'value': 10.8, 'sensor': 'temp1'}
    ]
    
    csv_string = RestClient.convert_to_csv(test_data)
    print("CSV conversion successful:")
    print(csv_string)
    
    # Test data sending (if server is available)
    if is_healthy:
        print("\nTesting data transmission...")
        
        # Send JSON data
        response = rest_client.send_data(test_data, experiment_name='test_experiment')
        print(f"JSON send response: {response}")
        
        # Send DataFrame as CSV
        df = pd.DataFrame(test_data)
        response = rest_client.send_data(df, experiment_name='test_experiment_csv')
        print(f"CSV send response: {response}")
        
        # Test data retrieval
        print("\nTesting data retrieval...")
        retrieved_data = rest_client.fetch_data(latest=True)
        print(f"Retrieved data: {retrieved_data}")
    else:
        print("Server offline - skipping data transmission tests")
