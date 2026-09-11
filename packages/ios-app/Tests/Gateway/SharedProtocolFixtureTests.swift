import Foundation
import Testing
@testable import TronMobile

private final class FixtureBundleMarker {}

@Suite("Shared TypeScript and Swift protocol fixtures")
struct SharedProtocolFixtureTests {
    @Test("protocol-v4 exhaustive session fixture decodes and round trips")
    func exhaustiveSessionFixture() throws {
        let bundle = Bundle(for: FixtureBundleMarker.self)
        let direct = bundle.url(forResource: "session-snapshot-v4", withExtension: "json")
        let nested = bundle.url(forResource: "session-snapshot-v4", withExtension: "json", subdirectory: "protocol-fixtures")
        let url = try #require(direct ?? nested)
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: data)

        #expect(snapshot.runtimeGeneration == "fixture-generation")
        #expect(snapshot.acceptsQueuedPrompts == false)
        #expect(snapshot.activeToolSegmentId == nil)
        #expect(snapshot.transcriptStart == 0)
        #expect(snapshot.transcriptTotal == snapshot.transcript.count)
        #expect(snapshot.transcriptTotal == 11)
        #expect(Set(snapshot.transcript.map(\.kind)) == Set(TranscriptItem.Kind.allFixtureKinds))
        #expect(snapshot.transcript.first?.presentationId == "user-entry")
        #expect(snapshot.transcript.first?.content?.map(\.id) == ["user-entry:0", "user-entry:1", "user-entry:2"])
        #expect(snapshot.transcript.first?.content?.map(\.ordinal) == [0, 1, 2])
        let assistant = snapshot.transcript.first { $0.role == .assistant }
        #expect(assistant?.presentationId == "assistant-entry")
        #expect(assistant?.content?.first?.thinkingRunOrdinal == 0)
        let fixtureToolCall = assistant?.content?.first { $0.type == .toolCall }
        #expect(fixtureToolCall?.toolSegmentId == "tool-segment:fixture-turn")
        #expect(fixtureToolCall?.groupId == "tool-group:[\"assistant-entry\",2]")
        #expect(fixtureToolCall?.groupIndex == 0)
        #expect(fixtureToolCall?.groupCount == 1)
        #expect(fixtureToolCall?.groupFinalized == true)
        #expect(snapshot.transcript.first?.content?.last?.type == .text)
        #expect(snapshot.transcript.first?.content?.last?.attachment?.name == "fixture.pdf")
        #expect(snapshot.transcript.first?.content?.last?.attachment?.size == 55_972)
        #expect(snapshot.transcript.first { $0.kind == .modelChange }?.modelRef == ModelRef(provider: "next-provider", id: "next-model"))
        #expect(snapshot.toolExecutions.first?.status == .running)
        #expect(snapshot.toolExecutions.first?.order == 0)
        #expect(snapshot.toolExecutions.first?.output == "working\nstep two")
        #expect(snapshot.toolExecutions.first?.progressSequence == 2)
        #expect(snapshot.toolExecutions.first?.toolSegmentId == fixtureToolCall?.toolSegmentId)
        #expect(snapshot.toolExecutions.first?.groupId == fixtureToolCall?.groupId)
        #expect(snapshot.toolExecutions.first?.groupFinalized == true)
        #expect(snapshot.transcript.first(where: { $0.toolCallId == "tool-call" })?.durationMs == 1_000)
        let directBash = snapshot.transcript.first(where: { $0.kind == .bash })
        #expect(directBash?.startedAt == "2026-01-01T00:00:02.250Z")
        #expect(directBash?.completedAt == "2026-01-01T00:00:03Z")
        #expect(directBash?.durationMs == 750)
        #expect(snapshot.transcript.first(where: { $0.toolCallId == "tool-call" })?.extensionOrigin == ExtensionToolOrigin(source: "fixture-extension", owner: ExtensionOwner(id: "fixture-owner", title: "Fixture Extension", source: "fixture-extension")))
        #expect(snapshot.extensionPresentation.version == 3)
        #expect(snapshot.extensionPresentation.surfaces.first?.frame.plainText == "Readable fallback")
        #expect(snapshot.extensionPresentation.inputLease?.id == "fixture-lease")
        #expect(snapshot.extensionPresentation.hostEpoch == "fixture-host-epoch")
        #expect(snapshot.extensionPresentation.revision == 9)
        #expect(snapshot.extensionPresentation.semanticState.toolsExpanded == true)
        #expect(snapshot.extensionPresentation.pendingInteractions.first?.method == .form)
        #expect(snapshot.extensionPresentation.pendingInteractions.first?.form?.questions.first?.id == "fixture-question")
        #expect(snapshot.extensionPresentation.pendingInteractions.first?.hostEpoch == "fixture-host-epoch")
        #expect(snapshot.queueRevision == 3)
        #expect(snapshot.queuedItems == [
            SessionSnapshot.QueuedMessage(
                id: "queued-steer",
                behavior: .steer,
                text: "correct course",
                attachmentCount: 0
            ),
            SessionSnapshot.QueuedMessage(
                id: "queued-follow-up",
                behavior: .followUp,
                text: "then verify",
                attachmentCount: 0
            ),
        ])

        let encoded = try JSONEncoder.gateway.encode(snapshot)
        let roundTrip = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: encoded)
        #expect(roundTrip == snapshot)

        var activeWire = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        activeWire["phase"] = "running"
        activeWire["acceptsQueuedPrompts"] = true
        activeWire["activeToolSegmentId"] = "tool-segment:fixture-turn"
        activeWire["operation"] = [
            "id": "fixture-operation",
            "kind": "prompt",
            "startedAt": "2026-01-01T00:00:11Z",
        ]
        activeWire.removeValue(forKey: "retry")
        let activeData = try JSONSerialization.data(withJSONObject: activeWire)
        let activeSnapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: activeData)
        #expect(activeSnapshot.activeToolSegmentId == "tool-segment:fixture-turn")
        #expect(SessionSnapshotTranscriptAdmissionPolicy.admit(activeSnapshot))
    }
    @Test("provider-bound browser results survive session.open and retain the floating tap route")
    func browserSessionOpenFixture() throws {
        let wire = try browserResultWire()
        for toolName in ["agent_browser", "display"] {
            for isError in [false, true] {
                var result = wire
                result["toolName"] = toolName
                result["isError"] = isError
                let response = try decodeBrowserSessionOpen(result)
                let item = try #require(response.session.transcript.first)
                let display = try #require(item.display)
                #expect(item.toolName == toolName)
                #expect(display.liveView?.viewId == "fixture-browser-view")
                let candidate = ChatTranscriptProjectionKernel.cold(snapshot: response.session)
                let tools = candidate.timeline.items.flatMap { item -> [ChatToolDescriptor] in
                    if case .toolRun(let run) = item { return run.tools }
                    return []
                }
                let tool = try #require(tools.first)
                #expect(tool.id == "browser-call")
                #expect(ToolDisplayActivation.command(for: tool, sessionID: response.session.sessionId)
                    == .showFloating(DisplayRoute(sessionID: response.session.sessionId, display: display)))
                let roundTrip = try JSONDecoder.gateway.decode(SessionSnapshot.self,
                    from: JSONEncoder.gateway.encode(response.session))
                #expect(roundTrip == response.session)
            }
        }
    }

    @Test("native live session and history projections admit display only, not browser or capture tool grants")
    func nativeLiveSessionOpenAdmission() throws {
        var result = try browserResultWire()
        var wireDisplay = try #require(result["display"] as? [String: Any])
        var liveView = try #require(wireDisplay["liveView"] as? [String: Any])
        wireDisplay["kind"] = "native_live"
        liveView["schema"] = "tron.native-live-view.v1"
        wireDisplay["liveView"] = liveView
        result["display"] = wireDisplay
        result["toolName"] = "display"
        let response = try decodeBrowserSessionOpen(result)
        let display = try #require(response.session.transcript.first?.display)
        #expect(display.kind == .nativeLive)
        let cached = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: JSONEncoder.gateway.encode(response.session))
        #expect(cached == response.session)
        let projection = ChatTranscriptProjectionKernel.cold(snapshot: cached)
        let tools = projection.timeline.items.flatMap { item -> [ChatToolDescriptor] in
            if case .toolRun(let run) = item { return run.tools }
            return []
        }
        #expect(ToolDisplayActivation.command(for: try #require(tools.first), sessionID: cached.sessionId)
            == .showFloating(DisplayRoute(sessionID: cached.sessionId, display: display)))
        for tool in ["agent_browser", "native_capture", "read"] {
            result["toolName"] = tool
            #expect(throws: DecodingError.self) { try decodeBrowserSessionOpen(result) }
        }
        result["toolName"] = "display"
        for role in ["assistant", "user"] {
            result["role"] = role
            #expect(throws: DecodingError.self) { try decodeBrowserSessionOpen(result) }
        }
        result["role"] = "toolResult"
        result["display"] = nil
        result["details"] = ["display": wireDisplay]
        #expect(try decodeBrowserSessionOpen(result).session.transcript.first?.display == nil)
    }

    @Test("browser display admission still rejects unrelated tools, roles, kinds and malformed sources")
    func browserSessionOpenRejections() throws {
        let wire = try browserResultWire()
        for toolName in [nil, "read", "other-tool"] as [String?] {
            var result = wire
            result["toolName"] = toolName
            #expect(throws: DecodingError.self) { try decodeBrowserSessionOpen(result) }
        }
        for toolName in ["agent_browser", "display"] {
            for role in ["user", "assistant"] {
                var result = wire
                result["role"] = role
                result["toolName"] = toolName
                #expect(throws: DecodingError.self) { try decodeBrowserSessionOpen(result) }
            }
        }
        var result = wire
        // A valid public webpage is still not an agent_browser live-view grant.
        result["display"] = [
            "schema": "tron.display.v1", "displayId": "web", "revision": 1,
            "title": "Web", "altText": "Web", "kind": "webpage",
            "presentation": ["requestedSurface": "sheet", "inlineTapAction": "sheet"],
            "eligibleSurfaces": ["sheet"], "fallbackText": "Web", "remoteURL": "https://example.com/",
        ]
        #expect(throws: DecodingError.self) { try decodeBrowserSessionOpen(result) }
        result["toolName"] = "display"
        #expect(try decodeBrowserSessionOpen(result).session.transcript.first?.display?.kind == .webpage)

        result = wire
        var display = try #require(wire["display"] as? [String: Any])
        var liveView = try #require(display["liveView"] as? [String: Any])
        liveView["generation"] = ""
        display["liveView"] = liveView
        result["display"] = display
        #expect(throws: DecodingError.self) { try decodeBrowserSessionOpen(result) }

        // Diagnostics alone do not become a renderer on either entrypoint.
        for toolName in ["agent_browser", "display"] {
            result = wire
            result["toolName"] = toolName
            result["display"] = nil
            result["details"] = ["display": wire["display"]!]
            #expect(try decodeBrowserSessionOpen(result).session.transcript.first?.display == nil)
        }
    }

    private func browserResultWire() throws -> [String: Any] {
        let bundle = Bundle(for: FixtureBundleMarker.self)
        let url = try #require(bundle.url(forResource: "browser-tool-result-v4", withExtension: "json")
            ?? bundle.url(forResource: "browser-tool-result-v4", withExtension: "json", subdirectory: "protocol-fixtures"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func decodeBrowserSessionOpen(_ result: [String: Any]) throws -> GatewaySessionOpenResponse {
        let snapshot = try SessionScenarioBuilder(seed: 8_175).openingTail(targetEncodedBytes: 4_096)
        var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder.gateway.encode(snapshot)) as? [String: Any])
        wire["transcript"] = [result]
        wire["transcriptStart"] = 0
        wire["transcriptTotal"] = 1
        wire["leafEntryId"] = "browser-result"
        let envelope: [String: Any] = ["session": wire, "syncToken": "fixture-sync", "subscriptionToken": "fixture-subscription"]
        return try JSONDecoder.gateway.decode(GatewaySessionOpenResponse.self,
            from: JSONSerialization.data(withJSONObject: envelope))
    }
}

private extension TranscriptItem.Kind {
    static let allFixtureKinds: [TranscriptItem.Kind] = [
        .message, .bash, .customMessage, .customEntry, .compaction,
        .branchSummary, .modelChange, .thinkingChange, .label,
    ]
}
