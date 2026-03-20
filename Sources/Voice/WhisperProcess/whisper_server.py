#!/usr/bin/env python3
"""STUB whisper server — echoes back dummy transcriptions for E2E testing.
Replace with real MLX Whisper implementation later."""
import json
import sys
import signal

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

# Read config line
config = json.loads(sys.stdin.readline().strip())
print(json.dumps({"status": "ready"}), flush=True)

_counter = 0
while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    cmd = json.loads(line)
    if cmd.get("cmd") == "shutdown":
        break
    if cmd.get("cmd") == "transcribe":
        audio_len = cmd.get("audio_length", 0)
        sys.stdin.buffer.read(audio_len)
        _counter += 1
        print(json.dumps({
            "segment_id": cmd.get("segment_id", _counter),
            "text": f"stub transcription {_counter}"
        }), flush=True)
