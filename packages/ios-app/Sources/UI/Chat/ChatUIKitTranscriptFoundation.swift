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
struct ChatUIKitTranscriptRow: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case user, assistant, streaming, thinking, tool, attachment, status
    }

    let id: String
    let text: String
    let kind: Kind
    let links: [ChatUIKitLink]
    let attachments: [String]
    let toolLabel: String?

    init?(
        id: String,
        text: String,
        kind: Kind = .assistant,
        links: [ChatUIKitLink] = [],
        attachments: [String] = [],
        toolLabel: String? = nil
    ) {
        guard !id.isEmpty,
              Set(links.map { "\($0.range.location):\($0.range.length):\($0.url.absoluteString)" }).count == links.count
        else { return nil }
        self.id = id
        self.text = text
        self.kind = kind
        self.links = links
        self.attachments = attachments
        self.toolLabel = toolLabel
    }
}

struct ChatUIKitPresentationInput: Equatable, Sendable {
    let version: UInt64
    let rows: [ChatUIKitTranscriptRow]

    init?(version: UInt64, rows: [ChatUIKitTranscriptRow]) {
        guard Set(rows.map(\.id)).count == rows.count else { return nil }
        self.version = version
        self.rows = rows
    }
}

typealias ChatUIKitTranscriptCommit = ChatUIKitPresentationInput

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

private final class ChatUIKitTranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitTranscriptCell"

    let textView = UITextView()
    private let attachmentStack = UIStackView()
    private let toolLabel = UILabel()
    var onAttachmentTapped: ((Int) -> Void)?
    var onToolTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        contentView.addSubview(textView)

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
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            toolLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            toolLabel.topAnchor.constraint(equalTo: textView.bottomAnchor),
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ]
        let value = NSMutableAttributedString(string: row.text, attributes: attributes)
        for link in row.links where NSMaxRange(link.range) <= value.length {
            value.addAttribute(.link, value: link.url, range: link.range)
        }
        textView.attributedText = value
        textView.accessibilityLabel = row.text
        textView.accessibilityIdentifier = "chat-row-\(row.id)"
        textView.accessibilityTraits = row.kind == .user ? [.staticText] : [.staticText]

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
        let intent = viewportState.intent
        input = next

        UIView.performWithoutAnimation {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
        }
        viewportState.appliedVersion = next.version

        if viewportState.interaction == .tracking || viewportState.interaction == .decelerating {
            if let anchor { viewportState.intent = .preserve(anchor) }
        } else {
            switch intent {
            case .followTail:
                setOffset(y: maxOffsetY)
            case .preserve(let semantic):
                restore(semantic)
            }
        }
        let recovered = !hasVisibleRows && !rows.isEmpty
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
        cell.configure(row)
        cell.onAttachmentTapped = { [weak self] index in
            self?.onAttachmentTapped?(row.id, index)
        }
        cell.onToolTapped = { [weak self] in self?.onToolTapped?(row.id) }
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

    private func restore(_ anchor: ChatUIKitSemanticAnchor) {
        guard let index = rows.firstIndex(where: { $0.id == anchor.rowID }) else {
            recoverBlankViewport()
            return
        }
        let path = IndexPath(item: index, section: 0)
        guard let attributes = collectionView.layoutAttributesForItem(at: path) else {
            recoverBlankViewport()
            return
        }
        setOffset(y: attributes.frame.minY - anchor.topOffset)
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
        switch viewportState.intent {
        case .followTail:
            setOffset(y: maxOffsetY)
        case .preserve(let anchor):
            if rows.contains(where: { $0.id == anchor.rowID }) { restore(anchor) }
            else { setOffset(y: minOffsetY) }
        }
        clampOffset()
    }

    private func clampOffset() {
        let y = min(max(collectionView.contentOffset.y, minOffsetY), maxOffsetY)
        guard y != collectionView.contentOffset.y else { return }
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
