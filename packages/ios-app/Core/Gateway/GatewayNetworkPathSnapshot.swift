import Foundation

/// The interfaces of the device's current network path (for example
/// "wifi,other" while Tailscale is up), as last reported by the app's one
/// NWPathMonitor owner (`GatewayPathDiagnosticsObserver`). Connection records
/// read it to say which interface an attempt could use, and the LAN lane's
/// availability is read from it (the lane is dialed only on Wi-Fi, E-3c); it
/// does not replace a connection.
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
    package init(transportOpened: Bool, transportOpenMilliseconds: Int?, waitedForConnectivity: Bool, networkInterfaces: String?, transport: String? = nil) {
        self.transportOpened = transportOpened
        self.transportOpenMilliseconds = transportOpenMilliseconds
        self.waitedForConnectivity = waitedForConnectivity
        self.networkInterfaces = networkInterfaces
        self.transport = transport
    }

    /// Whether the WebSocket opened: the socket reported opening, or the hello
    /// write completed (which requires an open socket).
    package let transportOpened: Bool
    let transportOpenMilliseconds: Int?
    let waitedForConnectivity: Bool
    package let networkInterfaces: String?
    /// Which lane this attempt's socket dialed: `lan` or `tailscale` (E-3c).
    /// nil when no lane was raced (a saved endpoint with no advertisement).
    package let transport: String?
}
