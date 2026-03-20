/// Horizontal scrollable strip of attachment tabs shown above the modifier bar.
///
/// Displays staged attachments as compact pill-shaped tabs with thumbnails,
/// filenames, and remove buttons. Slides up when attachments are present and
/// shows an upload progress overlay during file transfer.
///
/// Usage:
///   AttachmentStrip(
///     state: attachmentState,
///     onRemove: (id) => ref.read(attachmentProvider.notifier).remove(id),
///   )
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';
import 'attachment_service.dart';

/// A horizontal row of compact attachment tabs that slides in above the
/// modifier bar when files are staged for upload.
class AttachmentStrip extends StatelessWidget {
  /// Current attachment staging state.
  final AttachmentState state;

  /// Called when the user taps the remove button on an attachment tab.
  final ValueChanged<String> onRemove;

  const AttachmentStrip({
    super.key,
    required this.state,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isVisible = state.isNotEmpty;

    return AnimatedSlide(
      offset: isVisible ? Offset.zero : const Offset(0, 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: isVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: _StripBody(state: state, onRemove: onRemove),
      ),
    );
  }
}

/// The visual container and content of the attachment strip.
///
/// Separated from [AttachmentStrip] so the animation wrapper stays lean.
class _StripBody extends StatelessWidget {
  final AttachmentState state;
  final ValueChanged<String> onRemove;

  const _StripBody({required this.state, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      height: 44,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      decoration: BoxDecoration(
        color: c.modifierBarBg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(14),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Stack(
          children: [
            // Tab list — reduced opacity when uploading.
            Opacity(
              opacity: state.isUploading ? 0.3 : 1.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: state.items.length,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final item = state.items[index];
                    return _AttachmentTab(
                      item: item,
                      onRemove: () => onRemove(item.id),
                    );
                  },
                ),
              ),
            ),

            // Upload progress overlay.
            if (state.isUploading)
              Center(
                child: _UploadProgressLabel(
                  text: state.uploadProgress ?? 'Uploading...',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing upload status label overlaid on the tab list during file transfer.
class _UploadProgressLabel extends StatefulWidget {
  final String text;

  const _UploadProgressLabel({required this.text});

  @override
  State<_UploadProgressLabel> createState() => _UploadProgressLabelState();
}

class _UploadProgressLabelState extends State<_UploadProgressLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        // Pulse opacity between 0.5 and 1.0 for a subtle glow effect.
        final glowOpacity = 0.5 + (_pulseController.value * 0.5);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: c.attachmentUploadPulse.withAlpha((glowOpacity * 80).round()),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Text(
            widget.text,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: c.attachmentStatusText,
            ),
          ),
        );
      },
    );
  }
}

/// A single attachment tab — pill-shaped with thumbnail, filename, and remove.
///
/// Layout: [thumbnail 28px] [4px] [filename ≤80px] [4px] [X 16px]
class _AttachmentTab extends StatelessWidget {
  final AttachmentItem item;
  final VoidCallback onRemove;

  const _AttachmentTab({required this.item, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      height: 36,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.keyGroupResting,
        borderRadius: BorderRadius.circular(8),
        border: item.hasError
            ? Border.all(
                color: c.attachmentTabError,
                width: 2,
              )
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Thumbnail(item: item),
          const SizedBox(width: 4),
          _Filename(name: item.filename),
          const SizedBox(width: 4),
          _RemoveButton(onTap: onRemove),
        ],
      ),
    );
  }
}

/// 28px square thumbnail — shows image bytes or a generic file icon.
class _Thumbnail extends StatelessWidget {
  final AttachmentItem item;

  const _Thumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (item.thumbnailBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          item.thumbnailBytes!,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
        ),
      );
    }

    return SizedBox(
      width: 28,
      height: 28,
      child: Icon(
        Icons.description_outlined,
        size: 18,
        color: c.textMuted,
      ),
    );
  }
}

/// Filename label constrained to ~80px with ellipsis overflow.
class _Filename extends StatelessWidget {
  final String name;

  const _Filename({required this.name});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 80),
      child: Text(
        name,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontSize: 10,
          color: c.textSecondary,
        ),
      ),
    );
  }
}

/// 16px close icon with tap handling and scale animation.
class _RemoveButton extends StatefulWidget {
  final VoidCallback onTap;

  const _RemoveButton({required this.onTap});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 80),
        // Pad the hit target to at least 24px for accessibility.
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close_rounded,
            size: 16,
            color: c.textMuted,
          ),
        ),
      ),
    );
  }
}
