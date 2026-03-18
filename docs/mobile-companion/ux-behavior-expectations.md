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

### Design Tokens (Merged Palette)

GitHub-dark backgrounds with selective vibrancy. All tokens in `lib/app/colors.dart`.

| Token | Hex | Usage |
|-------|-----|-------|
| bgPrimary | `#0D1117` | Main background |
| bgSecondary | `#161B22` | Cards, bars, elevated surfaces |
| bgTertiary | `#21262D` | Active states, key backgrounds |
| bgSurface | `#1C2128` | Inset panels |
| textPrimary | `#E6EDF3` | Primary text |
| textSecondary | `#8B949E` | Secondary text |
| textMuted | `#484F58` | Muted/disabled text |
| accentBlue | `#58A6FF` | Primary accent (tabs, links, active states) |
| accentGreen | `#3FB950` | Running/connected indicators |
| accentOrange | `#D29922` | Warnings, reconnecting |
| accentRed | `#F85149` | Errors, destructive |
| accentPurple | `#BC8CFF` | Shell type indicator |
| accentCyan | `#39D2C0` | Secondary accent |
| borderSubtle | `#30363D` | Default borders |
| borderActive | `#58A6FF` | Active/focused borders |

Radii: sm=6, md=10, lg=16, xl=20

### Terminal Screen Layout

```
┌─────────────────────────────┐
│ [☰][Tab Bar       ][Type ▼] │  40px — TopBar
├─────────────────────────────┤
│                             │
│  Terminal Content           │  flex:1 — TerminalView (pure renderer)
│  (gesture layer wraps this) │
│                             │
├─────────────────────────────┤
│ [Esc][Ctrl][Alt]  [←↓↑→][⏎]│  52px — ModifierBar
└─────────────────────────────┘
```

### Tab Bar Behavior

- Scrollable horizontal tab strip showing surfaces in the current workspace
- Active tab: bgTertiary background, 2px blue underline, blue text, bold weight
- Inactive tab: transparent background, textSecondary color
- Green dot on tabs with running processes
- Separated from pane type dropdown by 1px vertical divider

### Pane Type Dropdown

- Anchored to top bar trigger, 200px wide
- Items: Terminal (green), Browser (blue), Files (orange), Shell (purple)
- Active type has checkmark; non-terminal types show "Soon" label
- Scale animation 0.95→1.0 on open
- Tap outside to dismiss

### Modifier Bar Behavior

- Left group: Esc, Ctrl, Alt, Tab
- Right group: ← ↓ ↑ → arrow keys + Enter
- **Esc and Tab**: Momentary — fire escape sequence on tap
- **Ctrl and Alt**: Toggle — highlight active until next key, then auto-clear
- Key styling: bgTertiary bg, borderSubtle border, 36px height, radiusSm corners
- Active key: accentBlue bg + blue glow shadow

### Workspace Drawer

- 300px width, left edge, bgPrimary background
- Header: "WORKSPACES" (uppercase, 10px, textMuted)
- Workspace items: 52px height, 32x32 icon + name + panel count
- Active workspace: bgSurface bg + 2px right border accentBlue
- Scrim overlay rgba(0,0,0,0.5) when open
- Tap workspace → switch workspace, update tab bar, close drawer

### Minimap Overlay

- Triggered by pinch-out gesture on terminal area (scale < 0.7)
- Shows proportional pane layout from `workspace.layout` API
- Focused pane: chipBgActive bg, accentBlue border, glow shadow
- Pane labels: 9px, textSecondary
- Tap pane → dismiss minimap, focus that pane's surface
- Fade + scale animation on open/close

### Gesture Map

| Gesture | Trigger | Action |
|---------|---------|--------|
| Left edge swipe | Pan from x < 20px, velocity > 200 | Open workspace drawer |
| Pinch out | Scale < 0.7 | Show minimap overlay |
| Directional swipe | Velocity > 200 | Send arrow key escape sequence |

### Pairing Screen

- Dark branded background (bgPrimary)
- "cmux" wordmark at top, "Companion" subtitle
- Camera viewfinder with rounded corners and accentBlue corner markers
- Instruction text in textSecondary
- Error banners: accentRed background tint + red border
- Success animation: green check icon with elastic scale before navigating

### Connection State Overlays

Overlays the terminal screen (not separate routes):

| State | Visual | Action |
|-------|--------|--------|
| Connecting/Authenticating | Blue pulse ring + "Connecting to Mac..." | — |
| Reconnecting | Orange pulse ring + "Reconnecting..." | — |
| Disconnected | Cloud-off icon + "Connection lost" | Reconnect button |
