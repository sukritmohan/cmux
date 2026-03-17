import Foundation

/// Context object passed as `Unmanaged` userdata to the Ghostty PTY output observer
/// C callback. Holds the surface UUID needed to route PTY output to the correct
/// bridge channel.
///
/// Lifecycle: retained via `Unmanaged.passRetained` when the observer is registered,
/// released via `Unmanaged.release` when unregistered. The C callback uses
/// `takeUnretainedValue` to read the surface ID without altering the retain count.
final class BridgePTYObserverContext {
    let surfaceId: UUID

    init(surfaceId: UUID) {
        self.surfaceId = surfaceId
    }
}
