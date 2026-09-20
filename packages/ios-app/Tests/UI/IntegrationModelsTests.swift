import XCTest
@testable import TronMobile

final class IntegrationModelsTests: XCTestCase {
    func testSnapshotDecodesRedactedInstancesAndConnectionScopedCapabilities() throws {
        let data = Data(#"""
        {
          "definitions": [{"schemaVersion":1,"id":"knowledge.raindrop","implementation":"knowledge-connector","displayName":"Raindrop","setupMethods":["token"],"capabilities":[{"id":"read","displayName":"Read bookmarks","effects":["read"],"supported":true}]}],
          "instances": [{"id":"account-a","definitionId":"knowledge.raindrop","implementation":"knowledge-connector","providerAccountId":"user-a","scope":"personal","credentialConfigured":true,"policy":{"enabled":true,"allowWrites":false,"paidAccessApproved":false,"paidBudgetCents":0,"recurringApproved":false},"health":"ready","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","setupRevision":1}],
          "setupOperations": [],
          "capabilities": [{"id":"read","availability":"available","effects":["read"],"definitionId":"knowledge.raindrop","connectionId":"account-a","provenance":{"owner":"connection","definitionId":"knowledge.raindrop","connectionId":"account-a"}}],
          "stateRevision": 3
        }
        """#.utf8)
        let snapshot = try JSONDecoder.gateway.decode(IntegrationSnapshot.self, from: data)
        XCTAssertEqual(snapshot.instances.map(\.id), ["account-a"])
        XCTAssertEqual(snapshot.capabilities.first?.connectionId, "account-a")
        XCTAssertEqual(snapshot.instances.first?.credentialConfigured, true)
        XCTAssertNil(snapshot.instances.first?.lastError)
    }

    func testPresentationAdmissionDropsRetiredOrOutOfOrderReads() {
        let first = KnowledgePresentationIdentity(profileID: "profile-a", lifecycleGeneration: 1, connectionID: 10)
        let replacement = KnowledgePresentationIdentity(profileID: "profile-b", lifecycleGeneration: 2, connectionID: 11)
        XCTAssertTrue(IntegrationPresentationAdmission.admits(presentationActive: true, currentIdentity: first, requestedIdentity: first, currentRequest: 2, requestedRequest: 2))
        XCTAssertFalse(IntegrationPresentationAdmission.admits(presentationActive: false, currentIdentity: first, requestedIdentity: first, currentRequest: 2, requestedRequest: 2))
        XCTAssertFalse(IntegrationPresentationAdmission.admits(presentationActive: true, currentIdentity: replacement, requestedIdentity: first, currentRequest: 2, requestedRequest: 2))
        XCTAssertFalse(IntegrationPresentationAdmission.admits(presentationActive: true, currentIdentity: first, requestedIdentity: first, currentRequest: 3, requestedRequest: 2))
    }

    func testConnectionCapabilityIdentityDoesNotCollapseSameProviderInstances() {
        let first = IntegrationCapabilityStatus(id: "read", availability: "available", effects: ["read"], definitionId: "knowledge.raindrop", connectionId: "account-a", provenance: IntegrationCapabilityProvenance(owner: "connection", definitionId: "knowledge.raindrop", connectionId: "account-a"), detail: nil)
        let second = IntegrationCapabilityStatus(id: "read", availability: "disabled", effects: ["read"], definitionId: "knowledge.raindrop", connectionId: "account-b", provenance: IntegrationCapabilityProvenance(owner: "connection", definitionId: "knowledge.raindrop", connectionId: "account-b"), detail: nil)
        XCTAssertNotEqual(first.instanceCapabilityID, second.instanceCapabilityID)
        XCTAssertEqual(first.connectionId, "account-a")
        XCTAssertEqual(second.connectionId, "account-b")
    }

    @MainActor
    func testIntegrationListRejectsNonConnectionCapabilityProvenance() async {
        let client = IntegrationsRPCClient(request: { _, _, _ in
            .object([
                "definitions": .array([]), "instances": .array([]), "setupOperations": .array([]),
                "capabilities": .array([.object([
                    "id": .string("tools"), "availability": .string("available"), "effects": .array([.string("read")]),
                    "definitionId": .string("mcp.remote-http"), "provenance": .object(["owner": .string("agent"), "definitionId": .string("mcp.remote-http")])
                ])]), "stateRevision": .number(1)
            ])
        })
        do {
            _ = try await client.snapshot()
            XCTFail("Non-owner provenance must not reach native management UI")
        } catch let failure as GatewayFailure {
            XCTAssertEqual(failure.code, "invalid_response")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
