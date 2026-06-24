import Foundation

// MARK: - Session list refresh coordination

extension EventStoreManager {

    /// Attach the shared `ConnectionManager` so offline refresh requests can be queued for
    /// reconnect. Called once by `DependencyContainer` during wire-up.
    func attachConnectionManager(_ manager: ConnectionManager) {
        refreshService.attachConnectionManager(manager)
    }

    /// Single entry point for refreshing the session list. All callers route here instead
    /// of calling `refreshSessionList()` directly — the service handles coalescing,
    /// foreground debouncing, and reconnect queuing.
    func requestSessionRefresh(reason: SessionRefreshService.RefreshReason) {
        refreshService.request(reason: reason)
    }
}
