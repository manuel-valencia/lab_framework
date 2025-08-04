"""
RestServer.py
==============
Flask REST API server for experiment automation framework.

This server accepts POST requests from peripheral nodes (e.g., sensors, actuators)
to upload experimental data after post-processing (typically in the DONE state).

This server stores the data in the lab_framework/network/tempRestData directory,
and will delete all directory items on server start to ensure a clean state.

This server also accepts GET requests from control nodes to retireive data from
the peripheral nodes as well as to list all available experiments and check server health.

This allows large data payloads in the form of JSONL or CSV files to be transferred 
reliably without MQTT size constraints. Each POST includes metadata for identification and storage
which will be required for later retrieval.

----------------------------------------------------------
Example Usage:
---------------
$ python RestServer.py

→ Once started, other nodes can send a POST request like:
POST http://<server_ip>:5000/data/probeNode
Content-Type: application/json
Body:
{
  "experiment": "test01",
  "data": [...],
  "meta": {
      "timestamp": "2025-07-27 23:54:12.514",
      "type": "waveData"
  }
}

More examples can be found in the docstrings of the endpoints.

----------------------------------------------------------
API Endpoints:
---------------
POST /data/<clientID>    - Accepts experiment data from node <clientID>
                          - Saves data as JSON, JSONL, or CSV depending on payload

GET /data/<clientID>     - Retrieves experiment data for <clientID>
                         - Supports query params for experiment name, format, and latest file

GET /data                - Lists all available experiments grouped by clientID
                         - Returns a JSON object mapping clientIDs to their experiment files
                         
GET /health              - Returns server health, runtime metadata, number of clients, and total files stored

----------------------------------------------------------
Notes:
------
- Requires Python 3.7+ and Flask
- Install dependencies with: pip install flask
- Flask server should be launched with host="0.0.0.0" to enable LAN access
- Port 5000 must be open on server firewall for cross-device communication
- Data is saved into ./network/tempRestData/<clientID>/<experimentTag>.jsonl

----------------------------------------------------------
"""

from flask import Flask, request, jsonify
from datetime import datetime
import os
import json
import shutil
import glob

TEMP_DIR = os.path.join(os.path.dirname(__file__), "tempRestData")
if os.path.exists(TEMP_DIR):
    shutil.rmtree(TEMP_DIR)
os.makedirs(TEMP_DIR, exist_ok=True)

SUPPORTED_EXTENSIONS = ('.csv', '.json', '.jsonl')

LAUNCH_TIME = datetime.now()

# Initialize Flask app
app = Flask(__name__)

#----------------------------------------------------------

@app.route('/data/<clientID>', methods=['POST'])
def receive_data(clientID):
    """
    Receives experimental data from a peripheral node via POST.
    Supports JSONL or CSV formats and stores them in a structured directory.

    Expected Headers:
      - Content-Type: application/json or text/csv

    Expected Payload:
      - JSONL: {'experimentName': <optional_name>, 'data': [<dict> ...]}
      - CSV: raw file upload via body with optional ?experimentName=<name> query param

    Example Usage (from MATLAB):
      - JSON:
        webwrite('http://localhost:5000/data/probeNode', jsonStruct)
      - CSV:
        webwrite(URL, csvData, weboptions('MediaType','text/csv'))

    Example Usage (from Python):
      - JSON:
        requests.post('http://localhost:5000/data/probeNode', json=payload)
      - CSV:
        requests.post('http://localhost:5000/data/probeNode?experimentName=test01',
                      data=csv_string, headers={'Content-Type': 'text/csv'})

    Returns:
      - 200: JSON response with save path and status
      - 400: JSON error if required fields are missing
      - 415: JSON error if unsupported content type is provided
      - 500: JSON error if there is a server-side exception
    """
    clientDir = os.path.join(TEMP_DIR, clientID)
    os.makedirs(clientDir, exist_ok=True)

    experimentTag = request.args.get('experimentName')
    if not experimentTag:
        experimentTag = datetime.now().strftime("%Y%m%d_%H%M%S")

    contentType = request.content_type or ""

    if contentType.startswith("application/json"):
        try:
            payload = request.get_json(force=True)
            data = payload.get("data")
            if not isinstance(data, list):
                return jsonify({"error": "Invalid or missing 'data' list in JSON."}), 400

            filePath = os.path.join(clientDir, f"{experimentTag}.jsonl")
            with open(filePath, 'w', encoding='utf-8') as f:
                for entry in data:
                    f.write(json.dumps(entry) + '\n')

            relPath = os.path.relpath(filePath, TEMP_DIR)
            return jsonify({"status": "success", "saved": relPath}), 200

        except Exception as e:
            return jsonify({"error": f"JSON handling error: {str(e)}"}), 500

    elif contentType.startswith("text/csv"):
        try:
            filePath = os.path.join(clientDir, f"{experimentTag}.csv")
            csv_data = request.get_data(as_text=True)
            with open(filePath, 'w', encoding='utf-8') as f:
                f.write(csv_data)

            relPath = os.path.relpath(filePath, TEMP_DIR)
            return jsonify({"status": "success", "saved": relPath}), 200

        except Exception as e:
            return jsonify({"error": f"CSV save error: {str(e)}"}), 500

    else:
        return jsonify({"error": f"Unsupported content type: {contentType}"}), 415

#----------------------------------------------------------

@app.route('/data/<clientID>', methods=['GET'])
def retrieve_data(clientID):
    """
    Retrieves experimental data for a given client (node).

    Query Parameters:
      - experimentName: optional, specific name of the experiment (without extension)
      - format: optional, one of ["json", "jsonl", "csv"], defaults to detected extension or "json"
      - latest: optional flag, if "true" retrieves the most recent file for the client

    Example Usage (from MATLAB):
      - webread('http://localhost:5000/data/probeNode?experimentName=test01&format=json')
      - webread('http://localhost:5000/data/probeNode?latest=true')

    Example Usage (from Python):
      - requests.get('http://localhost:5000/data/probeNode?experimentName=test01&format=csv')
      - requests.get('http://localhost:5000/data/probeNode?latest=true')

    Returns:
      - 200: JSON containing the file contents
          - For JSON: {"status": "success", "format": "json", "data": <object>}
          - For JSONL: {"status": "success", "format": "jsonl", "data": [<dict>, ...]}
          - For CSV: {"status": "success", "format": "csv", "csv": "<raw_csv_text>"}
      - 404: If file or directory is not found
      - 400: If parameters are malformed
      - 500: On unexpected server errors

    Notes:
      - JSONL files will be returned as a list of dicts
      - CSV files are returned as a raw text string in the "csv" key (client must parse)
      - JSON files will be returned as-is in the "data" key
    """

    clientDir = os.path.join(TEMP_DIR, clientID)
    if not os.path.isdir(clientDir):
        return jsonify({"error": f"No data found for client '{clientID}'"}), 404

    # Handle latest flag
    if request.args.get("latest", "false").lower() == "true":
        fileList = sorted(
            glob.glob(os.path.join(clientDir, "*.*")),
            key=os.path.getmtime,
            reverse=True
        )
        if not fileList:
            return jsonify({"error": f"No files available for client '{clientID}'"}), 404
        filePath = fileList[0]
    else:
        # Otherwise, require experimentName
        experimentTag = request.args.get("experimentName")
        if not experimentTag:
            return jsonify({"error": "Missing 'experimentName' or 'latest=true'"}), 400

        # Determine format
        requestedFormat = request.args.get("format", "").lower()
        if requestedFormat not in ["", "csv", "json", "jsonl"]:
            return jsonify({"error": f"Invalid format requested: {requestedFormat}"}), 400

        # Search for file
        candidates = []
        if requestedFormat:
            candidates = glob.glob(os.path.join(clientDir, f"{experimentTag}.{requestedFormat}"))
        else:
            # Try all known types
            for ext in ["csv", "json", "jsonl"]:
                candidates.extend(glob.glob(os.path.join(clientDir, f"{experimentTag}.{ext}")))
        if not candidates:
            return jsonify({"error": f"No matching file for experiment '{experimentTag}'"}), 404

        # If multiple candidates, pick the most recently modified file
        filePath = max(candidates, key=os.path.getmtime)
        filePath = candidates[0]  # use first match

    # Return content
    try:
        _, ext = os.path.splitext(filePath)
        ext = ext.lower()

        if ext == ".json":
            with open(filePath, 'r', encoding='utf-8') as f:
                data = json.load(f)
            return jsonify({"status": "success", "format": "json", "data": data}), 200

        elif ext == ".jsonl":
            with open(filePath, 'r', encoding='utf-8') as f:
                lines = [json.loads(line.strip()) for line in f if line.strip()]
            return jsonify({"status": "success", "format": "jsonl", "data": lines}), 200

        elif ext == ".csv":
            with open(filePath, 'r', encoding='utf-8') as f:
                csvText = f.read()
            return jsonify({"status": "success", "format": "csv", "csv": csvText}), 200

        else:
            return jsonify({"error": f"Unsupported file extension '{ext}'"}), 415

    except Exception as e:
        return jsonify({"error": f"Failed to read file: {str(e)}"}), 500

#----------------------------------------------------------

@app.route('/data', methods=['GET'])
def list_available_experiments():
    """
    Lists all available experiment data grouped by clientID (node).

    This endpoint scans the tempRestData directory for all known clients and
    returns a dictionary mapping each clientID to the list of saved experiment
    data files (CSV, JSON, JSONL).

    Example Usage (from MATLAB):
      - webread('http://localhost:5000/data')

    Example Usage (from Python):
      - requests.get('http://localhost:5000/data').json()

    Returns:
      - 200: JSON object of the form:
          {
              "probeNode": ["20240727_121503.csv", "waveTest01.jsonl"],
              "waveGenNode": ["testPulse01.csv"],
              ...
          }

      - 404: If no data directory exists or it is empty

    Notes:
      - This endpoint does not return the file contents, only filenames.
      - Files are returned relative to their clientID subdirectory.
      - The tempRestData directory is cleared on server start, so only data from the current session is available.
    """

    experimentIndex = {}

    if not os.path.exists(TEMP_DIR):
        return jsonify({"error": "No experiment data directory found."}), 404

    for clientID in os.listdir(TEMP_DIR):
        clientPath = os.path.join(TEMP_DIR, clientID)
        if os.path.isdir(clientPath):
            files = []
            for ext in SUPPORTED_EXTENSIONS:
                files.extend([os.path.basename(f) for f in glob.glob(os.path.join(clientPath, f"*{ext}"))])
            if files:
                experimentIndex[clientID] = sorted(files)
    if not experimentIndex:
        return jsonify({"message": "No experiment data available."}), 404

    return jsonify(experimentIndex), 200

#----------------------------------------------------------

@app.route('/health', methods=['GET'])
def health():
    """
    Returns server health and runtime metadata.

    This endpoint provides a basic status check for the REST API server,
    along with useful runtime metrics like server uptime, number of
    registered clients (nodes that have posted data), and total files
    stored under tempRestData.

    Example Usage (from MATLAB):
      - webread('http://localhost:5000/health')

    Example Usage (from Python):
      - requests.get('http://localhost:5000/health').json()

    Returns:
      - 200: JSON response of the form:
        {
          "status": "online",
          "uptime": "00:15:02",
          "stored_clients": 3,
          "total_files": 12
        }

    Notes:
      - `stored_clients` counts subfolders in tempRestData/
      - `total_files` includes all experiment files (.csv, .jsonl, etc.)
      - This endpoint is lightweight and does not scan file contents
    """

    now = datetime.now()
    uptimeDelta = now - LAUNCH_TIME
    uptimeStr = str(uptimeDelta).split('.')[0]  # Format as [D day[s], ]HH:MM:SS (may include days if uptime > 24h)

    # Count client subdirectories
    if os.path.exists(TEMP_DIR):
        clientDirs = [d for d in os.listdir(TEMP_DIR)
                      if os.path.isdir(os.path.join(TEMP_DIR, d))]
        numClients = len(clientDirs)

        # Count total files in all subdirs
        totalFiles = sum(
            len(files)
            for d in clientDirs
            for _, _, files in os.walk(os.path.join(TEMP_DIR, d))
        )
    else:
        numClients = 0
        totalFiles = 0

    return jsonify({
        "status": "online",
        "uptime": uptimeStr,
        "stored_clients": numClients,
        "total_files": totalFiles
    }), 200

#----------------------------------------------------------

if __name__ == "__main__":
    print("[REST API] Starting server on 0.0.0.0:5000 ...")
    app.run(host="0.0.0.0", port=5000)
