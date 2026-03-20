import 'dart:typed_data';

import 'package:cmux_companion/terminal/voice_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // VoiceAudioFrame
  // ---------------------------------------------------------------------------

  group('VoiceAudioFrame', () {
    test('encodeFrame prefixes PCM bytes with 0xFFFFFFFF channel ID', () {
      final pcm = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final frame = VoiceAudioFrame.encode(pcm);

      // Frame must be 4 (header) + 4 (payload) = 8 bytes.
      expect(frame.length, equals(8));

      // Header: 0xFFFFFFFF in little-endian = [0xFF, 0xFF, 0xFF, 0xFF].
      expect(frame[0], equals(0xFF));
      expect(frame[1], equals(0xFF));
      expect(frame[2], equals(0xFF));
      expect(frame[3], equals(0xFF));

      // Payload bytes follow verbatim.
      expect(frame[4], equals(0x01));
      expect(frame[5], equals(0x02));
      expect(frame[6], equals(0x03));
      expect(frame[7], equals(0x04));
    });

    test('encodeFrame with empty payload produces 4-byte header only', () {
      final frame = VoiceAudioFrame.encode(Uint8List(0));

      expect(frame.length, equals(4));
      expect(frame[0], equals(0xFF));
      expect(frame[1], equals(0xFF));
      expect(frame[2], equals(0xFF));
      expect(frame[3], equals(0xFF));
    });
  });

  // ---------------------------------------------------------------------------
  // TriggerWordDetector
  // ---------------------------------------------------------------------------

  group('TriggerWordDetector', () {
    test('detects "enter" as trailing trigger word', () {
      final result = TriggerWordDetector.check('hello world enter');
      expect(result.hasTrigger, isTrue);
      expect(result.cleanText, equals('hello world'));
      expect(result.triggerWord, equals('enter'));
    });

    test('detects "run" as trailing trigger word', () {
      final result = TriggerWordDetector.check('ls -la run');
      expect(result.hasTrigger, isTrue);
      expect(result.cleanText, equals('ls -la'));
      expect(result.triggerWord, equals('run'));
    });

    test('detects "execute" as trailing trigger word', () {
      final result = TriggerWordDetector.check('git status execute');
      expect(result.hasTrigger, isTrue);
      expect(result.cleanText, equals('git status'));
    });

    test('trigger word detection is case-insensitive', () {
      expect(TriggerWordDetector.check('hello ENTER').hasTrigger, isTrue);
      expect(TriggerWordDetector.check('hello Run').hasTrigger, isTrue);
      expect(TriggerWordDetector.check('hello EXECUTE').hasTrigger, isTrue);
    });

    test('does NOT trigger on "center" (substring of trigger word)', () {
      final result = TriggerWordDetector.check('go to center');
      expect(result.hasTrigger, isFalse);
      expect(result.cleanText, equals('go to center'));
    });

    test('does NOT trigger on "rerun" (starts with trigger word)', () {
      final result = TriggerWordDetector.check('please rerun');
      expect(result.hasTrigger, isFalse);
      expect(result.cleanText, equals('please rerun'));
    });

    test('handles single-word trigger: cleanText is empty string', () {
      final result = TriggerWordDetector.check('enter');
      expect(result.hasTrigger, isTrue);
      expect(result.cleanText, equals(''));
    });

    test('handles empty string: no trigger', () {
      final result = TriggerWordDetector.check('');
      expect(result.hasTrigger, isFalse);
      expect(result.cleanText, equals(''));
    });

    test('handles trailing whitespace correctly', () {
      // Trailing whitespace should not cause a false trigger and should be trimmed.
      final result = TriggerWordDetector.check('hello world   ');
      expect(result.hasTrigger, isFalse);
      expect(result.cleanText, equals('hello world'));
    });

    test('trigger word at end with trailing whitespace still triggers', () {
      final result = TriggerWordDetector.check('ls enter  ');
      expect(result.hasTrigger, isTrue);
      expect(result.cleanText, equals('ls'));
    });
  });

  // ---------------------------------------------------------------------------
  // TranscriptionChip
  // ---------------------------------------------------------------------------

  group('TranscriptionChip', () {
    test('creates chip with pending status by default', () {
      final chip = TranscriptionChip(
        segmentId: 1,
        text: 'hello world',
      );

      expect(chip.segmentId, equals(1));
      expect(chip.text, equals('hello world'));
      expect(chip.hasTrigger, isFalse);
      expect(chip.status, equals(ChipStatus.pending));
      expect(chip.createdAt, isNotNull);
    });

    test('commitText returns plain text when no trigger', () {
      final chip = TranscriptionChip(
        segmentId: 1,
        text: 'git status',
        hasTrigger: false,
        status: ChipStatus.pending,
        createdAt: DateTime(2024),
      );

      expect(chip.commitText, equals('git status'));
    });

    test('commitText appends \\r when trigger detected', () {
      final chip = TranscriptionChip(
        segmentId: 2,
        text: 'ls -la',
        hasTrigger: true,
        status: ChipStatus.pending,
        createdAt: DateTime(2024),
      );

      expect(chip.commitText, equals('ls -la\r'));
    });

    test('copyWith transitions status from pending to committing', () {
      final chip = TranscriptionChip(
        segmentId: 3,
        text: 'echo hello',
        hasTrigger: false,
        status: ChipStatus.pending,
        createdAt: DateTime(2024),
      );

      final committing = chip.copyWith(status: ChipStatus.committing);
      expect(committing.status, equals(ChipStatus.committing));
      // Other fields unchanged.
      expect(committing.segmentId, equals(3));
      expect(committing.text, equals('echo hello'));
      expect(committing.hasTrigger, isFalse);
    });

    test('dismissed chip has dismissed status', () {
      final chip = TranscriptionChip(
        segmentId: 4,
        text: 'dismissed text',
        hasTrigger: false,
        status: ChipStatus.dismissed,
        createdAt: DateTime(2024),
      );

      expect(chip.status, equals(ChipStatus.dismissed));
    });

    test('equality is by segmentId', () {
      final a = TranscriptionChip(
        segmentId: 5,
        text: 'text a',
        hasTrigger: false,
        status: ChipStatus.pending,
        createdAt: DateTime(2024),
      );
      final b = TranscriptionChip(
        segmentId: 5,
        text: 'text b',
        hasTrigger: true,
        status: ChipStatus.committed,
        createdAt: DateTime(2025),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  // ---------------------------------------------------------------------------
  // VoiceState
  // ---------------------------------------------------------------------------

  group('VoiceState', () {
    test('hasActiveChips returns true when pending chips exist', () {
      final state = VoiceState(
        status: VoiceStatus.idle,
        recordingMode: RecordingMode.holdToRecord,
        chips: [
          TranscriptionChip(
            segmentId: 1,
            text: 'hello',
            hasTrigger: false,
            status: ChipStatus.pending,
            createdAt: DateTime(2024),
          ),
        ],
      );

      expect(state.hasActiveChips, isTrue);
    });

    test('hasActiveChips returns true when committing chips exist', () {
      final state = VoiceState(
        status: VoiceStatus.idle,
        recordingMode: RecordingMode.holdToRecord,
        chips: [
          TranscriptionChip(
            segmentId: 1,
            text: 'hello',
            hasTrigger: false,
            status: ChipStatus.committing,
            createdAt: DateTime(2024),
          ),
        ],
      );

      expect(state.hasActiveChips, isTrue);
    });

    test('hasActiveChips returns false when only committed/dismissed chips', () {
      final state = VoiceState(
        status: VoiceStatus.idle,
        recordingMode: RecordingMode.holdToRecord,
        chips: [
          TranscriptionChip(
            segmentId: 1,
            text: 'hello',
            hasTrigger: false,
            status: ChipStatus.committed,
            createdAt: DateTime(2024),
          ),
          TranscriptionChip(
            segmentId: 2,
            text: 'world',
            hasTrigger: false,
            status: ChipStatus.dismissed,
            createdAt: DateTime(2024),
          ),
        ],
      );

      expect(state.hasActiveChips, isFalse);
    });

    test('isStripVisible when recording', () {
      final state = VoiceState(
        status: VoiceStatus.recording,
        recordingMode: RecordingMode.holdToRecord,
        chips: const [],
      );

      expect(state.isStripVisible, isTrue);
    });

    test('isStripVisible when has active chips (idle)', () {
      final state = VoiceState(
        status: VoiceStatus.idle,
        recordingMode: RecordingMode.holdToRecord,
        chips: [
          TranscriptionChip(
            segmentId: 1,
            text: 'hello',
            hasTrigger: false,
            status: ChipStatus.pending,
            createdAt: DateTime(2024),
          ),
        ],
      );

      expect(state.isStripVisible, isTrue);
    });

    test('isStripVisible is true when processing even with no chips', () {
      final state = VoiceState(
        status: VoiceStatus.processing,
      );

      expect(state.isStripVisible, isTrue);
    });

    test('isStripVisible is false when idle with no active chips', () {
      final state = VoiceState(
        status: VoiceStatus.idle,
      );

      expect(state.isStripVisible, isFalse);
    });

    test('copyWith preserves unmodified fields', () {
      final original = VoiceState(
        status: VoiceStatus.recording,
        recordingMode: RecordingMode.tapToggle,
        chips: const [],
        recordingDuration: const Duration(seconds: 5),
        errorMessage: 'test error',
      );

      final updated = original.copyWith(status: VoiceStatus.idle);

      expect(updated.status, equals(VoiceStatus.idle));
      // These fields are preserved.
      expect(updated.recordingMode, equals(RecordingMode.tapToggle));
      expect(updated.chips, isEmpty);
      expect(updated.recordingDuration, equals(const Duration(seconds: 5)));
      expect(updated.errorMessage, equals('test error'));
    });

    test('copyWith can update chips list', () {
      final original = VoiceState(
        status: VoiceStatus.idle,
        recordingMode: RecordingMode.holdToRecord,
        chips: const [],
      );

      final chip = TranscriptionChip(
        segmentId: 1,
        text: 'hello',
        hasTrigger: false,
        status: ChipStatus.pending,
        createdAt: DateTime(2024),
      );
      final updated = original.copyWith(chips: [chip]);

      expect(updated.chips.length, equals(1));
      expect(updated.chips.first.segmentId, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  group('Voice constants', () {
    test('kVoiceChannelId equals 0xFFFFFFFF', () {
      expect(kVoiceChannelId, equals(0xFFFFFFFF));
    });

    test('kSampleRate is 16000', () {
      expect(kSampleRate, equals(16000));
    });

    test('kAudioChunkBytes is 3200', () {
      expect(kAudioChunkBytes, equals(3200));
    });
  });
}
