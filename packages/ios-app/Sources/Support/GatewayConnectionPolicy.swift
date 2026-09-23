import Foundation

/// iOS values coupled to the Gateway's connection admission and liveness contract.
enum GatewayConnectionPolicy {
    static let clientPingInterval: Duration = .seconds(10)
    static let clientPongDeadline: Duration = .seconds(8)
    static let handshakeDeadline: Duration = .seconds(15)
    static let requestInactivityTimeout: TimeInterval = 60
    static let gracefulCloseLimit: Duration = .seconds(1)
}

struct GatewayConnectionContractFixture: Decodable {
    struct Milliseconds: Decodable { let milliseconds: Int }
    struct Count: Decodable { let count: Int }
    let serverHeartbeatInterval: Milliseconds
    let serverMissedHeartbeatLimit: Count
    let serverHelloDeadline: Milliseconds
    let clientPingInterval: Milliseconds
    let clientPongDeadline: Milliseconds
    let clientHandshakeDeadline: Milliseconds
    let perIdentitySocketCap: Count
}
