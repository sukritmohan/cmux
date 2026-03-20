# Voice-to-Terminal: UX Behavior Expectations

**Feature:** Voice input for the Android companion app
**Status:** Implemented
**Last updated:** 2026-03-19

---

## Overview

Voice input enables users to speak commands and dictation on their Android phone and have transcribed text committed to the active Mac terminal pane. The experience is optimized for quick one-liners (hold-to-record) and longer dictation sessions (tap-to-toggle), with a lightweight review step between transcription and terminal submission.

---

## Mic Button

The voice button lives in the modifier bar's middle 2×2 grid, bottom-right cell. It is 36×36px.

### Dual-Mode Activation

**Hold-to-record (quick command mode):**
- Press-and-hold starts recording immediately
- A floating label appears: "recording... release to stop"
- Releasing the button stops recording and processes the final buffered segment
- Intended for short, single-line commands where the user wants direct control

**Tap-to-toggle (dictation mode):**
- A single tap detected at < 250ms press duration toggles recording on
- Tapping again stops recording
- Recording also auto-stops after 3 seconds of continuous silence (see Silence Auto-Stop below)
- Intended for longer dictation or situations where the user needs both hands free

The tap/hold threshold is exactly 250ms (`kTapMaxDuration`). Presses below this duration are classified as taps; presses at or above are holds.

### Visual States

| State | Icon | Background | Additional effect |
|-------|------|------------|-------------------|
| Idle | `mic_none_rounded` (outline) | `keyGroupResting` (6% white) | None |
| Recording | `mic_rounded` (filled, red) | `voiceRecordingBg` (rgba 255,68,68 at ~12%) | Pulsing red box-shadow ring, 1500ms cycle |
| Processing | 16px circular spinner (amber) | amber at ~16% opacity | Spinner while transcription is in flight |
| Setup required | `mic_none_rounded` (outline) | `keyGroupResting` | 6px amber dot badge at top-right corner |

The recording state uses a `BoxShadow` whose alpha and blur radius animate continuously (not a separate ring element) to signal that the mic is live.

Processing state is brief (~200–500ms on Apple Silicon) and appears between recording stop and the first chip arriving. If multiple segments are in flight simultaneously, the button remains in processing state until all arrive.

### Taps During Processing

Taps while `VoiceStatus.processing` are ignored. The button does not respond until the status returns to `idle` (all chips have arrived) or the user is already in `recording` state.

### Setup Required State

`setupRequired` is displayed when the Whisper model has not been downloaded yet. Tapping the button in this state calls `voice.check_ready` and, on a `ready: false` response, shows the model setup bottom sheet. The amber dot badge persists until the model is available.

---

## Model Setup Flow

On the first tap of the mic button when Whisper is not yet available on the Mac:

1. Phone sends `voice.check_ready` RPC
2. Mac responds `{"ready": false, "reason": "model_not_downloaded"}`
3. Phone shows a bottom sheet: "Voice input requires a one-time model download (~500MB) on your Mac. Download now?"
4. User confirms → phone sends `voice.setup` → Mac begins the download via `huggingface_hub`
5. Mac sends `voice.setup_progress` events: `{"percent": N, "message": "Downloading whisper-small..."}`
6. The bottom sheet shows a progress indicator with the current percentage and message
7. On completion (`percent: 100`), the bottom sheet dismisses and the mic button becomes active

If the user dismisses the bottom sheet without confirming, the button state returns to `setupRequired` and no download is started.

This flow is explicit and intentional: avoid silently triggering a ~500MB download the first time a user taps the mic.

---

## Transcription Preview Strip

### When It Appears

The strip slides up from behind the modifier bar when any of the following is true (`VoiceState.isStripVisible`):
- Status is `recording`
- Status is `processing`
- At least one chip is in `pending` or `committing` state

The strip remains visible until all pending/committing chips are either committed or dismissed, even after recording has stopped.

### Slide Animation

- Appearance: `AnimatedSlide` from `Offset(0, 1)` (below) to `Offset.zero` (normal position), 250ms `easeOutCubic`; simultaneous `AnimatedOpacity` fade-in over 200ms
- Disappearance: reverses the same animation

### Layout

```
┌──────────────────────────────────────────────────────────────┐
│ [▓▓ waveform ▓▓] [0:03] [chip: "git status" ×] [chip: "&&" ×] │
│  44×36px          10px    scrollable chip area →               │
└──────────────────────────────────────────────────────────────┘
```

- Height: 52px
- Horizontal margin: 8px (matching modifier bar)
- Background: `rgba(16,16,24,0.90)` with 24px backdrop blur
- Border radius: 14px on top-left and top-right corners only (connects visually to modifier bar below)

### Waveform Visualizer

- 7 animated bars displayed at the left of the strip (44×36px container)
- While recording: bars animate with staggered sine-wave height variation, mapped to [6px, 28px], running at 1200ms/cycle
- While stopped: bars shrink to 4px resting height at 30% opacity
- Bar color: `voiceRecordingRed`

### Recording Timer

- Displayed in JetBrains Mono, 10px, weight 600, color `voiceTimerText`
- Format: `m:ss` (e.g., `0:03`, `1:42`)
- Shown only while `VoiceStatus.recording` and `recordingDuration` is not null
- Increments every second via a periodic `Timer`

---

## Transcription Chips

Each transcribed speech segment becomes a chip in the horizontal scrollable chip area of the strip.

### Chip Lifecycle

```
ARRIVE (from voice.transcription) → PENDING (800ms auto-commit timer starts)
                                          ↓
                                  [user taps × or swipes left]
                                          ↓
                                     DISMISSED (removed from strip)

                              OR: [timer fires]
                                          ↓
                                    COMMITTING (progress bar fills over 800ms)
                                          ↓
                           [text sent as surface.pty.write]
                                          ↓
                                    COMMITTED (chip fades to 40%, shrinks to 95%)
                                          ↓
                          [800ms fade-out timer]
                                          ↓
                                   (chip removed)
```

1. **Arrive** — chip slides in from the right edge of the scroll area
2. **Pending** — chip is visible; user can dismiss it; 800ms countdown to auto-commit begins
3. **Committing** — green progress bar fills from left to right over 800ms; chip border turns green-tinted; user can still dismiss during this phase
4. **Committed** — `surface.pty.write` fires with the full text; chip fades to 40% opacity and scales to 95%; dismiss button is hidden; chip is removed after 800ms
5. **Dismissed** — chip slides left and fades out; removed from the strip after 300ms; text is never sent to the terminal

### Commit Atomicity

When the commit timer fires, the chip transitions synchronously to `committed` state. The dismiss handler checks this flag first — if the chip is already `committed`, dismiss is a no-op. `surface.pty.write` sends the full text in a single message (not character-by-character), eliminating any race window between commit and dismiss.

### Chip Appearance

| Property | Value |
|----------|-------|
| Height | 36px |
| Max width | 200px (text truncates with ellipsis) |
| Border radius | 8px |
| Background (pending) | `voiceChipBg` (rgba 255,255,255 at ~8%) |
| Border (pending) | 1px `voiceChipBorder` (rgba 255,255,255 at ~12%) |
| Background (committing) | green-tinted blend of `voiceCommitGreen` at ~8% over `voiceChipBg` |
| Border (committing) | 1px `voiceCommitBorder` (rgba 80,200,120 at 30%) |
| Font | JetBrains Mono, 11px, weight 500 |
| Progress bar | 2px tall, `voiceCommitGreen`, aligned to bottom of chip |
| Trigger indicator | ⏎ symbol (U+23CE) in `accent` color, before text |

### Chip Dismissal

Two ways to dismiss:
1. **Tap the × button** — 16px close icon at the right of the chip; 24px hit target padded; scales to 93% on press with 80ms animation; `HapticFeedback.lightImpact()` on tap
2. **Swipe left** (startToEnd direction) — using Flutter `Dismissible` with swipe threshold at 50% widget width; `HapticFeedback.lightImpact()` on dismiss

Both gestures are available on `pending` and `committing` chips. Committed chips are non-interactive and have no dismiss button.

### Chip Ordering

Chips are rendered in insertion order (arrival order from the Mac). Gaps in segment IDs (caused by short noise bursts rejected by VAD) do not affect chip ordering — chips are displayed in the order `voice.transcription` messages arrive.

---

## Auto-Commit Timing

- **Delay before countdown starts:** 800ms from chip arrival (`kChipAutoCommitDelay`)
- **Countdown duration:** 800ms (the `_CommitProgressBar` fills over this interval)
- **Total time from chip arrival to commit:** 800ms (the progress bar starts filling immediately when the chip transitions to `committing` state, which happens at 800ms)
- **Fade-out duration after commit:** 800ms before the chip is removed from the strip

The green progress bar animation starts as soon as the chip enters `committing` state. The bar is driven by an `AnimationController` that runs for exactly `kChipAutoCommitDelay`.

---

## Trigger Words

If a transcription ends with a recognized trigger word as the final whitespace-delimited token, the word is stripped and a carriage return is appended to the commit text.

**Trigger words:** `enter`, `run`, `execute`

**Matching rule:** Only whole-word matches at the end of the transcription count. Substrings ("center", "rerun") and prefixes ("executing") do not trigger. The last word is checked case-insensitively after splitting on whitespace.

**Visual indicator:** A ⏎ symbol appears before the chip text, in accent color, to indicate that committing this chip will also submit the command.

**Commit behavior:** The trigger word is stripped from the text, and `\r` (carriage return) is appended to `commitText` before the `surface.pty.write` call. This causes the terminal to execute the command without the user needing to press Enter separately.

**User setting:** Trigger word detection is a user-toggleable preference (default: on).

---

## Silence Auto-Stop

In tap-toggle (dictation) mode only:

- The phone tracks the timestamp of the last non-silent audio frame (`_lastSpeechTime`)
- After each audio chunk, if the current time minus `_lastSpeechTime` exceeds 3 seconds, `stopRecording()` is called automatically
- This matches `kSilenceAutoStopDuration` (3 seconds)
- Hold-to-record mode does NOT auto-stop on silence; the user must release the button

Local silence suppression (suppressing frames with RMS energy below 0.02) is separate from auto-stop logic. Suppressed frames are not transmitted but still count toward the silence auto-stop timer.

---

## Terminal Targeting

The voice service reads the active surface ID from `surfaceProvider` (the same Riverpod provider used by `TerminalView` for PTY writes). All `surface.pty.write` calls include the `surface_id` parameter so the text goes to the correct terminal pane regardless of which surface is focused on the Mac.

---

## Haptic Feedback

| Event | Haptic |
|-------|--------|
| Recording starts (tap or hold) | `HapticFeedback.mediumImpact()` |
| Recording stops (tap, hold release, or auto-stop) | `HapticFeedback.lightImpact()` |
| Chip arrives | `HapticFeedback.selectionClick()` |
| Chip dismissed (swipe or × tap) | `HapticFeedback.lightImpact()` |
| Chip committed (text sent) | No haptic — this occurs silently to avoid constant feedback during rapid dictation |
| Setup bottom sheet trigger tap | `HapticFeedback.lightImpact()` |

---

## Accessibility Semantics

All voice button states expose a `Semantics` widget with `button: true` and a descriptive label.

| Voice status | Semantic label |
|--------------|---------------|
| `idle` | "Voice input" |
| `recording` | "Recording voice, tap to stop" |
| `processing` | "Processing voice input" |
| `setupRequired` | "Voice input, setup required" |

The dismiss button (×) on each chip has a 24px padded hit target (4px all around a 16px icon) for accessibility.

---

## Error Handling (UX)

| Scenario | User-facing behavior |
|----------|---------------------|
| Microphone permission denied | System permission dialog; mic button enters `setupRequired` state with amber badge |
| Model not downloaded | Bottom sheet asking user to confirm a one-time ~500MB download |
| Model download failure | Error message in the setup bottom sheet; user can retry |
| Whisper crash (< 3 times) | Brief delay in transcription; user may not notice single crash due to auto-restart |
| Whisper crash (3 times) | Toast notification; recording stops automatically |
| Connection lost during recording | Recording stops; toast notification; uncommitted chips remain in strip until dismissed |
| No speech detected in silence | Waveform animates but no chips appear; auto-stop fires after 3s |

---

## Connection to Modifier Bar

The `VoiceStrip` is positioned above the modifier bar and below the attachment strip (if both are visible simultaneously). The strip's top-corner-only border radius visually joins it to the modifier bar, making the two feel like a unified control surface when the strip is visible.

When both the attachment strip and the voice strip are visible, the voice strip appears between them (attachment strip → voice strip → modifier bar, top to bottom).
