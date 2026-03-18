import Foundation

/// Tracks live WebSocket connection state of bridge devices for the settings UI.
///
/// Subscribes to `BridgeServer.deviceConnected` / `.deviceDisconnected` notifications
/// and maintains a dictionary of device states with connected/disconnected timestamps.
/// The settings view observes this to show status dots (green/yellow/gray).
///
/// Singleton: access via `BridgeConnectionStatus.shared`.
final class BridgeConnectionStatus: ObservableObject {
    static let shared = BridgeConnectionStatus()

    /// Represents the current connection state of a single device.
    struct DeviceState: Equatable {
        let deviceId: UUID
        let deviceName: String
        var isConnected: Bool
        /// When the device last disconnected. `nil` while connected.
        var disconnectedAt: Date?
    }

    /// Current state of all known devices, keyed by device UUID.
    @Published var deviceStates: [UUID: DeviceState] = [:]

    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: BridgeServer.deviceConnected,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let deviceId = notification.userInfo?["deviceId"] as? UUID,
                      let deviceName = notification.userInfo?["deviceName"] as? String else { return }
                self.deviceStates[deviceId] = DeviceState(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    isConnected: true,
                    disconnectedAt: nil
                )
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: BridgeServer.deviceDisconnected,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let deviceId = notification.userInfo?["deviceId"] as? UUID else { return }
                if var state = self.deviceStates[deviceId] {
                    state.isConnected = false
                    state.disconnectedAt = Date()
                    self.deviceStates[deviceId] = state
                }
            }
        )
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Builds initial state from the server's current connections and paired device list.
    ///
    /// Queries `BridgeServer.shared.connectedDeviceIds()` and cross-references with
    /// `BridgeAuth.shared.listDevices()` to populate state for devices that connected
    /// before this object started observing.
    func refreshFromServer() {
        let connectedIds = BridgeServer.shared.connectedDeviceIds()
        let pairedDevices = BridgeAuth.shared.listDevices()

        for device in pairedDevices {
            let isConnected = connectedIds.contains(device.id)
            if isConnected {
                deviceStates[device.id] = DeviceState(
                    deviceId: device.id,
                    deviceName: device.name,
                    isConnected: true,
                    disconnectedAt: nil
                )
            } else if deviceStates[device.id] == nil {
                // Only add disconnected state if we don't already have one,
                // to preserve disconnectedAt timestamps from live notifications.
                deviceStates[device.id] = DeviceState(
                    deviceId: device.id,
                    deviceName: device.name,
                    isConnected: false,
                    disconnectedAt: device.lastSeenAt
                )
            }
        }
    }
}
