/// Voice recording service for the voice-to-terminal feature.
///
/// Manages the full voice recording lifecycle on the phone side:
///   - Audio capture via the `record` package (16 kHz, 16-bit, mono PCM stream)
///   - Local silence suppression (RMS energy below threshold skips the frame)
///   - Binary frame streaming to Mac via WebSocket using [VoiceAudioFrame.encode]
///   - Transcription chip state management (add/dismiss/commit/remove)
///   - JSON-RPC event handling for voice.transcription, voice.processing, voice.error
///
/// Usage:
///   // Start recording in hold-to-record mode.
///   ref.read(voiceProvider.notifier).startRecording(RecordingMode.holdToRecord, manager);
///
///   // Stop recording.
///   ref.read(voiceProvider.notifier).stopRecording(manager);
///
///   // Handle an incoming transcription chip.
///   ref.read(voiceProvider.notifier).addChip(segmentId, text, hasTrigger);
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../connection/connection_manager.dart';
import '../connection/message_protocol.dart';
import 'voice_protocol.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// RMS energy threshold below which an audio chunk is considered silence
/// and its frame is not transmitted. Range is [0.0, 1.0] for normalised
/// 16-bit PCM (max sample value = 32768).
const double _kSilenceThreshold = 0.02;

/// Duration of silence before recording auto-stops in dictation mode.
///
/// When no non-silent frame has been received for this long, [stopRecording]
/// is called automatically.
const Duration _kSilenceAutoStopDuration = kSilenceAutoStopDuration;

// ---------------------------------------------------------------------------
// VoiceNotifier
// ---------------------------------------------------------------------------

/// StateNotifier that owns the voice recording lifecycle.
///
/// Responsibilities:
///   - Initiating and tearing down the PCM audio stream
///   - Silence suppression before transmitting frames
///   - Auto-stop after sustained silence in [RecordingMode.tapToggle]
///   - Chip lifecycle (add → committing → committed → removed, or dismissed)
///   - RPC: voice.check_ready, voice.setup, voice.start, voice.stop
class VoiceNotifier extends StateNotifier<VoiceState> {
  VoiceNotifier() : super(const VoiceState());

  final AudioRecorder _recorder = AudioRecorder();

  // Active audio stream subscription.
  StreamSubscription<Uint8List>? _audioSub;

  // Periodic timer tracking how long the current recording session has run.
  Timer? _durationTimer;

  // Accumulated recording duration ticks (incremented every second).
  int _durationSeconds = 0;

  // Timestamp of the last non-silent audio chunk for auto-stop logic.
  DateTime? _lastSpeechTime;

  // Per-chip auto-commit timers keyed by segmentId.
  final Map<int, Timer> _commitTimers = {};

  // Per-chip fade-out removal timers keyed by segmentId.
  final Map<int, Timer> _removeTimers = {};

  // Subscription to bridge events (voice.transcription, voice.processing, etc.).
  StreamSubscription<BridgeEvent>? _eventSub;

  // ---------------------------------------------------------------------------
  // Event handling
  // ---------------------------------------------------------------------------

  /// Subscribe to bridge events for voice.* notifications from the Mac.
  ///
  /// Must be called before starting a recording session so that transcription
  /// results are routed to chip creation.
  void listenToEvents(ConnectionManager manager) {
    _eventSub?.cancel();
    _eventSub = manager.eventStream.listen(_handleBridgeEvent);
  }

  /// Handle an incoming bridge event — routes voice.* events to the appropriate
  /// state mutations.
  void _handleBridgeEvent(BridgeEvent event) {
    switch (event.event) {
      case 'voice.transcription':
        final segmentId = event.data['segment_id'] as int?;
        final text = event.data['text'] as String?;
        if (segmentId != null && text != null && text.isNotEmpty) {
          // Run trigger word detection on the transcribed text.
          final result = TriggerWordDetector.check(text);
          addChip(
            segmentId,
            result.cleanText.isEmpty ? text : result.cleanText,
            result.hasTrigger,
          );
        }

      case 'voice.processing':
        // Informational — Mac is transcribing a segment. Could show a
        // "thinking" indicator, but for now we just wait for the result.
        break;

      case 'voice.error':
        final message = event.data['message'] as String? ?? 'Unknown error';
        state = state.copyWith(errorMessage: message);
        debugPrint('[VoiceService] Mac error: $message');

      case 'voice.setup_progress':
        final percent = event.data['percent'];
        final message = event.data['message'] as String?;
        state = state.copyWith(
          setupProgress: percent is num ? percent.toDouble() / 100.0 : null,
          setupMessage: message,
        );

      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Public RPC API
  // ---------------------------------------------------------------------------

  /// Sends a `voice.check_ready` JSON-RPC request to the Mac to verify that
  /// the Whisper model is loaded and the voice pipeline is ready.
  void checkReady(ConnectionManager manager) {
    manager.sendRequest('voice.check_ready');
  }

  /// Sends a `voice.setup` JSON-RPC request to the Mac, triggering Whisper
  /// model download or initialisation if not already complete.
  void requestSetup(ConnectionManager manager) {
    manager.sendRequest('voice.setup');
  }

  // ---------------------------------------------------------------------------
  // Recording lifecycle
  // ---------------------------------------------------------------------------

  /// Starts an audio recording session.
  ///
  /// Checks microphone permission, sends `voice.start` to the Mac, then opens
  /// a PCM stream and begins forwarding non-silent chunks over the WebSocket.
  ///
  /// [mode] determines whether the session ends on button release
  /// ([RecordingMode.holdToRecord]) or on a second tap ([RecordingMode.tapToggle]).
  Future<void> startRecording(
    RecordingMode mode,
    ConnectionManager manager,
  ) async {
    // Guard: only start when idle.
    if (state.status == VoiceStatus.recording) return;

    // Check microphone permission before attempting to record.
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      state = state.copyWith(
        status: VoiceStatus.idle,
        errorMessage: 'Microphone permission denied.',
      );
      return;
    }

    // Subscribe to bridge events for transcription results.
    listenToEvents(manager);

    // Notify the Mac that a recording session is starting.
    manager.sendRequest('voice.start');

    // Open the raw PCM stream from the device microphone.
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRate,
        numChannels: kChannelCount,
        bitRate: kSampleRate * kBitsPerSample * kChannelCount,
      ),
    );

    _lastSpeechTime = DateTime.now();

    // Subscribe to incoming PCM chunks.
    _audioSub = stream.listen(
      (chunk) => _handleAudioChunk(chunk, mode, manager),
      onError: (Object e) {
        debugPrint('[VoiceService] Audio stream error: $e');
        stopRecording(manager);
      },
      onDone: () => stopRecording(manager),
    );

    // Start the duration ticker.
    _durationSeconds = 0;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _durationSeconds++;
      state = state.copyWith(
        recordingDuration: Duration(seconds: _durationSeconds),
      );
    });

    state = state.copyWith(
      status: VoiceStatus.recording,
      recordingMode: mode,
      recordingDuration: Duration.zero,
      errorMessage: null,
    );
  }

  /// Stops the current recording session.
  ///
  /// Sends `voice.stop` to the Mac, tears down the audio stream and timers,
  /// and transitions state to [VoiceStatus.processing].
  Future<void> stopRecording(ConnectionManager manager) async {
    if (state.status != VoiceStatus.recording) return;

    // Signal the Mac that the session is ending.
    manager.sendRequest('voice.stop');

    // Tear down audio pipeline.
    await _audioSub?.cancel();
    _audioSub = null;
    _durationTimer?.cancel();
    _durationTimer = null;

    // stop() is idempotent — safe to call even if recording already stopped.
    await _recorder.stop();

    state = state.copyWith(
      status: VoiceStatus.processing,
      recordingDuration: null,
    );

    // Safety timeout: if no transcriptions arrive within 5 seconds of
    // stopping, return to idle to avoid a permanently stuck spinner.
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (state.status == VoiceStatus.processing && !state.hasActiveChips) {
        state = state.copyWith(status: VoiceStatus.idle);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Chip lifecycle
  // ---------------------------------------------------------------------------

  /// Adds a new [TranscriptionChip] in [ChipStatus.pending] state and starts
  /// the [kChipAutoCommitDelay] auto-commit timer.
  ///
  /// The timer fires and transitions the chip to [ChipStatus.committing]. The
  /// UI layer is responsible for calling [markCommitted] once the text has been
  /// written to the pty.
  void addChip(int segmentId, String text, bool hasTrigger) {
    final chip = TranscriptionChip(
      segmentId: segmentId,
      text: text,
      hasTrigger: hasTrigger,
    );

    // Append the new chip while preserving insertion order.
    state = state.copyWith(chips: [...state.chips, chip]);

    // Cancel any stale timer for this segment (shouldn't normally exist).
    _commitTimers[segmentId]?.cancel();

    // After the delay, advance to committing so the UI can write to the pty.
    _commitTimers[segmentId] = Timer(kChipAutoCommitDelay, () {
      _commitTimers.remove(segmentId);
      _transitionChip(segmentId, ChipStatus.committing);
    });
  }

  /// Marks a chip as [ChipStatus.dismissed], cancelling any pending
  /// auto-commit timer. No-op if the chip is already committed.
  void dismissChip(int segmentId) {
    final chip = _findChip(segmentId);
    if (chip == null) return;

    // Committed chips cannot be dismissed — they are already in the pty.
    if (chip.status == ChipStatus.committed) return;

    // Cancel the auto-commit timer so it doesn't fire after dismissal.
    _commitTimers[segmentId]?.cancel();
    _commitTimers.remove(segmentId);

    _transitionChip(segmentId, ChipStatus.dismissed);
  }

  /// Marks a chip as [ChipStatus.committed] and starts the
  /// [kChipFadeOutDelay] removal timer so it fades out of the strip.
  void markCommitted(int segmentId) {
    _transitionChip(segmentId, ChipStatus.committed);

    // Schedule automatic removal after the fade-out animation completes.
    _removeTimers[segmentId]?.cancel();
    _removeTimers[segmentId] = Timer(kChipFadeOutDelay, () {
      _removeTimers.remove(segmentId);
      removeChip(segmentId);
    });
  }

  /// Removes the chip with [segmentId] from the strip entirely.
  void removeChip(int segmentId) {
    state = state.copyWith(
      chips: state.chips.where((c) => c.segmentId != segmentId).toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // Silence detection
  // ---------------------------------------------------------------------------

  /// Computes the root-mean-square energy of a 16-bit PCM byte buffer,
  /// normalised to [0.0, 1.0] where 1.0 is full scale (32768).
  ///
  /// Returns 0.0 for an empty or odd-length buffer (no complete samples).
  static double computeRMSEnergy(Uint8List bytes) {
    // Each 16-bit sample is 2 bytes; a buffer with fewer than 2 bytes has
    // no complete samples.
    if (bytes.length < 2) return 0.0;

    final sampleCount = bytes.length ~/ 2;
    final byteData = ByteData.sublistView(bytes);

    double sumOfSquares = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      // Read each little-endian signed 16-bit sample.
      final sample = byteData.getInt16(i * 2, Endian.little);
      final normalised = sample / 32768.0;
      sumOfSquares += normalised * normalised;
    }

    final meanSquare = sumOfSquares / sampleCount;
    // RMS is sqrt of mean-square; clamp to [0,1] since normalised samples are
    // already in [-1, 1].
    return meanSquare > 0 ? meanSquare.clamp(0.0, 1.0) : 0.0;
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _eventSub?.cancel();
    _audioSub?.cancel();
    _durationTimer?.cancel();
    for (final t in _commitTimers.values) {
      t.cancel();
    }
    for (final t in _removeTimers.values) {
      t.cancel();
    }
    // dispose() on AudioRecorder is async; fire-and-forget since StateNotifier
    // dispose() is synchronous and we cannot await here.
    _recorder.dispose();
    super.dispose(); // ignore: must_call_super
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Routes an incoming PCM chunk: runs silence detection and forwards
  /// non-silent frames to the Mac over the WebSocket.
  ///
  /// In [RecordingMode.tapToggle], also tracks silence duration for auto-stop.
  void _handleAudioChunk(
    Uint8List chunk,
    RecordingMode mode,
    ConnectionManager manager,
  ) {
    final energy = computeRMSEnergy(chunk);
    final isSilent = energy < _kSilenceThreshold;

    // Always send frames to Mac — let the Mac-side VAD handle speech detection.
    // Phone-side silence suppression is disabled for now; the record package's
    // PCM energy scale varies by device and needs calibration.
    manager.sendBinary(VoiceAudioFrame.encode(chunk));
    if (!isSilent) {
      _lastSpeechTime = DateTime.now();
    }

    // In tap-toggle mode, check for sustained silence to auto-stop.
    if (mode == RecordingMode.tapToggle && _lastSpeechTime != null) {
      final silenceDuration = DateTime.now().difference(_lastSpeechTime!);
      if (silenceDuration >= _kSilenceAutoStopDuration) {
        stopRecording(manager);
      }
    }
  }

  /// Returns the [TranscriptionChip] with [segmentId], or null.
  TranscriptionChip? _findChip(int segmentId) {
    try {
      return state.chips.firstWhere((c) => c.segmentId == segmentId);
    } catch (_) {
      return null;
    }
  }

  /// Replaces the chip with [segmentId] with a copy at [newStatus].
  void _transitionChip(int segmentId, ChipStatus newStatus) {
    state = state.copyWith(
      chips: state.chips.map((c) {
        if (c.segmentId != segmentId) return c;
        return c.copyWith(status: newStatus);
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Global Riverpod provider for voice recording state.
final voiceProvider = StateNotifierProvider<VoiceNotifier, VoiceState>((ref) {
  return VoiceNotifier();
});
