/// Demultiplexes binary WebSocket frames into per-channel PTY streams.
///
/// Binary frame format (from BridgeConnection.swift):
///   [4 bytes little-endian channel ID][raw PTY data bytes]
///
/// Each channel ID maps to a surface UUID's deterministic 32-bit hash.
/// Consumers subscribe to a channel and receive a [Stream<Uint8List>]
/// of raw terminal output for that channel.
library;

import 'dart:async';
import 'dart:typed_data';

class PtyDemuxer {
  final Map<int, StreamController<Uint8List>> _channels = {};

  /// Subscribe to PTY output for a specific channel ID.
  ///
  /// Returns a broadcast stream of raw PTY bytes for this channel.
  /// Multiple listeners can subscribe to the same channel.
  Stream<Uint8List> subscribe(int channelId) {
    final controller = _channels.putIfAbsent(
      channelId,
      () => StreamController<Uint8List>.broadcast(),
    );
    return controller.stream;
  }

  /// Unsubscribe from a channel. Closes the stream controller if no
  /// listeners remain.
  void unsubscribe(int channelId) {
    final controller = _channels.remove(channelId);
    controller?.close();
  }

  /// Process an incoming binary WebSocket frame.
  ///
  /// Extracts the 4-byte little-endian channel ID header and routes
  /// the remaining bytes to the corresponding channel stream.
  ///
  /// Frames shorter than 5 bytes (4-byte header + at least 1 data byte)
  /// are silently dropped.
  void handleBinaryFrame(Uint8List frame) {
    if (frame.length < 5) return;

    // Extract 4-byte little-endian channel ID.
    final channelId = frame.buffer.asByteData(frame.offsetInBytes).getUint32(0, Endian.little);

    // Route the PTY data (everything after the 4-byte header).
    final controller = _channels[channelId];
    if (controller != null && !controller.isClosed) {
      final data = Uint8List.sublistView(frame, 4);
      controller.add(data);
    }
  }

  /// Close all channels and clean up resources.
  void dispose() {
    for (final controller in _channels.values) {
      controller.close();
    }
    _channels.clear();
  }

  /// Set of currently active channel IDs.
  Set<int> get activeChannels => _channels.keys.toSet();
}
