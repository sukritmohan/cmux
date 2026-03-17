# Mobile Companion — Development Architecture

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
| `Sources/Bridge/BridgePTYStream.swift` | Thread-safe subscription registry tracking which connections want PTY output from which surfaces. Phase 1 stub. |
| `Sources/Bridge/BridgeEventRelay.swift` | Event push to bridge clients. `emit(event:data:)` serializes to JSON and broadcasts. Phase 1 stub (no observers wired). |
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

## Phase 2 (Planned)

- Wire `BridgePTYStream` to actual PTY fd tee for real-time terminal output
- Wire `BridgeEventRelay` to NotificationCenter observers for workspace/surface/pane events
- Implement `surface.pty.write` and `surface.pty.resize` (currently stubs)
- Add `ports.list` if needed (PortScanner callback model makes aggregation non-trivial)
