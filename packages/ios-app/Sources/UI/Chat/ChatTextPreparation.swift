import Foundation

struct ChatTextPreparationIdentity: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case markdown
        case thinking

        var evictionRank: Int {
            switch self {
            case .markdown: 0
            case .thinking: 1
            }
        }
    }

    let kind: Kind
    let value: String
}

struct ChatTextPreparationSource: Hashable, Sendable {
    let identity: ChatTextPreparationIdentity
    let source: String
}

enum ChatTextPreparationKey {
    static func content(_ part: ContentPart) -> String { "content:\(part.ordinal)" }
    static func thinking(_ segment: ChatThinkingSegment) -> String { segment.id }
    static func global(item: TranscriptItem, local: String) -> String {
        "\(item.presentationId):\(local)"
    }
}

struct ChatTextPreparationSnapshot: Hashable, Sendable {
    struct MarkdownEntry: Hashable, Sendable {
        let source: String
        let document: MarkdownPresentation.Document
        let revision: UInt64

        init(source: String, document: MarkdownPresentation.Document, revision: UInt64 = 0) {
            self.source = source
            self.document = document
            self.revision = revision
        }
    }

    struct ThinkingEntry: Hashable, Sendable {
        let source: String
        let inline: MarkdownPresentation.Inline
        let revision: UInt64

        init(source: String, inline: MarkdownPresentation.Inline, revision: UInt64 = 0) {
            self.source = source
            self.inline = inline
            self.revision = revision
        }
    }

    static let empty = ChatTextPreparationSnapshot(markdown: [:], thinking: [:], revision: [])

    let markdown: [String: MarkdownEntry]
    let thinking: [String: ThinkingEntry]
    /// Globally unique cache-entry revisions make this sorted membership token
    /// exact while keeping render-row equality independent of prepared payloads.
    let revision: [UInt64]

    init(
        markdown: [String: MarkdownEntry],
        thinking: [String: ThinkingEntry],
        revision: [UInt64] = []
    ) {
        self.markdown = markdown
        self.thinking = thinking
        self.revision = revision
    }

    func markdownDocument(identity: String, source: String) -> MarkdownPresentation.Document? {
        guard let entry = markdown[identity], entry.source == source else { return nil }
        return entry.document
    }

    func thinkingInline(identity: String, source: String) -> MarkdownPresentation.Inline? {
        guard let entry = thinking[identity], entry.source == source else { return nil }
        return entry.inline
    }

    func slice(for item: ChatTranscriptRenderItem) -> ChatTextPreparationSnapshot {
        let sourceItem: TranscriptItem
        let parts: [ChatMessagePart]
        switch item {
        case .transcript(let transcript):
            sourceItem = transcript
            parts = ChatTranscriptPresentation.messageParts(in: transcript)
        case .message(let message):
            sourceItem = message.item
            parts = message.parts
        case .toolRun, .notification:
            return .empty
        }

        var markdownSlice: [String: MarkdownEntry] = [:]
        var thinkingSlice: [String: ThinkingEntry] = [:]
        for part in parts {
            switch part {
            case .content(let content):
                let local = ChatTextPreparationKey.content(content)
                let global = ChatTextPreparationKey.global(item: sourceItem, local: local)
                if let entry = markdown[global] { markdownSlice[local] = entry }
            case .thinking(let run):
                for segment in run.segments {
                    let local = ChatTextPreparationKey.thinking(segment)
                    let global = ChatTextPreparationKey.global(item: sourceItem, local: local)
                    if let entry = thinking[global] { thinkingSlice[local] = entry }
                }
            }
        }
        let sliceRevision = (
            markdownSlice.values.map(\.revision) + thinkingSlice.values.map(\.revision)
        ).sorted()
        return ChatTextPreparationSnapshot(
            markdown: markdownSlice,
            thinking: thinkingSlice,
            revision: sliceRevision
        )
    }
}

struct ChatTextPreparationMetrics: Equatable, Sendable {
    let accountedBytes: Int
    let markdownCount: Int
    let thinkingCount: Int
}

enum ChatTextPreparationPolicy {
    static let maximumAccountedBytes = 4 * 1_024 * 1_024
    static let maximumMarkdownRevisions = 512
    static let maximumThinkingSegments = 4_096
    static let maximumSourceBytes = 320_000
    static let maximumConcurrentPreparations = 2
    static let maximumNewMarkdownPreparationsPerProjection = 32
    static let maximumNewThinkingPreparationsPerProjection = 128

    static func sources(in snapshot: SessionSnapshot) -> [ChatTextPreparationSource] {
        var result: [ChatTextPreparationSource] = []
        var indexes: [ChatTextPreparationIdentity: Int] = [:]

        func admit(_ source: ChatTextPreparationSource) {
            guard !source.source.isEmpty else { return }
            if let index = indexes[source.identity] {
                result[index] = source
            } else {
                indexes[source.identity] = result.count
                result.append(source)
            }
        }

        func admit(_ item: TranscriptItem) {
            guard item.kind == .message, item.role != .user, item.role != .toolResult else { return }
            for part in ChatTranscriptPresentation.messageParts(in: item) {
                switch part {
                case .content(let content):
                    guard content.type == .text, content.attachment == nil,
                          let text = content.text, !text.isEmpty else { continue }
                    let local = ChatTextPreparationKey.content(content)
                    admit(ChatTextPreparationSource(
                        identity: .init(
                            kind: .markdown,
                            value: ChatTextPreparationKey.global(item: item, local: local)
                        ),
                        source: text
                    ))
                case .thinking(let run):
                    for segment in run.segments {
                        let local = ChatTextPreparationKey.thinking(segment)
                        admit(ChatTextPreparationSource(
                            identity: .init(
                                kind: .thinking,
                                value: ChatTextPreparationKey.global(item: item, local: local)
                            ),
                            source: segment.text
                        ))
                    }
                }
            }
        }

        // Explicitly paged history may exceed one page. Only the render-critical
        // bounded tail is warmed; older lazily realized rows retain the exact
        // cold parser fallback and are never mirrored by this cache.
        for item in snapshot.transcript.suffix(ChatTranscriptPageRequest.maximumItemCount) {
            admit(item)
        }
        if let streaming = snapshot.streaming { admit(streaming) }
        return result
    }
}

actor ChatTextPreparationCache {
    private enum Value: Hashable, Sendable {
        case markdown(MarkdownPresentation.Document)
        case thinking(MarkdownPresentation.Inline)
    }

    private struct Entry: Hashable, Sendable {
        let source: String
        let value: Value
        let accountedBytes: Int
        let contentRevision: UInt64
        var accessOrdinal: UInt64
    }

    private struct Prepared: Sendable {
        let source: ChatTextPreparationSource
        let value: Value
        let accountedBytes: Int
    }

    private let maximumNewMarkdownPreparations: Int
    private let maximumNewThinkingPreparations: Int
    private var entries: [ChatTextPreparationIdentity: Entry] = [:]
    private var accountedBytes = 0
    private var accessOrdinal: UInt64 = 0
    private var nextContentRevision: UInt64 = 0

    init(
        maximumNewMarkdownPreparations: Int = ChatTextPreparationPolicy.maximumNewMarkdownPreparationsPerProjection,
        maximumNewThinkingPreparations: Int = ChatTextPreparationPolicy.maximumNewThinkingPreparationsPerProjection
    ) {
        self.maximumNewMarkdownPreparations = min(
            max(0, maximumNewMarkdownPreparations),
            ChatTextPreparationPolicy.maximumMarkdownRevisions
        )
        self.maximumNewThinkingPreparations = min(
            max(0, maximumNewThinkingPreparations),
            ChatTextPreparationPolicy.maximumThinkingSegments
        )
    }

    func prepare(_ requested: [ChatTextPreparationSource]) async -> ChatTextPreparationSnapshot {
        let newest = newestSources(requested)
        var allMisses: [ChatTextPreparationSource] = []
        for source in newest {
            guard source.source.utf8.count <= ChatTextPreparationPolicy.maximumSourceBytes else {
                remove(source.identity)
                continue
            }
            if var entry = entries[source.identity], entry.source == source.source {
                // Requested sources are oldest-to-newest, so the tail receives
                // the strongest deterministic recency without depending on task order.
                accessOrdinal &+= 1
                entry.accessOrdinal = accessOrdinal
                entries[source.identity] = entry
            } else {
                remove(source.identity)
                allMisses.append(source)
            }
        }

        var selectedNewestFirst: [ChatTextPreparationSource] = []
        var admittedMarkdownMisses = 0
        var admittedThinkingMisses = 0
        for source in allMisses.reversed() {
            switch source.identity.kind {
            case .markdown where admittedMarkdownMisses < maximumNewMarkdownPreparations:
                admittedMarkdownMisses += 1
                selectedNewestFirst.append(source)
            case .thinking where admittedThinkingMisses < maximumNewThinkingPreparations:
                admittedThinkingMisses += 1
                selectedNewestFirst.append(source)
            default:
                break
            }
        }
        let misses = Array(selectedNewestFirst.reversed())

        var start = 0
        while start < misses.count {
            let end = min(
                misses.count,
                start + ChatTextPreparationPolicy.maximumConcurrentPreparations
            )
            let batch = Array(misses[start..<end])
            let prepared = await withTaskGroup(of: Prepared.self, returning: [Prepared].self) { group in
                for source in batch {
                    group.addTask { Self.prepare(source) }
                }
                var result: [Prepared] = []
                for await value in group { result.append(value) }
                return result
            }
            // Task completion order is intentionally irrelevant to LRU order.
            // The selected batch is admitted oldest-to-newest.
            for source in batch {
                if let value = prepared.first(where: { $0.source.identity == source.identity }) {
                    admit(value)
                }
            }
            start = end
        }

        return snapshot(for: newest)
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        accountedBytes = 0
    }

    func metrics() -> ChatTextPreparationMetrics {
        ChatTextPreparationMetrics(
            accountedBytes: accountedBytes,
            markdownCount: entries.keys.count { $0.kind == .markdown },
            thinkingCount: entries.keys.count { $0.kind == .thinking }
        )
    }

    private func newestSources(_ requested: [ChatTextPreparationSource]) -> [ChatTextPreparationSource] {
        var result: [ChatTextPreparationSource] = []
        var indexes: [ChatTextPreparationIdentity: Int] = [:]
        for source in requested {
            if let index = indexes[source.identity] {
                result[index] = source
            } else {
                indexes[source.identity] = result.count
                result.append(source)
            }
        }
        return result
    }

    private static func prepare(_ source: ChatTextPreparationSource) -> Prepared {
        switch source.identity.kind {
        case .markdown:
            let document = MarkdownPresentation.Document(source: source.source)
            return Prepared(
                source: source,
                value: .markdown(document),
                accountedBytes: document.accountedByteCount
            )
        case .thinking:
            let inline = MarkdownPresentation.Inline(source: source.source)
            return Prepared(
                source: source,
                value: .thinking(inline),
                accountedBytes: inline.accountedByteCount
            )
        }
    }

    private func admit(_ prepared: Prepared) {
        guard prepared.accountedBytes <= ChatTextPreparationPolicy.maximumAccountedBytes else { return }
        remove(prepared.source.identity)
        accessOrdinal &+= 1
        nextContentRevision &+= 1
        let entry = Entry(
            source: prepared.source.source,
            value: prepared.value,
            accountedBytes: prepared.accountedBytes,
            contentRevision: nextContentRevision,
            accessOrdinal: accessOrdinal
        )
        entries[prepared.source.identity] = entry
        accountedBytes += entry.accountedBytes
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while exceedsAnyLimit(), let oldest = entries.min(by: {
            if $0.value.accessOrdinal != $1.value.accessOrdinal {
                return $0.value.accessOrdinal < $1.value.accessOrdinal
            }
            if $0.key.kind != $1.key.kind {
                return $0.key.kind.evictionRank < $1.key.kind.evictionRank
            }
            return $0.key.value < $1.key.value
        })?.key {
            remove(oldest)
        }
    }

    private func exceedsAnyLimit() -> Bool {
        accountedBytes > ChatTextPreparationPolicy.maximumAccountedBytes
            || entries.keys.count(where: { $0.kind == .markdown })
                > ChatTextPreparationPolicy.maximumMarkdownRevisions
            || entries.keys.count(where: { $0.kind == .thinking })
                > ChatTextPreparationPolicy.maximumThinkingSegments
    }

    private func remove(_ identity: ChatTextPreparationIdentity) {
        guard let removed = entries.removeValue(forKey: identity) else { return }
        accountedBytes -= removed.accountedBytes
    }

    private func snapshot(
        for requested: [ChatTextPreparationSource]
    ) -> ChatTextPreparationSnapshot {
        var markdown: [String: ChatTextPreparationSnapshot.MarkdownEntry] = [:]
        var thinking: [String: ChatTextPreparationSnapshot.ThinkingEntry] = [:]
        for source in requested {
            guard let entry = entries[source.identity], entry.source == source.source else { continue }
            switch entry.value {
            case .markdown(let document):
                markdown[source.identity.value] = .init(
                    source: source.source,
                    document: document,
                    revision: entry.contentRevision
                )
            case .thinking(let inline):
                thinking[source.identity.value] = .init(
                    source: source.source,
                    inline: inline,
                    revision: entry.contentRevision
                )
            }
        }
        let snapshotRevision = (
            markdown.values.map(\.revision) + thinking.values.map(\.revision)
        ).sorted()
        return ChatTextPreparationSnapshot(
            markdown: markdown,
            thinking: thinking,
            revision: snapshotRevision
        )
    }
}
