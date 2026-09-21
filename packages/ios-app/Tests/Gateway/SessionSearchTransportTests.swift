import Foundation
import XCTest
@testable import TronMobile

@MainActor
final class SessionSearchTransportTests: XCTestCase {
    func testSelectedProfileSearchUsesLifecycleOwnedTransport() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let defaultsName = "SessionSearchTransportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let profile = GatewayProfile(id: "selected", label: "Selected", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device")
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: defaultsName)))
        defer {
            Task { @MainActor in await model.teardown(); await client.close(); defaults.removePersistentDomain(forName: defaultsName) }
        }
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","session-search.v1"]}"#.utf8))
        try await model.connectHostedGateway(profile: profile, token: "token")
        try await Task.sleep(for: .milliseconds(100))
        let target = SessionSearchProfileTarget(profileID: profile.id, label: profile.label, capabilities: ["session-search.v1"], isSelected: true)
        let search = Task { await model.searchSessions(query: "needle", targets: [target]) }
        let requestIndex = try await waitForRequest(method: "session.search", on: socket)
        let frame = await socket.sentFrames()[requestIndex]
        let request = try XCTUnwrap(JSONDecoder.gateway.decode(JSONValue.self, from: frame).objectValue)
        let response: JSONValue = .object([
            "query": .string("needle"), "queryRevision": .string("q"), "corpusRevision": .string("c"), "indexRevision": .string("i"),
            "coverage": .object(["state": .string("complete"), "sessionsIndexed": .number(1), "sessionsTotal": .number(1), "passagesIndexed": .number(1), "omittedSessions": .number(0)]),
            "semantic": .object(["state": .string("unavailable"), "vectorsIndexed": .number(0), "vectorsTotal": .number(0), "reason": .string("synthetic")]),
            "ranking": .object(["state": .string("lexical"), "jev": .string("disabled")]),
            "results": .array([]),
        ])
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": request["id"] ?? .null, "ok": .bool(true), "result": response,
        ])))
        let aggregate = await search.value
        XCTAssertEqual(aggregate.profiles.first?.profileID, profile.id)
        XCTAssertNotEqual(aggregate.profiles.first?.state, "offline")
    }

    func testPolicyReadCannotOverwriteNewerToggleReceipt() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let defaultsName = "SessionSearchPolicyRaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let profile = GatewayProfile(id: "selected", label: "Selected", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device")
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: defaultsName)))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","session-search.v1"]}"#.utf8))
        try await model.connectHostedGateway(profile: profile, token: "token")
        let restore = Task { await model.restoreSessionSearchPolicy(profileID: profile.id, force: true) }
        let getIndex = try await waitForRequest(method: "session.search.policy.get", on: socket)
        let toggle = Task { try await model.setSessionSearchRemoteRanking(true, profileID: profile.id) }
        let setIndex = try await waitForRequest(method: "session.search.policy.set", on: socket)
        let setSentFrames = await socket.sentFrames()
        let setFrame = try XCTUnwrap(JSONDecoder.gateway.decode(JSONValue.self, from: setSentFrames[setIndex]).objectValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object(["type": .string("response"), "id": setFrame["id"] ?? .null, "ok": .bool(true), "result": .object(["enabled": .bool(true), "perQueryMicroCents": .number(1), "dailyMicroCents": .number(2), "policyRevision": .number(2)])])))
        _ = try await toggle.value
        let getSentFrames = await socket.sentFrames()
        let getFrame = try XCTUnwrap(JSONDecoder.gateway.decode(JSONValue.self, from: getSentFrames[getIndex]).objectValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object(["type": .string("response"), "id": getFrame["id"] ?? .null, "ok": .bool(true), "result": .object(["enabled": .bool(false), "perQueryMicroCents": .number(1), "dailyMicroCents": .number(2), "policyRevision": .number(1)])])))
        await restore.value
        XCTAssertTrue(model.sessionSearchConsent(for: profile.id))
        await model.teardown(); await client.close(); defaults.removePersistentDomain(forName: defaultsName)
    }

    func testBackgroundAnchorUsesCapturedPoolConnection() async throws {
        let socket = ScriptedGatewaySocket()
        let pool = DashboardGatewayConnectionPool(clientFactory: { GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory) })
        let profile = GatewayProfile(id: "background", label: "Background", host: "gateway.test", port: 9847, machineId: "machine", machineGroupID: "group", deviceId: "device")
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineGroupID":"group","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","session-search.v1"]}"#.utf8))
        pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
        for _ in 0..<100 where pool.requestAdmission(for: profile.id) == nil { try await Task.sleep(for: .milliseconds(10)) }
        let coordinator = SessionSearchCoordinator()
        let searchTask = Task { try await coordinator.search(query: "needle", profileID: profile.id, connections: pool) }
        let searchRequest = try await waitForRequest(method: "session.search", on: socket)
        let searchFrame = await socket.sentFrames()[searchRequest]
        let searchID = try XCTUnwrap(JSONDecoder.gateway.decode(JSONValue.self, from: searchFrame).objectValue?["id"]?.stringValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(searchID), "ok": .bool(true),
            "result": .object(["query": .string("needle"), "queryRevision": .string("q"), "corpusRevision": .string("c"), "indexRevision": .string("i"), "coverage": .object(["state": .string("complete"), "sessionsIndexed": .number(1), "sessionsTotal": .number(1), "passagesIndexed": .number(1), "omittedSessions": .number(0)]), "semantic": .object(["state": .string("unavailable"), "vectorsIndexed": .number(0), "vectorsTotal": .number(0), "reason": .string("synthetic")]), "ranking": .object(["state": .string("lexical"), "jev": .string("disabled")]), "results": .array([])])
        ])))
        _ = try await searchTask.value
        let result = SessionSearchResult(sessionId: "session", gatewayProfileID: profile.id, title: "Session", cwd: "/tmp", updatedAt: "2026-01-01T00:00:00Z", entryId: "entry", parentEntryId: nil, ordinal: 3, passageKind: "message", snippet: "needle", lexicalScore: 1, semanticScore: nil, jevScore: nil, anchorRevision: SessionSearchAnchorRevision(indexRevision: "i", fileIdentity: "file", branchDigest: "branch", leafEntryId: nil, entryOrdinal: 3, forkBoundary: nil))
        let anchorTask = Task { try await coordinator.anchor(result: result, profileID: profile.id, runtimeGeneration: "runtime", leafEntryID: nil, connections: pool, windowEnd: 8) }
        let anchorRequest = try await waitForRequest(method: "session.search.anchor", on: socket)
        let anchorFrame = await socket.sentFrames()[anchorRequest]
        let anchorID = try XCTUnwrap(JSONDecoder.gateway.decode(JSONValue.self, from: anchorFrame).objectValue?["id"]?.stringValue)
        let item: JSONValue = .object(["id": .string("entry"), "parentId": .null, "kind": .string("message"), "role": .string("user"), "presentationId": .string("entry"), "content": .array([.object(["id": .string("entry:0"), "ordinal": .number(0), "type": .string("text"), "text": .string("needle")])]), "timestamp": .string("2026-01-01T00:00:00Z")])
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(anchorID), "ok": .bool(true), "result": .object(["sessionId": .string("session"), "entryId": .string("entry"), "start": .number(3), "end": .number(4), "total": .number(10), "items": .array([item]), "runtimeGeneration": .string("runtime"), "leafEntryId": .null, "targetOrdinal": .number(3), "hasEarlier": .bool(true), "hasLater": .bool(true)])
        ])))
        let anchor = try await anchorTask.value
        XCTAssertEqual(anchor.entryId, result.entryId)
        XCTAssertEqual(anchor.runtimeGeneration, "runtime")
        pool.retire()
    }

    func testPolicyGetRestoresEnabledConsentAfterAdmission() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let defaultsName = "SessionSearchPolicyRestoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let profile = GatewayProfile(id: "selected", label: "Selected", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device")
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: defaultsName)))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","session-search.v1"]}"#.utf8))
        try await model.connectHostedGateway(profile: profile, token: "token")
        let restore = Task { await model.restoreSessionSearchPolicy(profileID: profile.id, force: true) }
        let requestIndex = try await waitForRequest(method: "session.search.policy.get", on: socket)
        let requestFrame = await socket.sentFrames()[requestIndex]
        let request = try XCTUnwrap(JSONDecoder.gateway.decode(JSONValue.self, from: requestFrame).objectValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": request["id"] ?? .null, "ok": .bool(true),
            "result": .object(["enabled": .bool(true), "perQueryMicroCents": .number(268_800), "dailyMicroCents": .number(2_688_000), "policyRevision": .number(4)]),
        ])))
        await restore.value
        XCTAssertTrue(model.sessionSearchConsent(for: profile.id))
        await model.teardown(); await client.close(); defaults.removePersistentDomain(forName: defaultsName)
    }

    private func waitForRequest(method: String, on socket: ScriptedGatewaySocket) async throws -> Int {
        for _ in 0..<100 {
            let frames = await socket.sentFrames()
            for (index, frame) in frames.enumerated() {
                if let object = try? JSONDecoder.gateway.decode(JSONValue.self, from: frame).objectValue,
                   object["method"]?.stringValue == method { return index }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let methods = (try? await socket.sentFrames().compactMap { try JSONDecoder.gateway.decode(JSONValue.self, from: $0).objectValue?["method"]?.stringValue }.joined(separator: ",")) ?? "<invalid>"
        throw NSError(domain: "SessionSearchTransportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Scripted Gateway did not receive \(method); sent=\(methods)"])
    }
}
