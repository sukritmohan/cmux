/// Attachment (+) button for the modifier bar tools grid.
///
/// Renders a 36px circular button with a (+) icon. Tapping opens a spring-
/// animated action sheet popover with Photos and Files options. Long-pressing
/// clears all staged attachments.
///
/// Photos option uses ImagePicker to pick multiple images from the gallery.
/// Files option uses FilePicker to pick multiple files of any type.
/// Both validate file size (50MB max) and generate thumbnails for images.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../app/colors.dart';
import 'attachment_service.dart';

// ---------------------------------------------------------------------------
// MIME type detection
// ---------------------------------------------------------------------------

/// Maps a file extension to its MIME type.
///
/// Covers common image, video, document, and archive formats.
/// Returns "application/octet-stream" for unrecognized extensions.
String mimeTypeFromExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return 'application/octet-stream';

  final ext = filename.substring(dot + 1).toLowerCase();

  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

/// Whether a MIME type represents an image format we can generate thumbnails for.
bool _isImageMime(String mimeType) => mimeType.startsWith('image/');

// ---------------------------------------------------------------------------
// Thumbnail generation
// ---------------------------------------------------------------------------

/// Maximum thumbnail dimension (width or height) in pixels.
const _kThumbnailMaxDimension = 120;

/// Generates a small JPEG thumbnail from image bytes.
///
/// Decodes the image, scales it so the longest side is at most
/// [_kThumbnailMaxDimension] pixels, and re-encodes as JPEG.
/// Returns null if decoding or encoding fails for any reason.
Future<Uint8List?> _generateThumbnail(String filePath) async {
  try {
    final fileBytes = await File(filePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(
      fileBytes,
      targetWidth: _kThumbnailMaxDimension,
      targetHeight: _kThumbnailMaxDimension,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    codec.dispose();

    if (byteData == null) return null;
    return byteData.buffer.asUint8List();
  } catch (e) {
    debugPrint('[AttachmentButton] Thumbnail generation failed: $e');
    return null;
  }
}

// ---------------------------------------------------------------------------
// AttachmentButton
// ---------------------------------------------------------------------------

/// A 36px circular (+) button that opens an attachment action sheet.
///
/// Inputs:
///   [isDisabled] — when true, the button is grayed out and taps are ignored.
///
/// The action sheet popover appears above the button on tap, with a spring
/// animation (overshoot curve). Tapping outside or selecting an option
/// dismisses it.
///
/// Long-pressing the (+) button clears all staged attachments.
class AttachmentButton extends ConsumerStatefulWidget {
  /// When true, the button renders at reduced opacity and ignores all taps.
  final bool isDisabled;

  /// Button diameter in logical pixels. Defaults to 36.
  final double size;

  const AttachmentButton({super.key, this.isDisabled = false, this.size = 36});

  @override
  ConsumerState<AttachmentButton> createState() => _AttachmentButtonState();
}

class _AttachmentButtonState extends ConsumerState<AttachmentButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  bool _sheetOpen = false;
  late final AnimationController _sheetController;
  late final Animation<double> _sheetScale;
  late final Animation<double> _sheetOpacity;

  OverlayEntry? _overlayEntry;
  final _layerLink = LayerLink();

  final _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _sheetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 120),
    );
    _sheetScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _sheetController,
        curve: const Cubic(0.34, 1.56, 0.64, 1), // bouncy spring
        reverseCurve: Curves.easeIn,
      ),
    );
    _sheetOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _sheetController,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
    );
  }

  @override
  void dispose() {
    _removeOverlay();
    _sheetController.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
  }

  void _toggleSheet() {
    if (widget.isDisabled) return;
    HapticFeedback.lightImpact();
    if (_sheetOpen) {
      _closeSheet();
    } else {
      setState(() => _sheetOpen = true);
      _showOverlay();
      _sheetController.forward();
    }
  }

  void _closeSheet() {
    _sheetController.reverse().then((_) {
      if (mounted) {
        _removeOverlay();
        setState(() => _sheetOpen = false);
      }
    });
  }

  void _showOverlay() {
    final c = AppColors.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Full-screen backdrop to catch taps outside.
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeSheet,
              behavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
            ),
          ),
          // The sheet, anchored above the button.
          CompositedTransformFollower(
            link: _layerLink,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -8),
            child: AnimatedBuilder(
              animation: _sheetController,
              builder: (context, child) {
                return Opacity(
                  opacity: _sheetOpacity.value,
                  child: Transform.scale(
                    scale: _sheetScale.value,
                    alignment: Alignment.bottomCenter,
                    child: child,
                  ),
                );
              },
              child: _ActionSheet(
                onPhotos: _onPhotos,
                onFiles: _onFiles,
                colors: c,
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  /// Long-press handler: clears all staged attachments.
  void _onLongPress() {
    if (widget.isDisabled) return;
    final state = ref.read(attachmentProvider);
    if (!state.isNotEmpty) return;

    HapticFeedback.mediumImpact();
    ref.read(attachmentProvider.notifier).clear();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All attachments cleared'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // -----------------------------------------------------------------------
  // File picking
  // -----------------------------------------------------------------------

  /// Picks multiple images from the gallery via ImagePicker, validates size,
  /// generates thumbnails, and stages them as attachments.
  Future<void> _onPhotos() async {
    _closeSheet();

    try {
      final pickedFiles = await _imagePicker.pickMultiImage();
      if (pickedFiles.isEmpty) return;

      final rejectedNames = <String>[];
      final validItems = <AttachmentItem>[];

      for (final xFile in pickedFiles) {
        final file = File(xFile.path);
        final fileSize = await file.length();

        if (fileSize > kMaxFileSizeBytes) {
          rejectedNames.add(xFile.name);
          continue;
        }

        final mimeType = mimeTypeFromExtension(xFile.name);
        final thumbnail = _isImageMime(mimeType)
            ? await _generateThumbnail(xFile.path)
            : null;

        validItems.add(AttachmentItem(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          filename: xFile.name,
          filePath: xFile.path,
          mimeType: mimeType,
          thumbnailBytes: thumbnail,
        ));

        // Ensure unique IDs when picking multiple files rapidly.
        await Future.delayed(const Duration(microseconds: 1));
      }

      if (validItems.isNotEmpty) {
        ref.read(attachmentProvider.notifier).addAll(validItems);
      }

      _showRejectionSnackBar(rejectedNames);
    } catch (e) {
      debugPrint('[AttachmentButton] Photo pick failed: $e');
    }
  }

  /// Picks multiple files of any type via FilePicker, validates size,
  /// generates thumbnails for images, and stages them as attachments.
  Future<void> _onFiles() async {
    _closeSheet();

    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;

      final rejectedNames = <String>[];
      final validItems = <AttachmentItem>[];

      for (final platformFile in result.files) {
        final path = platformFile.path;
        if (path == null) continue;

        final file = File(path);
        final fileSize = await file.length();

        if (fileSize > kMaxFileSizeBytes) {
          rejectedNames.add(platformFile.name);
          continue;
        }

        final mimeType = mimeTypeFromExtension(platformFile.name);
        final thumbnail = _isImageMime(mimeType)
            ? await _generateThumbnail(path)
            : null;

        validItems.add(AttachmentItem(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          filename: platformFile.name,
          filePath: path,
          mimeType: mimeType,
          thumbnailBytes: thumbnail,
        ));

        // Ensure unique IDs when picking multiple files rapidly.
        await Future.delayed(const Duration(microseconds: 1));
      }

      if (validItems.isNotEmpty) {
        ref.read(attachmentProvider.notifier).addAll(validItems);
      }

      _showRejectionSnackBar(rejectedNames);
    } catch (e) {
      debugPrint('[AttachmentButton] File pick failed: $e');
    }
  }

  /// Shows a SnackBar listing files that were rejected for exceeding the
  /// 50MB size limit. Does nothing if [names] is empty.
  void _showRejectionSnackBar(List<String> names) {
    if (names.isEmpty || !mounted) return;

    final label = names.length == 1
        ? '"${names.first}" exceeds the 50 MB limit'
        : '${names.length} files exceed the 50 MB limit';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(label),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final disabled = widget.isDisabled;

    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled
            ? null
            : (_) {
                setState(() => _pressed = false);
                _toggleSheet();
              },
        onTapCancel: disabled
            ? null
            : () => setState(() => _pressed = false),
        onLongPress: disabled ? null : _onLongPress,
        child: Semantics(
          label: 'Add attachment',
          button: true,
          child: AnimatedScale(
            scale: _pressed ? 0.93 : 1.0,
            duration: const Duration(milliseconds: 80),
            child: Opacity(
              opacity: disabled ? 0.35 : 1.0,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.keyGroupResting,
                ),
                child: Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: widget.size * 0.5,
                    color: c.keyGroupText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Action sheet popover with Photos and Files options.
///
/// Accepts [colors] explicitly because this widget renders in Flutter's
/// [Overlay] layer, which may not share the same inherited widget tree as the
/// button that spawned it.
class _ActionSheet extends StatelessWidget {
  final VoidCallback onPhotos;
  final VoidCallback onFiles;
  final AppColorScheme colors;

  const _ActionSheet({
    required this.onPhotos,
    required this.onFiles,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;

    return Container(
      width: 170,
      decoration: BoxDecoration(
        color: c.fanPopoverBg,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(128),
            blurRadius: 36,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: c.border,
            blurRadius: 0,
            spreadRadius: 1,
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionSheetItem(
            icon: Icons.photo_library_outlined,
            label: 'Photos',
            onTap: onPhotos,
            colors: c,
          ),
          Container(
            height: 1,
            color: c.border,
          ),
          _ActionSheetItem(
            icon: Icons.folder_outlined,
            label: 'Files',
            onTap: onFiles,
            colors: c,
          ),
        ],
      ),
    );
  }
}

/// Single action sheet item row.
class _ActionSheetItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final AppColorScheme colors;

  const _ActionSheetItem({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, size: 16, color: c.textMuted),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: c.textSecondary,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
