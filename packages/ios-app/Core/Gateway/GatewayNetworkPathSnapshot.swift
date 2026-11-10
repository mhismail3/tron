import Foundation

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

package struct GatewayHandshakeDiagnostic: Sendable, Equatable {
    package init(transportOpened: Bool, transportOpenMilliseconds: Int?, waitedForConnectivity: Bool, networkInterfaces: String?, transport: String? = nil) {
        self.transportOpened = transportOpened
        self.transportOpenMilliseconds = transportOpenMilliseconds
        self.waitedForConnectivity = waitedForConnectivity
        self.networkInterfaces = networkInterfaces
        self.transport = transport
    }

    package let transportOpened: Bool
    let transportOpenMilliseconds: Int?
    let waitedForConnectivity: Bool
    package let networkInterfaces: String?
    package let transport: String?
}
