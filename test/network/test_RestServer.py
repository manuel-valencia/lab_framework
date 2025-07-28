# test_RestServer.py
# This file contains unit tests for the RestServer Flask application.

import os
import json
import pytest
from flask import Flask
from network.RestServer import app, TEMP_DIR, SUPPORTED_EXTENSIONS

@pytest.fixture
def client():
    # Flask provides a test client for unit testing
    with app.test_client() as client:
        yield client

def test_post_json_success(client):
    payload = {
        "experiment": "test01",
        "data": [{"a": 1, "b": 2}, {"a": 3, "b": 4}],
        "meta": {"timestamp": "2025-07-27 23:54:12.514", "type": "waveData"}
    }
    resp = client.post("/data/testNode", json=payload)
    assert resp.status_code == 200
    assert "saved" in resp.json

def test_post_csv_success(client):
    csv_data = "col1,col2\n1,2\n3,4"
    resp = client.post("/data/testNode?experimentName=csvtest", data=csv_data, headers={"Content-Type": "text/csv"})
    assert resp.status_code == 200
    assert "saved" in resp.json

def test_post_json_missing_data(client):
    payload = {"experiment": "test01", "meta": {}}
    resp = client.post("/data/testNode", json=payload)
    assert resp.status_code == 400
    assert "error" in resp.json

def test_post_unsupported_content_type(client):
    resp = client.post("/data/testNode", data="foo", headers={"Content-Type": "application/xml"})
    assert resp.status_code == 415
    assert "error" in resp.json

def test_get_data_latest(client):
    # First, post some data
    payload = {"experiment": "test02", "data": [{"x": 1}]}
    client.post("/data/testNode", json=payload)
    resp = client.get("/data/testNode?latest=true")
    assert resp.status_code == 200
    assert resp.json["status"] == "success"

def test_get_data_by_name(client):
    payload = {"experiment": "test03", "data": [{"y": 2}]}
    client.post("/data/testNode?experimentName=test03", json=payload)
    resp = client.get("/data/testNode?experimentName=test03&format=jsonl")
    assert resp.status_code == 200
    assert resp.json["format"] == "jsonl"

def test_get_data_missing_experiment(client):
    resp = client.get("/data/testNode?experimentName=doesnotexist&format=jsonl")
    assert resp.status_code == 404 or resp.json.get("error")

def test_get_data_invalid_format(client):
    payload = {"experiment": "test04", "data": [{"z": 3}]}
    client.post("/data/testNode", json=payload)
    resp = client.get("/data/testNode?experimentName=test04&format=xml")
    assert resp.status_code == 400
    assert "error" in resp.json

def test_get_data_no_client(client):
    resp = client.get("/data/unknownNode?latest=true")
    assert resp.status_code == 404
    assert "error" in resp.json

def test_list_available_experiments(client):
    # Ensure at least one experiment exists
    payload = {"experiment": "test05", "data": [{"a": 5}]}
    client.post("/data/testNode", json=payload)
    resp = client.get("/data")
    assert resp.status_code == 200
    assert "testNode" in resp.json

def test_list_available_experiments_empty(client):
    # Remove all data
    for root, dirs, files in os.walk(TEMP_DIR):
        for f in files:
            os.remove(os.path.join(root, f))
    resp = client.get("/data")
    assert resp.status_code == 404

def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json["status"] == "online"
    assert "uptime" in resp.json
    assert "stored_clients" in resp.json
    assert "total_files" in resp.json

def test_post_and_get_csv(client):
    csv_data = "foo,bar\n1,2"
    client.post("/data/csvNode?experimentName=csvexp", data=csv_data, headers={"Content-Type": "text/csv"})
    resp = client.get("/data/csvNode?experimentName=csvexp&format=csv")
    assert resp.status_code == 200
    assert resp.json["format"] == "csv"
    assert "foo,bar" in resp.json["csv"]

def test_get_unsupported_filetype(client):
    # Create a dummy file with unsupported extension
    client_dir = os.path.join(TEMP_DIR, "dummyNode")
    os.makedirs(client_dir, exist_ok=True)
    file_path = os.path.join(client_dir, "badfile.txt")
    with open(file_path, "w") as f:
        f.write("bad content")
    resp = client.get("/data/dummyNode?experimentName=badfile&format=txt")
    assert resp.status_code in (400, 415, 404)

if __name__ == "__main__":
    pytest.main([__file__])