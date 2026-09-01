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
struct ChatUIKitTranscriptAttachment: Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int?
    let blobID: String?
    let preparedThumbnail: UIImage?

    init(
        id: String,
        name: String,
        mimeType: String,
        size: Int? = nil,
        blobID: String? = nil,
        preparedThumbnail: UIImage? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.blobID = blobID
        self.preparedThumbnail = preparedThumbnail
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.mimeType == rhs.mimeType
            && lhs.size == rhs.size && lhs.blobID == rhs.blobID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(mimeType)
        hasher.combine(size); hasher.combine(blobID)
    }
}

struct ChatUIKitTranscriptRow: Hashable {
    enum Kind: String, Hashable, Sendable {
        case user, assistant, streaming, thinking, tool, attachment, status
    }

    /// One canonical payload prevents a stale fallback label or one of several
    /// parallel fields from becoming an accidental rendering authority.
    struct PresentationFacts: Hashable {
        let text: String
        let kind: Kind
        let preparedText: ChatTextPreparationSnapshot?
        let markdownDocuments: [MarkdownPresentation.Document]
        let thinkingSegments: [ChatThinkingSegment]
        let thinkingLabel: String?
        let streaming: Bool
        let toolRun: ChatToolRunPresentation?
        let notification: ChatNotificationPresentation?
        let links: [ChatUIKitLink]
        let attachmentNames: [String]
        let attachmentFacts: [ChatUIKitTranscriptAttachment]
        let resourceInvocation: ComposerResourceInvocation?
        let toolLabel: String?
    }

    enum Payload: Hashable {
        /// Installed rows carry exactly one authority payload. Presentation
        /// facts are derived from it at read time, so callers cannot pair a
        /// physical row with stale text, attachment, or tool metadata.
        case installed(content: ChatPhysicalTranscriptRow.Content, preparedText: ChatTextPreparationSnapshot?)
        #if HOSTED_TEST
        /// Synthetic payloads exist only in the hosted test application and
        /// are never a fallback for an installed physical row.
        case synthetic(PresentationFacts)
        #endif
    }

    let id: String
    let semanticID: String
    let payload: Payload

    #if HOSTED_TEST
    var content: ChatPhysicalTranscriptRow.Content? {
        if case .installed(let content, _) = payload { return content }
        return nil
    }
    #else
    var content: ChatPhysicalTranscriptRow.Content {
        switch payload {
        case .installed(let content, _): return content
        }
    }
    #endif
    private var facts: PresentationFacts {
        switch payload {
        case .installed(let content, let preparedText):
            return ChatUIKitPresentationAdapter.facts(for: content, preparedText: preparedText)
        #if HOSTED_TEST
        case .synthetic(let facts): return facts
        #endif
        }
    }
    var preparedText: ChatTextPreparationSnapshot? { facts.preparedText }
    var markdownDocuments: [MarkdownPresentation.Document] { facts.markdownDocuments }
    var thinkingSegments: [ChatThinkingSegment] { facts.thinkingSegments }
    var thinkingLabel: String? { facts.thinkingLabel }
    var streaming: Bool { facts.streaming }
    var toolRun: ChatToolRunPresentation? { facts.toolRun }
    var notification: ChatNotificationPresentation? { facts.notification }
    var text: String { facts.text }
    var kind: Kind { facts.kind }
    var links: [ChatUIKitLink] { facts.links }
    var attachmentFacts: [ChatUIKitTranscriptAttachment] { facts.attachmentFacts }
    var attachments: [String] { facts.attachmentNames }
    var resourceInvocation: ComposerResourceInvocation? { facts.resourceInvocation }
    var toolLabel: String? { facts.toolLabel }

    #if HOSTED_TEST
    /// Synthetic rows are test fixtures only. Shipping code must construct a
    /// row from the canonical physical content factory below.
    init?(
        id: String,
        text: String,
        kind: Kind = .assistant,
        semanticID: String? = nil,
        preparedText: ChatTextPreparationSnapshot? = nil,
        markdownDocuments: [MarkdownPresentation.Document] = [],
        thinkingSegments: [ChatThinkingSegment] = [],
        thinkingLabel: String? = nil,
        streaming: Bool = false,
        toolRun: ChatToolRunPresentation? = nil,
        notification: ChatNotificationPresentation? = nil,
        links: [ChatUIKitLink] = [],
        attachments: [String] = [],
        attachmentFacts: [ChatUIKitTranscriptAttachment] = [],
        resourceInvocation: ComposerResourceInvocation? = nil,
        toolLabel: String? = nil
    ) {
        guard !id.isEmpty,
              Set(links.map { "\($0.range.location):\($0.range.length):\($0.url.absoluteString)" }).count == links.count
        else { return nil }
        self.id = id
        self.semanticID = semanticID ?? id
        let facts = PresentationFacts(
            text: text, kind: kind, preparedText: preparedText,
            markdownDocuments: markdownDocuments, thinkingSegments: thinkingSegments,
            thinkingLabel: thinkingLabel, streaming: streaming, toolRun: toolRun,
            notification: notification, links: links,
            attachmentNames: attachments.isEmpty ? attachmentFacts.map(\.name) : attachments,
            attachmentFacts: attachmentFacts,
            resourceInvocation: resourceInvocation, toolLabel: toolLabel
        )
        // This initializer is intentionally synthetic-only. Installed rows
        // must use the content factory below so facts cannot disagree with
        // their canonical payload.
        self.payload = .synthetic(facts)
    }
    #endif

    /// Factory for physical rows. Unlike the compatibility initializer above,
    /// this has no independent presentation fields to disagree with content.
    init?(
        id: String,
        semanticID: String? = nil,
        content: ChatPhysicalTranscriptRow.Content,
        preparedText: ChatTextPreparationSnapshot? = nil
    ) {
        guard !id.isEmpty else { return nil }
        self.id = id
        self.semanticID = semanticID ?? id
        self.payload = .installed(content: content, preparedText: preparedText)
    }
}

enum ChatUIKitHistoryState: Equatable, Sendable {
    case hidden
    case available
    case loading
    case failed(String)

    var isAffordanceVisible: Bool {
        self != .hidden
    }
}

struct ChatUIKitPresentationInput: Equatable {
    /// Presentation generations own the version domain. A replacement may
    /// restart versions, while delayed payloads from an older generation are
    /// never admitted.
    let generation: UInt64
    let version: UInt64
    let rows: [ChatUIKitTranscriptRow]
    /// A projection of the installed source window. Loading and failure are
    /// supplied by the existing paging owner; UIKit only exposes the action.
    let history: ChatUIKitHistoryState

    init?(
        generation: UInt64 = 0,
        version: UInt64,
        rows: [ChatUIKitTranscriptRow],
        history: ChatUIKitHistoryState = .hidden
    ) {
        guard Set(rows.map(\.id)).count == rows.count else { return nil }
        self.generation = generation
        self.version = version
        self.rows = rows
        self.history = history
    }
}

typealias ChatUIKitTranscriptCommit = ChatUIKitPresentationInput

/// Adapts an already-installed immutable presentation without copying or
/// reinterpreting SessionSnapshot. The UIKit surface receives every physical
/// row payload, including lifecycle and queue rows, while `text` remains only
/// a derived accessibility fallback.
enum ChatUIKitPresentationAdapter {
    /// Derives every renderer fact from the one canonical physical payload.
    /// This is intentionally shared by installed rows and never accepts a
    /// caller-supplied text/attachment/tool override.
    static func facts(
        for content: ChatPhysicalTranscriptRow.Content,
        preparedText: ChatTextPreparationSnapshot? = nil
    ) -> ChatUIKitTranscriptRow.PresentationFacts {
        let prepared = preparedText
        let documents = markdownDocuments(for: content, prepared: prepared)
        let attachments = attachmentFacts(for: content)
        return .init(
            text: accessibilityText(for: content),
            kind: kind(for: content),
            preparedText: prepared,
            markdownDocuments: documents,
            thinkingSegments: thinkingSegments(for: content),
            thinkingLabel: prepared?.hiddenThinkingLabel,
            streaming: isStreaming(content),
            toolRun: toolRun(for: content),
            notification: notification(for: content),
            links: links(in: documents),
            attachmentNames: attachments.map(\.name),
            attachmentFacts: attachments,
            resourceInvocation: resourceInvocation(for: content),
            toolLabel: toolLabel(for: content)
        )
    }

    static func input(
        from installed: InstalledChatTranscript,
        canonicalAliases: [String: String] = [:],
        generation: UInt64 = 0,
        version: UInt64,
        historyState: ChatUIKitHistoryState? = nil
    ) -> ChatUIKitPresentationInput? {
        let physical = ChatPhysicalTranscriptRowPolicy.rows(
            installed: installed,
            canonicalAliases: canonicalAliases
        )
        let rows = physical.compactMap { row -> ChatUIKitTranscriptRow? in
            let prepared = transcriptItem(from: row.content).map { installed.preparedText(for: $0) }
            return ChatUIKitTranscriptRow(
                id: row.id,
                semanticID: row.semanticID,
                content: row.content,
                preparedText: prepared
            )
        }
        let history = historyState ?? ((installed.sourceWindow.originalStart ?? 0) > 0
            ? .available
            : .hidden)
        return ChatUIKitPresentationInput(generation: generation, version: version, rows: rows, history: history)
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
                if item.kind == .customMessage || item.kind == .customEntry { return .status }
                return item.role == .user ? .user : .assistant
            }
        }
    }

    private static func markdownDocuments(
        for content: ChatPhysicalTranscriptRow.Content,
        prepared: ChatTextPreparationSnapshot?
    ) -> [MarkdownPresentation.Document] {
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
            return prepared?.markdownDocument(
                identity: ChatTextPreparationKey.content(value),
                source: source
            ) ?? MarkdownPresentation.Document(source: source)
        }
    }

    /// Carries the links discovered by MarkdownPresentation across the UIKit
    /// boundary. Ranges are measured in the same rendered, delimiter-free text
    /// that the native TextKit views display, never synthesized from the URL.
    private static func links(in documents: [MarkdownPresentation.Document]) -> [ChatUIKitLink] {
        var result: [ChatUIKitLink] = []
        var offset = 0
        for document in documents {
            for block in document.blocks {
                let inlines: [MarkdownPresentation.Inline] = switch block.kind {
                case .paragraph(let inline), .heading(_, let inline), .quote(let inline): [inline]
                case .list(let items): items.map(\.inline)
                case .code, .table, .rule: []
                }
                for inline in inlines {
                    if let attributed = inline.attributedString {
                        for run in attributed.runs {
                            guard let url = run.link,
                                  let link = ChatUIKitLink(
                                      range: NSRange(run.range, in: attributed),
                                      url: url
                                  ) else { continue }
                            result.append(ChatUIKitLink(
                                range: NSRange(
                                    location: link.range.location + offset,
                                    length: link.range.length
                                ),
                                url: link.url
                            )!)
                        }
                    }
                    offset += ((inline.attributedString.map { (String($0.characters) as NSString).length })
                        ?? (inline.source as NSString).length) + 1
                }
            }
            offset += 1
        }
        return result
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
        guard case .transcript(let item, _) = content else { return nil }
        switch item {
        case .toolRun(let value): return value
        case .transcript(let value) where value.kind == .bash:
            let tool = ChatToolPresentation(
                id: value.id,
                title: "bash",
                toolName: "bash",
                subtitle: value.cancelled == true
                    ? "Cancelled"
                    : "Exit \(value.exitCode.map(String.init) ?? "—")",
                request: .object(["command": .string(value.command ?? "")]),
                response: nil,
                content: value.output ?? "",
                fallbackContent: nil,
                error: value.cancelled == true || value.exitCode.map { $0 != 0 } == true,
                startedAt: value.startedAt,
                completedAt: value.completedAt,
                durationMs: value.durationMs,
                lastProgressAt: value.completedAt,
                progressSequence: nil,
                outputTruncated: value.truncated == true
            )
            return ChatToolRunPresentation(tools: [tool])
        default: return nil
        }
    }

    private static func notification(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> ChatNotificationPresentation? {
        guard case .transcript(let item, _) = content else { return nil }
        switch item {
        case .notification(let value): return value
        case .transcript(let value):
            return ChatNotificationPresentation.canonical(value, globalOrdinal: nil)
        default: return nil
        }
    }

    private static func attachmentFacts(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> [ChatUIKitTranscriptAttachment] {
        switch content {
        case .outgoing(_, let attachments):
            return attachments.map { attachment in
                ChatUIKitTranscriptAttachment(
                    id: attachment.id,
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    size: attachment.size,
                    blobID: attachment.transportBlobID,
                    preparedThumbnail: attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) }
                )
            }
        case .transcript(let item, _):
            let parts: [ChatMessagePart]
            switch item {
            case .transcript(let value): parts = ChatTranscriptPresentation.messageParts(in: value)
            case .message(let value): parts = value.parts
            case .toolRun, .notification: return []
            }
            return parts.compactMap { part in
                guard case .content(let value) = part,
                      value.type == .image || value.attachment != nil else { return nil }
                let attachment = value.attachment
                return ChatUIKitTranscriptAttachment(
                    id: value.id,
                    name: attachment?.name ?? "Image",
                    mimeType: attachment?.mimeType ?? value.mimeType ?? "image/*",
                    size: attachment?.size,
                    blobID: value.blobId
                )
            }
        case .pending(let value):
            return value.attachments?.map { attachment in
                ChatUIKitTranscriptAttachment(
                    id: attachment.id, name: attachment.name,
                    mimeType: attachment.mimeType, size: attachment.size
                )
            } ?? []
        case .queued(let entry):
            return entry.message.attachments?.map { attachment in
                ChatUIKitTranscriptAttachment(
                    id: attachment.id, name: attachment.name,
                    mimeType: attachment.mimeType, size: attachment.size
                )
            } ?? []
        }
    }

    private static func resourceInvocation(
        for content: ChatPhysicalTranscriptRow.Content
    ) -> ComposerResourceInvocation? {
        switch content {
        case .pending(let value): return value.resourceInvocation
        case .outgoing(let value, _): return value.resourceInvocation
        case .queued(let entry): return entry.message.resourceInvocation
        case .transcript(let item, _):
            switch item {
            case .transcript(let value): return value.semantic?.resourceInvocation
            case .message(let value): return value.item.semantic?.resourceInvocation
            case .toolRun, .notification: return nil
            }
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

/// Row actions cross the UIKit boundary as semantic intents. The native
/// renderer does not own route state or media data.
enum ChatUIKitTranscriptDetailIntent {
    case attachment(rowID: String, index: Int)
    case tool(rowID: String)
    case thinking(rowID: String)
    case notification(rowID: String)
}

struct ChatUIKitAttachmentDetailRoute: Identifiable {
    let id: UUID
    let attachment: ChatUIKitTranscriptAttachment
}

struct ChatUIKitThinkingDetailRoute: Identifiable {
    let id: String
    let label: String?
    let segments: [ChatThinkingSegment]
}

struct ChatUIKitDetailRoute: Identifiable {
    enum Kind {
        case attachment(ChatUIKitAttachmentDetailRoute)
        case toolRun(ChatToolRunPresentation, [ChatToolPresentation])
        case thinking(ChatUIKitThinkingDetailRoute)
        case notification(ChatNotificationPresentation)
    }
    let id: String
    let kind: Kind
}
