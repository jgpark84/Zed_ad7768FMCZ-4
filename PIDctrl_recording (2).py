#!/usr/bin/env python3
import os
import sys
import time
import math
import subprocess
import threading
import signal
import queue
from collections import deque

import numpy as np
import pyqtgraph as pg

from PySide6.QtCore import QFile, QTimer
from PySide6.QtUiTools import QUiLoader
from PySide6.QtWidgets import QApplication, QVBoxLayout


# =============================================================================
# Board / FPGA constants
# =============================================================================

SSH_HOST = "ad7768"
REMOTE_STREAM_CMD = "python3 /root/control_stream_source.py"

# Raw recording path is independent of the control stream.
REMOTE_RECORD_DAEMON = "/root/ad7768_recordd_v6"
REMOTE_RECORD_CLIENT = "/root/ad7768_stream_client_v4"
RECORD_RING_FRAMES = 4096
RECORD_SPILL_DIR = "/root"
RECORD_SEGMENT_SECONDS = 60

BASE = 0x43C10000

REG_AVG_SHIFT = BASE + 0x014

CORDIC_REGS = {
    0: (BASE + 0x018, BASE + 0x01C),  # CORDIC0 X/Y
    1: (BASE + 0x020, BASE + 0x024),  # CORDIC1 X/Y
    2: (BASE + 0x028, BASE + 0x02C),  # CORDIC2 X/Y
}

PID0_BASE = BASE + 0x040
PID_CTRL      = PID0_BASE + 0x00
PID_INPUT_SEL = PID0_BASE + 0x04
PID_SETPOINT  = PID0_BASE + 0x10
PID_KP        = PID0_BASE + 0x14
PID_KI        = PID0_BASE + 0x18
PID_KD        = PID0_BASE + 0x1C
PID_OUT_MIN   = PID0_BASE + 0x20
PID_OUT_MAX   = PID0_BASE + 0x24

AO_BASE = [
    BASE + 0x140,
    BASE + 0x160,
    BASE + 0x180,
    BASE + 0x1A0,
]

REG_APPLY = BASE + 0x1C0

# AO block offsets
AO_SOURCE = 0x00
AO_MANUAL = 0x04
AO_GAIN   = 0x08
AO_OFFSET = 0x0C
AO_MIN    = 0x10
AO_MAX    = 0x14

# ao_scaler does: (source * gain >> 16) + offset
#
# Manual source is already a 16-bit DAC code, so it must pass through:
#     gain = 1.0 Q16.16 = 0x00010000, offset = 0
#
# PID source is signed32 and is mapped to unsigned 16-bit DAC space:
#     gain raw = 1  -> source / 65536
#     offset = user AO offset (normally 32768)
AO_GAIN_MANUAL = 0x00010000
AO_GAIN_PID = 1

# No dedicated AO min/max widgets currently exist in the UI.
FIXED_AO_MIN = 0
FIXED_AO_MAX = 65535

FRAME_BYTES = 32

CONTROL_DTYPE = np.dtype([
    ("avg0",   "<i4"),
    ("avg1",   "<i4"),
    ("avg2",   "<i4"),
    ("avg3",   "<i4"),
    ("phase0", "<i4"),
    ("phase1", "<i4"),
    ("ao0",    "<u2"),
    ("ao1",    "<u2"),
    ("ao2",    "<u2"),
    ("ao3",    "<u2"),
])

BAM_TO_RAD = 2.0 * np.pi / (2 ** 32)
RAD_TO_BAM = (2 ** 32) / (2.0 * np.pi)

GUI_UPDATE_MS = 33
PHASE_HISTORY_SAMPLES = 10000


# =============================================================================
# Utility conversion
# =============================================================================

def u32(value: int) -> int:
    """Return value as a 32-bit two's-complement unsigned integer."""
    return int(value) & 0xFFFFFFFF


def q16_16(value: float) -> int:
    """Floating-point coefficient -> signed Q16.16 register bit pattern."""
    raw = int(round(float(value) * 65536.0))
    if raw < -0x80000000 or raw > 0x7FFFFFFF:
        raise ValueError("Q16.16 value is outside signed32 range")
    return u32(raw)


def rad_to_bam32(rad: float) -> int:
    """
    Radians -> signed32 BAM bit pattern.
    Phase wraps naturally to [-pi, pi).
    """
    wrapped = (float(rad) + math.pi) % (2.0 * math.pi) - math.pi
    signed = int(round(wrapped * RAD_TO_BAM))
    if signed >= 2**31:
        signed -= 2**32
    if signed < -(2**31):
        signed += 2**32
    return u32(signed)


def wrapped_phase_error(setpoint_rad, phase_rad):
    return (setpoint_rad - phase_rad + np.pi) % (2.0 * np.pi) - np.pi


# =============================================================================
# GUI physical-unit conversion
# =============================================================================

ADC_COUNTS_FULL_SCALE = float(2 ** 23)  # signed 24-bit ADC positive full-scale code
DAC_CODE_MAX = 65535

def adc_counts_to_physical(counts, vref):
    """Signed ADC counts -> volts, with AIVref interpreted as +full-scale volts."""
    return np.asarray(counts, dtype=np.float64) * (float(vref) / ADC_COUNTS_FULL_SCALE)

def ao_abs_to_cts(value, out_min, out_max):
    """Absolute physical AO value -> unsigned 16-bit DAC code."""
    lo = float(out_min)
    hi = float(out_max)
    if not hi > lo:
        raise ValueError("AO physical max must be greater than min")
    code = int(round((float(value) - lo) * DAC_CODE_MAX / (hi - lo)))
    return max(0, min(DAC_CODE_MAX, code))

def ao_cts_to_abs(code, out_min, out_max):
    """Unsigned 16-bit DAC code -> absolute physical AO value."""
    lo = float(out_min)
    hi = float(out_max)
    if not hi > lo:
        return float('nan')
    return lo + float(code) * (hi - lo) / DAC_CODE_MAX

def pid_limit_from_ao_code(code, center_code):
    """AO code limit -> PID signed32 domain for AO_GAIN_PID=1.

    ao_scaler: AO_code = (PID * 1 >> 16) + center_code
    therefore PID ~= (AO_code - center_code) * 65536.
    """
    raw = (int(code) - int(center_code)) * 65536
    return max(-2147483648, min(2147483647, raw))


# =============================================================================
# Persistent SSH control stream
# =============================================================================

class SSHControlStream:
    """
    One persistent SSH session.

    Board:
        FPGA -> IIO DMA -> /root/control_stream_source.py

    PC:
        this background thread continuously drains SSH stdout.

    GUI never requests N samples. It periodically takes every complete frame
    that has arrived since the previous GUI refresh.
    """

    def __init__(self, host=SSH_HOST,
                 remote_command=REMOTE_STREAM_CMD,
                 max_pc_backlog_bytes=FRAME_BYTES * 262144):
        self.host = host
        self.remote_command = remote_command
        self.max_pc_backlog_bytes = max_pc_backlog_bytes

        self.proc = None
        self.thread = None
        self.running = False

        self._lock = threading.Lock()
        self._buffer = bytearray()
        self._remainder = bytearray()

    def start(self):
        if self.running:
            return

        self.running = True
        self.proc = subprocess.Popen(
            ["ssh", "-T", self.host, self.remote_command],
            stdin=None,
            stdout=subprocess.PIPE,
            stderr=None,     # keep SSH errors/password prompts visible
            bufsize=0,
        )

        self.thread = threading.Thread(target=self._reader_loop, daemon=True)
        self.thread.start()

    def _reader_loop(self):
        try:
            while self.running and self.proc and self.proc.stdout:
                data = self.proc.stdout.read(128 * 1024)
                if not data:
                    break

                self._remainder.extend(data)

                usable = (len(self._remainder) // FRAME_BYTES) * FRAME_BYTES
                if usable == 0:
                    continue

                aligned = bytes(self._remainder[:usable])
                del self._remainder[:usable]

                with self._lock:
                    self._buffer.extend(aligned)

                    # GUI may stall briefly. Keep a bounded backlog and discard
                    # oldest complete frames instead of letting memory grow forever.
                    excess = len(self._buffer) - self.max_pc_backlog_bytes
                    if excess > 0:
                        drop = ((excess + FRAME_BYTES - 1) // FRAME_BYTES) * FRAME_BYTES
                        del self._buffer[:drop]

        finally:
            self.running = False

    def take_all(self):
        with self._lock:
            if not self._buffer:
                return np.empty(0, dtype=CONTROL_DTYPE)

            raw = bytes(self._buffer)
            self._buffer.clear()

        return np.frombuffer(raw, dtype=CONTROL_DTYPE).copy()

    def stop(self):
        self.running = False

        if self.proc is not None:
            try:
                self.proc.terminate()
            except Exception:
                pass

        if self.thread is not None:
            self.thread.join(timeout=1.0)

        self.proc = None
        self.thread = None


# =============================================================================
# Remote AXI register writes
# =============================================================================

def devmem_command(address, value):
    return f"busybox devmem 0x{address:08X} 32 0x{u32(value):08X}"


def ssh_write_registers(writes):
    """
    Perform infrequent configuration writes over a separate SSH command.
    Streaming remains on its own persistent SSH connection.
    """
    commands = [devmem_command(addr, val) for addr, val in writes]
    remote = " && ".join(commands)

    result = subprocess.run(
        ["ssh", "-T", SSH_HOST, remote],
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(f"SSH register write failed: return code {result.returncode}")


# =============================================================================
# GUI
# =============================================================================

class PIDControllerGUI:
    def __init__(self, ui_path):
        loader = QUiLoader()
        ui_file = QFile(ui_path)

        if not ui_file.open(QFile.ReadOnly):
            raise RuntimeError(f"Could not open UI file: {ui_path}")

        self.window = loader.load(ui_file)
        ui_file.close()

        if self.window is None:
            raise RuntimeError("Qt Designer UI load failed")

        # ---------------------------------------------------------------------
        # Runtime widget setup
        # ---------------------------------------------------------------------

        # PID Enable is used as a toggle state, but application happens only
        # when Apply is pressed.
        self.window.PIDON.setCheckable(True)
        self.window.PIDON.setChecked(False)
        self._update_pid_button_text()

        # Setpoint is interpreted as radians for PID0 phase mode.
        self.window.Setpoint.setRange(-math.pi, math.pi)
        self.window.Setpoint.setDecimals(6)
        self.window.Setpoint.setSingleStep(0.01)

        # PID coefficients are entered as real numbers and converted to Q16.16.
        for w in (self.window.PIDKp, self.window.PIDKi, self.window.PIDKd):
            w.setRange(-32768.0, 32767.999984)
            w.setDecimals(6)
            w.setSingleStep(0.01)

        # AO physical calibration / command values.
        # PIDoutmin/PIDoutmax are used as the physical full-scale endpoints
        # for the selected AO channel. AOmanual and AOoffset are entered in
        # the same physical unit (normally volts).
        for w in (self.window.PIDoutmin, self.window.PIDoutmax,
                  self.window.AOmanual, self.window.AOoffset):
            w.setRange(-1.0e9, 1.0e9)
            w.setDecimals(6)
            w.setSingleStep(0.1)

        # Do not invent an AO range. If min == max, Apply will ask the user
        # to enter the actual physical output range.

        # AI Vref: current UI used AIVrev by mistake; accept either spelling.
        self.ai_vref_widget = getattr(self.window, "AIVref", None)
        if self.ai_vref_widget is None:
            self.ai_vref_widget = getattr(self.window, "AIVrev", None)
        if self.ai_vref_widget is not None:
            self.ai_vref_widget.setRange(1.0e-9, 1.0e9)
            self.ai_vref_widget.setDecimals(6)
            self.ai_vref_widget.setSingleStep(0.1)
            if self.ai_vref_widget.value() <= 0:
                self.ai_vref_widget.setValue(1.0)
            self.ai_vref_widget.setToolTip(
                "ADC +full-scale voltage: +2^23 counts corresponds to +Vref"
            )

        # Clarify the physical-unit meaning of the existing controls.
        try:
            self.window.label_17.setText("AO min")
            self.window.label_18.setText("AO max")
            self.window.label_20.setText("AO center/offset")
            self.window.label_6.setText("AO manual")
            self.window.label_26.setText("AI Vref")
        except Exception:
            pass

        # AO gain is selected internally:
        # Manual -> 1.0 (0x00010000), PID -> raw 1 for signed32-to-u16 mapping.
        self.window.AOgain.setEnabled(False)
        self.window.AOgain.setToolTip(
            "Automatic: Manual=1.0 pass-through, PID source=signed32 to u16 scaling"
        )

        # Current control DMA contains phase0/phase1 but not phase2.
        # CORDIC2 can still be configured; live phase plot is unavailable.
        self.window.statusbar.showMessage("Starting control stream...")

        # PIDOdis can truthfully show selected AO output, because AO0..3 are
        # actually in the control DMA. PID internal output is not streamed.
        try:
            self.window.label.setText("AO OUT")
        except Exception:
            pass

        self.window.PIDoutdis.setRange(0, 65535)

        # Looptime display is GUI refresh timing, not FPGA loop time.
        try:
            self.window.label_11.setText("GUI dt (ms)")
        except Exception:
            pass

        # ---------------------------------------------------------------------
        # pyqtgraph widgets inserted into the two Designer QFrames
        # ---------------------------------------------------------------------

        self.iq_plot = pg.PlotWidget()
        iq_layout = QVBoxLayout(self.window.IQgraph)
        iq_layout.setContentsMargins(0, 0, 0, 0)
        iq_layout.addWidget(self.iq_plot)

        self.iq_plot.setLabel("bottom", "I", units="V")
        self.iq_plot.setLabel("left", "Q", units="V")
        self.iq_plot.showGrid(x=True, y=True, alpha=0.2)
        self.iq_plot.setAspectLocked(False)
        self.iq_curve = self.iq_plot.plot()

        self.phase_plot = pg.PlotWidget()
        phase_layout = QVBoxLayout(self.window.Phasechart)
        phase_layout.setContentsMargins(0, 0, 0, 0)
        phase_layout.addWidget(self.phase_plot)

        self.phase_plot.setLabel("bottom", "Sample")
        self.phase_plot.setLabel("left", "Phase", units="rad")
        self.phase_plot.showGrid(x=True, y=True, alpha=0.2)
        self.phase_curve = self.phase_plot.plot()

        self.phase_history = deque(maxlen=PHASE_HISTORY_SAMPLES)

        # ---------------------------------------------------------------------
        # Non-blocking command worker state
        # ---------------------------------------------------------------------

        self.command_results = queue.Queue()
        self.command_busy = False

        # ---------------------------------------------------------------------
        # Signals
        # ---------------------------------------------------------------------

        self.window.PIDON.clicked.connect(self._update_pid_button_text)
        self.window.apply.clicked.connect(self.apply_settings)
        self.window.PIDreset.clicked.connect(self.reset_pid)
        self.window.LoadRms.clicked.connect(self.load_rms)

        # Raw DMA recording is independent of the control/monitor stream.
        # Each REC start restarts the board recorder daemon using the currently
        # selected REC_avg, then launches the PC receiver as a separate process.
        self.record_proc = None
        self.record_transition = False
        self.record_results = queue.Queue()
        self.window.pushButton.setEnabled(True)
        self.window.pushButton.setCheckable(False)
        self.window.pushButton.setText("REC Start")
        self.window.pushButton.setToolTip(
            "Start/stop raw-DMA recording. REC_avg is applied only when recording starts."
        )
        self.window.pushButton.clicked.connect(self.toggle_recording)

        try:
            self.window.REC_path.setToolTip(
                "PC output directory for recording segments (for example: recordings/run01)"
            )
        except Exception:
            pass

        # ---------------------------------------------------------------------
        # Persistent stream
        # ---------------------------------------------------------------------

        self.stream = SSHControlStream()
        self.stream.start()

        self.last_gui_update = time.perf_counter()

        self.timer = QTimer(self.window)
        self.timer.timeout.connect(self.update_gui)
        self.timer.start(GUI_UPDATE_MS)

        self.window.destroyed.connect(self.shutdown)

    # -------------------------------------------------------------------------
    # Configuration
    # -------------------------------------------------------------------------

    def _update_pid_button_text(self):
        if self.window.PIDON.isChecked():
            self.window.PIDON.setText("PID Enabled")
        else:
            self.window.PIDON.setText("PID Disabled")

    def collect_apply_writes(self):
        # ComboBox order has been deliberately made equal to FPGA encoding.
        avg_shift = self.window.comboBox.currentIndex()

        cordic_index = self.window.Cordicsel.currentIndex()
        i_ch = self.window.Ichansel.currentIndex()
        q_ch = self.window.Qchansel.currentIndex()

        pid_input_sel = self.window.PIDinsel.currentIndex()
        pid_enable = 1 if self.window.PIDON.isChecked() else 0

        # PID0 phase setpoint: UI radians -> signed32 BAM.
        setpoint_reg = rad_to_bam32(self.window.Setpoint.value())

        kp_reg = q16_16(self.window.PIDKp.value())
        ki_reg = q16_16(self.window.PIDKi.value())
        kd_reg = q16_16(self.window.PIDKd.value())

        # Existing Out_min/Out_max spin boxes now define the selected AO's
        # physical full-scale range. AO manual and AO center/offset are entered
        # directly in that physical unit.
        ao_phys_min = float(self.window.PIDoutmin.value())
        ao_phys_max = float(self.window.PIDoutmax.value())
        if not ao_phys_max > ao_phys_min:
            raise ValueError("Set AO physical min/max first (max must be > min)")

        ao_index = self.window.AOsel.currentIndex()
        ao_source = self.window.AO_source.currentIndex()
        ao_base = AO_BASE[ao_index]

        ao_manual_phys = float(self.window.AOmanual.value())
        ao_center_phys = float(self.window.AOoffset.value())

        ao_manual = ao_abs_to_cts(ao_manual_phys, ao_phys_min, ao_phys_max)
        ao_center = ao_abs_to_cts(ao_center_phys, ao_phys_min, ao_phys_max)

        # PID internal limits are derived from the physical AO endpoints.
        # With AO_GAIN_PID=1, signed32 PID maps to signed16 DAC delta counts.
        pid_min = pid_limit_from_ao_code(0, ao_center)
        pid_max = pid_limit_from_ao_code(DAC_CODE_MAX, ao_center)

        if ao_source == 0:  # Manual: absolute physical value -> DAC code
            ao_gain_reg = AO_GAIN_MANUAL
            ao_offset_reg = 0
        else:               # PID: zero PID output -> requested physical center
            ao_gain_reg = AO_GAIN_PID
            ao_offset_reg = ao_center

        x_reg, y_reg = CORDIC_REGS[cordic_index]

        writes = [
            (REG_AVG_SHIFT, avg_shift),

            (x_reg, i_ch),
            (y_reg, q_ch),

            (PID_INPUT_SEL, pid_input_sel),
            (PID_SETPOINT, setpoint_reg),
            (PID_KP, kp_reg),
            (PID_KI, ki_reg),
            (PID_KD, kd_reg),
            (PID_OUT_MIN, u32(pid_min)),
            (PID_OUT_MAX, u32(pid_max)),
            (PID_CTRL, pid_enable),

            (ao_base + AO_SOURCE, ao_source),
            (ao_base + AO_MANUAL, ao_manual),
            (ao_base + AO_GAIN, ao_gain_reg),
            (ao_base + AO_OFFSET, ao_offset_reg),
            (ao_base + AO_MIN, FIXED_AO_MIN),
            (ao_base + AO_MAX, FIXED_AO_MAX),

            # Commit all shadow registers at once.
            (REG_APPLY, 1),
        ]

        return writes

    def _run_command_async(self, writes, success_message):
        """
        Run slow SSH/devmem work outside the Qt GUI thread.
        Results are returned through a thread-safe queue and consumed by update_gui().
        """
        if self.command_busy:
            self.window.statusbar.showMessage("Command already in progress", 2000)
            return

        self.command_busy = True
        self.window.apply.setEnabled(False)
        self.window.PIDreset.setEnabled(False)
        self.window.statusbar.showMessage("Sending command...")

        def worker():
            try:
                ssh_write_registers(writes)
                self.command_results.put((True, success_message))
            except Exception as e:
                self.command_results.put((False, str(e)))

        threading.Thread(target=worker, daemon=True).start()

    def _check_command_results(self):
        try:
            ok, message = self.command_results.get_nowait()
        except queue.Empty:
            return

        self.command_busy = False
        self.window.apply.setEnabled(True)
        self.window.PIDreset.setEnabled(True)

        if ok:
            self.window.statusbar.showMessage(message, 3000)
        else:
            self.window.statusbar.showMessage(f"Command failed: {message}", 8000)

    def apply_settings(self):
        try:
            writes = self.collect_apply_writes()
            ao_mode = (
                "Manual pass-through"
                if self.window.AO_source.currentIndex() == 0
                else "PID scaled"
            )
            self._run_command_async(writes, f"Apply complete ({ao_mode})")
        except Exception as e:
            self.window.statusbar.showMessage(f"Apply setup failed: {e}", 8000)

    def reset_pid(self):
        """
        PID reset is a separate toggle command and does not need APPLY.
        Preserve the current enable bit while asserting bit1.
        """
        enable = 1 if self.window.PIDON.isChecked() else 0
        value = enable | 0x2
        self._run_command_async(
            [(PID_CTRL, value)],
            "PID0 reset command sent"
        )

    # -------------------------------------------------------------------------
    # Raw DMA recording
    # -------------------------------------------------------------------------

    def _selected_rec_avg(self):
        """Parse the leading integer from items such as '1024 avg'."""
        text = self.window.REC_avg.currentText().strip()
        token = text.split()[0]
        value = int(token)
        if value < 1:
            raise ValueError("REC_avg must be >= 1")
        return value

    def _record_output_dir(self):
        path = self.window.REC_path.toPlainText().strip()
        if not path:
            path = "recordings"
        return os.path.abspath(os.path.expanduser(path))

    def _set_record_button(self, text, enabled=True):
        self.window.pushButton.setText(text)
        self.window.pushButton.setEnabled(enabled)

    def toggle_recording(self):
        if self.record_transition:
            return

        if self.record_proc is not None and self.record_proc.poll() is None:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        try:
            rec_avg = self._selected_rec_avg()
            out_dir = self._record_output_dir()
        except Exception as e:
            self.window.statusbar.showMessage(f"REC setup failed: {e}", 8000)
            return

        here = os.path.dirname(os.path.abspath(__file__))
        receiver = os.path.join(here, "ad7768_receiver_v9.py")
        if not os.path.isfile(receiver):
            self.window.statusbar.showMessage(
                f"REC start failed: missing {receiver}", 8000
            )
            return

        os.makedirs(out_dir, exist_ok=True)

        self.record_transition = True
        self._set_record_button("REC Starting...", False)
        self.window.REC_avg.setEnabled(False)
        self.window.REC_path.setEnabled(False)
        self.window.statusbar.showMessage(
            f"Starting recorder (REC_avg={rec_avg})..."
        )

        def worker():
            try:
                # Recording is deliberately independent of the control stream.
                # Recreate the board recorder for every requested REC_avg.
                remote = (
                    f"pkill -x ad7768_recordd_v6 >/dev/null 2>&1 || true; "
                    f"rm -f /run/ad7768_stream.sock; "
                    f"nohup {REMOTE_RECORD_DAEMON} "
                    f"-a {rec_avg} --ring-frames {RECORD_RING_FRAMES} "
                    f"--spill-dir {RECORD_SPILL_DIR} "
                    f"> /root/ad7768_recordd.log 2>&1 < /dev/null & "
                    f"sleep 0.5; test -S /run/ad7768_stream.sock"
                )

                result = subprocess.run(
                    ["ssh", "-T", SSH_HOST, remote],
                    check=False,
                )
                if result.returncode != 0:
                    raise RuntimeError(
                        f"board recorder start failed (ssh rc={result.returncode})"
                    )

                proc = subprocess.Popen(
                    [
                        sys.executable,
                        receiver,
                        "--host", SSH_HOST,
                        "-a", str(rec_avg),
                        "--segment-seconds", str(RECORD_SEGMENT_SECONDS),
                        "-o", out_dir,
                    ],
                    stdin=None,
                    stdout=None,
                    stderr=None,
                )

                # Catch immediate launch errors while keeping GUI non-blocking.
                time.sleep(0.4)
                if proc.poll() is not None:
                    raise RuntimeError(
                        f"PC receiver exited immediately (rc={proc.returncode})"
                    )

                self.record_results.put(("started", proc, rec_avg, out_dir))

            except Exception as e:
                self.record_results.put(("error", str(e)))

        threading.Thread(target=worker, daemon=True).start()

    def stop_recording(self):
        proc = self.record_proc
        if proc is None or proc.poll() is not None:
            self.record_proc = None
            self._set_record_button("REC Start", True)
            self.window.REC_avg.setEnabled(True)
            self.window.REC_path.setEnabled(True)
            return

        self.record_transition = True
        self._set_record_button("REC Stopping...", False)
        self.window.statusbar.showMessage("Stopping recording...")

        def worker():
            try:
                # receiver_v9 handles SIGINT as an intentional REC stop and sends
                # the board-side --stop command before it exits.
                proc.send_signal(signal.SIGINT)
                try:
                    rc = proc.wait(timeout=8.0)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    try:
                        rc = proc.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        rc = proc.wait()
                self.record_results.put(("stopped", rc))
            except Exception as e:
                self.record_results.put(("error", str(e)))

        threading.Thread(target=worker, daemon=True).start()

    def _check_record_results(self):
        try:
            item = self.record_results.get_nowait()
        except queue.Empty:
            # Detect an unexpected receiver exit after a successful start.
            if (self.record_proc is not None and
                    self.record_proc.poll() is not None and
                    not self.record_transition):
                rc = self.record_proc.returncode
                self.record_proc = None
                self._set_record_button("REC Start", True)
                self.window.REC_avg.setEnabled(True)
                self.window.REC_path.setEnabled(True)
                self.window.statusbar.showMessage(
                    f"Recording stopped unexpectedly (rc={rc})", 8000
                )
            return

        kind = item[0]
        self.record_transition = False

        if kind == "started":
            _, proc, rec_avg, out_dir = item
            self.record_proc = proc
            self._set_record_button("REC Stop", True)
            self.window.statusbar.showMessage(
                f"Recording: REC_avg={rec_avg}, path={out_dir}", 5000
            )

        elif kind == "stopped":
            _, rc = item
            self.record_proc = None
            self._set_record_button("REC Start", True)
            self.window.REC_avg.setEnabled(True)
            self.window.REC_path.setEnabled(True)
            self.window.statusbar.showMessage(
                f"Recording stopped (rc={rc})", 5000
            )

        elif kind == "error":
            _, message = item
            self.record_proc = None
            self._set_record_button("REC Start", True)
            self.window.REC_avg.setEnabled(True)
            self.window.REC_path.setEnabled(True)
            self.window.statusbar.showMessage(f"REC failed: {message}", 8000)

    # -------------------------------------------------------------------------
    # Streaming / plots
    # -------------------------------------------------------------------------

    def selected_phase_from_frames(self, frames):
        cordic = self.window.Cordicsel.currentIndex()

        if cordic == 0:
            return frames["phase0"].astype(np.float64) * BAM_TO_RAD

        if cordic == 1:
            return frames["phase1"].astype(np.float64) * BAM_TO_RAD

        # phase2 is not in the current 32-byte control DMA payload.
        return None

    def update_gui(self):
        # Finish any Apply/Reset operation without ever blocking Qt's event loop.
        self._check_command_results()
        self._check_record_results()

        now = time.perf_counter()
        gui_dt_ms = (now - self.last_gui_update) * 1000.0
        self.last_gui_update = now
        self.window.Looptime.display(gui_dt_ms)

        frames = self.stream.take_all()
        if len(frames) == 0:
            if not self.stream.running:
                self.window.statusbar.showMessage(
                    "Control stream stopped. Check SSH / board helper."
                )
            return

        cordic = self.window.Cordicsel.currentIndex()
        i_ch = self.window.Ichansel.currentIndex()
        q_ch = self.window.Qchansel.currentIndex()

        # CORDIC0/1 use averaged channels and those AVG values are present in
        # the current control DMA stream.
        if cordic in (0, 1):
            i_cts = frames[f"avg{i_ch}"].astype(np.float64)
            q_cts = frames[f"avg{q_ch}"].astype(np.float64)

            vref = self.ai_vref_widget.value() if self.ai_vref_widget is not None else 1.0
            i = adc_counts_to_physical(i_cts, vref)
            q = adc_counts_to_physical(q_cts, vref)

            # One GUI refresh = every sample that arrived since last refresh,
            # displayed in physical volts rather than ADC counts.
            self.iq_curve.setData(i, q)

            phase = self.selected_phase_from_frames(frames)

            if phase is not None and len(phase):
                self.phase_history.extend(phase.tolist())
                hist = np.asarray(self.phase_history, dtype=np.float64)
                self.phase_curve.setData(hist)

                current_phase = float(phase[-1])
                self.window.Cordicphase.display(current_phase)

                setpoint = float(self.window.Setpoint.value())
                error = float(wrapped_phase_error(setpoint, current_phase))
                self.window.PIDer.display(error)

        else:
            # CORDIC2 is raw. Current control DMA does not stream raw I/Q nor phase2.
            self.window.statusbar.showMessage(
                "CORDIC2 selected: raw I/Q and phase2 are not in the current control DMA."
            )

        # Actual AO codes are in the control DMA; convert them back to the
        # selected AO's physical scale for the numeric display.
        ao_index = self.window.AOsel.currentIndex()
        ao_code = int(frames[f"ao{ao_index}"][-1])
        ao_phys = ao_cts_to_abs(
            ao_code,
            self.window.PIDoutmin.value(),
            self.window.PIDoutmax.value(),
        )
        if math.isfinite(ao_phys):
            self.window.PIDOdis.display(ao_phys)
        self.window.PIDoutdis.setValue(ao_code)

    def load_rms(self):
        """
        RMS-phase display uses standard deviation about the mean of the currently
        retained phase waveform, which is useful as a lock-noise indicator.
        """
        if not self.phase_history:
            self.window.Phaserms.display(0.0)
            return

        data = np.asarray(self.phase_history, dtype=np.float64)
        rms = float(np.std(data))
        self.window.Phaserms.display(rms)

    def shutdown(self):
        try:
            self.timer.stop()
        except Exception:
            pass

        # Stop an active recording intentionally so receiver_v9 can close the
        # current session instead of leaving the board in spill mode.
        try:
            if self.record_proc is not None and self.record_proc.poll() is None:
                self.record_proc.send_signal(signal.SIGINT)
                try:
                    self.record_proc.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    self.record_proc.terminate()
        except Exception:
            pass

        try:
            self.stream.stop()
        except Exception:
            pass


def main():
    app = QApplication(sys.argv)

    here = os.path.dirname(os.path.abspath(__file__))
    ui_path = os.path.join(here, "PIDctrl.ui")

    gui = PIDControllerGUI(ui_path)
    gui.window.show()

    exit_code = app.exec()
    gui.shutdown()
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
