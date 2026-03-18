import 'dart:async';
import 'dart:typed_data';

import 'package:cmux_companion/connection/pty_demuxer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PtyDemuxer', () {
    late PtyDemuxer demuxer;

    setUp(() {
      demuxer = PtyDemuxer();
    });

    tearDown(() {
      demuxer.dispose();
    });

    /// Build a binary frame with a 4-byte LE channel ID header.
    Uint8List buildFrame(int channelId, List<int> data) {
      final buf = ByteData(4 + data.length);
      buf.setUint32(0, channelId, Endian.little);
      for (var i = 0; i < data.length; i++) {
        buf.setUint8(4 + i, data[i]);
      }
      return buf.buffer.asUint8List();
    }

    test('routes binary frame to correct channel', () async {
      final received = <Uint8List>[];
      demuxer.subscribe(42).listen(received.add);

      demuxer.handleBinaryFrame(buildFrame(42, [0x48, 0x65, 0x6C, 0x6C, 0x6F]));
      await Future.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received[0], equals([0x48, 0x65, 0x6C, 0x6C, 0x6F]));
    });

    test('ignores frames for unsubscribed channels', () async {
      final received = <Uint8List>[];
      demuxer.subscribe(1).listen(received.add);

      // Send to channel 2 — no subscriber.
      demuxer.handleBinaryFrame(buildFrame(2, [0x41]));
      await Future.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('demultiplexes to multiple channels', () async {
      final ch1 = <Uint8List>[];
      final ch2 = <Uint8List>[];

      demuxer.subscribe(1).listen(ch1.add);
      demuxer.subscribe(2).listen(ch2.add);

      demuxer.handleBinaryFrame(buildFrame(1, [0x41]));
      demuxer.handleBinaryFrame(buildFrame(2, [0x42]));
      demuxer.handleBinaryFrame(buildFrame(1, [0x43]));
      await Future.delayed(Duration.zero);

      expect(ch1, hasLength(2));
      expect(ch1[0], equals([0x41]));
      expect(ch1[1], equals([0x43]));
      expect(ch2, hasLength(1));
      expect(ch2[0], equals([0x42]));
    });

    test('drops frames shorter than 5 bytes', () async {
      final received = <Uint8List>[];
      demuxer.subscribe(0).listen(received.add);

      // 4-byte frame (header only, no data).
      demuxer.handleBinaryFrame(Uint8List.fromList([0, 0, 0, 0]));
      // 3-byte frame (too short for header).
      demuxer.handleBinaryFrame(Uint8List.fromList([0, 0, 0]));
      // Empty frame.
      demuxer.handleBinaryFrame(Uint8List(0));
      await Future.delayed(Duration.zero);

      expect(received, isEmpty);
    });

    test('unsubscribe stops delivery', () async {
      final received = <Uint8List>[];
      demuxer.subscribe(99).listen(received.add);

      demuxer.handleBinaryFrame(buildFrame(99, [0x01]));
      await Future.delayed(Duration.zero);
      expect(received, hasLength(1));

      demuxer.unsubscribe(99);

      demuxer.handleBinaryFrame(buildFrame(99, [0x02]));
      await Future.delayed(Duration.zero);
      expect(received, hasLength(1));
    });

    test('activeChannels tracks subscriptions', () {
      expect(demuxer.activeChannels, isEmpty);

      demuxer.subscribe(10);
      demuxer.subscribe(20);
      expect(demuxer.activeChannels, equals({10, 20}));

      demuxer.unsubscribe(10);
      expect(demuxer.activeChannels, equals({20}));
    });

    test('handles large channel IDs correctly', () async {
      // Max 32-bit unsigned: 0xFFFFFFFF = 4294967295
      const channelId = 0xFFFFFFFF;
      final received = <Uint8List>[];
      demuxer.subscribe(channelId).listen(received.add);

      demuxer.handleBinaryFrame(buildFrame(channelId, [0xAA]));
      await Future.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received[0], equals([0xAA]));
    });
  });
}
