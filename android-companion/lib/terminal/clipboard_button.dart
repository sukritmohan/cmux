/// Clipboard button and history bottom sheet for the modifier bar.
///
/// [ClipboardButton] renders a small paste icon with an amber badge dot when
/// the clipboard history is non-empty. Tapping it invokes the parent-provided
/// [onTap] callback which is expected to show the [ClipboardHistorySheet] via
/// [showModalBottomSheet].
///
/// [ClipboardHistorySheet] displays the clipboard history organised into
/// Latest / Starred / Recent sections, with a search bar and star-toggle
/// per item. Tapping an item calls [onPaste] with the item text and dismisses
/// the sheet.
///
/// Color tokens are sourced from [AppColors.of(context)] so both widgets adapt
/// to dark and light themes automatically.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';
import 'clipboard_history.dart';

// ---------------------------------------------------------------------------
// ClipboardButton
// ---------------------------------------------------------------------------

/// A 36px circular paste icon button with an optional amber badge dot.
///
/// Inputs:
///   [historyState] — current clipboard history snapshot, used to decide
///     whether the badge is visible and for the semantics item count.
///   [onTap] — callback invoked when the button is tapped (parent handles
///     showing the bottom sheet).
///
/// The badge (7px amber dot) appears in the top-right corner only when
/// [historyState.isNotEmpty] is true.
class ClipboardButton extends StatelessWidget {
  final ClipboardHistoryState historyState;
  final VoidCallback onTap;

  /// Button diameter in logical pixels. Defaults to 36.
  final double size;

  const ClipboardButton({
    super.key,
    required this.historyState,
    required this.onTap,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final itemCount = historyState.items.length;

    return Semantics(
      label: 'Clipboard, $itemCount items',
      button: true,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Circular background with icon.
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.keyGroupResting,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.content_paste_rounded,
                  size: size * 0.44,
                  color: c.keyGroupText,
                ),
              ),

              // Amber badge dot — only when history is non-empty.
              if (historyState.isNotEmpty)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.clipboardBadge,
                      border: Border.all(
                        color: c.clipboardBadgeBorder,
                        width: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ClipboardHistorySheet
// ---------------------------------------------------------------------------

/// Bottom sheet that displays the full clipboard history with search, starring,
/// and tap-to-paste.
///
/// Inputs:
///   [notifier] — the [ClipboardHistoryNotifier] used to toggle stars and
///     update the search query.
///   [historyState] — the current [ClipboardHistoryState] snapshot.
///   [onPaste] — called with the item text when the user taps an item body.
///     The caller is responsible for wrapping the text in bracketed paste mode.
///
/// Show this widget via:
/// ```dart
/// showModalBottomSheet(
///   context: context,
///   backgroundColor: Colors.transparent,
///   isScrollControlled: true,
///   builder: (_) => ClipboardHistorySheet(...),
/// );
/// ```
class ClipboardHistorySheet extends StatefulWidget {
  final ClipboardHistoryNotifier notifier;
  final ClipboardHistoryState historyState;
  final ValueChanged<String> onPaste;

  const ClipboardHistorySheet({
    super.key,
    required this.notifier,
    required this.historyState,
    required this.onPaste,
  });

  @override
  State<ClipboardHistorySheet> createState() => _ClipboardHistorySheetState();
}

class _ClipboardHistorySheetState extends State<ClipboardHistorySheet> {
  final _searchController = TextEditingController();
  Timer? _debounceTimer;

  /// Local search query used to filter the displayed list.
  String _searchQuery = '';

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 200), () {
      setState(() => _searchQuery = value);
      widget.notifier.search(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // Apply search filter when a query is active.
    final displayState = _searchQuery.isEmpty
        ? widget.historyState
        : widget.historyState.filteredItems(_searchQuery);

    final latestItem = displayState.latestItem;
    final starredItems = displayState.starredItems;
    final recentItems = displayState.recentItems;

    final hasItems = widget.historyState.items.isNotEmpty;
    final hasResults = displayState.items.isNotEmpty;
    final isSearchActive = _searchQuery.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: c.sheetBg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppColors.radiusXl),
        ),
      ),
      // Constrain height to 70% of the screen so the sheet doesn't cover
      // everything. DraggableScrollableSheet could be used for a more
      // sophisticated experience but is overkill for this spec.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle pill.
          _buildHandle(c),

          // Header row.
          _buildHeader(c),

          const SizedBox(height: 8),

          // Search bar.
          _buildSearchBar(c),

          const SizedBox(height: 8),

          // Scrollable content area.
          Flexible(
            child: _buildContent(
              c,
              latestItem: latestItem,
              starredItems: starredItems,
              recentItems: recentItems,
              hasItems: hasItems,
              hasResults: hasResults,
              isSearchActive: isSearchActive,
            ),
          ),

          // Footer hint.
          _buildFooter(c),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Sub-builders
  // -------------------------------------------------------------------------

  /// Drag handle pill centered at the top of the sheet.
  Widget _buildHandle(AppColorScheme c) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: c.sheetHandle,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  /// Header: "Clipboard" title + item count.
  Widget _buildHeader(AppColorScheme c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          Text(
            'Clipboard',
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
          const Spacer(),
          Text(
            '${widget.historyState.items.length} items',
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 10,
              color: c.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  /// Search text field with debounced query dispatch.
  Widget _buildSearchBar(AppColorScheme c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 11,
          color: c.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: 'Search clipboard...',
          hintStyle: TextStyle(
            fontFamily: 'JetBrains Mono',
            fontSize: 11,
            color: c.textMuted,
          ),
          filled: true,
          fillColor: c.sheetSearch,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            borderSide: BorderSide(color: c.sheetSearchBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            borderSide: BorderSide(color: c.sheetSearchBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            borderSide: BorderSide(color: c.sheetSearchBorder),
          ),
          isDense: true,
        ),
      ),
    );
  }

  /// Main scrollable list with Latest / Starred / Recent sections, or an
  /// empty / no-results state.
  Widget _buildContent(
    AppColorScheme c, {
    required ClipboardItem? latestItem,
    required List<ClipboardItem> starredItems,
    required List<ClipboardItem> recentItems,
    required bool hasItems,
    required bool hasResults,
    required bool isSearchActive,
  }) {
    // Empty state — no items at all.
    if (!hasItems) {
      return _buildEmptyState(c);
    }

    // No results for current search query.
    if (!hasResults && isSearchActive) {
      return _buildNoResults(c);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Latest section --
          if (latestItem != null) ...[
            _buildSectionHeader(c, 'Latest'),
            _buildLatestItem(c, latestItem),
          ],

          // -- Starred section --
          if (starredItems.isNotEmpty) ...[
            _buildSectionHeader(c, 'Starred'),
            for (final item in starredItems)
              _ClipboardListItem(
                item: item,
                isStarred: true,
                onTap: () => _pasteAndDismiss(item.text),
                onToggleStar: () => widget.notifier.toggleStar(item.id),
              ),
          ],

          // -- Recent section --
          if (recentItems.isNotEmpty) ...[
            _buildSectionHeader(c, 'Recent'),
            for (final item in recentItems)
              _ClipboardListItem(
                item: item,
                isStarred: false,
                onTap: () => _pasteAndDismiss(item.text),
                onToggleStar: () => widget.notifier.toggleStar(item.id),
              ),
          ],
        ],
      ),
    );
  }

  /// Section header: uppercase label.
  Widget _buildSectionHeader(AppColorScheme c, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: c.textMuted,
        ),
      ),
    );
  }

  /// The latest item card with a blue left border and "just copied" badge.
  Widget _buildLatestItem(AppColorScheme c, ClipboardItem item) {
    return GestureDetector(
      onTap: () => _pasteAndDismiss(item.text),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: c.clipboardLatestBorder, width: 2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // "just copied" badge.
            Text(
              'JUST COPIED',
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 7,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: c.clipboardLatestBadge,
              ),
            ),
            const SizedBox(height: 2),
            // Item text.
            Text(
              item.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 12,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            // Metadata line.
            Text(
              '${_relativeTime(item.copiedAt)} · ${item.text.length} chars',
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 9,
                color: c.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Centered empty state shown when the clipboard history has no items.
  Widget _buildEmptyState(AppColorScheme c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.content_paste_rounded,
              size: 24,
              color: c.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              'No clipboard history',
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 12,
                color: c.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Copy text from the terminal to see it here',
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 10,
                color: c.textMuted.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Centered "No matches" shown when search is active but nothing matched.
  Widget _buildNoResults(AppColorScheme c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(
          'No matches',
          style: TextStyle(
            fontFamily: 'JetBrains Mono',
            fontSize: 12,
            color: c.textMuted,
          ),
        ),
      ),
    );
  }

  /// Footer hint with a top border, respecting bottom safe area (Android nav bar).
  Widget _buildFooter(AppColorScheme c) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(0, 10, 0, 10 + bottomPadding),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: c.border),
        ),
      ),
      child: Text(
        'tap item to paste into terminal',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 9,
          color: c.textMuted,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Fires the paste callback and dismisses the bottom sheet.
  void _pasteAndDismiss(String text) {
    widget.onPaste(text);
    Navigator.pop(context);
  }
}

// ---------------------------------------------------------------------------
// _ClipboardListItem (private)
// ---------------------------------------------------------------------------

/// A single row in the starred or recent section of the clipboard history
/// sheet.
///
/// Tapping the body fires [onTap] (paste). Tapping the trailing star icon
/// fires [onToggleStar].
class _ClipboardListItem extends StatelessWidget {
  final ClipboardItem item;
  final bool isStarred;
  final VoidCallback onTap;
  final VoidCallback onToggleStar;

  const _ClipboardListItem({
    required this.item,
    required this.isStarred,
    required this.onTap,
    required this.onToggleStar,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            // Text content + metadata.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 12,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_relativeTime(item.copiedAt)} · ${item.text.length} chars',
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 9,
                      color: c.textMuted,
                    ),
                  ),
                ],
              ),
            ),

            // Star toggle button.
            GestureDetector(
              onTap: onToggleStar,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Center(
                  child: Icon(
                    isStarred ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 14,
                    color: isStarred ? c.clipboardBadge : c.border,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Relative time helper
// ---------------------------------------------------------------------------

/// Returns a short, human-readable relative time string for [dt].
///
/// Examples: "just now", "12s ago", "5m ago", "3h ago", "2d ago".
String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
