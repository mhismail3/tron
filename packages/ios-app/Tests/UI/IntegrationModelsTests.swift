@testable import TronMobileCore
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

    func testProviderDisplayTitlePrefersVerifiedMetadataAndUsesHonestAccountFallback() throws {
        let data = Data(#"""
        {"id":"account-a","definitionId":"knowledge.raindrop","implementation":"knowledge-connector","providerAccountId":"12345","providerDisplayName":"person@example.test","credentialConfigured":true,"policy":{"enabled":true,"allowWrites":false,"paidAccessApproved":false,"paidBudgetCents":0,"recurringApproved":false},"health":"ready","createdAt":"fixture","updatedAt":"fixture","setupRevision":4}
        """#.utf8)
        let withMetadata = try JSONDecoder.gateway.decode(IntegrationInstance.self, from: data)
        XCTAssertEqual(withMetadata.displayTitle, "person@example.test")
        let withoutMetadata = IntegrationInstance(id: "account-b", definitionId: "knowledge.raindrop", implementation: "knowledge-connector", providerAccountId: "67890", scope: nil, credentialConfigured: true, credentialAvailability: nil, providerIdentity: nil, providerDisplayName: nil, raindropCollections: nil, policy: withMetadata.policy, health: "ready", createdAt: "fixture", updatedAt: "fixture", setupRevision: 1, lastError: nil)
        XCTAssertEqual(withoutMetadata.displayTitle, "Account")
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
    func testPolicyMutationCarriesObservedRevisionAndExactConnection() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = GatewayLifecycleCoordinator(client: gateway, profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous, reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
            pairingCommit: { _, _ in }, profileTokenLookup: { _ in nil })
        let executor = ConfirmedMutationExecutor(client: gateway, lifecycle: lifecycle, clock: .continuous, performanceSignposts: RecordingPerformanceSignposts())
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":6,"minProtocolVersion":6,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
        do {
            try await lifecycle.connectHosted(profile: GatewayProfile(id: "fixture", label: "Fixture", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device"), token: "fixture-token")
            let policy = IntegrationPolicy(enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false)
            var captured: JSONValue?
            let client = IntegrationsRPCClient(request: { method, parameters in
                XCTAssertEqual(method, "connections.policy.update")
                captured = parameters
                return try JSONValue.encode(IntegrationSetupCompleted(id: "account-two", definitionId: "knowledge.raindrop", implementation: "knowledge-connector", providerAccountId: "fixture", scope: nil, policy: policy, health: "setup-required", createdAt: "fixture", updatedAt: "fixture", setupRevision: 8, lastError: nil))
            }, mutationExecutor: executor)
            _ = try await client.updatePolicy(instanceID: "account-two", expectedSetupRevision: 7, policy: policy)
            XCTAssertEqual(captured?.objectValue?["instanceId"], .string("account-two"))
            XCTAssertEqual(captured?.objectValue?["expectedSetupRevision"], .number(7))
            XCTAssertNotNil(captured?.objectValue?["commandId"]?.stringValue)
        } catch { await gateway.close(); throw error }
        await gateway.close()
    }

    @MainActor
    func testXCreditsAcceptsProviderRoundedDecimalTotal() async throws {
        let client = IntegrationsRPCClient(request: { _, _ in
            try JSONValue.encode(IntegrationXCredits(freeBalance: 0.2, prepaidBalance: 0.1, totalBalance: 0.3))
        })
        let credits = try await client.xCredits(connectionID: "x-reader")
        XCTAssertEqual(credits.totalBalance, 0.3)
    }

    /// Failure mode: an X balance requested under one Gateway profile resolves
    /// after the user switched profiles and is published on the new profile's
    /// sheet. The UI fixture cannot hold a reply across its reconnect, so the
    /// held request here is the only proof of the identity fence.
    @MainActor
    func testCreditReadStartedUnderPreviousIdentityIsNeverPublished() async throws {
        let gate = CreditGate()
        let client = IntegrationsRPCClient(request: { _, _ in
            await gate.wait()
            return try JSONValue.encode(IntegrationXCredits(freeBalance: 0, prepaidBalance: 4.2, totalBalance: 4.2))
        })
        let x = IntegrationInstance(id: "x-1", definitionId: "knowledge.x", implementation: "knowledge-connector", providerAccountId: "98765", scope: nil, credentialConfigured: true, credentialAvailability: nil, providerIdentity: nil, providerDisplayName: "@reader", raindropCollections: nil, policy: IntegrationPolicy(enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 100, recurringApproved: false), health: "ready", createdAt: "fixture", updatedAt: "fixture", setupRevision: 1, lastError: nil)
        let first = KnowledgePresentationIdentity(profileID: "gateway-a", lifecycleGeneration: 1, connectionID: 1)
        var current = first
        let controller = IntegrationCreditsReadController()
        controller.start(instances: [x], identity: first, client: client, presentationActive: { true }, currentIdentity: { current })
        await gate.untilWaiting()
        XCTAssertEqual(controller.loadingIDs, ["x-1"])
        current = KnowledgePresentationIdentity(profileID: "gateway-b", lifecycleGeneration: 1, connectionID: 2)
        await gate.release()
        for _ in 0..<50 where controller.loadingIDs.contains("x-1") { await Task.yield() }
        XCTAssertNil(controller.balances["x-1"], "A balance read for the previous profile must not be shown")
        XCTAssertFalse(controller.loadingIDs.contains("x-1"), "A discarded read must not leave the row loading")
    }

    @MainActor
    func testIntegrationListRejectsNonConnectionCapabilityProvenance() async {
        let client = IntegrationsRPCClient(request: { _, _ in
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

/// Holds one credit reply open until the test has changed the presentation identity.
private actor CreditGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
            waiting.forEach { $0.resume() }; waiting.removeAll()
        }
    }
    func untilWaiting() async {
        if waiter != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
