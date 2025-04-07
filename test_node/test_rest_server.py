from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/status', methods=['GET'])
def status():
    return jsonify({"node": "jetson_node", "status": "OK", "message": "System nominal"})

@app.route('/metadata', methods=['GET'])
def metadata():
    return jsonify({"node": "jetson_node", "sensors": ["camera", "imu"], "actuators": ["motor"]})

@app.route('/configure', methods=['POST'])
def configure():
    data = request.json
    print(f"[jetson_node] Configuration received: {data}")
    return jsonify({"success": True, "received": data})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)  # Listen on all interfaces so master can reach it
