import Foundation
@preconcurrency import UIKit

struct ChatUIKitLink: Hashable, Sendable {
    let range: NSRange
    let url: URL

    init?(range: NSRange, url: URL) {
        guard range.location >= 0, range.length > 0 else { return nil }
        self.range = range
        self.url = url
    }
}

/// Immutable UIKit input. Presentation owns ordering and identity; cells only
/// render these facts and never inspect SessionSnapshot or issue scroll writes.
struct ChatUIKitTranscriptRow: Hashable {
    enum Kind: String, Hashable, Sendable {
        case user, assistant, streaming, thinking, tool, attachment, status
    }

    let id: String
    let semanticID: String
    /// The complete installed physical-row payload. `text` is only a derived
    /// accessibility/fallback label and is never the presentation authority.
    let content: ChatPhysicalTranscriptRow.Content?
    let preparedText: ChatTextPreparationSnapshot?
    let markdownDocuments: [MarkdownPresentation.Document]
    let thinkingSegments: [ChatThinkingSegment]
    let thinkingLabel: String?
    let streaming: Bool
    let toolRun: ChatToolRunPresentation?
    let notification: ChatNotificationPresentation?
    let text: String
    let kind: Kind
    let links: [ChatUIKitLink]
    let attachments: [String]
    let toolLabel: String?

    init?(
        id: String,
        text: String,
        kind: Kind = .assistant,
        semanticID: String? = nil,
        content: ChatPhysicalTranscriptRow.Content? = nil,
        preparedText: ChatTextPreparationSnapshot? = nil,
        markdownDocuments: [MarkdownPresentation.Document] = [],
        thinkingSegments: [ChatThinkingSegment] = [],
        thinkingLabel: String? = nil,
        streaming: Bool = false,
        toolRun: ChatToolRunPresentation? = nil,
        notification: ChatNotificationPresentation? = nil,
        links: [ChatUIKitLink] = [],
        attachments: [String] = [],
        toolLabel: String? = nil
    ) {
        guard !id.isEmpty,
              Set(links.map { "\($0.range.location):\($0.range.length):\($0.url.absoluteString)" }).count == links.count
        else { return nil }
        self.id = id
        self.semanticID = semanticID ?? id
        self.content = content
        self.preparedText = preparedText
        self.markdownDocuments = markdownDocuments
        self.thinkingSegments = thinkingSegments
        self.thinkingLabel = thinkingLabel
        self.streaming = streaming
        self.toolRun = toolRun
        self.notification = notification
        self.text = text
        self.kind = kind
        self.links = links
        self.attachments = attachments
        self.toolLabel = toolLabel
    }
}

struct ChatUIKitPresentationInput: Equatable {
    let version: UInt64
    let rows: [ChatUIKitTranscriptRow]

    init?(version: UInt64, rows: [ChatUIKitTranscriptRow]) {
        guard Set(rows.map(\.id)).count == rows.count else { return nil }
        self.version = version
        self.rows = rows
    }
}

typealias ChatUIKitTranscriptCommit = ChatUIKitPresentationInput

/// Adapts an already-installed immutable presentation without copying or
/// reinterpreting SessionSnapshot. The UIKit surface receives every physical
/// row payload, including lifecycle and queue rows, while `text` remains only
/// a derived accessibility fallback.
enum ChatUIKitPresentationAdapter {
    static func input(
        from installed: InstalledChatTranscript,
        canonicalAliases: [String: String] = [:],
        version: UInt64
    ) -> ChatUIKitPresentationInput? {
        let physical = ChatPhysicalTranscriptRowPolicy.rows(
            installed: installed,
            canonicalAliases: canonicalAliases
        )
        let rows = physical.compactMap { row -> ChatUIKitTranscriptRow? in
            let item = transcriptItem(from: row.content)
            let prepared = item.map { installed.preparedText(for: $0) }
            return ChatUIKitTranscriptRow(
                id: row.id,
                text: accessibilityText(for: row.content),
                kind: kind(for: row.content),
                semanticID: row.semanticID,
                content: row.content,
                preparedText: prepared,
                markdownDocuments: markdownDocuments(for: row.content, prepared: prepared),
                thinkingSegments: thinkingSegments(for: row.content),
                thinkingLabel: prepared?.hiddenThinkingLabel,
                streaming: isStreaming(row.content),
                toolRun: toolRun(for: row.content),
                notification: notification(for: row.content),
                attachments: attachmentNames(for: row.content),
                toolLabel: toolLabel(for: row.content)
            )
        }
        return ChatUIKitPresentationInput(version: version, rows: rows)
    }

    private static func transcriptItem(
        from content: ChatPhysicalTranscriptRow.Content
    ) -> ChatTranscriptRenderItem? {
        guard case .transcript(let item, _) = content else { return nil }
        return item
    }

    private static func kind(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> ChatUIKitTranscriptRow.Kind {
        switch content {
        case .pending, .outgoing, .queued: return .status
        case .transcript(let item, _):
            switch item {
            case .toolRun: return .tool
            case .notification: return .status
            case .message(let message): return message.streaming ? .streaming : (message.item.role == .user ? .user : .assistant)
            case .transcript(let item):
                if item.kind == .thinkingChange { return .thinking }
                return item.role == .user ? .user : .assistant
            }
        }
    }

    private static func markdownDocuments(
        for content: ChatPhysicalTranscriptRow.Content,
        prepared: ChatTextPreparationSnapshot?
    ) -> [MarkdownPresentation.Document] {
        guard let prepared else { return [] }
        let values: [ChatMessagePart]
        switch content {
        case .transcript(let item, _):
            switch item {
            case .transcript(let value):
                guard value.role != .user else { return [] }
                values = ChatTranscriptPresentation.messageParts(in: value)
            case .message(let value):
                guard value.item.role != .user else { return [] }
                values = value.parts
            case .toolRun, .notification: return []
            }
        case .pending, .outgoing, .queued: return []
        }
        return values.compactMap { part in
            guard case .content(let value) = part, value.type == .text,
                  value.attachment == nil, let source = value.text else { return nil }
            return prepared.markdownDocument(
                identity: ChatTextPreparationKey.content(value),
                source: source
            ) ?? MarkdownPresentation.Document(source: source)
        }
    }

    private static func thinkingSegments(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> [ChatThinkingSegment] {
        let parts: [ChatMessagePart]
        switch content {
        case .transcript(let item, _):
            switch item {
            case .transcript(let value): parts = ChatTranscriptPresentation.messageParts(in: value)
            case .message(let value): parts = value.parts
            case .toolRun, .notification: return []
            }
        case .pending, .outgoing, .queued: return []
        }
        var result: [ChatThinkingSegment] = []
        for part in parts {
            if case .thinking(let run) = part { result.append(contentsOf: run.segments) }
        }
        return result
    }

    private static func isStreaming(
        _ content: ChatPhysicalTranscriptRow.Content
    ) -> Bool {
        guard case .transcript(let item, _) = content else { return false }
        if case .message(let value) = item { return value.streaming }
        return false
    }

    private static func toolRun(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> ChatToolRunPresentation? {
        guard case .transcript(let item, _) = content, case .toolRun(let value) = item else { return nil }
        return value
    }

    private static func notification(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> ChatNotificationPresentation? {
        guard case .transcript(let item, _) = content, case .notification(let value) = item else { return nil }
        return value
    }

    private static func attachmentNames(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> [String] {
        switch content {
        case .outgoing(_, let attachments): return attachments.map(\.name)
        case .transcript(let item, _):
            let parts: [ChatMessagePart]
            switch item {
            case .transcript(let value): parts = ChatTranscriptPresentation.messageParts(in: value)
            case .message(let value): parts = value.parts
            case .toolRun, .notification: return []
            }
            return parts.compactMap { part in
                guard case .content(let value) = part, let attachment = value.attachment else { return nil }
                return attachment.name
            }
        case .pending, .queued: return []
        }
    }

    private static func toolLabel(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> String? {
        guard case .transcript(let item, _) = content else { return nil }
        switch item {
        case .toolRun(let value): return [value.title, value.status].compactMap { $0 }.joined(separator: " · ")
        case .transcript(let value) where value.kind == .bash: return "bash"
        default: return nil
        }
    }

    private static func accessibilityText(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> String {
        switch content {
        case .pending(let value): return value.text
        case .outgoing(let value, _): return value.text
        case .queued(let value): return value.message.text
        case .transcript(let item, _):
            switch item {
            case .transcript(let value): return value.text
            case .message(let value): return value.parts.compactMap { part in
                if case .content(let content) = part { return content.text }
                if case .thinking(let thinking) = part { return thinking.segments.map(\.text).joined(separator: " ") }
                return nil
            }.joined(separator: "\n")
            case .toolRun(let value): return [value.title, value.status].compactMap { $0 }.joined(separator: ". ")
            case .notification(let value): return [value.title, value.detail, value.body].compactMap { $0 }.joined(separator: ". ")
            }
        }
    }
}
