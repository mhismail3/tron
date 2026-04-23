import Foundation

// MARK: - Session list refresh coordination

extension EventStoreManager {

    /// Shared coalescing coordinator. Lazy so we don't construct it until first use.
    /// In production the `DependencyContainer` calls `attachConnectionManager(_:)` after both
    /// this manager and the shared `ConnectionManager` are instantiated.
    private nonisolated(unsafe) static var refreshServiceKey: UInt8 = 0

    // A @MainActor-isolated dictionary mapping EventStoreManager instance → service.
    // Extensions can't add stored properties, so we piggyback on associated objects.
    // Keyed by ObjectIdentifier(self) to avoid retain loops.

    @MainActor
    private static var services: [ObjectIdentifier: SessionRefreshService] = [:]

    /// Returns the per-instance refresh service, creating it on first access.
    @MainActor
    fileprivate var refreshService: SessionRefreshService {
        let key = ObjectIdentifier(self)
        if let existing = Self.services[key] { return existing }
        let service = SessionRefreshService(
            performRefresh: { [weak self] in await self?.refreshSessionList() },
            isConnected: { [weak self] in self?.rpcClient.connectionState.isConnected ?? false }
        )
        Self.services[key] = service
        return service
    }

    /// Release the per-instance service. Call during teardown to avoid leaks in tests.
    @MainActor
    func releaseRefreshService() {
        Self.services.removeValue(forKey: ObjectIdentifier(self))
    }

    /// Attach the shared `ConnectionManager` so offline refresh requests can be queued for
    /// reconnect. Called once by `DependencyContainer` during wire-up.
    func attachConnectionManager(_ manager: ConnectionManager) {
        refreshService.attachConnectionManager(manager)
    }

    /// Single entry point for refreshing the session list. All callers route here instead
    /// of calling `refreshSessionList()` directly.
    func requestSessionRefresh(reason: SessionRefreshService.RefreshReason) {
        refreshService.request(reason: reason)
    }
}
