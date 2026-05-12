import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("CapabilityClient")
struct CapabilityClientTests {
    @Test("status invokes capability status with admin read scope")
    func statusUsesCapabilityStatusFunction() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://localhost:8082")!)
        let client = CapabilityClient(transport: transport)
        transport.readHandler = { functionId, _, options in
            #expect(functionId.rawValue == "capability::status")
            #expect(options.context?.authorityScopes.contains("capability.admin.read") == true)
            return CapabilityStatusDTO(catalogRevision: 42)
        }

        let status = try await client.status()

        #expect(status.catalogRevision == 42)
    }

    @Test("set binding invokes capability binding set with write scope")
    func setBindingUsesCapabilityWriteScope() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://localhost:8082")!)
        let client = CapabilityClient(transport: transport)
        transport.writeHandler = { functionId, _, _, options in
            #expect(functionId.rawValue == "capability::binding_set")
            #expect(options.context?.authorityScopes.contains("capability.admin.write") == true)
            return AnyCodable(["updated": true])
        }

        let result = try await client.setBinding(
            contractId: "filesystem::read_file",
            selectedImplementation: "first_party.filesystem.v1.read_file",
            idempotencyKey: .userAction("test.binding")
        )

        #expect(result.dictionaryValue?["updated"] as? Bool == true)
    }
}
