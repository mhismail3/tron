import Foundation
@preconcurrency import UIKit

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
final class ChatUIKitTranscriptRowView: UIView {
    private let stack = UIStackView()
    private let markdownView = ChatUIKitMarkdownView()
    private var mediaChips: [ChatUIKitMediaChip] = []
    private var currentID = ""
    private var activeAttachmentIDs: Set<String> = []
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
        mediaIdentity: ((String) -> ChatMediaIdentity?)?,
    ) {
        // The physical ID is stable for lifecycle updates. Keep the markdown
        // and media child instances when the same row receives a new payload.
        if currentID != row.id { reset(); currentID = row.id }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Preserve media controls for retained rows so failed/retrying and
        // in-flight presentation state survives authoritative frame updates.
        activeAttachmentIDs.removeAll()
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
        mediaChips.filter { !activeAttachmentIDs.contains($0.attachment.id) }.forEach { $0.cancelLoad() }
        mediaChips = Dictionary(grouping: mediaChips.filter { activeAttachmentIDs.contains($0.attachment.id) }, by: { $0.attachment.id }).compactMap { $0.value.first }
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
            card.mediaChips.forEach { activeAttachmentIDs.insert($0.attachment.id) }
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
            activeAttachmentIDs.insert(attachment.id)
            let chip = mediaChips.first(where: { $0.attachment == attachment }) ?? ChatUIKitMediaChip(attachment: attachment)
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
