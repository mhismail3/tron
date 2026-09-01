import Foundation
@preconcurrency import UIKit

/// The sole native viewport owner for the UIKit chat replacement. Its state is
/// intentionally finite: one intent, one interaction phase, and one active
/// transaction. Presentation updates are measured before and after layout;
/// no target materialization or second offset writer is used.
@MainActor
final class ChatUIKitChatViewController: UIViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UIScrollViewDelegate
{
    private(set) var input: ChatUIKitPresentationInput?
    private(set) var viewportState = ChatUIKitViewportState()
    var onAttachmentTapped: ((String, Int) -> Void)?
    /// The existing transcript/paging owner performs the request. UIKit emits
    /// this one semantic action and never tracks a page or cursor.
    var onLoadEarlier: (() -> Void)?
    var onToolTapped: ((String) -> Void)?
    var onThinkingDetails: ((String) -> Void)?
    var onNotificationDetails: ((String) -> Void)?
    /// The app/model owner supplies the existing lifecycle-bound media loader;
    /// UIKit never creates a second cache or fetches Gateway blobs itself.
    var chatMediaLoader: ChatMediaLoader?
    var chatMediaIdentity: ((String) -> ChatMediaIdentity?)?
    var onTransactionOutcome: ((ChatUIKitViewportTransactionOutcome) -> Void)?
    private var presentationActivity = ChatUIKitPresentationActivity.active(generation: 0)

    private var rows: [ChatUIKitTranscriptRow] { input?.rows ?? [] }
    private var historyOffset: Int { input?.history.isAffordanceVisible == true ? 1 : 0 }
    private let collectionView: UICollectionView

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 1
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        view.backgroundColor = ChatUIKitTheme.background
        collectionView.backgroundColor = ChatUIKitTheme.background
        collectionView.collectionViewLayout.invalidateLayout()
        if let input {
            for cell in collectionView.visibleCells {
                guard let transcriptCell = cell as? ChatUIKitTranscriptCell,
                      let indexPath = collectionView.indexPath(for: cell),
                      let rowIndex = rowIndex(for: indexPath), rowIndex < input.rows.count else { continue }
                transcriptCell.configure(input.rows[rowIndex], forceRefresh: true)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ChatUIKitTheme.background
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = ChatUIKitTheme.background
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ChatUIKitTranscriptCell.self, forCellWithReuseIdentifier: ChatUIKitTranscriptCell.reuseIdentifier)
        collectionView.register(ChatUIKitHistoryCell.self, forCellWithReuseIdentifier: ChatUIKitHistoryCell.reuseIdentifier)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Applies one complete presentation input. The outcome is emitted exactly
    /// once, including recovery/cancellation, and the detached intent survives
    /// all recovery paths.
    @discardableResult
    func apply(_ next: ChatUIKitPresentationInput) -> ChatUIKitViewportTransactionOutcome {
        if let appliedVersion = viewportState.appliedVersion, next.version <= appliedVersion {
            let outcome: ChatUIKitViewportTransactionOutcome = .stale(next.version)
            onTransactionOutcome?(outcome)
            return outcome
        }
        guard viewportState.transactionID < .max else {
            let outcome: ChatUIKitViewportTransactionOutcome = .failed(
                viewportState.transactionID,
                "Viewport transaction sequence exhausted"
            )
            onTransactionOutcome?(outcome)
            return outcome
        }
        viewportState.transactionID += 1
        let transactionID = viewportState.transactionID
        // Capture the semantic row and its measured pixel offset before any
        // mutation. Native contentOffset alone cannot account for prepend or
        // row-height changes while a gesture is in flight.
        let anchor = captureAnchor()
        let intent = viewportState.intent
        let isInteracting = viewportState.interaction == .tracking
            || viewportState.interaction == .decelerating
        let previousRows = input?.rows ?? []
        let previousHistory = input?.history ?? .hidden
        input = next

        UIView.performWithoutAnimation {
            if previousRows.map(\.id) == next.rows.map(\.id), previousHistory == next.history {
                // Existing cells are updated in place. This preserves mounted
                // TextKit/link/code-copy state while the authority streams a
                // new row presentation and avoids reloading unrelated cells.
                for cell in collectionView.visibleCells {
                    guard let indexPath = collectionView.indexPath(for: cell),
                          let rowIndex = rowIndex(for: indexPath),
                          rowIndex < next.rows.count,
                          let transcriptCell = cell as? ChatUIKitTranscriptCell else { continue }
                    transcriptCell.configure(next.rows[rowIndex])
                }
            } else {
                collectionView.reloadData()
            }
            // Streaming changes retain row identity but can change TextKit
            // height. Invalidate the native layout after the in-place update;
            // otherwise estimated heights stay stale and the viewport can
            // legally land beyond the nonblank intersection.
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
        viewportState.appliedVersion = next.version

        if isInteracting {
            // Restore against post-layout attributes. If the captured row was
            // removed, restore the nearest retained ordinal rather than
            // jumping to an unconditional top offset.
            if let anchor {
                viewportState.intent = .preserve(restore(anchor) ?? anchor)
            }
        } else {
            switch intent {
            case .followTail:
                setOffset(y: maxOffsetY)
            case .preserve(let semantic):
                // Keep a missing semantic request visible to recovery and
                // diagnostics; ordinal fallback may repair pixels without
                // rewriting the caller's anchor identity.
                if rows.contains(where: { $0.id == semantic.rowID }),
                   let retained = restore(semantic) {
                    viewportState.intent = .preserve(retained)
                }
            }
        }
        let missingRequestedAnchor: Bool = switch intent {
        case .followTail: false
        case .preserve(let anchor): !rows.contains(where: { $0.id == anchor.rowID })
        }
        let recovered = !isInteracting && !rows.isEmpty
            && (!hasVisibleRows || missingRequestedAnchor)
        if recovered { recoverBlankViewport() }
        clampOffset()
        let outcome: ChatUIKitViewportTransactionOutcome = recovered
            ? .recovered(transactionID)
            : .applied(transactionID)
        onTransactionOutcome?(outcome)
        return outcome
    }

    /// Presentation activity is explicit so covered/inactive generations stop
    /// row-local work without creating another lifecycle owner.
    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        presentationActivity = activity
        for cell in collectionView.visibleCells {
            if let historyCell = cell as? ChatUIKitHistoryCell { historyCell.setPresentationActivity(activity) }
            if let transcriptCell = cell as? ChatUIKitTranscriptCell { transcriptCell.setPresentationActivity(activity) }
        }
    }

    func setIntent(_ intent: ChatUIKitViewportIntent) {
        guard viewportState.interaction == .idle else { return }
        viewportState.intent = intent
        switch intent {
        case .followTail: setOffset(y: maxOffsetY)
        case .preserve(let anchor):
            if let retained = restore(anchor) { viewportState.intent = .preserve(retained) }
        }
        clampOffset()
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count + historyOffset
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if indexPath.item < historyOffset {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatUIKitHistoryCell.reuseIdentifier,
                for: indexPath
            ) as! ChatUIKitHistoryCell
            cell.setPresentationActivity(presentationActivity)
            cell.configure(input?.history ?? .hidden) { [weak self] in self?.onLoadEarlier?() }
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ChatUIKitTranscriptCell.reuseIdentifier,
            for: indexPath
        ) as! ChatUIKitTranscriptCell
        let rowIndex = indexPath.item - historyOffset
        let row = rows[rowIndex]
        cell.onAttachmentTapped = { [weak self] index in
            self?.onAttachmentTapped?(row.id, index)
        }
        cell.onToolTapped = { [weak self] in self?.onToolTapped?(row.id) }
        cell.onThinkingDetails = { [weak self] in self?.onThinkingDetails?(row.id) }
        cell.onNotificationDetails = { [weak self] in self?.onNotificationDetails?(row.id) }
        cell.mediaLoader = chatMediaLoader
        cell.mediaIdentity = chatMediaIdentity
        cell.setPresentationActivity(presentationActivity)
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
        guard let path = visible.first(where: { $0.item >= historyOffset }),
              let rowIndex = rowIndex(for: path),
              let attributes = collectionView.layoutAttributesForItem(at: path) else { return nil }
        return ChatUIKitSemanticAnchor(
            rowID: rows[rowIndex].id,
            ordinal: rowIndex,
            topOffset: attributes.frame.minY - collectionView.contentOffset.y
        )
    }

    @discardableResult
    private func restore(_ anchor: ChatUIKitSemanticAnchor) -> ChatUIKitSemanticAnchor? {
        guard !rows.isEmpty else { return nil }
        let index = rows.firstIndex(where: { $0.id == anchor.rowID })
            ?? min(max(anchor.ordinal, 0), rows.count - 1)
        let path = IndexPath(item: index + historyOffset, section: 0)
        guard let attributes = collectionView.layoutAttributesForItem(at: path) else {
            return nil
        }
        setOffset(y: attributes.frame.minY - anchor.topOffset)
        return ChatUIKitSemanticAnchor(rowID: rows[index].id, ordinal: index, topOffset: anchor.topOffset)
    }

    private func rowIndex(for path: IndexPath) -> Int? {
        let index = path.item - historyOffset
        return rows.indices.contains(index) ? index : nil
    }

    private var minOffsetY: CGFloat { -collectionView.adjustedContentInset.top }

    private var maxOffsetY: CGFloat {
        max(minOffsetY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    }

    private var hasVisibleRows: Bool {
        collectionView.indexPathsForVisibleItems.contains {
            $0.item >= historyOffset && $0.item < rows.count + historyOffset
        }
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
            guard restore(anchor) != nil else { setOffset(y: minOffsetY); return }
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
}
