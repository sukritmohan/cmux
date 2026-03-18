# Mobile Companion — Development Architecture

## Status

| Component | Phase | Status |
|-----------|-------|--------|
| Mac-side: cmux-bridge WebSocket server, pairing auth, V2 API relay | Phase 1 | **Complete** — merged to `main` |
| Mac-side: PTY streaming, event relay, Ghostty PTY observer C API | Phase 2 | **Complete** — merged to `main` |
| GhosttyKit Terminal/Screen C API (required for Android rendering) | Pre-Phase 3 | **In progress** |
| Android / Flutter companion app | — | **Not started** |

## Overview

The mobile companion feature enables a Flutter Android app to connect to a running cmux instance over Tailscale and control terminals via the existing V2 JSON-RPC protocol. The Mac-side infrastructure is an in-process WebSocket server (`cmux-bridge`).

## Phase 1 Architecture (Current)

### Components

| File | Purpose |
|---|---|
| `Sources/Bridge/BridgeAuth.swift` | Keychain-backed pairing token management. Singleton, thread-safe via NSLock. Constant-time token comparison using `timingsafe_bcmp`. |
| `Sources/Bridge/BridgeSettings.swift` | UserDefaults-backed config: enabled flag, port (default 17377). |
| `Sources/Bridge/BridgeServer.swift` | Network.framework WebSocket server (NWListener on 0.0.0.0:port). Heartbeat timer (15s ping, 3 missed pong disconnect). Broadcast methods for events and PTY data. |
| `Sources/Bridge/BridgeConnection.swift` | Per-connection state machine: auth -> dispatch. Routes bridge-specific methods (PTY, events), falls back to `TerminalController.dispatchV2` for V2 commands. |
| `Sources/Bridge/BridgePTYStream.swift` | Thread-safe subscription registry + Ghostty PTY observer lifecycle. Registers C callback on first subscriber, unregisters on last disconnect. Observes surface destruction for cleanup. |
| `Sources/Bridge/BridgePTYObserverContext.swift` | Simple context class holding `surfaceId: UUID`, passed as `Unmanaged` userdata to the Ghostty C callback. |
| `Sources/Bridge/BridgeEventRelay.swift` | Event push to bridge clients. Registers 11 NotificationCenter observers in `start()`, removes in `stop()`. `emit(event:data:)` serializes to JSON and broadcasts. |
| `Sources/Bridge/BridgeSettingsView.swift` | SwiftUI settings pane: enable toggle, port config, QR pairing, device management. |

### Key Design Decisions

**Network.framework over NIO/URLSession:** Avoids a dependency, integrates with Apple's networking stack, and provides first-class WebSocket support via `NWProtocolWebSocket.Options`.

**Pairing token auth (not HTTP bearer):** Network.framework's WebSocket implementation doesn't expose HTTP upgrade headers. Instead, auth is done via the first WebSocket message (`auth.pair` JSON-RPC call).

**No TLS:** Tailscale provides WireGuard encryption at the network layer. Adding TLS would add complexity without security benefit.

**`dispatchV2` extraction:** The V2 command dispatch switch was extracted from `processV2Command` into a public `dispatchV2(method:id:params:)` method on TerminalController. Both the Unix socket handler and BridgeConnection call this. The socket password check is intentionally NOT included in `dispatchV2` — bridge connections have their own auth layer (pairing tokens).

**Binary PTY frame format:** `[4-byte LE channel ID][raw PTY data]`. Channel ID derived from first 4 bytes of the surface UUID for efficient demultiplexing.

### Lifecycle

1. `cmuxApp.updateSocketController()` calls `updateBridgeServer()` which starts/stops based on `BridgeSettings.isEnabled`
2. `AppDelegate.applicationWillTerminate` calls `BridgeServer.shared.stop()` and `BridgeEventRelay.shared.stop()`
3. Settings changes to the bridge enabled toggle trigger `updateBridgeState()` in `BridgeSettingsView`

### Threading Model

- `BridgeAuth`: `@unchecked Sendable` + `NSLock`. Accessed from any thread.
- `BridgeServer`: `@unchecked Sendable` + `NSLock`. NWListener and connections on `DispatchQueue(label: "com.cmux.bridge-server")`.
- `BridgeConnection`: Not Sendable. All I/O serialized on the bridge server queue. `dispatchToTerminalController` uses `DispatchQueue.main.async` per the socket command threading policy.
- `BridgePTYStream`: `@unchecked Sendable` + `NSLock`.
- `BridgeEventRelay`: `@unchecked Sendable` + `NSLock`.

### Security

- 32-byte random tokens via `SecRandomCopyBytes`, URL-safe base64 encoded
- Constant-time comparison with length-leak protection (padding to max length)
- Keychain storage with `kSecAttrAccessibleAfterFirstUnlock`
- Unauthenticated connections immediately disconnected on non-auth messages
- Bridge auth is independent of Unix socket password auth (separate security domains)

## Phase 2 Architecture (Current)

### Ghostty Fork — PTY Output Observer C API

Added `ghostty_surface_set_output_observer(surface, callback, userdata)` to the Ghostty C API. The callback fires on Ghostty's IO reader thread with raw PTY bytes before terminal processing.

| File | Change |
|---|---|
| `ghostty/include/ghostty.h` | `ghostty_io_output_observer_cb` typedef, `ghostty_surface_set_output_observer` declaration |
| `ghostty/src/apprt/embedded.zig` | `IoOutputObserverCallback` type alias, C export that routes through `surface.core_surface.io.setOutputObserver` |
| `ghostty/src/termio/Termio.zig` | Observer callback/userdata fields with atomic load/store, hook in `processOutput()` before mutex lock |

Thread safety: `setOutputObserver` uses `@atomicStore` with release ordering (userdata before callback). `processOutput` uses `@atomicLoad` with acquire ordering. This ensures the IO reader thread always sees consistent callback+userdata.

### PTY Output Observer Swift Wiring

| File | Purpose |
|---|---|
| `Sources/Bridge/BridgePTYObserverContext.swift` | Simple class holding `surfaceId: UUID`, passed as `Unmanaged` userdata to the C callback |
| `Sources/Bridge/BridgePTYStream.swift` | Observer lifecycle: registers Ghostty callback on first subscriber, unregisters on last disconnect |

The C callback trampoline (`ptyOutputCallback`) runs on Ghostty's IO reader thread. It only copies bytes to `Data` and dispatches to `BridgeServer.shared.broadcastPTYData()`. Memory management uses `Unmanaged.passRetained` on registration, `takeUnretainedValue` in the callback (no retain churn on hot path), and `.release()` on unregistration.

Surface cleanup: BridgePTYStream observes `.bridgeSurfaceClosed` to proactively remove subscriptions and release observer contexts when terminals are destroyed.

### PTY Write and Resize

- `surface.pty.write`: Accepts `data_base64` (base64 binary) or `data` (plain text). Dispatches to main thread, resolves surface via `resolveTerminalPanel`, writes raw bytes via `ghostty_surface_text`.
- `surface.pty.resize`: Stores mobile dimensions per-subscription (does NOT resize the desktop PTY). Returns desktop dimensions so the mobile client can adapt.

### Event Relay (11 Events)

BridgeEventRelay registers NotificationCenter observers in `start()` for 11 event types:

| Event | Source | Notification |
|---|---|---|
| `workspace.selected` | TabManager selectedTabId | `.ghosttyDidFocusTab` (existing) |
| `workspace.created` | TabManager addWorkspace | `.bridgeWorkspaceCreated` (new) |
| `workspace.closed` | TabManager closeWorkspace | `.bridgeWorkspaceClosed` (new) |
| `workspace.title_changed` | Workspace title mutations | `.bridgeWorkspaceTitleChanged` (new) |
| `pane.split` | Workspace didSplitPane | `.bridgePaneSplit` (new) |
| `pane.closed` | Workspace didClosePane | `.bridgePaneClosed` (new) |
| `pane.focused` | Workspace didFocusPane | `.bridgePaneFocused` (new) |
| `surface.focused` | Workspace applyTabSelection | `.ghosttyDidFocusSurface` (existing) |
| `surface.closed` | Workspace didCloseTab | `.bridgeSurfaceClosed` (new) |
| `surface.moved` | Workspace didMoveTab | `.bridgeSurfaceMoved` (new) |
| `surface.reordered` | Workspace didReorderTab | `.bridgeSurfaceReordered` (new) |
| `surface.title_changed` | GhosttyTerminalView | `.ghosttyDidSetTitle` (existing) |

### PTY Backpressure

`BridgePTYStream` implements per-surface coalescing: PTY bytes accumulate in a buffer and flush at most once per 16ms (~60fps). If the buffer exceeds 256KB before the timer fires, it flushes immediately. This prevents `cat /dev/urandom` from flooding the WebSocket with hundreds of frames per second.

### V2 API: `ports.list`

Returns all discovered listening ports across workspaces. Accepts optional `workspace_id` filter. Response: `{"ports": [{"port": 3000, "workspace_id": "...", "surface_id": "..."}]}`.

## Android Companion — App Architecture

### Component Hierarchy

```
CmuxCompanionApp (MaterialApp.router)
├── PairingScreen          — QR scanning, credential storage
└── TerminalScreen         — Main post-pairing screen (orchestrator)
    ├── TopBar             — Tab strip + pane type dropdown
    │   ├── TabBarStrip    — Scrollable surface tabs
    │   └── PaneTypeDropdown — Terminal/Browser/Files/Shell selector
    ├── GestureLayer       — Edge swipe, pinch, arrow swipe detection
    │   └── TerminalView   — Pure cell renderer (CustomPainter)
    ├── ModifierBar        — Esc/Ctrl/Alt/Tab + arrow keys + Enter
    ├── WorkspaceDrawer    — Left-edge drawer with workspace list
    │   └── WorkspaceTile  — Single workspace item
    ├── MinimapView        — Pinch-out overlay showing pane layout
    │   └── MinimapPane    — Proportional pane rectangle
    └── ConnectionOverlay  — Connecting/reconnecting/disconnected states
```

### Riverpod State Architecture

| Provider | Type | Purpose |
|----------|------|---------|
| `connectionManagerProvider` | `Provider<ConnectionManager>` | Singleton WebSocket connection lifecycle |
| `pairingServiceProvider` | `Provider<PairingService>` | Keychain credential management |
| `connectionStatusProvider` | `StreamProvider<ConnectionStatus>` | Reactive connection state stream |
| `isPairedProvider` | `FutureProvider<bool>` | Whether device has stored credentials |
| `workspaceProvider` | `StateNotifierProvider<WorkspaceNotifier, WorkspaceState>` | Workspace list + active workspace |
| `surfaceProvider` | `StateNotifierProvider<SurfaceNotifier, SurfaceState>` | Surfaces (tabs) in active workspace + focus |
| `paneProvider` | `StateNotifierProvider<PaneNotifier, PaneState>` | Pane layout for minimap |
| `eventHandlerProvider` | `Provider<EventHandler>` | Routes bridge events to notifiers |

### Event Flow

```
Mac Bridge → WebSocket → ConnectionManager.eventStream
                             ↓
                       EventHandler._onEvent()
                             ↓
              ┌──────────────┼──────────────┐
              ↓              ↓              ↓
      WorkspaceNotifier  SurfaceNotifier  PaneNotifier
              ↓              ↓              ↓
        WorkspaceDrawer   TabBarStrip    MinimapView
```

Events dispatched: `workspace.{created,closed,title_changed,selected}`, `surface.{focused,closed,title_changed,moved,reordered}`, `pane.{focused,split,closed}`.

### File Structure

```
lib/
├── app/
│   ├── colors.dart         — Design tokens (AppColors)
│   ├── theme.dart          — ThemeData + named text styles
│   ├── router.dart         — GoRouter: /pair, /terminal
│   └── providers.dart      — Connection-layer Riverpod providers
├── connection/
│   ├── connection_manager.dart  — WebSocket lifecycle + reconnection
│   ├── connection_state.dart    — ConnectionStatus enum
│   ├── message_protocol.dart    — BridgeRequest/Response/Event/Error
│   ├── pairing_service.dart     — QR parsing + secure storage
│   ├── pty_demuxer.dart         — Binary frame channel demux
│   └── request_tracker.dart     — Request/response ID tracking
├── state/
│   ├── workspace_provider.dart  — Workspace list + selection
│   ├── surface_provider.dart    — Surface (tab) tracking + focus
│   ├── pane_provider.dart       — Pane layout for minimap
│   └── event_handler.dart       — Event → notifier dispatch
├── terminal/
│   ├── terminal_screen.dart     — Orchestrator (top bar + view + bar)
│   ├── terminal_view.dart       — Pure cell renderer (CustomPainter)
│   ├── cell_frame_parser.dart   — Binary cell frame parser
│   ├── top_bar.dart             — Tab bar + pane type trigger
│   ├── tab_bar_strip.dart       — Scrollable surface tabs
│   └── modifier_bar.dart        — Esc/Ctrl/Alt/Tab + arrows
├── workspace/
│   ├── workspace_drawer.dart    — Left-edge workspace drawer
│   └── workspace_tile.dart      — Single workspace item
├── minimap/
│   ├── minimap_view.dart        — Full-screen minimap overlay
│   └── minimap_pane.dart        — Proportional pane tile
├── shared/
│   ├── connection_overlay.dart  — Connection state overlays
│   ├── gesture_layer.dart       — Gesture recognizers
│   └── pane_type_dropdown.dart  — Pane type selector dropdown
├── onboarding/
│   └── pairing_screen.dart      — Branded QR pairing screen
├── native/
│   ├── ghostty_vt.dart          — GhosttyKit terminal C API wrapper
│   └── ghostty_vt_bindings.dart — FFI bindings
└── main.dart                    — App entry point
```

### Key Design Decisions

**TerminalScreen as orchestrator:** The terminal screen owns the connection init, workspace fetch, surface sync, and input routing. TerminalView is a pure renderer that only subscribes to cell streams and paints — no navigation or state management.

**Gesture layer wraps terminal content:** GestureLayer sits between the Column layout and the TerminalView, intercepting edge swipes (drawer), pinches (minimap), and directional swipes (arrow keys) without interfering with the terminal's own tap-to-focus and keyboard handling.

**Pane type dropdown uses Overlay:** The dropdown is rendered as an OverlayEntry anchored via CompositedTransformTarget/Follower, so it floats above the tab bar without being clipped by the top bar's bounds.

**Connection overlay as Stack layer:** Connection states (connecting, reconnecting, disconnected) are overlaid on top of the terminal screen's Stack, not as separate routes. This means the terminal view stays mounted and can resume rendering immediately when connection is restored.

### Cell Sizing Pipeline (Keyboard-Stable)

The terminal text resize bug was caused by `TerminalPainter.paint()` re-deriving `cellHeight = size.height / rows` from the clamped paint area. When `adjustResize` shrinks the view for the on-screen keyboard, height decreases → cellHeight decreases → font shrinks.

**Fix:** Cell dimensions are derived from viewport width only (stable regardless of keyboard state) and passed to the painter as constructor parameters — never re-derived from the paint area.

```
cellWidth     = constraints.maxWidth / cols       // width-only derivation
cellHeight    = cellWidth * 1.75                  // constant aspect ratio
terminalHeight = cellHeight * rows                // full logical height
fontSize      = cellHeight * 0.72                 // tuned for JetBrains Mono
```

When the terminal's logical height exceeds the visible viewport (keyboard up), a `ClipRect` + `Transform.translate` scrolls to keep the cursor row visible:

```
visibleRows   = (constraints.maxHeight / cellHeight).floor()
maxScrollRow  = max(0, rows - visibleRows)
scrollRow     = clamp(cursorRow - visibleRows + 1, 0, maxScrollRow)
scrollOffsetY = scrollRow * cellHeight
```

The `adjustResize` setting in AndroidManifest.xml is preserved — the modifier bar naturally stays above the keyboard.

### Font

JetBrains Mono (SIL Open Font License) bundled in `assets/fonts/`. Four weights: Regular, Bold, Italic, BoldItalic. Registered in `pubspec.yaml` under `flutter.fonts`. The painter uses `fontFamily: 'JetBrains Mono'`.

### Cursor Rendering

- Filled block cursor with `PaintingStyle.fill`, 2px corner radius via `RRect`
- Color: `terminalCursorFill` (accentBlue at ~78% alpha)
- Character under cursor drawn in `terminalBg` color for inversion effect
- Blink: 530ms on/530ms off via `Timer.periodic`, phase resets on new cell frame

### Depth Effects

- Top bar: `BoxShadow(black26, blur 4, offset 0,1)` replaces hard 1px border
- Terminal inner shadow: 3px `LinearGradient` overlay at top edge
- Terminal vignette: `RadialGradient` overlay (transparent center, `#080B10` edges at ~16%)

## Phase 3 (Planned)

- Mobile-specific rendering hints using stored mobile dimensions
