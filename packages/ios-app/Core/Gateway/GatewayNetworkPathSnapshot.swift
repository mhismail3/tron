import Foundation

/// The interfaces of the device's current network path (for example
/// "wifi,other" while Tailscale is up), as last reported by the app's one
/// NWPathMonitor owner (`GatewayPathDiagnosticsObserver`). Connection records
/// read it to say which interface an attempt could use; it never gates,
/// retries, or replaces a connection.
package final class GatewayNetworkPathSnapshot: @unchecked Sendable {
    package static let shared = GatewayNetworkPathSnapshot()

    private let lock = NSLock()
    private var interfaces: String?

    package func update(interfaces: String) {
        lock.lock(); self.interfaces = interfaces; lock.unlock()
    }

    package var current: String? {
        lock.lock(); defer { lock.unlock() }
        return interfaces
    }
}

/// Handshake facts for one connection attempt's record.
package struct GatewayHandshakeDiagnostic: Sendable, Equatable {
    package init(transportOpened: Bool, transportOpenMilliseconds: Int?, waitedForConnectivity: Bool, networkInterfaces: String?) {
        self.transportOpened = transportOpened
        self.transportOpenMilliseconds = transportOpenMilliseconds
        self.waitedForConnectivity = waitedForConnectivity
        self.networkInterfaces = networkInterfaces
    }

    /// Whether the WebSocket opened: the socket reported opening, or the hello
    /// write completed (which requires an open socket).
    package let transportOpened: Bool
    package let transportOpenMilliseconds: Int?
    package let waitedForConnectivity: Bool
    package let networkInterfaces: String?
}
