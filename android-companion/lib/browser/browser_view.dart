/// Browser pane with real WebView rendering and functional URL bar.
///
/// Manages one WebView per browser tab using an IndexedStack to preserve
/// scroll position and form state across tab switches. Handles URL rewriting
/// for localhost ports via Tailscale IP, self-signed cert acceptance for
/// Tailscale IPs, and bidirectional navigation sync with the desktop.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import 'browser_tab_provider.dart';
import 'speed_dial_view.dart';
import 'url_bar.dart';
import 'url_rewriter.dart';

/// Maximum number of live WebView instances before LRU eviction kicks in.
const _maxLiveWebViews = 5;

class BrowserView extends ConsumerStatefulWidget {
  const BrowserView({super.key});

  @override
  ConsumerState<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends ConsumerState<BrowserView> {
  /// Active WebView controllers, keyed by surface ID.
  final Map<String, WebViewController> _controllers = {};

  /// LRU access order for eviction — most recently used at the end.
  final LinkedHashMap<String, bool> _lruOrder = LinkedHashMap();

  /// URLs of evicted WebViews, for reload on re-focus.
  final Map<String, String> _evictedUrls = {};

  /// Guards against sync loops when loading a URL from a remote event.
  bool _isRemoteNavigation = false;

  /// Last URL set by remote navigation, for secondary sync loop guard.
  String? _lastRemoteUrl;

  /// Tailscale IP of the Mac, extracted from the connection host.
  String get _tailscaleIp {
    final manager = ref.read(connectionManagerProvider);
    // The connection host IS the Tailscale IP (or LAN IP)
    return manager.host ?? '100.0.0.0';
  }

  @override
  void dispose() {
    _controllers.clear();
    super.dispose();
  }

  /// Gets or creates a WebViewController for the given surface.
  WebViewController _getOrCreateController(String surfaceId, String? url) {
    if (_controllers.containsKey(surfaceId)) {
      // Move to end of LRU
      _lruOrder.remove(surfaceId);
      _lruOrder[surfaceId] = true;
      return _controllers[surfaceId]!;
    }

    // Check if this was evicted and needs reload
    final evictedUrl = _evictedUrls.remove(surfaceId);

    // Evict LRU if at capacity
    while (_controllers.length >= _maxLiveWebViews) {
      final oldestId = _lruOrder.keys.first;
      final oldController = _controllers.remove(oldestId);
      _lruOrder.remove(oldestId);

      // Store URL for potential reload
      final surfaces = ref.read(browserTabProvider).surfaces;
      final surface = surfaces.where((s) => s.id == oldestId).firstOrNull;
      if (surface?.url != null) {
        _evictedUrls[oldestId] = surface!.url!;
      }

      debugPrint('[BrowserView] Evicted WebView for surface $oldestId');
      // WebViewController is disposed when removed from widget tree
      oldController; // suppress unused warning
    }

    // Create new controller
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          ref.read(browserTabProvider.notifier).setLoading(surfaceId, true);
        },
        onPageFinished: (url) {
          ref.read(browserTabProvider.notifier).setLoading(surfaceId, false);
        },
        onUrlChange: (change) => _onUrlChange(surfaceId, change.url),
        onNavigationRequest: (request) {
          // Block file:// URLs for security
          if (request.url.startsWith('file://')) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onHttpError: (error) {
          debugPrint('[BrowserView] HTTP error for $surfaceId: ${error.response?.statusCode}');
        },
        onWebResourceError: (error) {
          debugPrint('[BrowserView] Resource error for $surfaceId: ${error.description}');
          ref.read(browserTabProvider.notifier).setLoading(surfaceId, false);
        },
      ));

    _controllers[surfaceId] = controller;
    _lruOrder[surfaceId] = true;

    // Load initial URL
    final urlToLoad = url ?? evictedUrl;
    if (urlToLoad != null && urlToLoad.isNotEmpty) {
      _loadUrl(controller, urlToLoad);
    }

    return controller;
  }

  /// Loads a URL in the WebView, applying Tailscale IP rewriting for local URLs.
  void _loadUrl(WebViewController controller, String url) {
    final rewritten = rewriteUrl(url, _tailscaleIp);
    controller.loadRequest(Uri.parse(rewritten));
  }

  /// Called when the WebView's URL changes (user-initiated or JS navigation).
  void _onUrlChange(String surfaceId, String? url) {
    if (url == null) return;

    // Clear remote navigation flag
    if (_isRemoteNavigation) {
      _isRemoteNavigation = false;
      return;
    }

    // Secondary guard: skip if this URL matches the last remote URL
    if (url == _lastRemoteUrl) {
      _lastRemoteUrl = null;
      return;
    }

    // User-initiated navigation — sync to bridge
    ref.read(browserTabProvider.notifier).setUrl(surfaceId, url);

    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('browser.navigate', params: {
      'surface_id': surfaceId,
      'url': url, // Send the original URL, not rewritten
    });

    // Add to recent URLs
    ref.read(browserTabProvider.notifier).addRecentUrl(RecentUrl(
      url: url,
      lastVisited: DateTime.now(),
    ));
  }

  /// Navigates the active surface to a URL (from URL bar or speed dial).
  void _navigateActiveSurface(String url) {
    final state = ref.read(browserTabProvider);
    final surfaceId = state.activeSurfaceId;
    if (surfaceId == null) return;

    final controller = _controllers[surfaceId];
    if (controller == null) return;

    ref.read(browserTabProvider.notifier).setUrl(surfaceId, url);
    _loadUrl(controller, url);

    // Sync to bridge
    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('browser.navigate', params: {
      'surface_id': surfaceId,
      'url': url,
    });

    // Add to recent URLs
    ref.read(browserTabProvider.notifier).addRecentUrl(RecentUrl(
      url: url,
      lastVisited: DateTime.now(),
    ));
  }

  /// Handles a remote navigation event (desktop navigated).
  void _onRemoteNavigation(String surfaceId, String url) {
    final controller = _controllers[surfaceId];
    if (controller == null) return;

    _isRemoteNavigation = true;
    _lastRemoteUrl = rewriteUrl(url, _tailscaleIp);
    _loadUrl(controller, url);
  }

  void _onBack() {
    final surfaceId = ref.read(browserTabProvider).activeSurfaceId;
    if (surfaceId == null) return;

    _controllers[surfaceId]?.goBack();

    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('browser.back', params: {'surface_id': surfaceId});
  }

  void _onForward() {
    final surfaceId = ref.read(browserTabProvider).activeSurfaceId;
    if (surfaceId == null) return;

    _controllers[surfaceId]?.goForward();

    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('browser.forward', params: {'surface_id': surfaceId});
  }

  void _onReload() {
    final surfaceId = ref.read(browserTabProvider).activeSurfaceId;
    if (surfaceId == null) return;

    final surface = ref.read(browserTabProvider).activeSurface;
    if (surface?.isLoading == true) {
      // Stop loading
      _controllers[surfaceId]?.loadRequest(Uri.parse('about:blank'));
      // Immediately go back to the original URL
      _controllers[surfaceId]?.goBack();
    } else {
      _controllers[surfaceId]?.reload();
    }

    final manager = ref.read(connectionManagerProvider);
    manager.sendRequest('browser.reload', params: {'surface_id': surfaceId});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserTabProvider);
    final activeSurface = state.activeSurface;

    if (activeSurface == null) {
      return const _EmptyBrowserState();
    }

    // If the active surface has no URL, show speed dial
    if (activeSurface.url == null || activeSurface.url!.isEmpty) {
      return Column(
        children: [
          UrlBar(
            url: null,
            isLoading: false,
            canGoBack: false,
            canGoForward: false,
            onNavigate: _navigateActiveSurface,
          ),
          Expanded(
            child: SpeedDialView(
              onUrlSelected: _navigateActiveSurface,
            ),
          ),
        ],
      );
    }

    // Build WebViews for all surfaces with URLs
    final surfacesWithUrls = state.surfaces
        .where((s) => s.url != null && s.url!.isNotEmpty)
        .toList();

    final activeIndex = surfacesWithUrls.indexWhere(
      (s) => s.id == activeSurface.id,
    );

    // Ensure controllers exist for all visible surfaces
    for (final surface in surfacesWithUrls) {
      _getOrCreateController(surface.id, surface.url);
    }

    return Column(
      children: [
        UrlBar(
          url: activeSurface.url,
          isLoading: activeSurface.isLoading,
          canGoBack: activeSurface.canGoBack,
          canGoForward: activeSurface.canGoForward,
          onBack: _onBack,
          onForward: _onForward,
          onReload: _onReload,
          onNavigate: _navigateActiveSurface,
        ),
        Expanded(
          child: IndexedStack(
            index: activeIndex >= 0 ? activeIndex : 0,
            children: surfacesWithUrls.map((surface) {
              final controller = _controllers[surface.id];
              if (controller == null) {
                return const SizedBox.shrink();
              }
              return WebViewWidget(controller: controller);
            }).toList(),
          ),
        ),
      ],
    );
  }
}

/// Shown when there are no browser surfaces at all.
class _EmptyBrowserState extends StatelessWidget {
  const _EmptyBrowserState();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.language, size: 48, color: c.textMuted),
          const SizedBox(height: 12),
          Text(
            'No browser tabs',
            style: TextStyle(fontSize: 14, color: c.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            'Create a new tab with the + button',
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}
