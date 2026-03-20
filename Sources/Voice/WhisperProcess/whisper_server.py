#!/usr/bin/env python3
"""STUB whisper server — echoes back dummy transcriptions for E2E testing.

Protocol (all via stdin/stdout in BINARY mode):
  - First line: JSON config (e.g. {"model_path": "..."})
  - Server prints: {"status": "ready"}
  - Each request: JSON line {"cmd":"transcribe","segment_id":N,"audio_length":M}
    followed immediately by M bytes of raw PCM audio
  - Server prints: {"segment_id":N,"text":"..."}
  - Shutdown: {"cmd":"shutdown"}

IMPORTANT: All stdin reads use sys.stdin.buffer (binary mode) to avoid
Python's text-mode buffering consuming binary audio bytes.
"""
import json
import sys
import signal

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

_stdin = sys.stdin.buffer  # binary mode only — never use sys.stdin (text mode)


def _read_line():
    """Read one newline-terminated line from binary stdin, return as str."""
    buf = b""
    while True:
        byte = _stdin.read(1)
        if not byte:
            return None  # EOF
        if byte == b"\n":
            return buf.decode("utf-8", errors="replace")
        buf += byte


def _log(msg):
    print(f"[whisper_server] {msg}", file=sys.stderr, flush=True)


# Read config line.
config_line = _read_line()
if not config_line:
    _log("ERROR: no config line on stdin")
    sys.exit(1)

config = json.loads(config_line)
_log(f"config: {config}")

# Signal ready.
sys.stdout.write(json.dumps({"status": "ready"}) + "\n")
sys.stdout.flush()

_counter = 0

while True:
    line = _read_line()
    if line is None:
        break  # EOF
    line = line.strip()
    if not line:
        continue

    try:
        cmd = json.loads(line)
    except json.JSONDecodeError as e:
        _log(f"JSON parse error: {e} — line: {line!r}")
        continue

    if cmd.get("cmd") == "shutdown":
        _log("shutdown requested")
        break

    if cmd.get("cmd") == "transcribe":
        segment_id = cmd.get("segment_id", 0)
        audio_len = cmd.get("audio_length", 0)

        # Read exactly audio_len bytes of raw PCM audio.
        audio_data = b""
        while len(audio_data) < audio_len:
            chunk = _stdin.read(audio_len - len(audio_data))
            if not chunk:
                _log("EOF while reading audio data")
                sys.exit(1)
            audio_data += chunk

        _counter += 1
        _log(f"segment {segment_id}: received {len(audio_data)} bytes, returning stub transcription")

        result = json.dumps({
            "segment_id": segment_id,
            "text": f"stub transcription {_counter}"
        })
        sys.stdout.write(result + "\n")
        sys.stdout.flush()

_log("exiting")
