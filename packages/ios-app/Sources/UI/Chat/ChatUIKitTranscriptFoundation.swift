import Foundation
@preconcurrency import UIKit

/// UIKit-facing row facts. The eventual renderer may replace `text` with
/// hosted content, but identity and ordering remain owned by the presentation
/// commit rather than by a cell or scroll callback.
struct ChatUIKitTranscriptRow: Hashable, Sendable {
    let id: String
    let text: String

    init?(id: String, text: String) {
        guard !id.isEmpty else { return nil }
        self.id = id
        self.text = text
    }
}

struct ChatUIKitTranscriptCommit: Equatable, Sendable {
    let version: UInt64
    let rows: [ChatUIKitTranscriptRow]

    init?(version: UInt64, rows: [ChatUIKitTranscriptRow]) {
        guard Set(rows.map(\.id)).count == rows.count else { return nil }
        self.version = version
        self.rows = rows
    }
}

private final class ChatUIKitTranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatUIKitTranscriptCell"

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// UIKit-only interactive transcript foundation. It is intentionally not
/// mounted by production navigation in this phase; its narrow API is the
/// future replacement boundary for the SwiftUI transcript surface.
@MainActor
final class ChatUIKitChatViewController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UITextViewDelegate
{
    private struct VisibleAnchor {
        let rowID: String
        let topOffset: CGFloat
    }

    private(set) var commit: ChatUIKitTranscriptCommit?
    var onSend: ((String) -> Void)?

    private var rows: [ChatUIKitTranscriptRow] { commit?.rows ?? [] }
    private let collectionView: UICollectionView
    private let composer = UITextView()
    private let sendButton = UIButton(type: .system)

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
        collectionView.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            ChatUIKitTranscriptCell.self,
            forCellWithReuseIdentifier: ChatUIKitTranscriptCell.reuseIdentifier
        )

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.font = .preferredFont(forTextStyle: .body)
        composer.layer.cornerRadius = 8
        composer.layer.borderWidth = 1
        composer.layer.borderColor = UIColor.separator.cgColor
        composer.isScrollEnabled = false
        composer.delegate = self

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("Send", for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let composerBar = UIView()
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        composerBar.addSubview(composer)
        composerBar.addSubview(sendButton)
        view.addSubview(collectionView)
        view.addSubview(composerBar)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: composerBar.topAnchor),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            composer.topAnchor.constraint(equalTo: composerBar.topAnchor),
            composer.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor),
            composer.bottomAnchor.constraint(equalTo: composerBar.bottomAnchor),
            sendButton.leadingAnchor.constraint(equalTo: composer.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: composer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 52),
        ])
    }

    /// Applies one immutable presentation commit and restores either the
    /// physical tail or one measured semantic row. No other object may write
    /// the collection view's content offset.
    func apply(_ next: ChatUIKitTranscriptCommit, animated: Bool = false) {
        let pinned = isPinned
        let anchor = pinned ? nil : captureAnchor()
        commit = next
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if pinned {
            setPinnedOffset(animated: animated)
        } else if let anchor {
            restore(anchor, animated: animated)
        }
        clampOffset(animated: false)
    }

    var isPinned: Bool {
        let distance = maxOffsetY - collectionView.contentOffset.y
        return distance <= 24
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int { rows.count }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ChatUIKitTranscriptCell.reuseIdentifier,
            for: indexPath
        ) as! ChatUIKitTranscriptCell
        cell.label.text = rows[indexPath.item].text
        return cell
    }

    private func captureAnchor() -> VisibleAnchor? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let indexPath = visible.first,
              indexPath.item < rows.count,
              let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return VisibleAnchor(
            rowID: rows[indexPath.item].id,
            topOffset: cell.frame.minY - collectionView.contentOffset.y
        )
    }

    private func restore(_ anchor: VisibleAnchor, animated: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == anchor.rowID }) else {
            clampOffset(animated: animated)
            return
        }
        collectionView.layoutIfNeeded()
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.cellForItem(at: path) else {
            collectionView.scrollToItem(at: path, at: .top, animated: false)
            collectionView.layoutIfNeeded()
            guard let materialized = collectionView.cellForItem(at: path) else { return }
            let target = materialized.frame.minY - anchor.topOffset
            setOffset(y: target, animated: animated)
            return
        }
        setOffset(y: cell.frame.minY - anchor.topOffset, animated: animated)
    }

    private func setPinnedOffset(animated: Bool) {
        setOffset(y: maxOffsetY, animated: animated)
    }

    private var minOffsetY: CGFloat { -collectionView.adjustedContentInset.top }

    private var maxOffsetY: CGFloat {
        max(
            minOffsetY,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
    }

    private func clampOffset(animated: Bool) {
        let clamped = min(max(collectionView.contentOffset.y, minOffsetY), maxOffsetY)
        guard clamped != collectionView.contentOffset.y else { return }
        setOffset(y: clamped, animated: animated)
    }

    private func setOffset(y: CGFloat, animated: Bool) {
        let bounded = min(max(y, minOffsetY), maxOffsetY)
        let point = CGPoint(x: collectionView.contentOffset.x, y: bounded)
        if animated {
            collectionView.setContentOffset(point, animated: true)
        } else {
            collectionView.contentOffset = point
        }
    }

    @objc private func sendTapped() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.text = nil
        onSend?(text)
    }
}
