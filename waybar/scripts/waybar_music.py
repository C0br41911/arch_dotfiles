#!/usr/bin/env python3
import fcntl
import html
import json
import math
import os
import signal
import struct
import subprocess
import sys
import threading
import time

import gi
gi.require_version('Gio', '2.0')
gi.require_version('GLib', '2.0')
from gi.repository import Gio, GLib

# --- Configuration ---
NUM_BARS = 8              # Soundbar column count
TARGET_FPS = 30           # Visualizer refresh rate
TEXT_LENGTH = 32          # Display length for scrolling text
SCROLL_SPEED = 8          # Text scroll rate divisor (lower = faster)
SKIP_LOCK_DURATION = 5.0  # Seconds to hold title ONLY during user-initiated skips

SAMPLE_RATE = 22050
FRAME_SAMPLES = int(SAMPLE_RATE / TARGET_FPS)
BYTES_PER_FRAME = FRAME_SAMPLES * 2

BLOCKS = [" ", " ", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
HEIGHT_COLORS = [
    "#45475a", "#26a65b", "#2ecc71", "#b5e853",
    "#f1c40f", "#f39c12", "#e67e22", "#e74c3c", "#c0392b"
]

# --- Audio Pre-computation ---
MIN_FREQ, MAX_FREQ = 50.0, 8000.0
PRECOMPUTED_BANDS = []
log_min, log_max = math.log10(MIN_FREQ), math.log10(MAX_FREQ)

for i in range(NUM_BARS):
    center_f = 10 ** (log_min + i * (log_max - log_min) / (NUM_BARS - 1)) if NUM_BARS > 1 else 440.0
    spreads = [0.88, 0.94, 1.0, 1.06, 1.12]
    band_tables = []
    for s in spreads:
        f = center_f * s
        omega = 2.0 * math.pi * f / SAMPLE_RATE
        cos_t = [math.cos(omega * n) for n in range(FRAME_SAMPLES)]
        sin_t = [math.sin(omega * n) for n in range(FRAME_SAMPLES)]
        band_tables.append((cos_t, sin_t))
    PRECOMPUTED_BANDS.append(band_tables)


def spawn_audio_proc():
    commands = [
        ["parec", "--device=@DEFAULT_MONITOR@", "--latency-msec=10", "--format=s16le", "--channels=1", f"--rate={SAMPLE_RATE}"],
        ["pw-record", "--latency=10ms", "--format=s16", "-r", str(SAMPLE_RATE), "-c", "1", "-"],
        ["parec", "--latency-msec=10", "--format=s16le", "--channels=1", f"--rate={SAMPLE_RATE}"],
    ]
    for cmd in commands:
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            fd = p.stdout.fileno()
            fl = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
            return p
        except Exception:
            continue
    return None


def drain_pipe_get_latest(fd, bytes_needed):
    buffer = b""
    while True:
        try:
            chunk = os.read(fd, 16384)
            if not chunk:
                break
            buffer += chunk
        except (BlockingIOError, OSError):
            break

    if len(buffer) >= bytes_needed:
        return buffer[-bytes_needed:]
    return b""


def calculate_spectrum(samples, smooth_bars, peak_tracker):
    FALL_SPEED = 0.28
    if not samples or len(samples) < FRAME_SAMPLES:
        for i in range(NUM_BARS):
            smooth_bars[i] = max(0.0, smooth_bars[i] - FALL_SPEED)
        return [int(round(b)) for b in smooth_bars]

    raw_mags = []
    for band_idx, band_tables in enumerate(PRECOMPUTED_BANDS):
        band_mag_sum = 0.0
        for cos_t, sin_t in band_tables:
            real = sum(s * c for s, c in zip(samples, cos_t))
            imag = sum(s * s_val for s, s_val in zip(samples, sin_t))
            band_mag_sum += math.sqrt(real * real + imag * imag) / FRAME_SAMPLES
        avg_mag = band_mag_sum / len(band_tables)
        raw_mags.append(avg_mag * (1.0 + (band_idx * (1.2 / max(1, NUM_BARS - 1)))))

    peak_tracker[0] = max(peak_tracker[0] * 0.96, max(raw_mags, default=1.0), 120.0)

    result_levels = []
    for i, mag in enumerate(raw_mags):
        norm = min(1.0, mag / peak_tracker[0])
        target_level = math.log10(1 + 9 * norm) * 8.0
        smooth_bars[i] = target_level if target_level >= smooth_bars[i] else max(0.0, smooth_bars[i] - FALL_SPEED)
        result_levels.append(int(round(smooth_bars[i])))

    return result_levels


def format_bars(bar_levels):
    formatted = []
    for h in bar_levels:
        h_clamped = max(0, min(8, h))
        char = BLOCKS[h_clamped] if h_clamped > 0 else BLOCKS[1]
        formatted.append(f"<span color='{HEIGHT_COLORS[h_clamped]}'>{char}</span>")
    return "".join(formatted)


def safe_unpack(val):
    if val is None:
        return None
    if hasattr(val, 'unpack'):
        try:
            return val.unpack()
        except Exception:
            return val
    return val


# --- Pure Declarative D-Bus Engine ---
class GioDBusMonitor:
    def __init__(self):
        self.lock = threading.Lock()
        self.track_title = ""
        self.playback_status = "Stopped"
        self.skip_lock_until = 0.0  # Timestamp for skip grace window

        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

        self.bus.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
            "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE,
            self.on_dbus_activity, None
        )

        self.bus.signal_subscribe(
            None, "org.freedesktop.DBus.Properties", "PropertiesChanged",
            "/org/mpris/MediaPlayer2", None, Gio.DBusSignalFlags.NONE,
            self.on_dbus_activity, None
        )
        
        # Register SIGUSR1 signal to trigger skip-lock
        signal.signal(signal.SIGUSR1, self.trigger_skip_lock)
        self.refresh_state()

    def trigger_skip_lock(self, signum, frame):
        with self.lock:
            self.skip_lock_until = time.time() + SKIP_LOCK_DURATION

    def on_dbus_activity(self, conn, sender, path, iface, signal, params, user_data):
        self.refresh_state()

    def refresh_state(self):
        with self.lock:
            try:
                reply = self.bus.call_sync(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", None,
                    GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, 250, None
                )
                names = safe_unpack(reply.get_child_value(0))
                mpris_names = [n for n in names if n.startswith("org.mpris.MediaPlayer2.") and "playerctld" not in n]
            except Exception:
                mpris_names = []

            best_track = ""
            best_status = "Stopped"

            for name in mpris_names:
                try:
                    reply = self.bus.call_sync(
                        name, "/org/mpris/MediaPlayer2",
                        "org.freedesktop.DBus.Properties", "GetAll",
                        GLib.Variant("(s)", ("org.mpris.MediaPlayer2.Player",)),
                        GLib.VariantType("(a{sv})"), Gio.DBusCallFlags.NONE, 250, None
                    )
                    props = safe_unpack(reply.get_child_value(0))
                    if not props:
                        continue

                    status = str(safe_unpack(props.get("PlaybackStatus", "Stopped")))
                    if status == "Stopped":
                        continue

                    meta = safe_unpack(props.get("Metadata", {}))
                    if not meta or not isinstance(meta, dict):
                        continue

                    track_id = str(safe_unpack(meta.get("mpris:trackid", "")))
                    if "NoTrack" in track_id:
                        continue

                    title_val = safe_unpack(meta.get("xesam:title"))
                    title = str(title_val).strip() if title_val is not None else ""
                    
                    artist_val = safe_unpack(meta.get("xesam:artist"))
                    artist = str(artist_val[0]).strip() if artist_val and isinstance(artist_val, (list, tuple)) else ""

                    if not title and not artist:
                        continue

                    track = (f"{artist} - {title}" if artist and title else title or artist).strip()
                    
                    if track:
                        if status == "Playing":
                            self.track_title = track
                            self.playback_status = "Playing"
                            return 
                        elif status == "Paused" and best_status == "Stopped":
                            best_track = track
                            best_status = "Paused"

                except Exception:
                    continue
            
            # WIPE / CLOSED TAB CHECK
            if not best_track and time.time() < self.skip_lock_until:
                # User pressed 'Next', hold onto the previous title briefly while browser buffers
                return

            self.track_title = best_track
            self.playback_status = best_status

    def get_info(self):
        with self.lock:
            return self.track_title, self.playback_status


def start_glib_loop():
    loop = GLib.MainLoop()
    loop.run()


# --- Main Rendering Loop ---
def main():
    monitor = GioDBusMonitor()

    glib_thread = threading.Thread(target=start_glib_loop, daemon=True)
    glib_thread.start()

    audio_proc = spawn_audio_proc()
    scroll_pos, frame_count = 0, 0
    last_display_track = ""
    frame_time = 1.0 / TARGET_FPS
    smooth_bars = [0.0] * NUM_BARS
    peak_tracker = [250.0]

    while True:
        start_time = time.time()
        frame_count += 1

        if audio_proc is None or audio_proc.poll() is not None:
            if audio_proc:
                try:
                    audio_proc.kill()
                except Exception:
                    pass
            audio_proc = spawn_audio_proc()

        track_info, current_status = monitor.get_info()

        raw_bytes = b""
        if audio_proc and audio_proc.stdout:
            fd = audio_proc.stdout.fileno()
            raw_bytes = drain_pipe_get_latest(fd, BYTES_PER_FRAME)

        if len(raw_bytes) >= BYTES_PER_FRAME:
            num_samples = len(raw_bytes) // 2
            samples = struct.unpack(f"<{num_samples}h", raw_bytes)
        else:
            samples = []

        if not track_info:
            smooth_bars = [0.0] * NUM_BARS
            scroll_pos = 0
            last_display_track = ""
            output_json = {"text": "", "tooltip": "", "class": "idle"}
        else:
            bar_levels = calculate_spectrum(samples, smooth_bars, peak_tracker) if current_status == "Playing" else [0] * NUM_BARS
            soundbars_pango = format_bars(bar_levels)

            if track_info != last_display_track:
                scroll_pos = 0
                last_display_track = track_info

            full_text = track_info + "   •   "
            if frame_count % SCROLL_SPEED == 0:
                scroll_pos = (scroll_pos + 1) % len(full_text)

            repeated_text = full_text * ((TEXT_LENGTH // len(full_text)) + 2)
            scrolled_text = repeated_text[scroll_pos : scroll_pos + TEXT_LENGTH]

            output_json = {
                "text": f"{soundbars_pango} <span color='#ffffff'>{html.escape(scrolled_text)}</span>",
                "tooltip": html.escape(f"[{current_status}] {track_info}"),
                "class": current_status.lower(),
            }

        try:
            sys.stdout.write(json.dumps(output_json) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            sys.exit(0)

        elapsed = time.time() - start_time
        time.sleep(max(0.001, frame_time - elapsed))


if __name__ == "__main__":
    main()
