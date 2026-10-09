import Foundation
import Testing
@testable import TronMobileCore
@testable import TronMobile

/// DTO/store checks cover wire cases a hosted app journey cannot supply together:
/// unknown future producers must not be hidden, and cold/live snapshots must agree.
@MainActor
@Suite("Managed subagent presentation")
struct ManagedSubagentPresentationTests {
    private func owner(_ kind: String?) throws -> ExtensionOwner {
        let fields: [String: JSONValue] = ["id": .string("provider"), "title": .string("Subagents"),
            "source": .string("tron:pi-subagents@fixture#build")]
        var value = fields
        if let kind { value["kind"] = .string(kind) }
        return try JSONDecoder.gateway.decode(ExtensionOwner.self, from: JSONEncoder.gateway.encode(JSONValue.object(value)))
    }

    @Test("owner classification survives decode; absent and future producers remain presentable")
    func ownerClassification() throws {
        for kind: String? in ["subagent", "extension", nil, "future-provider"] {
            let decoded = try owner(kind)
            let encoded = try JSONValue.encode(decoded)
            if kind == "subagent" || kind == "extension" {
                #expect(encoded.objectValue?["kind"]?.stringValue == kind)
            }
            let content = ExtensionRetainedContentPolicy.content(widgets: [
                ExtensionWidget(key: "private", lines: ["PI_SUBAGENT_ASYNC_JSON: private"], placement: .aboveEditor, owner: decoded)
            ], surfaces: nil, statuses: ["status": "private status"], statusOwners: ["status": decoded])
            #expect(content.isEmpty == (kind == "subagent"))
        }
    }

    @Test("component provenance uses the same typed classification, never a source spelling")
    func componentClassification() throws {
        for kind: String? in ["subagent", "extension", nil, "future-provider"] {
            var raw: [String: JSONValue] = ["source": .string("npm:pi-subagents@historic")]
            if let kind { raw["kind"] = .string(kind) }
            let provenance = try JSONDecoder.gateway.decode(ExtensionSurface.Provenance.self, from: JSONEncoder.gateway.encode(JSONValue.object(raw)))
            let surface = ExtensionSurface(id: "frame", kind: .widget, placement: .aboveEditor, lifecycle: .retained,
                provenance: provenance, revision: 1, focused: false, inputMode: .none,
                frame: ExtensionFrame(width: 30, height: 1, lines: [.init(plainText: "private frame", runs: [])], plainText: "private frame"))
            #expect(ExtensionRetainedContentPolicy.content(widgets: nil, surfaces: [surface]).isEmpty == (kind == "subagent"))
        }
    }

    private func wake(kind: String = "subagentWake") throws -> TranscriptItem {
        try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data("""
        {"id":"wake","parentId":null,"timestamp":"2026-01-01T00:00:00Z","presentationId":"wake","kind":"message","role":"user",
         "content":[{"id":"text","ordinal":0,"type":"text","text":"Subagent updates above."}],
         "semantic":{"version":1,"direction":"hiddenInternal","contextEffect":"modelInput","delivery":"stored","visibility":"hidden",
         "kind":"\(kind)","origin":{"kind":"subagent","title":"Subagents","confidence":"receipt"},"sequence":1}}
        """.utf8))
    }

    @Test("internal wake and unknown future input decode without corrupting historical/live transcript")
    func wakeDecodeAndStore() async throws {
        let item = try wake()
        #expect(item.semantic?.kind.rawValue == "subagentWake")
        #expect(try wake(kind: "future-input").semantic?.kind.rawValue == "unknown")
        let ordinary = try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data(#"{"id":"ordinary","parentId":null,"timestamp":"2026-01-01T00:00:00Z","presentationId":"ordinary","kind":"message","role":"user","content":[{"id":"ordinary-text","ordinal":0,"type":"text","text":"Ordinary prompt"}]}"#.utf8))
        #expect(ordinary.semantic == nil)
        var snapshot = try SessionScenarioBuilder(seed: 611).openingTail(targetEncodedBytes: 4096)
        snapshot.transcript = [item, ordinary]
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 2
        let sessions = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        defer { sessions.clearProfile() }
        sessions.installHostedSubscription(snapshot: snapshot, token: "subagents")
        #expect(sessions.visibleTranscript.first?.semantic?.kind.rawValue == "subagentWake")
        let transcript = ChatTranscriptPresentationStore()
        defer { transcript.reset() }
        let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
        #expect(transcript.submit(snapshot: snapshot, tag: tag))
        let installed = try await transcript.waitForInstall(of: tag)
        let reconstructed = installed.displayedItems.compactMap { row -> TranscriptItem? in
            switch row {
            case .transcript(let value): value
            case .message(let value): value.item
            default: nil
            }
        }
        #expect(reconstructed.map(\.id) == [ordinary.id])
        #expect(sessions.authoritativeSnapshot(for: snapshot.sessionId)?.transcript.first?.semantic?.origin.kind == .subagent)
    }

    private func inputWire(queued: Bool, kind: String? = "subagentWake", hidden: Bool = true) throws -> Data {
        var value: [String: JSONValue] = [
            "id": .string("input"), "text": .string("Subagent updates above."),
            "attachmentCount": .number(0), "behavior": .string("steer")
        ]
        if let kind {
            value["semantic"] = .object([
                "version": .number(1), "direction": .string(hidden ? "hiddenInternal" : "inboundContext"),
                "contextEffect": .string("modelInput"), "delivery": .string("stored"),
                "visibility": .string(hidden ? "hidden" : "visible"), "kind": .string(kind),
                "origin": .object(["kind": .string("subagent"), "title": .string("Subagents"), "confidence": .string("receipt")]),
                "sequence": .number(1)
            ])
        }
        if !queued { value["createdAt"] = .string("2026-01-01T00:00:00Z") }
        return try JSONEncoder.gateway.encode(JSONValue.object(value))
    }

    @Test("pending and queued DTOs retain present, absent and unknown input semantics")
    func inputSemanticDecode() throws {
        for kind: String? in ["subagentWake", nil, "future-input"] {
            let pending = try JSONDecoder.gateway.decode(SessionSnapshot.PendingPrompt.self, from: inputWire(queued: false, kind: kind))
            let queued = try JSONDecoder.gateway.decode(SessionSnapshot.QueuedMessage.self, from: inputWire(queued: true, kind: kind))
            for encoded in [try JSONValue.encode(pending), try JSONValue.encode(queued)] {
                let semantic = encoded.objectValue?["semantic"]?.objectValue
                #expect(semantic?["kind"]?.stringValue == kind.map { $0 == "subagentWake" ? $0 : "unknown" })
                #expect(semantic?["direction"]?.stringValue == kind.map { _ in "hiddenInternal" })
            }
        }
    }

    @Test("pending handoff and displayed queue hide internal inputs without mutating authority")
    func inputPresentationTransitions() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 613).openingTail(targetEncodedBytes: 4096)
        snapshot.transcript = []
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 0
        snapshot.phase = .compacting
        let sessions = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let transcript = ChatTranscriptPresentationStore()
        defer { sessions.clearProfile(); transcript.reset() }
        // Start/preflight, steer, visible replacement, return to hidden, cold reinstall.
        for (index, variant) in [(true, "subagentWake"), (true, "future-input"), (false, "prompt"), (false, nil), (true, "subagentWake")].enumerated() {
            let (hidden, kind) = variant
            snapshot.revision += 1
            snapshot.eventSequence += 1
            snapshot.queueRevision += 1
            snapshot.pendingPrompt = try JSONDecoder.gateway.decode(SessionSnapshot.PendingPrompt.self, from: inputWire(queued: false, kind: kind, hidden: hidden))
            snapshot.queuedItems = [try JSONDecoder.gateway.decode(SessionSnapshot.QueuedMessage.self, from: inputWire(queued: true, kind: kind, hidden: hidden))]
            if index == 0 || index == 4 {
                sessions.clearProfile()
                sessions.installHostedSubscription(snapshot: snapshot, token: "input-\(index)")
            } else {
                sessions.admitSynchronously(GatewayEvent(type: "event", topic: "session.snapshot", sessionId: snapshot.sessionId, payload: try JSONValue.encode(snapshot)))
            }
            let authoritative = try #require(sessions.authoritativeSnapshot(for: snapshot.sessionId))
            #expect(authoritative.queuedItems.count == 1)
            #expect(authoritative.queueRevision == snapshot.queueRevision)
            #expect(authoritative.pendingPrompt != nil)
            #expect(authoritative.displayedQueuedMessages.count == (hidden ? 0 : 1))
            let handoff = ChatTranscriptHandoffCommit.pending(in: authoritative)
            #expect((handoff.pendingPromptPresentation == nil) == hidden)
            let tag = ChatTranscriptProjectionTag(snapshot: authoritative, presentationGeneration: index + 1, handoff: handoff)
            #expect(transcript.submit(snapshot: authoritative, handoff: handoff, tag: tag))
            let installed = try await transcript.waitForInstall(of: tag)
            #expect(installed.queuedMessages.count == (hidden ? 0 : 1))
            #expect((installed.handoff.pendingPromptPresentation == nil) == hidden)
        }
    }

    @Test("hidden queue inputs remain subject to authoritative bounds and identity admission")
    func hiddenQueueAdmission() throws {
        var snapshot = try SessionScenarioBuilder(seed: 614).openingTail(targetEncodedBytes: 4096)
        let hidden = try JSONDecoder.gateway.decode(SessionSnapshot.QueuedMessage.self, from: inputWire(queued: true))
        snapshot.queuedItems = [hidden]
        #expect(SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
        snapshot.queuedItems = [hidden, hidden]
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
        snapshot.queuedItems = (0...SessionSnapshot.maximumQueuedMessages).map { index in
            SessionSnapshot.QueuedMessage(id: "hidden-\(index)", behavior: hidden.behavior,
                text: hidden.text, attachmentCount: 0, semantic: hidden.semantic)
        }
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
        snapshot.queuedItems = [.init(id: "", behavior: hidden.behavior, text: hidden.text,
            attachmentCount: 0, semantic: hidden.semantic)]
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
        snapshot.queuedItems = [.init(id: "invalid", behavior: hidden.behavior, text: hidden.text,
            attachmentCount: -1, semantic: hidden.semantic)]
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
    }

    @Test("snapshot replacement and cold reinstall preserve typed producer ownership")
    func retainedStateStoreTransitions() throws {
        var snapshot = try SessionScenarioBuilder(seed: 612).openingTail(targetEncodedBytes: 4096)
        let managed = try owner("subagent")
        snapshot.extensionPresentation.semanticState.statuses = ["provider": "private status"]
        snapshot.extensionPresentation.semanticState.statusOwners = ["provider": managed]
        snapshot.extensionPresentation.semanticState.widgets = [.init(key: "provider", lines: ["private widget"], placement: .aboveEditor, owner: managed)]
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        defer { store.clearProfile() }
        store.installHostedSubscription(snapshot: snapshot, token: "initial")
        func retained() throws -> ExtensionRetainedContent {
            let current = try #require(store.authoritativeSnapshot(for: snapshot.sessionId))
            return ExtensionRetainedContentPolicy.content(widgets: current.extensionPresentation.semanticState.widgets,
                surfaces: current.extensionPresentation.surfaces, statuses: current.extensionPresentation.semanticState.statuses,
                statusOwners: current.extensionPresentation.semanticState.statusOwners)
        }
        #expect(try retained().isEmpty)
        var successor = snapshot
        successor.revision += 1
        successor.eventSequence += 1
        successor.extensionPresentation.semanticState.statusOwners = ["provider": try owner("future-provider")]
        successor.extensionPresentation.semanticState.widgets = []
        store.admitSynchronously(GatewayEvent(type: "event", topic: "session.snapshot", sessionId: snapshot.sessionId, payload: try JSONValue.encode(successor)))
        #expect(try retained().entries.map(\.id) == ["status:provider"])
        store.clearProfile()
        store.installHostedSubscription(snapshot: snapshot, token: "cold-reinstall")
        #expect(try retained().isEmpty)
    }

    @Test("progress, child notes and uncategorized admitted messages use subagent pills")
    func pillCategories() {
        let origin = ChatOrigin(kind: .subagent, title: "Subagents", confidence: .receipt)
        for (customType, details, expected) in [
            ("subagent_supervisor_request", JSONValue.object(["reason": .string("progress_update")]), "Progress Update"),
            ("subagent-incremental-child-notify", .object([:]), "Child Update"),
            ("subagent-compaction-resume", .object([:]), "Update"),
            ("future-message", .object([:]), "Update")
        ] {
            let presentation = InboundContextMessagePresentation(origin: origin, customType: customType, details: details)
            #expect(presentation.title == "Subagent")
            #expect(presentation.status == expected)
            #expect(presentation.tone == .subagent)
        }
    }
}
