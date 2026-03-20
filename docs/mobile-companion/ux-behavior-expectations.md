# Mobile Companion — UX Behavior Expectations

## Settings UI

### Location
Settings > Mobile Companion section (between Automation and Browser)

### Controls

1. **Enable Mobile Companion** — Toggle, default off. When toggled on, starts the WebSocket server. When toggled off, stops the server and disconnects all clients.

2. **Port** — Number field, default 17377. Only visible when enabled. Changes take effect on next server restart.

3. **Pair New Device** — Button that opens a sheet for pairing. Only visible when enabled.

4. **Paired Devices** — List of paired devices with name, last seen timestamp, and Revoke button. Only visible when enabled and devices exist.

### Pairing Flow

1. User clicks "Pair..."
2. Sheet opens with a device name text field
3. User enters a name (or uses default "Mobile Device")
4. User clicks "Generate Pairing Code"
5. QR code appears containing JSON: `{"host": "<tailscale-ip>", "port": 17377, "token": "<base64>"}`
6. User scans QR with companion app
7. User clicks "Done"
8. Device appears in paired devices list

### QR Code Content

The QR code encodes a JSON payload:
- `host`: The local Tailscale IP address (auto-detected from `utun` interfaces in the 100.x.x.x CGNAT range)
- `port`: The configured bridge port
- `token`: The pairing token (32-byte URL-safe base64)

If no Tailscale interface is found, `host` falls back to `"0.0.0.0"` (user must manually configure).

### Device Revocation

Clicking "Revoke" on a paired device immediately removes it from the Keychain. The companion app will be disconnected on next authentication attempt.

## Connection Behavior

### Authentication
- First WebSocket message must be `auth.pair` with the pairing token
- Invalid tokens result in immediate disconnection
- Valid tokens trigger `lastSeenAt` timestamp update

### Heartbeat
- Server pings every 15 seconds
- Client that misses 3 consecutive pongs is disconnected
- Network.framework handles pong replies automatically

### Command Proxy
- All V2 JSON-RPC commands are proxied through to `TerminalController.dispatchV2`
- Bridge-specific commands: `surface.pty.subscribe/unsubscribe/write/resize`, `system.subscribe_events/unsubscribe_events`
- PTY write/resize return "not_implemented" in Phase 1

## Localization

All user-facing strings use `String(localized:defaultValue:)` with keys prefixed `settings.bridge.*`.

## Android Companion — Design System

### Visual Identity

Warm amber identity replacing the original GitHub Dark blue-accent palette. Dual dark/light theme support via `AppColors.of(context)`. Source of truth: `docs/mobile-ux/pane-type-switcher-final.html`.

### Color System (Dual Theme)

All tokens in `lib/app/colors.dart`. Access via `AppColors.of(context)` which returns `AppColorScheme` matching current brightness.

**Dark theme (default):**

| Token | Value | Usage |
|-------|-------|-------|
| bgDeep | `#0A0A0F` | Deepest background (terminal area) |
| bgPrimary | `#0E0E14` | Main background |
| bgElevated | `#16161E` | Cards, bars, elevated surfaces |
| bgSurface | `#1A1A24` | Active states, panels |
| textPrimary | `#E8E8EE` | Primary text |
| textSecondary | `#E8E8EE` 55% | Secondary text |
| textMuted | `#E8E8EE` 30% | Muted/disabled text |
| accent | `#E0A030` | Signature warm amber accent |
| accentText | `#F0C060` | Amber text on dark bg |

**Light theme:**

| Token | Value | Usage |
|-------|-------|-------|
| bgDeep | `#F5F5F0` | Deepest background |
| bgPrimary | `#FAFAF7` | Main background |
| bgElevated | `#FFFFFF` | Cards, bars |
| bgSurface | `#F0F0EB` | Active states |
| textPrimary | `#1A1A1F` | Primary text |
| accentText | `#B07810` | Amber text on light bg |

**Pane type colors (dark/light):**

| Pane Type | Dark | Light |
|-----------|------|-------|
| Terminal | `#50C878` | `#1B8C4E` |
| Browser | `#5B9BD5` | `#2D6AB0` |
| Files | `#E0A030` | `#B07810` |
| Overview | `#B08CDC` | `#7A5AAE` |

Radii: xs=4, sm=6, md=10, lg=14, xl=20

### Font Families

- **JetBrains Mono**: Headings, labels, section headers (bundled TTF)
- **IBM Plex Sans**: Body text, UI controls (via google_fonts)
- **IBM Plex Mono**: Code, tab labels, monospace content (via google_fonts)

### Terminal Screen Layout

```
┌─────────────────────────────┐
│ [☰][Tab Bar      ][PaneIcon]│  42px — TopBar
├─────────────────────────────┤
│                             │
│  Pane Content (per type)    │  flex:1 — Terminal/Browser/Files
│  (gesture layer on terminal)│
│                             │
├─────────────────────────────┤
│ [+][📋] │ [↑] │ RETURN     │  42px — Floating Capsule ModifierBar
│         │[←↓→]│            │  (terminal + browser only)
└─────────────────────────────┘
```

### Pane Type Switching

- Active pane type stored as `_activePaneType` state in TerminalScreen
- Switching types changes the content area: Terminal → TerminalView, Browser → BrowserView, Files → FileExplorerView
- Overview type opens the minimap overlay (not inline content)
- ModifierBar shown only for Terminal and Browser types
- Tab strip adapts: terminal mode shows surface tabs, browser mode shows static "localhost"/"GitHub" tabs

### Tab Bar Behavior

- Font: IBM Plex Mono 11.5px, weight 500, 0.2px letter spacing
- Active tab: textPrimary color, bgSurface background, amber underline (2px)
- Inactive tab: textMuted color, transparent background
- Connection dot: 5px green circle before active tab title (when process running)
- Right-edge fade gradient (32px) hinting at scrollability
- Browser mode: static tabs "localhost" (active) + "GitHub"

### Pane Type Dropdown

- Trigger: 36x36 icon-only button, tinted with pane type color/bg
- Dropdown: 200px wide, 14px radius, bgElevated bg, 4px padding
- Items: 28x28 colored icon bg + label + checkmark for active
- Active item: 3px amber left bar indicator
- Scrim: 40% black (dark) / 10% (light)
- All types functional (no "Coming soon" — Browser/Files show placeholder views)
- Four types: Terminal, Browser, Files, Overview

### Modifier Bar Behavior (Floating Capsule)

- **Shape**: Floating capsule, rounded 18px, backdrop blur(24px)
- **Position**: Margin 0 8px 2px, floats above home indicator
- **Background**: Semi-transparent (dark: rgba(16,16,24,0.82), light: rgba(255,255,255,0.75))
- **Three zones** separated by 1px dividers:
  1. **(+) amber accent button** + clipboard paste button (38x32, rounded 10px)
  2. **Inverted-T arrow grid** (3x2, 26px cells, rounded 6px, borderless)
  3. **"RETURN" key** (JetBrains Mono 9px, 700 weight, uppercase, 1.2px spacing)
- All keys: 32px height, rounded 10px, borderless
- Press animation: AnimatedScale 0.93 on tap
- Haptic: selectionClick on arrows, lightImpact on RETURN, mediumImpact on (+)
- The (+) fan-out button will expand to show Esc/Ctrl/Alt/Tab (future)

### Terminal Rendering

- **Font**: JetBrains Mono (Regular, Bold, Italic, BoldItalic) — bundled, SIL Open Font License
- **Cell aspect ratio**: 1.75:1 (width:height) — yields ~15-18 visible rows in portrait
- **Font sizing**: fontSize = cellHeight * 0.72, tuned for JetBrains Mono's larger x-height
- **Keyboard stability**: Cell dimensions derived from viewport width only (not height). When the on-screen keyboard appears via adjustResize, height shrinks but width stays constant — text size never changes
- **Cursor auto-scroll**: When keyboard reduces visible area, the terminal auto-scrolls via clip + translate to keep the cursor row visible
- **Cursor style**: Filled block with 2px corner radius, ~80% alpha amber (`#E0A030`), slightly transparent
- **Character inversion**: Character under cursor drawn in terminalBg color for contrast
- **Cursor blink**: 530ms on/530ms off cycle, resets on new cell frame (content/cursor change)
- **Background fill**: Painter fills entire canvas with terminalBg first to prevent gaps

### Depth & Atmosphere

- **Top bar shadow**: Soft BoxShadow (black26, blur 4, offset 0,1) replaces hard 1px bottom border
- **Inner shadow**: 3px gradient at terminal top edge (black at 15% → transparent) — terminal feels recessed below chrome
- **Subtle vignette**: Radial gradient on terminal content (center = transparent, edges = #080B10 at ~16% alpha) — adds richness

### Workspace Drawer

- 280px width, left edge, frosted glass (BackdropFilter blur 40px)
- Background: semi-transparent (dark: rgba(14,14,20,0.92), light: rgba(250,250,247,0.92))
- Header: "WORKSPACES" (JetBrains Mono, 10px, 600 weight, 2.5px spacing, textMuted)
- Search bar: 34px, magnifier icon, "Search workspaces..." placeholder, filters list
- Workspace items: name + panel count metadata row + optional branch badge
- Active workspace: bgSurface bg + 3px amber left bar (c.accent, not blue right border)
- Branch badge: IBM Plex Mono 10.5px, rounded 4px, accentGlow bg, accentText text
- Notification badge: 18px amber circle with white count text (if notificationCount > 0)
- Bottom pinned section:
  - Appearance toggle: segmented "Dark"/"Light" control dispatching to themeModeProvider
  - "+ New Workspace" button: bordered, textMuted placeholder

### Minimap Overlay

- Triggered by pinch-out gesture on terminal area (scale < 0.7) or Overview pane type
- Dot grid background: 1px dots, 20px grid, textMuted at ~15% alpha
- Header: "WORKSPACE" label + workspace name (20px semibold) + LIVE badge (pulsing green dot, 2s cycle)
- Optional branch badge in header
- 16:10 aspect ratio pane layout container, bgElevated bg, border
- Pane cards: bgElevated, type-color dot (6px) + IBM Plex Mono title (9px)
- Focused pane: amber border + amber glow shadow
- Stacked cards for surfaceCount > 1: pseudo-layers at -4px/-8px offsets
- Stack badge: 18px amber circle with count, top-right
- Hint: "Tap a pane to focus · Pinch in to dismiss"
- Fade + scale animation on open/close

### Browser View (Placeholder)

- URL bar: back/forward nav buttons (28x28) + URL field (30px, rounded 6px, bgSurface)
- URL text: scheme at 40% opacity + host (textPrimary) + path (textSecondary)
- Content area: shimmer-style placeholder blocks mimicking a web page
- No live functionality yet (Mac API integration pending)

### File Explorer View (Placeholder)

- Breadcrumb bar: IBM Plex Mono path segments ("~" > "cmux" > "Sources"), current bold
- File list: typed icons (folder=amber, swift=blue, json=purple) + name + size/chevron
- File action bar: "+ New File", "+ New Folder", "Sort" buttons
- Static mock data: 3 folders, 3 Swift files, 1 JSON file
- No live functionality yet (Mac API integration pending)

### Gesture Map

| Gesture | Trigger | Action |
|---------|---------|--------|
| Left edge swipe | Pan from x < 20px, velocity > 200 | Open workspace drawer |
| Pinch out | Scale < 0.7 | Show minimap overlay |
| Horizontal swipe | Direction-locked horizontal on terminal surface | Switch tabs (see below) |
| Directional swipe | Velocity > 200 | Send arrow key escape sequence |

### Swipe-to-Switch-Tabs

Horizontal swipe gestures on the terminal surface switch between tabs with interactive drag tracking and slide animations.

**Scope:**
- Only active on the terminal surface (not keyboard, modifier bar, tab bar, or non-terminal panes)
- Only active when multiple tabs exist (single-tab suppresses the gesture entirely)

**Direction lock:**
- First ~10px of finger movement determines axis (horizontal vs vertical)
- Once locked, the other axis is ignored for the remainder of the gesture
- Edge swipes (x < 20px) bypass direction lock entirely and always open the drawer

**Interactive drag:**
- Terminal content translates 1:1 with finger position
- Adjacent terminal's last known content (static snapshot) slides in from the edge
- Tab bar underline crossfades between current and target tab proportionally

**Commit vs cancel:**
- Commit: displacement > 35% of terminal width, OR velocity > 800 px/s
- Cancel: below both thresholds, springs back to center
- Edge behavior: rubber-band bounce (0.3x dampening) at first/last tab

**Haptic feedback:**
- Light haptic at 35% threshold crossing
- Medium haptic on commit
- No haptic on cancel or rubber-band

**Animation:**
- Spring-based animations for commit (~300ms, slight overshoot), cancel (snappier), and rubber-band (tight bounce)
- New touch during animation snaps the in-flight animation to its end state

**State sync:**
- On commit, sends `surface.focus` RPC to desktop to keep state in sync
- Scroll remainder resets on tab switch
- Text selection cleared on swipe start

### Pairing Screen

- Branded background (bgPrimary, adapts to dark/light)
- "cmux" wordmark at top, "Companion" subtitle
- Camera viewfinder with rounded corners and amber corner markers (c.accent)
- Instruction text in textSecondary
- Error banners: red (#F85149) background tint + red border
- Success animation: green check icon with elastic scale before navigating

### Connection State Overlays

Overlays the terminal screen (not separate routes):

| State | Visual | Action |
|-------|--------|--------|
| Connecting/Authenticating | Amber pulse ring + "Connecting to Mac..." | — |
| Reconnecting | Orange pulse ring + "Reconnecting..." | — |
| Disconnected | Cloud-off icon + "Connection lost" | Reconnect button |
