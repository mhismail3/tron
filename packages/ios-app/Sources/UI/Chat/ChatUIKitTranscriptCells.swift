import Foundation
@preconcurrency import UIKit

/// UIKit's transcript renderer is deliberately a row-local view tree. The
/// installed physical row remains the authority; this view only consumes its
/// immutable payload and keeps media work leased to ChatMediaLoader.
@MainActor
final class ChatUIKitHistoryCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitHistoryCell"
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        button.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -24)
        ])
        button.addTarget(self, action: #selector(pressed), for: .primaryActionTriggered)
        button.titleLabel?.font = ChatUIKitFont.sans(12, .semibold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ state: ChatUIKitHistoryState, onLoad: @escaping () -> Void) {
        action = onLoad
        spinner.stopAnimating()
        spinner.isHidden = true
        button.setImage(nil, for: .normal)
        switch state {
        case .hidden: button.setTitle(nil, for: .normal); button.isHidden = true
        case .available:
            button.isHidden = false
            button.setTitle("Load earlier messages", for: .normal)
            button.isEnabled = true
        case .loading:
            button.isHidden = false
            button.setTitle("Loading earlier messages…", for: .normal)
            button.isEnabled = false
            spinner.isHidden = false
            spinner.startAnimating()
        case .failed(let message):
            button.isHidden = false
            button.setTitle(message.isEmpty ? "Retry earlier messages" : "Retry: \(message)", for: .normal)
            button.isEnabled = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        action = nil
        spinner.stopAnimating()
        spinner.isHidden = true
        button.setTitle(nil, for: .normal)
        button.isHidden = false
    }

    @objc private func pressed() { action?() }
}

@MainActor
final class ChatUIKitTranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitTranscriptCell"

    private let rowView = ChatUIKitTranscriptRowView()
    var onAttachmentTapped: ((Int) -> Void)?
    var onToolTapped: (() -> Void)?
    var onThinkingDetails: (() -> Void)?
    var onNotificationDetails: (() -> Void)?
    var mediaLoader: ChatMediaLoader?
    var mediaIdentity: ((String) -> ChatMediaIdentity?)?
    private var presentationActivity = ChatUIKitPresentationActivity.active(generation: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        rowView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: ChatUIKitTranscriptRow) {
        rowView.onAttachmentTapped = onAttachmentTapped
        rowView.onToolTapped = onToolTapped
        rowView.onThinkingDetails = onThinkingDetails
        rowView.onNotificationDetails = onNotificationDetails
        rowView.setPresentationActivity(presentationActivity)
        rowView.configure(row, mediaLoader: mediaLoader, mediaIdentity: mediaIdentity)
        accessibilityIdentifier = "chat-row-\(row.id)"
    }

    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActivity = activity
        rowView.setPresentationActivity(activity)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowView.reset()
        mediaLoader = nil
        mediaIdentity = nil
    }
}

@MainActor
private final class ChatUIKitTranscriptRowView: UIView {
    private let stack = UIStackView()
    private let markdownView = ChatUIKitMarkdownView()
    private var mediaChips: [ChatUIKitMediaChip] = []
    private var currentID = ""
    var onAttachmentTapped: ((Int) -> Void)?
    var onToolTapped: (() -> Void)?
    var onThinkingDetails: (() -> Void)?
    var onNotificationDetails: (() -> Void)?
    private var presentationActivity = ChatUIKitPresentationActivity.active(generation: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        mediaChips.forEach { $0.cancelLoad() }
        mediaChips.removeAll()
        stack.arrangedSubviews.compactMap { $0 as? ChatUIKitToolPill }.forEach {
            $0.setPresentationActivity(.inactive(generation: 0))
        }
        stack.arrangedSubviews.compactMap { $0 as? ChatUIKitNotificationPill }.forEach {
            $0.setPresentationActivity(.inactive(generation: 0))
        }
        markdownView.reset()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onAttachmentTapped = nil
        onToolTapped = nil
        onThinkingDetails = nil
        onNotificationDetails = nil
        currentID = ""
    }

    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActivity = activity
        markdownView.setPresentationActivity(activity)
        mediaChips.forEach { $0.setPresentationActivity(activity) }
        stack.arrangedSubviews.compactMap { $0 as? ChatUIKitToolPill }.forEach {
            $0.setPresentationActivity(activity)
        }
        stack.arrangedSubviews.compactMap { $0 as? ChatUIKitNotificationPill }.forEach {
            $0.setPresentationActivity(activity)
        }
    }

    func configure(
        _ row: ChatUIKitTranscriptRow,
        mediaLoader: ChatMediaLoader?,
        mediaIdentity: ((String) -> ChatMediaIdentity?)?
    ) {
        // The physical ID is stable for lifecycle updates. Keep the markdown
        // and media child instances when the same row receives a new payload.
        if currentID != row.id { reset(); currentID = row.id }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        mediaChips.forEach { $0.cancelLoad() }
        mediaChips.removeAll()

        stack.alignment = .fill
        switch row.content {
        case .some(.transcript(let item, _)):
            renderTranscript(item, row: row, mediaLoader: mediaLoader, mediaIdentity: mediaIdentity)
        case .some(.pending(let pending)):
            renderPrompt(
                title: pending.cardTitle,
                text: pending.text,
                detail: pending.cardDetail,
                behavior: pending.cardBehavior,
                resource: pending.resourceInvocation,
                attachments: row.attachmentFacts,
                mediaLoader: mediaLoader,
                mediaIdentity: mediaIdentity
            )
        case .some(.outgoing(let outgoing, _)):
            renderPrompt(
                title: outgoing.cardTitle,
                text: outgoing.text,
                detail: outgoing.cardDetail,
                behavior: outgoing.cardBehavior,
                resource: outgoing.resourceInvocation,
                attachments: row.attachmentFacts,
                mediaLoader: mediaLoader,
                mediaIdentity: mediaIdentity
            )
        case .some(.queued(let entry)):
            let behavior = ChatPromptBehavior(entry.message.behavior)
            renderPrompt(
                title: behavior.title,
                text: entry.message.text,
                detail: behavior == .steer ? "After the current turn" : "After current work",
                behavior: behavior,
                resource: entry.message.resourceInvocation,
                attachments: row.attachmentFacts,
                mediaLoader: mediaLoader,
                mediaIdentity: mediaIdentity
            )
        case .none:
            renderFallback(row)
        }
        setPresentationActivity(presentationActivity)
        updateAccessibility(row)
    }

    private func renderTranscript(
        _ item: ChatTranscriptRenderItem,
        row: ChatUIKitTranscriptRow,
        mediaLoader: ChatMediaLoader?,
        mediaIdentity: ((String) -> ChatMediaIdentity?)?
    ) {
        switch item {
        case .toolRun(let run):
            let pill = ChatUIKitToolPill(run: run)
            pill.onActivate = onToolTapped
            stack.addArrangedSubview(pill)
        case .notification(let notification):
            let pill = ChatUIKitNotificationPill(presentation: notification)
            pill.onActivate = notification.hasDetailSheet ? onNotificationDetails : nil
            stack.addArrangedSubview(pill)
        case .transcript(let value):
            if value.kind == .customMessage {
                let tone = InboundProducerPresentationPolicy.tone(for: value.semantic?.origin.kind)
                let duration = InboundContextCompactPresentationPolicy.durationMilliseconds(details: value.details)
                let detail = [
                    InboundContextCompactPresentationPolicy.status(details: value.details),
                    duration.map { ToolTiming.format(milliseconds: $0) }
                ].compactMap { $0 }.joined(separator: " · ")
                let pill = ChatUIKitNotificationPill(
                    presentation: ChatNotificationPresentation(
                        id: "inbound-context-\(value.id)",
                        semanticID: value.id,
                        icon: "arrow.down.message.fill",
                        title: InboundProducerPresentationPolicy.compactTitle(for: value.semantic?.origin),
                        detail: detail,
                        body: nil,
                        tone: tone,
                        material: .glass
                    )
                )
                // customMessage is always an actionable inbound-context row,
                // including when its wire role is not user.
                pill.onActivate = onNotificationDetails
                stack.addArrangedSubview(pill)
                return
            }
            if value.kind == .customEntry, value.semantic?.kind == .command {
                let resource = value.semantic?.resourceInvocation
                let name = resource?.name ?? "Extension command"
                let origin = value.semantic?.origin.title
                    ?? value.semantic?.origin.kind.rawValue.capitalized
                    ?? "Extension"
                let title = CommandLifecyclePresentationPolicy.title(origin: origin, command: name)
                let notification = ChatNotificationPresentation(
                    id: value.id,
                    semanticID: value.id,
                    icon: "command",
                    title: title,
                    detail: CommandLifecyclePresentationPolicy.status(value.semantic?.lifecycle?.rawValue ?? "accepted"),
                    body: resource?.arguments,
                    tone: CommandLifecyclePresentationPolicy.tone(value.semantic?.lifecycle?.rawValue ?? "accepted"),
                    material: .glass
                )
                let pill = ChatUIKitNotificationPill(presentation: notification)
                pill.onActivate = onNotificationDetails
                stack.addArrangedSubview(pill)
                return
            }
            if value.kind == .bash {
                let card = ChatUIKitToolDetailCard(
                    title: "bash",
                    status: value.cancelled == true ? "Cancelled" : "Exit \(value.exitCode.map(String.init) ?? "—")",
                    content: value.output ?? "",
                    isError: value.cancelled == true || value.exitCode.map { $0 != 0 } == true
                )
                card.onActivate = onToolTapped
                stack.addArrangedSubview(card)
                return
            }
            let message = ChatMessagePresentation(
                id: value.id,
                semanticID: value.id,
                item: value,
                parts: ChatTranscriptPresentation.messageParts(in: value),
                streaming: false,
                showsFooter: true
            )
            renderMessage(message, row: row, mediaLoader: mediaLoader, mediaIdentity: mediaIdentity)
        case .message(let message):
            renderMessage(message, row: row, mediaLoader: mediaLoader, mediaIdentity: mediaIdentity)
        }
    }

    private func renderMessage(
        _ message: ChatMessagePresentation,
        row: ChatUIKitTranscriptRow,
        mediaLoader: ChatMediaLoader?,
        mediaIdentity: ((String) -> ChatMediaIdentity?)?
    ) {
        let item = message.item
        let isTrailing = item.role == .user || item.semantic?.direction == .inboundContext
        stack.alignment = isTrailing ? .trailing : .fill
        if item.role == .toolResult {
            let output = item.text.isEmpty ? (item.details.map { String(describing: $0) } ?? "") : item.text
            let card = ChatUIKitToolDetailCard(
                title: item.toolLabel ?? item.toolName ?? "Tool result",
                status: item.isError == true ? "Failed" : "Completed",
                content: output,
                isError: item.isError == true
            )
            card.onActivate = onToolTapped
            stack.addArrangedSubview(card)
            return
        }
        let parts = message.parts
        let attachments = row.attachmentFacts
        if let resource = row.resourceInvocation {
            stack.addArrangedSubview(ChatUIKitResourceChip(resource: resource))
        }
        if !attachments.isEmpty {
            let strip = attachmentStrip(
                attachments,
                mediaLoader: mediaLoader,
                mediaIdentity: mediaIdentity,
                alignment: .center
            )
            stack.addArrangedSubview(strip)
        }
        let hasText = parts.contains { part in
            guard case .content(let content) = part else { return false }
            return content.type == .text && !(content.text ?? "").isEmpty && content.attachment == nil
        }
        if item.role == .user {
            if hasText {
                let text = parts.compactMap { part -> String? in
                    guard case .content(let content) = part, content.type == .text,
                          content.attachment == nil else { return nil }
                    return content.text
                }.joined()
                stack.addArrangedSubview(ChatUIKitUserPromptBubble(text: text))
            }
        } else {
            markdownView.onThinkingDetails = onThinkingDetails
            markdownView.onNotificationDetails = onNotificationDetails
            markdownView.render(row)
            if !row.markdownDocuments.isEmpty || !row.thinkingSegments.isEmpty || !row.text.isEmpty {
                stack.addArrangedSubview(markdownView)
            }
        }
        if message.showsFooter {
            if let error = item.errorMessage, !error.isEmpty {
                stack.addArrangedSubview(ChatUIKitTranscriptNotice(text: error))
            }
            if item.role == .assistant, hasText,
               let provider = item.provider, let model = item.modelId {
                stack.addArrangedSubview(ChatUIKitModelFooter(
                    text: ModelDisplayFormatting.reference(provider: provider, model: model)
                ))
            }
        }
    }

    private func renderPrompt(
        title: String,
        text: String,
        detail: String?,
        behavior: ChatPromptBehavior,
        resource: ComposerResourceInvocation?,
        attachments: [ChatUIKitTranscriptAttachment],
        mediaLoader: ChatMediaLoader?,
        mediaIdentity: ((String) -> ChatMediaIdentity?)?
    ) {
        let wrapper = UIStackView()
        wrapper.axis = .vertical
        wrapper.alignment = .trailing
        wrapper.spacing = 4
        if let resource, !resource.isExtensionCommand {
            wrapper.addArrangedSubview(ChatUIKitResourceChip(resource: resource))
        }
        let card = ChatUIKitPromptCard(title: title, text: text, detail: detail, behavior: behavior)
        if !attachments.isEmpty {
            card.setAttachments(attachments, mediaLoader: mediaLoader, mediaIdentity: mediaIdentity) { [weak self] index in
                self?.onAttachmentTapped?(index)
            }
            mediaChips.append(contentsOf: card.mediaChips)
        }
        wrapper.addArrangedSubview(card)
        wrapper.alignment = .trailing
        stack.addArrangedSubview(wrapper)
    }

    private func renderFallback(_ row: ChatUIKitTranscriptRow) {
        if let run = row.toolRun {
            let pill = ChatUIKitToolPill(run: run)
            pill.onActivate = onToolTapped
            stack.addArrangedSubview(pill)
        } else if let notification = row.notification {
            let pill = ChatUIKitNotificationPill(presentation: notification)
            pill.onActivate = notification.hasDetailSheet ? onNotificationDetails : nil
            stack.addArrangedSubview(pill)
        } else if !row.text.isEmpty {
            markdownView.render(row)
            stack.addArrangedSubview(markdownView)
        }
    }

    private func attachmentStrip(
        _ attachments: [ChatUIKitTranscriptAttachment],
        mediaLoader: ChatMediaLoader?,
        mediaIdentity: ((String) -> ChatMediaIdentity?)?,
        alignment: UIStackView.Alignment
    ) -> UIView {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        let content = UIStackView()
        content.axis = .horizontal
        content.spacing = 8
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -3),
            content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -6),
            scroll.heightAnchor.constraint(equalToConstant: 70),
        ])
        for (index, attachment) in attachments.enumerated() {
            let chip = ChatUIKitMediaChip(attachment: attachment)
            chip.onActivate = { [weak self] in self?.onAttachmentTapped?(index) }
            chip.load(using: mediaLoader, identity: attachment.blobID.flatMap { mediaIdentity?($0) })
            content.addArrangedSubview(chip)
            mediaChips.append(chip)
        }
        content.alignment = alignment
        scroll.accessibilityLabel = "Prompt attachments"
        scroll.isAccessibilityElement = false
        return scroll
    }

    private func updateAccessibility(_ row: ChatUIKitTranscriptRow) {
        isAccessibilityElement = false
        accessibilityIdentifier = "chat-row-\(row.id)"
        accessibilityElements = stack.arrangedSubviews
        if let notification = row.notification {
            accessibilityLabel = [notification.title, notification.detail, notification.body]
                .compactMap { $0 }.joined(separator: ", ")
        } else {
            accessibilityLabel = row.text
        }
    }
}

@MainActor
private final class ChatUIKitSurfaceView: UIView {
    private let tint = UIView()
    let content = UIView()

    init(accent: UIColor, cornerRadius: CGFloat, glass: Bool = true) {
        super.init(frame: .zero)
        backgroundColor = .clear
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.tronBorder.withAlphaComponent(0.9).cgColor
        clipsToBounds = true
        if glass {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            blur.isUserInteractionEnabled = false
            blur.translatesAutoresizingMaskIntoConstraints = false
            addSubview(blur)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
                blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        tint.backgroundColor = accent.withAlphaComponent(0.14)
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: leadingAnchor), tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ChatUIKitToolPill: UIControl {
    var onActivate: (() -> Void)?
    private let title = UILabel()
    private let detail = UILabel()
    private let elapsed = UILabel()
    private let icon = UIImageView()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var run: ChatToolRunPresentation?
    private var elapsedTimer: Timer?
    private var presentationActive = true

    init(run: ChatToolRunPresentation) {
        self.run = run
        super.init(frame: .zero)
        let tone = run.failureCount > 0 ? UIColor.tronError : run.isRunning ? UIColor.tronAmber : UIColor.tronEmerald
        let surface = ChatUIKitSurfaceView(accent: tone, cornerRadius: ChatToolChipShapePolicy.cornerRadius)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -6)
        ])
        icon.image = UIImage(systemName: run.failureCount > 0 ? "exclamationmark.triangle.fill" : run.displayCount == 1 ? ToolDetailPresentation.icon(for: run.tools[0].title) : "square.stack.3d.up")
        icon.tintColor = tone
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.text = run.title; title.font = ChatUIKitFont.sans(12, .bold); title.textColor = UIColor.tronTextPrimary; title.numberOfLines = 1
        detail.text = run.status; detail.font = ChatUIKitFont.mono(10, .semibold); detail.textColor = tone; detail.numberOfLines = 1
        elapsed.text = run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:)); elapsed.font = ChatUIKitFont.mono(10, .semibold); elapsed.textColor = tone
        activity.isHidden = !run.isRunning; activity.color = tone
        if run.isRunning, presentationActive { activity.startAnimating() }
        if run.isRunning {
            row.addArrangedSubview(activity)
        } else {
            row.addArrangedSubview(icon)
        }
        row.addArrangedSubview(title); row.addArrangedSubview(detail); row.addArrangedSubview(elapsed)
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        if run.isRunning, presentationActive {
            elapsedTimer = Timer(timeInterval: 0.1, target: self, selector: #selector(elapsedTick(_:)), userInfo: nil, repeats: true)
            if let elapsedTimer { RunLoop.main.add(elapsedTimer, forMode: .common) }
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = [run.title, run.status, run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = "Opens tool details"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActive = activity.isActive
        if presentationActive, run?.isRunning == true {
            self.activity.startAnimating()
            if elapsedTimer == nil {
                elapsedTimer = Timer(timeInterval: 0.1, target: self, selector: #selector(elapsedTick(_:)), userInfo: nil, repeats: true)
                if let elapsedTimer { RunLoop.main.add(elapsedTimer, forMode: .common) }
            }
        } else {
            self.activity.stopAnimating()
            elapsedTimer?.invalidate(); elapsedTimer = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPresentationActivity(.inactive(generation: 0)) }
    }
    @objc private func elapsedTick(_ timer: Timer) {
        guard let run else { return }
        elapsed.text = run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
    }

    @objc private func activate() { onActivate?() }
}

@MainActor
private final class ChatUIKitNotificationPill: UIControl {
    var onActivate: (() -> Void)?
    private var activityIndicator: UIActivityIndicatorView?
    private var presentationActive = true
    init(presentation: ChatNotificationPresentation) {
        super.init(frame: .zero)
        let accent = UIColor.tronNotificationColor(presentation.tone)
        let surface = ChatUIKitSurfaceView(accent: accent, cornerRadius: presentation.material == .glass ? 999 : 18, glass: presentation.material == .glass)
        surface.translatesAutoresizingMaskIntoConstraints = false; addSubview(surface)
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor), surface.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor), surface.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5; row.alignment = .center; row.translatesAutoresizingMaskIntoConstraints = false
        surface.content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -10), row.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -6)
        ])
        let image = UIImageView(image: UIImage(systemName: presentation.icon)); image.tintColor = accent; image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let title = UILabel(); title.text = presentation.title; title.font = ChatUIKitFont.sans(12, .bold); title.textColor = accent; title.numberOfLines = 1
        let detail = UILabel(); detail.text = presentation.detail; detail.font = ChatUIKitFont.mono(10, .semibold); detail.textColor = UIColor.tronTextSecondary; detail.numberOfLines = 1
        row.addArrangedSubview(image); row.addArrangedSubview(title); row.addArrangedSubview(detail)
        if presentation.showsProgress {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = accent
            activityIndicator = spinner
            if presentationActive { spinner.startAnimating() }
            row.addArrangedSubview(spinner)
        }
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        isAccessibilityElement = true; accessibilityTraits = presentation.hasDetailSheet ? .button : .staticText
        accessibilityLabel = [presentation.title, presentation.detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = presentation.hasDetailSheet ? "Opens details" : nil
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActive = activity.isActive
        if presentationActive { activityIndicator?.startAnimating() } else { activityIndicator?.stopAnimating() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPresentationActivity(.inactive(generation: 0)) }
    }
    @objc private func activate() { onActivate?() }
}

@MainActor
private final class ChatUIKitResourceChip: UIView {
    init(resource: ComposerResourceInvocation) {
        super.init(frame: .zero)
        let accent: UIColor = resource.source == .skill ? .tronCyan : resource.source == .prompt ? .tronPurple : .tronIndigo
        let surface = ChatUIKitSurfaceView(accent: accent, cornerRadius: ChatToolChipShapePolicy.cornerRadius)
        surface.translatesAutoresizingMaskIntoConstraints = false; addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5; row.translatesAutoresizingMaskIntoConstraints = false; surface.content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -10), row.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -6)
        ])
        let icon = UIImageView(image: UIImage(systemName: resource.source == .skill ? "sparkles" : "command")); icon.tintColor = accent; icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let title = UILabel(); title.text = ComposerResourceNameFormatter.friendly(resource.name); title.font = ChatUIKitFont.sans(12, .bold); title.textColor = accent
        let kind = UILabel(); kind.text = resource.source == .skill ? "Skill" : resource.source == .prompt ? "Prompt" : "Command"; kind.font = ChatUIKitFont.mono(10, .semibold); kind.textColor = UIColor.tronTextSecondary
        row.addArrangedSubview(icon); row.addArrangedSubview(title); row.addArrangedSubview(kind)
        isAccessibilityElement = true; accessibilityTraits = .staticText; accessibilityLabel = "\(kind.text ?? "Resource"), \(title.text ?? resource.name)"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ChatUIKitPromptCard: UIView {
    private let stack = UIStackView()
    private let accent: UIColor
    private(set) var mediaChips: [ChatUIKitMediaChip] = []
    init(title: String, text: String, detail: String?, behavior: ChatPromptBehavior) {
        accent = behavior == .steer ? .tronEmerald : behavior == .followUp ? .tronPurple : .tronTextSecondary
        super.init(frame: .zero)
        let surface = ChatUIKitSurfaceView(accent: accent, cornerRadius: ChatPromptContainerStyle.cornerRadius)
        surface.translatesAutoresizingMaskIntoConstraints = false; addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor), surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: UserPromptTextLayoutPolicy.maximumWidth)
        ])
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; surface.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -12)
        ])
        let header = UIStackView(); header.axis = .horizontal; header.spacing = 8
        let heading = UILabel(); heading.text = title; heading.font = ChatUIKitFont.sans(12, .bold); heading.textColor = UIColor.tronTextPrimary
        let status = UILabel(); status.text = detail; status.font = ChatUIKitFont.mono(10, .semibold); status.textColor = accent; status.textAlignment = .right; status.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(heading); header.addArrangedSubview(UIView()); header.addArrangedSubview(status); stack.addArrangedSubview(header)
        if !text.isEmpty { stack.addArrangedSubview(ChatUIKitUserPromptBubble(text: text, insets: .zero, background: .clear)) }
        isAccessibilityElement = true; accessibilityTraits = .staticText; accessibilityLabel = [title, detail, text.isEmpty ? nil : text].compactMap { $0 }.joined(separator: ": ")
    }
    func setAttachments(_ attachments: [ChatUIKitTranscriptAttachment], mediaLoader: ChatMediaLoader?, mediaIdentity: ((String) -> ChatMediaIdentity?)?, onTap: @escaping (Int) -> Void) {
        guard !attachments.isEmpty else { return }
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 8
        for (index, attachment) in attachments.enumerated() {
            let chip = ChatUIKitMediaChip(attachment: attachment); chip.onActivate = { onTap(index) }; chip.load(using: mediaLoader, identity: attachment.blobID.flatMap { mediaIdentity?($0) }); row.addArrangedSubview(chip); mediaChips.append(chip)
        }
        stack.addArrangedSubview(row)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ChatUIKitUserPromptBubble: UILabel {
    private let insets: UIEdgeInsets
    init(text: String, insets: UIEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12), background: UIColor? = nil) {
        self.insets = insets
        super.init(frame: .zero); self.text = text; numberOfLines = 0; lineBreakMode = .byWordWrapping; font = ChatUIKitFont.body(14); textColor = UIColor.tronEmerald; textAlignment = .left; adjustsFontForContentSizeCategory = true; preferredMaxLayoutWidth = UserPromptTextLayoutPolicy.maximumWidth; layer.cornerRadius = ChatPromptContainerStyle.cornerRadius; layer.masksToBounds = true; self.backgroundColor = background ?? UIColor.tronEmerald.withAlphaComponent(0.14); isAccessibilityElement = true; accessibilityLabel = text
    }
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetBounds = bounds.inset(by: insets)
        let text = super.textRect(forBounds: insetBounds, limitedToNumberOfLines: numberOfLines)
        return text.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ChatUIKitToolDetailCard: UIControl {
    var onActivate: (() -> Void)?
    init(title: String, status: String, content: String, isError: Bool) {
        super.init(frame: .zero)
        let accent = isError ? UIColor.tronError : UIColor.tronEmerald
        let surface = ChatUIKitSurfaceView(accent: accent, cornerRadius: 12, glass: false)
        surface.translatesAutoresizingMaskIntoConstraints = false; addSubview(surface)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor), surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false; surface.content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -10)])
        let header = UIStackView(); header.axis = .horizontal; header.spacing = 8
        let heading = UILabel(); heading.text = title; heading.font = ChatUIKitFont.sans(12, .bold); heading.textColor = UIColor.tronTextPrimary
        let state = UILabel(); state.text = status; state.font = ChatUIKitFont.mono(10, .semibold); state.textColor = accent; state.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(heading); header.addArrangedSubview(UIView()); header.addArrangedSubview(state); stack.addArrangedSubview(header)
        if !content.isEmpty { let output = UITextView(); output.text = content; output.font = ChatUIKitFont.mono(11); output.textColor = UIColor.tronTextSecondary; output.isEditable = false; output.isSelectable = true; output.isScrollEnabled = false; output.textContainerInset = .zero; output.textContainer.lineFragmentPadding = 0; stack.addArrangedSubview(output) }
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = [title, status, content.isEmpty ? nil : content].compactMap { $0 }.joined(separator: ", "); accessibilityHint = "Opens tool details"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { onActivate?() }
}

@MainActor
private final class ChatUIKitTranscriptNotice: UILabel {
    init(text: String) { super.init(frame: .zero); self.text = text; numberOfLines = 0; font = ChatUIKitFont.sans(10, .semibold); textColor = UIColor.tronError; backgroundColor = UIColor.tronError.withAlphaComponent(0.10); layer.cornerRadius = 10; layer.masksToBounds = true; directionalLayoutMargins = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10); isAccessibilityElement = true; accessibilityLabel = text }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ChatUIKitModelFooter: UILabel {
    init(text: String) { super.init(frame: .zero); self.text = text; font = ChatUIKitFont.mono(10); textColor = UIColor.tronTextSecondary; numberOfLines = 1; accessibilityLabel = text }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ChatUIKitMediaChip: UIControl {
    let attachment: ChatUIKitTranscriptAttachment
    var onActivate: (() -> Void)?
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var loader: ChatMediaLoader?
    private var identity: ChatMediaIdentity?
    private var loadGeneration: UInt64 = 0
    private var failed = false
    private var presentationActive = true
    private let normalAccessibilityLabel: String

    init(attachment: ChatUIKitTranscriptAttachment) {
        self.attachment = attachment
        normalAccessibilityLabel = attachment.mimeType.hasPrefix("image/")
            ? "Image attachment, \(attachment.name)"
            : "File attachment, \(attachment.name)"
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 64)])
        imageView.translatesAutoresizingMaskIntoConstraints = false; addSubview(imageView)
        NSLayoutConstraint.activate([imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor), imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        imageView.contentMode = .scaleAspectFill; imageView.clipsToBounds = true; layer.cornerRadius = 14; layer.masksToBounds = true; layer.borderWidth = 0.5; layer.borderColor = UIColor.tronBorder.cgColor
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = normalAccessibilityLabel; accessibilityHint = "Opens a preview"
        showPlaceholder()
        if let image = attachment.preparedThumbnail { imageView.image = image }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(using loader: ChatMediaLoader?, identity: ChatMediaIdentity?) {
        self.loader = loader
        self.identity = identity
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        // A prepared thumbnail is already the authoritative bounded image and
        // must not be replaced by an asynchronous fetch.
        guard presentationActive, attachment.preparedThumbnail == nil, let loader, let identity else { return }
        if let cached = loader.cachedThumbnail(for: identity) {
            imageView.image = cached
            failed = false
            return
        }
        showPlaceholder()
        accessibilityLabel = normalAccessibilityLabel
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await loader.thumbnail(for: identity)
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.imageView.image = image
                self.failed = false
                self.accessibilityLabel = self.normalAccessibilityLabel
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.failed = true
                self.showFailure()
            }
        }
    }
    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActive = activity.isActive
        if presentationActive {
            load(using: loader, identity: identity)
        } else {
            cancelLoad()
        }
    }

    func cancelLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPresentationActivity(.inactive(generation: 0)) }
    }
    private func showPlaceholder() { imageView.image = UIImage(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text"); imageView.tintColor = UIColor.tronBlue; imageView.backgroundColor = UIColor.tronBlue.withAlphaComponent(0.10) }
    private func showFailure() { imageView.image = UIImage(systemName: "arrow.clockwise"); imageView.tintColor = UIColor.tronBlue; accessibilityLabel = "\(accessibilityLabel ?? "Attachment") unavailable, retry" }
    @objc private func activate() {
        if failed {
            failed = false
            showPlaceholder()
            load(using: loader, identity: identity)
        } else {
            onActivate?()
        }
    }
}

@MainActor
private enum ChatUIKitFont {
    static func scaled(_ font: UIFont, textStyle: UIFont.TextStyle) -> UIFont { UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font) }
    static func sans(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { scaled(TronFontLoader.createUIFont(size: size, weight: TronFontLoader.weight(weight)), textStyle: .body) }
    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { scaled(TronFontLoader.createUIFont(size: size, weight: TronFontLoader.weight(weight), mono: true), textStyle: .body) }
    static func body(_ size: CGFloat) -> UIFont { sans(size) }
}

private extension UIColor {
    static var tronTextPrimary: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#F8FAFC") : UIColor(hex: "#111827") } }
    static var tronTextSecondary: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#AAB2BF") : UIColor(hex: "#4B5563") } }
    static var tronTextMuted: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#8B949E") : UIColor(hex: "#6B7280") } }
    static var tronEmerald: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#10B981") : UIColor(hex: "#059669") } }
    static var tronPurple: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#8B5CF6") : UIColor(hex: "#7C3AED") } }
    static var tronCyan: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#06B6D4") : UIColor(hex: "#0891B2") } }
    static var tronIndigo: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#818CF8") : UIColor(hex: "#6366F1") } }
    static var tronAmber: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#F59E0B") : UIColor(hex: "#D97706") } }
    static var tronError: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#EF4444") : UIColor(hex: "#DC2626") } }
    static var tronBlue: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#3B82F6") : UIColor(hex: "#2563EB") } }
    static var tronBorder: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#3B424D") : UIColor(hex: "#D8DEE6") } }
    static func tronNotificationColor(_ tone: ChatNotificationTone) -> UIColor {
        switch tone { case .error: return .tronError; case .warning: return .tronAmber; case .purple: return .tronPurple; case .information: return .tronBlue; case .command: return .tronIndigo; case .tool, .accent: return .tronEmerald; case .neutral: return .tronTextMuted }
    }
}
