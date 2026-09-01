#if HOSTED_TEST
import Foundation
import Testing
@testable import TronMobile
@preconcurrency import UIKit

/// Real hosted integration gate for the UIKit replacement. Every transcript
/// commit starts at SessionPresentationStore, crosses the real projection
/// worker and adapter, and is mounted beside the composer in a UIWindow.
@MainActor
@Suite("Hosted UIKit chat integration")
struct ChatUIKitParityHarnessTests {
    @Test("bounded authoritative tail mounts real rows and sends one exact command")
    func boundedTailAndPinnedSend() async throws {
        let harness = try await ChatUIKitHostedHarness(snapshot: harnessSnapshot(seed: 700, count: 512))
        harness.transcript.setIntent(.followTail)
        let identity = ChatUIKitComposerSendIdentity(sessionID: harness.sessionID, submissionID: "submission-700")!
        harness.applyComposer(ChatUIKitComposerInput(
            sessionID: harness.sessionID,
            text: "ship this",
            revision: 1,
            submissionID: identity.submissionID,
            trailingMode: .send,
            isTranscriptReady: true,
            isCommandReady: true
        ))
        harness.commandAdapter.nextResolution = .accepted
        try harness.tapSend()
        try harness.tapSend()

        #expect(harness.input.rows.count == ChatTranscriptPageRequest.maximumItemCount)
        #expect(harness.input.rows.first?.content != nil)
        #expect(harness.commandAdapter.commands == [
            .init(identity: identity, behavior: nil)
        ])
        #expect(harness.commandAdapter.settlements == [
            .init(identity: identity, accepted: true)
        ])
        #expect(harness.hasLegalNonblankViewport)
    }

    @Test("detached native deceleration preserves semantic anchor through streaming growth and shrink")
    func detachedStreamingSettlement() async throws {
        var snapshot = try harnessSnapshot(seed: 701, count: 24)
        let streamID = "stream-701"
        snapshot.streaming = try transcriptItem("""
        {"id":"\(streamID)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","presentationId":"\(streamID)","content":[{"id":"stream-text","type":"text","text":"seed"}]}
        """)
        let harness = try await ChatUIKitHostedHarness(snapshot: snapshot)
        let collection = harness.collectionView
        collection.setContentOffset(CGPoint(x: 0, y: min(120, harness.maxOffsetY)), animated: false)
        harness.transcript.scrollViewWillBeginDragging(collection)
        harness.transcript.scrollViewDidEndDragging(collection, willDecelerate: true)
        let anchorID = try #require(harness.firstVisibleRowID)
        let initialTop = try #require(harness.rowViewportTop(for: anchorID))

        for index in 1...12 {
            snapshot.revision += 1
            snapshot.eventSequence += 1
            snapshot.streaming = try transcriptItem("""
            {"id":"\(streamID)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","presentationId":"\(streamID)","content":[{"id":"stream-text","type":"text","text":"\(String(repeating: "stream-\(index) ", count: index * 12))"}]}
            """)
            _ = try await harness.commit(snapshot)
            let top = try #require(harness.rowViewportTop(for: anchorID))
            #expect(abs(top - initialTop) <= 2.0)
            #expect(harness.hasLegalNonblankViewport)
        }

        snapshot.revision += 1
        snapshot.eventSequence += 1
        snapshot.streaming = nil
        snapshot.transcript.append(try transcriptItem("""
        {"id":"canonical-701","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","presentationId":"canonical-701","content":[{"id":"canonical-text","type":"text","text":"final"}]}
        """))
        _ = try await harness.commit(snapshot)
        harness.transcript.scrollViewDidEndDecelerating(collection)
        #expect(harness.transcript.viewportState.interaction == .idle)
        #expect(abs((try #require(harness.rowViewportTop(for: anchorID))) - initialTop) <= 2.0)
        #expect(harness.hasLegalNonblankViewport)
    }

    @Test("detached prepend uses the exact preceding page and emits load-earlier once")
    func exactPrecedingPageAndLoadEarlierIntent() async throws {
        let builder = SessionScenarioBuilder(seed: 702)
        let tailItems = builder.pagedMixedSession(totalEntries: 12).page(before: 12, count: 8)
        var tail = try harnessSnapshot(seed: 702, count: 8)
        tail.transcript = tailItems
        tail.transcriptStart = 4
        tail.transcriptTotal = 12
        let harness = try await ChatUIKitHostedHarness(snapshot: tail)
        harness.transcript.scrollViewWillBeginDragging(harness.collectionView)
        harness.transcript.scrollViewDidEndDragging(harness.collectionView, willDecelerate: true)
        harness.loadEarlierRequestCount = 0
        harness.onLoadEarlier = {
            harness.loadEarlierRequestCount += 1
            harness.nextUIVersion &+= 1
            let loading = ChatUIKitPresentationInput(
                generation: harness.input.generation,
                version: harness.nextUIVersion,
                rows: harness.input.rows,
                history: .loading
            )!
            _ = harness.transcript.apply(loading)
        }

        let historyButton = try #require(harness.historyButton)
        historyButton.sendActions(for: .primaryActionTriggered)
        #expect(!historyButton.isEnabled)
        if historyButton.isEnabled {
            historyButton.sendActions(for: .primaryActionTriggered)
        }
        #expect(harness.loadEarlierRequestCount == 1)

        let page = builder.pagedMixedSession(totalEntries: 12).page(before: 4, count: 4)
        let visible = page + tailItems
        var full = tail
        full.transcript = visible
        full.transcriptStart = 0
        full.transcriptTotal = 12
        harness.authority.installHostedLoadedHistory(visible: full, authoritativeTail: tail)
        _ = try await harness.publishCurrent()
        harness.transcript.scrollViewDidEndDecelerating(harness.collectionView)
        #expect(harness.authority.visibleTranscript.map(\.id) == visible.map(\.id))
        #expect(harness.input.rows.count == visible.count)
        #expect(harness.hasLegalNonblankViewport)
    }

    @Test("presentation replacement accepts lower new version and rejects old streaming payload")
    func generationReplacementRejectsLatePayload() async throws {
        var old = try harnessSnapshot(seed: 703, count: 12)
        old.streaming = try transcriptItem("""
        {"id":"old-stream","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","presentationId":"old-stream","content":[{"id":"old-text","type":"text","text":"old"}]}
        """)
        let harness = try await ChatUIKitHostedHarness(snapshot: old, version: 20)
        let oldInput = harness.input
        var replacement = try harnessSnapshot(seed: 704, count: 5)
        replacement.sessionId = old.sessionId
        replacement.runtimeGeneration = "replacement-runtime"
        replacement.revision = 1
        replacement.eventSequence = 1
        replacement.transcript = try [transcriptItem("""
        {"id":"new-payload","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","presentationId":"new-payload","content":[{"id":"new-text","type":"text","text":"new"}]}
        """)]
        let newInput = try await harness.commit(replacement, replacesPresentation: true, version: 1)
        #expect(harness.transcript.apply(oldInput) == .stale(oldInput.version))
        #expect(harness.input == newInput)
        #expect(harness.input.rows.map(\.id) == ["new-payload"])
    }

    @Test("rejection retries while accepted unacknowledged identity suppresses duplicates")
    func composerIdentitySettlement() async throws {
        let harness = try await ChatUIKitHostedHarness(snapshot: harnessSnapshot(seed: 705, count: 8))
        let rejected = ChatUIKitComposerSendIdentity(sessionID: harness.sessionID, submissionID: "reject-705")!
        harness.applyComposer(ChatUIKitComposerInput(
            sessionID: harness.sessionID, text: "retry", revision: 1,
            submissionID: rejected.submissionID, trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        harness.commandAdapter.nextResolution = .rejected
        try harness.tapSend()
        try harness.tapSend()
        #expect(harness.commandAdapter.commands.map(\.identity) == [rejected, rejected])
        #expect(harness.commandAdapter.settlements.map(\.identity) == [rejected, rejected])

        let accepted = ChatUIKitComposerSendIdentity(sessionID: harness.sessionID, submissionID: "accepted-705")!
        harness.applyComposer(ChatUIKitComposerInput(
            sessionID: harness.sessionID, text: "ambiguous", revision: 2,
            submissionID: accepted.submissionID, trailingMode: .send,
            isTranscriptReady: true, isCommandReady: true
        ))
        harness.commandAdapter.nextResolution = .unacknowledged
        try harness.tapSend()
        try harness.tapSend()
        harness.applyComposer(ChatUIKitComposerInput(
            sessionID: harness.sessionID, text: "ambiguous", revision: 3,
            submissionID: accepted.submissionID, trailingMode: .send,
            isSending: true, isTranscriptReady: true, isCommandReady: true
        ))
        harness.commandAdapter.settle(identity: accepted, accepted: true, composer: harness.composer)
        try harness.tapSend()
        #expect(harness.commandAdapter.commands.map(\.identity) == [rejected, rejected, accepted])
        #expect(harness.commandAdapter.settlements.last == .init(identity: accepted, accepted: true))
    }

    @Test("canonical Markdown, media, lifecycle, tool, queue, traits and accessibility mount together")
    func canonicalRowsAndTraits() async throws {
        var snapshot = try harnessSnapshot(seed: 706, count: 1)
        snapshot.transcript = try canonicalRowsFixture()
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.phase = .running
        snapshot.toolExecutions = SessionScenarioBuilder(seed: 706).liveToolBurst(count: 100)
        snapshot.queuedItems = [
            .init(id: "queue-706", behavior: .followUp, text: "after this", attachmentCount: 0)
        ]
        let harness = try await ChatUIKitHostedHarness(snapshot: snapshot)
        let rows = harness.input.rows
        #expect(rows.contains { $0.markdownDocuments.flatMap(\.blocks).contains { block in
            if case .code = block.kind { return true }; return false
        }})
        #expect(rows.contains { $0.markdownDocuments.flatMap(\.blocks).contains { block in
            if case .table = block.kind { return true }; return false
        }})
        #expect(rows.contains { !$0.links.isEmpty })
        #expect(rows.contains { !$0.thinkingSegments.isEmpty })
        #expect(rows.contains { !$0.attachmentFacts.isEmpty })
        #expect(rows.contains { $0.kind == .tool })
        #expect(rows.contains { $0.kind == .status })
        #expect(harness.collectionView.visibleCells.contains(where: harness.hasAccessibleContent(in:)))

        harness.window.overrideUserInterfaceStyle = .dark
        harness.shell.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            forChild: harness.transcript
        )
        harness.shell.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            forChild: harness.composer
        )
        harness.window.layoutIfNeeded()
        #expect(harness.transcript.view.traitCollection.userInterfaceStyle == .dark)
        #expect(harness.composer.view.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect((harness.composer.view.accessibilityElements?.isEmpty == false))
    }

    @Test("keyboard ownership and presentation activity follow real window lifecycle")
    func keyboardAndLifecycleOwnership() async throws {
        let harness = try await ChatUIKitHostedHarness(snapshot: harnessSnapshot(seed: 707, count: 8))
        #expect(harness.composer.view.window === harness.window)
        #expect(harness.composer.hostedKeyboardObserverCount == 2)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        harness.composer.view.removeFromSuperview()
        await Task.yield()
        await Task.yield()
        #expect(harness.composer.view.window == nil)
        #expect(harness.composer.hostedKeyboardObserverCount == 0)

        let inactive = ChatUIKitPresentationActivity.inactive(generation: 9)
        harness.transcript.setPresentationActivity(inactive)
        #expect(!harness.transcript.hostedPresentationActivity.isActive)
        harness.transcript.setPresentationActivity(.active(generation: 10))
        #expect(harness.transcript.hostedPresentationActivity.isActive)
    }
}

@MainActor
private final class ChatUIKitHostedHarness {
    // Keep test windows alive for the suite so UIKit does not tear down a key
    // root controller mid-appearance between Swift Testing cases. The one
    // lifecycle test detaches its root explicitly and verifies cleanup.
    private static var retainedWindows: [UIWindow] = []
    enum Resolution { case accepted, rejected, unacknowledged }

    struct Command: Equatable {
        let identity: ChatUIKitComposerSendIdentity
        let behavior: String?
    }

    struct Settlement: Equatable {
        let identity: ChatUIKitComposerSendIdentity
        let accepted: Bool
    }

    @MainActor
    final class RecordingCommandAdapter {
        var commands: [Command] = []
        var settlements: [Settlement] = []
        var nextResolution: Resolution = .unacknowledged

        func receive(
            _ intent: ChatUIKitComposerIntent,
            resolve: (ChatUIKitComposerSendIdentity, Bool) -> Void
        ) {
            guard case .send(let behavior, let identity) = intent else { return }
            commands.append(.init(identity: identity, behavior: behavior))
            switch nextResolution {
            case .accepted:
                settlements.append(.init(identity: identity, accepted: true))
                resolve(identity, true)
            case .rejected:
                settlements.append(.init(identity: identity, accepted: false))
                resolve(identity, false)
            case .unacknowledged:
                break
            }
        }

        func settle(
            identity: ChatUIKitComposerSendIdentity,
            accepted: Bool,
            composer: ChatUIKitComposerController
        ) {
            settlements.append(.init(identity: identity, accepted: accepted))
            composer.resolveSend(identity: identity, accepted: accepted)
        }
    }

    let authority: SessionPresentationStore
    let presentation: ChatTranscriptPresentationStore
    let transcript: ChatUIKitChatViewController
    let composer: ChatUIKitComposerController
    let shell: ShellViewController
    let window: UIWindow
    let commandAdapter = RecordingCommandAdapter()
    private(set) var input: ChatUIKitPresentationInput
    var nextUIVersion: UInt64
    var loadEarlierRequestCount = 0
    var onLoadEarlier: (() -> Void)? {
        didSet { transcript.onLoadEarlier = onLoadEarlier }
    }
    let sessionID: String

    init(snapshot: SessionSnapshot, version: UInt64 = 1) async throws {
        sessionID = snapshot.sessionId
        authority = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        presentation = ChatTranscriptPresentationStore()
        transcript = ChatUIKitChatViewController()
        composer = ChatUIKitComposerController()
        shell = ShellViewController(transcript: transcript, composer: composer)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        nextUIVersion = version
        window.rootViewController = shell
        window.makeKeyAndVisible()
        Self.retainedWindows.append(window)
        shell.loadViewIfNeeded()
        shell.view.frame = window.bounds
        shell.view.layoutIfNeeded()
        // Let UIKit finish the real root-controller appearance transition
        // before lifecycle and trait assertions inspect the mounted children.
        await Task.yield()
        await Task.yield()
        shell.view.layoutIfNeeded()
        transcript.loadViewIfNeeded()
        composer.loadViewIfNeeded()
        input = try #require(ChatUIKitPresentationInput(version: 0, rows: []))
        transcript.onLoadEarlier = nil
        composer.onIntent = { [weak composer, weak self] intent in
            guard let self else { return }
            self.commandAdapter.receive(intent) { identity, accepted in
                composer?.resolveSend(identity: identity, accepted: accepted)
            }
        }
        _ = try await commit(snapshot, version: version)
    }

    func commit(
        _ snapshot: SessionSnapshot,
        replacesPresentation: Bool = false,
        version: UInt64? = nil
    ) async throws -> ChatUIKitPresentationInput {
        if replacesPresentation || authority.presentationTarget(for: sessionID) == nil {
            authority.installHostedAuthoritativeSnapshot(snapshot)
        } else {
            authority.replaceHostedSnapshot(snapshot)
        }
        return try await publishCurrent(version: version)
    }

    func publishCurrent(version: UInt64? = nil) async throws -> ChatUIKitPresentationInput {
        let source = try #require(authority.transcriptSnapshot(for: sessionID))
        let target = try #require(authority.presentationTarget(for: sessionID))
        let handoff = ChatTranscriptHandoffCommit.none
        let tag = ChatTranscriptProjectionTag(
            snapshot: source,
            presentationGeneration: target.generation,
            handoff: handoff
        )
        _ = presentation.submit(snapshot: source, handoff: handoff, tag: tag)
        let installed = try await presentation.waitForInstall(of: tag)
        let nextVersion = version ?? (nextUIVersion &+ 1)
        nextUIVersion = nextVersion
        let next = try #require(ChatUIKitPresentationAdapter.input(
            from: installed,
            generation: UInt64(target.generation),
            version: nextVersion
        ))
        input = next
        _ = transcript.apply(next)
        transcript.view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        return next
    }

    func applyComposer(_ next: ChatUIKitComposerInput) {
        composer.apply(next)
        composer.view.layoutIfNeeded()
    }

    func tapSend() throws {
        composer.hostedTrailingButton.sendActions(for: .primaryActionTriggered)
    }

    var collectionView: UICollectionView {
        guard let value = descendant(of: transcript.view, matching: UICollectionView.self) else {
            fatalError("UIKit transcript collection view is not mounted")
        }
        return value
    }

    var historyButton: UIButton? {
        descendant(of: transcript.view) { view in
            guard let button = view as? UIButton else { return false }
            return button.title(for: .normal) == "Load earlier messages"
        } as? UIButton
    }

    var maxOffsetY: CGFloat {
        max(-collectionView.adjustedContentInset.top,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    }

    var firstVisibleRowID: String? {
        collectionView.visibleCells.compactMap { cell -> String? in
            guard let path = collectionView.indexPath(for: cell), path.item < input.rows.count else { return nil }
            return input.rows[path.item].id
        }.first
    }

    func rowFrame(for id: String) -> CGRect? {
        guard let index = input.rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    }

    func rowViewportTop(for id: String) -> CGFloat? {
        rowFrame(for: id).map { $0.minY - collectionView.contentOffset.y }
    }

    var hasLegalNonblankViewport: Bool {
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(minimum, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let legal = collectionView.contentOffset.y >= minimum - 0.5 && collectionView.contentOffset.y <= maximum + 0.5
        let visible = collectionView.visibleCells.contains { $0.frame.intersects(collectionView.bounds.insetBy(dx: 0, dy: 1)) }
        return legal && (input.rows.isEmpty || visible)
    }

    func hasAccessibleContent(in view: UIView) -> Bool {
        if !(view.accessibilityLabel ?? "").isEmpty || !(view.accessibilityValue ?? "").isEmpty {
            return true
        }
        return view.subviews.contains(where: hasAccessibleContent(in:))
    }

    private func descendant<T: UIView>(of view: UIView, matching type: T.Type) -> T? {
        if let value = view as? T { return value }
        for child in view.subviews {
            if let value = descendant(of: child, matching: type) { return value }
        }
        return nil
    }

    private func descendant(of view: UIView, where predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let value = descendant(of: child, where: predicate) { return value }
        }
        return nil
    }
}

@MainActor
private final class ShellViewController: UIViewController {
    private let transcript: ChatUIKitChatViewController
    private let composer: ChatUIKitComposerController

    init(transcript: ChatUIKitChatViewController, composer: ChatUIKitComposerController) {
        self.transcript = transcript
        self.composer = composer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(transcript)
        addChild(composer)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view)
        view.addSubview(composer.view)
        NSLayoutConstraint.activate([
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: composer.view.topAnchor),
            composer.view.heightAnchor.constraint(equalToConstant: 120),
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        transcript.didMove(toParent: self)
        composer.didMove(toParent: self)
    }
}

private func harnessSnapshot(seed: Int, count: Int) throws -> SessionSnapshot {
    var snapshot = try SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 4_096)
    snapshot.transcript = SessionScenarioBuilder(seed: seed).pagedMixedSession(totalEntries: count).page(before: count, count: count)
    snapshot.transcriptStart = 0
    snapshot.transcriptTotal = count
    snapshot.revision = 1
    snapshot.eventSequence = 1
    return snapshot
}

private func transcriptItem(_ json: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(TranscriptItem.self, from: Data(json.utf8))
}

private func canonicalRowsFixture() throws -> [TranscriptItem] {
    try [
        transcriptItem("""
        {"id":"user-rich","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","presentationId":"user-rich","content":[{"id":"user-text","type":"text","text":"Review [the link](https://example.invalid/docs)\\n\\n```swift\\nlet value = 1\\n```\\n\\n| Name | Value |\\n| --- | --- |\\n| one | two |"}]}
        """),
        transcriptItem("""
        {"id":"assistant-rich","parentId":"user-rich","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","presentationId":"assistant-rich","content":[{"id":"thinking","type":"thinking","text":"Checking the request"},{"id":"answer","type":"text","text":"See [details](https://example.invalid/details)\\n\\n```swift\\nlet value = 1\\n```\\n\\n| Name | Value |\\n| --- | --- |\\n| one | two |"},{"id":"attachment","type":"image","attachment":{"name":"diagram.png","mimeType":"image/png","size":12},"mimeType":"image/png","blobId":"blob-706"}]}
        """),
        transcriptItem("""
        {"id":"custom-rich","parentId":"assistant-rich","timestamp":"2026-01-01T00:00:02Z","kind":"customMessage","customType":"notice","content":[{"id":"custom-text","type":"text","text":"Inbound context"}]}
        """),
        transcriptItem("""
        {"id":"bash-rich","parentId":"custom-rich","timestamp":"2026-01-01T00:00:03Z","kind":"bash","command":"printf ok","output":"ok","exitCode":0,"cancelled":false,"truncated":false}
        """),
        transcriptItem("""
        {"id":"summary-rich","parentId":"bash-rich","timestamp":"2026-01-01T00:00:04Z","kind":"compaction","summary":"Context compacted"}
        """),
        transcriptItem("""
        {"id":"thinking-change-rich","parentId":"summary-rich","timestamp":"2026-01-01T00:00:05Z","kind":"thinkingChange","level":"high"}
        """),
        transcriptItem("""
        {"id":"label-rich","parentId":"thinking-change-rich","timestamp":"2026-01-01T00:00:06Z","kind":"label","targetId":"assistant-rich","label":"checkpoint"}
        """)
    ]
}
#endif
