import Foundation
import Combine

// MARK: - BridgeBrowserHandler

/// Observes a `BrowserPanel` instance via Combine and posts bridge notifications
/// when the browser navigates (URL, title, or navigation state changes).
///
/// Each `BrowserPanel` gets its own handler instance, installed when the panel is
/// created and torn down when the panel is closed. The handler posts
/// `.bridgeBrowserNavigated` notifications that `BridgeEventRelay` picks up and
/// broadcasts to connected bridge clients.
///
/// ## Lifecycle
/// - Created via `observe(_:)` when a browser panel is added to a workspace.
/// - The returned `AnyCancellable` should be stored alongside the panel; dropping
///   it stops observation automatically.
///
/// ## Threading
/// All Combine pipelines receive on `DispatchQueue.main` because `BrowserPanel`
/// publishes on main and `NotificationCenter.default.post` is thread-safe.
@MainActor
enum BridgeBrowserHandler {

    /// Begins observing a browser panel's navigation state and posts
    /// `.bridgeBrowserNavigated` whenever the URL, title, or back/forward state changes.
    ///
    /// - Parameter browserPanel: The panel to observe.
    /// - Returns: A cancellable that stops observation when released.
    static func observe(_ browserPanel: BrowserPanel) -> AnyCancellable {
        // Combine the four navigation-relevant published properties. We use
        // CombineLatest4 to capture any change to url, title, canGoBack, or
        // canGoForward and emit a single bridge notification with the full
        // snapshot. `removeDuplicates` on each stream avoids redundant posts
        // when only one property setter fires without an actual value change.
        let urlStream = browserPanel.$currentURL
            .removeDuplicates()
            .map { $0?.absoluteString ?? "" }

        let titleStream = browserPanel.$pageTitle
            .removeDuplicates()

        let canGoBackStream = browserPanel.$canGoBack
            .removeDuplicates()

        let canGoForwardStream = browserPanel.$canGoForward
            .removeDuplicates()

        return Publishers.CombineLatest4(
            urlStream,
            titleStream,
            canGoBackStream,
            canGoForwardStream
        )
        .dropFirst()  // Skip the initial value emission on subscription
        .receive(on: DispatchQueue.main)
        .sink { [weak browserPanel] url, title, canGoBack, canGoForward in
            guard let browserPanel = browserPanel else { return }

            // Only emit navigation events when the browser has actually loaded content.
            // Empty URL means the panel is in its initial "new tab" state.
            guard !url.isEmpty else { return }

            NotificationCenter.default.post(
                name: .bridgeBrowserNavigated,
                object: nil,
                userInfo: [
                    GhosttyNotificationKey.surfaceId: browserPanel.id,
                    BridgeNotificationKey.url: url,
                    GhosttyNotificationKey.title: title,
                    BridgeNotificationKey.faviconURL: browserPanel.lastFaviconURL ?? "",
                    BridgeNotificationKey.canGoBack: canGoBack,
                    BridgeNotificationKey.canGoForward: canGoForward,
                ]
            )
        }
    }
}
