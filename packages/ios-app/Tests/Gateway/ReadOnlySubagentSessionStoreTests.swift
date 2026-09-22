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

    private func nextRequest(_ fixture: ProcessSheetGatewayFixture, method: String, after: Int) async throws -> Int {
        try await withTestWatchdog { @MainActor in
            while true {
                let frames = await fixture.socket.sentFrames()
                for index in frames.indices where index > after {
                    let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[index])
                    if request.objectValue?["method"]?.stringValue == method { return index }
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private func fail(_ fixture: ProcessSheetGatewayFixture, at index: Int, code: String) async throws {
        let value = try await request(fixture, at: index)
        let id = try #require(value["id"]?.stringValue)
        await fixture.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(false),
            "error": .object(["code": .string(code), "message": .string("Fixture unavailable"), "retryable": .bool(true)]),
        ])))
    }

    private func activity(bound: Bool, active: Bool) -> SessionProcessActivity {
        SessionProcessActivity(
            processId: "worker", kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
            lifecycle: SessionProcessLifecycle(state: active ? .running : .completed, sequence: 1,
                observedAt: "2026-01-01T00:00:02Z",
                terminalAt: active ? nil : "2026-01-01T00:00:02Z",
                recentUntil: active ? nil : "2026-01-01T00:05:02Z"),
            visibility: active ? .active : .recent, startedAt: "2026-01-01T00:00:00Z", title: "worker",
            toolCallId: "call-worker", runId: "run-worker", childSessionRef: bound ? "child-worker" : nil
        )
    }

    @Test("repeated completion updates cannot renew exhausted recovery; explicit retry can")
    func terminalUpdatesDoNotResetRecovery() async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        let completed = activity(bound: true, active: false)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1,
                   parentSubscriptionToken: "parent-token", activity: completed)
        var index = 0
        for attempt in 0..<4 {
            index = try await nextRequest(fixture, method: "session.processTranscript.open", after: index)
            try await fail(fixture, at: index, code: "busy")
            try await withTestWatchdog { @MainActor in
                while store.status == .opening { try await Task.sleep(for: .milliseconds(1)) }
            }
            for _ in 0..<10 { store.updateLiveActivity(completed) }
            if attempt < 3 { #expect(store.status == .waiting) }
        }
        if case .failed = store.status {} else { Issue.record("Recovery did not terminate: \(store.status)") }
        let requests = await fixture.socket.sentFrames()
        #expect(try requests.filter { try JSONDecoder.gateway.decode(JSONValue.self, from: $0).objectValue?["method"]?.stringValue == "session.processTranscript.open" }.count == 4)
        store.retry()
        let retry = try await nextRequest(fixture, method: "session.processTranscript.open", after: index)
        try await fixture.respond(at: retry, method: "session.processTranscript.open", result: ProcessSheetGatewayFixture.transcript(texts: ["recovered"]))
        try await withTestWatchdog { @MainActor in
            while store.status != .open { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(store.items.count == 1)
        store.close(); await fixture.client.close()
    }

    @Test("unbound child resumes at exact availability while running or after completion", arguments: [true, false])
    func delayedBindingAvailability(active: Bool) async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        let unbound = activity(bound: false, active: active)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1,
                   parentSubscriptionToken: "parent-token", activity: unbound)
        try await fail(fixture, at: 1, code: "not_found")
        try await withTestWatchdog { @MainActor in
            while store.status != (active ? .waiting : .unavailable) { try await Task.sleep(for: .milliseconds(1)) }
        }
        for _ in 0..<10 { store.updateLiveActivity(unbound) }
        #expect(store.status == (active ? .waiting : .unavailable))
        store.updateLiveActivity(activity(bound: true, active: active))
        let next = try await nextRequest(fixture, method: "session.processTranscript.open", after: 1)
        try await fixture.respond(at: next, method: "session.processTranscript.open", result: ProcessSheetGatewayFixture.transcript(texts: ["live child"]))
        try await withTestWatchdog { @MainActor in
            while store.status != .open { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(store.processID == "worker")
        store.close(); await fixture.client.close()
    }

    @Test("conflict recovery keeps the loaded transcript while reopening its exact viewer")
    func conflictPreservesLoadedTranscript() async throws {
        let fixture = ProcessSheetGatewayFixture()
        try await fixture.connect(capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
        let store = ReadOnlySubagentSessionStore(client: fixture.client)
        store.open(parentSessionID: "parent", processID: "worker", presentationGeneration: 1, parentSubscriptionToken: "parent-token")
        try await fixture.respond(at: 1, method: "session.processTranscript.open", result: ProcessSheetGatewayFixture.transcript(texts: ["visible"]))
        try await withTestWatchdog { @MainActor in
            while store.status != .open { try await Task.sleep(for: .milliseconds(1)) }
        }
        let viewer = try #require(store.leaseID)
        store.invalidate(ProcessTranscriptChanged(leaseId: viewer, processId: "worker", revision: "transcript-2", total: 2, leafEntryId: nil, closed: nil, reason: nil))
        let page = try await nextRequest(fixture, method: "session.processTranscript.page", after: 1)
        try await fail(fixture, at: page, code: "conflict")
        let reopened = try await nextRequest(fixture, method: "session.processTranscript.open", after: page)
        #expect(store.status == .reconnecting)
        #expect(store.items.map(\.id) == ["entry-0"])
        try await fixture.respond(at: reopened, method: "session.processTranscript.open", result: ProcessSheetGatewayFixture.transcript(texts: ["visible", "appended"]))
        try await withTestWatchdog { @MainActor in
            while store.status != .open { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(store.items.count == 2)
        store.close(); await fixture.client.close()
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
