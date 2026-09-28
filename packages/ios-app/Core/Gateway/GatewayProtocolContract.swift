import Foundation

/// One lockstep wire contract shared by every first-party Gateway client.
/// `config/GatewayProtocol.json` is the repository authority; build policy
/// verifies these compile-time values and the final signed artifact metadata.
package enum TronGatewayProtocolContract {
    package static let protocolVersion = 6
    package static let minimumProtocolVersion = 6
}
