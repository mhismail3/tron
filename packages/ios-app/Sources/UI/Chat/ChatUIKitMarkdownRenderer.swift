import Foundation
@preconcurrency import UIKit

private final class ChatUIKitThinkingTraceView: UIView {
    private let textView = UITextView()
    private let fade = CAGradientLayer()
    private var maximumHeight: CGFloat {
        (textView.font?.lineHeight ?? ChatThinkingTraceLayoutPolicy.fallbackLineHeight)
            * CGFloat(ChatThinkingTraceLayoutPolicy.maximumLines)
    }
    let detailsButton = UIButton(type: .system)
    var onDetails: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.text = text
        let baseFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: .regular), compatibleWith: traitCollection)
        textView.font = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
        textView.textColor = ChatUIKitTheme.secondary
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = text
        clipsToBounds = true
        addSubview(textView)
        detailsButton.setTitle("Show full thinking trace", for: .normal)
        detailsButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11, weight: .medium), compatibleWith: traitCollection)
        detailsButton.accessibilityLabel = "Show full thinking trace"
        detailsButton.accessibilityHint = "Opens the complete thinking trace"
        detailsButton.addAction(UIAction { [weak self] _ in self?.onDetails?() }, for: .primaryActionTriggered)
        detailsButton.isHidden = true
        addSubview(detailsButton)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        fade.locations = [0, 0.35]
        // Text and the details control remain separate VoiceOver elements.
        isAccessibilityElement = false
        accessibilityElements = [textView, detailsButton]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let measured = measuredTextHeight()
        let overflow = ChatThinkingTraceLayoutPolicy.isOverflowing(contentHeight: measured, maximumHeight: maximumHeight)
        let viewport = overflow ? maximumHeight : measured
        // A short trace is ordinary inline content: it is neither faded nor
        // padded to the overflow viewport. Only an overflowing trace shows the
        // bounded tail and its details action.
        textView.frame = CGRect(
            x: 0,
            y: overflow ? -ChatThinkingTraceLayoutPolicy.tailOffset(contentHeight: measured, viewportHeight: viewport) : 0,
            width: bounds.width,
            height: measured
        )
        detailsButton.frame = CGRect(x: 0, y: viewport + 2, width: bounds.width, height: 24)
        detailsButton.isHidden = !overflow
        if overflow {
            fade.frame = CGRect(x: 0, y: max(0, measured - viewport), width: bounds.width, height: viewport)
            textView.layer.mask = fade
        } else {
            textView.layer.mask = nil
        }
    }

    private func measuredTextHeight() -> CGFloat {
        guard bounds.width > 0 else {
            // Auto Layout may ask for intrinsic size before assigning a width.
            // Do not turn that provisional measurement into a four-line
            // overflow reservation for an otherwise short trace.
            return textView.text?.isEmpty == false ? (textView.font?.lineHeight ?? ChatThinkingTraceLayoutPolicy.fallbackLineHeight) : 0
        }
        return max(0, textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        let baseFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: .regular), compatibleWith: traitCollection)
        textView.font = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
        detailsButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11, weight: .medium), compatibleWith: traitCollection)
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let measured = measuredTextHeight()
        let overflow = ChatThinkingTraceLayoutPolicy.isOverflowing(contentHeight: measured, maximumHeight: maximumHeight)
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: ceil(overflow ? maximumHeight : measured) + (overflow ? 26 : 0)
        )
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
    private var presentationActive = true

    func configure(inline: MarkdownPresentation.Inline, identity: String, streaming: Bool) {
        timer?.invalidate(); timer = nil
        self.identity = identity
        self.source = inline.source
        self.streaming = streaming
        isEditable = false; isSelectable = true; isScrollEnabled = false
        backgroundColor = .clear; textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 14, weight: .regular), compatibleWith: traitCollection)
        textColor = ChatUIKitTheme.primary
        baseAttributedText = NSAttributedString(inline.attributedString ?? AttributedString(inline.source))
        attributedText = baseAttributedText
        // Markdown may normalize the attributed string (for example by
        // dropping source delimiters). Token ranges must be measured against
        // the rendered TextKit string, never the source spelling.
        tokens = Self.tokens(in: baseAttributedText?.string ?? inline.source, identity: identity)
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

    func setPresentationActivity(_ active: Bool) {
        presentationActive = active
        if active { schedule() } else { timer?.invalidate(); timer = nil }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else {
            schedule()
        }
    }

    func reset() {
        timer?.invalidate(); timer = nil
        identity = ""; source = ""; baseAttributedText = nil; attributedText = nil
        tokens.removeAll(); revealedIDs.removeAll(); revealStarts.removeAll()
        admittedInitialContent = false; streaming = false; presentationActive = false
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard window != nil, presentationActive, streaming, !UIAccessibility.isReduceMotionEnabled else { return }
        let nextTimer = Timer(timeInterval: 0.033, target: self, selector: #selector(revealTick(_:)), userInfo: nil, repeats: true)
        timer = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    @objc private func revealTick(_ timer: Timer) {
        guard presentationActive else { return }
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
            let color = (output.attribute(.foregroundColor, at: token.range.location, effectiveRange: nil) as? UIColor) ?? textColor ?? ChatUIKitTheme.primary
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

private final class ChatUIKitCodeTextView: UITextView {
    var lineSpacing: CGFloat = 0 { didSet { applyParagraphStyle() } }

    override var intrinsicContentSize: CGSize {
        guard let font else { return super.intrinsicContentSize }
        let lines = max(1, (text as NSString).components(separatedBy: "\n").count)
        let maxLineWidth = (text as NSString).components(separatedBy: "\n").map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return CGSize(
            width: ceil(maxLineWidth) + textContainerInset.left + textContainerInset.right + 1,
            height: ceil(font.lineHeight * CGFloat(lines) + lineSpacing * CGFloat(max(0, lines - 1))) + textContainerInset.top + textContainerInset.bottom
        )
    }

    override var text: String! {
        didSet { applyParagraphStyle() }
    }

    private func applyParagraphStyle() {
        guard textStorage.length > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byClipping
        textStorage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: textStorage.length))
        invalidateIntrinsicContentSize()
    }
}

final class ChatUIKitMarkdownView: UIView {
    private let stack = UIStackView()
    private var inlineViews: [String: ChatUIKitStreamingInlineTextView] = [:]
    private var activeInlineIDs: Set<String> = []
    private var codeButtons: [UIButton] = []
    private var thinkingButton: UIButton?
    private var activityIndicators: [ChatUIKitPulseLoadingView] = []
    private var presentationActivity = ChatUIKitPresentationActivity.active(generation: 0)
    var onCodeCopied: ((String) -> Void)?
    var onThinkingDetails: (() -> Void)?
    var onNotificationDetails: (() -> Void)?

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

    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActivity = activity
        activityIndicators.forEach { indicator in
            if activity.isActive { indicator.startAnimating() } else { indicator.stopAnimating() }
        }
        inlineViews.values.forEach { $0.setPresentationActivity(activity.isActive) }
    }

    func reset() {
        inlineViews.values.forEach { $0.reset() }
        inlineViews.removeAll()
        activityIndicators.forEach { $0.stopAnimating() }
        activityIndicators.removeAll()
        codeButtons.removeAll()
        thinkingButton = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func render(_ row: ChatUIKitTranscriptRow) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        codeButtons.removeAll()
        thinkingButton = nil
        activeInlineIDs.removeAll()
        activityIndicators.forEach { $0.stopAnimating() }
        activityIndicators.removeAll()
        let documents = row.markdownDocuments
        if let toolRun = row.toolRun {
            stack.addArrangedSubview(toolRunView(toolRun))
            pruneInlineViews()
            return
        }
        if let notification = row.notification {
            stack.addArrangedSubview(notificationView(notification))
            pruneInlineViews()
            return
        }
        if documents.isEmpty, row.thinkingSegments.isEmpty, !row.text.isEmpty {
            let view = inlineView(MarkdownPresentation.Inline(source: row.text), identity: "row:\(row.id):fallback", streaming: row.streaming)
            let value = NSMutableAttributedString(attributedString: view.attributedText ?? NSAttributedString(string: row.text))
            for link in row.links where NSMaxRange(link.range) <= value.length {
                value.addAttribute(.link, value: link.url, range: link.range)
            }
            view.attributedText = value
            stack.addArrangedSubview(view)
        } else {
            for (documentIndex, document) in documents.enumerated() {
                render(document: document, identityPrefix: "row:\(row.id):document:\(documentIndex)", streaming: row.streaming)
            }
            if !row.thinkingSegments.isEmpty {
                renderThinking(row.thinkingSegments, label: row.thinkingLabel)
            }
        }
        setPresentationActivity(presentationActivity)
        if documents.isEmpty, row.thinkingSegments.isEmpty, row.text.isEmpty {
            let spacer = UIView()
            spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(spacer)
        }
        pruneInlineViews()
    }

    private func pruneInlineViews() {
        let stale = inlineViews.filter { !activeInlineIDs.contains($0.key) }
        stale.values.forEach { $0.reset() }
        inlineViews = inlineViews.filter { activeInlineIDs.contains($0.key) }
    }

    private func toolRunView(_ presentation: ChatToolRunPresentation) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = ChatUIKitTheme.toolBubble
        card.layer.cornerRadius = 10
        card.layer.borderWidth = 0.5
        card.layer.borderColor = ChatUIKitTheme.border.resolvedColor(with: traitCollection).cgColor
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel(); title.text = presentation.title; title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: .semibold), compatibleWith: traitCollection); title.textColor = ChatUIKitTheme.primary
        let status = UILabel(); status.text = [presentation.status, presentation.elapsedMilliseconds().map { ToolTiming.format(milliseconds: $0) }].compactMap { $0 }.joined(separator: " · "); status.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11), compatibleWith: traitCollection); status.textColor = presentation.failureCount > 0 ? ChatUIKitTheme.error : ChatUIKitTheme.secondary
        stack.addArrangedSubview(title); stack.addArrangedSubview(status)
        if presentation.isRunning {
            let indicator = ChatUIKitPulseLoadingView(accent: ChatUIKitTheme.emerald)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
            activityIndicators.append(indicator)
            stack.addArrangedSubview(indicator)
            if presentationActivity.isActive { indicator.startAnimating() }
        }
        for descriptor in presentation.reverseChronologicalTools {
            let line = UILabel(); line.text = "• \(descriptor.title): \(descriptor.subtitle)"; line.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11), compatibleWith: traitCollection); line.textColor = ChatUIKitTheme.secondary; line.numberOfLines = 0; stack.addArrangedSubview(line)
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)])
        card.isAccessibilityElement = false
        card.accessibilityElements = stack.arrangedSubviews
        return card
    }

    private func notificationView(_ presentation: ChatNotificationPresentation) -> UIView {
        let card = UIView(); card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = presentation.material == .glass ? ChatUIKitTheme.elevatedSurface : .clear
        card.layer.cornerRadius = presentation.material == .glass ? 10 : 0
        card.layer.borderWidth = presentation.material == .glass ? 0.5 : 0
        card.layer.borderColor = ChatUIKitTheme.border.resolvedColor(with: traitCollection).cgColor
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.alignment = .top; row.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: presentation.icon)); icon.tintColor = notificationColor(presentation.tone); icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(); text.axis = .vertical; text.spacing = 2
        let title = UILabel(); title.text = presentation.title; title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: .semibold), compatibleWith: traitCollection); title.textColor = ChatUIKitTheme.primary
        text.addArrangedSubview(title)
        if let detail = presentation.detail { let label = UILabel(); label.text = detail; label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11), compatibleWith: traitCollection); label.textColor = ChatUIKitTheme.secondary; text.addArrangedSubview(label) }
        if let body = presentation.body { let label = UILabel(); label.text = body; label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12), compatibleWith: traitCollection); label.numberOfLines = 0; label.textColor = ChatUIKitTheme.primary; text.addArrangedSubview(label) }
        if presentation.hasDetailSheet {
            let details = UIButton(type: .system)
            details.setTitle("Details", for: .normal)
            details.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11, weight: .medium), compatibleWith: traitCollection)
            details.addAction(UIAction { [weak self] _ in self?.onNotificationDetails?() }, for: .primaryActionTriggered)
            text.addArrangedSubview(details)
        }
        row.addArrangedSubview(icon); row.addArrangedSubview(text); card.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10), row.topAnchor.constraint(equalTo: card.topAnchor, constant: 8), row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8), icon.widthAnchor.constraint(equalToConstant: 18)])
        card.isAccessibilityElement = false
        card.accessibilityElements = row.arrangedSubviews
        return card
    }

    private func notificationColor(_ tone: ChatNotificationTone) -> UIColor {
        switch tone { case .error: return ChatUIKitTheme.error; case .warning: return ChatUIKitTheme.amber; case .tool: return ChatUIKitTheme.blue; case .accent, .command: return ChatUIKitTheme.emerald; case .purple: return ChatUIKitTheme.purple; case .information: return ChatUIKitTheme.info; case .neutral: return ChatUIKitTheme.muted }
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
                rule.backgroundColor = ChatUIKitTheme.border
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
        view.setPresentationActivity(presentationActivity.isActive)
        view.accessibilityLabel = inline.accessibilitySource
        return view
    }

    private func quoteView(_ inline: MarkdownPresentation.Inline, identity: String, streaming: Bool) -> UIView {
        let row = UIStackView(arrangedSubviews: [inlineView(inline, identity: identity, streaming: streaming)])
        row.axis = .horizontal
        row.spacing = 10
        let bar = UIView()
        bar.backgroundColor = ChatUIKitTheme.border
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
        container.backgroundColor = ChatUIKitTheme.elevatedSurface
        container.layer.cornerRadius = 9
        container.layer.borderWidth = 0.5
        container.layer.borderColor = ChatUIKitTheme.border.resolvedColor(with: traitCollection).cgColor
        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = language?.isEmpty == false ? language : "code"
        title.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: TronFontLoader.createUIFont(size: 10, weight: .medium, mono: false), compatibleWith: traitCollection)
        title.textColor = ChatUIKitTheme.muted
        header.addArrangedSubview(title)
        header.addArrangedSubview(UIView())
        if streaming {
            let indicator = ChatUIKitPulseLoadingView(accent: ChatUIKitTheme.emerald)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
            activityIndicators.append(indicator)
            if presentationActivity.isActive { indicator.startAnimating() }
            header.addArrangedSubview(indicator)
        }
        let copy = UIButton(type: .system)
        copy.setTitle("Copy", for: .normal)
        copy.titleLabel?.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: TronFontLoader.createUIFont(size: 10, weight: .medium, mono: false), compatibleWith: traitCollection)
        copy.accessibilityLabel = "Copy code"
        copy.addAction(UIAction { [weak copy, weak self] _ in
            UIPasteboard.general.string = code
            copy?.setTitle("Copied", for: .normal)
            self?.onCodeCopied?(code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copy] in copy?.setTitle("Copy", for: .normal) }
        }, for: .primaryActionTriggered)
        header.addArrangedSubview(copy)
        let divider = UIView()
        divider.backgroundColor = ChatUIKitTheme.border
        divider.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceHorizontal = true
        scroll.showsHorizontalScrollIndicator = false
        let text = ChatUIKitCodeTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isScrollEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 13, weight: .regular, mono: true), compatibleWith: traitCollection)
        text.textColor = ChatUIKitTheme.primary
        text.text = code
        text.lineSpacing = ChatUIKitTheme.codeLineSpacing
        text.textContainerInset = ChatUIKitTheme.codeTextInsets
        text.textContainer.lineFragmentPadding = 0
        scroll.addSubview(text)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12), header.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7), divider.leadingAnchor.constraint(equalTo: container.leadingAnchor), divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            text.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), text.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), text.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), text.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor), text.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
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
                label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: rowIndex == 0 ? .semibold : .regular), compatibleWith: traitCollection)
                label.textColor = ChatUIKitTheme.primary
                label.numberOfLines = 0
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
                row.addArrangedSubview(label)
            }
            table.addArrangedSubview(row)
            if rowIndex == 0 { let divider = UIView(); divider.backgroundColor = ChatUIKitTheme.border; divider.heightAnchor.constraint(equalToConstant: 1 / traitCollection.displayScale).isActive = true; table.addArrangedSubview(divider) }
        }
        table.isLayoutMarginsRelativeArrangement = true
        table.layoutMargins = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), table.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), table.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), table.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), table.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        scroll.backgroundColor = ChatUIKitTheme.elevatedSurface
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
            title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 11, weight: .semibold), compatibleWith: traitCollection)
            title.textColor = ChatUIKitTheme.secondary
            wrapper.addArrangedSubview(title)
        }
        let trace = ChatUIKitThinkingTraceView(text: segments.map(\.text).joined(separator: " "))
        trace.onDetails = onThinkingDetails
        wrapper.addArrangedSubview(trace)
        // The details button must remain a separate VoiceOver action.
        wrapper.isAccessibilityElement = false
        stack.addArrangedSubview(wrapper)
    }
}
