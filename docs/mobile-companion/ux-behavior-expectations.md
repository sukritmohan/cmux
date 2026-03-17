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
