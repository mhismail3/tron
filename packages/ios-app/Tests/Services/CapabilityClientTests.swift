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

    @Test("search uses explicit operator lexical-degraded policy")
    func searchUsesOperatorLexicalPolicy() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://localhost:8082")!)
        let client = CapabilityClient(transport: transport)
        transport.readHandler = { functionId, _, options in
            #expect(functionId.rawValue == "capability::search")
            #expect(options.context?.authorityScopes.contains("capability.search") == true)
            let metadata = options.context?.runtimeMetadata ?? [:]
            #expect(metadata["capability.searchPolicyId"] == "operatorConsoleHybridLexical")
            #expect(metadata["capability.searchPolicy"]?.contains(#""requireLocalVector":false"#) == true)
            #expect(metadata["capability.searchPolicy"]?.contains(#""allowLexicalOnlyWhenDegraded":true"#) == true)
            return CapabilityPrimitiveResultDTO(
                content: nil,
                details: AnyCodable([
                    "query": "read file",
                    "catalogRevision": 303,
                    "results": [],
                    "searchMode": [
                        "lexical": true,
                        "localVector": true,
                        "state": "unavailable",
                        "degradedReason": "embedding assets unavailable"
                    ]
                ]),
                isError: nil,
                stopTurn: nil
            )
        }

        let result = try await client.search(CapabilitySearchRequestDTO(query: "read file", limit: 25))

        #expect(result.catalogRevision == 303)
        #expect(result.searchMode?.state == "unavailable")
        #expect(result.searchMode?.degradedReason == "embedding assets unavailable")
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

    @Test("program execute invokes capability execute with JavaScript schema")
    func executeProgramUsesCapabilityPrimitive() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://localhost:8082")!)
        let client = CapabilityClient(transport: transport)
        transport.writeHandler = { functionId, payload, idempotencyKey, options in
            #expect(functionId.rawValue == "capability::execute")
            #expect(idempotencyKey.rawValue.contains("test.program"))
            #expect(options.context?.authorityScopes.contains("capability.execute") == true)
            #expect(options.context?.authorityScopes.contains("contract.allow:program::run_javascript") == true)
            let fields = Dictionary(
                uniqueKeysWithValues: Mirror(reflecting: payload).children.compactMap { child in
                    child.label.map { ($0, child.value) }
                }
            )
            #expect(fields["mode"] as? String == "program")
            #expect(fields["language"] as? String == "javascript")
            #expect(fields["code"] as? String == "return args;")
            #expect(fields["inspectionHandle"] as? String == "capability-inspection:v1:program")
            #expect(fields["expectedRevision"] as? UInt64 == 12)
            #expect(fields["expectedSchemaDigest"] as? String == "sha256:program")
            return CapabilityPrimitiveResultDTO(
                content: nil,
                details: AnyCodable([
                    "status": "ok",
                    "programRunId": "program_run_test",
                    "parentInvocationId": "invocation_parent",
                    "rootInvocationId": "invocation_root",
                    "bindingDecisionId": "binding_decision_test",
                    "codeHash": "code",
                    "argsHash": "args",
                    "childInvocations": [],
                    "selectedImplementations": [],
                    "compensationAttempts": []
                ]),
                isError: nil,
                stopTurn: nil
            )
        }

        let result = try await client.executeProgram(
            code: "return args;",
            inspectionHandle: "capability-inspection:v1:program",
            expectedRevision: 12,
            expectedSchemaDigest: "sha256:program",
            idempotencyKey: .userAction("test.program")
        )

        #expect(result.programRunId == "program_run_test")
        #expect(result.bindingDecisionId == "binding_decision_test")
    }

    @Test("program run list invokes capability admin read path")
    func programRunListUsesCapabilityAdminReadScope() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://localhost:8082")!)
        let client = CapabilityClient(transport: transport)
        transport.readHandler = { functionId, _, options in
            #expect(functionId.rawValue == "capability::program_run_list")
            #expect(options.context?.authorityScopes.contains("capability.admin.read") == true)
            return CapabilityProgramRunQueryResultDTO(programRuns: [], redacted: true)
        }

        let result = try await client.programRunList()

        #expect(result.redacted == true)
    }
}
