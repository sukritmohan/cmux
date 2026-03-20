/// Pure Dart protocol types for the voice-to-terminal feature.
///
/// Provides binary frame encoding, trigger word detection, transcription chip
/// models, and voice state types. These are the foundation types used by the
/// audio service (Task 4) and UI (Task 5).
///
/// Usage:
///   // Encode a PCM audio chunk for transmission.
///   final frame = VoiceAudioFrame.encode(pcmBytes);
///
///   // Check a transcription segment for a trigger word.
///   final result = TriggerWordDetector.check('ls -la run');
///   if (result.hasTrigger) { /* send cleanText + \r */ }
///
///   // Build a chip for the strip UI.
///   final chip = TranscriptionChip(
///     segmentId: 1,
///     text: result.cleanText,
///     hasTrigger: result.hasTrigger,
///   );
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Binary channel ID reserved for audio frames.
///
/// Sent as a 4-byte little-endian prefix on every audio frame so the Mac-side
/// demuxer can distinguish audio data from RPC messages on the same WebSocket.
const int kVoiceChannelId = 0xFFFFFFFF;

/// Delay before a transcription chip auto-commits after the user stops speaking.
const Duration kChipAutoCommitDelay = Duration(milliseconds: 800);

/// Delay before a committed chip fades out of the strip UI.
const Duration kChipFadeOutDelay = Duration(milliseconds: 800);

/// Silence duration that triggers automatic recording stop.
const Duration kSilenceAutoStopDuration = Duration(seconds: 3);

/// Maximum hold-press duration before a tap is classified as a hold.
const Duration kTapMaxDuration = Duration(milliseconds: 250);

/// Audio sample rate sent to Whisper (16 kHz, mono, 16-bit).
const int kSampleRate = 16000;

/// Bits per PCM sample.
const int kBitsPerSample = 16;

/// Number of audio channels (mono).
const int kChannelCount = 1;

/// Number of PCM bytes per audio chunk (100 ms of 16 kHz 16-bit mono audio:
/// 16000 samples/s * 0.1 s * 2 bytes/sample = 3200 bytes).
const int kAudioChunkBytes = 3200;

// ---------------------------------------------------------------------------
// VoiceAudioFrame
// ---------------------------------------------------------------------------

/// Encodes raw PCM bytes into a binary WebSocket frame for the voice channel.
///
/// Frame format: `[4 bytes LE kVoiceChannelId][pcmBytes]`
///
/// The 4-byte little-endian channel ID prefix lets the Mac-side demuxer route
/// the frame to the voice pipeline rather than the JSON RPC layer.
abstract final class VoiceAudioFrame {
  /// Encodes [pcmBytes] into a framed binary payload.
  ///
  /// Inputs:  [pcmBytes] — raw 16-bit PCM audio samples.
  /// Outputs: [Uint8List] — 4-byte LE header followed by the PCM payload.
  static Uint8List encode(Uint8List pcmBytes) {
    final buffer = ByteData(4 + pcmBytes.length);

    // Write channel ID as little-endian 32-bit unsigned int.
    buffer.setUint32(0, kVoiceChannelId, Endian.little);

    // Copy PCM payload after the header.
    final result = buffer.buffer.asUint8List();
    result.setRange(4, 4 + pcmBytes.length, pcmBytes);
    return result;
  }
}

// ---------------------------------------------------------------------------
// TriggerWordResult
// ---------------------------------------------------------------------------

/// Result of a trigger word check on a transcription segment.
///
/// [hasTrigger] is true when a whole-word trigger was found at the end of the
/// text. [cleanText] is the original text with the trigger word stripped and
/// whitespace trimmed.
class TriggerWordResult {
  /// Whether a trigger word was detected at the end of the text.
  final bool hasTrigger;

  /// The text with the trigger word removed (and trimmed). Equals the original
  /// trimmed text when [hasTrigger] is false.
  final String cleanText;

  /// The matched trigger word (lowercase), or null if no trigger was found.
  final String? triggerWord;

  const TriggerWordResult({
    required this.hasTrigger,
    required this.cleanText,
    this.triggerWord,
  });
}

// ---------------------------------------------------------------------------
// TriggerWordDetector
// ---------------------------------------------------------------------------

/// Detects voice command trigger words at the end of a transcription segment.
///
/// Trigger words: "enter", "run", "execute".
///
/// Only whole-word (whitespace-delimited) trailing matches count — substrings
/// like "center" and prefixes like "rerun" do NOT trigger.
abstract final class TriggerWordDetector {
  static const Set<String> _triggers = {'enter', 'run', 'execute'};

  /// Checks [text] for a trailing trigger word.
  ///
  /// Inputs:  [text] — raw transcription segment (may have trailing whitespace).
  /// Outputs: [TriggerWordResult] with [hasTrigger] and [cleanText].
  static TriggerWordResult check(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const TriggerWordResult(hasTrigger: false, cleanText: '');
    }

    // Split into whitespace-delimited words and examine only the last word.
    final words = trimmed.split(RegExp(r'\s+'));
    final lastWord = words.last.toLowerCase();

    if (_triggers.contains(lastWord)) {
      // Remove the last word and re-join, then trim any trailing whitespace.
      final withoutTrigger = words.sublist(0, words.length - 1).join(' ').trim();
      return TriggerWordResult(
        hasTrigger: true,
        cleanText: withoutTrigger,
        triggerWord: lastWord,
      );
    }

    return TriggerWordResult(hasTrigger: false, cleanText: trimmed);
  }
}

// ---------------------------------------------------------------------------
// ChipStatus
// ---------------------------------------------------------------------------

/// Lifecycle state for a transcription chip in the voice strip.
///
/// - [pending]    — Chip is visible and waiting for auto-commit or user action.
/// - [committing] — Chip is in the process of being sent to the terminal.
/// - [committed]  — Text has been sent; chip is fading out.
/// - [dismissed]  — Chip has been removed from the strip without committing.
enum ChipStatus { pending, committing, committed, dismissed }

// ---------------------------------------------------------------------------
// TranscriptionChip
// ---------------------------------------------------------------------------

/// An immutable transcription chip shown in the voice strip.
///
/// Each chip represents one transcription segment. Equality is determined
/// solely by [segmentId] so that chip lists can be diffed efficiently.
///
/// [commitText] appends `\r` to [text] when [hasTrigger] is true, producing
/// a carriage-return submit to the terminal.
class TranscriptionChip {
  /// Unique identifier for this transcription segment.
  final int segmentId;

  /// Transcription text displayed in the chip (trigger word already stripped).
  final String text;

  /// Whether a trigger word was detected; if true, [commitText] appends `\r`.
  final bool hasTrigger;

  /// Current lifecycle state of this chip.
  final ChipStatus status;

  /// When the chip was created (used for ordering and age-based dismissal).
  final DateTime createdAt;

  TranscriptionChip({
    required this.segmentId,
    required this.text,
    this.hasTrigger = false,
    this.status = ChipStatus.pending,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  // -- Computed --

  /// Text to send to the terminal. Appends `\r` when [hasTrigger] is true so
  /// the terminal treats it as a submitted command.
  String get commitText => hasTrigger ? '$text\r' : text;

  // -- Mutations --

  /// Returns a new [TranscriptionChip] with the given fields overridden.
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

  // -- Equality by segmentId --

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TranscriptionChip && other.segmentId == segmentId);

  @override
  int get hashCode => segmentId.hashCode;

  @override
  String toString() =>
      'TranscriptionChip(segmentId: $segmentId, status: $status, text: $text)';
}

// ---------------------------------------------------------------------------
// RecordingMode
// ---------------------------------------------------------------------------

/// How the user activates recording.
///
/// - [holdToRecord] — Record while the button is held; release to stop.
/// - [tapToggle]    — First tap starts recording; second tap stops.
enum RecordingMode { holdToRecord, tapToggle }

// ---------------------------------------------------------------------------
// VoiceStatus
// ---------------------------------------------------------------------------

/// High-level status of the voice subsystem.
///
/// - [idle]          — No active recording or processing.
/// - [recording]     — Audio is being captured and streamed.
/// - [processing]    — Audio was sent; waiting for transcription result.
/// - [setupRequired] — Whisper model or microphone not yet configured.
enum VoiceStatus { idle, recording, processing, setupRequired }

// ---------------------------------------------------------------------------
// VoiceState
// ---------------------------------------------------------------------------

/// Immutable snapshot of the voice subsystem state.
///
/// Consumed by the voice button and transcript strip widgets. Computed
/// properties [hasActiveChips] and [isStripVisible] drive strip visibility.
class VoiceState {
  /// Current operational status.
  final VoiceStatus status;

  /// How the current (or last) session was initiated, or null if no session yet.
  final RecordingMode? recordingMode;

  /// Transcription chips currently in the strip, ordered by [createdAt].
  final List<TranscriptionChip> chips;

  /// How long the current recording session has been running, or null.
  final Duration? recordingDuration;

  /// Setup progress value in [0.0, 1.0], or null when not in setup.
  final double? setupProgress;

  /// Human-readable setup status message, or null.
  final String? setupMessage;

  /// Most recent error message to surface to the user, or null.
  final String? errorMessage;

  const VoiceState({
    this.status = VoiceStatus.idle,
    this.recordingMode,
    this.chips = const [],
    this.recordingDuration,
    this.setupProgress,
    this.setupMessage,
    this.errorMessage,
  });

  // -- Computed --

  /// Whether any chip is in [pending] or [committing] state.
  ///
  /// Used to keep the strip visible while chips are still actionable.
  bool get hasActiveChips => chips.any(
        (c) => c.status == ChipStatus.pending || c.status == ChipStatus.committing,
      );

  /// Whether the transcript strip should be shown.
  ///
  /// True when recording, processing, or when at least one actionable chip exists.
  bool get isStripVisible =>
      status == VoiceStatus.recording ||
      status == VoiceStatus.processing ||
      hasActiveChips;

  // -- Mutations --

  /// Returns a new [VoiceState] with the given fields overridden.
  VoiceState copyWith({
    VoiceStatus? status,
    RecordingMode? recordingMode,
    List<TranscriptionChip>? chips,
    Duration? recordingDuration,
    double? setupProgress,
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
