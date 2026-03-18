/// Parses binary cell frames sent from the Mac's BridgeCellStream
/// into CellData lists for rendering.
///
/// Frame types:
///   0x01 — Full snapshot: complete screen contents
///   0x02 — Dirty rows: only changed rows
///   0x03 — Cursor only: cursor position update
library;

import 'dart:typed_data';

import '../native/ghostty_vt.dart';

/// Result of parsing a cell frame.
class CellFrameResult {
  /// Updated cell list (full grid, row-major order).
  final List<CellData> cells;

  /// Grid dimensions.
  final int cols;
  final int rows;

  /// Cursor state.
  final int cursorCol;
  final int cursorRow;
  final bool cursorVisible;

  /// Whether the cell grid changed (false for cursor-only updates).
  final bool cellsChanged;

  const CellFrameResult({
    required this.cells,
    required this.cols,
    required this.rows,
    required this.cursorCol,
    required this.cursorRow,
    required this.cursorVisible,
    required this.cellsChanged,
  });
}

/// Stateful parser that maintains the current cell grid and applies
/// incremental updates from binary frames.
class CellFrameParser {
  List<CellData> _cells = [];
  int _cols = 0;
  int _rows = 0;
  int _cursorCol = 0;
  int _cursorRow = 0;
  bool _cursorVisible = true;

  /// Size of a single cell in the binary encoding (20 bytes).
  static const _cellSize = 20;

  /// Parse a binary frame (after the 4-byte channel ID has been stripped).
  ///
  /// Returns null if the frame is malformed or too short.
  CellFrameResult? parse(Uint8List data) {
    if (data.isEmpty) return null;

    final frameType = data[0];

    switch (frameType) {
      case 0x01:
        return _parseFullSnapshot(data);
      case 0x02:
        return _parseDirtyRows(data);
      case 0x03:
        return _parseCursorOnly(data);
      default:
        return null;
    }
  }

  /// Frame type 0x01: Full snapshot.
  ///
  /// Layout:
  ///   [1] frame type (0x01)
  ///   [2] cols (LE u16)
  ///   [2] rows (LE u16)
  ///   [1] cursor_col
  ///   [1] cursor_row
  ///   [1] cursor_visible
  ///   [cols*rows * 20] cell data
  CellFrameResult? _parseFullSnapshot(Uint8List data) {
    if (data.length < 8) return null;

    final bd = data.buffer.asByteData(data.offsetInBytes, data.length);
    final cols = bd.getUint16(1, Endian.little);
    final rows = bd.getUint16(3, Endian.little);
    _cursorCol = bd.getUint8(5);
    _cursorRow = bd.getUint8(6);
    _cursorVisible = bd.getUint8(7) != 0;

    final totalCells = cols * rows;
    final expectedLen = 8 + totalCells * _cellSize;
    if (data.length < expectedLen) return null;

    _cols = cols;
    _rows = rows;
    _cells = List<CellData>.generate(totalCells, (i) {
      return _readCell(bd, 8 + i * _cellSize);
    });

    return CellFrameResult(
      cells: _cells,
      cols: _cols,
      rows: _rows,
      cursorCol: _cursorCol,
      cursorRow: _cursorRow,
      cursorVisible: _cursorVisible,
      cellsChanged: true,
    );
  }

  /// Frame type 0x02: Dirty rows.
  ///
  /// Layout:
  ///   [1] frame type (0x02)
  ///   [2] cols (LE u16)
  ///   [1] cursor_col
  ///   [1] cursor_row
  ///   [1] cursor_visible
  ///   Per dirty row:
  ///     [2] row_index (LE u16)
  ///     [cols * 20] cell data
  ///   [2] 0xFFFF sentinel
  CellFrameResult? _parseDirtyRows(Uint8List data) {
    if (data.length < 6) return null;

    final bd = data.buffer.asByteData(data.offsetInBytes, data.length);
    final cols = bd.getUint16(1, Endian.little);
    _cursorCol = bd.getUint8(3);
    _cursorRow = bd.getUint8(4);
    _cursorVisible = bd.getUint8(5) != 0;

    // If cols changed, we can't apply a dirty-row update meaningfully.
    if (cols != _cols || _cells.isEmpty) return null;

    // Make a mutable copy to apply dirty rows.
    _cells = List<CellData>.from(_cells);

    int offset = 6;
    bool anyChange = false;

    while (offset + 2 <= data.length) {
      final rowIndex = bd.getUint16(offset, Endian.little);
      offset += 2;

      if (rowIndex == 0xFFFF) break; // Sentinel
      if (rowIndex >= _rows) return null; // Invalid row

      final rowDataLen = cols * _cellSize;
      if (offset + rowDataLen > data.length) return null;

      final baseIdx = rowIndex * cols;
      for (int x = 0; x < cols; x++) {
        _cells[baseIdx + x] = _readCell(bd, offset + x * _cellSize);
      }
      offset += rowDataLen;
      anyChange = true;
    }

    return CellFrameResult(
      cells: _cells,
      cols: _cols,
      rows: _rows,
      cursorCol: _cursorCol,
      cursorRow: _cursorRow,
      cursorVisible: _cursorVisible,
      cellsChanged: anyChange,
    );
  }

  /// Frame type 0x03: Cursor only.
  ///
  /// Layout:
  ///   [1] frame type (0x03)
  ///   [1] cursor_col
  ///   [1] cursor_row
  ///   [1] cursor_visible
  CellFrameResult? _parseCursorOnly(Uint8List data) {
    if (data.length < 4) return null;

    _cursorCol = data[1];
    _cursorRow = data[2];
    _cursorVisible = data[3] != 0;

    return CellFrameResult(
      cells: _cells,
      cols: _cols,
      rows: _rows,
      cursorCol: _cursorCol,
      cursorRow: _cursorRow,
      cursorVisible: _cursorVisible,
      cellsChanged: false,
    );
  }

  /// Read a single CellData from the binary buffer at the given offset.
  ///
  /// Per-cell encoding (20 bytes):
  ///   [4] codepoint (LE u32)
  ///   [1] grapheme_len
  ///   [3] fg_rgb
  ///   [1] fg_is_default
  ///   [3] bg_rgb
  ///   [1] bg_is_default
  ///   [3] ul_rgb
  ///   [1] ul_is_default
  ///   [1] underline_style
  ///   [2] flags (LE u16)
  static CellData _readCell(ByteData bd, int offset) {
    return CellData(
      codepoint: bd.getUint32(offset, Endian.little),
      graphemeLen: bd.getUint8(offset + 4),
      fgR: bd.getUint8(offset + 5),
      fgG: bd.getUint8(offset + 6),
      fgB: bd.getUint8(offset + 7),
      fgIsDefault: bd.getUint8(offset + 8) != 0,
      bgR: bd.getUint8(offset + 9),
      bgG: bd.getUint8(offset + 10),
      bgB: bd.getUint8(offset + 11),
      bgIsDefault: bd.getUint8(offset + 12) != 0,
      ulR: bd.getUint8(offset + 13),
      ulG: bd.getUint8(offset + 14),
      ulB: bd.getUint8(offset + 15),
      ulIsDefault: bd.getUint8(offset + 16) != 0,
      underlineStyle: bd.getUint8(offset + 17),
      flags: bd.getUint16(offset + 18, Endian.little),
    );
  }
}
