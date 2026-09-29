import Foundation

/// Whether iOS denied this install the Local Network permission (E-3c).
///
/// The permission is granted once per install, so a denial outlives a launch:
/// the phone stays on Tailscale and does not dial the LAN lane again until the
/// user changes the permission in Settings. The flag is the lane's whole
/// availability decision — a LAN the phone is merely away from is not a denial
/// and still gets dialed on the next attempt.
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
}
