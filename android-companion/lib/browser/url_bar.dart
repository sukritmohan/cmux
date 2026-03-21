/// Functional URL bar for the browser pane.
///
/// Row layout: back/forward nav buttons + URL field with styled scheme/host/path
/// + reload/stop button. Tap the URL field to enter edit mode.
/// A thin progress indicator appears at the bottom during page loads.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import 'url_rewriter.dart';

class UrlBar extends StatefulWidget {
  /// Current URL to display (null for new/empty tabs).
  final String? url;

  /// Whether a page is currently loading.
  final bool isLoading;

  /// Whether the back button should be enabled.
  final bool canGoBack;

  /// Whether the forward button should be enabled.
  final bool canGoForward;

  /// Called when the user taps the back button.
  final VoidCallback? onBack;

  /// Called when the user taps the forward button.
  final VoidCallback? onForward;

  /// Called when the user taps the reload/stop button.
  final VoidCallback? onReload;

  /// Called when the user submits a URL in edit mode.
  final ValueChanged<String>? onNavigate;

  const UrlBar({
    super.key,
    this.url,
    this.isLoading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.onBack,
    this.onForward,
    this.onReload,
    this.onNavigate,
  });

  @override
  State<UrlBar> createState() => _UrlBarState();
}

class _UrlBarState extends State<UrlBar> {
  bool _isEditing = false;
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.url ?? '');
  }

  @override
  void didUpdateWidget(UrlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update text controller when URL changes externally (not during editing)
    if (!_isEditing && widget.url != oldWidget.url) {
      _textController.text = widget.url ?? '';
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _textController.text = widget.url ?? '';
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    });
  }

  void _submitUrl() {
    final url = _textController.text.trim();
    setState(() => _isEditing = false);
    if (url.isNotEmpty) {
      // Auto-prepend https:// if no scheme provided
      final withScheme = url.contains('://') ? url : 'https://$url';
      widget.onNavigate?.call(withScheme);
    }
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _textController.text = widget.url ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: c.bgPrimary,
            border: Border(
              bottom: BorderSide(color: c.border),
            ),
          ),
          child: Row(
            children: [
              // Back button
              _NavButton(
                icon: Icons.arrow_back_ios_new,
                enabled: widget.canGoBack,
                onTap: widget.onBack,
              ),
              const SizedBox(width: 8),

              // Forward button
              _NavButton(
                icon: Icons.arrow_forward_ios,
                enabled: widget.canGoForward,
                onTap: widget.onForward,
              ),
              const SizedBox(width: 8),

              // URL field
              Expanded(
                child: _isEditing
                    ? _buildEditField(c)
                    : _buildDisplayField(c),
              ),

              const SizedBox(width: 8),

              // Reload / Stop button
              _NavButton(
                icon: widget.isLoading ? Icons.close : Icons.refresh,
                enabled: widget.url != null,
                onTap: widget.onReload,
              ),
            ],
          ),
        ),
        // Loading progress indicator
        if (widget.isLoading)
          LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation<Color>(c.browserColor),
          ),
      ],
    );
  }

  Widget _buildDisplayField(AppColorScheme c) {
    if (widget.url == null || widget.url!.isEmpty) {
      return GestureDetector(
        onTap: _enterEditMode,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: c.bgSurface,
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            'Search or enter URL',
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        ),
      );
    }

    final parsed = parseDisplayUrl(widget.url!);

    return GestureDetector(
      onTap: _enterEditMode,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: c.bgSurface,
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
        ),
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            children: [
              // Scheme at 40% opacity
              if (parsed.scheme.isNotEmpty)
                TextSpan(
                  text: parsed.scheme,
                  style: TextStyle(
                    fontSize: 12,
                    color: c.textPrimary.withAlpha(102),
                  ),
                ),
              // Host at full opacity
              TextSpan(
                text: parsed.host,
                style: TextStyle(
                  fontSize: 12,
                  color: c.textPrimary,
                ),
              ),
              // Path in secondary color
              if (parsed.path.isNotEmpty)
                TextSpan(
                  text: parsed.path,
                  style: TextStyle(
                    fontSize: 12,
                    color: c.textSecondary,
                  ),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildEditField(AppColorScheme c) {
    return SizedBox(
      height: 30,
      child: TextField(
        controller: _textController,
        autofocus: true,
        style: TextStyle(fontSize: 12, color: c.textPrimary),
        decoration: InputDecoration(
          filled: true,
          fillColor: c.bgSurface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            borderSide: BorderSide(color: c.browserColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            borderSide: BorderSide(color: c.browserColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            borderSide: BorderSide(color: c.browserColor, width: 1.5),
          ),
          isDense: true,
        ),
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _submitUrl(),
        onTapOutside: (_) => _cancelEdit(),
      ),
    );
  }
}

/// 28x28 navigation button (back/forward/reload).
class _NavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _NavButton({
    required this.icon,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(
          icon,
          size: 14,
          color: enabled ? c.textSecondary : c.textMuted,
        ),
      ),
    );
  }
}
