/// Lightweight cell stream consumer for minimap pane tiles.
///
/// Subscribes to the same `surface.cells.subscribe` stream that the
/// main [TerminalView] uses, but throttles repaints to ~3fps (300ms)
/// since the minimap only needs spatial awareness, not readability.
///
/// Lifecycle mirrors [_TerminalViewState]: call [subscribe] on mount,
/// [dispose] on unmount. Does NOT send resize or workspace.select —
/// the minimap shows the Mac's native resolution as-is.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/connection_manager.dart';
import '../terminal/cell_frame_parser.dart';
import '../native/ghostty_vt.dart';

class MinimapCellConsumer {
  final ConnectionManager _manager;
  final String _surfaceId;
  final VoidCallback _onUpdate;

  final _parser = CellFrameParser();
  StreamSubscription<Uint8List>? _cellSub;
  int? _channelId;
  Timer? _repaintTimer;

  /// Whether new cell data arrived since the last repaint callback.
  bool _dirty = false;

  /// Whether at least one full snapshot has been received.
  bool _hasData = false;

  /// Debug status for on-screen diagnostics (remove after debugging).
  String debugStatus = 'init';
  int _frameCount = 0;

  // Exposed state for the painter.
  List<CellData> cells = [];
  int cols = 0;
  int rows = 0;

  /// Repaint interval (~3fps). Minimap doesn't need 60fps.
  static const _repaintInterval = Duration(milliseconds: 300);

  MinimapCellConsumer({
    required ConnectionManager manager,
    required String surfaceId,
    required VoidCallback onUpdate,
  })  : _manager = manager,
        _surfaceId = surfaceId,
        _onUpdate = onUpdate;

  bool get hasData => _hasData;

  /// Subscribe to the cell stream for this surface.
  ///
  /// Follows the same pattern as `_TerminalViewState._subscribeToSurface`
  /// but skips workspace.select and resize — minimap is read-only.
  Future<void> subscribe() async {
    debugStatus = 'subscribing...';
    _onUpdate();
    try {
      final response = await _manager.sendRequest(
        'surface.cells.subscribe',
        params: {'surface_id': _surfaceId},
      );

      debugPrint('[MinimapCell] Subscribe response for $_surfaceId: ok=${response.ok} result=${response.result} error=${response.error}');

      if (!response.ok || response.result == null) {
        debugStatus = 'FAIL: ${response.error ?? "no result"}';
        _onUpdate();
        return;
      }

      _channelId = response.result!['channel'] as int?;
      if (_channelId == null) {
        debugStatus = 'FAIL: no channel';
        _onUpdate();
        return;
      }

      debugStatus = 'ch=$_channelId waiting...';
      _onUpdate();

      // Listen for binary cell frames.
      _cellSub = _manager.ptyDemuxer.subscribe(_channelId!).listen(_onFrame);

      // Periodic repaint timer — checks dirty flag every 300ms.
      _repaintTimer = Timer.periodic(_repaintInterval, (_) {
        if (_dirty) {
          _dirty = false;
          _onUpdate();
        }
      });
    } catch (e) {
      debugStatus = 'ERR: $e';
      _onUpdate();
    }
  }

  /// Handles an incoming binary cell frame.
  ///
  /// Parses immediately (keeps internal state current) but does NOT
  /// trigger a repaint. The periodic timer handles that at ~3fps.
  void _onFrame(Uint8List data) {
    _frameCount++;
    debugStatus = 'frames=$_frameCount ${data.length}B';
    final result = _parser.parse(data);
    if (result == null) {
      debugStatus = 'frames=$_frameCount PARSE_NULL';
      return;
    }

    // Only update exposed state when cells actually changed.
    if (result.cellsChanged) {
      debugStatus = 'LIVE ${result.cols}x${result.rows} f=$_frameCount';
      cells = result.cells;
      cols = result.cols;
      rows = result.rows;
      _hasData = true;
      _dirty = true;
    }
  }

  /// Unsubscribe and release all resources.
  void dispose() {
    _repaintTimer?.cancel();
    _repaintTimer = null;

    _cellSub?.cancel();
    _cellSub = null;

    if (_channelId != null) {
      try {
        _manager.sendRequest(
          'surface.cells.unsubscribe',
          params: {'surface_id': _surfaceId},
        );
        _manager.ptyDemuxer.unsubscribe(_channelId!);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }
}
