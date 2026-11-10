import Foundation

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

    package func update(systemDenied: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard defaults.bool(forKey: Self.key) != systemDenied else { return }
        defaults.set(systemDenied, forKey: Self.key)
    }
}
