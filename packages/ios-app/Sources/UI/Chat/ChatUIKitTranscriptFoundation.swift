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

struct ChatUIKitSemanticAnchor: Equatable, Sendable {
    let rowID: String
    let topOffset: CGFloat
}

enum ChatUIKitViewportIntent: Equatable, Sendable {
    case followTail
    case preserve(ChatUIKitSemanticAnchor)
}

enum ChatUIKitInteractionPhase: Equatable, Sendable {
    case idle
    case tracking
    case decelerating
}

struct ChatUIKitViewportState: Equatable, Sendable {
    fileprivate(set) var intent: ChatUIKitViewportIntent = .followTail
    fileprivate(set) var interaction: ChatUIKitInteractionPhase = .idle
    fileprivate(set) var appliedVersion: UInt64?
    fileprivate(set) var transactionID: UInt64 = 0
}

enum ChatUIKitViewportTransactionOutcome: Equatable, Sendable {
    case applied(UInt64)
    case recovered(UInt64)
    case cancelled(UInt64)
}

private final class ChatUIKitThinkingTraceView: UIView {
    private let textView = UITextView()
    private let fade = CAGradientLayer()
    private let maximumHeight = ChatThinkingTraceLayoutPolicy.fallbackLineHeight * CGFloat(ChatThinkingTraceLayoutPolicy.maximumLines)
    let detailsButton = UIButton(type: .system)
    var onDetails: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.text = text
        textView.font = TronFontLoader.createUIFont(size: 11, weight: .regular)
        textView.textColor = .secondaryLabel
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = text
        clipsToBounds = true
        addSubview(textView)
        detailsButton.setTitle("Show full thinking trace", for: .normal)
        detailsButton.titleLabel?.font = TronFontLoader.createUIFont(size: 11, weight: .medium)
        detailsButton.addAction(UIAction { [weak self] _ in self?.onDetails?() }, for: .primaryActionTriggered)
        detailsButton.isHidden = true
        addSubview(detailsButton)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        fade.locations = [0, 0.35]
        isAccessibilityElement = true
        accessibilityLabel = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let measured = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let viewport = ChatThinkingTraceLayoutPolicy.viewportHeight(
            contentHeight: measured,
            maximumHeight: maximumHeight,
            fallbackLineHeight: ChatThinkingTraceLayoutPolicy.fallbackLineHeight
        )
        let overflow = ChatThinkingTraceLayoutPolicy.isOverflowing(contentHeight: measured, maximumHeight: maximumHeight)
        textView.frame = CGRect(x: 0, y: -ChatThinkingTraceLayoutPolicy.tailOffset(contentHeight: measured, viewportHeight: viewport), width: bounds.width, height: measured)
        detailsButton.frame = CGRect(x: 0, y: viewport + 2, width: bounds.width, height: 24)
        detailsButton.isHidden = !overflow
        fade.frame = CGRect(x: 0, y: max(0, measured - viewport), width: bounds.width, height: viewport)
        textView.layer.mask = fade
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: maximumHeight + 26)
    }
}

private final class ChatUIKitStreamingInlineTextView: UITextView {
    private struct Token { let id: String; let range: NSRange; let isWord: Bool }
    private var identity = ""
    private var source = ""
    private var baseAttributedText: NSAttributedString?
    private var tokens: [Token] = []
    private var revealedIDs: Set<String> = []
    private var revealStarts: [String: Date] = [:]
    private var timer: Timer?
    private var admittedInitialContent = false
    private var streaming = false

    func configure(inline: MarkdownPresentation.Inline, identity: String, streaming: Bool) {
        self.identity = identity
        self.source = inline.source
        self.streaming = streaming
        isEditable = false; isSelectable = true; isScrollEnabled = false
        backgroundColor = .clear; textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        font = TronFontLoader.createUIFont(size: 14, weight: .regular)
        textColor = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: "#F8FAFC") : UIColor(hex: "#111827") }
        baseAttributedText = NSAttributedString(inline.attributedString ?? AttributedString(inline.source))
        attributedText = baseAttributedText
        tokens = Self.tokens(in: inline.source, identity: identity)
        let current = Set(tokens.filter(\.isWord).map(\.id))
        guard streaming, !UIAccessibility.isReduceMotionEnabled else {
            revealedIDs.formUnion(current); revealStarts.removeAll(); admittedInitialContent = true; render(); return
        }
        revealedIDs.formIntersection(current)
        revealStarts = revealStarts.filter { current.contains($0.key) }
        let pending = tokens.filter { $0.isWord && !revealedIDs.contains($0.id) && revealStarts[$0.id] == nil }
        if !admittedInitialContent {
            admittedInitialContent = true
            revealedIDs.formUnion(current)
            revealStarts.removeAll()
        } else if ChatStreamingTextRevealPolicy.shouldCatchUp(pendingTokenCount: pending.count) {
            revealedIDs.formUnion(current); revealStarts.removeAll()
        }
        render()
        schedule()
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard streaming, !UIAccessibility.isReduceMotionEnabled else { return }
        let nextTimer = Timer(timeInterval: 0.033, target: self, selector: #selector(revealTick(_:)), userInfo: nil, repeats: true)
        timer = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    @objc private func revealTick(_ timer: Timer) {
        let now = Date.now
        if let next = tokens.first(where: { $0.isWord && !revealedIDs.contains($0.id) && revealStarts[$0.id] == nil }) {
            let last = revealStarts.values.max() ?? now.addingTimeInterval(-Double(ChatStreamingTextRevealPolicy.wordIntervalMilliseconds) / 1_000)
            if now.timeIntervalSince(last) * 1_000 >= Double(ChatStreamingTextRevealPolicy.wordIntervalMilliseconds) {
                revealStarts[next.id] = now
            }
        }
        for (id, start) in revealStarts where now.timeIntervalSince(start) * 1_000 >= Double(ChatStreamingTextRevealPolicy.fadeMilliseconds) {
            revealedIDs.insert(id); revealStarts.removeValue(forKey: id)
        }
        render()
        if tokens.filter(\.isWord).allSatisfy({ revealedIDs.contains($0.id) }) {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func render() {
        guard let value = baseAttributedText else { return }
        let output = NSMutableAttributedString(attributedString: value)
        let now = Date.now
        for token in tokens where token.isWord {
            let opacity: CGFloat
            if revealedIDs.contains(token.id) { opacity = 1 }
            else if let start = revealStarts[token.id] {
                opacity = CGFloat(ChatStreamingTextRevealPolicy.opacity(elapsedMilliseconds: max(0, Int(now.timeIntervalSince(start) * 1_000))))
            } else { opacity = 0 }
            let color = (output.attribute(.foregroundColor, at: token.range.location, effectiveRange: nil) as? UIColor) ?? textColor ?? .label
            output.addAttribute(.foregroundColor, value: color.withAlphaComponent(opacity), range: token.range)
        }
        super.attributedText = output
        accessibilityLabel = source
    }

    private static func tokens(in source: String, identity: String) -> [Token] {
        var result: [Token] = []
        let ns = source as NSString
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: [.byWords, .substringNotRequired]) { _, substringRange, _, _ in
            let range = NSRange(substringRange, in: source)
            result.append(Token(id: "\(identity):word:\(result.count)", range: range, isWord: true))
        }
        var covered = Set<Int>()
        for token in result { for index in token.range.location..<(token.range.location + token.range.length) { covered.insert(index) } }
        for index in 0..<ns.length where !covered.contains(index) {
            if index == 0 || covered.contains(index - 1) { result.append(Token(id: "\(identity):space:\(index)", range: NSRange(location: index, length: 1), isWord: false)) }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
}

private final class ChatUIKitMarkdownView: UIView {
    private let stack = UIStackView()
    private var inlineViews: [String: ChatUIKitStreamingInlineTextView] = [:]
    private var activeInlineIDs: Set<String> = []
    private var codeButtons: [UIButton] = []
    private var thinkingButton: UIButton?
    var onCodeCopied: ((String) -> Void)?
    var onThinkingDetails: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ row: ChatUIKitTranscriptRow) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        codeButtons.removeAll()
        thinkingButton = nil
        activeInlineIDs.removeAll()
        let documents = row.markdownDocuments
        if documents.isEmpty, row.thinkingSegments.isEmpty, !row.text.isEmpty {
            let view = inlineView(MarkdownPresentation.Inline(source: row.text), identity: "fallback", streaming: row.streaming)
            let value = NSMutableAttributedString(attributedString: view.attributedText ?? NSAttributedString(string: row.text))
            for link in row.links where NSMaxRange(link.range) <= value.length {
                value.addAttribute(.link, value: link.url, range: link.range)
            }
            view.attributedText = value
            stack.addArrangedSubview(view)
        } else {
            for (documentIndex, document) in documents.enumerated() {
                render(document: document, identityPrefix: "document:\(documentIndex)", streaming: row.streaming)
            }
            if !row.thinkingSegments.isEmpty {
                renderThinking(row.thinkingSegments, label: row.thinkingLabel)
            }
        }
        if documents.isEmpty, row.thinkingSegments.isEmpty, row.text.isEmpty {
            let spacer = UIView()
            spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(spacer)
        }
    }

    private func render(document: MarkdownPresentation.Document, identityPrefix: String, streaming: Bool) {
        for (index, block) in document.blocks.enumerated() {
            switch block.kind {
            case .paragraph(let inline): stack.addArrangedSubview(inlineView(inline, identity: "\(identityPrefix):block:\(index)", streaming: streaming))
            case .heading(let level, let inline):
                let view = inlineView(inline, identity: "\(identityPrefix):block:\(index)", streaming: streaming)
                view.font = TronFontLoader.createUIFont(
                    size: CGFloat(max(14, 22 - level * 2)),
                    weight: level <= 2 ? .bold : .semibold
                )
                view.textContainerInset.top = level <= 2 ? 6 : 2
                stack.addArrangedSubview(view)
            case .quote(let inline): stack.addArrangedSubview(quoteView(inline, identity: "\(identityPrefix):block:\(index)", streaming: streaming))
            case .list(let items): stack.addArrangedSubview(listView(items, identity: "\(identityPrefix):block:\(index)", streaming: streaming))
            case .code(let language, let code):
                stack.addArrangedSubview(codeView(language: language, code: code, streaming: streaming && block.isOpenCodeFence))
            case .table(let rows): stack.addArrangedSubview(tableView(rows))
            case .rule:
                let rule = UIView()
                rule.backgroundColor = UIColor(hex: "#D8DEE6")
                rule.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true
                stack.addArrangedSubview(rule)
            }
        }
    }

    private func inlineView(_ inline: MarkdownPresentation.Inline, identity: String, streaming: Bool) -> ChatUIKitStreamingInlineTextView {
        activeInlineIDs.insert(identity)
        let view = inlineViews[identity] ?? ChatUIKitStreamingInlineTextView()
        inlineViews[identity] = view
        view.configure(inline: inline, identity: identity, streaming: streaming)
        view.accessibilityLabel = inline.accessibilitySource
        return view
    }

    private func legacyInlineView(_ inline: MarkdownPresentation.Inline) -> UITextView {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = TronFontLoader.createUIFont(size: 14, weight: .regular)
        view.textColor = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: "#F8FAFC") : UIColor(hex: "#111827") }
        view.attributedText = NSAttributedString(inline.attributedString ?? AttributedString(inline.source))
        view.accessibilityLabel = inline.accessibilitySource
        view.accessibilityTraits = .staticText
        return view
    }

    private func quoteView(_ inline: MarkdownPresentation.Inline, identity: String, streaming: Bool) -> UIView {
        let row = UIStackView(arrangedSubviews: [inlineView(inline, identity: identity, streaming: streaming)])
        row.axis = .horizontal
        row.spacing = 10
        let bar = UIView()
        bar.backgroundColor = UIColor(hex: "#D8DEE6")
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        row.insertArrangedSubview(bar, at: 0)
        return row
    }

    private func listView(_ items: [MarkdownPresentation.ListItem], identity: String, streaming: Bool) -> UIView {
        let result = UIStackView()
        result.axis = .vertical
        result.spacing = 5
        for item in items {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            let marker = UILabel()
            marker.text = item.marker
            marker.font = TronFontLoader.createUIFont(size: 14, weight: .regular)
            marker.widthAnchor.constraint(greaterThanOrEqualToConstant: 10).isActive = true
            row.addArrangedSubview(marker)
            row.addArrangedSubview(inlineView(item.inline, identity: "\(identity):item:\(items.firstIndex(where: { $0.id == item.id }) ?? 0)", streaming: streaming))
            row.layoutMargins = UIEdgeInsets(top: 0, left: CGFloat(item.depth) * 14, bottom: 0, right: 0)
            row.isLayoutMarginsRelativeArrangement = true
            result.addArrangedSubview(row)
        }
        return result
    }

    private func codeView(language: String?, code: String, streaming: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: "#252A32") : UIColor(hex: "#EEF2F6") }
        container.layer.cornerRadius = 9
        container.layer.borderWidth = 0.5
        container.layer.borderColor = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: "#3B424D") : UIColor(hex: "#D8DEE6") }.cgColor
        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = language?.isEmpty == false ? language : "code"
        title.font = TronFontLoader.createUIFont(size: 10, weight: .medium, mono: false)
        title.textColor = UIColor(hex: "#6B7280")
        header.addArrangedSubview(title)
        header.addArrangedSubview(UIView())
        if streaming {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.color = UIColor(hex: "#059669")
            indicator.startAnimating()
            header.addArrangedSubview(indicator)
        }
        let copy = UIButton(type: .system)
        copy.setTitle("Copy", for: .normal)
        copy.titleLabel?.font = TronFontLoader.createUIFont(size: 10, weight: .medium, mono: false)
        copy.accessibilityLabel = "Copy code"
        copy.addAction(UIAction { [weak self] _ in
            UIPasteboard.general.string = code
            copy.setTitle("Copied", for: .normal)
            self?.onCodeCopied?(code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copy] in copy?.setTitle("Copy", for: .normal) }
        }, for: .primaryActionTriggered)
        header.addArrangedSubview(copy)
        let divider = UIView()
        divider.backgroundColor = UIColor.separator
        divider.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceHorizontal = true
        scroll.showsHorizontalScrollIndicator = false
        let text = UITextView()
        text.isEditable = false
        text.isSelectable = true
        text.isScrollEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = TronFontLoader.createUIFont(size: 13, weight: .regular, mono: true)
        text.textColor = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: "#F8FAFC") : UIColor(hex: "#111827") }
        text.text = code
        text.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        text.textContainer.lineFragmentPadding = 0
        scroll.addSubview(text)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12), header.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7), divider.leadingAnchor.constraint(equalTo: container.leadingAnchor), divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            text.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), text.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), text.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), text.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        container.addSubview(header); container.addSubview(divider); container.addSubview(scroll)
        return container
    }

    private func tableView(_ rows: [[String]]) -> UIView {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceHorizontal = true
        scroll.showsHorizontalScrollIndicator = true
        let table = UIStackView()
        table.axis = .vertical
        table.spacing = 7
        table.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(table)
        for (rowIndex, values) in rows.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 12
            for value in values {
                let label = UILabel()
                label.text = value
                label.font = TronFontLoader.createUIFont(size: 12, weight: rowIndex == 0 ? .semibold : .regular)
                label.numberOfLines = 0
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
                row.addArrangedSubview(label)
            }
            table.addArrangedSubview(row)
            if rowIndex == 0 { let divider = UIView(); divider.backgroundColor = .separator; divider.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true; table.addArrangedSubview(divider) }
        }
        table.isLayoutMarginsRelativeArrangement = true
        table.layoutMargins = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), table.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), table.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), table.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), table.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        scroll.backgroundColor = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: "#252A32") : UIColor(hex: "#EEF2F6") }
        scroll.layer.cornerRadius = 9
        return scroll
    }

    private func renderThinking(_ segments: [ChatThinkingSegment], label: String?) {
        let wrapper = UIStackView()
        wrapper.axis = .vertical
        wrapper.spacing = 0
        if let label, !label.isEmpty {
            let title = UILabel()
            title.text = label
            title.font = TronFontLoader.createUIFont(size: 11, weight: .semibold)
            title.textColor = .secondaryLabel
            wrapper.addArrangedSubview(title)
        }
        let trace = ChatUIKitThinkingTraceView(text: segments.map(\.text).joined(separator: " "))
        trace.onDetails = onThinkingDetails
        wrapper.addArrangedSubview(trace)
        wrapper.isAccessibilityElement = true
        wrapper.accessibilityLabel = [label, segments.map(\.text).joined(separator: " ")].compactMap { $0 }.joined(separator: ". ")
        stack.addArrangedSubview(wrapper)
    }
}

private final class ChatUIKitTranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitTranscriptCell"

    private let markdownView = ChatUIKitMarkdownView()
    private let attachmentStack = UIStackView()
    private let toolLabel = UILabel()
    var onAttachmentTapped: ((Int) -> Void)?
    var onToolTapped: (() -> Void)?
    var onThinkingDetails: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(markdownView)

        toolLabel.translatesAutoresizingMaskIntoConstraints = false
        toolLabel.numberOfLines = 0
        toolLabel.font = .preferredFont(forTextStyle: .caption1)
        toolLabel.textColor = .secondaryLabel
        toolLabel.isUserInteractionEnabled = true
        contentView.addSubview(toolLabel)

        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentStack.axis = .vertical
        attachmentStack.spacing = 4
        contentView.addSubview(attachmentStack)

        NSLayoutConstraint.activate([
            markdownView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            markdownView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            markdownView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            toolLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            toolLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            toolLabel.topAnchor.constraint(equalTo: markdownView.bottomAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            attachmentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            attachmentStack.topAnchor.constraint(equalTo: toolLabel.bottomAnchor, constant: 4),
            attachmentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toolTapped))
        toolLabel.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: ChatUIKitTranscriptRow) {
        markdownView.render(row)
        markdownView.onThinkingDetails = onThinkingDetails ?? onToolTapped
        markdownView.accessibilityIdentifier = "chat-row-\(row.id)"
        toolLabel.text = row.toolLabel
        toolLabel.isHidden = row.toolLabel == nil
        attachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, name) in row.attachments.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(name, for: .normal)
            button.contentHorizontalAlignment = .leading
            button.accessibilityLabel = "Attachment \(name)"
            button.tag = index
            button.addTarget(self, action: #selector(attachmentTapped(_:)), for: .touchUpInside)
            attachmentStack.addArrangedSubview(button)
        }
        attachmentStack.isHidden = row.attachments.isEmpty
    }

    @objc private func attachmentTapped(_ sender: UIButton) {
        onAttachmentTapped?(sender.tag)
    }

    @objc private func toolTapped() {
        onToolTapped?()
    }
}

/// The sole native viewport owner for the UIKit chat replacement. Its state is
/// intentionally finite: one intent, one interaction phase, and one active
/// transaction. Presentation updates are measured before and after layout;
/// no target materialization or second offset writer is used.
@MainActor
final class ChatUIKitChatViewController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UIScrollViewDelegate,
    UITextViewDelegate
{
    private(set) var input: ChatUIKitPresentationInput?
    private(set) var viewportState = ChatUIKitViewportState()
    var onSend: ((String) -> Void)?
    var onAttachmentTapped: ((String, Int) -> Void)?
    var onToolTapped: ((String) -> Void)?
    var onThinkingDetails: ((String) -> Void)?
    var onTransactionOutcome: ((ChatUIKitViewportTransactionOutcome) -> Void)?

    private var rows: [ChatUIKitTranscriptRow] { input?.rows ?? [] }
    private let collectionView: UICollectionView
    private let composer = UITextView()
    private let sendButton = UIButton(type: .system)
    private var composerHeight: NSLayoutConstraint?
    private let minimumComposerHeight: CGFloat = 40
    private let maximumComposerHeight: CGFloat = 140

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 1
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ChatUIKitTranscriptCell.self, forCellWithReuseIdentifier: ChatUIKitTranscriptCell.reuseIdentifier)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.isScrollEnabled = false
        composer.isEditable = true
        composer.delegate = self
        composer.accessibilityLabel = "Message"
        composer.accessibilityHint = "Enter a message to send to Tron"
        composer.layer.cornerRadius = 8
        composer.layer.borderWidth = 1
        composer.layer.borderColor = UIColor.separator.cgColor

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("Send", for: .normal)
        sendButton.accessibilityLabel = "Send message"
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(composer)
        bar.addSubview(sendButton)
        view.addSubview(collectionView)
        view.addSubview(bar)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: minimumComposerHeight)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            composer.topAnchor.constraint(equalTo: bar.topAnchor),
            composer.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            composerHeight!,
            sendButton.leadingAnchor.constraint(equalTo: composer.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 52),
        ])
    }

    /// Applies one complete presentation input. The outcome is emitted exactly
    /// once, including recovery/cancellation, and the detached intent survives
    /// all recovery paths.
    @discardableResult
    func apply(_ next: ChatUIKitPresentationInput) -> ChatUIKitViewportTransactionOutcome {
        guard input?.version != next.version else {
            let outcome: ChatUIKitViewportTransactionOutcome = .cancelled(viewportState.transactionID)
            onTransactionOutcome?(outcome)
            return outcome
        }
        viewportState.transactionID &+= 1
        let transactionID = viewportState.transactionID
        let anchor = captureAnchor()
        let nativePosition = collectionView.contentOffset
        let intent = viewportState.intent
        let isInteracting = viewportState.interaction == .tracking
            || viewportState.interaction == .decelerating
        let previousRows = input?.rows ?? []
        input = next

        UIView.performWithoutAnimation {
            if previousRows.map(\.id) == next.rows.map(\.id) {
                // Existing cells are updated in place. This preserves mounted
                // TextKit/link/code-copy state while the authority streams a
                // new row presentation and avoids reloading unrelated cells.
                for cell in collectionView.visibleCells {
                    guard let indexPath = collectionView.indexPath(for: cell),
                          indexPath.item < next.rows.count,
                          let transcriptCell = cell as? ChatUIKitTranscriptCell else { continue }
                    transcriptCell.configure(next.rows[indexPath.item])
                }
            } else {
                collectionView.reloadData()
            }
            collectionView.layoutIfNeeded()
        }
        viewportState.appliedVersion = next.version

        if isInteracting {
            // reloadData may invalidate estimated heights and move the native
            // offset. Restore only that measured pre-update position; this is
            // a safety correction, not a semantic navigation command. The
            // anchor is retained for the next idle settlement as evidence.
            preserveNativePosition(nativePosition)
            if let anchor { viewportState.intent = .preserve(anchor) }
        } else {
            switch intent {
            case .followTail:
                setOffset(y: maxOffsetY)
            case .preserve(let semantic):
                restore(semantic)
            }
        }
        let recovered = !isInteracting && !hasVisibleRows && !rows.isEmpty
        if recovered { recoverBlankViewport() }
        clampOffset()
        let outcome: ChatUIKitViewportTransactionOutcome = recovered
            ? .recovered(transactionID)
            : .applied(transactionID)
        onTransactionOutcome?(outcome)
        return outcome
    }

    func setIntent(_ intent: ChatUIKitViewportIntent) {
        guard viewportState.interaction == .idle else { return }
        viewportState.intent = intent
        switch intent {
        case .followTail: setOffset(y: maxOffsetY)
        case .preserve(let anchor): restore(anchor)
        }
        clampOffset()
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ChatUIKitTranscriptCell.reuseIdentifier,
            for: indexPath
        ) as! ChatUIKitTranscriptCell
        let row = rows[indexPath.item]
        cell.onAttachmentTapped = { [weak self] index in
            self?.onAttachmentTapped?(row.id, index)
        }
        cell.onToolTapped = { [weak self] in self?.onToolTapped?(row.id) }
        cell.onThinkingDetails = { [weak self] in self?.onThinkingDetails?(row.id) }
        cell.configure(row)
        return cell
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        viewportState.interaction = .tracking
        if let anchor = captureAnchor() { viewportState.intent = .preserve(anchor) }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate {
            viewportState.interaction = .decelerating
        } else {
            finishInteraction()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishInteraction() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard viewportState.interaction == .idle else { return }
        clampOffset()
    }

    func textViewDidChange(_ textView: UITextView) {
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        composer.isScrollEnabled = fitting.height > maximumComposerHeight
        composerHeight?.constant = min(max(fitting.height, minimumComposerHeight), maximumComposerHeight)
        view.layoutIfNeeded()
    }

    private func finishInteraction() {
        viewportState.interaction = .idle
        if let anchor = captureAnchor() {
            viewportState.intent = .preserve(anchor)
        }
        if hasReachedTail { viewportState.intent = .followTail }
        if !hasVisibleRows && !rows.isEmpty { recoverBlankViewport() }
    }

    private func captureAnchor() -> ChatUIKitSemanticAnchor? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let path = visible.first,
              path.item < rows.count,
              let attributes = collectionView.layoutAttributesForItem(at: path) else { return nil }
        return ChatUIKitSemanticAnchor(
            rowID: rows[path.item].id,
            topOffset: attributes.frame.minY - collectionView.contentOffset.y
        )
    }

    @discardableResult
    private func restore(_ anchor: ChatUIKitSemanticAnchor) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == anchor.rowID }) else {
            return false
        }
        let path = IndexPath(item: index, section: 0)
        guard let attributes = collectionView.layoutAttributesForItem(at: path) else {
            return false
        }
        setOffset(y: attributes.frame.minY - anchor.topOffset)
        return true
    }

    private var minOffsetY: CGFloat { -collectionView.adjustedContentInset.top }

    private var maxOffsetY: CGFloat {
        max(minOffsetY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    }

    private var hasVisibleRows: Bool {
        collectionView.indexPathsForVisibleItems.contains { $0.item < rows.count }
    }

    private var hasReachedTail: Bool {
        maxOffsetY - collectionView.contentOffset.y <= 24
    }

    private func recoverBlankViewport() {
        guard !rows.isEmpty else { return }
        // Recovery is deliberately bounded and never calls back into itself:
        // a missing layout attribute is a terminal recovery condition for this
        // transaction, not permission to recurse through anchor restoration.
        switch viewportState.intent {
        case .followTail:
            setOffset(y: maxOffsetY)
        case .preserve(let anchor):
            guard restore(anchor) else { setOffset(y: minOffsetY); return }
        }
        clampOffset()
    }

    private func clampOffset() {
        let y = min(max(collectionView.contentOffset.y, minOffsetY), maxOffsetY)
        guard y != collectionView.contentOffset.y else { return }
        setOffset(y: y)
    }

    private func preserveNativePosition(_ position: CGPoint) {
        let y = min(max(position.y, minOffsetY), maxOffsetY)
        guard collectionView.contentOffset.y != y else { return }
        setOffset(y: y)
    }

    /// The only method in this type that writes native offset.
    private func setOffset(y: CGFloat) {
        collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: min(max(y, minOffsetY), maxOffsetY))
    }

    @objc private func sendTapped() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.text = nil
        textViewDidChange(composer)
        onSend?(text)
    }
}
