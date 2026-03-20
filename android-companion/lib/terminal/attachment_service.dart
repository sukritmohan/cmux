/// Attachment state management for the modifier bar's (+) button.
///
/// Manages a list of files staged for upload to the desktop. Attachments are
/// ephemeral — they are not persisted across sessions. The upload flow reads
/// file bytes in an isolate via `compute()` to avoid UI freezes on large files.
///
/// Usage:
///   // Add a picked file.
///   ref.read(attachmentProvider.notifier).add(item);
///
///   // Watch state for UI.
///   final state = ref.watch(attachmentProvider);
///   if (state.isNotEmpty) { /* show strip */ }
///
///   // Upload all staged files.
///   final paths = await ref.read(attachmentProvider.notifier).uploadAll();
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// AttachmentItem
// ---------------------------------------------------------------------------

/// Maximum number of attachments that can be staged at once.
const kMaxAttachments = 10;

/// Maximum file size in bytes (50 MB).
const kMaxFileSizeBytes = 50 * 1024 * 1024;

/// A single file staged for upload to the desktop.
class AttachmentItem {
  /// Unique identifier (microseconds-since-epoch).
  final String id;

  /// Display filename (e.g., "photo.jpg").
  final String filename;

  /// Local Android file path for reading bytes on upload.
  final String filePath;

  /// MIME type (e.g., "image/jpeg").
  final String mimeType;

  /// Small thumbnail JPEG (~5KB) for display, or null for non-image files.
  final Uint8List? thumbnailBytes;

  /// Whether the last upload attempt for this item failed.
  final bool hasError;

  const AttachmentItem({
    required this.id,
    required this.filename,
    required this.filePath,
    required this.mimeType,
    this.thumbnailBytes,
    this.hasError = false,
  });

  AttachmentItem copyWith({
    String? id,
    String? filename,
    String? filePath,
    String? mimeType,
    Uint8List? thumbnailBytes,
    bool? hasError,
  }) {
    return AttachmentItem(
      id: id ?? this.id,
      filename: filename ?? this.filename,
      filePath: filePath ?? this.filePath,
      mimeType: mimeType ?? this.mimeType,
      thumbnailBytes: thumbnailBytes ?? this.thumbnailBytes,
      hasError: hasError ?? this.hasError,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AttachmentItem && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

// ---------------------------------------------------------------------------
// AttachmentState
// ---------------------------------------------------------------------------

/// Immutable snapshot of the attachment staging area.
class AttachmentState {
  /// All staged attachments in insertion order.
  final List<AttachmentItem> items;

  /// Whether an upload is currently in progress.
  final bool isUploading;

  /// Human-readable upload progress (e.g., "Uploading 3 files...").
  final String? uploadProgress;

  const AttachmentState({
    this.items = const [],
    this.isUploading = false,
    this.uploadProgress,
  });

  // -- Computed getters --

  /// Whether any attachments are staged.
  bool get isNotEmpty => items.isNotEmpty;

  /// Whether any staged item has a failed upload.
  bool get hasErrors => items.any((item) => item.hasError);

  /// Number of staged attachments.
  int get count => items.length;

  /// Whether the attachment limit has been reached.
  bool get isAtLimit => items.length >= kMaxAttachments;

  /// Items that failed their last upload attempt.
  List<AttachmentItem> get errorItems =>
      items.where((item) => item.hasError).toList();

  AttachmentState copyWith({
    List<AttachmentItem>? items,
    bool? isUploading,
    String? uploadProgress,
  }) {
    return AttachmentState(
      items: items ?? this.items,
      isUploading: isUploading ?? this.isUploading,
      uploadProgress: uploadProgress ?? this.uploadProgress,
    );
  }
}

// ---------------------------------------------------------------------------
// AttachmentNotifier
// ---------------------------------------------------------------------------

/// StateNotifier managing the attachment staging area.
///
/// Handles add/remove/clear operations with deduplication and limit
/// enforcement. The [uploadAll] method reads file bytes in an isolate
/// and returns inbox paths (currently stubbed).
class AttachmentNotifier extends StateNotifier<AttachmentState> {
  AttachmentNotifier() : super(const AttachmentState());

  /// Add a single attachment. Silently ignores duplicates (by filePath) and
  /// rejects when the limit is reached.
  void add(AttachmentItem item) {
    if (state.isAtLimit) return;
    if (state.items.any((a) => a.filePath == item.filePath)) return;
    state = state.copyWith(items: [...state.items, item]);
  }

  /// Batch add attachments with dedup and limit enforcement.
  void addAll(List<AttachmentItem> items) {
    final existingPaths = state.items.map((a) => a.filePath).toSet();
    final newItems = <AttachmentItem>[];

    for (final item in items) {
      if (state.items.length + newItems.length >= kMaxAttachments) break;
      if (existingPaths.contains(item.filePath)) continue;
      existingPaths.add(item.filePath);
      newItems.add(item);
    }

    if (newItems.isEmpty) return;
    state = state.copyWith(items: [...state.items, ...newItems]);
  }

  /// Remove an attachment by ID.
  void remove(String id) {
    state = state.copyWith(
      items: state.items.where((a) => a.id != id).toList(),
    );
  }

  /// Clear all staged attachments and reset upload state.
  void clear() {
    state = const AttachmentState();
  }

  /// Mark a specific item as having a failed upload.
  void markError(String id) {
    state = state.copyWith(
      items: state.items.map((a) {
        if (a.id != id) return a;
        return a.copyWith(hasError: true);
      }).toList(),
    );
  }

  /// Reset all error flags (before a retry attempt).
  void clearErrors() {
    state = state.copyWith(
      items: state.items.map((a) {
        if (!a.hasError) return a;
        return a.copyWith(hasError: false);
      }).toList(),
    );
  }

  /// Remove items whose IDs are in [ids] (for partial success cleanup).
  void removeSuccessful(Set<String> ids) {
    state = state.copyWith(
      items: state.items.where((a) => !ids.contains(a.id)).toList(),
    );
  }

  /// Set the uploading state with optional progress message.
  void setUploading(bool uploading, {String? progress}) {
    state = state.copyWith(
      isUploading: uploading,
      uploadProgress: uploading ? progress : null,
    );
  }

  /// Upload all staged attachments to the desktop.
  ///
  /// For each item, reads file bytes in an isolate, base64-encodes them,
  /// and calls the (currently stubbed) file.transfer RPC.
  ///
  /// Returns a map of item ID → inbox path for successful uploads.
  /// Failed items are marked with [hasError] = true.
  Future<Map<String, String>> uploadAll() async {
    final items = state.items;
    if (items.isEmpty) return {};

    setUploading(true, progress: 'Uploading ${items.length} file${items.length > 1 ? 's' : ''}...');

    final successPaths = <String, String>{};

    for (final item in items) {
      try {
        final path = await _stubbedFileTransfer(item)
            .timeout(const Duration(seconds: 30));
        successPaths[item.id] = path;
      } catch (e) {
        debugPrint('[AttachmentUpload] Failed to upload ${item.filename}: $e');
        markError(item.id);
      }
    }

    setUploading(false);
    return successPaths;
  }

  /// Stubbed file transfer — reads and encodes file bytes to exercise the
  /// real codepath, then returns a synthetic inbox path.
  Future<String> _stubbedFileTransfer(AttachmentItem item) async {
    // Read and base64-encode in an isolate to avoid UI freezes.
    await compute(_readAndEncodeFile, item.filePath);

    // Simulate network delay.
    await Future.delayed(const Duration(milliseconds: 500));

    debugPrint(
      '[AttachmentUpload] Stubbed: file.transfer not implemented on desktop '
      '— returning synthetic path for ${item.filename}',
    );

    return '~/.cmux/inbox/${item.filename}';
  }
}

/// Top-level function for compute() — reads file bytes and base64-encodes.
/// Returns the base64 string (not used by stub, but exercises the codepath).
String _readAndEncodeFile(String filePath) {
  final bytes = File(filePath).readAsBytesSync();
  return base64Encode(bytes);
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Global Riverpod provider for attachment staging state.
final attachmentProvider =
    StateNotifierProvider<AttachmentNotifier, AttachmentState>(
  (ref) => AttachmentNotifier(),
);
