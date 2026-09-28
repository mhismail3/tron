import Foundation

/// iOS values coupled to the Gateway's connection admission and liveness contract.
package enum GatewayConnectionPolicy {
    package static let clientPingInterval: Duration = .seconds(10)
    package static let clientPongDeadline: Duration = .seconds(8)
    /// Bounds the WebSocket open alone: a path that cannot open the socket is
    /// down, not slow, and must not spend the hello budget on a connect (D-4).
    package static let transportOpenDeadline: Duration = .seconds(5)
    /// Bounds the hello exchange and authentication after the socket opened.
    package static let helloDeadline: Duration = .seconds(15)
    package static let requestInactivityTimeout: TimeInterval = 60
    package static let gracefulCloseLimit: Duration = .seconds(1)
}

struct GatewayConnectionContractFixture: Decodable {
    struct Milliseconds: Decodable { let milliseconds: Int }
    struct Count: Decodable { let count: Int }
    let serverHeartbeatInterval: Milliseconds
    let serverMissedHeartbeatLimit: Count
    let serverHelloDeadline: Milliseconds
    let clientPingInterval: Milliseconds
    let clientPongDeadline: Milliseconds
    let clientTransportOpenDeadline: Milliseconds
    let clientHelloDeadline: Milliseconds
    let perIdentitySocketCap: Count
}
