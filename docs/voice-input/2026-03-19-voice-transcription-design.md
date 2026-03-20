# Voice-to-Terminal with Mac-Hosted MLX Whisper

**Date:** 2026-03-19
**Status:** Approved
**Playground:** [voice-transcription-playground.html](./voice-transcription-playground.html)

## Overview

Real-time voice-to-terminal input for the Android companion app. Audio is captured on the phone, streamed to the Mac over the existing WebSocket connection (using the binary channel framing), transcribed by MLX Whisper, and returned as phrase-level transcriptions that appear as dismissible chips in a preview strip before auto-committing to the terminal.

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

**Key principle:** Voice reuses the existing WebSocket connection. Audio goes through the binary channel framing (reserved channel ID `0xFFFFFFFF`), and control/transcription messages go through the existing V2 JSON-RPC text frame path. No second WebSocket, no port discovery problem, no second auth handshake.

## Phone-Side Design

### Mic Button (Dual-Mode Activation)

The voice button lives in the modifier bar's middle 2×2 grid (bottom-right cell, 36×36px).

**Hold for quick command:**
- Press-and-hold starts recording immediately
- Floating label appears: "recording... release to stop"
- Release stops recording and processes the final segment
- Best for short one-liner commands

**Tap for continuous dictation:**
- Single tap enters recording mode (tap detected by `< 250ms` press duration)
- Tap again to stop
- Auto-stops after 3 seconds of silence (local energy check on phone)
- Best for longer dictation sessions

**Visual states:**
| State | Icon | Background | Effect |
|-------|------|------------|--------|
| Idle | `mic_none_rounded` (outline) | `keyGroupResting` (6% white) | None |
| Recording | `mic` (filled) | `rgba(255,68,68,0.2)` | Pulsing red ring (1.5s cycle) |
| Processing | Spinner | `rgba(224,160,48,0.15)` | Spin animation (brief, ~600ms) |
| Setup required | `mic_none_rounded` + badge | `keyGroupResting` | Amber dot badge (model not ready) |

**Haptic feedback:**
- Recording start: `HapticFeedback.mediumImpact()`
- Recording stop: `HapticFeedback.lightImpact()`
- Chip arrives: `HapticFeedback.selectionClick()`
- Chip dismissed: `HapticFeedback.lightImpact()`
- Chip committed (text sent): no haptic (too frequent)

**Accessibility (Semantics):**
| State | Label |
|-------|-------|
| Idle | "Voice input" |
| Recording | "Recording voice, tap to stop" |
| Processing | "Processing voice input" |
| Setup required | "Voice input, setup required" |

### Model Setup Flow

On first tap of the mic button (when Whisper model is not yet available on Mac):

1. Phone sends `voice.check_ready` RPC
2. Mac responds with `{"ready": false, "reason": "model_not_downloaded"}`
3. Phone shows a bottom sheet: "Voice input requires a one-time model download (~500MB) on your Mac. Download now?"
4. User confirms → phone sends `voice.setup` RPC → Mac begins download
5. Progress reported via `voice.setup_progress` events: `{"percent": 45, "message": "Downloading whisper-small..."}`
6. On completion, mic button becomes active. Model is cached in `~/.cmux/models/`

This keeps the setup explicit and avoids surprising the user with a multi-minute download when they expect to speak.

### Transcription Preview Strip

A new horizontal strip that appears above the modifier bar (below the attachment strip if both are active).

**Layout:**
```
┌──────────────────────────────────────────────────────────────┐
│ [▓▓ waveform ▓▓] [0:03] [chip: "git status" ×] [chip: "&&" ×] │
│  44×36px          10px    scrollable chip area →               │
└──────────────────────────────────────────────────────────────┘
```

**Dimensions:**
- Height: 52px (when visible)
- Margin: 8px horizontal (same as modifier bar)
- Border radius: 14px top corners (connects visually to modifier bar below)
- Background: `rgba(16,16,24,0.90)` with 24px backdrop blur

**Components:**
- **Waveform visualizer** (left, 44×36px): 7 animated bars when recording, static when stopped
- **Timer** (10px JetBrains Mono): recording duration in `m:ss` format, red color
- **Chip scroll area** (flex, horizontal scroll): transcription chips flow left-to-right

**Slide animation:**
- Strip slides up from behind modifier bar when recording starts (300ms, spring curve)
- Strip slides back down when recording stops AND all chips are committed/dismissed
- Opacity fades in sync with slide

### Transcription Chips

Each transcribed phrase becomes a chip in the scroll area.

**Chip anatomy:**
```
┌─────────────────────────────────┐
│ "git status" [0.5] [×]          │
│ ████████████░░░░░░              │  ← progress bar (bottom, 2px)
└─────────────────────────────────┘
```

**Lifecycle:**
1. **Arrive** — chip slides in from right with spring animation (300ms)
2. **Committing** — after 200ms pause, green progress bar fills over 0.8s; countdown timer shows remaining seconds; border turns green-tinted
3. **Committed** — text is sent to terminal as a single atomic `surface.pty.write` call; chip fades to 40% opacity, shrinks to 95% scale; removed after 800ms. The "typing" visual effect is rendered only on the phone's terminal view, not via character-by-character writes.
4. **Dismissed** — chip slides left 20px, fades out, removed after 300ms

**Commit atomicity:** When the commit timer fires, the chip is immediately marked as `committed` (state transition is synchronous). The dismiss handler checks this flag first — if already committed, dismiss is a no-op. The `surface.pty.write` sends the full text in a single message (not character-by-character), eliminating the race window between commit and dismiss.

**Dismiss interaction:**
- **Tap ×** button on any uncommitted chip to cancel it
- **Swipe left** past 50px threshold to dismiss (with live drag feedback)
- Dismissed chips are NOT typed into the terminal
- Cancels the auto-commit countdown

**Styling:**
- Background: `rgba(255,255,255,0.08)`
- Border: 1px `rgba(255,255,255,0.12)`
- Committing border: `rgba(80,200,120,0.3)`
- Max width: 200px (ellipsis overflow)
- Font: JetBrains Mono, 11px, weight 500

### Trigger Words

If a transcribed phrase ends with a trigger word as a separate word (word-boundary match):

**Trigger words:** "enter", "run", "execute"

**Matching rule:** The last whitespace-delimited word in the transcription must exactly match a trigger word (case-insensitive). This means "center" or "rerun" do NOT trigger, because the matching is on whole words only.

**Behavior:**
1. The trigger word is stripped from the text
2. A `⏎` indicator appears on the chip
3. After the text is committed to the terminal, `\r` (Return) is appended
4. This is a user-toggleable setting (default: on)

### Terminal Integration

**Surface targeting:** The voice service reads the active surface ID from `surfaceProvider` (the same Riverpod provider used by `TerminalView` for PTY writes). All `surface.pty.write` calls include the `surface_id` parameter.

**Commit write:** Committed text is sent as a single `surface.pty.write` call with the full text string. No character-by-character sending. If a trigger word was detected, `\r` is appended to the text payload.

### Local Silence Suppression

The phone performs a lightweight local energy check on audio frames before sending them to the Mac. Frames where the RMS energy is below a silence threshold are suppressed (not sent). This avoids streaming dead air during pauses in speech:

- 3 seconds of 16kHz PCM at 16-bit = ~96KB of silence that would otherwise be transmitted
- Silence suppression reduces this to zero while preserving the phone-side auto-stop timer
- When speech resumes, frames are sent again immediately

## Mac-Side Design

### Voice Channel in BridgeServer

Voice reuses the existing `BridgeServer` infrastructure:

**Binary audio frames:** Use the existing 4-byte channel ID prefix framing (same as PTY data). Reserved channel ID: `0xFFFFFFFF` for voice audio. The `PtyDemuxer` equivalent on the Mac side routes these frames to the `VoiceChannel` handler.

**JSON-RPC commands:** Voice control messages are standard V2 JSON-RPC on the text frame path:
- `voice.check_ready` — check if Whisper model is available
- `voice.setup` — trigger model download
- `voice.start` — begin a recording session (Mac starts buffering audio)
- `voice.stop` — end a recording session
- `voice.transcription` — event from Mac to phone with transcribed text

### MLX Whisper Integration

**Subprocess architecture:**
- cmux desktop spawns a Python subprocess when `voice.start` is received (not on connection)
- Subprocess runs MLX Whisper and communicates via stdin/stdout (line-delimited JSON)
- Swift side writes audio segments to subprocess stdin, reads transcriptions from stdout
- Subprocess stays alive until `voice.stop` + 30 second idle timeout (avoids cold start on next recording)
- On idle timeout, subprocess is terminated gracefully (SIGTERM → 5s → SIGKILL)

**Model:**
- Default: `mlx-community/whisper-small-mlx` (~500MB)
- Configurable to medium for better accuracy (setting in cmux preferences)
- Downloaded on `voice.setup` RPC, cached in `~/.cmux/models/`
- Download uses `huggingface_hub` Python package

**Crash recovery:**
- Crash detected by: subprocess exit (monitored via `Process.waitUntilExit()`) or broken stdin pipe
- On crash: log error, discard the in-flight audio segment (lost)
- Auto-restart on next audio segment arrival (up to 3 restart attempts per session)
- After 3 crashes, send error to phone: `{"type": "error", "message": "Whisper crashed repeatedly. Check logs."}`
- Phone shows toast and stops recording

### Voice Activity Detection (VAD)

Energy-based VAD in Swift (no ML needed):
- Compute RMS energy of each audio frame
- Speech detected when energy exceeds threshold (auto-calibrated from first 500ms of silence)
- Speech segment ends after 500ms of continuous silence
- Minimum segment duration: 300ms (ignore very short noise bursts)
- Maximum segment duration: 30s (force-flush to prevent memory buildup)

### Processing Pipeline

1. Phone sends 16-bit PCM audio as binary frames (channel `0xFFFFFFFF`), ~100ms chunks, silence-suppressed
2. `BridgeServer` routes frames with channel `0xFFFFFFFF` to `VoiceChannel` handler
3. Swift buffers incoming audio and runs VAD
4. When speech segment boundary detected, buffer is written to Whisper subprocess stdin
5. Whisper transcribes (~200-500ms for a 2-3s chunk on Apple Silicon)
6. Result read from subprocess stdout, sent to phone as `voice.transcription` JSON-RPC event

### Segment ID Protocol

- Segment IDs are monotonically increasing integers starting at 1 per session
- Mac sends `voice.processing` event when a segment begins transcription
- Mac sends `voice.transcription` event with the same segment_id when done
- Gaps in segment IDs are expected (noise segments rejected by min-duration filter)
- Phone renders chips in arrival order, ignoring segment_id gaps
- If a `voice.transcription` arrives without a prior `voice.processing` for that ID, phone treats it as valid (processing message is informational only)

## Protocol

### Phone → Mac (JSON-RPC)

```json
// Check if Whisper is ready
{"jsonrpc": "2.0", "method": "voice.check_ready", "id": 1}

// Trigger model download
{"jsonrpc": "2.0", "method": "voice.setup", "id": 2}

// Start a recording session
{"jsonrpc": "2.0", "method": "voice.start", "id": 3}

// Stop a recording session
{"jsonrpc": "2.0", "method": "voice.stop", "id": 4}
```

### Phone → Mac (Binary)

```
// Audio data: binary WebSocket frames with channel prefix
// [4 bytes: 0xFFFFFFFF (voice channel)] [raw PCM audio bytes]
// Format: 16-bit little-endian PCM, 16kHz, mono
// Chunk size: ~100ms (~3200 bytes payload per frame)
// Silence-suppressed: frames below energy threshold are not sent
```

### Mac → Phone (JSON-RPC)

```json
// Ready check response
{"jsonrpc": "2.0", "id": 1, "result": {"ready": true}}
{"jsonrpc": "2.0", "id": 1, "result": {"ready": false, "reason": "model_not_downloaded"}}

// Setup progress events
{"jsonrpc": "2.0", "method": "voice.setup_progress", "params": {"percent": 45, "message": "Downloading whisper-small..."}}

// Session started acknowledgment
{"jsonrpc": "2.0", "id": 3, "result": {"session_id": "abc123"}}

// Processing a segment (informational)
{"jsonrpc": "2.0", "method": "voice.processing", "params": {"segment_id": 1}}

// Transcription result
{"jsonrpc": "2.0", "method": "voice.transcription", "params": {"segment_id": 1, "text": "git status"}}

// Error
{"jsonrpc": "2.0", "method": "voice.error", "params": {"message": "Whisper crashed repeatedly. Check logs."}}
```

## Error Handling

| Scenario | Mac behavior | Phone behavior |
|----------|-------------|----------------|
| MLX Whisper not installed | Respond to `check_ready` with reason | Show setup bottom sheet on mic tap |
| Model not downloaded | Respond to `check_ready` with reason | Show setup bottom sheet with download option |
| Model downloading | Send `setup_progress` events | Show progress in bottom sheet |
| Whisper subprocess crash | Auto-restart (up to 3 attempts) | Brief delay; after 3 crashes, toast + stop recording |
| Connection lost during recording | N/A | Stop recording, show toast, keep uncommitted chips |
| Audio permission denied | N/A | Show system permission dialog, mic button shows badge |
| No speech detected (silence) | No transcription sent | Strip shows waveform but no chips appear |
| Phone-side silence (3s) | No audio frames received | Auto-stop recording in dictation mode |

## Flutter Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `record` | `^5.1.0` | Audio recording — supports raw PCM output at configurable sample rates on Android/iOS. Verified: supports 16kHz 16-bit PCM stream. |
| `web_socket_channel` | `^3.0.2` | Already in pubspec — reused for voice binary frames and RPC |

No new native permissions beyond microphone (already declared in AndroidManifest for future use).

## File Structure (Phone-Side)

```
lib/terminal/
├── voice_button.dart          # Existing placeholder → full dual-mode implementation
├── voice_service.dart         # NEW: Riverpod provider — recording state, audio streaming,
│                              #   chip management, commit/dismiss logic, silence suppression,
│                              #   reads active surface_id from surfaceProvider
├── voice_strip.dart           # NEW: transcription strip UI — waveform, timer, chip scroll,
│                              #   chip dismiss/swipe, commit progress animation
└── voice_protocol.dart        # NEW: JSON-RPC message types, binary frame encoding,
                               #   segment tracking, trigger word detection
```

## File Structure (Mac-Side)

```
Sources/Voice/
├── VoiceChannel.swift         # NEW: binary frame handler for channel 0xFFFFFFFF,
│                              #   routes audio to VAD
├── VoiceCommands.swift        # NEW: JSON-RPC command handlers (check_ready, setup,
│                              #   start, stop)
├── VoiceActivityDetector.swift# NEW: energy-based VAD with auto-calibrating threshold
├── WhisperBridge.swift        # NEW: subprocess lifecycle (spawn, crash detect,
│                              #   restart with backoff, idle timeout, stdin/stdout IPC)
└── WhisperProcess/
    └── whisper_server.py      # NEW: MLX Whisper subprocess — reads audio segments
                               #   from stdin, writes transcriptions to stdout (line JSON)
```
