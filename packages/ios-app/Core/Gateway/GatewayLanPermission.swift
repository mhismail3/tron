import Foundation

/// Whether iOS denied this install the Local Network permission (E-3c).
///
/// The permission is a fact about the install, not about one attempt: the phone
/// stays on Tailscale and does not dial the LAN lane while this says denied.
/// Two observers write it, and the newer one wins. The app's one path monitor
/// writes what the system reports for the current path, which can also clear a
/// stale denial after the user changes the permission in Settings. A pinned dial
/// that iOS fails as "not connected" while the saved lane reaches the same Mac
/// confirms the denial from the connect path itself.
package final class GatewayLanPermissionRecord: @unchecked Sendable {
    private static let key = "gateway.lan-permission-denied"

    private let lock = NSLock()
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package var isDenied: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: Self.key)
    }

    package func markDenied() {
        lock.lock(); defer { lock.unlock() }
        defaults.set(true, forKey: Self.key)
    }

    /// The system's own report for the current network path (`NWPath`
    /// unsatisfied because the local network is denied). This is the live fact,
    /// so a path that no longer reports the denial clears it.
    package func update(systemDenied: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard defaults.bool(forKey: Self.key) != systemDenied else { return }
        defaults.set(systemDenied, forKey: Self.key)
    }
}
