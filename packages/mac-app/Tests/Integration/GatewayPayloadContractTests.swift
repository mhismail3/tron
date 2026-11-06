import Foundation
import Testing
@testable import TronMac

/// The payload manifest and selection formats are written by
/// `scripts/gateway-payload-deploy.mjs` and `bundle-gateway.sh`, and read by the C
/// launcher and this store. Each side's tests assert its own literals against the
/// one shared contract, `packages/mac-app/scripts/gateway-payload-contract.json`.
struct GatewayPayloadContractTests {
    private struct Contract: Decodable {
        let schema: Int
        let payloadKind: String
        let selectionKind: String
        let dependencyTreeCoverage: String
        let manifestKeys: [String]
        let selectionKeys: [String]
    }

    private static func contract() throws -> Contract {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/gateway-payload-contract.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    @Test func storeReadsTheSharedPayloadContract() throws {
        let contract = try Self.contract()
        #expect(GatewayPayloadStore.schema == contract.schema)
        #expect(GatewayPayloadManifest.payloadKind == contract.payloadKind)
        #expect(GatewayPayloadManifest.selectionKind == contract.selectionKind)
        #expect(GatewayPayloadStore.fingerprintCoverage == contract.dependencyTreeCoverage)
        #expect(GatewayPayloadStore.manifestKeys.sorted() == contract.manifestKeys.sorted())
        #expect(GatewayPayloadStore.selectionKeys.sorted() == contract.selectionKeys.sorted())
        #expect(Set(GatewayPayloadStore.manifestKeys).count == GatewayPayloadStore.manifestKeys.count)
    }
}
