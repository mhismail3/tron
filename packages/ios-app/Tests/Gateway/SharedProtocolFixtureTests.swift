import Foundation
import Testing
@testable import TronMobile

private final class FixtureBundleMarker {}

@Suite("Shared TypeScript and Swift protocol fixtures")
struct SharedProtocolFixtureTests {
    @Test("protocol-v2 exhaustive session fixture decodes and round trips")
    func exhaustiveSessionFixture() throws {
        let bundle = Bundle(for: FixtureBundleMarker.self)
        let direct = bundle.url(forResource: "session-snapshot-v2", withExtension: "json")
        let nested = bundle.url(forResource: "session-snapshot-v2", withExtension: "json", subdirectory: "protocol-fixtures")
        let url = try #require(direct ?? nested)
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: data)

        #expect(snapshot.runtimeGeneration == "fixture-generation")
        #expect(Set(snapshot.transcript.map(\.kind)) == Set(TranscriptItem.Kind.allFixtureKinds))
        #expect(snapshot.transcript.first?.content?.map(\.id) == ["user-entry:0", "user-entry:1"])
        #expect(snapshot.transcript.first { $0.kind == .modelChange }?.modelRef == ModelRef(provider: "next-provider", id: "next-model"))
        #expect(snapshot.toolExecutions.first?.status == .running)
        #expect(snapshot.extensionUI.pendingInteractions.first?.method == .select)

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
