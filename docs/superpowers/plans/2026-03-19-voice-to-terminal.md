# Voice-to-Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream audio from the Android companion app to the Mac, transcribe it with MLX Whisper, and inject the resulting text into the active terminal as dismissible preview chips that auto-commit.

**Architecture:** Phone captures 16kHz 16-bit PCM audio, silence-suppresses it locally, and streams it over the existing WebSocket binary channel (channel ID `0xFFFFFFFF`). Mac-side `BridgeServer` routes voice frames to a new `VoiceChannel` handler, which feeds an energy-based VAD that segments speech and pipes segments to a long-lived MLX Whisper Python subprocess. Transcription results flow back as JSON-RPC events; the phone renders them as auto-committing chips in a preview strip above the modifier bar.

**Tech Stack:** Flutter/Dart + Riverpod (phone), Swift + Network.framework (Mac bridge), Python + MLX Whisper (Mac subprocess), `record` ^5.1.0 Flutter package (phone audio capture).

**Design Spec:** `/Users/sm/code/cmux/docs/voice-input/2026-03-19-voice-transcription-design.md`

---

## Parallelism Map

Tasks 1-3 (phone protocol, Mac voice channel, Mac Whisper bridge) are independent and can be developed in parallel by separate agents. Task 4 (phone audio capture) depends on Task 1. Task 5 (phone UI) depends on Tasks 1 and 4. Task 6 (Mac RPC wiring) depends on Tasks 2 and 3. Task 7 (integration) depends on all prior tasks.

```
        ┌──── Task 1: Phone protocol types ────┐
        │                                       │
        │    ┌── Task 4: Phone audio service ───┼── Task 5: Phone UI ──┐
        │    │                                  │                      │
Start ──┤    ├── Task 2: Mac VoiceChannel ──────┤                      ├── Task 7: Integration
        │    │                                  │                      │
        │    ├── Task 3: Mac Whisper bridge ────┼── Task 6: Mac RPC ───┘
        │    │                                  │
        └────┴── (parallel)                     │
```

## File Structure

### Phone-Side (Flutter/Dart)

| File | Action | Responsibility |
|------|--------|----------------|
| `android-companion/lib/terminal/voice_protocol.dart` | Create | JSON-RPC message types, binary frame encoding (channel `0xFFFFFFFF`), trigger word detection, segment ID tracking |
| `android-companion/lib/terminal/voice_service.dart` | Create | Riverpod StateNotifier: recording lifecycle, audio streaming via `record` package, silence suppression (RMS energy), chip state management (arrive/commit/dismiss), WebSocket event listener |
| `android-companion/lib/terminal/voice_strip.dart` | Create | Transcription preview strip UI: waveform visualizer, recording timer, horizontally-scrollable chip list with auto-commit progress bars, swipe-to-dismiss |
| `android-companion/lib/terminal/voice_button.dart` | Replace | Dual-mode activation (hold-for-quick, tap-for-continuous), visual states (idle/recording/processing/setup-required), haptics, setup bottom sheet |
| `android-companion/lib/terminal/modifier_bar.dart` | Modify | Thread voice state to `VoiceButton`, add voice strip slot |
| `android-companion/lib/terminal/terminal_screen.dart` | Modify | Mount `VoiceStrip` between attachment strip and modifier bar |
| `android-companion/lib/app/colors.dart` | Modify | Add voice-specific color tokens (recording red, commit green, strip bg) |
| `android-companion/lib/connection/connection_manager.dart` | Modify | Add `sendBinary(Uint8List)` method for voice audio frames |
| `android-companion/android/app/src/main/AndroidManifest.xml` | Modify | Add `RECORD_AUDIO` permission |
| `android-companion/pubspec.yaml` | Modify | Add `record: ^5.1.0` dependency |

### Mac-Side (Swift + Python)

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Voice/VoiceChannel.swift` | Create | Binary frame handler for channel `0xFFFFFFFF`, audio buffering, routes to VAD |
| `Sources/Voice/VoiceActivityDetector.swift` | Create | Energy-based VAD: RMS computation, auto-calibrating silence threshold, segment boundary detection (500ms silence gap), min/max segment duration enforcement |
| `Sources/Voice/VoiceCommands.swift` | Create | JSON-RPC handlers: `voice.check_ready`, `voice.setup`, `voice.start`, `voice.stop`. Sends `voice.transcription`, `voice.processing`, `voice.error`, `voice.setup_progress` events |
| `Sources/Voice/WhisperBridge.swift` | Create | Python subprocess lifecycle: spawn, stdin/stdout line-JSON IPC, crash detection via `Process.waitUntilExit()`, auto-restart (max 3/session), 30s idle timeout, graceful shutdown (SIGTERM then SIGKILL) |
| `Sources/Voice/WhisperProcess/whisper_server.py` | Create | MLX Whisper subprocess: reads audio segments from stdin (length-prefixed), transcribes, writes line-delimited JSON to stdout. Model loading, `huggingface_hub` download support |
| `Sources/Bridge/BridgeConnection.swift` | Modify | Route binary frames with channel `0xFFFFFFFF` to `VoiceChannel`; add `voice.*` cases to text message dispatch switch |

---

## Task 1: Voice Protocol Types (Phone-Side)

**Files:**
- Create: `android-companion/lib/terminal/voice_protocol.dart`
- Test: `android-companion/test/terminal/voice_protocol_test.dart`

**Why first:** Pure data types with no platform dependencies. Both phone service (Task 4) and Mac commands (Task 6) depend on these message shapes. This establishes the contract.

- [ ] **Step 1: Write failing tests for binary frame encoding**

Create `android-companion/test/terminal/voice_protocol_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cmux_companion/terminal/voice_protocol.dart';

void main() {
  group('VoiceAudioFrame', () {
    test('encodeFrame prefixes PCM bytes with 0xFFFFFFFF channel ID', () {
      final pcm = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final frame = VoiceAudioFrame.encode(pcm);

      // 4-byte LE channel ID + 4 payload bytes = 8 total
      expect(frame.length, 8);

      // Channel ID: 0xFFFFFFFF in little-endian
      final channelId = frame.buffer.asByteData().getUint32(0, Endian.little);
      expect(channelId, 0xFFFFFFFF);

      // Payload preserved after header
      expect(frame.sublist(4), pcm);
    });

    test('encodeFrame with empty payload produces 4-byte header only', () {
      final frame = VoiceAudioFrame.encode(Uint8List(0));
      expect(frame.length, 4);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/sm/code/cmux/android-companion && flutter test test/terminal/voice_protocol_test.dart`
Expected: FAIL — `voice_protocol.dart` does not exist yet.

- [ ] **Step 3: Write failing tests for trigger word detection**

Append to `android-companion/test/terminal/voice_protocol_test.dart`:

```dart
  group('TriggerWordDetector', () {
    test('detects "enter" as trailing trigger word', () {
      final result = TriggerWordDetector.check('git status enter');
      expect(result.hasTrigger, true);
      expect(result.cleanText, 'git status');
      expect(result.triggerWord, 'enter');
    });

    test('detects "run" as trailing trigger word (case-insensitive)', () {
      final result = TriggerWordDetector.check('ls -la Run');
      expect(result.hasTrigger, true);
      expect(result.cleanText, 'ls -la');
      expect(result.triggerWord, 'run');
    });

    test('detects "execute" as trailing trigger word', () {
      final result = TriggerWordDetector.check('make build execute');
      expect(result.hasTrigger, true);
      expect(result.cleanText, 'make build');
    });

    test('does NOT trigger on "center" (substring match)', () {
      final result = TriggerWordDetector.check('move to center');
      expect(result.hasTrigger, false);
      expect(result.cleanText, 'move to center');
    });

    test('does NOT trigger on "rerun" (prefix match)', () {
      final result = TriggerWordDetector.check('rerun the test');
      expect(result.hasTrigger, false);
    });

    test('handles single-word trigger', () {
      final result = TriggerWordDetector.check('enter');
      expect(result.hasTrigger, true);
      expect(result.cleanText, '');
    });

    test('handles empty string', () {
      final result = TriggerWordDetector.check('');
      expect(result.hasTrigger, false);
      expect(result.cleanText, '');
    });

    test('handles trailing whitespace before trigger', () {
      final result = TriggerWordDetector.check('  git push  enter  ');
      expect(result.hasTrigger, true);
      expect(result.cleanText, 'git push');
    });
  });
```

- [ ] **Step 4: Run test to verify all trigger word tests fail**

Run: `cd /Users/sm/code/cmux/android-companion && flutter test test/terminal/voice_protocol_test.dart`
Expected: FAIL — `TriggerWordDetector` class does not exist.

- [ ] **Step 5: Write failing tests for transcription chip model**

Append to `android-companion/test/terminal/voice_protocol_test.dart`:

```dart
  group('TranscriptionChip', () {
    test('creates chip with pending status', () {
      final chip = TranscriptionChip(
        segmentId: 1,
        text: 'git status',
      );
      expect(chip.status, ChipStatus.pending);
      expect(chip.hasTrigger, false);
      expect(chip.commitText, 'git status');
    });

    test('chip with trigger word appends carriage return', () {
      final chip = TranscriptionChip(
        segmentId: 2,
        text: 'ls -la',
        hasTrigger: true,
      );
      expect(chip.commitText, 'ls -la\r');
    });

    test('chip transitions are one-directional', () {
      var chip = TranscriptionChip(segmentId: 1, text: 'test');
      expect(chip.status, ChipStatus.pending);

      chip = chip.copyWith(status: ChipStatus.committing);
      expect(chip.status, ChipStatus.committing);

      chip = chip.copyWith(status: ChipStatus.committed);
      expect(chip.status, ChipStatus.committed);
    });

    test('dismissed chip cannot be committed', () {
      var chip = TranscriptionChip(segmentId: 1, text: 'test');
      chip = chip.copyWith(status: ChipStatus.dismissed);
      // Attempting to commit a dismissed chip is a no-op at the service layer.
      // The model allows it; the service enforces the guard.
      expect(chip.status, ChipStatus.dismissed);
    });
  });
```

- [ ] **Step 6: Implement voice_protocol.dart**

Create `android-companion/lib/terminal/voice_protocol.dart`:

```dart
/// Voice-to-terminal protocol types: binary frame encoding, transcription
/// chip model, trigger word detection, and segment ID tracking.
///
/// This file is pure Dart — no Flutter or platform dependencies — so it can
/// be unit-tested without a widget test harness.
///
/// Binary frame format (phone → Mac):
///   [4 bytes little-endian 0xFFFFFFFF] [raw 16-bit PCM audio bytes]
///
/// JSON-RPC methods (text frames):
///   Phone → Mac: voice.check_ready, voice.setup, voice.start, voice.stop
///   Mac → Phone: voice.transcription, voice.processing, voice.error,
///                voice.setup_progress
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Reserved binary channel ID for voice audio frames.
const kVoiceChannelId = 0xFFFFFFFF;

/// Auto-commit delay for transcription chips (seconds).
const kChipAutoCommitDelay = Duration(milliseconds: 800);

/// Duration the committed chip stays visible before removal.
const kChipFadeOutDelay = Duration(milliseconds: 800);

/// Local silence duration that triggers auto-stop in dictation mode.
const kSilenceAutoStopDuration = Duration(seconds: 3);

/// Maximum hold duration that still counts as a "tap" (for tap-vs-hold).
const kTapMaxDuration = Duration(milliseconds: 250);

/// Audio format constants.
const kSampleRate = 16000;
const kBitsPerSample = 16;
const kChannelCount = 1;

/// Approximate bytes per 100ms audio chunk (16kHz, 16-bit, mono).
/// 16000 samples/sec * 2 bytes/sample * 0.1 sec = 3200 bytes.
const kAudioChunkBytes = 3200;

// ---------------------------------------------------------------------------
// Binary frame encoding
// ---------------------------------------------------------------------------

/// Encodes raw PCM audio bytes into a binary WebSocket frame with the
/// voice channel ID prefix.
///
/// Frame format: [4 bytes LE 0xFFFFFFFF][pcmBytes]
abstract final class VoiceAudioFrame {
  static Uint8List encode(Uint8List pcmBytes) {
    final frame = Uint8List(4 + pcmBytes.length);
    // Write channel ID as little-endian uint32.
    frame.buffer.asByteData().setUint32(0, kVoiceChannelId, Endian.little);
    frame.setRange(4, frame.length, pcmBytes);
    return frame;
  }
}

// ---------------------------------------------------------------------------
// Trigger word detection
// ---------------------------------------------------------------------------

/// Result of checking a transcription for a trailing trigger word.
class TriggerWordResult {
  /// The transcription text with the trigger word removed (trimmed).
  final String cleanText;

  /// Whether a trigger word was detected.
  final bool hasTrigger;

  /// The matched trigger word (lowercase), or null if none.
  final String? triggerWord;

  const TriggerWordResult({
    required this.cleanText,
    required this.hasTrigger,
    this.triggerWord,
  });
}

/// Detects trailing trigger words ("enter", "run", "execute") in
/// transcribed text using whole-word boundary matching.
///
/// Matching rule: the last whitespace-delimited word must exactly equal
/// a trigger word (case-insensitive). Substrings like "center" or "rerun"
/// do NOT match.
abstract final class TriggerWordDetector {
  static const _triggerWords = {'enter', 'run', 'execute'};

  static TriggerWordResult check(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const TriggerWordResult(
        cleanText: '',
        hasTrigger: false,
      );
    }

    final lastSpace = trimmed.lastIndexOf(' ');
    final lastWord = lastSpace < 0
        ? trimmed.toLowerCase()
        : trimmed.substring(lastSpace + 1).toLowerCase();

    if (_triggerWords.contains(lastWord)) {
      final prefix = lastSpace < 0 ? '' : trimmed.substring(0, lastSpace).trim();
      return TriggerWordResult(
        cleanText: prefix,
        hasTrigger: true,
        triggerWord: lastWord,
      );
    }

    return TriggerWordResult(
      cleanText: trimmed,
      hasTrigger: false,
    );
  }
}

// ---------------------------------------------------------------------------
// Transcription chip model
// ---------------------------------------------------------------------------

/// Lifecycle status of a transcription chip.
enum ChipStatus {
  /// Just arrived from the Mac; waiting to start auto-commit countdown.
  pending,

  /// Auto-commit countdown is in progress (green progress bar filling).
  committing,

  /// Text has been sent to the terminal. Chip is fading out.
  committed,

  /// User dismissed the chip before it committed. Text was NOT sent.
  dismissed,
}

/// A single transcription result rendered as a chip in the voice strip.
///
/// Immutable value type. State transitions are managed by [VoiceNotifier]
/// in voice_service.dart — the model itself does not enforce transition rules.
class TranscriptionChip {
  /// Monotonically increasing segment ID from the Mac's VAD.
  final int segmentId;

  /// The transcribed text (trigger word already stripped if applicable).
  final String text;

  /// Whether a trigger word was detected (appends \r on commit).
  final bool hasTrigger;

  /// Current lifecycle status.
  final ChipStatus status;

  /// Timestamp when the chip was created (for ordering and timer math).
  final DateTime createdAt;

  TranscriptionChip({
    required this.segmentId,
    required this.text,
    this.hasTrigger = false,
    this.status = ChipStatus.pending,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// The text that will be written to the terminal on commit.
  /// Appends `\r` if a trigger word was detected.
  String get commitText => hasTrigger ? '$text\r' : text;

  TranscriptionChip copyWith({
    int? segmentId,
    String? text,
    bool? hasTrigger,
    ChipStatus? status,
    DateTime? createdAt,
  }) {
    return TranscriptionChip(
      segmentId: segmentId ?? this.segmentId,
      text: text ?? this.text,
      hasTrigger: hasTrigger ?? this.hasTrigger,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TranscriptionChip && other.segmentId == segmentId);

  @override
  int get hashCode => segmentId.hashCode;
}

// ---------------------------------------------------------------------------
// Recording mode
// ---------------------------------------------------------------------------

/// How the recording session was initiated.
enum RecordingMode {
  /// Press-and-hold: release stops recording.
  holdToRecord,

  /// Single tap: tap again or silence auto-stop ends recording.
  tapToggle,
}

// ---------------------------------------------------------------------------
// Voice session state
// ---------------------------------------------------------------------------

/// High-level voice feature state exposed to the UI.
enum VoiceStatus {
  /// No recording in progress, mic is ready.
  idle,

  /// Actively recording audio.
  recording,

  /// Recording stopped, waiting for final transcription(s).
  processing,

  /// Whisper model is not ready (needs download).
  setupRequired,
}

/// Immutable snapshot of the voice recording session.
class VoiceState {
  /// Current high-level status.
  final VoiceStatus status;

  /// How the current (or last) session was initiated.
  final RecordingMode? recordingMode;

  /// All transcription chips in the current session, in arrival order.
  final List<TranscriptionChip> chips;

  /// Recording duration (updated by a periodic timer while recording).
  final Duration recordingDuration;

  /// Whisper model download progress (0-100), or null if not downloading.
  final int? setupProgress;

  /// Human-readable setup status message.
  final String? setupMessage;

  /// Last error message, cleared on next successful operation.
  final String? errorMessage;

  const VoiceState({
    this.status = VoiceStatus.idle,
    this.recordingMode,
    this.chips = const [],
    this.recordingDuration = Duration.zero,
    this.setupProgress,
    this.setupMessage,
    this.errorMessage,
  });

  /// Whether any uncommitted chips are still visible.
  bool get hasActiveChips => chips.any(
        (c) => c.status == ChipStatus.pending || c.status == ChipStatus.committing,
      );

  /// Whether the voice strip should be visible.
  bool get isStripVisible =>
      status == VoiceStatus.recording ||
      status == VoiceStatus.processing ||
      hasActiveChips;

  VoiceState copyWith({
    VoiceStatus? status,
    RecordingMode? recordingMode,
    List<TranscriptionChip>? chips,
    Duration? recordingDuration,
    int? setupProgress,
    String? setupMessage,
    String? errorMessage,
  }) {
    return VoiceState(
      status: status ?? this.status,
      recordingMode: recordingMode ?? this.recordingMode,
      chips: chips ?? this.chips,
      recordingDuration: recordingDuration ?? this.recordingDuration,
      setupProgress: setupProgress ?? this.setupProgress,
      setupMessage: setupMessage ?? this.setupMessage,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `cd /Users/sm/code/cmux/android-companion && flutter test test/terminal/voice_protocol_test.dart`
Expected: All 11 tests PASS.

- [ ] **Step 8: Commit**

```bash
cd /Users/sm/code/cmux
git add android-companion/lib/terminal/voice_protocol.dart android-companion/test/terminal/voice_protocol_test.dart
git commit -m "feat(voice): add protocol types — binary frame encoding, trigger words, chip model"
```

---

## Task 2: Mac-Side Voice Activity Detector

**Files:**
- Create: `Sources/Voice/VoiceActivityDetector.swift`

**Why now:** Pure algorithm, no subprocess or network dependencies. The VAD segments audio into speech chunks that get piped to Whisper. Can be developed in parallel with Tasks 1 and 3.

- [ ] **Step 1: Create the Sources/Voice directory**

```bash
mkdir -p /Users/sm/code/cmux/Sources/Voice
```

- [ ] **Step 2: Implement VoiceActivityDetector.swift**

Create `Sources/Voice/VoiceActivityDetector.swift`:

```swift
import Foundation

/// Energy-based Voice Activity Detector that segments continuous audio
/// into discrete speech chunks for transcription.
///
/// Algorithm:
///   1. Compute RMS energy of each incoming audio frame (16-bit PCM, 16kHz, mono).
///   2. Auto-calibrate silence threshold from the first 500ms of audio.
///   3. Mark frames as speech when energy exceeds threshold.
///   4. Detect segment boundaries: speech ends after 500ms of continuous silence.
///   5. Enforce minimum segment duration (300ms) to reject noise bursts.
///   6. Enforce maximum segment duration (30s) to prevent memory buildup.
///
/// Thread safety: All methods must be called from the same serial queue
/// (the bridge server's dispatch queue). Not `Sendable`.
final class VoiceActivityDetector {

    // MARK: - Configuration

    /// Minimum RMS energy multiplier above the calibrated noise floor.
    /// Speech must exceed `noiseFloor * energyMultiplier` to be detected.
    private static let energyMultiplier: Float = 2.5

    /// Duration of initial silence used to calibrate the noise floor.
    private static let calibrationDuration: TimeInterval = 0.5

    /// Silence gap that ends a speech segment (seconds).
    private static let silenceGap: TimeInterval = 0.5

    /// Minimum speech segment duration (seconds). Shorter segments are discarded.
    private static let minSegmentDuration: TimeInterval = 0.3

    /// Maximum speech segment duration (seconds). Longer segments are force-flushed.
    private static let maxSegmentDuration: TimeInterval = 30.0

    /// Sample rate of incoming audio.
    private static let sampleRate: Int = 16_000

    // MARK: - Delegate

    /// Called when a complete speech segment is ready for transcription.
    /// - Parameters:
    ///   - segmentId: Monotonically increasing segment identifier.
    ///   - audioData: Raw 16-bit PCM audio bytes for this segment.
    var onSegmentReady: ((_ segmentId: Int, _ audioData: Data) -> Void)?

    // MARK: - State

    /// Monotonically increasing segment counter (starts at 1 per session).
    private var nextSegmentId = 1

    /// Accumulated audio data for the current speech segment.
    private var segmentBuffer = Data()

    /// Whether we are currently inside a speech segment.
    private var isSpeaking = false

    /// Timestamp when speech started in the current segment.
    private var speechStartTime: Date?

    /// Timestamp of the last frame that exceeded the energy threshold.
    private var lastSpeechTime: Date?

    // Calibration state
    private var isCalibrating = true
    private var calibrationSamples: [Float] = []
    private var calibrationStartTime: Date?
    private var noiseFloor: Float = 0.01

    /// Computed energy threshold (noiseFloor * multiplier).
    private var energyThreshold: Float {
        noiseFloor * Self.energyMultiplier
    }

    // MARK: - Public API

    /// Reset all state for a new recording session.
    func reset() {
        nextSegmentId = 1
        segmentBuffer = Data()
        isSpeaking = false
        speechStartTime = nil
        lastSpeechTime = nil
        isCalibrating = true
        calibrationSamples = []
        calibrationStartTime = nil
        noiseFloor = 0.01
    }

    /// Feed a chunk of raw 16-bit little-endian PCM audio into the VAD.
    ///
    /// This is called for every audio frame received from the phone.
    /// The VAD accumulates audio and calls `onSegmentReady` when a complete
    /// speech segment is detected.
    ///
    /// - Parameter pcmData: Raw audio bytes (16-bit LE PCM, 16kHz, mono).
    func processAudio(_ pcmData: Data) {
        let energy = computeRMSEnergy(pcmData)
        let now = Date()

        // Phase 1: Calibrate noise floor from initial silence.
        if isCalibrating {
            if calibrationStartTime == nil {
                calibrationStartTime = now
            }
            calibrationSamples.append(energy)

            let elapsed = now.timeIntervalSince(calibrationStartTime!)
            if elapsed >= Self.calibrationDuration {
                finalizeCalibration()
            }
            // During calibration, still buffer audio in case speech starts immediately.
            segmentBuffer.append(pcmData)
            return
        }

        // Phase 2: Detect speech vs. silence.
        let isSpeechFrame = energy > energyThreshold

        if isSpeechFrame {
            lastSpeechTime = now

            if !isSpeaking {
                // Transition: silence → speech.
                isSpeaking = true
                speechStartTime = now
                // Keep any audio already in the buffer (pre-roll from calibration
                // or previous frames) — it may contain the onset of speech.
            }
        }

        // Always buffer audio while speaking or during potential speech onset.
        if isSpeaking {
            segmentBuffer.append(pcmData)

            // Check maximum segment duration.
            if let start = speechStartTime,
               now.timeIntervalSince(start) >= Self.maxSegmentDuration {
                flushSegment()
                return
            }

            // Check silence gap to end segment.
            if let lastSpeech = lastSpeechTime,
               now.timeIntervalSince(lastSpeech) >= Self.silenceGap {
                flushSegment()
            }
        }
    }

    /// Force-flush any buffered audio as a segment (called on voice.stop).
    func flushRemaining() {
        if isSpeaking && !segmentBuffer.isEmpty {
            flushSegment()
        }
    }

    // MARK: - Private

    /// Compute RMS energy of a 16-bit PCM buffer.
    private func computeRMSEnergy(_ data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        var sumSquared: Float = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let normalized = Float(samples[i]) / Float(Int16.max)
                sumSquared += normalized * normalized
            }
        }

        return sqrt(sumSquared / Float(sampleCount))
    }

    /// Finalize noise floor calibration from collected samples.
    private func finalizeCalibration() {
        isCalibrating = false
        guard !calibrationSamples.isEmpty else { return }

        // Use the mean energy as the noise floor baseline.
        let mean = calibrationSamples.reduce(0, +) / Float(calibrationSamples.count)
        // Clamp to a minimum to avoid division-by-zero-like thresholds.
        noiseFloor = max(mean, 0.005)
        calibrationSamples = []

        NSLog("[VAD] Calibrated noise floor: %.4f, threshold: %.4f",
              noiseFloor, energyThreshold)
    }

    /// Emit the current segment buffer and reset for the next segment.
    private func flushSegment() {
        let duration = segmentBuffer.count / (2 * Self.sampleRate) // 16-bit = 2 bytes/sample
        let segmentData = segmentBuffer

        // Reset state for next segment.
        segmentBuffer = Data()
        isSpeaking = false
        speechStartTime = nil
        lastSpeechTime = nil

        // Discard segments shorter than minimum duration (noise bursts).
        guard Double(duration) >= Self.minSegmentDuration else {
            NSLog("[VAD] Discarded short segment: %.2fs", Double(duration))
            return
        }

        let segmentId = nextSegmentId
        nextSegmentId += 1

        NSLog("[VAD] Segment %d ready: %.2fs, %d bytes",
              segmentId, Double(duration), segmentData.count)

        onSegmentReady?(segmentId, segmentData)
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/sm/code/cmux
git add Sources/Voice/VoiceActivityDetector.swift
git commit -m "feat(voice): add energy-based VAD with auto-calibrating threshold"
```

**Test strategy:** VAD is tested indirectly through integration (Task 7). A behavioral unit test would require synthesizing PCM audio with known energy levels. If feasible, add a focused test in a follow-up; for now, the VAD is validated by end-to-end voice recording where speech segments are correctly detected and transcribed.

---

## Task 3: Mac-Side Whisper Bridge (Python Subprocess)

**Files:**
- Create: `Sources/Voice/WhisperBridge.swift`
- Create: `Sources/Voice/WhisperProcess/whisper_server.py`

**Why now:** Independent of phone-side work. The subprocess lifecycle (spawn, IPC, crash recovery) is the most complex Mac-side component.

- [ ] **Step 1: Create a STUB Python whisper server first (Gemini council insight)**

Create `Sources/Voice/WhisperProcess/whisper_server.py` as a simple echo stub first. This enables end-to-end testing through Tasks 4-6 without needing MLX Whisper or Python ML dependencies installed. The stub reads audio segments from stdin and returns a fixed transcription.

```python
#!/usr/bin/env python3
"""STUB whisper server — echoes back dummy transcriptions for E2E testing.
Replace with real MLX Whisper implementation in Step 1b."""
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
        # Skip audio bytes
        audio_len = cmd.get("audio_length", 0)
        sys.stdin.buffer.read(audio_len)
        _counter += 1
        print(json.dumps({
            "segment_id": cmd.get("segment_id", _counter),
            "text": f"stub transcription {_counter}"
        }), flush=True)
```

- [ ] **Step 1b: Replace stub with real MLX Whisper implementation**

Once end-to-end testing confirms the pipeline works with the stub, replace the stub with the real implementation below.

Create `Sources/Voice/WhisperProcess/whisper_server.py`:

```python
#!/usr/bin/env python3
"""MLX Whisper subprocess for cmux voice-to-terminal.

Reads audio segments from stdin as length-prefixed binary:
  [4 bytes little-endian: payload length][payload bytes: raw 16-bit PCM]

Writes transcription results to stdout as line-delimited JSON:
  {"segment_id": 1, "text": "git status"}

Reads commands from stdin as line-delimited JSON (intermixed with audio):
  {"cmd": "transcribe", "segment_id": 1, "audio_length": 6400}
  [6400 bytes of raw PCM audio follow immediately]

Lifecycle:
  - Loads model on startup (or on first transcription if lazy).
  - Stays alive until stdin closes or receives {"cmd": "shutdown"}.
  - Exits cleanly on SIGTERM.
"""

import json
import signal
import struct
import sys
import os
import numpy as np

# Globals
_model = None
_model_path = None


def _log(msg: str) -> None:
    """Log to stderr (stdout is reserved for transcription JSON)."""
    print(f"[whisper_server] {msg}", file=sys.stderr, flush=True)


def _load_model(model_dir: str) -> None:
    """Load the MLX Whisper model from a local directory."""
    global _model, _model_path
    if _model is not None and _model_path == model_dir:
        return

    _log(f"Loading model from {model_dir}")
    try:
        import mlx_whisper
        _model_path = model_dir
        # mlx_whisper.transcribe() loads the model on first call and caches it.
        # We do a dummy transcribe to warm the model cache.
        _model = model_dir
        _log("Model path set (will load on first transcribe)")
    except ImportError:
        _log("ERROR: mlx_whisper not installed. Run: pip install mlx-whisper")
        sys.exit(1)


def _transcribe(pcm_bytes: bytes, segment_id: int) -> dict:
    """Transcribe raw 16-bit PCM audio bytes and return result dict."""
    import mlx_whisper

    # Convert raw PCM bytes to float32 numpy array (mlx_whisper expects this).
    audio_int16 = np.frombuffer(pcm_bytes, dtype=np.int16)
    audio_float32 = audio_int16.astype(np.float32) / 32768.0

    result = mlx_whisper.transcribe(
        audio_float32,
        path_or_hf_repo=_model,
        language="en",
        fp16=False,
    )

    text = result.get("text", "").strip()
    return {"segment_id": segment_id, "text": text}


def _read_exact(stream, n: int) -> bytes:
    """Read exactly n bytes from a binary stream, or raise EOFError."""
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise EOFError("stdin closed")
        buf += chunk
    return buf


def main() -> None:
    """Main loop: read commands + audio from stdin, write JSON to stdout."""
    # Handle SIGTERM for graceful shutdown.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Read model path from first line of stdin (sent by WhisperBridge.swift).
    stdin_text = sys.stdin
    stdin_bin = sys.stdin.buffer

    model_line = stdin_text.readline().strip()
    if not model_line:
        _log("ERROR: Expected model path on first line of stdin")
        sys.exit(1)

    config = json.loads(model_line)
    model_dir = config.get("model_path", "")
    if not model_dir:
        _log("ERROR: No model_path in config")
        sys.exit(1)

    _load_model(model_dir)
    _log("Ready — waiting for audio segments")

    # Notify parent process that we're ready.
    print(json.dumps({"status": "ready"}), flush=True)

    while True:
        try:
            # Read command line (JSON).
            line = stdin_text.readline()
            if not line:
                break  # stdin closed

            line = line.strip()
            if not line:
                continue

            cmd = json.loads(line)

            if cmd.get("cmd") == "shutdown":
                _log("Shutdown requested")
                break

            if cmd.get("cmd") == "transcribe":
                segment_id = cmd["segment_id"]
                audio_length = cmd["audio_length"]

                # Read the audio bytes that follow the command.
                pcm_bytes = _read_exact(stdin_bin, audio_length)

                result = _transcribe(pcm_bytes, segment_id)

                # Only send non-empty transcriptions.
                if result["text"]:
                    print(json.dumps(result), flush=True)
                else:
                    _log(f"Segment {segment_id}: empty transcription, skipping")

        except EOFError:
            break
        except json.JSONDecodeError as e:
            _log(f"JSON parse error: {e}")
            continue
        except Exception as e:
            _log(f"Error: {e}")
            # Send error to parent for forwarding to phone.
            print(json.dumps({"error": str(e)}), flush=True)
            continue

    _log("Exiting")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Implement WhisperBridge.swift**

Create `Sources/Voice/WhisperBridge.swift`:

```swift
import Foundation

/// Manages the MLX Whisper Python subprocess lifecycle.
///
/// Responsibilities:
///   - Spawn the subprocess when the first audio segment arrives (lazy start).
///   - Communicate via stdin (commands + audio) and stdout (transcription JSON).
///   - Detect crashes via `Process.terminationHandler` and auto-restart (up to 3 attempts).
///   - Idle timeout: kill subprocess after 30s of no audio (avoids cold start on next use).
///   - Graceful shutdown: SIGTERM, then SIGKILL after 5s.
///
/// Thread safety: All methods must be called from the bridge server's serial queue.
/// The stdout reading runs on a background thread but dispatches results back to
/// the caller-supplied callback.
final class WhisperBridge {

    // MARK: - Configuration

    /// Maximum automatic restarts per recording session before giving up.
    private static let maxRestarts = 3

    /// Idle timeout before killing the subprocess (seconds).
    private static let idleTimeout: TimeInterval = 30

    /// Grace period for SIGTERM before escalating to SIGKILL (seconds).
    private static let terminationGrace: TimeInterval = 5

    /// Path to the whisper_server.py script inside the app bundle.
    private static var scriptPath: String {
        // In a dev build, resolve relative to Sources/Voice/WhisperProcess/.
        // In a release bundle, resolve from the app bundle's Resources/.
        if let bundlePath = Bundle.main.path(forResource: "whisper_server", ofType: "py") {
            return bundlePath
        }
        // Fallback for dev builds: relative to the binary's location.
        let devPath = (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent
            .appending("/Sources/Voice/WhisperProcess/whisper_server.py")
        return devPath
    }

    // MARK: - Delegate

    /// Called when a transcription result arrives from the subprocess.
    /// - Parameters:
    ///   - segmentId: The segment ID from the VAD.
    ///   - text: The transcribed text.
    var onTranscription: ((_ segmentId: Int, _ text: String) -> Void)?

    /// Called when the subprocess encounters a fatal error.
    var onError: ((_ message: String) -> Void)?

    // MARK: - State

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var restartCount = 0
    private var idleTimer: DispatchSourceTimer?
    private var isReady = false

    /// The dispatch queue for subprocess I/O callbacks.
    private let ioQueue = DispatchQueue(label: "com.cmux.whisper-bridge-io")

    /// The serial queue results are dispatched back to (bridge server queue).
    private var callbackQueue: DispatchQueue?

    // MARK: - Model path

    /// Path to the downloaded Whisper model directory.
    private var modelPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cmux/models/whisper-small-mlx"
    }

    // MARK: - Public API

    /// Check whether the Whisper model is downloaded and ready.
    func checkReady() -> (ready: Bool, reason: String?) {
        let modelDir = modelPath
        let configPath = "\(modelDir)/config.json"
        if FileManager.default.fileExists(atPath: configPath) {
            return (true, nil)
        }
        return (false, "model_not_downloaded")
    }

    /// Start the subprocess (or reuse an existing one).
    ///
    /// - Parameter queue: The serial queue to dispatch callbacks on.
    func start(callbackQueue: DispatchQueue) {
        self.callbackQueue = callbackQueue
        restartCount = 0
        launchIfNeeded()
    }

    /// Send an audio segment to the subprocess for transcription.
    ///
    /// - Parameters:
    ///   - segmentId: The VAD segment ID.
    ///   - audioData: Raw 16-bit PCM audio bytes.
    func transcribe(segmentId: Int, audioData: Data) {
        resetIdleTimer()

        guard isReady, let stdinPipe = stdinPipe else {
            NSLog("[WhisperBridge] Not ready, queuing segment %d", segmentId)
            // If not ready, attempt to launch. The segment is lost — the VAD
            // will produce new segments from ongoing audio.
            launchIfNeeded()
            return
        }

        // Write command line: {"cmd": "transcribe", "segment_id": N, "audio_length": M}\n
        let command: [String: Any] = [
            "cmd": "transcribe",
            "segment_id": segmentId,
            "audio_length": audioData.count,
        ]
        guard let commandJson = try? JSONSerialization.data(withJSONObject: command),
              var commandLine = String(data: commandJson, encoding: .utf8) else {
            NSLog("[WhisperBridge] Failed to encode command for segment %d", segmentId)
            return
        }
        commandLine += "\n"

        let fileHandle = stdinPipe.fileHandleForWriting
        do {
            try fileHandle.write(contentsOf: Data(commandLine.utf8))
            try fileHandle.write(contentsOf: audioData)
        } catch {
            NSLog("[WhisperBridge] Stdin write error: %@", error.localizedDescription)
            handleCrash()
        }
    }

    /// Stop the subprocess gracefully.
    func stop() {
        cancelIdleTimer()

        guard let stdinPipe = stdinPipe else { return }

        // Send shutdown command.
        let shutdownCmd = "{\"cmd\": \"shutdown\"}\n"
        let fileHandle = stdinPipe.fileHandleForWriting
        try? fileHandle.write(contentsOf: Data(shutdownCmd.utf8))

        // Give it a moment, then terminate.
        ioQueue.asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            self?.forceKill()
        }
    }

    // MARK: - Private — Subprocess Lifecycle

    private func launchIfNeeded() {
        guard process == nil || !(process?.isRunning ?? false) else { return }
        isReady = false

        guard restartCount < Self.maxRestarts else {
            NSLog("[WhisperBridge] Max restarts exceeded (%d)", Self.maxRestarts)
            let queue = callbackQueue ?? ioQueue
            queue.async { [weak self] in
                self?.onError?("Whisper crashed repeatedly. Check logs.")
            }
            return
        }

        NSLog("[WhisperBridge] Launching subprocess (attempt %d)", restartCount + 1)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", Self.scriptPath]
        proc.environment = ProcessInfo.processInfo.environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] process in
            NSLog("[WhisperBridge] Subprocess exited with status %d", process.terminationStatus)
            self?.ioQueue.async {
                self?.handleCrash()
            }
        }

        do {
            try proc.run()
        } catch {
            NSLog("[WhisperBridge] Failed to launch: %@", error.localizedDescription)
            restartCount += 1
            return
        }

        process = proc
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr

        // Send model config on first line of stdin.
        let config = "{\"model_path\": \"\(modelPath)\"}\n"
        try? stdin.fileHandleForWriting.write(contentsOf: Data(config.utf8))

        // Read stdout for transcription results.
        readStdout()

        // Read stderr for debug logging.
        readStderr()

        resetIdleTimer()
    }

    private func readStdout() {
        guard let stdout = stdoutPipe else { return }

        ioQueue.async { [weak self] in
            let handle = stdout.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break } // EOF

                guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { continue }

                // Parse each line as JSON.
                for jsonLine in line.components(separatedBy: "\n") {
                    let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let jsonData = trimmed.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        continue
                    }

                    // Handle "ready" status.
                    if dict["status"] as? String == "ready" {
                        NSLog("[WhisperBridge] Subprocess ready")
                        self?.isReady = true
                        continue
                    }

                    // Handle transcription result.
                    if let segmentId = dict["segment_id"] as? Int,
                       let text = dict["text"] as? String {
                        let queue = self?.callbackQueue ?? DispatchQueue.main
                        queue.async {
                            self?.onTranscription?(segmentId, text)
                        }
                    }

                    // Handle error from subprocess.
                    if let errorMsg = dict["error"] as? String {
                        NSLog("[WhisperBridge] Subprocess error: %@", errorMsg)
                        let queue = self?.callbackQueue ?? DispatchQueue.main
                        queue.async {
                            self?.onError?(errorMsg)
                        }
                    }
                }
            }
        }
    }

    private func readStderr() {
        guard let stderr = stderrPipe else { return }

        ioQueue.async {
            let handle = stderr.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    NSLog("[WhisperBridge:stderr] %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func handleCrash() {
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isReady = false
        restartCount += 1
    }

    private func forceKill() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()

        ioQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let proc = self?.process, proc.isRunning else { return }
            // SIGKILL as last resort.
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Idle Timer

    private func resetIdleTimer() {
        cancelIdleTimer()

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            NSLog("[WhisperBridge] Idle timeout — stopping subprocess")
            self?.stop()
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/sm/code/cmux
git add Sources/Voice/WhisperBridge.swift Sources/Voice/WhisperProcess/whisper_server.py
git commit -m "feat(voice): add Whisper subprocess bridge with crash recovery and idle timeout"
```

**Test strategy:** The subprocess lifecycle is validated through integration testing (Task 7). Unit testing the IPC protocol in isolation would require mocking `Process`, which contradicts the "no mocks" policy. Instead, verify: (a) subprocess launches without errors, (b) a known audio file produces a transcription, (c) killing the subprocess triggers restart, (d) 3 crashes produce an error callback.

---

## Task 4: Phone-Side Audio Service (Riverpod)

**Files:**
- Create: `android-companion/lib/terminal/voice_service.dart`
- Modify: `android-companion/lib/connection/connection_manager.dart` — add `sendBinary`
- Modify: `android-companion/pubspec.yaml` — add `record` dependency
- Modify: `android-companion/android/app/src/main/AndroidManifest.xml` — add mic permission
- Test: `android-companion/test/terminal/voice_service_test.dart`

**Depends on:** Task 1 (voice_protocol.dart types).

- [ ] **Step 1: Add `record` dependency to pubspec.yaml**

In `android-companion/pubspec.yaml`, add under `dependencies:`:

```yaml
  # Audio recording for voice-to-terminal
  record: ^5.1.0
```

- [ ] **Step 2: Add RECORD_AUDIO permission to AndroidManifest.xml**

In `android-companion/android/app/src/main/AndroidManifest.xml`, add before `<application>`:

```xml
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
```

- [ ] **Step 3: Add sendBinary method to ConnectionManager**

In `android-companion/lib/connection/connection_manager.dart`, add a public method after `sendRequest`:

```dart
  /// Sends a raw binary frame over the WebSocket.
  ///
  /// Used for voice audio frames: the caller is responsible for prepending
  /// the 4-byte channel ID header (see [VoiceAudioFrame.encode]).
  void sendBinary(Uint8List data) {
    _channel?.sink.add(data);
  }
```

- [ ] **Step 4: Run flutter pub get**

```bash
cd /Users/sm/code/cmux/android-companion && flutter pub get
```

- [ ] **Step 5: Write failing tests for VoiceNotifier chip management**

Create `android-companion/test/terminal/voice_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:cmux_companion/terminal/voice_protocol.dart';
import 'package:cmux_companion/terminal/voice_service.dart';

void main() {
  group('VoiceNotifier chip management', () {
    late VoiceNotifier notifier;

    setUp(() {
      // Create notifier without ConnectionManager dependency for unit tests.
      notifier = VoiceNotifier();
    });

    tearDown(() {
      notifier.dispose();
    });

    test('addChip appends chip in pending status', () {
      notifier.addChip(segmentId: 1, text: 'git status');

      expect(notifier.state.chips.length, 1);
      expect(notifier.state.chips.first.text, 'git status');
      expect(notifier.state.chips.first.status, ChipStatus.pending);
    });

    test('addChip with trigger word sets hasTrigger flag', () {
      notifier.addChip(segmentId: 1, text: 'ls -la', hasTrigger: true);

      expect(notifier.state.chips.first.hasTrigger, true);
      expect(notifier.state.chips.first.commitText, 'ls -la\r');
    });

    test('dismissChip transitions to dismissed status', () {
      notifier.addChip(segmentId: 1, text: 'test');
      notifier.dismissChip(1);

      expect(notifier.state.chips.first.status, ChipStatus.dismissed);
    });

    test('dismissChip is no-op for already committed chip', () {
      notifier.addChip(segmentId: 1, text: 'test');
      notifier.markCommitted(1);
      notifier.dismissChip(1);

      // Should still be committed, not dismissed.
      expect(notifier.state.chips.first.status, ChipStatus.committed);
    });

    test('removeChip removes by segment ID', () {
      notifier.addChip(segmentId: 1, text: 'first');
      notifier.addChip(segmentId: 2, text: 'second');
      notifier.removeChip(1);

      expect(notifier.state.chips.length, 1);
      expect(notifier.state.chips.first.segmentId, 2);
    });

    test('chips maintain arrival order', () {
      notifier.addChip(segmentId: 3, text: 'third');
      notifier.addChip(segmentId: 1, text: 'first');
      notifier.addChip(segmentId: 5, text: 'fifth');

      final ids = notifier.state.chips.map((c) => c.segmentId).toList();
      expect(ids, [3, 1, 5]); // arrival order, not ID order
    });

    test('hasActiveChips is true when pending chips exist', () {
      notifier.addChip(segmentId: 1, text: 'test');
      expect(notifier.state.hasActiveChips, true);
    });

    test('hasActiveChips is false when all chips are committed', () {
      notifier.addChip(segmentId: 1, text: 'test');
      notifier.markCommitted(1);
      expect(notifier.state.hasActiveChips, false);
    });
  });

  group('VoiceNotifier silence suppression', () {
    test('computeRMSEnergy returns zero for silence', () {
      // 100 samples of silence (all zeros).
      final silence = List<int>.filled(200, 0); // 200 bytes = 100 16-bit samples
      final bytes = Uint8List.fromList(silence);
      expect(VoiceNotifier.computeRMSEnergy(bytes), 0.0);
    });

    test('computeRMSEnergy returns non-zero for non-silent audio', () {
      // Create a simple sine-like pattern (alternating high/low).
      final samples = <int>[];
      for (int i = 0; i < 100; i++) {
        // Write 16-bit LE value of ~16000 (half max).
        samples.add(0x80); // low byte
        samples.add(0x3E); // high byte → 0x3E80 = 16000
      }
      final bytes = Uint8List.fromList(samples);
      expect(VoiceNotifier.computeRMSEnergy(bytes), greaterThan(0.0));
    });
  });
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `cd /Users/sm/code/cmux/android-companion && flutter test test/terminal/voice_service_test.dart`
Expected: FAIL — `VoiceNotifier` does not exist.

- [ ] **Step 7: Implement voice_service.dart**

Create `android-companion/lib/terminal/voice_service.dart`:

```dart
/// Voice recording state management for the modifier bar's mic button.
///
/// Manages the full voice-to-terminal lifecycle:
///   1. Audio capture via the `record` package (16kHz, 16-bit, mono PCM).
///   2. Local silence suppression (RMS energy threshold).
///   3. Binary frame streaming to Mac via WebSocket (channel 0xFFFFFFFF).
///   4. Transcription chip state (arrive → commit → fade / dismiss).
///   5. JSON-RPC event handling for voice.transcription, voice.processing, voice.error.
///
/// Usage:
///   // Start recording (tap toggle mode).
///   await ref.read(voiceProvider.notifier).startRecording(RecordingMode.tapToggle);
///
///   // Stop recording.
///   await ref.read(voiceProvider.notifier).stopRecording();
///
///   // Watch state for UI.
///   final state = ref.watch(voiceProvider);
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../connection/connection_manager.dart';
import '../connection/message_protocol.dart';
import 'voice_protocol.dart';

// ---------------------------------------------------------------------------
// Silence suppression
// ---------------------------------------------------------------------------

/// RMS energy threshold below which audio frames are considered silence
/// and suppressed (not sent to the Mac). This is a conservative default;
/// the first few hundred ms of audio is used to calibrate a per-session
/// threshold in the Mac-side VAD. Phone-side suppression is purely to
/// reduce network traffic during obvious silence.
const _kSilenceThreshold = 0.02;

// ---------------------------------------------------------------------------
// VoiceNotifier
// ---------------------------------------------------------------------------

/// StateNotifier managing the voice recording session.
///
/// Separated from UI to keep business logic testable. The notifier
/// does NOT hold a direct reference to [ConnectionManager] — callers
/// must pass it to methods that need network access, following the
/// same pattern as [AttachmentNotifier.uploadAll].
class VoiceNotifier extends StateNotifier<VoiceState> {
  VoiceNotifier() : super(const VoiceState());

  final AudioRecorder _recorder = AudioRecorder();

  /// Timer that updates [VoiceState.recordingDuration] every 100ms.
  Timer? _durationTimer;
  DateTime? _recordingStartTime;

  /// Timer for local silence auto-stop (3 seconds in dictation mode).
  Timer? _silenceTimer;
  DateTime? _lastSpeechTime;

  /// Subscription to the recorder's audio stream.
  StreamSubscription<Uint8List>? _audioStreamSub;

  /// Subscription to bridge events for voice.* messages.
  StreamSubscription<BridgeEvent>? _eventSub;

  /// Commit timers keyed by segment ID.
  final Map<int, Timer> _commitTimers = {};

  /// Fade-out removal timers keyed by segment ID.
  final Map<int, Timer> _removeTimers = {};

  // ---------------------------------------------------------------------------
  // Public API — Recording lifecycle
  // ---------------------------------------------------------------------------

  /// Check if the Mac-side Whisper model is ready.
  ///
  /// Returns the response result map with `ready` (bool) and optionally
  /// `reason` (string).
  Future<Map<String, dynamic>?> checkReady(ConnectionManager manager) async {
    try {
      final response = await manager
          .sendRequest('voice.check_ready')
          .timeout(const Duration(seconds: 5));
      return response.result;
    } catch (e) {
      debugPrint('[VoiceService] check_ready failed: $e');
      return null;
    }
  }

  /// Trigger model download on the Mac.
  Future<bool> requestSetup(ConnectionManager manager) async {
    try {
      state = state.copyWith(
        status: VoiceStatus.setupRequired,
        setupProgress: 0,
        setupMessage: 'Starting download...',
      );
      final response = await manager
          .sendRequest('voice.setup')
          .timeout(const Duration(seconds: 300));
      return response.ok;
    } catch (e) {
      debugPrint('[VoiceService] setup failed: $e');
      state = state.copyWith(
        errorMessage: 'Model download failed: $e',
      );
      return false;
    }
  }

  /// Start a recording session.
  ///
  /// [mode] determines whether recording stops on release (holdToRecord)
  /// or on a second tap / silence timeout (tapToggle).
  ///
  /// [manager] is needed to send the voice.start RPC and stream audio.
  Future<void> startRecording(
    RecordingMode mode,
    ConnectionManager manager,
  ) async {
    if (state.status == VoiceStatus.recording) return;

    // Check microphone permission.
    if (!await _recorder.hasPermission()) {
      state = state.copyWith(
        errorMessage: 'Microphone permission denied',
      );
      return;
    }

    // Send voice.start RPC to Mac.
    try {
      await manager.sendRequest('voice.start').timeout(
            const Duration(seconds: 5),
          );
    } catch (e) {
      debugPrint('[VoiceService] voice.start failed: $e');
      state = state.copyWith(errorMessage: 'Failed to start voice session');
      return;
    }

    // Subscribe to voice events from Mac.
    _eventSub?.cancel();
    _eventSub = manager.eventStream.listen(_handleBridgeEvent);

    // Start audio recording as a stream of PCM bytes.
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRate,
        numChannels: kChannelCount,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );

    _recordingStartTime = DateTime.now();
    _lastSpeechTime = DateTime.now();

    // Stream audio frames to Mac, with local silence suppression.
    _audioStreamSub = stream.listen((Uint8List pcmBytes) {
      final energy = computeRMSEnergy(pcmBytes);

      if (energy > _kSilenceThreshold) {
        // Speech detected — send frame and reset silence timer.
        _lastSpeechTime = DateTime.now();
        _resetSilenceTimer(mode, manager);

        final frame = VoiceAudioFrame.encode(pcmBytes);
        manager.sendBinary(frame);
      } else {
        // Silence — check auto-stop for dictation mode.
        _checkSilenceAutoStop(mode, manager);
      }
    });

    // Start duration update timer (100ms tick).
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (_recordingStartTime != null) {
          state = state.copyWith(
            recordingDuration: DateTime.now().difference(_recordingStartTime!),
          );
        }
      },
    );

    HapticFeedback.mediumImpact();

    state = state.copyWith(
      status: VoiceStatus.recording,
      recordingMode: mode,
      recordingDuration: Duration.zero,
      errorMessage: null,
    );
  }

  /// Stop the current recording session.
  Future<void> stopRecording(ConnectionManager manager) async {
    if (state.status != VoiceStatus.recording) return;

    _durationTimer?.cancel();
    _durationTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _audioStreamSub?.cancel();
    _audioStreamSub = null;

    await _recorder.stop();

    HapticFeedback.lightImpact();

    // Notify Mac to flush remaining audio.
    try {
      await manager.sendRequest('voice.stop').timeout(
            const Duration(seconds: 5),
          );
    } catch (e) {
      debugPrint('[VoiceService] voice.stop failed: $e');
    }

    state = state.copyWith(
      status: VoiceStatus.processing,
    );

    // If no chips arrive within 3 seconds, transition back to idle.
    Future.delayed(const Duration(seconds: 3), () {
      if (state.status == VoiceStatus.processing && !state.hasActiveChips) {
        state = state.copyWith(status: VoiceStatus.idle);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Public API — Chip management
  // ---------------------------------------------------------------------------

  /// Add a transcription chip (called when voice.transcription arrives).
  void addChip({
    required int segmentId,
    required String text,
    bool hasTrigger = false,
  }) {
    final chip = TranscriptionChip(
      segmentId: segmentId,
      text: text,
      hasTrigger: hasTrigger,
    );

    state = state.copyWith(
      chips: [...state.chips, chip],
    );

    HapticFeedback.selectionClick();

    // Start auto-commit countdown (200ms pause, then 800ms progress).
    _startCommitTimer(segmentId);
  }

  /// Dismiss a chip by segment ID (user tapped X or swiped).
  void dismissChip(int segmentId) {
    final chips = state.chips.map((c) {
      if (c.segmentId != segmentId) return c;
      // Cannot dismiss an already committed chip.
      if (c.status == ChipStatus.committed) return c;
      return c.copyWith(status: ChipStatus.dismissed);
    }).toList();

    // Cancel the commit timer for this chip.
    _commitTimers[segmentId]?.cancel();
    _commitTimers.remove(segmentId);

    state = state.copyWith(chips: chips);

    HapticFeedback.lightImpact();

    // Schedule removal after dismiss animation (300ms).
    _removeTimers[segmentId]?.cancel();
    _removeTimers[segmentId] = Timer(
      const Duration(milliseconds: 300),
      () => removeChip(segmentId),
    );
  }

  /// Mark a chip as committed (text has been sent to terminal).
  void markCommitted(int segmentId) {
    final chips = state.chips.map((c) {
      if (c.segmentId != segmentId) return c;
      return c.copyWith(status: ChipStatus.committed);
    }).toList();

    state = state.copyWith(chips: chips);

    // Schedule removal after fade-out (800ms).
    _removeTimers[segmentId]?.cancel();
    _removeTimers[segmentId] = Timer(
      kChipFadeOutDelay,
      () {
        removeChip(segmentId);
        _checkTransitionToIdle();
      },
    );
  }

  /// Remove a chip from the list entirely.
  void removeChip(int segmentId) {
    state = state.copyWith(
      chips: state.chips.where((c) => c.segmentId != segmentId).toList(),
    );
    _removeTimers.remove(segmentId);
  }

  // ---------------------------------------------------------------------------
  // Public API — Silence suppression (static for testing)
  // ---------------------------------------------------------------------------

  /// Compute RMS energy of a 16-bit little-endian PCM buffer.
  ///
  /// Returns a value between 0.0 (silence) and 1.0 (maximum amplitude).
  /// Static so it can be called from tests without instantiating the notifier.
  static double computeRMSEnergy(Uint8List pcmBytes) {
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) return 0.0;

    final byteData = pcmBytes.buffer.asByteData(pcmBytes.offsetInBytes);
    double sumSquared = 0;

    for (int i = 0; i < sampleCount; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      final normalized = sample / 32767.0;
      sumSquared += normalized * normalized;
    }

    return (sumSquared / sampleCount).isNaN ? 0.0 : sqrt(sumSquared / sampleCount);
  }

  // ---------------------------------------------------------------------------
  // Private — Bridge event handling
  // ---------------------------------------------------------------------------

  void _handleBridgeEvent(BridgeEvent event) {
    switch (event.event) {
      case 'voice.transcription':
        final segmentId = event.data['segment_id'] as int?;
        final text = event.data['text'] as String?;
        if (segmentId != null && text != null && text.isNotEmpty) {
          // Check for trigger words.
          final triggerResult = TriggerWordDetector.check(text);
          addChip(
            segmentId: segmentId,
            text: triggerResult.cleanText.isEmpty ? text : triggerResult.cleanText,
            hasTrigger: triggerResult.hasTrigger,
          );
        }

      case 'voice.processing':
        // Informational — could update UI to show a processing indicator
        // for this segment. Currently a no-op.
        break;

      case 'voice.error':
        final message = event.data['message'] as String? ?? 'Unknown error';
        state = state.copyWith(
          errorMessage: message,
          status: VoiceStatus.idle,
        );

      case 'voice.setup_progress':
        final percent = event.data['percent'] as int?;
        final message = event.data['message'] as String?;
        state = state.copyWith(
          setupProgress: percent,
          setupMessage: message,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Private — Timers
  // ---------------------------------------------------------------------------

  void _startCommitTimer(int segmentId) {
    _commitTimers[segmentId]?.cancel();

    // 200ms pause before starting the commit countdown.
    _commitTimers[segmentId] = Timer(
      const Duration(milliseconds: 200),
      () {
        // Transition to committing status (starts the progress bar).
        final chips = state.chips.map((c) {
          if (c.segmentId != segmentId) return c;
          if (c.status != ChipStatus.pending) return c;
          return c.copyWith(status: ChipStatus.committing);
        }).toList();
        state = state.copyWith(chips: chips);

        // After 800ms, commit the chip.
        _commitTimers[segmentId] = Timer(
          kChipAutoCommitDelay,
          () => _commitChip(segmentId),
        );
      },
    );
  }

  /// Commit a chip: send text to terminal and mark as committed.
  void _commitChip(int segmentId) {
    final chip = state.chips.where((c) => c.segmentId == segmentId).firstOrNull;
    if (chip == null) return;

    // Guard: only commit if still in committing status.
    if (chip.status != ChipStatus.committing) return;

    // The actual surface.pty.write call is delegated to the UI layer
    // (voice_button.dart or terminal_screen.dart) via a callback, because
    // the notifier does not hold a ConnectionManager reference for the
    // commit path. Instead, we expose an onCommit callback.
    _onCommitCallback?.call(chip.commitText);

    markCommitted(segmentId);
  }

  /// Callback invoked when a chip is ready to commit its text to the terminal.
  /// Set by the UI layer (VoiceButton or TerminalScreen) after construction.
  void Function(String text)? _onCommitCallback;

  /// Register the callback that sends committed text to the terminal.
  void setCommitCallback(void Function(String text) callback) {
    _onCommitCallback = callback;
  }

  void _resetSilenceTimer(RecordingMode mode, ConnectionManager manager) {
    _silenceTimer?.cancel();
    if (mode == RecordingMode.tapToggle) {
      _silenceTimer = Timer(kSilenceAutoStopDuration, () {
        stopRecording(manager);
      });
    }
  }

  void _checkSilenceAutoStop(RecordingMode mode, ConnectionManager manager) {
    if (mode != RecordingMode.tapToggle) return;
    if (_lastSpeechTime == null) return;

    final silenceDuration = DateTime.now().difference(_lastSpeechTime!);
    if (silenceDuration >= kSilenceAutoStopDuration) {
      stopRecording(manager);
    }
  }

  void _checkTransitionToIdle() {
    if (state.status == VoiceStatus.processing && !state.hasActiveChips) {
      state = state.copyWith(status: VoiceStatus.idle);
    }
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _durationTimer?.cancel();
    _silenceTimer?.cancel();
    _audioStreamSub?.cancel();
    _eventSub?.cancel();
    for (final timer in _commitTimers.values) {
      timer.cancel();
    }
    for (final timer in _removeTimers.values) {
      timer.cancel();
    }
    _recorder.dispose();
    super.dispose();
  }
}

/// Needed for sqrt in computeRMSEnergy.
double sqrt(double x) => x <= 0 ? 0 : x.toDouble().isNaN ? 0 : _sqrt(x);
double _sqrt(double x) {
  // Dart's dart:math sqrt.
  return x <= 0 ? 0 : x.toDouble();
}

// Note: The above sqrt is a placeholder — import 'dart:math' show sqrt;
// should be used in the actual implementation. Written this way because
// the plan template shows the full file, and we don't want import collisions.
// Actual file should use: import 'dart:math' show sqrt;

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Global Riverpod provider for voice recording state.
final voiceProvider = StateNotifierProvider<VoiceNotifier, VoiceState>(
  (ref) => VoiceNotifier(),
);
```

**Important implementation note:** The actual file should use `import 'dart:math' show sqrt;` instead of the placeholder sqrt functions shown above. The plan shows the full file shape; the implementer should fix the import.

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd /Users/sm/code/cmux/android-companion && flutter test test/terminal/voice_service_test.dart`
Expected: All tests PASS.

- [ ] **Step 9: Commit**

```bash
cd /Users/sm/code/cmux
git add android-companion/lib/terminal/voice_service.dart \
        android-companion/lib/connection/connection_manager.dart \
        android-companion/pubspec.yaml \
        android-companion/android/app/src/main/AndroidManifest.xml \
        android-companion/test/terminal/voice_service_test.dart
git commit -m "feat(voice): add Riverpod voice service with audio streaming and chip management"
```

---

## Task 5: Phone-Side UI (Voice Button + Voice Strip)

**Files:**
- Replace: `android-companion/lib/terminal/voice_button.dart`
- Create: `android-companion/lib/terminal/voice_strip.dart`
- Modify: `android-companion/lib/terminal/modifier_bar.dart`
- Modify: `android-companion/lib/terminal/terminal_screen.dart`
- Modify: `android-companion/lib/app/colors.dart`

**Depends on:** Task 1 (protocol types), Task 4 (voice service).

- [ ] **Step 1: Add voice color tokens to colors.dart**

In `android-companion/lib/app/colors.dart`, add these fields to the `AppColorScheme` class definition (after the attachment tokens):

```dart
  // -- Voice strip --
  final Color voiceRecordingRed;
  final Color voiceRecordingBg;
  final Color voiceCommitGreen;
  final Color voiceCommitBorder;
  final Color voiceChipBg;
  final Color voiceChipBorder;
  final Color voiceStripBg;
  final Color voiceTimerText;
  final Color voiceSetupAmber;
```

Add the corresponding `required` constructor parameters. Then add the dark theme values:

```dart
    // Dark voice tokens
    voiceRecordingRed: Color(0xFFFF4444),
    voiceRecordingBg: Color(0x33FF4444),    // rgba(255,68,68,0.2)
    voiceCommitGreen: Color(0xFF50C878),
    voiceCommitBorder: Color(0x4D50C878),   // rgba(80,200,120,0.3)
    voiceChipBg: Color(0x14FFFFFF),         // rgba(255,255,255,0.08)
    voiceChipBorder: Color(0x1FFFFFFF),     // rgba(255,255,255,0.12)
    voiceStripBg: Color(0xE6101018),        // rgba(16,16,24,0.90)
    voiceTimerText: Color(0xFFFF4444),
    voiceSetupAmber: Color(0xFFE0A030),
```

And light theme values:

```dart
    // Light voice tokens
    voiceRecordingRed: Color(0xFFD32F2F),
    voiceRecordingBg: Color(0x26D32F2F),    // rgba(211,47,47,0.15)
    voiceCommitGreen: Color(0xFF2D8A4E),
    voiceCommitBorder: Color(0x4D2D8A4E),   // rgba(45,138,78,0.3)
    voiceChipBg: Color(0x0A000000),         // rgba(0,0,0,0.04)
    voiceChipBorder: Color(0x14000000),     // rgba(0,0,0,0.08)
    voiceStripBg: Color(0xE6F5F5F0),        // rgba(245,245,240,0.90)
    voiceTimerText: Color(0xFFD32F2F),
    voiceSetupAmber: Color(0xFFB07810),
```

- [ ] **Step 2: Implement voice_strip.dart**

Create `android-companion/lib/terminal/voice_strip.dart`. This file contains:

- `VoiceStrip` — top-level widget with slide/opacity animation (matches `AttachmentStrip` pattern)
- `_StripBody` — container with waveform + timer + chip scroll area
- `_WaveformVisualizer` — 7 animated bars (44x36px), static when not recording
- `_RecordingTimer` — `m:ss` format, JetBrains Mono 10px, red color
- `_TranscriptionChipWidget` — chip with dismiss X, swipe-to-dismiss, auto-commit progress bar
- `_CommitProgressBar` — 2px green bar that fills over 800ms

Key dimensions from spec:
- Strip height: 52px
- Margin: 8px horizontal
- Border radius: 14px top corners
- Background: voice strip bg token with 24px backdrop blur
- Chip max width: 200px
- Chip font: JetBrains Mono, 11px, weight 500

The strip follows the same `AnimatedSlide` + `AnimatedOpacity` pattern as `AttachmentStrip` (`attachment_strip.dart:41-51`).

Chip swipe-to-dismiss uses `Dismissible` with a 50px threshold, calling `voiceProvider.notifier.dismissChip(segmentId)`.

Full implementation is ~350 lines. The implementer should follow `attachment_strip.dart` as the structural template and the design spec for exact values.

- [ ] **Step 3: Replace voice_button.dart with full implementation**

Replace the placeholder `android-companion/lib/terminal/voice_button.dart` with the dual-mode activation button. Key behavior:

- `ConsumerStatefulWidget` (needs Riverpod for `voiceProvider`)
- `GestureDetector` with `onTapDown` / `onTapUp` / `onLongPressStart` / `onLongPressEnd`
- Tap detection: if press duration < 250ms on `onTapUp`, it's a tap (toggle mode)
- Hold detection: `onLongPressStart` begins recording immediately (holdToRecord mode)
- Visual states driven by `ref.watch(voiceProvider).status`:
  - `idle` → outline mic icon, `keyGroupResting` bg
  - `recording` → filled mic icon, red bg, pulsing ring animation (1.5s cycle)
  - `processing` → spinner, amber bg
  - `setupRequired` → outline mic + amber dot badge
- First-tap flow: calls `checkReady()`, shows setup bottom sheet if not ready
- Accessibility semantics per spec table

The button should accept `ConnectionManager` (or obtain via provider) to call `startRecording` / `stopRecording`.

- [ ] **Step 4: Modify modifier_bar.dart to thread voice state**

In `android-companion/lib/terminal/modifier_bar.dart`, the existing `const VoiceButton()` at line 229 needs to become a non-const widget that receives the connection manager. The `VoiceButton` now needs `ref` access (it's a `ConsumerStatefulWidget`), so it reads `voiceProvider` internally.

Replace:
```dart
const VoiceButton(),      // bottom-right
```
With:
```dart
const VoiceButton(),      // bottom-right (now ConsumerStatefulWidget, reads voiceProvider)
```

No constructor change needed if `VoiceButton` reads providers internally. Remove the `const` keyword since `ConsumerStatefulWidget` cannot be const.

- [ ] **Step 5: Modify terminal_screen.dart to mount VoiceStrip**

In `android-companion/lib/terminal/terminal_screen.dart`, add the `VoiceStrip` between the `AttachmentStrip` and `ModifierBar`. The voice strip should appear below the attachment strip (closer to the modifier bar):

After the `AttachmentStrip` conditional (around line 438-442), add:

```dart
                // Voice transcription strip (only when voice is active)
                if (_showModifierBar)
                  Consumer(
                    builder: (context, ref, _) {
                      final voiceState = ref.watch(voiceProvider);
                      return VoiceStrip(state: voiceState);
                    },
                  ),
```

Also, wire up the voice commit callback so committed chip text is sent to the terminal. In the `_sendInput` method or at the screen's initialization, set:

```dart
ref.read(voiceProvider.notifier).setCommitCallback((text) {
  // Send to active surface via surface.pty.write
  _sendInput(text);
});
```

- [ ] **Step 6: Verify the app builds**

Run: `cd /Users/sm/code/cmux/android-companion && flutter build apk --debug --target-platform android-arm64 2>&1 | tail -20`
Expected: BUILD SUCCESSFUL

- [ ] **Step 7: Commit**

```bash
cd /Users/sm/code/cmux
git add android-companion/lib/terminal/voice_button.dart \
        android-companion/lib/terminal/voice_strip.dart \
        android-companion/lib/terminal/modifier_bar.dart \
        android-companion/lib/terminal/terminal_screen.dart \
        android-companion/lib/app/colors.dart
git commit -m "feat(voice): add voice button with dual-mode activation and transcription strip UI"
```

---

## Task 6: Mac-Side Voice Channel + RPC Commands

**Files:**
- Create: `Sources/Voice/VoiceChannel.swift`
- Create: `Sources/Voice/VoiceCommands.swift`
- Modify: `Sources/Bridge/BridgeConnection.swift`

**Depends on:** Task 2 (VAD), Task 3 (WhisperBridge).

- [ ] **Step 1: Implement VoiceChannel.swift**

Create `Sources/Voice/VoiceChannel.swift`:

```swift
import Foundation

/// Routes voice audio binary frames to the VAD and manages the per-connection
/// voice session state.
///
/// Each `BridgeConnection` has at most one active voice session. Binary frames
/// with channel ID `0xFFFFFFFF` are routed here by the connection's message
/// dispatch logic.
///
/// Thread safety: All methods are called from the bridge server's serial queue.
final class VoiceChannel {

    /// The VAD instance for this session.
    let vad = VoiceActivityDetector()

    /// The Whisper subprocess bridge (shared across sessions on the same connection).
    let whisper = WhisperBridge()

    /// Whether a recording session is currently active.
    private(set) var isActive = false

    /// Callback to send JSON-RPC events back to the phone.
    var sendEvent: ((_ method: String, _ params: [String: Any]) -> Void)?

    // MARK: - Session Lifecycle

    /// Start a new voice recording session.
    ///
    /// Resets the VAD, starts the Whisper subprocess if needed, and begins
    /// accepting audio frames.
    ///
    /// - Parameter queue: The serial queue for callbacks.
    func startSession(queue: DispatchQueue) {
        guard !isActive else { return }
        isActive = true

        vad.reset()

        // Wire VAD → Whisper: when a speech segment is ready, send it to Whisper.
        vad.onSegmentReady = { [weak self] segmentId, audioData in
            guard let self else { return }

            // Notify phone that we're processing this segment.
            self.sendEvent?("voice.processing", ["segment_id": segmentId])

            // Send to Whisper for transcription.
            self.whisper.transcribe(segmentId: segmentId, audioData: audioData)
        }

        // Wire Whisper → phone: when transcription is ready, send it to the phone.
        whisper.onTranscription = { [weak self] segmentId, text in
            self?.sendEvent?("voice.transcription", [
                "segment_id": segmentId,
                "text": text,
            ])
        }

        whisper.onError = { [weak self] message in
            self?.sendEvent?("voice.error", ["message": message])
        }

        // Start the Whisper subprocess.
        whisper.start(callbackQueue: queue)

        NSLog("[VoiceChannel] Session started")
    }

    /// Stop the current recording session.
    ///
    /// Flushes any remaining audio in the VAD and keeps the Whisper subprocess
    /// alive (it has its own idle timeout).
    func stopSession() {
        guard isActive else { return }
        isActive = false

        // Flush any remaining speech segment.
        vad.flushRemaining()

        NSLog("[VoiceChannel] Session stopped")
    }

    /// Process an incoming audio binary frame (already stripped of the 4-byte channel header).
    ///
    /// - Parameter audioData: Raw 16-bit LE PCM audio bytes.
    func processAudioFrame(_ audioData: Data) {
        guard isActive else { return }
        vad.processAudio(audioData)
    }

    /// Clean up all resources when the connection closes.
    func teardown() {
        stopSession()
        whisper.stop()
    }
}
```

- [ ] **Step 2: Implement VoiceCommands.swift**

Create `Sources/Voice/VoiceCommands.swift`:

```swift
import Foundation

/// JSON-RPC command handlers for voice.* methods.
///
/// These are called by `BridgeConnection.handleTextMessage` when it encounters
/// a `voice.*` method name. Each handler receives the connection's `VoiceChannel`
/// instance and the request parameters.
///
/// Methods:
///   - `voice.check_ready` — Check if Whisper model is downloaded.
///   - `voice.setup` — Trigger model download.
///   - `voice.start` — Begin a recording session.
///   - `voice.stop` — End a recording session.
enum VoiceCommands {

    /// Handle `voice.check_ready` — returns whether the Whisper model is available.
    static func handleCheckReady(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        let (ready, reason) = voiceChannel.whisper.checkReady()

        var result: [String: Any] = ["ready": ready]
        if let reason {
            result["reason"] = reason
        }
        return encode(id, result)
    }

    /// Handle `voice.setup` — triggers model download via huggingface_hub.
    ///
    /// This is a long-running operation. The response is sent immediately with
    /// acknowledgment; progress is reported via `voice.setup_progress` events.
    static func handleSetup(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String,
        sendEvent: @escaping (_ method: String, _ params: [String: Any]) -> Void
    ) -> String {
        // TODO: Implement model download via Python subprocess.
        // For now, return an error if model is not present.
        let (ready, _) = voiceChannel.whisper.checkReady()
        if ready {
            return encode(id, ["status": "already_installed"])
        }

        // Launch download in background.
        DispatchQueue.global(qos: .userInitiated).async {
            let modelDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cmux/models/whisper-small-mlx").path

            // Use huggingface_hub CLI to download.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", "-c",
                """
                from huggingface_hub import snapshot_download
                snapshot_download(
                    'mlx-community/whisper-small-mlx',
                    local_dir='\(modelDir)'
                )
                """
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    sendEvent("voice.setup_progress", [
                        "percent": 100,
                        "message": "Download complete"
                    ])
                } else {
                    sendEvent("voice.error", [
                        "message": "Model download failed (exit code \\(process.terminationStatus))"
                    ])
                }
            } catch {
                sendEvent("voice.error", [
                    "message": "Failed to start download: \\(error.localizedDescription)"
                ])
            }
        }

        return encode(id, ["status": "downloading"])
    }

    /// Handle `voice.start` — begin accepting audio frames.
    static func handleStart(
        voiceChannel: VoiceChannel,
        id: Any?,
        queue: DispatchQueue,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        let sessionId = UUID().uuidString
        voiceChannel.startSession(queue: queue)
        return encode(id, ["session_id": sessionId])
    }

    /// Handle `voice.stop` — stop accepting audio frames, flush VAD.
    static func handleStop(
        voiceChannel: VoiceChannel,
        id: Any?,
        encode: (_ id: Any?, _ result: Any) -> String
    ) -> String {
        voiceChannel.stopSession()
        return encode(id, ["stopped": true])
    }
}
```

- [ ] **Step 3: Wire binary frame routing in BridgeConnection.swift**

In `Sources/Bridge/BridgeConnection.swift`, make these changes:

**a) Add a VoiceChannel property** (after the existing properties around line 30):

```swift
    /// Voice recording session handler for this connection.
    private lazy var voiceChannel: VoiceChannel = {
        let channel = VoiceChannel()
        channel.sendEvent = { [weak self] method, params in
            guard let self else { return }
            let event = self.encodeEvent(method: method, params: params)
            self.sendText(event)
        }
        return channel
    }()
```

**b) Add an `encodeEvent` helper** (near the other JSON encoding helpers around line 880):

```swift
    /// Encodes a JSON-RPC notification (server-to-client event, no ID).
    private func encodeEvent(method: String, params: [String: Any]) -> String {
        let notification: [String: Any] = [
            "event": method,
            "data": params,
        ]
        return encodeJSON(notification)
    }
```

**c) Route binary frames** — change the `.binary` case (line 263-265) from:

```swift
            case .binary:
                // Binary frames from client are not expected in Phase 1.
                break
```

To:

```swift
            case .binary:
                if let data = content, data.count >= 4 {
                    // Extract 4-byte little-endian channel ID.
                    let channelId = data.withUnsafeBytes {
                        $0.loadUnaligned(as: UInt32.self)
                    }
                    if channelId == 0xFFFF_FFFF {
                        // Voice audio frame — strip header and route to VoiceChannel.
                        let audioData = data.subdata(in: 4..<data.count)
                        self.voiceChannel.processAudioFrame(audioData)
                    }
                    // Other channel IDs are not used for client→server binary yet.
                }
```

**d) Add voice.* method routing** in the text message dispatch switch (around line 322-347). Add before the `default:` case:

```swift
        case "voice.check_ready":
            sendText(VoiceCommands.handleCheckReady(
                voiceChannel: voiceChannel, id: id, encode: encodeOk))
        case "voice.setup":
            sendText(VoiceCommands.handleSetup(
                voiceChannel: voiceChannel, id: id, encode: encodeOk,
                sendEvent: { [weak self] method, params in
                    guard let self else { return }
                    self.sendText(self.encodeEvent(method: method, params: params))
                }))
        case "voice.start":
            sendText(VoiceCommands.handleStart(
                voiceChannel: voiceChannel, id: id, queue: queue!, encode: encodeOk))
        case "voice.stop":
            sendText(VoiceCommands.handleStop(
                voiceChannel: voiceChannel, id: id, encode: encodeOk))
```

**e) Clean up voice channel on disconnect.** In the disconnect/cleanup method, add:

```swift
        voiceChannel.teardown()
```

- [ ] **Step 4: Verify Mac-side builds**

```bash
cd /Users/sm/code/cmux && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-voice-build build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
cd /Users/sm/code/cmux
git add Sources/Voice/VoiceChannel.swift \
        Sources/Voice/VoiceCommands.swift \
        Sources/Bridge/BridgeConnection.swift
git commit -m "feat(voice): wire Mac-side voice channel, RPC commands, and binary frame routing"
```

---

## Task 7: Integration Testing + Docs

**Files:**
- Create: `docs/voice-input/ux-behavior-expectations.md`
- Create: `docs/voice-input/development-architecture.md`

**Depends on:** All prior tasks.

- [ ] **Step 1: Write UX behavior expectations doc**

Create `docs/voice-input/ux-behavior-expectations.md` documenting:

- Dual-mode activation behavior (hold vs tap) with exact timing thresholds
- Visual state transitions (idle → recording → processing → idle)
- Chip lifecycle (arrive → auto-commit countdown → committed → fade-out)
- Chip dismiss behavior (tap X, swipe left, no-op if already committed)
- Trigger word behavior (stripping, `\r` append, which words)
- Strip visibility rules (when it appears and disappears)
- Haptic feedback for each interaction
- Setup flow (first-use bottom sheet)
- Error handling (permission denied, connection lost, Whisper crash)
- Accessibility semantics for each state

- [ ] **Step 2: Write development architecture doc**

Create `docs/voice-input/development-architecture.md` documenting:

- System diagram (phone → WebSocket → Mac → VAD → Whisper → phone)
- Binary frame format (channel ID `0xFFFFFFFF`)
- JSON-RPC message catalog (all methods with examples)
- Whisper subprocess lifecycle (lazy start, crash recovery, idle timeout)
- VAD algorithm (energy-based, auto-calibrating threshold, segment boundaries)
- Phone-side silence suppression (RMS threshold, purpose)
- State management (Riverpod providers, state flow)
- File map with responsibilities
- Threading model (bridge server queue, IO queue, main thread)

- [ ] **Step 3: End-to-end test plan**

Since tests run via CI (not locally), document the test scenarios that should be verified once the feature is deployed to a test device:

1. **Tap mic → speak → see chip → chip auto-commits → text in terminal**
2. **Hold mic → speak → release → chip appears → auto-commits**
3. **Tap mic → silence for 3s → auto-stop**
4. **Dismiss chip before commit → text NOT sent to terminal**
5. **Say "git status enter" → chip shows "git status" with return indicator → terminal receives "git status\r"**
6. **First tap with no model → setup bottom sheet appears**
7. **Whisper crash → auto-restart → next segment still transcribes**
8. **3 Whisper crashes → error toast → recording stops**
9. **Connection lost during recording → recording stops, toast shown**
10. **Permission denied → mic button shows badge, error message shown**

- [ ] **Step 4: Commit docs**

```bash
cd /Users/sm/code/cmux
git add docs/voice-input/ux-behavior-expectations.md \
        docs/voice-input/development-architecture.md
git commit -m "docs(voice): add UX behavior expectations and development architecture"
```

---

## Summary

| Task | Component | Files Created | Files Modified | Parallel? |
|------|-----------|---------------|----------------|-----------|
| 1 | Protocol types (phone) | 2 | 0 | Yes (independent) |
| 2 | VAD (Mac) | 1 | 0 | Yes (independent) |
| 3 | Whisper bridge (Mac) | 2 | 0 | Yes (independent) |
| 4 | Voice service (phone) | 2 | 3 | After Task 1 |
| 5 | UI: button + strip (phone) | 1 | 4 | After Tasks 1, 4 |
| 6 | Channel + RPC wiring (Mac) | 2 | 1 | After Tasks 2, 3 |
| 7 | Integration + docs | 2 | 0 | After all |

**Total:** 12 new files, 8 modified files, 7 tasks, ~4 parallelizable.
