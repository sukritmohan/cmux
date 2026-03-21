# Android Browser Pane Design Spec

**Date:** 2026-03-21
**Status:** Draft
**Feature:** Browser pane for the Android companion app

## Overview

Add a functional browser pane to the Android companion app that mirrors desktop browser panes as tabs. The browser serves a hybrid purpose: primarily for previewing localhost dev servers (via Tailscale IP rewriting) and secondarily for general web browsing. External URLs load directly from the phone's connection; localhost URLs are rewritten to the Mac's Tailscale IP.

## Requirements

### Core
- Embedded WebView rendering real web pages (replacing the current mock/shimmer stub)
- One WebView instance per tab to preserve scroll position, form state, and history
- Mirror desktop browser panes as mobile tabs (same model as terminal surfaces)
- Speed dial new tab page: discovered ports grid, recent URLs, URL bar
- URL bar with back/forward/reload controls
- URL rewriting: localhost/127.0.0.1/0.0.0.0 ports → Mac's Tailscale IP
- Auto-accept self-signed HTTPS certificates for Tailscale IPs

### Out of Scope (v1)
- Developer tools (JS console, responsive mode, CSS injection)
- Chrome Custom Tabs integration
- Bridge HTTP proxy for port forwarding
- File:// URL support on phone

## Architecture

### Bridge Protocol Extension

New API methods added to BridgeConnection.swift, following the existing terminal surface pattern:

**Commands (phone → desktop):**

| Method | Params | Returns | Description |
|--------|--------|---------|-------------|
| `browser.list` | `{workspace_id?}` | `{surfaces: [{id, url, title, favicon_url, can_go_back, can_go_forward}]}` | List browser surfaces in active workspace |
| `browser.navigate` | `{surface_id, url}` | `{ok: true}` | Navigate a browser surface to a URL |
| `browser.back` | `{surface_id}` | `{ok: true}` | Navigate back in history |
| `browser.forward` | `{surface_id}` | `{ok: true}` | Navigate forward in history |
| `browser.reload` | `{surface_id}` | `{ok: true}` | Reload current page |
| `browser.create` | `{url?}` | `{surface_id}` | Create new browser pane on desktop |
| `browser.close` | `{surface_id}` | `{ok: true}` | Close a browser pane |

**Events (desktop → phone, pushed):**

| Event | Data | Description |
|-------|------|-------------|
| `browser.navigated` | `{surface_id, url, title, favicon_url, can_go_back, can_go_forward}` | URL changed on desktop |
| `browser.created` | `{surface_id, url?, title?}` | New browser pane created on desktop |
| `browser.closed` | `{surface_id}` | Browser pane closed on desktop |

### URL Classification & Rewriting

URLs are classified into two categories with different loading strategies:

**Local URLs** (rewritten to Tailscale IP):
- `localhost:PORT` → `{tailscale_ip}:PORT`
- `127.0.0.1:PORT` → `{tailscale_ip}:PORT`
- `0.0.0.0:PORT` → `{tailscale_ip}:PORT`
- Already a Tailscale IP → pass through unchanged

**External URLs** (loaded directly from phone):
- Any public hostname (github.com, docs.example.com, etc.)
- Phone uses its own internet connection, no routing through Mac

**Sync behavior:**
- Both local and external URLs sync navigation state via bridge (URL, title, back/forward capability)
- The bridge protocol is always followed for state sync regardless of URL type
- Only the loading path differs (Tailscale IP vs direct)

**Mac Tailscale IP:** Stored during pairing. Already captured in connection setup (the WebSocket connects to this IP).

### Flutter State Model (Riverpod)

New provider following the existing surface_provider pattern:

```
BrowserTabProvider (StateNotifier)
  ├── List<BrowserSurface> surfaces
  │   ├── String id
  │   ├── String? url
  │   ├── String? title
  │   ├── String? faviconUrl
  │   ├── bool isLoading
  │   ├── bool canGoBack
  │   └── bool canGoForward
  ├── String? activeSurfaceId
  ├── List<DiscoveredPort> discoveredPorts  (from ports.list, refreshed periodically)
  └── List<RecentUrl> recentUrls            (persisted locally via SharedPreferences)
```

**DiscoveredPort:**
```
├── int port
├── String? processName   (detected framework/server name)
└── String? protocol      (http/https)
```

**RecentUrl:**
```
├── String url
├── String? title
├── String? faviconUrl
└── DateTime lastVisited
```

### WebView Management

- One `WebView` widget per browser tab, managed via `IndexedStack` or `Offstage`
- Active tab's WebView is visible; background tabs remain in widget tree but offstage
- Max 5 live WebViews; beyond that, evict the least-recently-used background WebView (destroy widget, reload URL on re-focus)
- Each WebView has its own `WebViewController` for independent navigation
- WebView `onPageStarted` / `onPageFinished` callbacks update `isLoading` state
- WebView `onUrlChange` callback sends `browser.navigate` to bridge for sync — **guarded by a `_isRemoteNavigation` flag** to prevent sync loops (flag is set true before loading a URL from a `browser.navigated` event, cleared after `onUrlChange` fires)
- Self-signed HTTPS certificates auto-accepted when host is in the Tailscale CGNAT range (100.64.0.0/10)

### Initialization & Lifecycle

- `browser.list` is called on initial connection (after `system.subscribe_events`), on workspace switch, and on reconnect — mirroring how `surfaceProvider` fetches terminal surfaces
- Browser surfaces are tracked only in `BrowserTabProvider`, separate from the terminal `surfaceProvider`. The `tab_bar_strip` checks the active `PaneType` to decide which provider to read from.
- Browser tabs are per-workspace: switching workspaces tears down current WebViews and creates new ones for the new workspace's browser surfaces
- Session state (cookies, localStorage) is not synced between phone and desktop — the phone's WebView is an independent browser context
- Favicon URLs: if the desktop browser pane exposes them, they are included in `browser.list` / `browser.navigated`. If not available, the field is null and the tab strip shows a globe icon fallback.

## UI Design

### Layout (top to bottom)

1. **Top Bar** — Shared with terminal: pane type dropdown + tab strip showing browser surfaces
2. **URL Bar** — Functional URL input with navigation controls
3. **WebView** — Main content area, fills remaining space
4. **Modifier Bar** — Same bottom bar as terminal. In browser mode, modifier keys (Tab, arrows, Esc) are injected into the WebView's focused element via JavaScript `dispatchEvent(new KeyboardEvent(...))` rather than PTY writes.

### URL Bar

- Displays current URL with scheme (https://) at 40% opacity, host at full opacity, path in secondary color
- Left side: back button (disabled if !canGoBack), forward button (disabled if !canGoForward)
- Right side: reload button (changes to stop button while loading)
- Tap URL text → enters edit mode: full URL pre-selected (typing replaces it), keyboard opens
- Loading state: thin progress bar at bottom of URL bar
- Submit → classifies URL, applies rewriting if local, navigates WebView

### Speed Dial (New Tab Page)

Shown when a browser surface has no URL or user creates a new tab:

- **URL bar** auto-focused at top for immediate typing
- **Discovered Ports** section:
  - Grid of cards (2 columns)
  - Each card: port number prominently displayed, process/framework name below if detected
  - One-tap opens `http://{tailscale_ip}:{port}` in the WebView
  - Refreshed via `ports.list` API (polled every 10 seconds while speed dial is visible, with a manual refresh button)
- **Recent URLs** section:
  - Vertical list below ports
  - Each row: favicon + title + URL subdued
  - Tap to navigate
  - Persisted in local storage, max 20 entries

### Tab Strip Behavior

- Shows browser surfaces from desktop (same as terminal tab strip shows terminal surfaces)
- Tab label: page title if available, otherwise hostname, otherwise "New Tab"
- `+` button sends `browser.create` to desktop
- Close tab: long press → close option, or swipe up on tab (matching terminal behavior)
- Active tab indicator matches terminal's style

### Gestures & Touch

- **No swipe on WebView** — WebView gets full native touch control (scroll, zoom, horizontal scroll, long press)
- **Tab switching** — Tap tabs in the strip only
- **Pinch out** — Minimap overlay (triggered from top bar / URL bar area, not WebView content)
- **Pull to refresh** — Not used (conflicts with WebView internal scrolling). Reload via the URL bar reload button instead.

### Loading & Error States

- **Loading:** Thin horizontal progress bar at bottom of URL bar
- **Connection error (Tailscale down):** Same connection overlay as terminal pane
- **Page load error:** WebView's native error page (ERR_CONNECTION_REFUSED, etc.)
- **Port not running:** Standard connection refused error in WebView — no special handling needed

## File Changes

### New Files (Flutter)

| File | Purpose |
|------|---------|
| `lib/browser/browser_tab_provider.dart` | Riverpod StateNotifier for browser surfaces, ports, recent URLs |
| `lib/browser/speed_dial_view.dart` | New tab page with discovered ports grid and recent URLs |
| `lib/browser/url_rewriter.dart` | URL classification (local vs external) and Tailscale IP rewriting |

### Modified Files (Flutter)

| File | Change |
|------|--------|
| `lib/browser/browser_view.dart` | Replace mock shimmer with real WebView + IndexedStack for multi-tab |
| `lib/browser/url_bar.dart` | Replace static display with functional URL input, nav controls, loading state |
| `lib/connection/connection_manager.dart` | Add `browser.*` method calls |
| `lib/state/event_handler.dart` | Handle `browser.navigated/created/closed` events |
| `lib/terminal/tab_bar_strip.dart` | Show real browser surfaces when pane type is browser |
| `pubspec.yaml` | Add `webview_flutter: ^4.x` dependency |

### New Files (Swift / Mac Bridge)

| File | Purpose |
|------|---------|
| `Sources/Bridge/BridgeBrowserHandler.swift` | Handle `browser.*` commands, query desktop browser pane state. Integrates into the existing `dispatchV2` routing chain in BridgeConnection. |

### Modified Files (Swift / Mac Bridge)

| File | Change |
|------|--------|
| `Sources/Bridge/BridgeConnection.swift` | Route `browser.*` methods to BridgeBrowserHandler |
| `Sources/Bridge/BridgeEventRelay.swift` | Emit `browser.*` events when desktop browser state changes |

## Data Flow

### Phone navigates to URL
```
User types URL in URL bar
  → url_rewriter classifies (local vs external)
  → if local: rewrite host to Tailscale IP
  → WebViewController.loadRequest(rewritten_url)
  → browser.navigate {surface_id, url} sent to bridge (sends the original URL, not the rewritten one)
  → Desktop browser pane navigates to original URL
  → browser.navigated event pushed back (confirms sync)
```

### Desktop navigates
```
User navigates in desktop browser pane
  → browser.navigated event pushed to phone
  → BrowserTabProvider updates surface URL/title
  → WebView loads new URL (rewritten if local)
```

### New tab from phone
```
User taps (+) in tab strip
  → browser.create {} sent to bridge
  → Desktop creates new browser pane
  → browser.created event pushed back with surface_id
  → BrowserTabProvider adds new surface
  → Speed dial shown (no URL yet)
  → User taps discovered port or types URL
  → Normal navigation flow
```

## Security Considerations

- Self-signed cert auto-accept is scoped to Tailscale IP range (100.64.0.0/10) only
- No cert bypass for public URLs
- WebView JavaScript enabled by default (required for modern web apps)
- No file:// URL access from WebView
- Cookie/session storage is per-WebView instance (isolated per tab)
