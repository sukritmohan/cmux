# Implementation Plan: Android Browser Pane

**Date:** 2026-03-21
**Spec:** `docs/superpowers/specs/2026-03-21-android-browser-pane-design.md`

## Executive Summary

This plan adds a functional browser pane to the Android companion app, replacing the current shimmer stub with real WebView rendering. The work spans three layers: a new `BridgeBrowserHandler` on the Swift/Mac side to push browser state change events, a `BrowserTabProvider` Riverpod notifier on the Flutter side, and a rewritten `BrowserView` with embedded WebViews, URL bar, and speed dial page. The desktop already has `browser.tab.list`, `browser.tab.new`, `browser.tab.close`, `browser.navigate`, `browser.back`, `browser.forward`, `browser.reload` implemented in `TerminalController.dispatchV2` — the primary bridge work is emitting push events for state changes.

## API Naming Decision

The design spec proposed `browser.list`, `browser.create`, `browser.close` but the desktop already implements `browser.tab.list`, `browser.tab.new`, `browser.tab.close`. **We use the existing API names** on the Flutter side to avoid adding Swift routing code.

---

## Checkpoint 1: Browser State Provider + URL Rewriter (Flutter)

**Goal:** Create the Riverpod state model and URL rewriting utility — pure Dart, no UI, no bridge changes.

### New Files

**`android-companion/lib/browser/browser_tab_provider.dart`**
- `BrowserSurface` data class: `id`, `url`, `title`, `faviconUrl`, `isLoading`, `canGoBack`, `canGoForward`
- `BrowserTabState`: `List<BrowserSurface> surfaces`, `String? activeSurfaceId`, `List<DiscoveredPort> discoveredPorts`, `List<RecentUrl> recentUrls`
- `BrowserTabNotifier extends StateNotifier<BrowserTabState>`:
  - `setSurfaces(List<BrowserSurface>, {String? focusedId})`
  - `onBrowserNavigated(Map<String, dynamic> data)` — updates url/title/canGoBack/canGoForward
  - `onBrowserCreated(Map<String, dynamic> data)` — adds surface
  - `onBrowserClosed(Map<String, dynamic> data)` — removes surface
  - `setActiveSurface(String id)`
  - `setDiscoveredPorts(List<DiscoveredPort>)`
  - `addRecentUrl(RecentUrl)` — prepends, dedupes by URL, caps at 20, persists via SharedPreferences
  - `loadRecentUrls()` — reads from SharedPreferences on init
- `DiscoveredPort` data class: `int port`, `String? processName`, `String? protocol`
- `RecentUrl` data class: `String url`, `String? title`, `String? faviconUrl`, `DateTime lastVisited`
- Global provider: `final browserTabProvider = StateNotifierProvider<BrowserTabNotifier, BrowserTabState>(...)`

**`android-companion/lib/browser/url_rewriter.dart`**
- `UrlClassification` enum: `local`, `external`
- `classifyUrl(String url) -> UrlClassification` — checks for localhost, 127.0.0.1, 0.0.0.0, Tailscale CGNAT range (100.64.0.0/10)
- `rewriteUrl(String url, String tailscaleIp) -> String` — replaces local hosts with tailscaleIp
- `isTailscaleCgnat(String host) -> bool` — checks if IP is in 100.64.0.0/10 (addresses 100.64.x.x through 100.127.x.x)
- `parseDisplayUrl(String url) -> ({String scheme, String host, String path})` — splits URL for styled rendering

### Acceptance Criteria
- `BrowserTabNotifier` can be instantiated, surfaces added/removed/updated
- `url_rewriter` correctly classifies: `localhost:3000` → local, `127.0.0.1:8080` → local, `github.com` → external, `100.100.1.1:3000` → local (Tailscale)
- Recent URLs persist and dedupe correctly

### Complexity: Low

---

## Checkpoint 2: Bridge Protocol — Browser Events & Connection Methods

**Goal:** Wire browser events into the event handler, add browser API call methods to ConnectionManager, and fetch browser surfaces on connect.

### Modified Files

**`android-companion/lib/connection/connection_manager.dart`**
- Add methods: `browserList()`, `browserNavigate(surfaceId, url)`, `browserBack(surfaceId)`, `browserForward(surfaceId)`, `browserReload(surfaceId)`, `browserCreate({url?})`, `browserClose(surfaceId)`
- Each sends the appropriate JSON-RPC request: `browser.tab.list`, `browser.navigate`, `browser.back`, `browser.forward`, `browser.reload`, `browser.tab.new`, `browser.tab.close`

**`android-companion/lib/state/event_handler.dart`**
- Import `browser_tab_provider.dart`
- Add cases to `_onEvent` switch:
  - `'browser.navigated'` → `_ref.read(browserTabProvider.notifier).onBrowserNavigated(data)`
  - `'browser.created'` → `_ref.read(browserTabProvider.notifier).onBrowserCreated(data)`
  - `'browser.closed'` → `_ref.read(browserTabProvider.notifier).onBrowserClosed(data)`

**`android-companion/lib/terminal/terminal_screen.dart`**
- In initial data fetch: also call `browser.tab.list` and populate `browserTabProvider` with browser surfaces
- On workspace switch: re-fetch browser surfaces for new workspace
- On reconnect: re-fetch browser surfaces

### Acceptance Criteria
- Connection manager can send all `browser.*` requests
- Incoming `browser.navigated/created/closed` events update `BrowserTabState`
- Browser surfaces are fetched on initial connect and workspace switch

### Complexity: Low
### Dependencies: Checkpoint 1

---

## Checkpoint 3: Bridge Protocol — Mac Side Push Events (Swift)

**Goal:** Add push events from the desktop so the phone receives real-time updates when browser panes navigate, are created, or closed.

### New Files

**`Sources/Bridge/BridgeBrowserHandler.swift`**
- Observes `BrowserPanel` state changes (URL navigation, title updates)
- Posts NotificationCenter notifications for browser events
- The existing `browser.*` commands already route through `TerminalController.dispatchV2` — no command routing changes needed

### Modified Files

**`Sources/Bridge/BridgeEventRelay.swift`**
- Add notification names: `bridgeBrowserNavigated`, `bridgeBrowserCreated`, `bridgeBrowserClosed`
- Register observers in `registerObservers()` for these notifications
- Each observer calls `emit(event:data:)` with:
  - `browser.navigated`: `{surface_id, url, title, favicon_url, can_go_back, can_go_forward}`
  - `browser.created`: `{surface_id, url?, title?}`
  - `browser.closed`: `{surface_id}`

### Key Risk
This is the riskiest checkpoint. `BrowserPanel` is `@MainActor` and `ObservableObject` — observing `@Published currentURL` changes requires either:
- **Option A:** Combine observation (subscribe to `$currentURL` publisher)
- **Option B:** Post `NotificationCenter` notification from `BrowserPanel` itself when URL changes

Option B is simpler and matches existing event relay patterns. Add `NotificationCenter.default.post(name: .bridgeBrowserNavigated, ...)` in `BrowserPanel`'s `didSet` for URL-related properties.

### Acceptance Criteria
- When desktop browser pane navigates, `browser.navigated` event is pushed to phone
- When desktop browser pane is created/closed, corresponding event is pushed
- `browser.tab.list` returns correct browser surfaces with URLs and titles

### Complexity: Medium
### Dependencies: None (can be done in parallel with Checkpoints 1-2)

---

## Checkpoint 4: WebView Integration + URL Bar (Flutter)

**Goal:** Replace mock BrowserView with real WebView and functional URL bar. Single-tab first.

### Modified Files

**`android-companion/pubspec.yaml`**
- Add dependency: `webview_flutter: ^4.10.0`

**`android-companion/lib/browser/url_bar.dart`**
- Remove `MockUrl` class entirely
- Make `UrlBar` a `StatefulWidget`
- Constructor params: `String? url`, `bool isLoading`, `bool canGoBack`, `bool canGoForward`, `VoidCallback onBack`, `VoidCallback onForward`, `VoidCallback onReload`, `ValueChanged<String> onNavigate`
- Display mode: URL rendered with scheme at 40% opacity, host full, path secondary color (using `parseDisplayUrl`)
- Edit mode: tap URL → TextField with full URL pre-selected, submit calls `onNavigate`
- Left side: back/forward buttons (disabled state driven by canGoBack/canGoForward)
- Right side: reload button (swaps to stop icon when `isLoading`)
- Bottom: thin `LinearProgressIndicator` when `isLoading`

**`android-companion/lib/browser/browser_view.dart`**
- Remove `_MockWebContent`, `_ShimmerBlock`, all shimmer code
- Make `BrowserView` a `ConsumerStatefulWidget`
- Create `WebViewController` for the active surface
- URL rewriting: before loading, run through `url_rewriter` to rewrite local URLs
- Sync loop prevention:
  - `_isRemoteNavigation` flag: set true before loading a URL from `browser.navigated` event, cleared after `onUrlChange` fires
  - Secondary guard: compare reported URL against last-set remote URL, skip bridge notification if they match
- `onPageStarted`/`onPageFinished` → update `isLoading` in provider
- `onUrlChange` → if not remote navigation, send `browser.navigate` to bridge (with original URL, not rewritten)
- SSL handling: auto-accept self-signed certs when host is in Tailscale CGNAT range (100.64.0.0/10) via `onSslError`
- Wire URL bar callbacks to connection manager methods

### Acceptance Criteria
- WebView loads and renders a real web page
- URL bar displays current URL with styled segments
- Typing a URL and submitting navigates the WebView
- `localhost:3000` is rewritten to `{tailscaleIp}:3000` before loading
- Back/forward/reload buttons work
- Loading indicator shows during page load
- Self-signed certs accepted for Tailscale IPs
- Desktop navigation updates phone WebView without sync loop

### Complexity: High (largest checkpoint)
### Dependencies: Checkpoints 1, 2, 3

---

## Checkpoint 5: Multi-Tab WebView Management (Flutter)

**Goal:** Support multiple browser tabs with per-tab WebView instances, tab strip integration, and LRU eviction.

### Modified Files

**`android-companion/lib/browser/browser_view.dart`**
- Wrap WebViews in `IndexedStack` (active visible, others offstage)
- Track `Map<String, WebViewController>` keyed by surface ID
- LRU eviction: max 5 live WebViews. Beyond that, destroy least-recently-focused WebView, store its URL for reload on re-focus. (May need to reduce to 3 on low-memory devices — add a configurable constant.)
- On tab switch: if WebView exists, show it; if evicted, recreate and reload URL

**`android-companion/lib/terminal/tab_bar_strip.dart`**
- Replace `_staticBrowserTabs` with real data from `browserTabProvider`
- `_buildBrowserTabs()`: read `BrowserTabState.surfaces`, render `_TabChip` for each
- Tab label: `surface.title ?? hostname ?? 'New Tab'`
- Tap → update `activeSurfaceId` in `BrowserTabProvider`
- Long-press → close option (calls `browserClose`)
- Globe icon fallback when `faviconUrl` is null

**`android-companion/lib/terminal/terminal_screen.dart`**
- When `_activePaneType == PaneType.browser`: pass browser surfaces and focused ID to `TopBar`
- Wire `_onSurfaceSelected` to handle browser surface focus
- Wire `_onNewTab` to send `browser.tab.new` when in browser mode

### Acceptance Criteria
- Tab strip shows actual browser surfaces with real titles
- Tapping a tab switches visible WebView without reloading
- `(+)` button creates desktop browser pane, shows new tab on phone
- Closing a tab removes it from phone and desktop
- With 6+ tabs, LRU eviction kicks in; re-focusing evicted tab reloads URL
- Tab switching preserves scroll position and form state

### Complexity: Medium-high
### Dependencies: Checkpoint 4

---

## Checkpoint 6: Speed Dial View (Flutter)

**Goal:** New tab page with discovered ports grid and recent URLs.

### New Files

**`android-companion/lib/browser/speed_dial_view.dart`**
- Shown when active browser surface has `url == null` (new tab)
- URL bar at top, auto-focused
- **Discovered Ports** section:
  - 2-column `GridView` of cards
  - Each card: port number prominent, process/framework name below
  - Tap → navigate to `http://{tailscaleIp}:{port}`
  - Data from `ports.list` API, polled every 10 seconds via `Timer.periodic` (cancelled on dispose)
  - Manual refresh button
- **Recent URLs** section:
  - `ListView` below ports grid
  - Each row: globe icon + title + subdued URL
  - Tap → navigate
  - Data from `BrowserTabState.recentUrls`
- Calls `browserTabProvider.addRecentUrl()` on successful navigation

### Modified Files

**`android-companion/lib/browser/browser_view.dart`**
- When active surface has `url == null`, show `SpeedDialView` instead of WebView
- When user selects port or types URL, navigate and update surface

### Acceptance Criteria
- New tab shows speed dial with URL bar auto-focused
- Discovered ports appear in grid, refresh every 10s
- Tapping port card loads `http://{tailscaleIp}:{port}`
- Recent URLs persist across app restarts (SharedPreferences)
- Navigating from speed dial transitions to WebView content

### Complexity: Medium
### Dependencies: Checkpoints 4, 5

---

## Checkpoint 7: Polish + Edge Cases

**Goal:** Handle workspace switching, reconnection, modifier bar integration, and connection overlay.

### Modified Files

**`android-companion/lib/terminal/terminal_screen.dart`**
- On workspace switch: tear down browser WebViews for old workspace, create for new
- On reconnect: re-fetch browser surfaces via `browser.tab.list`

**`android-companion/lib/browser/browser_view.dart`**
- Show connection lost overlay (same as terminal) when bridge disconnects
- Guard against empty/invalid URLs in navigation

**`android-companion/lib/terminal/modifier_bar.dart`** (or browser_view.dart)
- In browser mode: inject modifier key events (Esc, Tab, arrows) into WebView via JavaScript:
  ```javascript
  dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', ...}))
  ```
- Note: JS injection may be brittle with complex web apps — start simple, iterate if needed

**`android-companion/lib/state/event_handler.dart`**
- On `workspace.selected` event: trigger browser surface re-sync

### Acceptance Criteria
- Switching workspaces shows correct browser surfaces (old ones torn down)
- Reconnecting restores browser state
- Modifier bar keys work in browser mode for basic form navigation
- Connection overlay shows when bridge disconnects

### Complexity: Medium
### Dependencies: Checkpoints 5, 6

---

## Risks

1. **Push events (Checkpoint 3):** Desktop has no existing mechanism to push `browser.navigated` events. This requires hooking into `BrowserPanel`'s navigation lifecycle — riskiest part of the plan.
2. **Sync loop prevention:** The `_isRemoteNavigation` flag could get stuck if `onUrlChange` fires multiple times. Secondary URL-comparison guard mitigates this.
3. **WebView memory:** Android has per-process WebView limits. The 5-tab LRU cap may need reduction to 3 on low-memory devices.
4. **SSL handling:** `webview_flutter` SSL error handling varies across Android versions. The CGNAT range check must be precise (100.64.0.0/10 = addresses 100.64.x.x through 100.127.x.x).
5. **JS key injection:** Modifier bar keys via `dispatchEvent` may not work with all web frameworks. Start simple, iterate.

## File Summary

### New Files (4)
| File | Checkpoint |
|------|-----------|
| `android-companion/lib/browser/browser_tab_provider.dart` | 1 |
| `android-companion/lib/browser/url_rewriter.dart` | 1 |
| `android-companion/lib/browser/speed_dial_view.dart` | 6 |
| `Sources/Bridge/BridgeBrowserHandler.swift` | 3 |

### Modified Files (8)
| File | Checkpoint |
|------|-----------|
| `android-companion/pubspec.yaml` | 4 |
| `android-companion/lib/browser/browser_view.dart` | 4, 5, 6, 7 |
| `android-companion/lib/browser/url_bar.dart` | 4 |
| `android-companion/lib/connection/connection_manager.dart` | 2 |
| `android-companion/lib/state/event_handler.dart` | 2, 7 |
| `android-companion/lib/terminal/tab_bar_strip.dart` | 5 |
| `android-companion/lib/terminal/terminal_screen.dart` | 2, 5, 7 |
| `Sources/Bridge/BridgeEventRelay.swift` | 3 |
