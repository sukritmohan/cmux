/// Clipboard history data model and Riverpod provider.
///
/// Maintains a per-connection list of copied text entries with support for
/// starring, reordering, search filtering, and persistent storage via
/// SharedPreferences. The history is capped at 100 items; when the cap is
/// reached, the oldest unstarred items are evicted first.
///
/// Usage:
///   // Load persisted history after the connection key is known.
///   await ref.read(clipboardHistoryProvider.notifier).load();
///
///   // Add a new entry (deduplicates automatically).
///   ref.read(clipboardHistoryProvider.notifier).add('some text');
///
///   // Read filtered items for display.
///   final state = ref.watch(clipboardHistoryProvider);
///   final starred = state.starredItems;
///   final recent  = state.recentItems;
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// ClipboardItem
// ---------------------------------------------------------------------------

/// A single entry in the clipboard history.
class ClipboardItem {
  /// Unique identifier. Uses microseconds-since-epoch as a simple unique ID
  /// since the `uuid` package is not available in this project.
  final String id;

  /// The copied text content.
  final String text;

  /// When this item was copied (or moved to the top of the list on re-copy).
  final DateTime copiedAt;

  /// Whether the user has starred (pinned) this item.
  final bool isStarred;

  const ClipboardItem({
    required this.id,
    required this.text,
    required this.copiedAt,
    this.isStarred = false,
  });

  /// Deserialise from a JSON map stored in SharedPreferences.
  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    return ClipboardItem(
      id: json['id'] as String,
      text: json['text'] as String,
      copiedAt: DateTime.parse(json['copiedAt'] as String),
      isStarred: json['isStarred'] as bool? ?? false,
    );
  }

  /// Serialise to a JSON map for SharedPreferences storage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'copiedAt': copiedAt.toIso8601String(),
        'isStarred': isStarred,
      };

  ClipboardItem copyWith({
    String? id,
    String? text,
    DateTime? copiedAt,
    bool? isStarred,
  }) {
    return ClipboardItem(
      id: id ?? this.id,
      text: text ?? this.text,
      copiedAt: copiedAt ?? this.copiedAt,
      isStarred: isStarred ?? this.isStarred,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ClipboardItem && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

// ---------------------------------------------------------------------------
// ClipboardHistoryState
// ---------------------------------------------------------------------------

/// Immutable snapshot of the clipboard history, including the active search
/// query.
///
/// Items are stored with the most-recently-copied entry first (index 0).
class ClipboardHistoryState {
  /// All items in recency order (index 0 = most recent).
  final List<ClipboardItem> items;

  /// The active search query string. Empty string means no filter.
  final String searchQuery;

  const ClipboardHistoryState({
    this.items = const [],
    this.searchQuery = '',
  });

  // -------------------------------------------------------------------------
  // Computed getters
  // -------------------------------------------------------------------------

  /// The most recently copied item, or null when the history is empty.
  ClipboardItem? get latestItem => items.isEmpty ? null : items.first;

  /// All starred items, excluding the latest (which is shown in its own
  /// section at the top of the UI).
  List<ClipboardItem> get starredItems {
    final latest = latestItem;
    return items
        .where((item) => item.isStarred && item != latest)
        .toList();
  }

  /// All unstarred items, excluding the latest.
  List<ClipboardItem> get recentItems {
    final latest = latestItem;
    return items
        .where((item) => !item.isStarred && item != latest)
        .toList();
  }

  /// Whether the history contains any items.
  bool get isNotEmpty => items.isNotEmpty;

  // -------------------------------------------------------------------------
  // Filtered views
  // -------------------------------------------------------------------------

  /// Returns a filtered state where each section (latest / starred / recent)
  /// is narrowed to items whose text contains [query] (case-insensitive).
  ///
  /// The returned object carries the same [searchQuery] so consumers can
  /// detect whether filtering is active.
  ClipboardHistoryState filteredItems(String query) {
    if (query.isEmpty) return this;
    final lower = query.toLowerCase();
    final filtered = items
        .where((item) => item.text.toLowerCase().contains(lower))
        .toList();
    return ClipboardHistoryState(items: filtered, searchQuery: query);
  }

  ClipboardHistoryState copyWith({
    List<ClipboardItem>? items,
    String? searchQuery,
  }) {
    return ClipboardHistoryState(
      items: items ?? this.items,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }
}

// ---------------------------------------------------------------------------
// ClipboardHistoryNotifier
// ---------------------------------------------------------------------------

/// Maximum number of clipboard entries retained before evicting stale items.
const _kMaxClipboardItems = 100;

/// StateNotifier that manages [ClipboardHistoryState] with SharedPreferences
/// persistence.
///
/// Persistence key is scoped to [connectionKey] so each paired Mac host
/// maintains its own independent clipboard history.
class ClipboardHistoryNotifier extends StateNotifier<ClipboardHistoryState> {
  /// Connection-scoped key used to namespace the SharedPreferences entry.
  final String connectionKey;

  ClipboardHistoryNotifier({required this.connectionKey})
      : super(const ClipboardHistoryState());

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Add [text] to the top of the history.
  ///
  /// If the same text already exists, the existing entry is moved to the top
  /// and its timestamp is refreshed; its starred status is preserved. When the
  /// list would exceed [_kMaxClipboardItems] after adding, the oldest
  /// unstarred items (excluding the new entry) are evicted.
  void add(String text) {
    if (text.isEmpty) return;

    final existingIndex =
        state.items.indexWhere((item) => item.text == text);

    ClipboardItem newItem;
    List<ClipboardItem> updated;

    if (existingIndex != -1) {
      // Move the existing entry to the top, refreshing its timestamp while
      // preserving its starred status.
      final existing = state.items[existingIndex];
      newItem = existing.copyWith(
        copiedAt: DateTime.now(),
      );
      updated = [
        newItem,
        ...state.items.where((item) => item.text != text),
      ];
    } else {
      newItem = ClipboardItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: text,
        copiedAt: DateTime.now(),
        isStarred: false,
      );
      updated = [newItem, ...state.items];
    }

    // Enforce the item cap by evicting the oldest unstarred items (never
    // evict starred items, and never evict the entry just added).
    if (updated.length > _kMaxClipboardItems) {
      updated = _evictOldestUnstarred(updated, newItem.id);
    }

    state = state.copyWith(items: updated);
    _save();
  }

  /// Toggle the starred status of the item with [id].
  void toggleStar(String id) {
    final updated = state.items.map((item) {
      if (item.id != id) return item;
      return item.copyWith(isStarred: !item.isStarred);
    }).toList();

    state = state.copyWith(items: updated);
    _save();
  }

  /// Reorder a starred item within the starred section.
  ///
  /// [newIndex] is relative to the starred-items list (excluding the latest
  /// item and unstarred items). The item's position in the full [items] list
  /// is updated accordingly.
  void reorderStarred(String id, int newIndex) {
    final latest = state.latestItem;
    // Starred items in their current order, without the latest item.
    final starred = state.items
        .where((item) => item.isStarred && item != latest)
        .toList();

    final movingIndex = starred.indexWhere((item) => item.id == id);
    if (movingIndex == -1) return;

    // Clamp newIndex to valid range.
    final clampedIndex = newIndex.clamp(0, starred.length - 1);
    final moving = starred.removeAt(movingIndex);
    starred.insert(clampedIndex, moving);

    // Rebuild the full list: latest first, then reordered starred, then
    // unstarred recents in their original relative order.
    final recentItems = state.items
        .where((item) => !item.isStarred && item != latest)
        .toList();

    final rebuilt = [
      ?latest,
      ...starred,
      ...recentItems,
    ];

    state = state.copyWith(items: rebuilt);
    _save();
  }

  /// Update the active search query. Consumers should use
  /// [ClipboardHistoryState.filteredItems] to derive the filtered view.
  void search(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Clear the active search query.
  void clearSearch() {
    state = state.copyWith(searchQuery: '');
  }

  /// Load persisted history from SharedPreferences.
  ///
  /// Call this imperatively once the [connectionKey] is known (e.g., after
  /// pairing). Does nothing if no persisted data is found.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;

      final decoded = jsonDecode(raw);
      if (decoded is! List) return;

      final items = decoded
          .cast<Map<String, dynamic>>()
          .map(ClipboardItem.fromJson)
          .toList();

      state = state.copyWith(items: items);
    } catch (_) {
      // Corrupt or missing data — start with empty history.
    }
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// SharedPreferences key scoped to [connectionKey].
  String get _prefsKey => 'clipboard_history_$connectionKey';

  /// Persist the current item list to SharedPreferences.
  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        state.items.map((item) => item.toJson()).toList(),
      );
      await prefs.setString(_prefsKey, encoded);
    } catch (_) {
      // Write failures are non-fatal — the in-memory state remains correct.
    }
  }

  /// Remove the oldest unstarred items from [items] until the list fits
  /// within [_kMaxClipboardItems]. The item with [protectedId] is never
  /// evicted (it was just added).
  List<ClipboardItem> _evictOldestUnstarred(
    List<ClipboardItem> items,
    String protectedId,
  ) {
    final mutable = List<ClipboardItem>.from(items);

    // Collect indices of eviction candidates: unstarred, not the newly added.
    // The list is in recency order so the last matching indices are oldest.
    final candidateIndices = <int>[];
    for (var i = 0; i < mutable.length; i++) {
      final item = mutable[i];
      if (!item.isStarred && item.id != protectedId) {
        candidateIndices.add(i);
      }
    }

    // Evict from the end (oldest) first.
    var excess = mutable.length - _kMaxClipboardItems;
    for (var i = candidateIndices.length - 1;
        i >= 0 && excess > 0;
        i--, excess--) {
      mutable.removeAt(candidateIndices[i]);
    }

    return mutable;
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Global Riverpod provider for clipboard history.
///
/// The default [connectionKey] is `'default'`. Override it by creating a
/// [ProviderScope] override or a family variant when per-connection isolation
/// is required.
final clipboardHistoryProvider =
    StateNotifierProvider<ClipboardHistoryNotifier, ClipboardHistoryState>(
  (ref) => ClipboardHistoryNotifier(connectionKey: 'default'),
);
