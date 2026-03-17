import Foundation

/// UserDefaults-backed configuration for the cmux-bridge WebSocket server.
///
/// All settings are stored in `UserDefaults.standard` under the `bridge.*` key prefix.
/// Default state is disabled; the user must explicitly enable the bridge in Settings.
enum BridgeSettings {
    // MARK: - Keys

    static let enabledKey = "bridge.enabled"
    static let portKey = "bridge.port"

    // MARK: - Defaults

    static let defaultEnabled = false
    static let defaultPort = 17377

    // MARK: - Accessors

    /// Whether the bridge WebSocket server is enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) != nil
            ? UserDefaults.standard.bool(forKey: enabledKey)
            : defaultEnabled }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The TCP port the bridge listens on.
    static var port: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            return stored > 0 ? stored : defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }
}
