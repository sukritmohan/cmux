# Pane Attention Notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect when terminal panes need user attention (bell, output silence, output activity) and deliver notifications on desktop (dock badge + sound) and Android companion (push + in-app badge).

**Architecture:** A per-surface state machine (`SurfaceActivityTracker`) observes output timestamps from Ghostty's `SET_TITLE` action callback (fires on each shell prompt/command change, providing a lightweight existing signal) and the `RING_BELL` action. The tracker runs fixed-interval polling timers on a dedicated serial dispatch queue to detect silence/activity transitions. Notification delivery goes through the existing `TerminalNotificationStore` (new attention-specific path that skips macOS banners) and `BridgeEventRelay` (new `surface.attention` event to Android).

**Tech Stack:** Swift (macOS app), Dart/Flutter (Android companion), Ghostty C API callbacks, `DispatchSource` timers, Riverpod state management, `flutter_local_notifications` plugin.

**Spec:** `docs/superpowers/specs/2026-03-19-pane-attention-notifications-design.md`
**UX:** `docs/pane-attention/ux-behavior-expectations.md`
**Architecture doc:** `docs/pane-attention/development-architecture.md`

---

## File Map

### New Files

| File | Responsibility |
|---|---|
| `Sources/SurfaceActivityTracker.swift` | Per-surface state machine, timer management, output timestamp tracking, attention trigger logic |
| `Sources/AttentionConfiguration.swift` | Global attention settings (UserDefaults-backed), threshold constants, hot-reload support |
| `android-companion/lib/notifications/attention_notification_handler.dart` | Handles `surface.attention` bridge events, triggers Android system notifications, manages notification channels |

### Modified Files

| File | What Changes |
|---|---|
| `Sources/GhosttyTerminalView.swift` | Hook `GHOSTTY_ACTION_SET_TITLE` to post output-detected timestamp. Hook `GHOSTTY_ACTION_RING_BELL` (surface-target) to call `SurfaceActivityTracker.triggerBellAttention`. |
| `Sources/TerminalNotificationStore.swift` | Add `TerminalNotification.Kind` enum (`.standard` vs `.attention`). Add `addAttentionNotification()` method that increments badge + plays sound but skips `UNUserNotificationCenter` banner. |
| `Sources/Bridge/BridgeEventRelay.swift` | Add `.bridgeSurfaceAttention` notification name. Register observer #13 for `surface.attention` event emission. |
| `Sources/TerminalController.swift` | Add V2 API commands: `attention.configure`, `attention.status`, `attention.enable`, `attention.disable`. |
| `CLI/cmux.swift` | Add `cmux attention` subcommand with `enable`, `disable`, `config`, `status` sub-actions. |
| `android-companion/lib/state/event_handler.dart` | Route `surface.attention` events to attention notification handler. |
| `android-companion/lib/state/workspace_provider.dart` | Add `attentionCount` field to `Workspace` model. Add methods to increment/clear attention state. |
| `android-companion/pubspec.yaml` | Add `flutter_local_notifications` dependency. |

---

## Critical Constraints (from CLAUDE.md)

1. **Typing-latency paths are sacred.** The output detection hook goes in `GHOSTTY_ACTION_SET_TITLE` handler (already fires on shell prompt changes). The only work added is a single function call that writes a timestamp. Do NOT touch `hitTest()`, `TabItemView` body, or `forceRefresh()`.
2. **Socket threading policy.** `SurfaceActivityTracker` timers and state transitions run on a dedicated serial dispatch queue. Only the final notification delivery dispatches to main via `async`.
3. **No content inspection.** The tracker only knows *when* output-related actions fire, never *what* the terminal content says.
4. **All panes tracked.** Focus state gates notification delivery, not state machine transitions.
5. **Test quality policy.** No tests that grep source files or check plist entries. Tests must verify runtime behavior through executable paths.

---

## Task 1: AttentionConfiguration — Global Settings Store

### Description
Create the configuration store for attention thresholds. This is a pure data/settings layer with no dependencies on Ghostty or the tracker.

**Files:**
- Create: `Sources/AttentionConfiguration.swift`

- [ ] **Step 1: Create `AttentionConfiguration.swift` with settings enum**

```swift
// Sources/AttentionConfiguration.swift

import Foundation

/// Global configuration for pane attention notifications.
/// All thresholds are global in v1 (no per-pane overrides).
/// Values are UserDefaults-backed with hot-reload: changes take effect on the
/// next state transition (active timers complete with the value they started with).
enum AttentionConfiguration {
    // MARK: - UserDefaults Keys

    static let enabledKey = "attentionEnabled"
    static let silenceThresholdKey = "attentionSilenceThreshold"
    static let idleThresholdKey = "attentionIdleThreshold"
    static let cooldownKey = "attentionCooldown"
    static let bellCooldownKey = "attentionBellCooldown"

    // MARK: - Defaults

    static let defaultEnabled = true
    static let defaultSilenceThreshold: TimeInterval = 30
    static let defaultIdleThreshold: TimeInterval = 5
    static let defaultCooldown: TimeInterval = 60
    static let defaultBellCooldown: TimeInterval = 5

    // MARK: - Readers

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func silenceThreshold(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: silenceThresholdKey)
        return value > 0 ? value : defaultSilenceThreshold
    }

    static func idleThreshold(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: idleThresholdKey)
        return value > 0 ? value : defaultIdleThreshold
    }

    static func cooldown(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: cooldownKey)
        return value > 0 ? value : defaultCooldown
    }

    static func bellCooldown(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: bellCooldownKey)
        return value > 0 ? value : defaultBellCooldown
    }

    // MARK: - Writers (for socket/CLI configuration)

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func setSilenceThreshold(_ value: TimeInterval, defaults: UserDefaults = .standard) {
        guard value > 0 else { return }
        defaults.set(value, forKey: silenceThresholdKey)
    }

    static func setIdleThreshold(_ value: TimeInterval, defaults: UserDefaults = .standard) {
        guard value > 0 else { return }
        defaults.set(value, forKey: idleThresholdKey)
    }

    static func setCooldown(_ value: TimeInterval, defaults: UserDefaults = .standard) {
        guard value > 0 else { return }
        defaults.set(value, forKey: cooldownKey)
    }

    static func setBellCooldown(_ value: TimeInterval, defaults: UserDefaults = .standard) {
        guard value > 0 else { return }
        defaults.set(value, forKey: bellCooldownKey)
    }

    /// Returns a snapshot of all current configuration values.
    static func snapshot(defaults: UserDefaults = .standard) -> ConfigSnapshot {
        ConfigSnapshot(
            enabled: isEnabled(defaults: defaults),
            silenceThreshold: silenceThreshold(defaults: defaults),
            idleThreshold: idleThreshold(defaults: defaults),
            cooldown: cooldown(defaults: defaults),
            bellCooldown: bellCooldown(defaults: defaults)
        )
    }

    struct ConfigSnapshot {
        let enabled: Bool
        let silenceThreshold: TimeInterval
        let idleThreshold: TimeInterval
        let cooldown: TimeInterval
        let bellCooldown: TimeInterval

        /// Serializes to a dictionary suitable for V2 API / bridge responses.
        func toDictionary() -> [String: Any] {
            [
                "enabled": enabled,
                "silence_threshold": silenceThreshold,
                "idle_threshold": idleThreshold,
                "cooldown": cooldown,
                "bell_cooldown": bellCooldown,
            ]
        }
    }
}
```

- [ ] **Step 2: Verify the file compiles**

Run (tagged build, compile-only):
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-config build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/AttentionConfiguration.swift
git commit -m "feat(attention): add AttentionConfiguration settings store

Global UserDefaults-backed configuration for pane attention thresholds.
Supports hot-reload: changes take effect on next state transition."
```

---

## Task 2: SurfaceActivityTracker — Core State Machine

### Description
Create the per-surface state machine that tracks output timestamps, runs silence-check polling timers, and fires attention triggers. This is the heart of the feature. No Ghostty dependencies — it receives timestamps from external callers.

**Files:**
- Create: `Sources/SurfaceActivityTracker.swift`

- [ ] **Step 1: Create `SurfaceActivityTracker.swift` with the state machine**

```swift
// Sources/SurfaceActivityTracker.swift

import Foundation

/// Reason a surface triggered an attention notification.
enum AttentionReason: String {
    case bell = "bell"
    case silence = "silence"
    case activity = "activity"

    /// Human-readable description for notification bodies.
    var displayDescription: String {
        switch self {
        case .bell: return String(localized: "attention.reason.bell", defaultValue: "Terminal bell")
        case .silence: return String(localized: "attention.reason.silence", defaultValue: "Output stopped (may need input)")
        case .activity: return String(localized: "attention.reason.activity", defaultValue: "New output started")
        }
    }
}

/// Callback invoked when a surface triggers an attention notification.
/// Called on the tracker's serial queue — callers must dispatch to main if needed.
typealias AttentionCallback = (
    _ surfaceId: UUID,
    _ tabId: UUID,
    _ reason: AttentionReason,
    _ surfaceTitle: String
) -> Void

/// Tracks per-surface output activity and fires attention notifications
/// based on silence/activity heuristics and bell signals.
///
/// **Threading:** All state mutations and timer callbacks run on a dedicated
/// serial dispatch queue (`trackerQueue`). The only main-thread interaction
/// is the final attention callback dispatch. Per-output cost is O(1): a single
/// timestamp write when in ACTIVE state.
///
/// **All panes are tracked** (focused and unfocused). Focus state only gates
/// notification delivery, not state machine transitions.
final class SurfaceActivityTracker {
    static let shared = SurfaceActivityTracker()

    /// Polling interval for the silence check timer (seconds).
    /// The timer fires at this interval and checks `now - lastOutputAt >= silenceThreshold`.
    static let silenceCheckInterval: TimeInterval = 5.0

    // MARK: - Per-Surface State

    enum SurfaceState: String {
        case idle
        case active
        case silentAfterActive = "silent_after_active"
    }

    struct SurfaceActivityState {
        var state: SurfaceState = .idle
        var lastOutputAt: Date = .distantPast
        var isFocused: Bool = true
        var tabId: UUID
        var surfaceTitle: String = ""

        /// Timestamp of last general attention notification for cooldown.
        var lastAttentionAt: Date = .distantPast
        /// Timestamp of last bell attention for bell-specific cooldown.
        var lastBellAttentionAt: Date = .distantPast

        /// The silence check polling timer (fires every `silenceCheckInterval`).
        /// Created on IDLE -> ACTIVE, cancelled on ACTIVE -> SILENT_AFTER_ACTIVE.
        var silenceCheckTimer: DispatchSourceTimer?

        /// One-shot cooldown timer that transitions SILENT_AFTER_ACTIVE -> IDLE.
        var cooldownTimer: DispatchSourceTimer?
    }

    // MARK: - Private State

    /// Dedicated serial queue for all state mutations and timer callbacks.
    /// Keeps the hot path off the main thread (per socket threading policy).
    private let trackerQueue = DispatchQueue(
        label: "com.cmuxterm.surface-activity-tracker",
        qos: .utility
    )

    /// Per-surface state, keyed by surface UUID. Accessed only on `trackerQueue`.
    private var surfaces: [UUID: SurfaceActivityState] = [:]

    /// Callback fired when a surface triggers attention. Set during initialization.
    var onAttention: AttentionCallback?

    private init() {}

    // MARK: - Public API (thread-safe, dispatches to trackerQueue)

    /// Register a new surface for tracking. Call when a surface is created.
    /// Surfaces start in IDLE state and focused.
    func registerSurface(surfaceId: UUID, tabId: UUID, isFocused: Bool = true) {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            guard self.surfaces[surfaceId] == nil else { return }
            self.surfaces[surfaceId] = SurfaceActivityState(
                tabId: tabId,
                isFocused: isFocused
            )
        }
    }

    /// Unregister a surface when it is destroyed. Cancels all timers.
    func unregisterSurface(surfaceId: UUID) {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            self.cancelTimers(for: surfaceId)
            self.surfaces.removeValue(forKey: surfaceId)
        }
    }

    /// Called when output-related activity is detected on a surface.
    /// This is the hot path: when state is ACTIVE, the only work is a timestamp write.
    func recordOutput(surfaceId: UUID, title: String? = nil) {
        guard AttentionConfiguration.isEnabled() else { return }

        trackerQueue.async { [weak self] in
            guard let self else { return }
            guard var surfaceState = self.surfaces[surfaceId] else { return }

            let now = Date()
            if let title { surfaceState.surfaceTitle = title }

            switch surfaceState.state {
            case .idle:
                let idleThreshold = AttentionConfiguration.idleThreshold()
                let idleDuration = now.timeIntervalSince(surfaceState.lastOutputAt)
                let wasIdleLongEnough = idleDuration >= idleThreshold

                surfaceState.lastOutputAt = now
                surfaceState.state = .active
                self.surfaces[surfaceId] = surfaceState

                // Start the silence check polling timer
                self.startSilenceCheckTimer(surfaceId: surfaceId)

                // Fire activity attention if idle long enough AND unfocused
                if wasIdleLongEnough && !surfaceState.isFocused {
                    self.fireAttention(
                        surfaceId: surfaceId,
                        state: &self.surfaces[surfaceId]!,
                        reason: .activity
                    )
                }

            case .active:
                // Hot path: single timestamp write, no timer manipulation
                surfaceState.lastOutputAt = now
                if let title { surfaceState.surfaceTitle = title }
                self.surfaces[surfaceId] = surfaceState

            case .silentAfterActive:
                // Output resumed during cooldown — go back to active
                surfaceState.lastOutputAt = now
                surfaceState.state = .active
                self.cancelCooldownTimer(for: surfaceId)
                self.surfaces[surfaceId] = surfaceState
                self.startSilenceCheckTimer(surfaceId: surfaceId)
            }
        }
    }

    /// Update focus state for a surface. Focus gates notification delivery,
    /// not state transitions. If unfocusing a surface in SILENT_AFTER_ACTIVE
    /// or ACTIVE-but-silent state, attention fires immediately.
    func updateFocus(surfaceId: UUID, isFocused: Bool) {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            guard var surfaceState = self.surfaces[surfaceId] else { return }

            let wasFocused = surfaceState.isFocused
            surfaceState.isFocused = isFocused
            self.surfaces[surfaceId] = surfaceState

            // When unfocusing: check if we should fire immediately
            if wasFocused && !isFocused {
                if surfaceState.state == .silentAfterActive {
                    // Was silent while focused — fire now
                    self.fireAttention(
                        surfaceId: surfaceId,
                        state: &self.surfaces[surfaceId]!,
                        reason: .silence
                    )
                } else if surfaceState.state == .active {
                    // Check if currently silent (output stopped while focused)
                    let silenceThreshold = AttentionConfiguration.silenceThreshold()
                    let silenceDuration = Date().timeIntervalSince(surfaceState.lastOutputAt)
                    if silenceDuration >= silenceThreshold {
                        self.transitionToSilentAfterActive(surfaceId: surfaceId)
                    }
                }
            }
        }
    }

    /// Update the tabId for a surface (when moved between workspaces).
    func updateTabId(surfaceId: UUID, tabId: UUID) {
        trackerQueue.async { [weak self] in
            self?.surfaces[surfaceId]?.tabId = tabId
        }
    }

    /// Immediate bell attention, bypassing the state machine.
    /// Subject to bell-specific 5-second cooldown.
    func triggerBellAttention(surfaceId: UUID, tabId: UUID, surfaceTitle: String) {
        guard AttentionConfiguration.isEnabled() else { return }

        trackerQueue.async { [weak self] in
            guard let self else { return }
            guard var surfaceState = self.surfaces[surfaceId] else {
                // Surface not yet registered — register and fire
                var newState = SurfaceActivityState(tabId: tabId)
                newState.surfaceTitle = surfaceTitle
                newState.isFocused = false
                self.surfaces[surfaceId] = newState
                self.fireAttention(
                    surfaceId: surfaceId,
                    state: &self.surfaces[surfaceId]!,
                    reason: .bell
                )
                return
            }

            // Bell fires regardless of focus, but check bell cooldown
            let bellCooldown = AttentionConfiguration.bellCooldown()
            let timeSinceLastBell = Date().timeIntervalSince(surfaceState.lastBellAttentionAt)
            guard timeSinceLastBell >= bellCooldown else { return }

            // Only notify if unfocused
            guard !surfaceState.isFocused else { return }

            surfaceState.surfaceTitle = surfaceTitle
            self.surfaces[surfaceId] = surfaceState

            self.fireAttention(
                surfaceId: surfaceId,
                state: &self.surfaces[surfaceId]!,
                reason: .bell
            )
        }
    }

    /// Returns a snapshot of all tracked surfaces (for `attention.status` API).
    func statusSnapshot(completion: @escaping ([UUID: SurfaceActivityState]) -> Void) {
        trackerQueue.async { [weak self] in
            completion(self?.surfaces ?? [:])
        }
    }

    /// Removes all tracked surfaces and cancels all timers.
    /// Used for testing or when attention is globally disabled.
    func reset() {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            for surfaceId in self.surfaces.keys {
                self.cancelTimers(for: surfaceId)
            }
            self.surfaces.removeAll()
        }
    }

    // MARK: - Private: Timer Management

    private func startSilenceCheckTimer(surfaceId: UUID) {
        // Cancel any existing silence timer first
        surfaces[surfaceId]?.silenceCheckTimer?.cancel()
        surfaces[surfaceId]?.silenceCheckTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: trackerQueue)
        timer.schedule(
            deadline: .now() + Self.silenceCheckInterval,
            repeating: Self.silenceCheckInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkSilence(surfaceId: surfaceId)
        }
        surfaces[surfaceId]?.silenceCheckTimer = timer
        timer.resume()
    }

    private func checkSilence(surfaceId: UUID) {
        guard var surfaceState = surfaces[surfaceId] else { return }
        guard surfaceState.state == .active else {
            // Timer fired but state changed — cancel it
            cancelSilenceTimer(for: surfaceId)
            return
        }

        let silenceThreshold = AttentionConfiguration.silenceThreshold()
        let silenceDuration = Date().timeIntervalSince(surfaceState.lastOutputAt)

        guard silenceDuration >= silenceThreshold else { return }

        // Transition to SILENT_AFTER_ACTIVE
        transitionToSilentAfterActive(surfaceId: surfaceId)
    }

    private func transitionToSilentAfterActive(surfaceId: UUID) {
        guard var surfaceState = surfaces[surfaceId] else { return }

        surfaceState.state = .silentAfterActive
        surfaces[surfaceId] = surfaceState
        cancelSilenceTimer(for: surfaceId)

        // Fire silence attention if unfocused
        if !surfaceState.isFocused {
            fireAttention(
                surfaceId: surfaceId,
                state: &surfaces[surfaceId]!,
                reason: .silence
            )
        }

        // Start cooldown timer to transition back to IDLE
        startCooldownTimer(surfaceId: surfaceId)
    }

    private func startCooldownTimer(surfaceId: UUID) {
        cancelCooldownTimer(for: surfaceId)

        let cooldown = AttentionConfiguration.cooldown()
        let timer = DispatchSource.makeTimerSource(queue: trackerQueue)
        timer.schedule(deadline: .now() + cooldown)
        timer.setEventHandler { [weak self] in
            self?.completeCooldown(surfaceId: surfaceId)
        }
        surfaces[surfaceId]?.cooldownTimer = timer
        timer.resume()
    }

    private func completeCooldown(surfaceId: UUID) {
        guard var surfaceState = surfaces[surfaceId] else { return }
        surfaceState.state = .idle
        surfaceState.cooldownTimer = nil
        surfaces[surfaceId] = surfaceState
    }

    // MARK: - Private: Attention Firing

    private func fireAttention(
        surfaceId: UUID,
        state: inout SurfaceActivityState,
        reason: AttentionReason
    ) {
        // Check general cooldown (bell has its own separate cooldown checked at call site)
        if reason != .bell {
            let cooldown = AttentionConfiguration.cooldown()
            let timeSinceLastAttention = Date().timeIntervalSince(state.lastAttentionAt)
            guard timeSinceLastAttention >= cooldown else { return }
        }

        let now = Date()
        state.lastAttentionAt = now
        if reason == .bell {
            state.lastBellAttentionAt = now
        }

        let tabId = state.tabId
        let title = state.surfaceTitle
        let callback = onAttention

        DispatchQueue.main.async {
            callback?(surfaceId, tabId, reason, title)
        }
    }

    // MARK: - Private: Timer Cleanup

    private func cancelTimers(for surfaceId: UUID) {
        cancelSilenceTimer(for: surfaceId)
        cancelCooldownTimer(for: surfaceId)
    }

    private func cancelSilenceTimer(for surfaceId: UUID) {
        surfaces[surfaceId]?.silenceCheckTimer?.cancel()
        surfaces[surfaceId]?.silenceCheckTimer = nil
    }

    private func cancelCooldownTimer(for surfaceId: UUID) {
        surfaces[surfaceId]?.cooldownTimer?.cancel()
        surfaces[surfaceId]?.cooldownTimer = nil
    }
}
```

- [ ] **Step 2: Verify the file compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-tracker build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/SurfaceActivityTracker.swift
git commit -m "feat(attention): add SurfaceActivityTracker state machine

Per-surface IDLE -> ACTIVE -> SILENT_AFTER_ACTIVE state machine with
fixed-interval polling timers on a dedicated serial queue. Hot path
is a single timestamp write. All panes tracked; focus gates delivery."
```

---

## Task 3: TerminalNotificationStore — Attention Notification Path

### Description
Extend the existing notification store to support attention notifications that increment the dock badge and play sound but do NOT create macOS banner notifications.

**Files:**
- Modify: `Sources/TerminalNotificationStore.swift`

- [ ] **Step 1: Add `Kind` field to `TerminalNotification`**

In `Sources/TerminalNotificationStore.swift`, add a `Kind` enum to `TerminalNotification` and a `kind` property:

```swift
// Inside TerminalNotification struct, add before the `id` property:
    enum Kind {
        /// Standard notification (existing behavior): dock badge + sound + macOS banner.
        case standard
        /// Attention notification: dock badge + sound, NO macOS banner.
        case attention(reason: String)
    }

    let kind: Kind
```

Update the existing `TerminalNotification` initializer usage. The `kind` field defaults to `.standard`. Update the struct to include `kind` in `Hashable` conformance (hash the enum's case string).

- [ ] **Step 2: Add `addAttentionNotification` method to `TerminalNotificationStore`**

Add a new method after the existing `addNotification` method:

```swift
    /// Adds an attention notification (dock badge + sound, no macOS banner).
    /// Attention notifications are added to the `notifications` array for unread count
    /// tracking but never trigger `UNUserNotificationCenter` banner delivery.
    func addAttentionNotification(
        tabId: UUID,
        surfaceId: UUID,
        reason: AttentionReason,
        title: String
    ) {
        var updated = notifications
        // Remove any existing attention notification for this surface
        // (each surface gets at most one active attention notification)
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId,
                  existing.surfaceId == surfaceId,
                  case .attention = existing.kind else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let shouldSuppressSound = isAppFocused && isFocusedPanel

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManager?.moveTabToTopForNotification(tabId)
        }

        let notification = TerminalNotification(
            kind: .attention(reason: reason.rawValue),
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: reason.displayDescription,
            body: "",
            createdAt: Date(),
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated

        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }

        // Play sound directly (bypassing UNUserNotificationCenter) if not suppressed
        if !shouldSuppressSound {
            playAttentionSound()
        }
        // Dock badge is refreshed automatically via notifications didSet -> refreshDockBadge()
    }

    /// Plays the configured notification sound for attention events.
    /// Uses the same sound settings as standard notifications but bypasses
    /// `UNNotificationSound` (which requires a banner notification).
    private func playAttentionSound() {
        let soundValue = UserDefaults.standard.string(
            forKey: NotificationSoundSettings.key
        ) ?? NotificationSoundSettings.defaultValue

        switch soundValue {
        case "none":
            break
        case "default":
            NSSound.beep()
        case NotificationSoundSettings.customFileValue:
            NotificationSoundSettings.playCustomFileSound()
        default:
            NSSound(named: NSSound.Name(soundValue))?.play()
        }
    }
```

- [ ] **Step 3: Update existing `TerminalNotification` initialization to include `kind: .standard`**

Search for all existing `TerminalNotification(` initializations in the file. Each one needs the `kind: .standard` parameter. The existing `addNotification` method creates one `TerminalNotification` — add `kind: .standard` to it.

- [ ] **Step 4: Verify the file compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-notif build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/TerminalNotificationStore.swift
git commit -m "feat(attention): add attention notification path to TerminalNotificationStore

Attention notifications increment dock badge and play sound but skip
macOS UNUserNotificationCenter banners. Adds TerminalNotification.Kind
enum (.standard vs .attention) to distinguish notification types."
```

---

## Task 4: Ghostty Integration — Output Detection + Bell Hook

### Description
Wire the Ghostty action callbacks (`GHOSTTY_ACTION_SET_TITLE` and `GHOSTTY_ACTION_RING_BELL`) into `SurfaceActivityTracker`. Also register/unregister surfaces on creation/destruction.

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift`

**Key constraint:** `SET_TITLE` fires on shell prompt changes and command title updates. It is not per-byte output, but it fires frequently enough during interactive sessions and command execution to serve as a lightweight activity signal. The spec explicitly says "a thin bridging callback" is acceptable, and `SET_TITLE` is already a callback that fires with surface context.

- [ ] **Step 1: Hook `GHOSTTY_ACTION_SET_TITLE` to record output**

In `Sources/GhosttyTerminalView.swift`, inside the `case GHOSTTY_ACTION_SET_TITLE:` handler (around line 2171), after the existing title notification post, add a call to the tracker. Add this INSIDE the existing `if let tabId = surfaceView.tabId, let surfaceId = surfaceView.terminalSurface?.id` block:

```swift
            // Record output activity for pane attention tracking.
            // This is the output detection hot path: only a timestamp write when ACTIVE.
            SurfaceActivityTracker.shared.recordOutput(
                surfaceId: surfaceId,
                title: title
            )
```

This goes after the `DispatchQueue.main.async` block that posts `.ghosttyDidSetTitle`, still within the `if let tabId, surfaceId` guard.

- [ ] **Step 2: Hook `GHOSTTY_ACTION_RING_BELL` (surface-target) for bell attention**

In the surface-target `case GHOSTTY_ACTION_RING_BELL:` handler (around line 2066), add bell attention tracking. The surface-target handler has `surfaceView` in scope:

```swift
        case GHOSTTY_ACTION_RING_BELL:
            performOnMain {
                self.ringBell()
            }
            // Trigger bell attention (bypasses state machine, has own cooldown).
            // Only the surface-target bell fires attention — the app-target bell
            // (no surface context) only handles sound and dock bounce.
            if let tabId = surfaceView.tabId,
               let surfaceId = surfaceView.terminalSurface?.id {
                // Resolve surface title from the tab manager.
                // titleForTab returns the workspace title; for per-surface title,
                // use panelTitles dict on the workspace model.
                let title: String = {
                    guard let ws = AppDelegate.shared?.tabManager?.tabs
                        .first(where: { $0.id == tabId }) else { return "" }
                    return ws.panelTitles[surfaceId] ?? ws.title
                }()
                SurfaceActivityTracker.shared.triggerBellAttention(
                    surfaceId: surfaceId,
                    tabId: tabId,
                    surfaceTitle: title
                )
            }
            return true
```

- [ ] **Step 3: Register surfaces on creation, unregister on destruction**

Find the `close_surface_cb` callback (around line 1104) and add unregistration. Find the surface creation path where `GhosttySurfaceCallbackContext` is created and add registration.

For unregistration in `close_surface_cb`:
```swift
            // Unregister from attention tracker
            SurfaceActivityTracker.shared.unregisterSurface(surfaceId: callbackSurfaceId)
```

For registration, find the path where `GhosttySurfaceCallbackContext` is initialized and surfaces are set up. Add after the context is created:
```swift
            SurfaceActivityTracker.shared.registerSurface(
                surfaceId: terminalSurface.id,
                tabId: tabId,
                isFocused: true // New surfaces start focused
            )
```

- [ ] **Step 4: Wire focus updates**

Hook into the existing `.ghosttyDidFocusSurface` notification handling. When a surface gains focus, the previously-focused surface loses focus. Add focus tracking in the `handleAction` method where `GHOSTTY_ACTION_FOCUS` events are processed, or alternatively in the `BridgeEventRelay` observer for `pane.focused`.

The simplest approach: in the attention callback setup (Task 5), observe `.ghosttyDidFocusSurface` notifications and call `updateFocus` on the tracker.

- [ ] **Step 5: Verify the file compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-hooks build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/GhosttyTerminalView.swift
git commit -m "feat(attention): hook Ghostty SET_TITLE and RING_BELL into activity tracker

SET_TITLE fires on shell prompt changes, providing lightweight output
detection without per-byte overhead. Bell uses surface-target handler
where surfaceView context is available."
```

---

## Task 5: Wire Attention Callback — Connect Tracker to NotificationStore + Bridge

### Description
Set up the `SurfaceActivityTracker.onAttention` callback to deliver notifications through both the desktop notification store and the bridge event relay. Also set up focus observation.

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift` (or `Sources/AppDelegate.swift` — wherever app initialization happens)
- Modify: `Sources/Bridge/BridgeEventRelay.swift`

- [ ] **Step 1: Add `bridgeSurfaceAttention` notification name in `BridgeEventRelay.swift`**

In the `Notification.Name` extension at the top of `Sources/Bridge/BridgeEventRelay.swift`:

```swift
    /// Posted when a surface triggers an attention notification.
    static let bridgeSurfaceAttention = Notification.Name("bridge.surface.attention")
```

Add a key for reason in `BridgeNotificationKey`:
```swift
    static let attentionReason = "bridge.attentionReason"
    static let surfaceTitle = "bridge.surfaceTitle"
```

- [ ] **Step 2: Register observer #13 in `BridgeEventRelay.registerObservers()`**

Add at the end of `registerObservers()`:

```swift
        // 13. surface.attention — fired when a pane triggers attention
        observers.append(NotificationCenter.default.addObserver(
            forName: .bridgeSurfaceAttention, object: nil, queue: nil
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            let reason = notification.userInfo?[BridgeNotificationKey.attentionReason] as? String ?? "unknown"
            let paneId = notification.userInfo?[BridgeNotificationKey.paneId] as? String ?? ""
            let title = notification.userInfo?[BridgeNotificationKey.surfaceTitle] as? String ?? ""
            self?.emit(event: "surface.attention", data: [
                "workspace_id": tabId.uuidString,
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId,
                "reason": reason,
                "surface_title": title,
            ])
        })
```

Update the comment "Registers observers for all 12 bridge event types" to say "13".

- [ ] **Step 3: Wire the attention callback in app initialization**

In `GhosttyApp.swift` initialization (or `AppDelegate`), after the tracker singleton is available, set up the callback. Find the appropriate initialization point (likely in `AppDelegate.applicationDidFinishLaunching` or similar):

```swift
        // Wire attention tracker to notification delivery
        SurfaceActivityTracker.shared.onAttention = { surfaceId, tabId, reason, surfaceTitle in
            // Desktop: add attention notification (badge + sound, no banner)
            TerminalNotificationStore.shared.addAttentionNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                reason: reason,
                title: surfaceTitle
            )

            // Bridge: post notification for Android companion.
            // Resolve pane ID using workspace.paneId(forPanelId:) — same pattern
            // as other bridge events (pane.focused, surface.reordered, etc.)
            let paneId: String = {
                guard let workspace = AppDelegate.shared?.tabManager?.tabs
                    .first(where: { $0.id == tabId }) else { return "" }
                return workspace.paneId(forPanelId: surfaceId)?.id.uuidString ?? ""
            }()
            NotificationCenter.default.post(
                name: .bridgeSurfaceAttention,
                object: nil,
                userInfo: [
                    GhosttyNotificationKey.tabId: tabId,
                    GhosttyNotificationKey.surfaceId: surfaceId,
                    BridgeNotificationKey.paneId: paneId,
                    BridgeNotificationKey.attentionReason: reason.rawValue,
                    BridgeNotificationKey.surfaceTitle: surfaceTitle,
                ]
            )
        }
```

- [ ] **Step 4: Set up focus observation**

Register a `NotificationCenter` observer for `.ghosttyDidFocusSurface` to update the tracker's focus state:

```swift
        NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { notification in
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            // The newly focused surface
            SurfaceActivityTracker.shared.updateFocus(surfaceId: surfaceId, isFocused: true)

            // All other surfaces in the same tab become unfocused
            // (The tracker handles this via the isFocused flag per surface)
        }
```

Also observe app activation/deactivation for the "app loses focus" case described in the spec:

```swift
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // When app loses focus, all surfaces become "unfocused" for attention purposes
            SurfaceActivityTracker.shared.statusSnapshot { surfaces in
                for (surfaceId, _) in surfaces {
                    SurfaceActivityTracker.shared.updateFocus(surfaceId: surfaceId, isFocused: false)
                }
            }
        }
```

- [ ] **Step 5: Verify the build compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-wire build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sources/Bridge/BridgeEventRelay.swift Sources/GhosttyTerminalView.swift
git commit -m "feat(attention): wire tracker to notification store and bridge relay

Attention callback delivers to TerminalNotificationStore (desktop badge +
sound) and posts bridgeSurfaceAttention for Android companion. Focus
observation tracks surface and app activation state."
```

---

## Task 6: V2 Socket API — `attention.configure` and `attention.status`

### Description
Add V2 socket commands for configuring and querying attention state. Follows the existing V2 command patterns in `TerminalController.swift`.

**Files:**
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Add V2 command routing in the main dispatch switch**

In the V2 command dispatch `switch` statement (around line 2163, after the Notifications section), add:

```swift
        // Attention
        case "attention.configure":
            return v2Result(id: id, self.v2AttentionConfigure(params: params))
        case "attention.status":
            return v2Result(id: id, self.v2AttentionStatus(params: params))
        case "attention.enable":
            return v2Result(id: id, self.v2AttentionEnable())
        case "attention.disable":
            return v2Result(id: id, self.v2AttentionDisable())
```

- [ ] **Step 2: Implement `v2AttentionConfigure`**

Add a new method section after the notification methods:

```swift
    // MARK: - V2 Attention Methods

    private func v2AttentionConfigure(params: [String: Any]) -> V2CallResult {
        if let enabled = v2Bool(params, "enabled") {
            AttentionConfiguration.setEnabled(enabled)
        }
        if let silenceThreshold = v2Double(params, "silence_threshold") {
            guard silenceThreshold > 0 else {
                return .err(
                    code: "invalid_params",
                    message: "silence_threshold must be positive",
                    data: nil
                )
            }
            AttentionConfiguration.setSilenceThreshold(silenceThreshold)
        }
        if let idleThreshold = v2Double(params, "idle_threshold") {
            guard idleThreshold > 0 else {
                return .err(
                    code: "invalid_params",
                    message: "idle_threshold must be positive",
                    data: nil
                )
            }
            AttentionConfiguration.setIdleThreshold(idleThreshold)
        }
        if let cooldown = v2Double(params, "cooldown") {
            guard cooldown > 0 else {
                return .err(
                    code: "invalid_params",
                    message: "cooldown must be positive",
                    data: nil
                )
            }
            AttentionConfiguration.setCooldown(cooldown)
        }
        if let bellCooldown = v2Double(params, "bell_cooldown") {
            guard bellCooldown > 0 else {
                return .err(
                    code: "invalid_params",
                    message: "bell_cooldown must be positive",
                    data: nil
                )
            }
            AttentionConfiguration.setBellCooldown(bellCooldown)
        }
        return .ok(AttentionConfiguration.snapshot().toDictionary())
    }
```

- [ ] **Step 3: Implement `v2AttentionStatus`**

```swift
    private func v2AttentionStatus(params: [String: Any]) -> V2CallResult {
        let config = AttentionConfiguration.snapshot()
        var surfaceList: [[String: Any]] = []

        // statusSnapshot is async on the tracker queue — use a semaphore
        // for the synchronous V2 response (acceptable for diagnostic commands).
        let semaphore = DispatchSemaphore(value: 0)
        SurfaceActivityTracker.shared.statusSnapshot { surfaces in
            let formatter = ISO8601DateFormatter()
            for (surfaceId, state) in surfaces {
                surfaceList.append([
                    "surface_id": surfaceId.uuidString,
                    "workspace_id": state.tabId.uuidString,
                    "state": state.state.rawValue,
                    "last_output_at": formatter.string(from: state.lastOutputAt),
                    "is_focused": state.isFocused,
                    "in_cooldown": state.state == .silentAfterActive,
                ])
            }
            semaphore.signal()
        }
        semaphore.wait()

        return .ok([
            "config": config.toDictionary(),
            "surfaces": surfaceList,
        ])
    }
```

- [ ] **Step 4: Implement `v2AttentionEnable` and `v2AttentionDisable`**

```swift
    private func v2AttentionEnable() -> V2CallResult {
        AttentionConfiguration.setEnabled(true)
        return .ok(["enabled": true])
    }

    private func v2AttentionDisable() -> V2CallResult {
        AttentionConfiguration.setEnabled(false)
        return .ok(["enabled": false])
    }
```

- [ ] **Step 5: Check if `v2Double` helper exists; add if not**

Search `TerminalController.swift` for `v2Double`. If it does not exist, add a helper near the other `v2Bool`, `v2UUID`, `v2RawString` helpers:

```swift
    private nonisolated func v2Double(_ params: [String: Any], _ key: String) -> Double? {
        if let value = params[key] as? Double {
            return value
        }
        if let value = params[key] as? Int {
            return Double(value)
        }
        if let value = params[key] as? String, let parsed = Double(value) {
            return parsed
        }
        return nil
    }
```

- [ ] **Step 6: Verify the build compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-v2 build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Sources/TerminalController.swift
git commit -m "feat(attention): add V2 socket API commands

attention.configure — update thresholds at runtime
attention.status — returns config snapshot and per-surface states
attention.enable / attention.disable — master toggle shortcuts"
```

---

## Task 7: CLI — `cmux attention` Subcommand

### Description
Add the `cmux attention` CLI subcommand that sends V2 API commands to the socket. Follows existing CLI patterns in `CLI/cmux.swift`.

**Files:**
- Modify: `CLI/cmux.swift`

- [ ] **Step 1: Add `attention` case to the main command dispatch switch**

In the main `switch command` block (around line 1507), add:

```swift
        case "attention":
            try handleAttentionCommand(commandArgs: commandArgs, client: client)
```

- [ ] **Step 2: Implement `handleAttentionCommand`**

Add a new method:

```swift
    private func handleAttentionCommand(
        commandArgs: [String],
        client: SocketClient
    ) throws {
        let subcommand = commandArgs.first ?? "status"
        let subArgs = Array(commandArgs.dropFirst())

        switch subcommand {
        case "enable":
            let response = try client.sendV2(method: "attention.enable", params: [:])
            print(formatV2Response(response, key: "enabled"))

        case "disable":
            let response = try client.sendV2(method: "attention.disable", params: [:])
            print(formatV2Response(response, key: "enabled"))

        case "status":
            let response = try client.sendV2(method: "attention.status", params: [:])
            printJSON(response)

        case "config":
            var params: [String: Any] = [:]
            var i = 0
            while i < subArgs.count {
                switch subArgs[i] {
                case "--silence-threshold":
                    i += 1
                    guard i < subArgs.count, let value = Double(subArgs[i]) else {
                        throw CLIError(message: "Missing or invalid value for --silence-threshold")
                    }
                    params["silence_threshold"] = value
                case "--idle-threshold":
                    i += 1
                    guard i < subArgs.count, let value = Double(subArgs[i]) else {
                        throw CLIError(message: "Missing or invalid value for --idle-threshold")
                    }
                    params["idle_threshold"] = value
                case "--cooldown":
                    i += 1
                    guard i < subArgs.count, let value = Double(subArgs[i]) else {
                        throw CLIError(message: "Missing or invalid value for --cooldown")
                    }
                    params["cooldown"] = value
                case "--bell-cooldown":
                    i += 1
                    guard i < subArgs.count, let value = Double(subArgs[i]) else {
                        throw CLIError(message: "Missing or invalid value for --bell-cooldown")
                    }
                    params["bell_cooldown"] = value
                default:
                    throw CLIError(message: "Unknown config option: \(subArgs[i])")
                }
                i += 1
            }
            guard !params.isEmpty else {
                throw CLIError(message: "No config options provided. Use --silence-threshold, --idle-threshold, --cooldown, or --bell-cooldown")
            }
            let response = try client.sendV2(method: "attention.configure", params: params)
            printJSON(response)

        default:
            throw CLIError(message: "Unknown attention subcommand: \(subcommand). Use: enable, disable, status, config")
        }
    }
```

- [ ] **Step 3: Add help text for `attention` subcommand**

In the `subcommandUsage` method, add:

```swift
        case "attention":
            return """
            Usage: cmux attention [subcommand] [options]

            Manage pane attention notifications.

            Subcommands:
              enable                   Enable attention tracking
              disable                  Disable attention tracking
              status                   Show current config and per-surface states (default)
              config [options]         Update attention thresholds

            Config options:
              --silence-threshold N    Seconds of silence before "waiting" alert (default: 30)
              --idle-threshold N       Seconds idle before "woke up" alert (default: 5)
              --cooldown N             Seconds between repeat notifications per pane (default: 60)
              --bell-cooldown N        Seconds between repeat bell notifications (default: 5)

            Examples:
              cmux attention status
              cmux attention enable
              cmux attention config --silence-threshold 10 --cooldown 30
            """
```

- [ ] **Step 4: Verify the build compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-cli build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add CLI/cmux.swift
git commit -m "feat(attention): add 'cmux attention' CLI subcommand

Supports enable/disable/status/config sub-actions. Config accepts
--silence-threshold, --idle-threshold, --cooldown, --bell-cooldown."
```

---

## Task 8: Android — Add `flutter_local_notifications` Dependency + Notification Handler

### Description
Add the Flutter local notifications plugin and create the attention notification handler that receives bridge events and shows Android system notifications.

**Files:**
- Modify: `android-companion/pubspec.yaml`
- Create: `android-companion/lib/notifications/attention_notification_handler.dart`

- [ ] **Step 1: Add `flutter_local_notifications` to `pubspec.yaml`**

In `android-companion/pubspec.yaml`, under `dependencies:`, add:

```yaml
  # Local notifications for pane attention alerts
  flutter_local_notifications: ^18.0.1
```

- [ ] **Step 2: Run `flutter pub get`**

```bash
cd android-companion && flutter pub get
```
Expected: No errors.

- [ ] **Step 3: Create `attention_notification_handler.dart`**

```dart
// android-companion/lib/notifications/attention_notification_handler.dart

/// Handles `surface.attention` bridge events and delivers Android system
/// notifications for pane attention alerts.
///
/// Uses [flutter_local_notifications] for system notification delivery.
/// Notifications appear in the notification shade even when the companion
/// app is backgrounded (requires active WebSocket connection).
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/workspace_provider.dart';

/// Notification channel for pane attention alerts.
const _channelId = 'pane_attention';
const _channelName = 'Pane Attention';
const _channelDescription = 'Alerts when terminal panes need your attention';

/// Singleton handler for attention notifications.
class AttentionNotificationHandler {
  final FlutterLocalNotificationsPlugin _plugin;
  final Ref _ref;
  bool _initialized = false;

  /// Counter for unique notification IDs (wraps around at max int).
  int _nextNotificationId = 1000;

  AttentionNotificationHandler(this._ref)
      : _plugin = FlutterLocalNotificationsPlugin();

  /// Initialize the notification plugin. Must be called once at app startup.
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create the notification channel
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
      enableVibration: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  /// Handle an incoming `surface.attention` bridge event.
  ///
  /// Shows a system notification and updates in-app workspace attention state.
  Future<void> handleAttentionEvent(Map<String, dynamic> data) async {
    if (!_initialized) await initialize();

    final workspaceId = data['workspace_id'] as String? ?? '';
    final surfaceId = data['surface_id'] as String? ?? '';
    final reason = data['reason'] as String? ?? 'unknown';
    final surfaceTitle = data['surface_title'] as String? ?? '';

    // Look up workspace name for notification title
    final workspaces = _ref.read(workspaceProvider);
    final workspace = workspaces.workspaces
        .where((w) => w.id == workspaceId)
        .firstOrNull;
    final workspaceName = workspace?.title ?? 'Terminal';

    // Build notification body from reason
    final reasonDescription = _reasonDescription(reason);
    final body = surfaceTitle.isNotEmpty
        ? '$surfaceTitle — $reasonDescription'
        : reasonDescription;

    // Show system notification
    final notificationId = _nextNotificationId++;
    if (_nextNotificationId > 100000) _nextNotificationId = 1000;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(notificationId, workspaceName, body, details,
        payload: '$workspaceId:$surfaceId');

    // Update in-app workspace attention count
    _ref
        .read(workspaceProvider.notifier)
        .incrementAttentionCount(workspaceId);
  }

  /// Maps reason codes to human-readable descriptions.
  String _reasonDescription(String reason) {
    switch (reason) {
      case 'bell':
        return 'Terminal bell';
      case 'silence':
        return 'Output stopped (may need input)';
      case 'activity':
        return 'New output started';
      default:
        return 'Needs attention';
    }
  }

  /// Called when user taps a notification. Navigates to the workspace/pane.
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.contains(':')) return;

    final parts = payload.split(':');
    if (parts.length < 2) return;

    final workspaceId = parts[0];
    // Select the workspace in the app
    _ref.read(workspaceProvider.notifier).selectWorkspace(workspaceId);
  }
}

/// Provider for the attention notification handler singleton.
final attentionNotificationHandlerProvider =
    Provider<AttentionNotificationHandler>((ref) {
  return AttentionNotificationHandler(ref);
});
```

- [ ] **Step 4: Verify Flutter analysis passes**

```bash
cd android-companion && flutter analyze
```
Expected: No errors (warnings acceptable).

- [ ] **Step 5: Commit**

```bash
git add android-companion/pubspec.yaml android-companion/lib/notifications/attention_notification_handler.dart
git commit -m "feat(attention/android): add attention notification handler

Uses flutter_local_notifications for system notification delivery.
Handles surface.attention bridge events with workspace-aware titles."
```

---

## Task 9: Android — Wire Event Handler + Workspace Attention State

### Description
Route `surface.attention` events from the bridge event handler to the notification handler. Add attention count state to the workspace model.

**Files:**
- Modify: `android-companion/lib/state/event_handler.dart`
- Modify: `android-companion/lib/state/workspace_provider.dart`

- [ ] **Step 1: Add `attentionCount` support to `WorkspaceNotifier`**

In `android-companion/lib/state/workspace_provider.dart`, add to `WorkspaceNotifier` (the notifier class):

```dart
  /// Increment the attention count for a workspace.
  void incrementAttentionCount(String workspaceId) {
    final current = state.workspaces;
    final updated = current.map((w) {
      if (w.id == workspaceId) {
        return w.copyWith(
          notificationCount: w.notificationCount + 1,
        );
      }
      return w;
    }).toList();

    state = state.copyWith(workspaces: updated);
  }

  /// Clear attention count for a workspace (called when user views it).
  void clearAttentionCount(String workspaceId) {
    final current = state.workspaces;
    final updated = current.map((w) {
      if (w.id == workspaceId) {
        return w.copyWith(notificationCount: 0);
      }
      return w;
    }).toList();

    state = state.copyWith(workspaces: updated);
  }
```

The `Workspace` model already has `notificationCount` and `copyWith` support (confirmed in the codebase).

- [ ] **Step 2: Route `surface.attention` events in `EventHandler`**

In `android-companion/lib/state/event_handler.dart`, add the import and case:

Add import at the top:
```dart
import '../notifications/attention_notification_handler.dart';
```

Add case in the `_onEvent` switch (before `default:`):

```dart
      // Attention events
      case 'surface.attention':
        _ref.read(attentionNotificationHandlerProvider).handleAttentionEvent(data);
```

- [ ] **Step 3: Verify Flutter analysis passes**

```bash
cd android-companion && flutter analyze
```
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add android-companion/lib/state/event_handler.dart android-companion/lib/state/workspace_provider.dart
git commit -m "feat(attention/android): wire attention events to notification handler

Routes surface.attention bridge events through EventHandler to
AttentionNotificationHandler. Adds workspace attention count methods."
```

---

## Task 10: Manual Validation + Cleanup

### Description
End-to-end verification and cleanup. This task covers the manual testing steps and any adjustments needed.

**Files:**
- Possibly adjust: any files from Tasks 1-9 based on build/runtime issues

- [ ] **Step 1: Full build verification**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-attention-full build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify CLI help output**

After building, test the CLI help:
```bash
/tmp/cmux-attention-full/Build/Products/Debug/cmux\ DEV\ attention-full.app/Contents/MacOS/cmux-dev attention --help
```
Expected: Shows usage text with all subcommands and options.

- [ ] **Step 3: Verify Android companion builds**

```bash
cd android-companion && flutter build apk --debug
```
Expected: Build succeeds.

- [ ] **Step 4: Update documentation files**

Update `docs/pane-attention/development-architecture.md` with any implementation details that differ from the original spec (actual file paths, any decisions made during implementation).

Update `docs/pane-attention/ux-behavior-expectations.md` if any edge case handling was adjusted.

- [ ] **Step 5: Commit documentation updates**

```bash
git add docs/pane-attention/
git commit -m "docs(attention): update architecture docs with implementation details"
```

---

## Dependency Graph

```
Task 1 (AttentionConfiguration) ─────────┐
                                          ├──► Task 2 (SurfaceActivityTracker)
                                          │        │
Task 3 (NotificationStore) ───────────────┤        │
                                          ├──► Task 4 (Ghostty hooks)
                                          │        │
                                          ├──► Task 5 (Wire callback) ──► Task 6 (V2 API) ──► Task 7 (CLI)
                                          │
                                          └──► Task 8 (Android handler) ──► Task 9 (Android wiring)
                                                                                    │
                                                              Task 10 (Validation) ◄┘
```

Tasks 1 and 3 are independent and can be done in parallel.
Tasks 8-9 (Android) are independent of Tasks 4-7 (desktop) and can be done in parallel after Task 1.
Task 10 depends on all previous tasks.

---

## Testing Strategy

Per the project's testing policy ("Never run tests locally"), tests run via CI. However, the following test scenarios should be covered:

### Unit Tests (for SurfaceActivityTracker)
These test the state machine in isolation — no Ghostty dependency:

1. **IDLE -> ACTIVE transition**: `recordOutput` on an idle surface after `idleThreshold` fires activity attention.
2. **ACTIVE -> SILENT_AFTER_ACTIVE**: After output stops for `silenceThreshold`, silence attention fires.
3. **General cooldown**: Second notification within `cooldown` seconds is suppressed.
4. **Bell cooldown**: Second bell within `bellCooldown` is suppressed, but general notifications still fire.
5. **Focused pane suppression**: Attention does not fire for focused panes.
6. **Unfocus fires deferred attention**: Pane in SILENT_AFTER_ACTIVE that gets unfocused fires immediately.
7. **Hot path cost**: `recordOutput` on an already-ACTIVE surface only writes a timestamp (no timer manipulation).

### Integration Tests (V2 Socket API)
Via python socket test suite (`tests_v2/`):

1. `attention.status` returns config and empty surfaces list.
2. `attention.configure` updates thresholds and returns new config.
3. `attention.enable` / `attention.disable` toggle the master switch.
4. Invalid parameters (negative thresholds) return error responses.

### Manual Validation Checklist
1. Open two panes. Focus pane A. In pane B, run `sleep 35 && echo "done"`. After ~35s of silence, verify dock badge increments and sound plays.
2. In a background pane, run `echo -e '\x07'`. Verify bell attention fires (dock badge + sound).
3. Rapid bell: `for i in $(seq 1 10); do echo -e '\x07'; done`. Verify at most one notification per 5 seconds.
4. Run `cmux attention status` and verify JSON output shows surface states.
5. Run `cmux attention config --silence-threshold 10` and verify it takes effect.
6. With Android companion connected, verify system notification appears on attention trigger.
