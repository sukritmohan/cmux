// Hand-written FFI bindings for libghostty-vt terminal C API.
// Mirrors ghostty/include/ghostty/vt/terminal.h exactly.
//
// Can be regenerated via `dart run ffigen` once the .so is built,
// but this hand-written version is kept for bootstrap / CI where
// the native library may not be available.

// ignore_for_file: non_constant_identifier_names, camel_case_types

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Result codes (result.h)
// ---------------------------------------------------------------------------

/// GHOSTTY_SUCCESS = 0, GHOSTTY_OUT_OF_MEMORY = -1, GHOSTTY_INVALID_VALUE = -2
typedef GhosttyResult = Int32;

// ---------------------------------------------------------------------------
// Structs (terminal.h)
// ---------------------------------------------------------------------------

/// RGB color triple.
final class GhosttyRgb extends Struct {
  @Uint8()
  external int r;
  @Uint8()
  external int g;
  @Uint8()
  external int b;
}

/// Resolved cell data. All colors pre-resolved to RGB.
///
/// Flags bitfield (16-bit):
///   Bit 0:  bold
///   Bit 1:  italic
///   Bit 2:  faint/dim
///   Bit 3:  underline
///   Bit 4:  strikethrough
///   Bit 5:  inverse/reverse
///   Bit 6:  invisible
///   Bit 7:  overline
///   Bit 8:  blink
///   Bit 9:  wide
///   Bit 10: spacer_head
///   Bit 11: spacer_tail
///   Bit 12: protected
///   Bit 13: has_hyperlink
///   Bit 14-15: semantic_content
final class GhosttyCell extends Struct {
  @Uint32()
  external int codepoint;

  @Uint8()
  external int grapheme_len;

  @Uint8()
  external int fg_r;
  @Uint8()
  external int fg_g;
  @Uint8()
  external int fg_b;
  @Bool()
  external bool fg_is_default;

  @Uint8()
  external int bg_r;
  @Uint8()
  external int bg_g;
  @Uint8()
  external int bg_b;
  @Bool()
  external bool bg_is_default;

  @Uint8()
  external int ul_r;
  @Uint8()
  external int ul_g;
  @Uint8()
  external int ul_b;
  @Bool()
  external bool ul_is_default;

  /// 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed
  @Uint8()
  external int underline_style;

  @Uint16()
  external int flags;
}

/// Row metadata.
final class GhosttyRow extends Struct {
  @Bool()
  external bool wrap;
  @Bool()
  external bool wrap_continuation;
  @Bool()
  external bool dirty;

  /// 0=none, 1=prompt, 2=prompt_continuation
  @Uint8()
  external int semantic_prompt;
}

/// Terminal mode snapshot.
final class GhosttyModes extends Struct {
  @Bool()
  external bool alternate_screen;
  @Bool()
  external bool cursor_visible;
  @Bool()
  external bool cursor_blinking;
  @Bool()
  external bool bracketed_paste;
  @Bool()
  external bool focus_events;
  @Bool()
  external bool reverse_colors;
  @Bool()
  external bool wraparound;
  @Bool()
  external bool origin_mode;
  @Bool()
  external bool insert_mode;
  @Bool()
  external bool linefeed_mode;

  /// 0=none, 1=x10, 2=normal, 3=button, 4=any
  @Uint8()
  external int mouse_event;

  /// 0=x10, 1=utf8, 2=sgr, 3=urxvt, 4=sgr_pixels
  @Uint8()
  external int mouse_format;

  @Bool()
  external bool synchronized_output;
  @Bool()
  external bool grapheme_cluster;
}

/// Selection bounds (viewport-relative).
final class GhosttySelection extends Struct {
  @Uint16()
  external int start_col;
  @Uint16()
  external int start_row;
  @Uint16()
  external int end_col;
  @Uint16()
  external int end_row;
  @Bool()
  external bool rectangle;
  @Bool()
  external bool active;
}

/// Hyperlink at a cell position.
final class GhosttyHyperlink extends Struct {
  external Pointer<Utf8> uri;
}

// ---------------------------------------------------------------------------
// Allocator (allocator.h) — opaque, passed as NULL for default
// ---------------------------------------------------------------------------

final class GhosttyAllocatorVtable extends Opaque {}

final class GhosttyAllocator extends Struct {
  external Pointer<Void> ctx;
  external Pointer<GhosttyAllocatorVtable> vtable;
}

// ---------------------------------------------------------------------------
// Native function typedefs
// ---------------------------------------------------------------------------

// 1. Lifecycle
typedef ghostty_terminal_new_C = Int32 Function(
    Pointer<GhosttyAllocator> alloc, Uint16 cols, Uint16 rows, Pointer<Pointer<Void>> out);
typedef ghostty_terminal_new_Dart = int Function(
    Pointer<GhosttyAllocator> alloc, int cols, int rows, Pointer<Pointer<Void>> out);

typedef ghostty_terminal_free_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_free_Dart = void Function(Pointer<Void> t);

typedef ghostty_terminal_resize_C = Int32 Function(Pointer<Void> t, Uint16 cols, Uint16 rows);
typedef ghostty_terminal_resize_Dart = int Function(Pointer<Void> t, int cols, int rows);

typedef ghostty_terminal_reset_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_reset_Dart = void Function(Pointer<Void> t);

// 2. Input
typedef ghostty_terminal_feed_C = Int32 Function(
    Pointer<Void> t, Pointer<Uint8> data, IntPtr len);
typedef ghostty_terminal_feed_Dart = int Function(
    Pointer<Void> t, Pointer<Uint8> data, int len);

// 3. Dimensions & Cursor
typedef ghostty_terminal_uint16_C = Uint16 Function(Pointer<Void> t);
typedef ghostty_terminal_uint16_Dart = int Function(Pointer<Void> t);

typedef ghostty_terminal_uint8_C = Uint8 Function(Pointer<Void> t);
typedef ghostty_terminal_uint8_Dart = int Function(Pointer<Void> t);

typedef ghostty_terminal_bool_C = Bool Function(Pointer<Void> t);
typedef ghostty_terminal_bool_Dart = bool Function(Pointer<Void> t);

// 4. Cell & Screen
typedef ghostty_terminal_cell_at_C = Int32 Function(
    Pointer<Void> t, Uint16 col, Uint16 row, Pointer<GhosttyCell> out);
typedef ghostty_terminal_cell_at_Dart = int Function(
    Pointer<Void> t, int col, int row, Pointer<GhosttyCell> out);

typedef ghostty_terminal_read_screen_C = IntPtr Function(
    Pointer<Void> t, Pointer<GhosttyCell> buf, IntPtr buf_len);
typedef ghostty_terminal_read_screen_Dart = int Function(
    Pointer<Void> t, Pointer<GhosttyCell> buf, int buf_len);

typedef ghostty_terminal_cell_grapheme_C = IntPtr Function(
    Pointer<Void> t, Uint16 col, Uint16 row, Pointer<Uint32> out_buf, IntPtr buf_cap);
typedef ghostty_terminal_cell_grapheme_Dart = int Function(
    Pointer<Void> t, int col, int row, Pointer<Uint32> out_buf, int buf_cap);

// 5. Row metadata
typedef ghostty_terminal_row_at_C = Int32 Function(
    Pointer<Void> t, Uint16 row, Pointer<GhosttyRow> out);
typedef ghostty_terminal_row_at_Dart = int Function(
    Pointer<Void> t, int row, Pointer<GhosttyRow> out);

// 6. Dirty tracking
typedef ghostty_terminal_row_is_dirty_C = Bool Function(Pointer<Void> t, Uint16 row);
typedef ghostty_terminal_row_is_dirty_Dart = bool Function(Pointer<Void> t, int row);

// 7. Scrollback
typedef ghostty_terminal_scrollback_len_C = IntPtr Function(Pointer<Void> t);
typedef ghostty_terminal_scrollback_len_Dart = int Function(Pointer<Void> t);

typedef ghostty_terminal_scroll_viewport_C = Void Function(Pointer<Void> t, Int32 delta);
typedef ghostty_terminal_scroll_viewport_Dart = void Function(Pointer<Void> t, int delta);

typedef ghostty_terminal_read_scrollback_row_C = IntPtr Function(
    Pointer<Void> t, IntPtr offset, Pointer<GhosttyCell> buf, IntPtr buf_len);
typedef ghostty_terminal_read_scrollback_row_Dart = int Function(
    Pointer<Void> t, int offset, Pointer<GhosttyCell> buf, int buf_len);

// 8. Selection
typedef ghostty_terminal_get_selection_C = Bool Function(
    Pointer<Void> t, Pointer<GhosttySelection> out);
typedef ghostty_terminal_get_selection_Dart = bool Function(
    Pointer<Void> t, Pointer<GhosttySelection> out);

typedef ghostty_terminal_select_start_C = Void Function(
    Pointer<Void> t, Uint16 col, Uint16 row, Bool rectangle);
typedef ghostty_terminal_select_start_Dart = void Function(
    Pointer<Void> t, int col, int row, bool rectangle);

typedef ghostty_terminal_select_update_C = Void Function(Pointer<Void> t, Uint16 col, Uint16 row);
typedef ghostty_terminal_select_update_Dart = void Function(Pointer<Void> t, int col, int row);

typedef ghostty_terminal_select_word_C = Void Function(Pointer<Void> t, Uint16 col, Uint16 row);
typedef ghostty_terminal_select_word_Dart = void Function(Pointer<Void> t, int col, int row);

typedef ghostty_terminal_select_line_C = Void Function(Pointer<Void> t, Uint16 row);
typedef ghostty_terminal_select_line_Dart = void Function(Pointer<Void> t, int row);

// 9. Text extraction — returns char*, must free
typedef ghostty_terminal_string_C = Pointer<Utf8> Function(Pointer<Void> t);
typedef ghostty_terminal_string_Dart = Pointer<Utf8> Function(Pointer<Void> t);

typedef ghostty_terminal_free_string_C = Void Function(Pointer<Void> t, Pointer<Utf8> str);
typedef ghostty_terminal_free_string_Dart = void Function(Pointer<Void> t, Pointer<Utf8> str);

typedef ghostty_terminal_selection_string_C = Pointer<Utf8> Function(Pointer<Void> t);
typedef ghostty_terminal_selection_string_Dart = Pointer<Utf8> Function(Pointer<Void> t);

// 10. Modes
typedef ghostty_terminal_modes_C = Void Function(Pointer<Void> t, Pointer<GhosttyModes> out);
typedef ghostty_terminal_modes_Dart = void Function(Pointer<Void> t, Pointer<GhosttyModes> out);

// 11. PWD
typedef ghostty_terminal_pwd_copy_C = IntPtr Function(
    Pointer<Void> t, Pointer<Utf8> buf, IntPtr buf_cap);
typedef ghostty_terminal_pwd_copy_Dart = int Function(
    Pointer<Void> t, Pointer<Utf8> buf, int buf_cap);

// 12. Hyperlink
typedef ghostty_terminal_hyperlink_at_C = Bool Function(
    Pointer<Void> t, Uint16 col, Uint16 row, Pointer<GhosttyHyperlink> out);
typedef ghostty_terminal_hyperlink_at_Dart = bool Function(
    Pointer<Void> t, int col, int row, Pointer<GhosttyHyperlink> out);

// 13. Palette
typedef ghostty_terminal_palette_color_C = GhosttyRgb Function(Pointer<Void> t, Uint8 index);
typedef ghostty_terminal_palette_color_Dart = GhosttyRgb Function(Pointer<Void> t, int index);

typedef ghostty_terminal_set_palette_color_C = Void Function(
    Pointer<Void> t, Uint8 index, GhosttyRgb color);
typedef ghostty_terminal_set_palette_color_Dart = void Function(
    Pointer<Void> t, int index, GhosttyRgb color);

typedef ghostty_terminal_default_color_C = GhosttyRgb Function(Pointer<Void> t);
typedef ghostty_terminal_default_color_Dart = GhosttyRgb Function(Pointer<Void> t);

typedef ghostty_terminal_clear_dirty_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_clear_dirty_Dart = void Function(Pointer<Void> t);

typedef ghostty_terminal_scroll_to_bottom_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_scroll_to_bottom_Dart = void Function(Pointer<Void> t);

typedef ghostty_terminal_select_clear_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_select_clear_Dart = void Function(Pointer<Void> t);

typedef ghostty_terminal_select_all_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_select_all_Dart = void Function(Pointer<Void> t);

typedef ghostty_terminal_reset_palette_C = Void Function(Pointer<Void> t);
typedef ghostty_terminal_reset_palette_Dart = void Function(Pointer<Void> t);
