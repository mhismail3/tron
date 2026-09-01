import Foundation
@preconcurrency import UIKit

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

final class ChatUIKitMarkdownView: UIView {
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

