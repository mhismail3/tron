import Foundation

/// Explicit runtime identities for the Release-owned Stable Gateway and the
/// read-only developer-owned Debug projection.
struct TronGatewayProfile: Equatable, Sendable {
    let name: String
    let launchAgentLabel: String
    let channel: String
    let homeName: String
    let agentDirectoryName: String
    let port: Int
    let agentBundleName: String

    static let stable = TronGatewayProfile(
        name: "stable", launchAgentLabel: "com.tron.server", channel: "stable",
        homeName: ".tron", agentDirectoryName: "agent", port: 9847, agentBundleName: "Tron Agent"
    )
    /// Developer-owned Debug Gateway. Installed Release may authenticate to
    /// and report this profile, but no Mac wrapper manages its lifecycle.
    static let debug = TronGatewayProfile(
        name: "debug", launchAgentLabel: "com.tron.server.dev", channel: "dev",
        homeName: ".tron-dev", agentDirectoryName: "agent-dev", port: 9848, agentBundleName: "Tron Agent Dev"
    )
}

