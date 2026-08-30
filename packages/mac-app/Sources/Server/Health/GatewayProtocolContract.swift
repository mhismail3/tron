import Foundation

/// One lockstep wire contract shared by every Mac-side Gateway client.
/// `config/GatewayProtocol.json` is the repository authority; build policy
/// verifies these compile-time values and the final app/payload metadata.
enum TronGatewayProtocolContract {
    static let protocolVersion = 4
    static let minimumProtocolVersion = 4
}
