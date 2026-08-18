import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded chat text preparation")
struct ChatTextPreparationTests {
    @Test("ratchets match the approved shared Phase 6 budget")
    func ratchets() {
        #expect(ChatTextPreparationPolicy.maximumAccountedBytes == 4_194_304)
        #expect(ChatTextPreparationPolicy.maximumMarkdownRevisions == 512)
        #expect(ChatTextPreparationPolicy.maximumThinkingSegments == 4_096)
        #expect(ChatTextPreparationPolicy.maximumSourceBytes == 320_000)
        #expect(ChatTextPreparationPolicy.maximumConcurrentPreparations == 2)
        #expect(ChatTextPreparationPolicy.maximumNewMarkdownPreparationsPerProjection == 32)
        #expect(ChatTextPreparationPolicy.maximumNewThinkingPreparationsPerProjection == 128)
    }

    @Test("newest source wins per identity and oversized replacement cannot expose stale text")
    func newestOnlyAndOversized() async throws {
        let cache = ChatTextPreparationCache()
        let identity = ChatTextPreparationIdentity(kind: .markdown, value: "message:0")
        let latest = await cache.prepare([
            .init(identity: identity, source: "old"),
            .init(identity: identity, source: "**new**"),
        ])
        #expect(latest.markdownDocument(identity: identity.value, source: "old") == nil)
        #expect(latest.markdownDocument(identity: identity.value, source: "**new**") != nil)
        #expect(await cache.metrics().markdownCount == 1)

        let oversized = String(repeating: "x", count: ChatTextPreparationPolicy.maximumSourceBytes + 1)
        let rejected = await cache.prepare([.init(identity: identity, source: oversized)])
        #expect(rejected.markdown.isEmpty)
        #expect(await cache.metrics().markdownCount == 0)
    }

    @Test("prepared Markdown and thinking values are exactly equal to the cold oracle")
    func coldEquivalence() async {
        let cache = ChatTextPreparationCache()
        let markdownSource = "# Heading\n\n**body**"
        let thinkingSource = "_considering_…"
        let snapshot = await cache.prepare([
            .init(identity: .init(kind: .markdown, value: "markdown"), source: markdownSource),
            .init(identity: .init(kind: .thinking, value: "thinking"), source: thinkingSource),
        ])

        #expect(snapshot.markdownDocument(
            identity: "markdown",
            source: markdownSource
        ) == MarkdownPresentation.Document(source: markdownSource))
        #expect(snapshot.thinkingInline(
            identity: "thinking",
            source: thinkingSource
        ) == MarkdownPresentation.Inline(source: thinkingSource))
    }

    @Test("Markdown revision count is bounded by deterministic LRU eviction")
    func markdownCountBound() async {
        let cache = ChatTextPreparationCache(
            maximumNewMarkdownPreparations: ChatTextPreparationPolicy.maximumMarkdownRevisions
        )
        let requested = (0...ChatTextPreparationPolicy.maximumMarkdownRevisions).map { index in
            ChatTextPreparationSource(
                identity: .init(kind: .markdown, value: "markdown-\(index)"),
                source: "value \(index)"
            )
        }
        let snapshot = await cache.prepare(requested)
        let metrics = await cache.metrics()

        #expect(metrics.markdownCount == ChatTextPreparationPolicy.maximumMarkdownRevisions)
        #expect(snapshot.markdown.count == ChatTextPreparationPolicy.maximumMarkdownRevisions)
        #expect(snapshot.markdown["markdown-0"] == nil)
        #expect(snapshot.markdown["markdown-512"] != nil)
        #expect(metrics.accountedBytes <= ChatTextPreparationPolicy.maximumAccountedBytes)
    }

    @Test("thinking count shares the cache but retains its independent segment ceiling")
    func thinkingCountBound() async {
        let cache = ChatTextPreparationCache(
            maximumNewThinkingPreparations: ChatTextPreparationPolicy.maximumThinkingSegments
        )
        let requested = (0...ChatTextPreparationPolicy.maximumThinkingSegments).map { index in
            ChatTextPreparationSource(
                identity: .init(kind: .thinking, value: "thinking-\(index)"),
                source: "segment \(index)"
            )
        }
        let snapshot = await cache.prepare(requested)
        let metrics = await cache.metrics()

        #expect(metrics.thinkingCount == ChatTextPreparationPolicy.maximumThinkingSegments)
        #expect(snapshot.thinking.count == ChatTextPreparationPolicy.maximumThinkingSegments)
        #expect(snapshot.thinking["thinking-0"] == nil)
        #expect(snapshot.thinking["thinking-4096"] != nil)
        #expect(metrics.accountedBytes <= ChatTextPreparationPolicy.maximumAccountedBytes)
    }

    @Test("source and presentation accounting enforce one shared byte budget")
    func sharedByteBudget() async {
        let cache = ChatTextPreparationCache()
        let source = String(repeating: "a", count: 300_000)
        let requested = (0..<5).map { index in
            ChatTextPreparationSource(
                identity: .init(kind: index.isMultiple(of: 2) ? .markdown : .thinking, value: "large-\(index)"),
                source: source + String(index)
            )
        }
        let snapshot = await cache.prepare(requested)
        let metrics = await cache.metrics()

        #expect(metrics.accountedBytes <= ChatTextPreparationPolicy.maximumAccountedBytes)
        #expect(snapshot.markdown.count + snapshot.thinking.count < requested.count)
        #expect(metrics.markdownCount + metrics.thinkingCount == snapshot.markdown.count + snapshot.thinking.count)
    }

    @Test("source extraction prepares assistant Markdown and normalized thinking only")
    func sourceExtraction() throws {
        var snapshot = try SessionScenarioBuilder(seed: 6_201)
            .openingTail(targetEncodedBytes: 4_096)
        snapshot.transcript = [
            try message(id: "user", role: "user", parts: [
                #"{"id":"user:0","type":"text","text":"do not cache"}"#,
            ]),
            try message(id: "assistant", role: "assistant", parts: [
                #"{"id":"assistant:0","type":"thinking","text":"first\n\nsecond"}"#,
                #"{"id":"assistant:1","type":"text","text":"**answer**"}"#,
            ]),
        ]
        snapshot.streaming = try message(id: "streaming", role: "assistant", parts: [
            #"{"id":"streaming:0","type":"text","text":"live"}"#,
        ])

        let sources = ChatTextPreparationPolicy.sources(in: snapshot)
        #expect(sources.map(\.identity.kind) == [.thinking, .thinking, .markdown, .markdown])
        #expect(sources.map(\.source) == ["first…", "second…", "**answer**", "live"])
        #expect(!sources.contains { $0.source == "do not cache" })
    }

    @Test("preparation scans only the bounded render-critical transcript tail")
    func renderCriticalTailBound() throws {
        var snapshot = try SessionScenarioBuilder(seed: 6_202)
            .openingTail(targetEncodedBytes: 4_096)
        snapshot.transcript = try (0..<600).map { index in
            try message(id: "assistant-\(index)", role: "assistant", parts: [
                #"{"id":"part-\#(index)","type":"text","text":"value \#(index)"}"#,
            ])
        }

        let sources = ChatTextPreparationPolicy.sources(in: snapshot)
        #expect(sources.count == ChatTranscriptPageRequest.maximumItemCount)
        #expect(sources.first?.identity.value == "part-88")
        #expect(sources.last?.identity.value == "part-599")
    }

    @Test("a row slice contains only that row's immutable prepared values")
    func rowSlice() throws {
        let first = try message(id: "first", role: "assistant", parts: [
            #"{"id":"first:0","type":"text","text":"one"}"#,
        ])
        let snapshot = ChatTextPreparationSnapshot(
            markdown: [
                "first:0": .init(source: "one", document: .init(source: "one")),
                "second:0": .init(source: "two", document: .init(source: "two")),
            ],
            thinking: [:]
        )

        let slice = snapshot.slice(for: .transcript(first))
        #expect(Set(slice.markdown.keys) == ["first:0"])
        #expect(slice.markdownDocument(identity: "first:0", source: "one") != nil)
        #expect(slice.markdownDocument(identity: "second:0", source: "two") == nil)
    }

    private func message(id: String, role: String, parts: [String]) throws -> TranscriptItem {
        let data = Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"\(role)","content":[\(parts.joined(separator: ","))]}
        """.utf8)
        return try JSONDecoder.gateway.decode(TranscriptItem.self, from: data)
    }
}
