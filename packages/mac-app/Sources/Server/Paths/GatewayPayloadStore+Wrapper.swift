import Foundation

extension GatewayPayloadStore {
    static func channel(environment: [String: String]) -> String {
        let value = environment[TronPaths.gatewayChannelEnv] ?? "stable"
        return validChannel(value) ? value : "stable"
    }

    static func selected(home: URL = TronPaths.tronHome, environment: [String: String]) -> GatewayPayloadStore {
        GatewayPayloadStore(home: home, channel: channel(environment: environment))
    }

}
