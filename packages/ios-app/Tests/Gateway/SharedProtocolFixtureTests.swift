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
    }
}

private extension TranscriptItem.Kind {
    static let allFixtureKinds: [TranscriptItem.Kind] = [
        .message, .bash, .customMessage, .customEntry, .compaction,
        .branchSummary, .modelChange, .thinkingChange, .label,
    ]
}
