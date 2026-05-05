"""
MyNodeManager.py

Replace this docstring with a description of what hardware this node owns,
what hasSensor / hasActuator flags it requires, and the interface used
(NI-DAQ analog voltage, GPIO digital/PWM, serial port, etc.).

One node per physical hardware interface:
    A single hardware interface (DAQ device, serial port, GPIO connection)
    cannot be shared between two node processes — the driver only allows one
    connection at a time. If you need to read from multiple sensors AND drive
    an actuator that all connect to the same interface, they must all live in
    one node class (hasSensor=True AND hasActuator=True). Only split into
    separate nodes if they use separate physical devices.

Calibration:
    Describe what Calibrate commands this node accepts and what they produce.
    (e.g. bias collection, gain fitting, lookup table construction)

Run:
    Describe what handle_run does and what post-processing enter_post_proc applies.

Required cfg["hardware"] fields:
    List the fields this node reads from the hardware section of its config JSON.
"""

import json
import os
import time
import threading
import pickle
from typing import Any, Dict, Optional

# Uncomment the import that matches your hardware interface:
#
# NI-DAQ:
#   import nidaqmx
#   from nidaqmx.constants import AcquisitionType, TerminalConfiguration
#
# Serial port (pip install pyserial):
#   import serial
#
# Raspberry Pi GPIO (pip install RPi.GPIO  or  pip install gpiozero):
#   import RPi.GPIO as GPIO
#   # or: from gpiozero import LED, Button, PWMOutputDevice

import sys
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

from pythonCommon.ExperimentManager import ExperimentManager, State
from pythonCommon.CommClient import CommClient
from pythonCommon.RestClient import RestClient


class MyNodeManager(ExperimentManager):
    """
    Node-specific subclass of ExperimentManager.
    Implements the seven hardware methods for this node's physical interface.
    """

    def __init__(self, cfg: Dict[str, Any], comm: CommClient, rest: RestClient):
        # Set instance variables BEFORE calling super().__init__() because the
        # base class calls initialize_hardware() during construction.
        self.device         = None      # hardware interface object
        self.sample_rate    = None      # Hz — for polling/DAQ nodes
        self.is_collecting  = False
        self.raw_data       = []
        self.output_columns = []        # field names to keep; empty = keep all
        self.duration       = None      # seconds, set by configure_hardware
        self.bias_values    = None      # 1-D array of per-channel DC offsets
        self.stream_thread  = None      # background thread for GPIO/serial streaming
        self.stream_active  = False     # flag to stop the stream thread

        node_dir = os.path.dirname(os.path.abspath(__file__))
        self.log_dir          = os.path.join(node_dir, "myNodeLogs")
        self.calibration_file = os.path.join(node_dir, "myNodeCalibration.pkl")

        # Base class calls initialize_hardware() and transitions to IDLE.
        super().__init__(cfg, comm, rest)

        # Load saved calibration after base init (base may overwrite bias_table).
        if os.path.isfile(self.calibration_file):
            try:
                with open(self.calibration_file, "rb") as f:
                    saved = pickle.load(f)
                self.bias_values = saved.get("bias_values")
                self.log("INFO", "Calibration loaded.")
            except Exception as e:
                self.log("WARN", f"Could not load calibration file: {e}")
        else:
            self.log("WARN", "No calibration file found. Run calibration before first experiment.")

        self.log("INFO", "MyNodeManager initialized.")

    # ── Hardware lifecycle ────────────────────────────────────────────────────

    def initialize_hardware(self, cfg: Dict[str, Any]) -> None:
        """
        Open and configure the hardware interface for this node.
        Called once at BOOT by the base class constructor, and again after
        ERROR recovery (stopHardware reinit path).

        Load any required model or lookup files here so that ERROR recovery
        also reloads them.

        Choose the pattern that matches your hardware type.
        """
        self.is_collecting = False

        # ── Option A: NI-DAQ analog voltage ───────────────────────────────────
        #
        # IMPORTANT: two nodes cannot share one physical DAQ device.
        # nidaqmx only allows one Task per device channel at a time.
        # If multiple sensors and actuators share the same device,
        # add all channels to THIS node (hasSensor=True, hasActuator=True).
        #
        # Input (sensor) task:
        #   self.sample_rate   = cfg["hardware"]["sampleRate"]
        #   self.device        = nidaqmx.Task()
        #   self.device.ai_channels.add_ai_voltage_chan(
        #       f"{cfg['hardware']['daqDevice']}/{cfg['hardware']['sensorChannel']}")
        #   self.device.timing.cfg_samp_clk_timing(
        #       self.sample_rate, sample_mode=AcquisitionType.CONTINUOUS)
        #   self.log("INFO", f"NI-DAQ task ready at {self.sample_rate} Hz.")
        #
        # For a node with both input and output channels, use two separate Tasks
        # (one for AI, one for AO) and start/stop them together. nidaqmx does
        # not require a combined session the way MATLAB's daq() does.
        #
        # Reading a finite block:
        #   samples = self.device.read(number_of_samples_per_channel=N)
        #   # returns a list (single channel) or list-of-lists (multi-channel)
        #
        # Writing to an output task:
        #   self.ao_task.write(signal_array)

        # ── Option B: Serial port (pyserial) ──────────────────────────────────
        #
        # Use for microcontrollers, instruments, or any device with a COM/tty port.
        #
        #   self.sample_rate = cfg["hardware"]["sampleRate"]
        #   self.device = serial.Serial(
        #       port     = cfg["hardware"]["port"],       # e.g. "COM3" or "/dev/ttyUSB0"
        #       baudrate = cfg["hardware"]["baudRate"],   # e.g. 9600
        #       timeout  = 1.0)
        #   self.log("INFO", f"Serial port {cfg['hardware']['port']} ready.")
        #
        # Reading a line (sensor returning ASCII):
        #   line = self.device.readline().decode("utf-8").strip()
        #   value = float(line)
        #
        # Writing a command (actuator control):
        #   self.device.write(b"SET 100\n")

        # ── Option C: Raspberry Pi GPIO (RPi.GPIO) ────────────────────────────
        #
        # The RPi.GPIO package must be installed: pip install RPi.GPIO
        # This runs only on a Raspberry Pi — not on a standard PC.
        #
        #   self.sample_rate = cfg["hardware"]["sampleRate"]
        #   GPIO.setmode(GPIO.BCM)
        #   GPIO.setup(cfg["hardware"]["sensorPin"],  GPIO.IN)
        #   GPIO.setup(cfg["hardware"]["outputPin"],  GPIO.OUT, initial=GPIO.LOW)
        #   self.log("INFO", "Raspberry Pi GPIO interface ready.")
        #
        # Digital read:
        #   val = GPIO.input(cfg["hardware"]["sensorPin"])   # 0 or 1
        #
        # Digital write:
        #   GPIO.output(cfg["hardware"]["outputPin"], GPIO.HIGH)
        #
        # PWM output (e.g. motor speed):
        #   self.pwm = GPIO.PWM(cfg["hardware"]["pwmPin"], frequency_hz)
        #   self.pwm.start(duty_cycle_percent)   # 0–100
        #   self.pwm.ChangeDutyCycle(50)

        # ── Option D: gpiozero (higher-level Pi GPIO library) ─────────────────
        #
        #   from gpiozero import LED, Button, PWMOutputDevice, MCP3008
        #   self.output = LED(cfg["hardware"]["outputPin"])
        #   self.sensor = Button(cfg["hardware"]["sensorPin"])
        #   self.pwm    = PWMOutputDevice(cfg["hardware"]["pwmPin"])
        #
        # Read digital input:
        #   val = self.sensor.is_pressed   # True / False
        #
        # Drive digital output:
        #   self.output.on()   # or .off()
        #
        # Drive PWM:
        #   self.pwm.value = 0.5   # 0.0–1.0

        raise NotImplementedError("initialize_hardware not implemented.")

    def stop_hardware(self) -> None:
        """
        Safe-stop all outputs and halt data collection.
        Called on Abort, Reset, and entry into IDLE from any active state.
        """
        self.is_collecting = False
        self.stream_active = False
        self.log("INFO", "stop_hardware: halting hardware interface.")

        # NI-DAQ pattern:
        #   try:
        #       if self.device and not self.device.is_task_done():
        #           self.device.stop()
        #   except Exception as e:
        #       self.log("WARN", f"stop_hardware error: {e}")
        #   # After ERROR recovery, recreate the task to reset driver state.
        #   if self.prev_state == State.ERROR:
        #       try:
        #           self.device.close()
        #       except Exception:
        #           pass
        #       self.initialize_hardware(self.cfg)
        #       self.log("INFO", "stop_hardware: NI-DAQ task recreated after ERROR recovery.")

        # Serial port pattern:
        #   try:
        #       self.device.write(b"STOP\n")
        #   except Exception as e:
        #       self.log("WARN", f"stop_hardware serial error: {e}")

        # RPi.GPIO pattern:
        #   GPIO.output(self.cfg["hardware"]["outputPin"], GPIO.LOW)

        raise NotImplementedError("stop_hardware not implemented.")

    def shutdown_hardware(self) -> None:
        """
        Release all hardware resources on clean node exit.
        Called by ExperimentManager.shutdown() before disconnecting MQTT.
        """
        self.is_collecting   = False
        self.stream_active   = False
        self.experiment_data = []
        self.raw_data        = []
        self.log("INFO", "shutdown_hardware: releasing hardware interface.")

        # NI-DAQ pattern:
        #   try:
        #       self.device.stop()
        #       self.device.close()
        #   except Exception as e:
        #       self.log("WARN", f"shutdown_hardware error: {e}")

        # Serial port pattern:
        #   try:
        #       self.device.write(b"STOP\n")
        #       self.device.close()
        #   except Exception as e:
        #       self.log("WARN", f"shutdown_hardware error: {e}")

        # RPi.GPIO pattern:
        #   try:
        #       GPIO.output(self.cfg["hardware"]["outputPin"], GPIO.LOW)
        #       GPIO.cleanup()
        #   except Exception as e:
        #       self.log("WARN", f"shutdown_hardware error: {e}")

        raise NotImplementedError("shutdown_hardware not implemented.")

    # ── FSM method implementations ────────────────────────────────────────────

    def configure_hardware(self, params: Dict[str, Any]) -> bool:
        """
        Validate experiment parameters against hardware limits.
        Return False (with a WARN log) on any failed check; True when all pass.
        Do NOT transition state here — the base class handles that.

        Args:
            params: Experiment parameter dict from the Configure command.

        Returns:
            True if parameters are valid and safe to run.
        """
        if "duration" not in params or not isinstance(params["duration"], (int, float)) \
                or params["duration"] <= 0:
            self.log("WARN", "configure_hardware: duration missing or invalid.")
            return False

        # Optional: restrict which output columns are saved to CSV / REST.
        if "outputColumns" in params and params["outputColumns"]:
            self.output_columns = list(params["outputColumns"])
        else:
            self.output_columns = []

        # Optional: allow control node to override sample rate per experiment.
        # Only applies to DAQ/polling nodes — remove for event-driven hardware.
        # if "sampleRate" in params and params["sampleRate"] > 0:
        #     self.sample_rate = params["sampleRate"]
        #     self.log("INFO", f"Sample rate overridden to {self.sample_rate} Hz.")

        # Add your hardware-limit checks here. Pattern:
        #   if params.get("myParam", 0) > MAX_VALUE:
        #       self.log("WARN", f"myParam {params['myParam']} exceeds limit {MAX_VALUE}.")
        #       return False

        self.log("INFO", f"Config valid: duration={params['duration']:.1f} s.")
        return True

    def setup_current_experiment(self) -> None:
        """
        Optional override — called by the base class at CONFIGUREVALIDATE.
        Use this to reset per-run buffers and read per-experiment params from
        self.experiment_spec before the run starts. Always call super() first.
        """
        super().setup_current_experiment()

        if "experiments" in self.experiment_spec.get("params", {}):
            current = self.experiment_spec["params"]["experiments"][self.current_experiment_index]
        else:
            current = self.experiment_spec.get("params", {})

        self.duration = current.get("duration")
        self.raw_data = []
        self.is_collecting = False

        # Read any other per-run params you need here.

    def handle_calibrate(self, cmd: Dict[str, Any]) -> None:
        """
        Calibration routine. Common pattern: collect point-by-point readings,
        finalize on params["finished"] = True, save to self.calibration_file.

        Bias collection example (blocking, NI-DAQ):
            N = round(self.sample_rate * 1.0)
            samples = self.device.read(number_of_samples_per_channel=N)
            # samples is a list (single ch) or list-of-lists (multi-ch)
            self.bias_values = sum(samples) / len(samples)
            self._save_calibration()
            self.transition(State.IDLE)

        Bias collection example (serial/GPIO polling):
            N = round(self.sample_rate * 1.0)
            buf = []
            for _ in range(N):
                line = self.device.readline().decode().strip()
                buf.append(float(line))
                time.sleep(1 / self.sample_rate)
            self.bias_values = sum(buf) / len(buf)
            self._save_calibration()
            self.transition(State.IDLE)

        Point-by-point calibration (any interface):
            known = cmd["params"]["knownValue"]
            measured = <read one sample>
            self._calib_buffer.append((known, measured))
            if cmd["params"].get("finished"):
                # fit e.g. numpy polyfit, save, transition
                self.transition(State.IDLE)
        """
        raise NotImplementedError("handle_calibrate not implemented.")

    def handle_test(self, cmd: Dict[str, Any]) -> None:
        """
        Live sensor or actuator diagnostics.

        IMPORTANT: handle_test must return immediately — do NOT block here.
        A blocking loop prevents the MQTT thread from processing a Reset
        command, leaving the node stuck in TESTINGSENSOR.

        Use a background thread for GPIO/serial streaming:
            self.stream_active = True
            self.stream_thread = threading.Thread(
                target=self._stream_loop, daemon=True)
            self.stream_thread.start()
            # handle_test returns; _stream_loop runs in background.
            # It checks self.stream_active and self.state to self-stop.

        NI-DAQ continuous acquisition (background thread, same idea):
            self.stream_active = True
            self.stream_thread = threading.Thread(
                target=self._daq_stream_loop, daemon=True)
            self.stream_thread.start()

        Actuator test (short timed run, background thread):
            def run_actuator():
                self.device.write(signal)
                time.sleep(duration)
                self.stop_hardware()
                self.transition(State.IDLE)
            threading.Thread(target=run_actuator, daemon=True).start()
        """
        raise NotImplementedError("handle_test not implemented.")

    def handle_run(self, cmd: Dict[str, Any]) -> None:
        """
        Execute the main experiment. Check self.abort_requested frequently
        so the Abort command is processed promptly during long acquisitions.

        NI-DAQ chunked acquisition (abort-safe):
            target_samples = round(self.duration * self.sample_rate)
            chunk_size     = max(1, round(0.25 * self.sample_rate))
            collected      = 0
            self.raw_data  = []
            self.is_collecting = True
            while collected < target_samples:
                if self.abort_requested or self.state != State.RUNNING:
                    self.is_collecting = False
                    self.raw_data = []
                    return
                n = min(chunk_size, target_samples - collected)
                chunk = self.device.read(number_of_samples_per_channel=n)
                self.raw_data.extend(chunk)
                collected += n
            self.is_collecting = False
            self.transition(State.POSTPROC)

        Serial / GPIO polling loop (abort-safe, drift-corrected):
            target_samples = round(self.duration * self.sample_rate)
            interval       = 1.0 / self.sample_rate
            self.raw_data  = []
            self.is_collecting = True
            for _ in range(target_samples):
                t0 = time.perf_counter()
                if self.abort_requested or self.state != State.RUNNING:
                    self.is_collecting = False
                    self.raw_data = []
                    return
                line = self.device.readline().decode().strip()
                self.raw_data.append(float(line))
                elapsed = time.perf_counter() - t0
                time.sleep(max(0.0, interval - elapsed))
            self.is_collecting = False
            self.transition(State.POSTPROC)
        """
        raise NotImplementedError("handle_run not implemented.")

    # ── Post-processing (optional override) ───────────────────────────────────

    def enter_post_proc(self) -> None:
        """
        Optional override — called automatically by the base class when the FSM
        enters POSTPROC. Override here to process self.raw_data before the base
        class saves the CSV and POSTs to REST.

        Typical pipeline:
            1. Apply bias subtraction, calibration, filtering to self.raw_data
            2. Build self.experiment_data as a list of dicts, one per sample:
                   self.experiment_data = [
                       {"time": t, "value": v, ...}
                       for t, v in zip(time_array, processed_array)
                   ]
            3. Apply output_columns filter (optional — restrict saved fields)
            4. Call super().enter_post_proc() — MUST be last

        If you do not need custom post-processing, delete this method entirely.
        The base class will save whatever is already in self.experiment_data.
        """
        # Replace with your processing, then always end with:
        super().enter_post_proc()

    # ── Private helpers ───────────────────────────────────────────────────────

    def _stream_loop(self) -> None:
        """
        Background thread for GPIO/serial live streaming during handleTest.
        Reads one sample per interval, publishes to MQTT, and self-stops
        when self.stream_active is cleared (by stop_hardware or Reset).
        """
        interval = 1.0 / self.sample_rate if self.sample_rate else 0.1
        while self.stream_active and self.state == State.TESTINGSENSOR:
            try:
                t0 = time.perf_counter()

                # Replace with your actual read:
                # value = float(self.device.readline().decode().strip())
                value = 0.0

                reading = {
                    "value": value,
                    "timestamp": __import__("datetime").datetime.now()
                                    .strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
                }
                self.comm.comm_publish(
                    self.comm.get_full_topic("data"),
                    json.dumps(reading))

                elapsed = time.perf_counter() - t0
                time.sleep(max(0.0, interval - elapsed))
            except Exception as e:
                self.log("WARN", f"_stream_loop error: {e}")

        self.log("INFO", "_stream_loop: stopped.")

    def _save_calibration(self) -> None:
        """Persists current calibration state to self.calibration_file."""
        os.makedirs(os.path.dirname(self.calibration_file), exist_ok=True)
        with open(self.calibration_file, "wb") as f:
            pickle.dump({"bias_values": self.bias_values}, f)
        self.log("INFO", f"Calibration saved to {self.calibration_file}.")
