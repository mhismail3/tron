import Foundation
import Testing
@testable import TronMobile

@Suite("Read-only subagent viewer ownership", .serialized)
@MainActor
struct ReadOnlySubagentSessionStoreTests {
    private func request(_ fixture: ProcessSheetGatewayFixture, at index: Int) async throws -> [String: JSONValue] {
        try await fixture.waitForRequest(at: index)
        return try #require(JSONDecoder.gateway.decode(JSONValue.self, from: await fixture.socket.sentFrames()[index]).objectValue)
    }

    @Test("dismissal retires the preallocated viewer before an open response exists")
    func dismissDuringOpen() async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1, parentSubscriptionToken: "parent-token")
        let opening = try await request(fixture, at: 1)
        let viewer = try #require(opening["params"]?.objectValue?["viewerId"]?.stringValue)
        #expect(opening["params"]?.objectValue?["subscriptionToken"]?.stringValue == "parent-token")
        store.close()
        let close = try await request(fixture, at: 2)
        #expect(close["method"]?.stringValue == "session.processTranscript.close")
        #expect(close["params"]?.objectValue?["leaseId"]?.stringValue == viewer)
        #expect(store.status == .idle)
        await fixture.client.close()
    }

    @Test("malformed open fails visibly and closes only its own allocated viewer")
    func malformedOpen() async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1, parentSubscriptionToken: "parent-token")
        let opening = try await request(fixture, at: 1)
        let viewer = try #require(opening["params"]?.objectValue?["viewerId"]?.stringValue)
        var response = try #require(ProcessSheetGatewayFixture.transcript(texts: []).objectValue)
        response["leaseId"] = .string("another-viewer")
        try await fixture.respond(at: 1, method: "session.processTranscript.open", result: .object(response))
        let close = try await request(fixture, at: 2)
        #expect(close["params"]?.objectValue?["leaseId"]?.stringValue == viewer)
        if case .failed = store.status {} else { Issue.record("Malformed response left viewer in \(store.status)") }
        store.close()
        await fixture.client.close()
    }

    @Test("append during prepend waits for and drains the historical read lane")
    func appendDuringPrepend() async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1, parentSubscriptionToken: "parent-token")
        let opening = try await request(fixture, at: 1)
        let viewer = try #require(opening["params"]?.objectValue?["viewerId"]?.stringValue)
        var response = try #require(ProcessSheetGatewayFixture.transcript(texts: ["first", "second"]).objectValue)
        var page = try #require(response["page"]?.objectValue)
        let items = try #require(page["items"]?.arrayValue)
        page["items"] = .array([items[1]])
        page["start"] = .number(1)
        response["page"] = .object(page)
        try await fixture.respond(at: 1, method: "session.processTranscript.open", result: .object(response))
        try await withTestWatchdog { @MainActor in
            while store.status != .open { try await Task.sleep(for: .milliseconds(1)) }
        }
        store.loadEarlier()
        let earlier = try await request(fixture, at: 2)
        #expect(earlier["params"]?.objectValue?["before"] == .number(1))
        store.invalidate(ProcessTranscriptChanged(leaseId: viewer, processId: "worker", revision: "transcript-2", total: 3, leafEntryId: nil, closed: nil, reason: nil))
        page["items"] = .array([items[0]])
        page["start"] = .number(0)
        page["end"] = .number(1)
        page["nextEntryId"] = .string("entry-1")
        page["revision"] = .string("transcript-1")
        try await fixture.respond(at: 2, method: "session.processTranscript.page", result: .object(page))
        let refresh = try await request(fixture, at: 3)
        #expect(refresh["method"]?.stringValue == "session.processTranscript.page")
        #expect(refresh["params"]?.objectValue?["before"] == nil)
        #expect(store.items.map(\.id) == ["entry-0", "entry-1"])
        store.close()
        await fixture.client.close()
    }

    @Test("invalidation received before baseline response drains after opening")
    func openingInvalidation() async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1, parentSubscriptionToken: "parent-token")
        let opening = try await request(fixture, at: 1)
        let viewer = try #require(opening["params"]?.objectValue?["viewerId"]?.stringValue)
        store.invalidate(ProcessTranscriptChanged(leaseId: viewer, processId: "worker", revision: "transcript-2", total: 1, leafEntryId: nil, closed: nil, reason: nil))
        try await fixture.respond(at: 1, method: "session.processTranscript.open", result: ProcessSheetGatewayFixture.transcript(texts: []))
        let refresh = try await request(fixture, at: 2)
        #expect(refresh["method"]?.stringValue == "session.processTranscript.page")
        #expect(refresh["params"]?.objectValue?["leaseId"]?.stringValue == viewer)
        #expect(refresh["params"]?.objectValue?["expectedRevision"]?.stringValue == "transcript-1")
        store.close()
        await fixture.client.close()
    }
}
