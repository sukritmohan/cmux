/// High-level Dart wrapper around the GhosttyKit VT terminal C API.
///
/// Opens `libghostty-vt.so` via [DynamicLibrary] and exposes a safe,
/// idiomatic Dart interface for creating terminals, feeding PTY data,
/// reading cell/screen state, and querying cursor/mode/color info.
///
/// Thread safety: A single [TerminalState] must only be accessed from
/// one isolate at a time. The underlying C terminal is not thread-safe.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ghostty_vt_bindings.dart';

/// Resolved cell data extracted from the native [GhosttyCell].
///
/// Immutable snapshot of a single terminal cell with decoded colors,
/// flags, and codepoint.
class CellData {
  final int codepoint;
  final int fgR, fgG, fgB;
  final bool fgIsDefault;
  final int bgR, bgG, bgB;
  final bool bgIsDefault;
  final int ulR, ulG, ulB;
  final bool ulIsDefault;
  final int underlineStyle;
  final int flags;
  final int graphemeLen;

  const CellData({
    required this.codepoint,
    required this.fgR,
    required this.fgG,
    required this.fgB,
    required this.fgIsDefault,
    required this.bgR,
    required this.bgG,
    required this.bgB,
    required this.bgIsDefault,
    required this.ulR,
    required this.ulG,
    required this.ulB,
    required this.ulIsDefault,
    required this.underlineStyle,
    required this.flags,
    required this.graphemeLen,
  });

  /// Construct from a native [GhosttyCell] struct pointer.
  factory CellData.fromNative(GhosttyCell cell) {
    return CellData(
      codepoint: cell.codepoint,
      fgR: cell.fg_r,
      fgG: cell.fg_g,
      fgB: cell.fg_b,
      fgIsDefault: cell.fg_is_default,
      bgR: cell.bg_r,
      bgG: cell.bg_g,
      bgB: cell.bg_b,
      bgIsDefault: cell.bg_is_default,
      ulR: cell.ul_r,
      ulG: cell.ul_g,
      ulB: cell.ul_b,
      ulIsDefault: cell.ul_is_default,
      underlineStyle: cell.underline_style,
      flags: cell.flags,
      graphemeLen: cell.grapheme_len,
    );
  }

  // Flag accessors
  bool get isBold => (flags & (1 << 0)) != 0;
  bool get isItalic => (flags & (1 << 1)) != 0;
  bool get isFaint => (flags & (1 << 2)) != 0;
  bool get isUnderline => (flags & (1 << 3)) != 0;
  bool get isStrikethrough => (flags & (1 << 4)) != 0;
  bool get isInverse => (flags & (1 << 5)) != 0;
  bool get isInvisible => (flags & (1 << 6)) != 0;
  bool get isOverline => (flags & (1 << 7)) != 0;
  bool get isBlink => (flags & (1 << 8)) != 0;
  bool get isWide => (flags & (1 << 9)) != 0;
  bool get isSpacerHead => (flags & (1 << 10)) != 0;
  bool get isSpacerTail => (flags & (1 << 11)) != 0;
  bool get hasHyperlink => (flags & (1 << 13)) != 0;

  /// The Unicode character for this cell, or space if empty.
  String get character => codepoint == 0 ? ' ' : String.fromCharCode(codepoint);
}

/// Cell flag bit positions for direct bitfield checks.
abstract final class CellFlags {
  static const int bold = 1 << 0;
  static const int italic = 1 << 1;
  static const int faint = 1 << 2;
  static const int underline = 1 << 3;
  static const int strikethrough = 1 << 4;
  static const int inverse = 1 << 5;
  static const int invisible = 1 << 6;
  static const int overline = 1 << 7;
  static const int blink = 1 << 8;
  static const int wide = 1 << 9;
  static const int spacerHead = 1 << 10;
  static const int spacerTail = 1 << 11;
  static const int hasHyperlink = 1 << 13;
}

/// Cursor style constants matching the C API.
abstract final class CursorStyle {
  static const int block = 0;
  static const int underline = 1;
  static const int bar = 2;
  static const int blockHollow = 3;
}

/// High-level wrapper around a GhosttyTerminal C handle.
///
/// Manages native memory lifecycle. Call [dispose] when done.
class TerminalState {
  /// The native library handle — loaded once per process.
  static late final DynamicLibrary _lib;
  static bool _libLoaded = false;

  // Native function pointers — resolved once at library load.
  static late final ghostty_terminal_new_Dart _new;
  static late final ghostty_terminal_free_Dart _free;
  static late final ghostty_terminal_resize_Dart _resize;
  static late final ghostty_terminal_reset_Dart _reset;
  static late final ghostty_terminal_feed_Dart _feed;
  static late final ghostty_terminal_uint16_Dart _cols;
  static late final ghostty_terminal_uint16_Dart _rows;
  static late final ghostty_terminal_uint16_Dart _cursorCol;
  static late final ghostty_terminal_uint16_Dart _cursorRow;
  static late final ghostty_terminal_uint8_Dart _cursorStyle;
  static late final ghostty_terminal_bool_Dart _cursorVisible;
  static late final ghostty_terminal_bool_Dart _cursorBlinking;
  static late final ghostty_terminal_cell_at_Dart _cellAt;
  static late final ghostty_terminal_read_screen_Dart _readScreen;
  static late final ghostty_terminal_cell_grapheme_Dart _cellGrapheme;
  static late final ghostty_terminal_row_at_Dart _rowAt;
  static late final ghostty_terminal_bool_Dart _isDirty;
  static late final ghostty_terminal_row_is_dirty_Dart _rowIsDirty;
  static late final ghostty_terminal_clear_dirty_Dart _clearDirty;
  static late final ghostty_terminal_scrollback_len_Dart _scrollbackLen;
  static late final ghostty_terminal_scroll_viewport_Dart _scrollViewport;
  static late final ghostty_terminal_bool_Dart _viewportIsScrolled;
  static late final ghostty_terminal_scroll_to_bottom_Dart _scrollToBottom;
  static late final ghostty_terminal_read_scrollback_row_Dart _readScrollbackRow;
  static late final ghostty_terminal_get_selection_Dart _getSelection;
  static late final ghostty_terminal_select_start_Dart _selectStart;
  static late final ghostty_terminal_select_update_Dart _selectUpdate;
  static late final ghostty_terminal_select_clear_Dart _selectClear;
  static late final ghostty_terminal_select_word_Dart _selectWord;
  static late final ghostty_terminal_select_line_Dart _selectLine;
  static late final ghostty_terminal_select_all_Dart _selectAll;
  static late final ghostty_terminal_selection_string_Dart _selectionString;
  static late final ghostty_terminal_free_string_Dart _freeString;
  static late final ghostty_terminal_string_Dart _dumpScreen;
  static late final ghostty_terminal_string_Dart _dumpScreenUnwrapped;
  static late final ghostty_terminal_modes_Dart _modes;
  static late final ghostty_terminal_pwd_copy_Dart _pwdCopy;
  static late final ghostty_terminal_bool_Dart _cursorIsAtPrompt;
  static late final ghostty_terminal_default_color_Dart _defaultFg;
  static late final ghostty_terminal_default_color_Dart _defaultBg;
  static late final ghostty_terminal_default_color_Dart _cursorColor;

  /// The opaque native terminal handle.
  Pointer<Void> _handle = nullptr;

  /// Whether [dispose] has been called.
  bool _disposed = false;

  /// Reusable buffer for bulk screen reads. Allocated to cols*rows cells.
  Pointer<GhosttyCell> _screenBuf = nullptr;
  int _screenBufLen = 0;

  /// Create a new terminal with the given dimensions.
  ///
  /// Throws [StateError] if the native library failed to create the terminal.
  factory TerminalState({int cols = 80, int rows = 24}) {
    _ensureLibLoaded();

    final outPtr = calloc<Pointer<Void>>();
    try {
      final result = _new(nullptr, cols, rows, outPtr);
      if (result != 0 || outPtr.value == nullptr) {
        throw StateError(
            'ghostty_terminal_new failed with result $result');
      }
      return TerminalState._(outPtr.value, cols, rows);
    } finally {
      calloc.free(outPtr);
    }
  }

  TerminalState._(this._handle, int cols, int rows) {
    _allocScreenBuf(cols * rows);
  }

  /// Ensures the native library is loaded exactly once.
  static void _ensureLibLoaded() {
    if (_libLoaded) return;

    _lib = DynamicLibrary.open('libghostty-vt.so');

    _new = _lib.lookupFunction<ghostty_terminal_new_C, ghostty_terminal_new_Dart>(
        'ghostty_terminal_new');
    _free = _lib.lookupFunction<ghostty_terminal_free_C, ghostty_terminal_free_Dart>(
        'ghostty_terminal_free');
    _resize = _lib.lookupFunction<ghostty_terminal_resize_C, ghostty_terminal_resize_Dart>(
        'ghostty_terminal_resize');
    _reset = _lib.lookupFunction<ghostty_terminal_reset_C, ghostty_terminal_reset_Dart>(
        'ghostty_terminal_reset');
    _feed = _lib.lookupFunction<ghostty_terminal_feed_C, ghostty_terminal_feed_Dart>(
        'ghostty_terminal_feed');
    _cols = _lib.lookupFunction<ghostty_terminal_uint16_C, ghostty_terminal_uint16_Dart>(
        'ghostty_terminal_cols');
    _rows = _lib.lookupFunction<ghostty_terminal_uint16_C, ghostty_terminal_uint16_Dart>(
        'ghostty_terminal_rows');
    _cursorCol = _lib.lookupFunction<ghostty_terminal_uint16_C, ghostty_terminal_uint16_Dart>(
        'ghostty_terminal_cursor_col');
    _cursorRow = _lib.lookupFunction<ghostty_terminal_uint16_C, ghostty_terminal_uint16_Dart>(
        'ghostty_terminal_cursor_row');
    _cursorStyle = _lib.lookupFunction<ghostty_terminal_uint8_C, ghostty_terminal_uint8_Dart>(
        'ghostty_terminal_cursor_style');
    _cursorVisible = _lib.lookupFunction<ghostty_terminal_bool_C, ghostty_terminal_bool_Dart>(
        'ghostty_terminal_cursor_visible');
    _cursorBlinking = _lib.lookupFunction<ghostty_terminal_bool_C, ghostty_terminal_bool_Dart>(
        'ghostty_terminal_cursor_blinking');
    _cellAt = _lib.lookupFunction<ghostty_terminal_cell_at_C, ghostty_terminal_cell_at_Dart>(
        'ghostty_terminal_cell_at');
    _readScreen = _lib.lookupFunction<ghostty_terminal_read_screen_C, ghostty_terminal_read_screen_Dart>(
        'ghostty_terminal_read_screen');
    _cellGrapheme = _lib.lookupFunction<ghostty_terminal_cell_grapheme_C, ghostty_terminal_cell_grapheme_Dart>(
        'ghostty_terminal_cell_grapheme');
    _rowAt = _lib.lookupFunction<ghostty_terminal_row_at_C, ghostty_terminal_row_at_Dart>(
        'ghostty_terminal_row_at');
    _isDirty = _lib.lookupFunction<ghostty_terminal_bool_C, ghostty_terminal_bool_Dart>(
        'ghostty_terminal_is_dirty');
    _rowIsDirty = _lib.lookupFunction<ghostty_terminal_row_is_dirty_C, ghostty_terminal_row_is_dirty_Dart>(
        'ghostty_terminal_row_is_dirty');
    _clearDirty = _lib.lookupFunction<ghostty_terminal_clear_dirty_C, ghostty_terminal_clear_dirty_Dart>(
        'ghostty_terminal_clear_dirty');
    _scrollbackLen = _lib.lookupFunction<ghostty_terminal_scrollback_len_C, ghostty_terminal_scrollback_len_Dart>(
        'ghostty_terminal_scrollback_len');
    _scrollViewport = _lib.lookupFunction<ghostty_terminal_scroll_viewport_C, ghostty_terminal_scroll_viewport_Dart>(
        'ghostty_terminal_scroll_viewport');
    _viewportIsScrolled = _lib.lookupFunction<ghostty_terminal_bool_C, ghostty_terminal_bool_Dart>(
        'ghostty_terminal_viewport_is_scrolled');
    _scrollToBottom = _lib.lookupFunction<ghostty_terminal_scroll_to_bottom_C, ghostty_terminal_scroll_to_bottom_Dart>(
        'ghostty_terminal_scroll_to_bottom');
    _readScrollbackRow = _lib.lookupFunction<ghostty_terminal_read_scrollback_row_C, ghostty_terminal_read_scrollback_row_Dart>(
        'ghostty_terminal_read_scrollback_row');
    _getSelection = _lib.lookupFunction<ghostty_terminal_get_selection_C, ghostty_terminal_get_selection_Dart>(
        'ghostty_terminal_get_selection');
    _selectStart = _lib.lookupFunction<ghostty_terminal_select_start_C, ghostty_terminal_select_start_Dart>(
        'ghostty_terminal_select_start');
    _selectUpdate = _lib.lookupFunction<ghostty_terminal_select_update_C, ghostty_terminal_select_update_Dart>(
        'ghostty_terminal_select_update');
    _selectClear = _lib.lookupFunction<ghostty_terminal_select_clear_C, ghostty_terminal_select_clear_Dart>(
        'ghostty_terminal_select_clear');
    _selectWord = _lib.lookupFunction<ghostty_terminal_select_word_C, ghostty_terminal_select_word_Dart>(
        'ghostty_terminal_select_word');
    _selectLine = _lib.lookupFunction<ghostty_terminal_select_line_C, ghostty_terminal_select_line_Dart>(
        'ghostty_terminal_select_line');
    _selectAll = _lib.lookupFunction<ghostty_terminal_select_all_C, ghostty_terminal_select_all_Dart>(
        'ghostty_terminal_select_all');
    _selectionString = _lib.lookupFunction<ghostty_terminal_selection_string_C, ghostty_terminal_selection_string_Dart>(
        'ghostty_terminal_selection_string');
    _freeString = _lib.lookupFunction<ghostty_terminal_free_string_C, ghostty_terminal_free_string_Dart>(
        'ghostty_terminal_free_string');
    _dumpScreen = _lib.lookupFunction<ghostty_terminal_string_C, ghostty_terminal_string_Dart>(
        'ghostty_terminal_dump_screen');
    _dumpScreenUnwrapped = _lib.lookupFunction<ghostty_terminal_string_C, ghostty_terminal_string_Dart>(
        'ghostty_terminal_dump_screen_unwrapped');
    _modes = _lib.lookupFunction<ghostty_terminal_modes_C, ghostty_terminal_modes_Dart>(
        'ghostty_terminal_modes');
    _pwdCopy = _lib.lookupFunction<ghostty_terminal_pwd_copy_C, ghostty_terminal_pwd_copy_Dart>(
        'ghostty_terminal_pwd_copy');
    _cursorIsAtPrompt = _lib.lookupFunction<ghostty_terminal_bool_C, ghostty_terminal_bool_Dart>(
        'ghostty_terminal_cursor_is_at_prompt');
    _defaultFg = _lib.lookupFunction<ghostty_terminal_default_color_C, ghostty_terminal_default_color_Dart>(
        'ghostty_terminal_default_fg');
    _defaultBg = _lib.lookupFunction<ghostty_terminal_default_color_C, ghostty_terminal_default_color_Dart>(
        'ghostty_terminal_default_bg');
    _cursorColor = _lib.lookupFunction<ghostty_terminal_default_color_C, ghostty_terminal_default_color_Dart>(
        'ghostty_terminal_cursor_color');

    _libLoaded = true;
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('TerminalState has been disposed');
  }

  void _allocScreenBuf(int cellCount) {
    if (_screenBufLen >= cellCount) return;
    if (_screenBuf != nullptr) calloc.free(_screenBuf);
    _screenBuf = calloc<GhosttyCell>(cellCount);
    _screenBufLen = cellCount;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Free the native terminal and all associated resources.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_handle != nullptr) {
      _free(_handle);
      _handle = nullptr;
    }
    if (_screenBuf != nullptr) {
      calloc.free(_screenBuf);
      _screenBuf = nullptr;
      _screenBufLen = 0;
    }
  }

  /// Resize the terminal to [newCols] x [newRows].
  void resize(int newCols, int newRows) {
    _checkNotDisposed();
    _resize(_handle, newCols, newRows);
    _allocScreenBuf(newCols * newRows);
  }

  /// Full terminal reset (RIS).
  void reset() {
    _checkNotDisposed();
    _reset(_handle);
  }

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  /// Feed raw PTY output bytes into the terminal state machine.
  void feed(Uint8List data) {
    _checkNotDisposed();
    if (data.isEmpty) return;

    final ptr = calloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      _feed(_handle, ptr, data.length);
    } finally {
      calloc.free(ptr);
    }
  }

  // ---------------------------------------------------------------------------
  // Dimensions & Cursor
  // ---------------------------------------------------------------------------

  int get cols {
    _checkNotDisposed();
    return _cols(_handle);
  }

  int get rows {
    _checkNotDisposed();
    return _rows(_handle);
  }

  int get cursorCol {
    _checkNotDisposed();
    return _cursorCol(_handle);
  }

  int get cursorRow {
    _checkNotDisposed();
    return _cursorRow(_handle);
  }

  /// 0=block, 1=underline, 2=bar, 3=block_hollow
  int get cursorStyle {
    _checkNotDisposed();
    return _cursorStyle(_handle);
  }

  bool get cursorVisible {
    _checkNotDisposed();
    return _cursorVisible(_handle);
  }

  bool get cursorBlinking {
    _checkNotDisposed();
    return _cursorBlinking(_handle);
  }

  // ---------------------------------------------------------------------------
  // Cell & Screen Buffer
  // ---------------------------------------------------------------------------

  /// Read a single cell at viewport-relative coordinates.
  CellData cellAt(int col, int row) {
    _checkNotDisposed();
    final cellPtr = calloc<GhosttyCell>();
    try {
      _cellAt(_handle, col, row, cellPtr);
      return CellData.fromNative(cellPtr.ref);
    } finally {
      calloc.free(cellPtr);
    }
  }

  /// Bulk read the entire viewport into a list of [CellData].
  ///
  /// Returns cells in row-major order (row 0 col 0, row 0 col 1, ...).
  List<CellData> readScreen() {
    _checkNotDisposed();
    final c = cols;
    final r = rows;
    final total = c * r;
    _allocScreenBuf(total);

    final written = _readScreen(_handle, _screenBuf, total);
    final cells = List<CellData>.generate(written, (i) {
      return CellData.fromNative(_screenBuf[i]);
    });
    return cells;
  }

  // ---------------------------------------------------------------------------
  // Dirty Tracking
  // ---------------------------------------------------------------------------

  /// Whether anything changed since the last [clearDirty] call.
  bool get isDirty {
    _checkNotDisposed();
    return _isDirty(_handle);
  }

  /// Per-row dirty check.
  bool isRowDirty(int row) {
    _checkNotDisposed();
    return _rowIsDirty(_handle, row);
  }

  /// Clear all dirty flags. Call after rendering a frame.
  void clearDirty() {
    _checkNotDisposed();
    _clearDirty(_handle);
  }

  // ---------------------------------------------------------------------------
  // Scrollback
  // ---------------------------------------------------------------------------

  /// Total scrollback lines above current viewport.
  int get scrollbackLen {
    _checkNotDisposed();
    return _scrollbackLen(_handle);
  }

  /// Scroll viewport. Positive = up (into history), negative = down.
  void scrollViewport(int delta) {
    _checkNotDisposed();
    _scrollViewport(_handle, delta);
  }

  /// Whether the viewport is scrolled away from the bottom.
  bool get viewportIsScrolled {
    _checkNotDisposed();
    return _viewportIsScrolled(_handle);
  }

  /// Snap viewport back to the bottom.
  void scrollToBottom() {
    _checkNotDisposed();
    _scrollToBottom(_handle);
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  void selectStart(int col, int row, {bool rectangle = false}) {
    _checkNotDisposed();
    _selectStart(_handle, col, row, rectangle);
  }

  void selectUpdate(int col, int row) {
    _checkNotDisposed();
    _selectUpdate(_handle, col, row);
  }

  void selectClear() {
    _checkNotDisposed();
    _selectClear(_handle);
  }

  void selectWord(int col, int row) {
    _checkNotDisposed();
    _selectWord(_handle, col, row);
  }

  void selectLine(int row) {
    _checkNotDisposed();
    _selectLine(_handle, row);
  }

  void selectAll() {
    _checkNotDisposed();
    _selectAll(_handle);
  }

  /// Get the selected text, or null if no selection.
  String? get selectionString {
    _checkNotDisposed();
    final ptr = _selectionString(_handle);
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      _freeString(_handle, ptr);
    }
  }

  // ---------------------------------------------------------------------------
  // Text Extraction
  // ---------------------------------------------------------------------------

  /// Dump entire viewport as plain UTF-8 text.
  String dumpScreen() {
    _checkNotDisposed();
    final ptr = _dumpScreen(_handle);
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } finally {
      _freeString(_handle, ptr);
    }
  }

  // ---------------------------------------------------------------------------
  // Colors
  // ---------------------------------------------------------------------------

  /// Default foreground color.
  ({int r, int g, int b}) get defaultFg {
    _checkNotDisposed();
    final rgb = _defaultFg(_handle);
    return (r: rgb.r, g: rgb.g, b: rgb.b);
  }

  /// Default background color.
  ({int r, int g, int b}) get defaultBg {
    _checkNotDisposed();
    final rgb = _defaultBg(_handle);
    return (r: rgb.r, g: rgb.g, b: rgb.b);
  }
}
