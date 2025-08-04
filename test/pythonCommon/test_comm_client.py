"""
test_comm_client.py

Comprehensive test suite for CommClient.py, mirroring the functionality 
of MATLAB CommClientTestScript.m with proper mocking and edge case testing.

This test suite validates:
- Constructor with various configuration options
- MQTT connection and disconnection
- Message publishing and subscription
- Heartbeat functionality
- Message logging and callbacks
- Error handling and edge cases

Author: Automated port and enhancement of MATLAB test patterns
"""

import json
import pytest
import time
import threading
from unittest.mock import Mock, patch, MagicMock, call
from datetime import datetime

# Import the CommClient class
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'pythonCommon'))

from CommClient import CommClient


class TestCommClientConstructor:
    """Test CommClient constructor with various configurations."""
    
    def test_constructor_minimal_config(self):
        """Test constructor with minimal required configuration."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        assert client.client_id == 'testNode'
        assert client.broker_address == 'localhost'
        assert client.broker_port == 1883
        assert client.heartbeat_interval == 0
        assert client.verbose is False
        assert client.subscriptions == ['testNode/cmd']
        assert 'testNode/status' in client.publications
        
    def test_constructor_full_config(self):
        """Test constructor with complete configuration."""
        callback = Mock()
        config = {
            'clientID': 'fullNode',
            'brokerAddress': '192.168.1.100',
            'brokerPort': 8883,
            'onMessageCallback': callback,
            'subscriptions': ['custom/topic1', 'custom/topic2'],
            'publications': ['custom/out1', 'custom/out2'],
            'heartbeatInterval': 5.0,
            'keepAliveDuration': 120,
            'verbose': True,
            'timeout': 45.0
        }
        
        client = CommClient(config)
        
        assert client.client_id == 'fullNode'
        assert client.broker_address == '192.168.1.100'
        assert client.broker_port == 8883
        assert client.on_message_callback == callback
        assert client.subscriptions == ['custom/topic1', 'custom/topic2']
        assert client.publications == ['custom/out1', 'custom/out2']
        assert client.heartbeat_interval == 5.0
        assert client.keep_alive_duration == 120
        assert client.verbose is True
        assert client.timeout == 45.0
        
    def test_constructor_missing_client_id(self):
        """Test constructor fails without clientID."""
        config = {'brokerAddress': 'localhost'}
        
        with pytest.raises(ValueError, match="clientID is required"):
            CommClient(config)
            
    def test_constructor_empty_client_id(self):
        """Test constructor fails with empty clientID."""
        config = {'clientID': ''}
        
        with pytest.raises(ValueError, match="clientID is required"):
            CommClient(config)
            
    def test_constructor_invalid_callback(self):
        """Test constructor fails with non-callable callback."""
        config = {
            'clientID': 'testNode',
            'onMessageCallback': 'not_a_function'
        }
        
        with pytest.raises(TypeError, match="onMessageCallback must be callable"):
            CommClient(config)
            
    def test_constructor_invalid_subscriptions(self):
        """Test constructor fails with invalid subscriptions type."""
        config = {
            'clientID': 'testNode',
            'subscriptions': 'not_a_list'
        }
        
        with pytest.raises(TypeError, match="subscriptions must be a list or tuple"):
            CommClient(config)
            
    def test_constructor_invalid_publications(self):
        """Test constructor fails with invalid publications type."""
        config = {
            'clientID': 'testNode',
            'publications': 42
        }
        
        with pytest.raises(TypeError, match="publications must be a list or tuple"):
            CommClient(config)


class TestCommClientConnection:
    """Test MQTT connection functionality."""
    
    @patch('CommClient.mqtt.Client')
    def test_successful_connection(self, mock_mqtt_class):
        """Test successful MQTT connection."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)  # Success code
        
        config = {'clientID': 'testNode', 'verbose': True}
        client = CommClient(config)
        
        # Simulate successful connection callback
        def simulate_connect():
            time.sleep(0.01)  # Small delay
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        
        client.connect()
        thread.join()
        
        mock_client.connect.assert_called_once_with('localhost', 1883, 60)
        mock_client.loop_start.assert_called_once()
        mock_client.subscribe.assert_called()
        assert client.connected is True
        
    @patch('CommClient.mqtt.Client')
    def test_connection_timeout(self, mock_mqtt_class):
        """Test connection timeout."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        
        config = {'clientID': 'testNode', 'timeout': 0.1}
        client = CommClient(config)
        
        with pytest.raises(ConnectionError, match="Connection timeout"):
            client.connect()
            
    @patch('CommClient.mqtt.Client')
    def test_connection_failure(self, mock_mqtt_class):
        """Test connection failure with error code."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        
        config = {'clientID': 'testNode', 'timeout': 0.1}  # Short timeout
        client = CommClient(config)
        
        # Simulate connection failure callback immediately
        def simulate_connect_fail():
            client._on_connect(mock_client, None, None, 1)  # Error code 1
            
        # Mock the connect method to call our failure simulation
        original_connect = mock_client.connect
        def mock_connect(*args, **kwargs):
            original_connect(*args, **kwargs)
            simulate_connect_fail()
            
        mock_client.connect = mock_connect
        
        with pytest.raises(ConnectionError, match="MQTT connection failed with code 1"):
            client.connect()
        
    @patch('CommClient.mqtt.Client')
    def test_already_connected(self, mock_mqtt_class):
        """Test connecting when already connected."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Simulate successful connection
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        
        client.connect()
        thread.join()
        
        # Try to connect again
        client.connect()  # Should not raise exception
        
        # Should only call connect once
        assert mock_client.connect.call_count == 1


class TestCommClientDisconnection:
    """Test MQTT disconnection functionality."""
    
    @patch('CommClient.mqtt.Client')
    def test_successful_disconnection(self, mock_mqtt_class):
        """Test successful disconnection."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Now disconnect
        client.disconnect()
        
        mock_client.loop_stop.assert_called_once()
        mock_client.disconnect.assert_called_once()
        assert client.connected is False
        
    def test_disconnect_when_not_connected(self):
        """Test disconnecting when not connected."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Should not raise exception
        client.disconnect()
        assert client.connected is False


class TestCommClientPublishing:
    """Test message publishing functionality."""
    
    @patch('CommClient.mqtt.Client')
    def test_publish_string_message(self, mock_mqtt_class):
        """Test publishing string message."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        mock_result = Mock()
        mock_result.rc = 0  # Success
        mock_client.publish.return_value = mock_result
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Publish message
        client.comm_publish('test/topic', 'Hello World')
        
        mock_client.publish.assert_called_once_with('test/topic', 'Hello World')
        
    @patch('CommClient.mqtt.Client')
    def test_publish_dict_message(self, mock_mqtt_class):
        """Test publishing dictionary message (JSON)."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        mock_result = Mock()
        mock_result.rc = 0
        mock_client.publish.return_value = mock_result
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Publish dictionary
        test_data = {'key': 'value', 'number': 42}
        client.comm_publish('test/topic', test_data)
        
        expected_json = json.dumps(test_data)
        mock_client.publish.assert_called_once_with('test/topic', expected_json)
        
    def test_publish_not_connected(self):
        """Test publishing when not connected raises error."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        with pytest.raises(ConnectionError, match="MQTT client is not connected"):
            client.comm_publish('test/topic', 'message')
            
    @patch('CommClient.mqtt.Client')
    def test_publish_failure(self, mock_mqtt_class):
        """Test publish failure handling."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        mock_result = Mock()
        mock_result.rc = 1  # Error code
        mock_client.publish.return_value = mock_result
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        with pytest.raises(Exception, match="Failed to publish"):
            client.comm_publish('test/topic', 'message')


class TestCommClientHeartbeat:
    """Test heartbeat functionality."""
    
    @patch('CommClient.mqtt.Client')
    def test_heartbeat_disabled_by_default(self, mock_mqtt_class):
        """Test heartbeat is disabled by default."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        assert client.heartbeat_interval == 0
        assert client._heartbeat_timer is None
        
    @patch('CommClient.mqtt.Client')
    def test_send_heartbeat(self, mock_mqtt_class):
        """Test manual heartbeat sending."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        mock_result = Mock()
        mock_result.rc = 0
        mock_client.publish.return_value = mock_result
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Send heartbeat
        client.send_heartbeat()
        
        # Verify heartbeat was published
        assert mock_client.publish.call_count >= 1
        # Find the heartbeat call
        heartbeat_call = None
        for call_args in mock_client.publish.call_args_list:
            if 'testNode/status' in str(call_args):
                heartbeat_call = call_args
                break
                
        assert heartbeat_call is not None
        topic, payload = heartbeat_call[0]
        assert topic == 'testNode/status'
        
        # Parse JSON payload
        heartbeat_data = json.loads(payload)
        assert heartbeat_data['clientID'] == 'testNode'
        assert heartbeat_data['state'] == 'READY'
        assert 'timestamp' in heartbeat_data
        
    def test_heartbeat_not_connected(self):
        """Test heartbeat when not connected."""
        config = {'clientID': 'testNode', 'verbose': True}
        client = CommClient(config)
        
        # Should not raise exception
        client.send_heartbeat()


class TestCommClientSubscription:
    """Test subscription functionality."""
    
    @patch('CommClient.mqtt.Client')
    def test_dynamic_subscribe(self, mock_mqtt_class):
        """Test dynamic topic subscription."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Subscribe to new topic
        initial_count = len(client.subscriptions)
        client.comm_subscribe('new/topic')
        
        assert len(client.subscriptions) == initial_count + 1
        assert 'new/topic' in client.subscriptions
        
    @patch('CommClient.mqtt.Client')
    def test_subscribe_duplicate_topic(self, mock_mqtt_class):
        """Test subscribing to already subscribed topic."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Try to subscribe to existing topic
        initial_count = len(client.subscriptions)
        existing_topic = client.subscriptions[0]
        client.comm_subscribe(existing_topic)
        
        assert len(client.subscriptions) == initial_count
        
    def test_subscribe_not_connected(self):
        """Test subscribing when not connected."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        with pytest.raises(ConnectionError, match="MQTT client is not connected"):
            client.comm_subscribe('new/topic')


class TestCommClientUnsubscription:
    """Test unsubscription functionality."""
    
    @patch('CommClient.mqtt.Client')
    def test_dynamic_unsubscribe(self, mock_mqtt_class):
        """Test dynamic topic unsubscription."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        mock_client.unsubscribe.return_value = (0, 1)
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Unsubscribe from existing topic
        topic_to_remove = client.subscriptions[0]
        initial_count = len(client.subscriptions)
        client.comm_unsubscribe(topic_to_remove)
        
        assert len(client.subscriptions) == initial_count - 1
        assert topic_to_remove not in client.subscriptions
        
    @patch('CommClient.mqtt.Client')
    def test_unsubscribe_nonexistent_topic(self, mock_mqtt_class):
        """Test unsubscribing from non-subscribed topic."""
        mock_client = Mock()
        mock_mqtt_class.return_value = mock_client
        mock_client.subscribe.return_value = (0, 1)
        
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        # Connect first
        def simulate_connect():
            time.sleep(0.01)
            client._on_connect(mock_client, None, None, 0)
            
        thread = threading.Thread(target=simulate_connect)
        thread.start()
        client.connect()
        thread.join()
        
        # Try to unsubscribe from non-existent topic
        initial_count = len(client.subscriptions)
        client.comm_unsubscribe('nonexistent/topic')
        
        assert len(client.subscriptions) == initial_count


class TestCommClientMessageHandling:
    """Test message handling and logging."""
    
    def test_handle_message_logging(self):
        """Test message handling adds to log."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        initial_count = len(client.message_log)
        client.handle_message('test/topic', 'test message')
        
        assert len(client.message_log) == initial_count + 1
        last_entry = client.message_log[-1]
        assert last_entry['topic'] == 'test/topic'
        assert last_entry['message'] == 'test message'
        assert 'timestamp' in last_entry
        
    def test_handle_message_callback(self):
        """Test message handling calls callback."""
        callback = Mock()
        config = {
            'clientID': 'testNode',
            'onMessageCallback': callback
        }
        client = CommClient(config)
        
        client.handle_message('test/topic', 'test message')
        
        callback.assert_called_once_with('test/topic', 'test message')
        
    def test_handle_message_callback_error(self):
        """Test message handling with callback error."""
        def failing_callback(topic, message):
            raise Exception("Callback error")
            
        config = {
            'clientID': 'testNode',
            'onMessageCallback': failing_callback
        }
        client = CommClient(config)
        
        # Should not raise exception, just log warning
        client.handle_message('test/topic', 'test message')
        
        # Message should still be logged
        assert len(client.message_log) == 1


class TestCommClientUtilities:
    """Test utility methods."""
    
    def test_get_full_topic(self):
        """Test topic construction."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        assert client.get_full_topic('log') == 'testNode/log'
        assert client.get_full_topic('status') == 'testNode/status'
        assert client.get_full_topic('custom') == 'testNode/custom'
        
    def test_get_full_topic_invalid_suffix(self):
        """Test topic construction with invalid suffix."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        with pytest.raises(TypeError, match="Suffix must be a string"):
            client.get_full_topic(123)
            
    def test_add_to_log_valid(self):
        """Test adding valid log entry."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        client.add_to_log('test/topic', 'test message')
        
        assert len(client.message_log) == 1
        entry = client.message_log[0]
        assert entry['topic'] == 'test/topic'
        assert entry['message'] == 'test message'
        
    def test_add_to_log_invalid(self):
        """Test adding invalid log entry."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        with pytest.raises(ValueError, match="Topic and message are required"):
            client.add_to_log('', 'message')
            
        with pytest.raises(ValueError, match="Topic and message are required"):
            client.add_to_log('topic', '')
            
    def test_get_message_log(self):
        """Test getting message log copy."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        client.add_to_log('topic1', 'message1')
        client.add_to_log('topic2', 'message2')
        
        log_copy = client.get_message_log()
        
        assert len(log_copy) == 2
        assert log_copy[0]['topic'] == 'topic1'
        assert log_copy[1]['topic'] == 'topic2'
        
        # Modifying copy should not affect original
        log_copy.clear()
        assert len(client.message_log) == 2
        
    def test_clear_message_log(self):
        """Test clearing message log."""
        config = {'clientID': 'testNode'}
        client = CommClient(config)
        
        client.add_to_log('topic1', 'message1')
        client.add_to_log('topic2', 'message2')
        assert len(client.message_log) == 2
        
        client.clear_message_log()
        assert len(client.message_log) == 0


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
