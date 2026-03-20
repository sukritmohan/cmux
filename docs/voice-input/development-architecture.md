# Voice-to-Terminal: Development Architecture

**Feature:** Voice input for the Android companion app
**Status:** Implemented
**Last updated:** 2026-03-19

---

## Overview

Voice-to-terminal lets users speak commands and dictation on their Android phone and have the transcribed text appear in the active Mac terminal pane. Audio is captured on the phone, streamed to the Mac over the existing WebSocket connection, transcribed by MLX Whisper running locally on the Mac, and returned as phrase-level transcriptions that the user can review before they are committed to the terminal.

---

## Architecture

```
┌─────────────────────┐              ┌──────────────────────────┐
│  Android Companion   │              │     Mac (cmux desktop)    │
│                      │  Existing    │                           │
│  Mic → 16kHz PCM ────┼─ WebSocket ─→│  BridgeServer             │
│  (binary channel     │  (binary     │  ↓ demux by channel ID    │
│   0xFFFFFFFF)        │   frames)    │  VoiceChannel handler     │
│                      │              │  ↓                        │
│  voice.start/stop ───┼─ JSON-RPC ──→│  Voice RPC commands       │
│                      │              │  ↓                        │
│  ←────────────────────┼─ JSON-RPC ──│  Swift VAD (energy-based) │
│  voice.transcription │              │  ↓ speech segments        │
│  ↓                   │              │  MLX Whisper subprocess   │
│  Preview strip chips │              │  (small/medium model)     │
│  ↓ (auto-commit 0.8s)│              │                           │
│  surface.pty.write ──┼─ JSON-RPC ──→│  Terminal input            │
│  (atomic, single msg)│              │  (targets active surface)  │
└─────────────────────┘              └──────────────────────────┘
```

**Design principle:** Voice reuses the existing WebSocket connection. Audio goes through the binary channel framing (reserved channel ID `0xFFFFFFFF`), and control/transcription messages go through the existing V2 JSON-RPC text frame path. No second WebSocket, no port discovery problem, no second auth handshake.

---

## Audio Transport

### Binary Channel Framing

Audio is sent as binary WebSocket frames using the same 4-byte channel ID prefix framing already used for PTY data. The reserved channel ID `0xFFFFFFFF` identifies voice audio frames to the Mac-side demuxer.

**Frame format:**
```
[4 bytes LE: 0xFFFFFFFF (kVoiceChannelId)] [raw PCM bytes]
```

**Audio format:**
- Encoding: 16-bit signed little-endian PCM
- Sample rate: 16 kHz, mono (1 channel)
- Chunk size: ~100ms per frame = 3,200 bytes (16,000 samples/s × 0.1s × 2 bytes/sample)

### Phone-Side Silence Suppression

Before a frame is transmitted, the phone computes the RMS energy of the PCM buffer and suppresses frames whose energy falls below a threshold (`_kSilenceThreshold = 0.02`). This avoids streaming dead air during natural pauses:

- 3 seconds of 16kHz 16-bit silence = ~96KB that would otherwise be sent
- Silence suppression reduces this to zero while preserving the local auto-stop timer
- When speech resumes, frames are transmitted again immediately

RMS energy calculation normalises each signed 16-bit sample to [-1, 1] by dividing by 32,768, then takes the square root of the mean of squared normalised samples.

---

## Voice Activity Detection (VAD)

**File:** `Sources/Voice/VoiceActivityDetector.swift`

Energy-based VAD implemented in Swift. No ML model required. All methods must be called from the bridge server's serial dispatch queue.

### Algorithm

1. **Calibration phase** (first 500ms): Collect RMS energy samples from the incoming stream to establish an ambient noise floor. The noise floor is the mean of collected samples, floored at 0.005 to handle near-silence environments.

2. **Detection phase:** Compare each frame's RMS energy to a dynamic threshold:
   - `energyThreshold = noiseFloor × 2.5`
   - Energy ≥ threshold → speech frame
   - Energy < threshold → silence frame

3. **Segment lifecycle:**
   - Silence → speech: begin buffering audio, record `speechStartTime`
   - Speech → silence: continue buffering (to avoid clipping speech tail)
   - Silence sustained ≥ 500ms after last speech frame: flush the segment
   - Segment duration < 300ms: discard (noise burst)
   - Segment duration ≥ 30s: force-flush to bound transcription latency and memory usage

4. **Flush on stop:** When `voice.stop` is received, `flushRemaining()` is called to emit any partial open segment so the user's final phrase is not lost.

### Key Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `calibrationDuration` | 500ms | Silence window for noise floor measurement |
| `energyMultiplier` | 2.5× | Speech must be 2.5× above noise floor |
| `silenceGap` | 500ms | Silence duration that closes a segment |
| `minSegmentDuration` | 300ms | Minimum length to reject noise bursts |
| `maxSegmentDuration` | 30s | Maximum length before force-flush |
| `sampleRate` | 16,000 Hz | Expected PCM stream sample rate |

---

## Whisper Subprocess

**File:** `Sources/Voice/WhisperBridge.swift`
**Script:** `Sources/Voice/WhisperProcess/whisper_server.py`

### Subprocess Architecture

cmux spawns `whisper_server.py` as a Python child process when `voice.start` is received (not on connection). Communication is via stdin/stdout using line-delimited JSON with binary audio data interleaved.

**Startup protocol:**
1. Swift writes a JSON config line to stdin: `{"model_path": "...", "sample_rate": 16000, "encoding": "pcm_s16le"}\n`
2. Script responds with `{"status": "ready"}\n` once the model is loaded

**Transcription request:**
```
[JSON command line]\n[raw audio bytes]
```
Command: `{"cmd": "transcribe", "segment_id": N, "audio_length": M}\n` followed immediately by M raw PCM bytes.

**Transcription response:**
```json
{"segment_id": N, "text": "transcribed text"}
```

**Shutdown:**
Swift sends `{"cmd": "shutdown"}\n`, then waits up to 5 seconds for a clean exit before issuing SIGKILL.

### Process Lifecycle

- Process is spawned on first `voice.start` within a connection
- Process stays warm for 30 seconds after the last audio segment (idle timeout avoids cold-start latency on the next recording)
- On idle timeout: graceful shutdown (shutdown command → 5s grace → SIGKILL)
- On connection close: `teardown()` stops the process via `VoiceChannel`

### Crash Recovery

- Crash detected by: `Process.terminationHandler` firing with a non-zero exit code
- On crash: log the event, clean up pipes, auto-restart (up to 3 attempts per session)
- After 3 crashes: dispatch `voice.error` event to phone with a human-readable message; phone shows a toast and stops recording
- The in-flight audio segment at time of crash is discarded (lost)

### Model

- Default: `mlx-community/whisper-small-mlx` (~500MB)
- Configurable to medium for better accuracy (cmux Preferences)
- Downloaded by `voice.setup` RPC using `huggingface_hub.snapshot_download`
- Cached at `~/.cmux/models/whisper-small-mlx/`
- Transcription latency: ~200–500ms for a 2–3s segment on Apple Silicon

### Script Notes

`whisper_server.py` is currently a **stub** that echoes `"stub transcription N"` for each segment. It is used for E2E testing. The stub reads and discards the audio bytes from stdin via `sys.stdin.buffer.read(audio_len)` to keep the protocol correct. The production MLX Whisper implementation will replace this stub.

---

## Phone-Side Components

### `voice_protocol.dart`

Pure Dart protocol types with no Flutter dependencies. Foundation layer used by the service and UI.

**Key types:**
- `VoiceAudioFrame` — encodes raw PCM bytes into a binary WebSocket frame with the channel ID prefix
- `TriggerWordDetector` — detects trailing trigger words ("enter", "run", "execute") using whole-word matching on the last whitespace-delimited token
- `TriggerWordResult` — holds `hasTrigger`, `cleanText` (trigger word stripped), and the matched `triggerWord`
- `TranscriptionChip` — immutable value type representing one transcription segment in the strip; equality by `segmentId`; `commitText` property appends `\r` when `hasTrigger` is true
- `ChipStatus` enum — `pending | committing | committed | dismissed`
- `VoiceStatus` enum — `idle | recording | processing | setupRequired`
- `VoiceState` — immutable snapshot consumed by button and strip; computed properties `hasActiveChips` and `isStripVisible` drive strip visibility

**Constants defined here:**
- `kVoiceChannelId = 0xFFFFFFFF`
- `kChipAutoCommitDelay = 800ms`
- `kChipFadeOutDelay = 800ms`
- `kSilenceAutoStopDuration = 3s`
- `kTapMaxDuration = 250ms`
- `kSampleRate = 16000`, `kBitsPerSample = 16`, `kChannelCount = 1`
- `kAudioChunkBytes = 3200` (100ms of 16kHz 16-bit mono)

### `voice_service.dart`

Riverpod `StateNotifier<VoiceState>` that owns the entire voice recording lifecycle.

**Responsibilities:**
- Permission check before first recording
- Opens a raw PCM stream via the `record` package (`AudioEncoder.pcm16bits`, 16kHz, mono)
- Per-chunk silence suppression: RMS energy computed with `computeRMSEnergy()`, frames below 0.02 threshold are not transmitted
- Auto-stop after 3 seconds of continuous silence in tap-toggle mode
- Duration ticker (increments `recordingDuration` every second)
- Chip lifecycle: `addChip()` → `_commitTimers` fires after 800ms → chip transitions to `committing` → UI writes pty → `markCommitted()` → `_removeTimers` fires after 800ms → `removeChip()`
- `dismissChip()` cancels the commit timer and marks the chip dismissed; no-op if chip is already committed

**Provider:** `voiceProvider` (global `StateNotifierProvider`)

**Flutter dependency:** `record ^5.1.0` (raw PCM stream on Android/iOS)

### `voice_strip.dart`

Stateless `VoiceStrip` widget plus internal stateful sub-widgets.

**Layout:** `[_WaveformVisualizer 44×36px] [_RecordingTimer] [scrollable ListView of _TranscriptionChipWidget]`

**Strip container:**
- Height: 52px, horizontal margin: 8px
- Background: `voiceStripBg` (rgba 16,16,24 at 90% opacity)
- 24px backdrop blur (`ImageFilter.blur`)
- Border radius: 14px top corners only (connects visually to modifier bar below)

**Visibility animation:** `AnimatedSlide` (Offset(0,1) → Offset.zero, 250ms easeOutCubic) + `AnimatedOpacity` (200ms) driven by `VoiceState.isStripVisible`

**`_WaveformVisualizer`:** 7 animated bars using an `AnimationController` (1200ms repeat). Each bar height is computed from a sine wave with a unique phase offset, mapping [-1,1] → [6px, 28px]. When not recording, bars rest at 4px height at 30% opacity.

**`_TranscriptionChipWidget`:** Wraps `_ChipContent` in a `Dismissible` (swipe direction: `startToEnd`) for pending/committing chips. Committed chips skip the `Dismissible` and use `AnimatedOpacity(0.4)` + `AnimatedScale(0.95)`.

**`_CommitProgressBar`:** `AnimationController` that runs for `kChipAutoCommitDelay` and fills a `FractionallySizedBox` from left to right. The bar is 2px tall, green (`voiceCommitGreen`), with rounded corners.

**Chip styling:**
- Background: `voiceChipBg` (rgba 255,255,255 at ~8%)
- Border: `voiceChipBorder` (rgba 255,255,255 at ~12%); committing: `voiceCommitBorder` (rgba 80,200,120 at 30%)
- Max width: 200px (ellipsis overflow)
- Font: JetBrains Mono, 11px, weight 500
- Trigger indicator: `⏎` symbol (U+23CE) in accent color, shown before the chip text

### `voice_button.dart`

`ConsumerStatefulWidget` with a `SingleTickerProviderStateMixin` for the pulsing ring animation.

**Gesture handling:** Uses `GestureDetector` with `onTapDown`, `onTapUp`, `onTapCancel`, `onLongPressStart`, and `onLongPressEnd`. Press duration is measured by recording `_tapDownTime` on `TapDown` and computing the difference on `TapUp`. Presses < 250ms are taps; ≥ 250ms are holds.

**Visual implementation (`_ButtonVisual`):** 36×36px container with a 10px border radius. The pulsing red ring in recording state is implemented as an animated `BoxShadow` whose alpha and `blurRadius` are driven by the pulse `AnimationController` (1500ms repeat with `reverse: true`).

---

## Mac-Side Components

### `VoiceChannel.swift`

Per-connection coordinator that holds one `VoiceActivityDetector` and one `WhisperBridge`. Must be called from the bridge server's serial dispatch queue.

**Session lifecycle:**
1. `startSession(queue:)` — resets VAD, wires VAD → Whisper → phone callback chain, starts the Whisper subprocess
2. `processAudioFrame(_:)` — feeds PCM data into the VAD; no-op when no session is active
3. `stopSession()` — calls `vad.flushRemaining()` to emit any partial segment, marks session inactive
4. `teardown()` — called on connection close; stops the Whisper subprocess

**Event routing:** `sendEvent` closure is set by `BridgeConnection` and used to push `voice.processing`, `voice.transcription`, and `voice.error` JSON-RPC events back to the phone.

### `VoiceActivityDetector.swift`

Energy-based VAD (see algorithm section above). Emits speech segments via `onSegmentReady` callback with a monotonically increasing `segmentId` starting at 1 per session reset.

### `WhisperBridge.swift`

Python subprocess lifecycle manager. Handles spawn, config handshake, transcription IPC, crash detection, auto-restart, idle timeout, and graceful/forced shutdown.

**Threading model:**
- Public API must be called from the bridge server's serial queue
- All subprocess I/O runs on a private serial `ioQueue` (`com.cmux.whisper-bridge.io`)
- `onTranscription` and `onError` callbacks are dispatched to `callbackQueue` (the bridge server's queue)

**Script resolution:** Release builds look for `whisper_server.py` inside the app bundle at `Resources/WhisperProcess/whisper_server.py`. Development builds resolve the path relative to `WhisperBridge.swift`'s source file location via `#file`.

### `VoiceCommands.swift`

Stateless enum with static handler methods for each `voice.*` RPC method. Each method takes a `VoiceChannel`, the JSON-RPC request ID, an `encode` closure for building the success response, and (for `handleSetup`) a `sendEvent` closure.

| Method | Handler | Returns |
|--------|---------|---------|
| `voice.check_ready` | `handleCheckReady` | `{ready: bool, reason?: string}` |
| `voice.setup` | `handleSetup` | `{status: "already_installed" \| "downloading"}` |
| `voice.start` | `handleStart` | `{session_id: string}` |
| `voice.stop` | `handleStop` | `{status: "stopped"}` |

`handleSetup` dispatches the `huggingface_hub.snapshot_download` Python process to `DispatchQueue.global(qos: .userInitiated)` to avoid blocking the bridge queue.

### `whisper_server.py`

Python subprocess that reads audio segments from stdin and writes transcriptions to stdout as line-delimited JSON. Currently a stub for E2E testing. The production implementation will replace the stub responses with MLX Whisper inference.

---

## JSON-RPC Protocol

### Phone → Mac (control)

```json
{"jsonrpc": "2.0", "method": "voice.check_ready", "id": 1}
{"jsonrpc": "2.0", "method": "voice.setup", "id": 2}
{"jsonrpc": "2.0", "method": "voice.start", "id": 3}
{"jsonrpc": "2.0", "method": "voice.stop", "id": 4}
```

### Phone → Mac (audio)

Binary WebSocket frames. No JSON. Format: `[4 bytes LE: 0xFFFFFFFF][raw PCM]`

### Mac → Phone (responses and events)

```json
// check_ready response
{"jsonrpc": "2.0", "id": 1, "result": {"ready": true}}
{"jsonrpc": "2.0", "id": 1, "result": {"ready": false, "reason": "model_not_downloaded"}}

// setup response (immediate; download happens asynchronously)
{"jsonrpc": "2.0", "id": 2, "result": {"status": "downloading"}}

// setup progress events (pushed asynchronously during download)
{"jsonrpc": "2.0", "method": "voice.setup_progress", "params": {"percent": 45, "message": "Downloading whisper-small..."}}
{"jsonrpc": "2.0", "method": "voice.setup_progress", "params": {"percent": 100, "message": "Download complete"}}

// start response
{"jsonrpc": "2.0", "id": 3, "result": {"session_id": "abc123"}}

// segment processing notification (informational; sent before transcription is ready)
{"jsonrpc": "2.0", "method": "voice.processing", "params": {"segment_id": 1}}

// transcription result
{"jsonrpc": "2.0", "method": "voice.transcription", "params": {"segment_id": 1, "text": "git status"}}

// error (non-recoverable)
{"jsonrpc": "2.0", "method": "voice.error", "params": {"message": "Whisper subprocess crashed 3 times..."}}
```

### Segment ID Protocol

- Segment IDs are monotonically increasing integers starting at 1 per session reset
- IDs are assigned and incremented by `VoiceActivityDetector` at the point of flush
- Gaps in IDs are expected: segments rejected by the min-duration filter consume an ID slot but no transcription is emitted for them
- Phone renders chips in arrival order and ignores gaps
- A `voice.transcription` without a prior `voice.processing` for the same ID is valid; the processing message is informational only

---

## Error Handling

| Scenario | Mac behavior | Phone behavior |
|----------|-------------|----------------|
| Model not installed | `check_ready` returns `ready: false` | Show setup bottom sheet on mic tap |
| Model downloading | Send `setup_progress` events | Show progress in bottom sheet |
| Whisper crash | Auto-restart up to 3 times; then `voice.error` | Brief delay; after 3 crashes: toast + stop recording |
| Connection lost during recording | N/A | Stop recording, show toast, keep uncommitted chips |
| Audio permission denied | N/A | Show system permission dialog; mic button shows badge |
| No speech detected (silence) | VAD emits no segments | Strip shows waveform but no chips |
| Phone-side silence (3s, dictation mode) | No audio frames received | VoiceService auto-stops recording |

---

## File Structure

### Phone (Android companion)

```
android-companion/lib/terminal/
├── voice_protocol.dart    # Protocol types, constants, binary frame encoding, trigger word detection
├── voice_service.dart     # Riverpod StateNotifier — recording lifecycle, silence suppression, chip state
├── voice_strip.dart       # Transcription strip UI — waveform, timer, chips, commit progress, swipe dismiss
└── voice_button.dart      # Mic button — dual-mode activation, visual states, haptic feedback
```

### Mac (cmux desktop)

```
Sources/Voice/
├── VoiceChannel.swift          # Binary frame handler; coordinates VAD + Whisper per connection
├── VoiceCommands.swift         # Stateless JSON-RPC handlers for voice.* methods
├── VoiceActivityDetector.swift # Energy-based VAD with auto-calibrating threshold
├── WhisperBridge.swift         # Python subprocess lifecycle, crash recovery, idle timeout
└── WhisperProcess/
    └── whisper_server.py       # Stub Whisper subprocess (E2E testing; production impl TBD)
```

---

## Flutter Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `record` | `^5.1.0` | Raw PCM audio stream at 16kHz 16-bit on Android/iOS |
| `web_socket_channel` | `^3.0.2` | Reused for voice binary frames and JSON-RPC (already present) |
| `flutter_riverpod` | existing | State management for VoiceNotifier |
