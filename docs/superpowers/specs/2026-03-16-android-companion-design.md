# cmux Android Companion App — Design Spec

**Date:** 2026-03-16
**Status:** Draft

## Progress

- **Mac-side bridge infrastructure:** Complete. 8 files, 12 events, PTY streaming, QR pairing — all merged to `main`.
- **Android / Flutter app:** 0% — no code written yet.
- **GhosttyKit Android feasibility:** GO. Zig cross-compiles to Android NDK targets. **Blocker:** GhosttyKit's C API (`lib-vt`) only exposes parsers (key events, OSC, SGR). A full Terminal/Screen C API is needed to power a rich terminal experience identical to desktop Ghostty. This is the next step before any Flutter work begins.

## Overview

A Flutter-based Android companion app that connects to a running cmux desktop instance on Mac over Tailscale, providing full real-time access to the desktop workflow from mobile. The app is a thin client — desktop cmux is the source of truth for all state.

## Goals

1. Continue cmux desktop workflow from an Android device on the move
2. Real-time access to all terminal surfaces, browser panels, and workspace state
3. Gesture-driven, terminal-first mobile experience
4. File system access to the Mac over Tailscale
5. Standalone mosh+tmux shell as a fallback

## Non-Goals

- Offline mode (requires Tailscale connection)
- State synchronization or local caching
- Building a standalone terminal multiplexer on Android
- iOS support (future consideration)

---

## System Architecture

```
+---------------------------------------------+
|  Android Device (Flutter App)               |
|                                             |
|  +----------+ +----------+ +------------+   |
|  | Terminal  | | Browser  | |   File     |   |
|  | (native) | | (WebView)| |  Manager   |   |
|  +----+-----+ +----+-----+ +-----+------+   |
|       |             |             |          |
|  +----+-------------+-------------+------+   |
|  |       cmux Connection Manager         |   |
|  |  (WebSocket client + mosh + SFTP)     |   |
|  +-------------------+-------------------+   |
+--------------------------+-------------------+
                           | Tailscale (WireGuard)
+--------------------------+-------------------+
|  Mac Desktop             |                   |
|                          |                   |
|  +-----------------------+---------------+   |
|  |   cmux-bridge (in-process WebSocket)  |   |
|  |   - Unix socket <-> WebSocket         |   |
|  |   - PTY stream forwarding             |   |
|  |   - QR pairing auth                   |   |
|  +-------------------+-------------------+   |
|                      |                       |
|  +-------------------+------+  +---------+   |
|  |  cmux (desktop app)      |  | mosh-   |   |
|  |  Unix socket API (V2)    |  | server  |   |
|  +---------------------------+  | + tmux  |   |
|                                 +---------+   |
+-----------------------------------------------+
```

### Connection Flows

| Flow | Protocol | Path |
|------|----------|------|
| Terminal (cmux surfaces) | WebSocket (PTY stream) | Android -> Tailscale -> cmux-bridge -> cmux internal API |
| cmux API (workspace state, commands) | WebSocket (JSON V2) | Android -> Tailscale -> cmux-bridge -> cmux internal API |
| Browser | HTTP/HTTPS | Android WebView -> Tailscale -> Mac localhost (or public URLs) |
| File manager | SFTP | Android -> Tailscale -> Mac SSH/SFTP (built-in Remote Login) |
| Standalone shell | mosh (UDP) | Android -> Tailscale -> mosh-server on Mac -> tmux |

### Security

- **Network layer:** Tailscale provides WireGuard encryption and device identity verification. Only devices on the user's tailnet can reach cmux-bridge.
- **Application layer:** One-time QR pairing flow. cmux desktop displays a QR code containing `{host, port, pairing_token}`. Android app scans the QR to establish a trusted pairing. The pairing token is stored in Android Keystore and sent as a bearer token on every WebSocket connection. This protects against compromised devices on shared tailnets, multi-user tailnets, or Tailscale ACL misconfigurations.
- **Token management:** Paired devices are listed in cmux Settings > Mobile. Tokens can be revoked individually. New pairing generates a fresh token.

---

## Mac-Side: cmux-bridge

An in-process WebSocket server running inside the cmux desktop app (Swift async task using NIOWebSocket or URLSessionWebSocketTask). This avoids the need for a separate binary, IPC overhead, and socket path discovery.

### Responsibilities

- WebSocket server on configurable TCP port (default: `17377`)
- Validates bearer token on WebSocket upgrade handshake
- Bidirectional JSON V2 message proxying via cmux's internal API (no Unix socket hop needed since it's in-process)
- PTY stream forwarding: tee raw PTY output for subscribed surfaces, forward as binary WebSocket frames
- Heartbeat/keepalive (ping every 15s, disconnect after 3 missed pongs)
- Event subscription relay for real-time state updates
- Auto-restart on crash (supervised async task)

### Lifecycle

- Started automatically when cmux launches (configurable in Settings > Mobile)
- Binds to `0.0.0.0:17377` (accessible on all interfaces including Tailscale)
- Runs as long as cmux is running
- Graceful shutdown when cmux quits (closes all WebSocket connections with 1001 Going Away)

---

## Mac-Side: New cmux Socket API Methods

The following new V2 API methods are required. All methods use UUID-based surface/workspace/pane identifiers (not session-scoped ref ordinals) to ensure stable addressing across bridge connections.

### `surface.pty.subscribe`

Subscribe to raw PTY output stream for a surface.

```json
{"id":"1","method":"surface.pty.subscribe","params":{"surface_id":"<uuid>"}}
```

Response: `{"id":"1","ok":true,"result":{"channel":1}}`. The `channel` integer identifies this subscription in subsequent binary frames.

**Binary frame format:** Each binary WebSocket frame begins with a 4-byte little-endian channel ID, followed by the raw PTY output bytes. This allows multiplexing multiple PTY subscriptions over a single WebSocket connection.

```
[channel: 4 bytes LE uint32][pty_data: remaining bytes]
```

**Error codes:** `surface_not_found`, `not_a_terminal`, `already_subscribed`

### `surface.pty.write`

Write raw bytes to a surface's PTY input (keystrokes, escape sequences).

```json
{"id":"2","method":"surface.pty.write","params":{"surface_id":"<uuid>","data_base64":"bHMgLWxhDQ=="}}
```

The `data_base64` field contains base64-encoded binary data, since PTY input can contain arbitrary bytes (control characters, escape sequences) that are not safe in JSON strings.

**Error codes:** `surface_not_found`, `not_a_terminal`, `pty_write_failed`

### `surface.pty.resize`

Notify cmux of the Android terminal view dimensions. This does NOT resize the desktop PTY (which would disrupt the desktop view). Instead, cmux stores the mobile dimensions per-subscription and uses them for mobile-specific rendering hints.

```json
{"id":"3","method":"surface.pty.resize","params":{"surface_id":"<uuid>","cols":80,"rows":24}}
```

**Design note:** The Android terminal emulator adapts to the desktop terminal's actual dimensions (received in the subscription response). If the mobile screen is narrower, horizontal scrolling or font scaling is used. The desktop PTY size is never changed by the mobile client.

### `surface.pty.unsubscribe`

Stop streaming PTY output for a surface.

```json
{"id":"4","method":"surface.pty.unsubscribe","params":{"surface_id":"<uuid>"}}
```

### `system.subscribe_events`

Subscribe to real-time state change events. All subscriptions are implicitly cancelled when the WebSocket connection drops (fire-and-forget, no acknowledgment required).

```json
{"id":"5","method":"system.subscribe_events","params":{}}
```

Events pushed as JSON text frames:

```json
{"event":"workspace.created","data":{"workspace_id":"<uuid>","name":"feature-auth","branch":"feat/auth"}}
{"event":"workspace.closed","data":{"workspace_id":"<uuid>"}}
{"event":"workspace.renamed","data":{"workspace_id":"<uuid>","name":"new-name"}}
{"event":"surface.created","data":{"surface_id":"<uuid>","pane_id":"<uuid>","type":"terminal","title":"zsh"}}
{"event":"surface.closed","data":{"surface_id":"<uuid>"}}
{"event":"surface.title_changed","data":{"surface_id":"<uuid>","title":"vim main.swift"}}
{"event":"notification.created","data":{"workspace_id":"<uuid>","title":"Claude Code","body":"Task complete","level":"info"}}
{"event":"pane.layout_changed","data":{"workspace_id":"<uuid>","panes":[{"pane_id":"<uuid>","x":0,"y":0,"width":0.5,"height":1.0,"surfaces":["<uuid>","<uuid>"]},{"pane_id":"<uuid>","x":0.5,"y":0,"width":0.5,"height":1.0,"surfaces":["<uuid>"]}]}}
```

### `system.unsubscribe_events`

Explicitly unsubscribe from events (optional — connection drop also unsubscribes).

```json
{"id":"6","method":"system.unsubscribe_events","params":{}}
```

### `workspace.layout`

Get the spatial pane layout for a workspace (pane positions and sizes as normalized fractions).

```json
{"id":"7","method":"workspace.layout","params":{"workspace_id":"<uuid>"}}
```

Response:

```json
{
  "id":"7","ok":true,
  "result":{
    "panes":[
      {"pane_id":"<uuid>","x":0,"y":0,"width":0.5,"height":1.0,"surfaces":[{"surface_id":"<uuid>","type":"terminal","title":"zsh","active":true},{"surface_id":"<uuid>","type":"terminal","title":"node"}]},
      {"pane_id":"<uuid>","x":0.5,"y":0,"width":0.5,"height":1.0,"surfaces":[{"surface_id":"<uuid>","type":"terminal","title":"server-log","active":true}]}
    ]
  }
}
```

### `ports.list`

List active listening ports detected across all workspaces (leverages existing PortScanner).

```json
{"id":"8","method":"ports.list","params":{}}
```

Response:

```json
{
  "id":"8","ok":true,
  "result":{
    "ports":[
      {"port":3000,"workspace_id":"<uuid>","process":"node","url":"http://localhost:3000"},
      {"port":8080,"workspace_id":"<uuid>","process":"python","url":"http://localhost:8080"}
    ]
  }
}
```

Used by the Android browser to show discovered local services for quick access.

---

## Android App: Technology Stack

| Component | Package/Technology |
|-----------|-------------------|
| Framework | Flutter (Dart) |
| Terminal emulator | **Primary:** GhosttyKit via NDK/JNI (same engine as desktop cmux and Echo SSH). **Fallback:** `xterm.dart` (pure Dart). Prototype both in Phase 1. |
| WebSocket client | `web_socket_channel` |
| Browser | `webview_flutter` (Android WebView) |
| SSH/SFTP | `dartssh2` |
| State management | `riverpod` |
| Local storage | `flutter_secure_storage` (pairing token, SSH keys in Android Keystore) |
| QR scanner | `mobile_scanner` |

**Terminal emulator strategy (inspired by Echo SSH):**

Echo SSH (by Replay Software) proves that Ghostty's rendering engine works beautifully on mobile — it ships GhosttyKit on iOS with Metal-accelerated rendering, producing desktop-quality terminal output on a phone. Since cmux already maintains a Ghostty fork, we should leverage the same engine on Android:

- **Primary path:** Build GhosttyKit for Android via NDK. Expose it to Flutter via JNI/FFI platform channel. This gives us Vulkan/OpenGL-accelerated rendering, identical escape sequence handling to desktop cmux, and the same theme/font system. The PTY stream from the Mac is fed directly into Ghostty's terminal state machine on the Android side.
- **Fallback path:** If GhosttyKit on Android proves infeasible in Phase 1 (Zig cross-compilation to Android, Vulkan surface integration with Flutter), fall back to `xterm.dart` — a pure-Dart terminal emulator that accepts raw byte streams without needing a local PTY.
- **NOT suitable:** `flutter_pty` (local PTY spawner, wrong architecture for thin client) and `xterm` WebView-wrapped (too much overhead).

---

## Android App: Navigation & UX

### Core Principle

Terminal-first, gesture-driven, zero chrome. The terminal fills the screen. Everything else is accessed via gestures.

### Screen States

#### 1. Default: Terminal View

```
+------------------------------------------+
| [zsh | node] . [server-log]    [T icon]  |  <- Pane-grouped tab strip + type dropdown (icon only)
|                                          |
|                                          |
|          Terminal content                 |
|          (full screen)                    |
|                                          |
|                                          |
| [(+)] [([_])]  [<][v][^][>]  [Enter]     |  <- Modifier key bar
+------------------------------------------+
```

- **Top bar:** Pane-grouped tab strip on left, pane type dropdown (icon only) on right
- **Content:** Terminal rendering PTY stream from focused surface
- **Bottom bar:** `[ (+) ] [ ([_]) ] [ < v ^ > ] [ Enter ]`
  - `(+)` fan-out: keyboard modifiers (Esc, Ctrl, Alt, Cmd, Tab). Tap modifier to toggle it — next keystroke sends modified key (e.g., Ctrl+C). Fan collapses after selection. **Customizable:** long-press `(+)` to configure which quick keys appear in the fan (users may want backtick, pipe, tilde, etc. depending on workflow — lesson from Echo SSH).
  - `([_])` fan-out: editing actions (Copy, Paste, Cut). Extensible for future actions (Select All, Undo). Fan collapses after action.
  - Arrow keys: always visible for one-tap input. **Additionally:** swipe gestures on the terminal area provide directional input — swipe left/right/up/down for arrow keys (inspired by Echo SSH's gesture-based arrow movement, more natural on touchscreens than tiny buttons).
  - Enter: always visible
- Tab groups separated by visual dot/divider: `[Pane 1: zsh | node] . [Pane 2: logs]`
- Terminal adapts to desktop PTY dimensions; if narrower than phone screen, uses available width. If wider, horizontal scroll or font scaling.

**Copy/paste behavior:**
- **Long press:** Begins text selection. User drags to select text. On drag end, a floating toolbar appears above the selection with `Copy | Paste` buttons.
  - If text is selected: tap Copy to copy selection to clipboard, or Paste to replace/insert clipboard contents.
  - If long press on empty area (no drag): floating toolbar shows `Paste` only, allowing quick paste of last clipboard contents at cursor position.
- **([_]) fan-out:** Also provides Copy, Paste, Cut as an alternative path. Copy copies the current selection (if any), Paste sends clipboard to the surface via `surface.pty.write`.
- **Cut:** Available in `([_])` fan and in the floating toolbar when applicable (e.g., text fields in browser view).

#### 2. Pane Type Dropdown (tap icon)

```
+------------------------------------------+
| [zsh | node] . [server-log]    [T icon]  |
|                          +------------+  |
|                          | * Terminal  |  |
|                          |   Browser   |  |
|                          |   Files     |  |
|                          |   Shell     |  |
|                          +------------+  |
|          (dimmed terminal)               |
| [(+)] [([_])]  [<][v][^][>]  [Enter]     |
+------------------------------------------+
```

- Icon-only when collapsed (saves horizontal space for tabs)
- Expanded dropdown shows full text labels with icons
- Active type has a checkmark
- Selecting a type switches the view; the new type's surfaces appear in the tab strip

#### 3. Browser View (after selecting Browser)

```
+------------------------------------------+
| [localhost | GitHub]           [B icon]   |  <- Browser tabs + type dropdown
| [< ] [> ] [ https://localhost:3000    ]  |  <- URL bar (top, standard browser pattern)
|                                          |
|          WebView content                 |
|                                          |
|                                          |
| [(+)] [([_])]  [<][v][^][>]  [Enter]     |  <- Same modifier bar
+------------------------------------------+
```

- URL bar positioned below tab strip (standard browser convention)
- Bottom bar: same modifier keys (for typing in web forms, consistent muscle memory)
- Swipe up for full keyboard (same as terminal)
- Discovered local ports (from `ports.list`) shown as suggestions when opening a new browser tab

#### 4. File Explorer View (after selecting Files)

```
+------------------------------------------+
| ~ > cmux > Sources             [F icon]  |  <- Breadcrumb path + type dropdown
|                                          |
| [folder] Sources/                        |
| [folder] Resources/                      |
| [swift]  AppDelegate.swift    471KB      |
| [swift]  Workspace.swift      214KB      |
| [json]   package.json         2KB        |
|                                          |
| [New File] [New Folder] [Sort]           |  <- File action bar
+------------------------------------------+
```

- Breadcrumb path replaces tab strip (no tabs in file explorer)
- SFTP-based file browsing of Mac filesystem
- File actions: create, rename, delete, upload, download
- Tap file to open in terminal (vim/cat) or markdown viewer

#### 5. Left Edge Swipe: Workspace Drawer

```
+------------------+
| WORKSPACES       |
|                  |
| * main           |  <- Active workspace (highlighted)
|   [main] 3 panes |
|   1 notification |
|                  |
|   feature-auth   |
|   [feat/auth]    |
|   2 panes        |
|                  |
|   bugfix-login   |
|   [fix/login]    |
|   1 pane         |
|                  |
|                  |
| [+ New Workspace]|
+------------------+
```

- Workspaces only
- Shows workspace name, git branch, pane count, notification badges
- Tap to switch workspace; tab strip updates to show new workspace's surfaces
- Kept in sync via `system.subscribe_events`

#### 6. Pinch Out: Minimap

```
+------------------------------------------+
|              WORKSPACE: main              |
|                                          |
|  +----------------+ +----------------+   |
|  |                | |                |   |
|  |   Pane 1       | |   Pane 2       |   |
|  |   zsh (active) | |   server-log   |   |
|  |   $ claude...  | |   listening:   |   |
|  |                | |   :3000        |   |
|  +----------------+ +----------------+   |
|  +-----------------------------------+   |
|  |            Pane 3                  |   |
|  +-----------------------------------+   |
|                                          |
|         Tap a pane to focus              |
+------------------------------------------+
```

- Shows actual desktop pane layout (proportions from `workspace.layout` response)
- Each pane shows tiny text preview (last few lines) and tab dots for surfaces
- Tap any pane to zoom back in, focusing that pane's first surface
- Tab strip scrolls to the tapped pane's group
- Pinch-in or tap to dismiss

#### 7. Keyboard Active (swipe up)

```
+------------------------------------------+
| [zsh | node] . [server-log]    [T icon]  |
|                                          |
|   Terminal (compressed)                  |
|                                          |
| [(+)] [([_])]  [<][v][^][>]  [Enter]     |  <- Modifier bar above keyboard
| +--------------------------------------+ |
| |  q  w  e  r  t  y  u  i  o  p       | |
| |   a  s  d  f  g  h  j  k  l         | |
| |     z  x  c  v  b  n  m             | |
| +--------------------------------------+ |
+------------------------------------------+
```

- Software keyboard slides up
- Modifier bar repositions above keyboard
- Terminal content compresses but stays visible
- Modifier keys are toggleable (Ctrl highlighted = next key sends Ctrl+key)

### Gesture Summary

| Gesture | Action |
|---------|--------|
| Left edge swipe | Workspace drawer |
| Pinch out | Minimap (desktop pane layout) |
| Swipe up | Show keyboard |
| Swipe down (on keyboard) | Hide keyboard |
| Top-right icon tap | Pane type dropdown |
| Tab tap/swipe | Switch surfaces within focused pane |
| Long press tab | Tab options (close, move, rename) |
| Long press terminal | Text selection with drag handles; floating Copy/Paste toolbar on release |
| Long press (no drag) | Floating Paste toolbar at cursor position |
| (+) fan tap | Keyboard modifiers: Esc, Ctrl, Alt, Cmd, Tab |
| ([_]) fan tap | Editing actions: Copy, Paste, Cut |
| Swipe on terminal (1-finger) | Arrow key input (left/right/up/down) |
| Long press (+) | Customize quick keys in fan-out |

---

## Android App: Connection Manager

### Initial Pairing

1. User opens cmux Settings > Mobile on desktop, clicks "Pair Device" — displays QR code
2. Android app scans QR code containing `{host: "<tailscale-ip>", port: 17377, token: "<pairing-token>"}`
3. App stores pairing in secure storage, connects WebSocket with bearer token
4. Desktop shows "Device paired: <device-name>" confirmation

### Connection Flow (after pairing)

1. App connects WebSocket to `ws://<host>:<port>` with `Authorization: Bearer <token>` header
2. On connect: sends `system.ping` to verify, then `system.tree` to get full state
3. Subscribes to `system.subscribe_events` for real-time updates
4. Subscribes to `surface.pty.subscribe` for the initially focused surface
5. Connection status indicator in top-left (green dot = connected, yellow = reconnecting, red = disconnected)

### Reconnection

- Automatic reconnect with exponential backoff (1s, 2s, 4s, 8s, max 30s)
- On reconnect: re-fetch full state via `system.tree`, re-subscribe to PTY streams
- During disconnect: show "Reconnecting..." banner, freeze terminal display (no stale data)

### App Lifecycle & Connection Persistence

Echo SSH users reported mosh sessions not resuming after iOS app suspension. Android has similar lifecycle challenges. Our approach:

- **WebSocket connection:** When app backgrounds, the WebSocket is kept alive via Android foreground service (with a persistent notification showing connection status). If the OS kills it, auto-reconnect on resume with full state re-sync via `system.tree`.
- **PTY subscriptions:** On background, pause PTY stream subscriptions (stop binary frames) to save bandwidth. On foreground, re-subscribe and request a screen buffer snapshot to catch up on missed output.
- **mosh sessions:** mosh is inherently resilient to app suspension (UDP, stateless protocol). Sessions resume automatically when the app returns. This is a key advantage of the mosh fallback.
- **Foreground service:** A lightweight foreground service keeps the connection alive for up to 10 minutes in background. After 10 minutes, the connection is gracefully closed and re-established on resume.

### Latency Management

- PTY output renders locally in the Flutter terminal emulator (no round-trip for display)
- Keystroke latency = network round-trip (10-30ms LAN, 50-150ms cellular via DERP relay)
- For interactive editing: standalone mosh+tmux session provides speculative local echo

---

## Android App: File Manager

### Implementation

- SFTP over Tailscale to Mac's built-in SSH server (enable "Remote Login" in System Settings)
- Uses `dartssh2` Flutter package for SFTP operations
- Connects with SSH key or password (stored securely in Android Keystore)

### Capabilities

- Browse Mac filesystem (home directory by default)
- View files (text, images, markdown)
- Create/rename/delete files and folders
- Upload files from Android to Mac
- Download files from Mac to Android
- Open files in terminal (sends `vim <path>` to a terminal surface via `surface.pty.write`)

---

## Android App: Standalone Shell (Mosh)

### Purpose

Fallback terminal for when you need:
- Speculative local echo (mosh predicts and renders keystrokes before server confirms)
- Raw shell access outside cmux's surface model
- Connection resilience (mosh survives IP changes, sleep/wake)

### Implementation

- mosh client compiled for Android (via NDK) or using an existing mosh Android library
- Connects to mosh-server on Mac over Tailscale
- tmux session for persistence (survives mosh disconnects)
- Appears as a pane type in the dropdown alongside Terminal/Browser/Files

### Prerequisites on Mac

- `mosh` installed (`brew install mosh`)
- SSH access enabled (System Settings > General > Sharing > Remote Login)
- tmux installed (`brew install tmux`)

---

## Implementation Phases

### Phase 1: Foundation (MVP)

**Mac-side:**
- cmux-bridge in-process WebSocket server (JSON V2 relay, pairing auth)
- QR pairing UI in cmux Settings > Mobile
- `workspace.layout` and `ports.list` API methods

**Android:**
- Flutter app skeleton with QR pairing and connection screen
- Workspace drawer showing live workspace list from cmux API
- Basic terminal view using standalone mosh+tmux (not PTY streaming)
- Connection manager with reconnection logic
- **Terminal engine prototype (critical path):** Investigate building GhosttyKit for Android via Zig cross-compilation to `aarch64-linux-android` and `x86_64-linux-android`. Build a minimal Flutter platform channel that renders a Ghostty surface in a native Android view (SurfaceView/TextureView). If GhosttyKit on Android is infeasible, fall back to `xterm.dart` and document why. This decision gates Phase 2.

### Phase 2: Integrated Terminal

**Mac-side:**
- `surface.pty.subscribe/write/resize/unsubscribe` API methods
- PTY output tee in cmux (read from Ghostty surface screen buffer or PTY fd)
- Binary WebSocket frame multiplexing in cmux-bridge
- `system.subscribe_events` / `system.unsubscribe_events`

**Android:**
- Flutter terminal emulator rendering PTY stream from cmux surfaces
- Pane-grouped tab strip with visual pane separators
- Pinch-out minimap with `workspace.layout` data
- Real-time state sync via event subscription
- Pane type dropdown (Terminal + Shell for now)

### Phase 3: Browser & Files

**Android:**
- Embedded Android WebView with tab management
- URL bar with navigation controls
- Discovered port suggestions (from `ports.list`)
- SFTP file manager with dartssh2
- File browsing, viewing, upload/download
- Pane type dropdown gains Browser + Files entries

### Phase 4: Polish

- Notification badges and push notifications (via Firebase + cmux event subscription)
- Gesture physics tuning
- Landscape mode support
- Connection diagnostics and troubleshooting UI
- Onboarding flow (Tailscale setup, Mac prerequisites check)
- Paired device management UI on desktop

---

## Resolved Decisions

1. **cmux-bridge:** In-process Swift (runs inside cmux app as an async task). Avoids separate binary, IPC overhead, and socket path discovery. Uses cmux's internal API directly.
2. **Authentication:** QR pairing flow with bearer token, stored in Android Keystore. Tailscale for network security, token for application-level auth.
3. **PTY resize:** Mobile client does NOT resize the desktop PTY. The Android terminal adapts to the desktop's dimensions. This prevents disrupting the desktop view.
4. **Binary multiplexing:** 4-byte LE channel ID header on binary WebSocket frames. Channel IDs assigned per `surface.pty.subscribe` response.
5. **ID format:** All API messages between Android and cmux-bridge use UUID-based identifiers (not session-scoped ref ordinals) for stable cross-connection addressing.
6. **Terminal engine:** GhosttyKit via NDK/JNI as primary (same engine as desktop cmux and Echo SSH app). `xterm.dart` as fallback. Prototype both in Phase 1 — GhosttyKit decision gates Phase 2.

## Design Inspiration

**Echo SSH** (by Replay Software) — an iOS SSH+mosh client built on Ghostty. Key patterns adopted:
- GhosttyKit as the terminal rendering engine on mobile (proven on iOS, we target Android)
- Customizable keyboard toolbar (fixed toolbars don't work — users need backtick, pipe, tilde, etc.)
- Gesture-based arrow key movement (swipe on terminal for directional input)
- Minimal, distraction-free UI philosophy (terminal-first, zero chrome)
- AI agent workflow as primary use case (Claude Code monitoring/approval from phone)

## Open Questions

1. **GhosttyKit on Android:** Can Zig cross-compile GhosttyKit to Android NDK targets? What graphics backend (Vulkan/OpenGL ES)? How to integrate with Flutter's rendering pipeline (Texture widget + platform view)?
2. **Mosh on Android:** Build from source via NDK, or find an existing Flutter/Android mosh package?
3. **Push notifications:** Should cmux-bridge push notifications via Firebase when the app is backgrounded, or only show them when the app is active?
4. **PTY output source:** Tee from the Ghostty surface's PTY file descriptor, or read from `ghostty_surface_screen` buffer? The former gives real-time stream; the latter gives snapshot. Need to investigate Ghostty API availability.
