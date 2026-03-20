/// Unit tests for VoiceNotifier chip management and silence detection.
///
/// These tests exercise the pure in-process logic only — no recording,
/// no networking, no platform channels. The tests verify:
///   - Chip insertion, ordering, and state transitions
///   - Silence / non-silence energy detection via computeRMSEnergy
///
/// Tests that require real device audio or a live WebSocket are intentionally
/// omitted here; those are covered by the integration test suite.
import 'dart:typed_data';

import 'package:cmux_companion/terminal/voice_protocol.dart';
import 'package:cmux_companion/terminal/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Creates a [VoiceNotifier] and disposes it after the test body runs.
  VoiceNotifier makeNotifier() => VoiceNotifier();

  // ---------------------------------------------------------------------------
  // addChip
  // ---------------------------------------------------------------------------

  group('addChip', () {
    test('appends chip in pending status', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(1, 'hello world', false);

      final chips = notifier.state.chips;
      expect(chips.length, equals(1));
      expect(chips[0].segmentId, equals(1));
      expect(chips[0].text, equals('hello world'));
      expect(chips[0].status, equals(ChipStatus.pending));
    });

    test('addChip with trigger flag sets hasTrigger to true', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(2, 'ls -la', true);

      expect(notifier.state.chips[0].hasTrigger, isTrue);
    });

    test('addChip with no trigger flag sets hasTrigger to false', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(3, 'some text', false);

      expect(notifier.state.chips[0].hasTrigger, isFalse);
    });

    test('chips maintain arrival order when multiple are added', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(10, 'first', false);
      notifier.addChip(11, 'second', false);
      notifier.addChip(12, 'third', false);

      final ids = notifier.state.chips.map((c) => c.segmentId).toList();
      expect(ids, equals([10, 11, 12]));
    });
  });

  // ---------------------------------------------------------------------------
  // dismissChip
  // ---------------------------------------------------------------------------

  group('dismissChip', () {
    test('transitions pending chip to dismissed status', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(5, 'dismiss me', false);
      notifier.dismissChip(5);

      final chip = notifier.state.chips.firstWhere((c) => c.segmentId == 5);
      expect(chip.status, equals(ChipStatus.dismissed));
    });

    test('is a no-op when chip is already committed', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(6, 'already committed', false);
      notifier.markCommitted(6);

      // Attempt to dismiss an already-committed chip.
      notifier.dismissChip(6);

      // Status must remain committed — dismissal is not allowed after commit.
      final chip = notifier.state.chips.firstWhere((c) => c.segmentId == 6);
      expect(chip.status, equals(ChipStatus.committed));
    });

    test('is a no-op for unknown segmentId', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      // Should not throw even for a segment that was never added.
      expect(() => notifier.dismissChip(999), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // markCommitted
  // ---------------------------------------------------------------------------

  group('markCommitted', () {
    test('transitions chip to committed status', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(7, 'commit me', false);
      notifier.markCommitted(7);

      final chip = notifier.state.chips.firstWhere((c) => c.segmentId == 7);
      expect(chip.status, equals(ChipStatus.committed));
    });
  });

  // ---------------------------------------------------------------------------
  // removeChip
  // ---------------------------------------------------------------------------

  group('removeChip', () {
    test('removes chip by segmentId', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(20, 'alpha', false);
      notifier.addChip(21, 'beta', false);
      notifier.removeChip(20);

      final ids = notifier.state.chips.map((c) => c.segmentId).toList();
      expect(ids, equals([21]));
    });

    test('is a no-op for unknown segmentId', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(30, 'gamma', false);
      notifier.removeChip(999);

      // The existing chip should still be present.
      expect(notifier.state.chips.length, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // hasActiveChips
  // ---------------------------------------------------------------------------

  group('hasActiveChips', () {
    test('is true when a chip is pending', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(40, 'pending chip', false);

      expect(notifier.state.hasActiveChips, isTrue);
    });

    test('is false when all chips are dismissed', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(41, 'will dismiss', false);
      notifier.dismissChip(41);

      expect(notifier.state.hasActiveChips, isFalse);
    });

    test('is false when chip list is empty', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      expect(notifier.state.hasActiveChips, isFalse);
    });

    test('is false when all chips are committed', () {
      final notifier = makeNotifier();
      addTearDown(notifier.dispose);

      notifier.addChip(42, 'committed chip', false);
      notifier.markCommitted(42);

      expect(notifier.state.hasActiveChips, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // computeRMSEnergy
  // ---------------------------------------------------------------------------

  group('computeRMSEnergy', () {
    test('returns zero for all-zero (silence) buffer', () {
      // 10 zero samples — completely silent.
      final silence = Uint8List(20); // 10 × 16-bit samples, all zero.

      final energy = VoiceNotifier.computeRMSEnergy(silence);

      expect(energy, equals(0.0));
    });

    test('returns non-zero for non-silent audio', () {
      // Construct a buffer with full-scale positive 16-bit samples (0x7FFF).
      // Value: 32767 LE = [0xFF, 0x7F].
      const sampleCount = 100;
      final bytes = Uint8List(sampleCount * 2);
      final byteData = ByteData.sublistView(bytes);
      for (int i = 0; i < sampleCount; i++) {
        byteData.setInt16(i * 2, 32767, Endian.little);
      }

      final energy = VoiceNotifier.computeRMSEnergy(bytes);

      // Non-zero signal must produce energy above the silence threshold.
      expect(energy, greaterThan(0.0));
      expect(energy, greaterThanOrEqualTo(0.02));
    });

    test('returns zero for empty buffer', () {
      final energy = VoiceNotifier.computeRMSEnergy(Uint8List(0));
      expect(energy, equals(0.0));
    });

    test('returns zero for single-byte buffer (no complete sample)', () {
      final energy = VoiceNotifier.computeRMSEnergy(Uint8List.fromList([0xAB]));
      expect(energy, equals(0.0));
    });

    test('result is clamped to [0.0, 1.0]', () {
      // Full-scale signal should not exceed 1.0.
      const sampleCount = 8;
      final bytes = Uint8List(sampleCount * 2);
      final byteData = ByteData.sublistView(bytes);
      for (int i = 0; i < sampleCount; i++) {
        byteData.setInt16(i * 2, 32767, Endian.little);
      }

      final energy = VoiceNotifier.computeRMSEnergy(bytes);

      expect(energy, lessThanOrEqualTo(1.0));
      expect(energy, greaterThanOrEqualTo(0.0));
    });
  });
}
