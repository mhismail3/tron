import Foundation
@preconcurrency import UIKit

@MainActor
final class ChatUIKitSurfaceView: UIView {
    private let tint = UIView()
    let content = UIView()

    init(accent: UIColor, cornerRadius: CGFloat, glass: Bool = true) {
        super.init(frame: .zero)
        backgroundColor = .clear
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 0.5
        layer.borderColor = ChatUIKitTheme.border.resolvedColor(with: traitCollection).withAlphaComponent(0.9).cgColor
        clipsToBounds = true
        if glass {
            let blur = UIVisualEffectView(effect: ChatUIKitTheme.material())
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = ChatUIKitTheme.border.resolvedColor(with: traitCollection).withAlphaComponent(0.9).cgColor
    }
}

@MainActor
final class ChatUIKitToolPill: UIControl {
    var onActivate: (() -> Void)?
    private let title = UILabel()
    private let detail = UILabel()
    private let elapsed = UILabel()
    private let icon = UIImageView()
    private let activity = ChatUIKitPulseLoadingView(accent: ChatUIKitTheme.amber)
    private var run: ChatToolRunPresentation?
    private var elapsedTimer: Timer?
    private var presentationActive = true

    init(run: ChatToolRunPresentation) {
        self.run = run
        super.init(frame: .zero)
        let tone = run.failureCount > 0 ? ChatUIKitTheme.error : run.isRunning ? ChatUIKitTheme.amber : ChatUIKitTheme.emerald
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
        title.text = run.title; title.font = ChatUIKitFont.sans(12, .bold); title.textColor = ChatUIKitTheme.primary; title.numberOfLines = 1
        detail.text = run.status; detail.font = ChatUIKitFont.mono(10, .semibold); detail.textColor = tone; detail.numberOfLines = 1
        elapsed.text = run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:)); elapsed.font = ChatUIKitFont.mono(10, .semibold); elapsed.textColor = tone
        activity.isHidden = !run.isRunning; activity.accentColor = tone
        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.widthAnchor.constraint(equalToConstant: 16).isActive = true
        activity.heightAnchor.constraint(equalToConstant: 16).isActive = true
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
final class ChatUIKitNotificationPill: UIControl {
    var onActivate: (() -> Void)?
    private var activityIndicator: ChatUIKitPulseLoadingView?
    private var presentationActive = true
    init(presentation: ChatNotificationPresentation) {
        super.init(frame: .zero)
        let accent = ChatUIKitTheme.notificationColor(presentation.tone)
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
        let detail = UILabel(); detail.text = presentation.detail; detail.font = ChatUIKitFont.mono(10, .semibold); detail.textColor = ChatUIKitTheme.secondary; detail.numberOfLines = 1
        row.addArrangedSubview(image); row.addArrangedSubview(title); row.addArrangedSubview(detail)
        if presentation.showsProgress {
            let spinner = ChatUIKitPulseLoadingView(accent: accent)
            spinner.accentColor = accent
            activityIndicator = spinner
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
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
final class ChatUIKitResourceChip: UIView {
    init(resource: ComposerResourceInvocation) {
        super.init(frame: .zero)
        let accent: UIColor = resource.source == .skill ? ChatUIKitTheme.cyan : resource.source == .prompt ? ChatUIKitTheme.purple : ChatUIKitTheme.indigo
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
        let kind = UILabel(); kind.text = resource.source == .skill ? "Skill" : resource.source == .prompt ? "Prompt" : "Command"; kind.font = ChatUIKitFont.mono(10, .semibold); kind.textColor = ChatUIKitTheme.secondary
        row.addArrangedSubview(icon); row.addArrangedSubview(title); row.addArrangedSubview(kind)
        isAccessibilityElement = true; accessibilityTraits = .staticText; accessibilityLabel = "\(kind.text ?? "Resource"), \(title.text ?? resource.name)"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ChatUIKitPromptCard: UIView {
    private let stack = UIStackView()
    private let accent: UIColor
    private let attachmentScroll = UIScrollView()
    private let attachmentStack = UIStackView()
    private(set) var mediaChips: [ChatUIKitMediaChip] = []
    init(title: String, text: String, detail: String?, behavior: ChatPromptBehavior) {
        accent = behavior == .steer ? ChatUIKitTheme.emerald : behavior == .followUp ? ChatUIKitTheme.purple : ChatUIKitTheme.secondary
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
        let heading = UILabel(); heading.text = title; heading.font = ChatUIKitFont.sans(12, .bold); heading.textColor = ChatUIKitTheme.primary
        let status = UILabel(); status.text = detail; status.font = ChatUIKitFont.mono(10, .semibold); status.textColor = accent; status.textAlignment = .right; status.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(heading); header.addArrangedSubview(UIView()); header.addArrangedSubview(status); stack.addArrangedSubview(header)
        if !text.isEmpty { stack.addArrangedSubview(ChatUIKitUserPromptBubble(text: text, insets: .zero, background: .clear)) }
        // Attachment controls are nested in this card and must remain reachable.
        isAccessibilityElement = false
        accessibilityElements = stack.arrangedSubviews
    }
    func setAttachments(
        _ attachments: [ChatUIKitTranscriptAttachment],
        mediaLoader: ChatMediaLoader?,
        mediaIdentity: ((String) -> ChatMediaIdentity?)?,
        reusableChips: [ChatUIKitMediaChip] = [],
        onTap: @escaping (Int) -> Void
    ) {
        guard !attachments.isEmpty else { return }
        attachmentScroll.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.showsHorizontalScrollIndicator = false
        attachmentScroll.alwaysBounceHorizontal = true
        attachmentScroll.accessibilityLabel = "Prompt attachments"
        attachmentScroll.isAccessibilityElement = false
        attachmentStack.axis = .horizontal
        attachmentStack.spacing = 8
        attachmentStack.alignment = .center
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.addSubview(attachmentStack)
        NSLayoutConstraint.activate([
            attachmentStack.leadingAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.leadingAnchor),
            attachmentStack.trailingAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.trailingAnchor),
            attachmentStack.topAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.topAnchor),
            attachmentStack.bottomAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.bottomAnchor),
            attachmentStack.heightAnchor.constraint(equalTo: attachmentScroll.frameLayoutGuide.heightAnchor),
            attachmentScroll.heightAnchor.constraint(equalToConstant: 70)
        ])
        let old = Dictionary(uniqueKeysWithValues: reusableChips.map { ($0.attachment.id, $0) })
        for (index, attachment) in attachments.enumerated() {
            let chip = old[attachment.id] ?? ChatUIKitMediaChip(attachment: attachment)
            chip.onActivate = { onTap(index) }
            chip.load(using: mediaLoader, identity: attachment.blobID.flatMap { mediaIdentity?($0) })
            attachmentStack.addArrangedSubview(chip)
            mediaChips.append(chip)
        }
        stack.addArrangedSubview(attachmentScroll)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ChatUIKitUserPromptBubble: UILabel {
    private let insets: UIEdgeInsets
    init(text: String, insets: UIEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12), background: UIColor? = nil) {
        self.insets = insets
        super.init(frame: .zero); self.text = text; numberOfLines = 0; lineBreakMode = .byWordWrapping; font = ChatUIKitFont.body(14); textColor = ChatUIKitTheme.emerald; textAlignment = .left; adjustsFontForContentSizeCategory = true; preferredMaxLayoutWidth = UserPromptTextLayoutPolicy.maximumWidth; layer.cornerRadius = ChatPromptContainerStyle.cornerRadius; layer.masksToBounds = true; self.backgroundColor = background ?? ChatUIKitTheme.emerald.withAlphaComponent(0.16); isAccessibilityElement = true; accessibilityLabel = text
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
final class ChatUIKitToolDetailCard: UIControl {
    var onActivate: (() -> Void)?
    init(title: String, status: String, content: String, isError: Bool) {
        super.init(frame: .zero)
        let accent = isError ? ChatUIKitTheme.error : ChatUIKitTheme.emerald
        let surface = ChatUIKitSurfaceView(accent: accent, cornerRadius: 12, glass: false)
        surface.translatesAutoresizingMaskIntoConstraints = false; addSubview(surface)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor), surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false; surface.content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor, constant: -10)])
        let header = UIStackView(); header.axis = .horizontal; header.spacing = 8
        let heading = UILabel(); heading.text = title; heading.font = ChatUIKitFont.sans(12, .bold); heading.textColor = ChatUIKitTheme.primary
        let state = UILabel(); state.text = status; state.font = ChatUIKitFont.mono(10, .semibold); state.textColor = accent; state.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(heading); header.addArrangedSubview(UIView()); header.addArrangedSubview(state); stack.addArrangedSubview(header)
        if !content.isEmpty { let output = UITextView(); output.text = content; output.font = ChatUIKitFont.mono(11); output.textColor = ChatUIKitTheme.secondary; output.isEditable = false; output.isSelectable = true; output.isScrollEnabled = false; output.textContainerInset = .zero; output.textContainer.lineFragmentPadding = 0; output.accessibilityLabel = "Output"; stack.addArrangedSubview(output) }
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        // Keep selectable output discoverable instead of swallowing it in the card.
        isAccessibilityElement = false
        accessibilityElements = stack.arrangedSubviews
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Open tool details") { [weak self] _ in self?.onActivate?(); return true }]
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { onActivate?() }
}

@MainActor
final class ChatUIKitTranscriptNotice: UILabel {
    init(text: String) { super.init(frame: .zero); self.text = text; numberOfLines = 0; font = ChatUIKitFont.sans(10, .semibold); textColor = ChatUIKitTheme.error; backgroundColor = ChatUIKitTheme.error.withAlphaComponent(0.10); layer.cornerRadius = 10; layer.masksToBounds = true; directionalLayoutMargins = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10); isAccessibilityElement = true; accessibilityLabel = text }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ChatUIKitModelFooter: UILabel {
    init(text: String) { super.init(frame: .zero); self.text = text; font = ChatUIKitFont.mono(10); textColor = ChatUIKitTheme.secondary; numberOfLines = 1; accessibilityLabel = text }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ChatUIKitMediaChip: UIControl {
    let attachment: ChatUIKitTranscriptAttachment
    var onActivate: (() -> Void)?
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var loader: ChatMediaLoader?
    private var identity: ChatMediaIdentity?
    private var loadGeneration: UInt64 = 0
    private var failed = false
    private var presentationActive = true
    private(set) var loadState: ChatMediaLoadState = .idle
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
        imageView.contentMode = .scaleAspectFill; imageView.clipsToBounds = true; layer.cornerRadius = 14; layer.masksToBounds = true; layer.borderWidth = 0.5; layer.borderColor = ChatUIKitTheme.border.resolvedColor(with: traitCollection).cgColor
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = normalAccessibilityLabel; accessibilityValue = attachmentFacts; accessibilityHint = "Opens a preview; activate again to retry if unavailable"
        showPlaceholder()
        if let image = attachment.preparedThumbnail { imageView.image = image }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(using loader: ChatMediaLoader?, identity: ChatMediaIdentity?) {
        if let prepared = attachment.preparedThumbnail {
            imageView.image = prepared
            failed = false
            loadState = .succeeded
        }
        let sameRequest = self.loader === loader && self.identity == identity
        let previousLoader = self.loader
        let previousIdentity = self.identity
        if !sameRequest, let previousLoader, let previousIdentity {
            previousLoader.cancelThumbnail(for: previousIdentity)
        }
        self.loader = loader
        self.identity = identity
        // Keep an in-flight or successful request stable across configure calls.
        // Failed/cancelled requests intentionally fall through so retry and
        // reactivation create a fresh generation for the same identity.
        if sameRequest && (loadState == .loading || loadState == .succeeded) { return }
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        guard presentationActive, attachment.preparedThumbnail == nil, let loader, let identity else {
            if loadState != .succeeded { loadState = .idle }
            return
        }
        if let cached = loader.cachedThumbnail(for: identity) {
            imageView.image = cached
            failed = false
            loadState = .succeeded
            return
        }
        showPlaceholder()
        failed = false
        loadState = .loading
        accessibilityLabel = normalAccessibilityLabel
        accessibilityValue = attachmentFacts
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await loader.thumbnail(for: identity)
                guard !Task.isCancelled, self.loadGeneration == generation,
                      self.identity == identity else { return }
                self.imageView.image = image
                self.failed = false
                self.loadState = .succeeded
                self.loadTask = nil
                self.accessibilityLabel = self.normalAccessibilityLabel
                self.accessibilityValue = self.attachmentFacts
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation,
                      self.identity == identity else { return }
                self.failed = true
                self.loadState = error is CancellationError ? .cancelled : .failed
                self.loadTask = nil
                if self.loadState == .failed { self.showFailure() }
            }
        }
    }
    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        let wasActive = presentationActive
        presentationActive = activity.isActive
        if presentationActive {
            if !wasActive || loadState == .cancelled || loadState == .failed {
                load(using: loader, identity: identity)
            }
        } else {
            cancelLoad()
        }
    }

    func cancelLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        if let loader, let identity { loader.cancelThumbnail(for: identity) }
        if loadState == .loading { loadState = .cancelled }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { setPresentationActivity(.inactive(generation: 0)) }
    }
    private func showPlaceholder() { imageView.image = UIImage(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text"); imageView.tintColor = ChatUIKitTheme.blue; imageView.backgroundColor = ChatUIKitTheme.blue.withAlphaComponent(0.10); accessibilityValue = attachmentFacts }
    private func showFailure() { imageView.image = UIImage(systemName: "arrow.clockwise"); imageView.tintColor = ChatUIKitTheme.blue; accessibilityValue = "Preview unavailable; activate to retry" }
    private var attachmentFacts: String {
        var values = [attachment.mimeType]
        if let size = attachment.size { values.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return values.joined(separator: ", ")
    }
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
enum ChatUIKitFont {
    static func scaled(_ font: UIFont, textStyle: UIFont.TextStyle) -> UIFont { UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font) }
    static func sans(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { scaled(TronFontLoader.createUIFont(size: size, weight: TronFontLoader.weight(weight)), textStyle: .body) }
    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { scaled(TronFontLoader.createUIFont(size: size, weight: TronFontLoader.weight(weight), mono: true), textStyle: .body) }
    static func body(_ size: CGFloat) -> UIFont { sans(size) }
}
