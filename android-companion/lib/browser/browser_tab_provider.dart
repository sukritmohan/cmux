/// Riverpod notifier for browser surface state within the active workspace.
///
/// Tracks which browser surfaces exist, which one is focused, discovered
/// ports from the desktop, and recently visited URLs. Reacts to bridge
/// events for browser navigation/create/close.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A discovered port running on the desktop Mac.
class DiscoveredPort {
  final int port;
  final String? processName;
  final String? protocol;

  const DiscoveredPort({
    required this.port,
    this.processName,
    this.protocol,
  });
}

/// A recently visited URL, persisted locally.
class RecentUrl {
  final String url;
  final String? title;
  final String? faviconUrl;
  final DateTime lastVisited;

  const RecentUrl({
    required this.url,
    this.title,
    this.faviconUrl,
    required this.lastVisited,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'favicon_url': faviconUrl,
        'last_visited': lastVisited.toIso8601String(),
      };

  factory RecentUrl.fromJson(Map<String, dynamic> json) => RecentUrl(
        url: json['url'] as String,
        title: json['title'] as String?,
        faviconUrl: json['favicon_url'] as String?,
        lastVisited: DateTime.parse(json['last_visited'] as String),
      );
}

/// A browser surface (tab) within a workspace, mirroring a desktop browser pane.
class BrowserSurface {
  final String id;
  final String? url;
  final String? title;
  final String? faviconUrl;
  final bool isLoading;
  final bool canGoBack;
  final bool canGoForward;

  const BrowserSurface({
    required this.id,
    this.url,
    this.title,
    this.faviconUrl,
    this.isLoading = false,
    this.canGoBack = false,
    this.canGoForward = false,
  });

  BrowserSurface copyWith({
    String? id,
    String? url,
    String? title,
    String? faviconUrl,
    bool? isLoading,
    bool? canGoBack,
    bool? canGoForward,
  }) {
    return BrowserSurface(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      faviconUrl: faviconUrl ?? this.faviconUrl,
      isLoading: isLoading ?? this.isLoading,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
    );
  }
}

/// State held by [BrowserTabNotifier].
class BrowserTabState {
  final List<BrowserSurface> surfaces;
  final String? activeSurfaceId;
  final List<DiscoveredPort> discoveredPorts;
  final List<RecentUrl> recentUrls;

  const BrowserTabState({
    this.surfaces = const [],
    this.activeSurfaceId,
    this.discoveredPorts = const [],
    this.recentUrls = const [],
  });

  /// The currently active browser surface, falling back to the first one.
  BrowserSurface? get activeSurface {
    if (activeSurfaceId == null) return surfaces.firstOrNull;
    return surfaces
            .where((s) => s.id == activeSurfaceId)
            .firstOrNull ??
        surfaces.firstOrNull;
  }

  /// Zero-based index of the active surface, or 0 if not found.
  int get activeIndex {
    if (activeSurfaceId == null) return 0;
    final index = surfaces.indexWhere((s) => s.id == activeSurfaceId);
    return index == -1 ? 0 : index;
  }

  /// Whether more than one browser surface exists.
  bool get hasMultipleSurfaces => surfaces.length > 1;

  BrowserTabState copyWith({
    List<BrowserSurface>? surfaces,
    String? activeSurfaceId,
    List<DiscoveredPort>? discoveredPorts,
    List<RecentUrl>? recentUrls,
  }) {
    return BrowserTabState(
      surfaces: surfaces ?? this.surfaces,
      activeSurfaceId: activeSurfaceId ?? this.activeSurfaceId,
      discoveredPorts: discoveredPorts ?? this.discoveredPorts,
      recentUrls: recentUrls ?? this.recentUrls,
    );
  }
}

/// Maximum number of recent URLs to persist.
const _maxRecentUrls = 20;

/// SharedPreferences key for recent URLs.
const _recentUrlsKey = 'browser_recent_urls';

class BrowserTabNotifier extends StateNotifier<BrowserTabState> {
  BrowserTabNotifier() : super(const BrowserTabState());

  /// Replace all browser surfaces (e.g. after fetching workspace panels or on
  /// workspace switch).
  void setSurfaces(List<BrowserSurface> surfaces, {String? focusedId}) {
    state = BrowserTabState(
      surfaces: surfaces,
      activeSurfaceId: focusedId ?? surfaces.firstOrNull?.id,
      discoveredPorts: state.discoveredPorts,
      recentUrls: state.recentUrls,
    );
  }

  /// Handle browser.navigated event — URL/title changed on desktop.
  void onBrowserNavigated(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;

    final updated = state.surfaces.map((s) {
      if (s.id != surfaceId) return s;
      return s.copyWith(
        url: data['url'] as String? ?? s.url,
        title: data['title'] as String? ?? s.title,
        faviconUrl: data['favicon_url'] as String? ?? s.faviconUrl,
        canGoBack: data['can_go_back'] as bool? ?? s.canGoBack,
        canGoForward: data['can_go_forward'] as bool? ?? s.canGoForward,
      );
    }).toList();

    state = state.copyWith(surfaces: updated);
  }

  /// Handle browser.created event — new browser pane on desktop.
  void onBrowserCreated(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;

    // Avoid duplicates
    if (state.surfaces.any((s) => s.id == surfaceId)) return;

    final surface = BrowserSurface(
      id: surfaceId,
      url: data['url'] as String?,
      title: data['title'] as String?,
    );

    state = BrowserTabState(
      surfaces: [...state.surfaces, surface],
      activeSurfaceId: surfaceId,
      discoveredPorts: state.discoveredPorts,
      recentUrls: state.recentUrls,
    );
  }

  /// Handle browser.closed event — browser pane removed on desktop.
  void onBrowserClosed(Map<String, dynamic> data) {
    final surfaceId = data['surface_id'] as String?;
    if (surfaceId == null) return;

    final updated = state.surfaces.where((s) => s.id != surfaceId).toList();
    state = BrowserTabState(
      surfaces: updated,
      activeSurfaceId: state.activeSurfaceId == surfaceId
          ? updated.firstOrNull?.id
          : state.activeSurfaceId,
      discoveredPorts: state.discoveredPorts,
      recentUrls: state.recentUrls,
    );
  }

  /// Focus a specific browser surface by ID.
  void setActiveSurface(String id) {
    state = state.copyWith(activeSurfaceId: id);
  }

  /// Update the loading state for a specific surface.
  void setLoading(String surfaceId, bool isLoading) {
    final updated = state.surfaces.map((s) {
      if (s.id != surfaceId) return s;
      return s.copyWith(isLoading: isLoading);
    }).toList();
    state = state.copyWith(surfaces: updated);
  }

  /// Update the URL for a specific surface (from local WebView navigation).
  void setUrl(String surfaceId, String url) {
    final updated = state.surfaces.map((s) {
      if (s.id != surfaceId) return s;
      return s.copyWith(url: url);
    }).toList();
    state = state.copyWith(surfaces: updated);
  }

  /// Replace discovered ports from ports.list response.
  void setDiscoveredPorts(List<DiscoveredPort> ports) {
    state = state.copyWith(discoveredPorts: ports);
  }

  /// Add a URL to the recent URLs list, deduplicating by URL and capping at
  /// [_maxRecentUrls]. Persists to SharedPreferences.
  Future<void> addRecentUrl(RecentUrl recentUrl) async {
    final existing = state.recentUrls.where((r) => r.url != recentUrl.url).toList();
    final updated = [recentUrl, ...existing].take(_maxRecentUrls).toList();
    state = state.copyWith(recentUrls: updated);
    await _persistRecentUrls(updated);
  }

  /// Load recent URLs from SharedPreferences on init.
  Future<void> loadRecentUrls() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_recentUrlsKey);
      if (jsonString == null) return;

      final list = (jsonDecode(jsonString) as List)
          .cast<Map<String, dynamic>>()
          .map(RecentUrl.fromJson)
          .toList();
      state = state.copyWith(recentUrls: list);
    } catch (e) {
      debugPrint('[BrowserTabProvider] Failed to load recent URLs: $e');
    }
  }

  Future<void> _persistRecentUrls(List<RecentUrl> urls) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(urls.map((u) => u.toJson()).toList());
      await prefs.setString(_recentUrlsKey, jsonString);
    } catch (e) {
      debugPrint('[BrowserTabProvider] Failed to persist recent URLs: $e');
    }
  }
}

final browserTabProvider =
    StateNotifierProvider<BrowserTabNotifier, BrowserTabState>((ref) {
  final notifier = BrowserTabNotifier();
  notifier.loadRecentUrls();
  return notifier;
});
