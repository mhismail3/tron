import Foundation
import Testing
@testable import TronMobile

@Suite("Gateway update control plane")
struct GatewayUpdateControlPlaneTests {
    @Test("older GatewayInfo remains decodable and runtime identity is optional")
    func legacyInfoDecodes() throws {
        let data = Data(#"{"gatewayVersion":"1","piVersion":"2","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","capabilities":[]}"#.utf8)
        let info = try JSONDecoder.gateway.decode(GatewayInfo.self, from: data)
        #expect(info.machineGroupID == "machine")
        #expect(info.sourceRevision == nil)
        #expect(info.runtimeEpoch == nil)
    }

    @Test("update config admits legacy optional artifact roots and bounded paths")
    func updateConfigAdmission() throws {
        let data = Data(#"{"schema":1,"kind":"tron-gateway-update-config","sourceRoot":"/Users/name/Workspace/tron","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        let config = try JSONDecoder.gateway.decode(GatewayUpdateConfig.self, from: data)
        #expect(config.artifactRoot == nil)
        #expect(config.sourceRoot == "/Users/name/Workspace/tron")
        #expect(throws: GatewayFailure.self) {
            _ = try JSONDecoder.gateway.decode(
                GatewayUpdateConfig.self,
                from: Data(#"{"schema":1,"kind":"tron-gateway-update-config","sourceRoot":"relative/path","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
            )
        }
        #expect(throws: GatewayFailure.self) {
            _ = try GatewayUpdateConfig(
                sourceRoot: "/" + String(repeating: "x", count: GatewayUpdateConfigPolicy.maximumPathBytes),
                updatedAt: "2026-01-01T00:00:00Z"
            )
        }
    }

    @Test("status presentation is bounded and candidate availability is explicit")
    func statusPresentation() {
        let available = GatewayUpdateStatus(
            state: "ready", channel: "stable", currentIdentity: nil,
            candidateIdentity: GatewayUpdateIdentity(version: "2026.01", gatewayVersion: nil, sourceRevision: nil, runtimeEpoch: nil, payloadFingerprint: nil),
            candidateAvailable: true, error: nil, updatedAt: "2026-01-01T00:00:00Z"
        )
        #expect(available.presentationTitle == "Update available")
        let unavailable = GatewayUpdateStatus(
            state: "unknown", channel: "stable", currentIdentity: nil, candidateIdentity: nil,
            candidateAvailable: false, error: "unsupported", updatedAt: nil
        )
        #expect(unavailable.presentationTitle == "Unavailable")
        #expect(AppModel.supportsGatewayUpdate(capabilities: ["restart-drain.v1"]) == false)
        #expect(AppModel.supportsGatewayUpdate(capabilities: ["gateway-update.v1"]))
    }
}
