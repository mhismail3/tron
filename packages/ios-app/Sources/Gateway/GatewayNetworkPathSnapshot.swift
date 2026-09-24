import Foundation

/// The interfaces of the device's current network path (for example
/// "wifi,other" while Tailscale is up), as last reported by the app's one
/// NWPathMonitor owner (`GatewayPathDiagnosticsObserver`). Connection records
/// read it to say which interface an attempt could use; it never gates,
/// retries, or replaces a connection.
final class GatewayNetworkPathSnapshot: @unchecked Sendable {
    static let shared = GatewayNetworkPathSnapshot()

    private let lock = NSLock()
    private var interfaces: String?

    func update(interfaces: String) {
        lock.lock(); self.interfaces = interfaces; lock.unlock()
    }

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return interfaces
    }
}

/// Handshake facts for one connection attempt's record.
struct GatewayHandshakeDiagnostic: Sendable, Equatable {
    /// Whether the WebSocket opened: the socket reported opening, or the hello
    /// write completed (which requires an open socket).
    let transportOpened: Bool
    let transportOpenMilliseconds: Int?
    let waitedForConnectivity: Bool
    let networkInterfaces: String?
}
