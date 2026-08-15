import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Hosted ChatView scroll harness", .serialized)
struct ChatViewScrollHarnessTests {
    @Test("hosted aggregate counters and retained row frames are bounded")
    func hostedEvidenceBounds() {
        let probe = ChatHostedProbe()
        for index in 0..<300 {
            probe.updateRowFrame(
                id: "synthetic-row-\(index)",
                frame: CGRect(x: 0, y: index, width: 10, height: 10)
            )
        }
        #expect(probe.observation.rowFrames.count == 256)
        #expect(probe.observation.semanticFrameCallbackCount == 300)
    }

    @Test("harness renders the production scroll view and semantic row geometry")
    func harnessFidelity() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 101) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.scrollSettledDistance != nil
                        && sample.observation.geometry.contentHeight > sample.observation.geometry.containerHeight
                        && !sample.observation.visibleRowIDs.isEmpty
                        && !sample.observation.rowFrames.isEmpty
                }

                #expect(sample.observation.geometry.isValid)
                #expect(sample.observation.rowFrames.keys.allSatisfy(harness.transcriptIDs.contains))
                #expect(Set(sample.observation.visibleRowIDs).isSubset(of: harness.transcriptIDs))
            }
        }
    }

    @Test("a real visible semantic frame computes a zero-excursion prepend correction")
    func semanticAnchorCorrection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 106) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.rowFrames.keys.contains(where: {
                            sample.observation.visibleRowIDs.contains($0)
                        })
                }
                guard let rowID = sample.observation.visibleRowIDs.first(where: {
                    sample.observation.rowFrames[$0] != nil
                }), let capturedFrame = sample.observation.rowFrames[rowID] else {
                    Issue.record("expected a visible semantic frame")
                    return
                }
                let insertedPrefixHeight: CGFloat = 173
                let installedFrameMinY = capturedFrame.minY + insertedPrefixHeight
                let requestedOffset = ChatScrollCoordinator.prependCorrectionOffset(
                    currentOffsetY: sample.observation.geometry.offsetY,
                    capturedViewportOffsetY: capturedFrame.minY,
                    installedFrameMinY: installedFrameMinY
                )
                let restoredFrameMinY = installedFrameMinY
                    - (requestedOffset - sample.observation.geometry.offsetY)
                #expect(abs(restoredFrameMinY - capturedFrame.minY) <= 1)
            }
        }
    }

    @Test("an overflowing authoritative transcript opens at its latest tail")
    func opensAtTail() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 102) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.scrollSettledDistance != nil
                        && sample.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }

                let scrollEvents = harness.scrollEvents
                #expect((sample.observation.scrollSettledDistance ?? .infinity)
                    <= ChatTranscriptGeometry.catchUpDistance)
                #expect(sample.observation.visibleRowIDs.contains(harness.lastTranscriptID))
                #expect(!sample.observation.visibleRowIDs.contains(harness.firstTranscriptID))
                #expect(sample.observation.scrollCommandCount > 0)
                #expect(scrollEvents.first == .begin(.scrollCommandSettle))
                #expect(scrollEvents.contains(.end(.scrollCommandSettle, .success, .none)))
                #expect(!scrollEvents.contains(.end(.scrollCommandSettle, .failure, .none)))
                #expect(!scrollEvents.contains(.end(.scrollCommandSettle, .cancelled, .none)))
            }
        }
    }

    @Test("readiness is recorded only after a display-link frame")
    func firstReadyFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 104) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                #expect(harness.firstReadyEvents == [
                    .begin(.firstReadyFrame),
                    .end(.firstReadyFrame, .success, .none),
                ])
            }
        }
    }

    @Test("cancelled frame wait closes readiness exactly once")
    func cancelledReadyFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            let scheduler = DisplayFrameScheduler { throw CancellationError() }
            try await withHarness(seed: 105, displayFrameScheduler: scheduler) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                #expect(harness.firstReadyEvents == [
                    .begin(.firstReadyFrame),
                    .end(.firstReadyFrame, .cancelled, .none),
                ])
            }
        }
    }

    @Test("actual ChatView executor emits one automatic command per frame and none while detached")
    func drivenCoordinatorExecutor() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 107) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }

                let baseline = harness.recorder.samples.last?.observation.automaticScrollCommandCount ?? 0
                let projectionWorkBaseline = harness.probeObservation.projectionWorkAdmissionCount
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let firstGrowth = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_100, containerHeight: 400
                )
                let secondGrowth = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_180, containerHeight: 400
                )
                harness.driveGeometry(previous: bottom, current: firstGrowth)
                harness.driveGeometry(previous: firstGrowth, current: secondGrowth)
                try await harness.driveFrameBoundary()
                _ = try await harness.recorder.waitUntil {
                    $0.observation.automaticScrollCommandCount == baseline + 1
                }

                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveSemanticResponse()
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)
                let commandsBeforeDetachedGrowth = harness.probeObservation.scrollCommandCount
                harness.driveComposerViewportTransition()
                harness.driveGeometry(
                    previous: away,
                    current: ChatTranscriptGeometry(
                        offsetY: 300, contentHeight: 1_200, containerHeight: 400
                    )
                )
                harness.driveGeometry(
                    previous: away,
                    current: ChatTranscriptGeometry(
                        offsetY: 300, contentHeight: 1_200, containerHeight: 320, bottomInset: 80
                    ),
                    viewport: true
                )
                try await harness.driveFrameBoundary()
                #expect(
                    harness.probeObservation.scrollCommandCount
                        == commandsBeforeDetachedGrowth
                )
                #expect(
                    harness.probeObservation.projectionWorkAdmissionCount
                        == projectionWorkBaseline
                )

                let commandsBeforeCatchUp = harness.probeObservation.scrollCommandCount
                harness.driveCatchUp(reduceMotion: true)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.scrollCommandCount == commandsBeforeCatchUp + 1
                }
                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)
            }
        }
    }

    @Test("visible discrete insertion reveals once and owns one smooth follow")
    func discreteInsertionEntrance() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_190) { harness in
                let ready = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let entranceBaseline = ready.observation.animatedEntranceCount
                let smoothBaseline = ready.observation.smoothAutomaticScrollCommandCount
                let installBaseline = ready.observation.projectionInstallCount

                var updated = harness.snapshot
                updated.transcript.append(try harnessMessage(id: "discrete-tail"))
                updated.transcriptTotal = (updated.transcriptTotal ?? updated.transcript.count - 1) + 1
                updated.revision += 1
                updated.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(updated)

                let revealed = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                        && $0.observation.animatedEntranceCount == entranceBaseline + 1
                }
                #expect(revealed.observation.smoothAutomaticScrollCommandCount <= smoothBaseline + 1)

                // Repeated geometry for the same row cannot replay admission.
                if let frame = revealed.observation.rowFrames["discrete-tail"] {
                    harness.probe.updateRowFrame(id: "discrete-tail", frame: frame)
                }
                #expect(harness.probeObservation.animatedEntranceCount == entranceBaseline + 1)
            }
        }
    }

    @Test("detached discrete insertion performs no automatic write")
    func detachedDiscreteInsertion() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 1_191) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                #expect(harness.probeObservation.isDetached)

                let commandBaseline = harness.probeObservation.automaticScrollCommandCount
                let installBaseline = harness.probeObservation.projectionInstallCount
                var updated = harness.snapshot
                updated.transcript.append(try harnessMessage(id: "detached-tail"))
                updated.transcriptTotal = (updated.transcriptTotal ?? updated.transcript.count - 1) + 1
                updated.revision += 1
                updated.eventSequence += 1
                harness.replaceAuthoritativeSnapshot(updated)
                _ = try await harness.recorder.waitUntil {
                    $0.observation.projectionInstallCount > installBaseline
                }
                #expect(harness.probeObservation.automaticScrollCommandCount == commandBaseline)
            }
        }
    }

    @Test("streaming burst installs only its newest projection while detached scrolling stays writable")
    func streamingBurstLatestProjection() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 118) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.projectionInstallCount >= 1
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                #expect(harness.probeObservation.isDetached)

                var newest = harness.snapshot
                let initialSequence = newest.eventSequence
                let initialProjectionOrdinal = try #require(
                    harness.probeObservation.installedProjectionSourceOrdinal
                )
                let initialProjectionInstalls = harness.probeObservation.projectionInstallCount
                for offset in 1...30 {
                    newest.revision += 1
                    newest.eventSequence = initialSequence + offset
                    newest.streaming = newest.transcript.last
                    harness.replaceAuthoritativeSnapshot(newest)
                }

                harness.driveComposerViewportTransition()
                harness.driveGeometry(
                    previous: away,
                    current: ChatTranscriptGeometry(
                        offsetY: 300,
                        contentHeight: 1_120,
                        containerHeight: 320,
                        bottomInset: 80
                    ),
                    viewport: true
                )
                let newestInstall = try await harness.recorder.waitUntil {
                    $0.observation.installedProjectionSourceOrdinal == initialProjectionOrdinal + 30
                }
                #expect(newestInstall.observation.installedProjectionRowCount > 0)
                #expect(newestInstall.observation.isDetached)
                #expect(
                    newestInstall.observation.projectionInstallCount
                        <= initialProjectionInstalls + 2
                )
            }
        }
    }

    @Test("manual tail return hides catch-up and pinned keyboard transition follows")
    func manualTailReturnAndKeyboardFollow() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 117) { harness in
                _ = try await harness.recorder.waitUntil {
                    $0.observation.readyFrameCompletionCount == 1
                        && $0.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                        && ($0.observation.scrollSettledDistance ?? .infinity)
                            <= ChatTranscriptGeometry.catchUpDistance
                }
                let bottom = ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_000, containerHeight: 400
                )
                let away = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 400
                )
                harness.drivePhase(from: .idle, to: .interacting, geometry: bottom)
                harness.driveNativeOwnership(true)
                harness.driveGeometry(previous: bottom, current: away)
                harness.drivePhase(from: .interacting, to: .idle, geometry: away)
                harness.driveNativeOwnership(false)
                harness.driveSemanticResponse()
                #expect(harness.probeObservation.isDetached)
                #expect(harness.probeObservation.hasUnread)

                // Production callback order observed on device: the final
                // direct return can be a mixed scroll/viewport callback while
                // interactive keyboard dismissal changes the inset.
                harness.drivePhase(from: .idle, to: .interacting, geometry: away)
                let intermediateViewport = ChatTranscriptGeometry(
                    offsetY: 300, contentHeight: 1_000, containerHeight: 350
                )
                harness.driveGeometry(previous: away, current: intermediateViewport, viewport: true)
                #expect(harness.probeObservation.isDetached)
                let mixedBottom = ChatTranscriptGeometry(
                    offsetY: 700, contentHeight: 1_000, containerHeight: 300
                )
                harness.drivePhase(from: .interacting, to: .idle, geometry: mixedBottom)
                #expect(!harness.probeObservation.isDetached)
                #expect(!harness.probeObservation.hasUnread)

                let automaticBeforeKeyboard = harness.probeObservation.automaticScrollCommandCount
                harness.driveComposerViewportTransition()
                let keyboard = ChatTranscriptGeometry(
                    offsetY: 700,
                    contentHeight: 1_000,
                    containerHeight: 250,
                    bottomInset: 100
                )
                harness.driveGeometry(previous: mixedBottom, current: keyboard, viewport: true)
                try await harness.driveFrameBoundary()
                _ = try await harness.recorder.waitUntil {
                    $0.observation.automaticScrollCommandCount == automaticBeforeKeyboard + 1
                }
                #expect(!harness.probeObservation.isDetached)
            }
        }
    }

    @Test("hosted exact page barrier rejects repeat and stale prepend completion")
    func hostedPrependBarrier() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 108) { harness in
                _ = try await harness.recorder.waitUntil { sample in
                    sample.observation.readyFrameCompletionCount == 1
                        && sample.observation.visibleRowIDs.contains(where: {
                            sample.observation.rowFrames[$0] != nil
                        })
                }
                guard harness.drivePrepend() else {
                    Issue.record("expected measured hosted prepend admission")
                    return
                }
                #expect(!harness.drivePrepend())
                _ = try await harness.recorder.waitUntil { $0.observation.prependLoadWaiting }
                let callbacksBeforeRelease = harness.probeObservation.semanticFrameCallbackCount
                let automaticBeforeRelease = harness.probeObservation.automaticScrollCommandCount
                harness.releasePrependPage()
                let completed = try await harness.recorder.waitUntil {
                    $0.observation.prependCompletionResult == .success
                }
                #expect(completed.observation.semanticFrameCallbackCount > callbacksBeforeRelease)
                #expect(completed.observation.maximumSemanticExcursion <= 2)
                #expect(completed.observation.automaticScrollCommandCount == automaticBeforeRelease)

                #expect(harness.drivePrepend())
                _ = try await harness.recorder.waitUntil { $0.observation.prependLoadWaiting }
                harness.drivePresentationInvalidation()
                _ = try await harness.recorder.waitUntil {
                    $0.observation.prependCompletionResult == .discarded
                }
                harness.releasePrependPage()
            }
        }
    }

    @Test("geometry observations are coalesced to one sample per presented frame")
    func oneSamplePerPresentedFrame() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 103) { harness in
                let initial = try await harness.recorder.waitUntil { $0.observation.geometry.isValid }
                harness.resize(height: 760)
                let resized = try await harness.recorder.waitUntil {
                    abs($0.observation.geometry.containerHeight - initial.observation.geometry.containerHeight) > 1
                }
                harness.resize(height: 844)
                _ = try await harness.recorder.waitUntil {
                    $0.frameIndex > resized.frameIndex
                        && abs($0.observation.geometry.containerHeight - initial.observation.geometry.containerHeight) <= 1
                }

                let samples = harness.recorder.samples
                #expect(samples.count >= 3)
                #expect(Set(samples.map(\.frameIndex)).count == samples.count)
                for (previous, current) in zip(samples, samples.dropFirst()) {
                    #expect(
                        current.observation.automaticScrollCommandCount
                            - previous.observation.automaticScrollCommandCount <= 1
                    )
                }
            }
        }
    }

    private func withHarness(
        seed: Int,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        let harness = try ChatViewScrollHarness(
            seed: seed,
            displayFrameScheduler: displayFrameScheduler
        )
        do {
            try await operation(harness)
        } catch {
            harness.cleanup()
            throw error
        }
        harness.cleanup()
    }
}

private func harnessMessage(id: String) throws -> TranscriptItem {
    try JSONDecoder.gateway.decode(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"\(id):text","type":"text","text":"A new response"}]}
        """.utf8)
    )
}

@MainActor
final class ChatViewScrollHarness {
    let snapshot: SessionSnapshot
    let transcriptIDs: Set<String>
    let firstTranscriptID: String
    let lastTranscriptID: String
    let recorder: PresentedFrameRecorder
    let signposts: RecordingPerformanceSignposts
    let probe: ChatHostedProbe

    private let model: AppModel
    private let suiteName: String
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let window: UIWindow
    private let hostingController: UIHostingController<AnyView>

    convenience init(seed: Int, displayFrameScheduler: DisplayFrameScheduler) throws {
        try self.init(
            snapshot: SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 10_000),
            displayFrameScheduler: displayFrameScheduler
        )
    }

    init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil
    ) throws {
        self.snapshot = snapshot
        transcriptIDs = Set(snapshot.transcript.map(\.id))
        firstTranscriptID = try Self.require(snapshot.transcript.first?.id)
        lastTranscriptID = try Self.require(snapshot.transcript.last?.id)
        let signposts = RecordingPerformanceSignposts()
        self.signposts = signposts

        suiteName = "ChatViewScrollHarnessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let model = AppModel(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot)
        )
        self.model = model
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == nil else {
            throw HarnessError.invalidAuthorityBoundary
        }
        model.installHostedAuthoritativeSnapshot(snapshot)
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot else {
            throw HarnessError.invalidAuthorityBoundary
        }

        let probe = ChatHostedProbe()
        self.probe = probe
        let sessionID = snapshot.sessionId
        let root = AnyView(
            NavigationStack {
                ChatView(
                    sessionID: sessionID,
                    hostedProbe: probe,
                    displayFrameScheduler: displayFrameScheduler,
                    performanceSignposts: performanceSignposts ?? signposts
                )
            }
            .environment(model)
        )
        hostingController = UIHostingController(rootView: root)
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HarnessError.missingWindowScene
        }
        window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let hostedView = hostingController.view!
        recorder = PresentedFrameRecorder(probe: probe) { geometry in
            Self.containsNativeTranscriptScrollView(in: hostedView, matching: geometry)
        }
        recorder.start()
    }

    var probeObservation: ChatHostedObservation { probe.observation }

    func replaceAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        model.replaceHostedAuthoritativeSnapshot(snapshot)
    }

    func driveGeometry(
        previous: ChatTranscriptGeometry,
        current: ChatTranscriptGeometry,
        viewport: Bool = false
    ) {
        probe.driveGeometry(previous: previous, current: current, viewport: viewport)
    }

    func drivePhase(from: ScrollPhase, to: ScrollPhase, geometry: ChatTranscriptGeometry?) {
        probe.drivePhase(from: from, to: to, geometry: geometry)
    }

    func driveNativeOwnership(_ owned: Bool) {
        probe.driveNativeOwnership(owned)
    }

    func driveSemanticResponse() {
        probe.driveSemanticResponse()
    }

    func driveComposerViewportTransition() {
        probe.driveComposerViewportTransition()
    }

    func driveCatchUp(reduceMotion: Bool) {
        probe.driveCatchUp(reduceMotion: reduceMotion)
    }

    func drivePrepend() -> Bool { probe.drivePrepend() }

    func releasePrependPage() { probe.releasePrependPage() }

    func drivePresentationInvalidation() { probe.drivePresentationInvalidation() }

    func driveFrameBoundary() async throws {
        try await probe.driveFrameBoundary()
    }

    var firstReadyEvents: [RecordingPerformanceSignposts.Event] {
        signposts.events().filter { $0.operation == .firstReadyFrame }
    }

    var scrollEvents: [RecordingPerformanceSignposts.Event] {
        signposts.events().filter { $0.operation == .scrollCommandSettle }
    }

    private static func containsNativeTranscriptScrollView(
        in view: UIView,
        matching geometry: ChatTranscriptGeometry
    ) -> Bool {
        Self.scrollViews(in: view).contains { scrollView in
            !(scrollView is UITextView)
                && scrollView.contentSize.height > scrollView.bounds.height
                && abs(scrollView.contentSize.height - geometry.contentHeight) <= 2
                && abs(scrollView.bounds.origin.y - geometry.offsetY) <= 2
        }
    }

    func resize(height: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    func cleanup() {
        recorder.stop()
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw HarnessError.missingTranscript }
        return value
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }
}

@MainActor
final class PresentedFrameRecorder: NSObject {
    struct Sample: Sendable {
        let frameIndex: Int
        let observation: ChatHostedObservation
        let nativeGeometryMatches: Bool
    }

    private struct Waiter {
        let id: Int
        let predicate: @MainActor (Sample) -> Bool
        let continuation: CheckedContinuation<Sample, Error>
    }

    private let probe: ChatHostedProbe
    private let nativeGeometryMatches: @MainActor (ChatTranscriptGeometry) -> Bool
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var lastRevision = -1
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private(set) var samples: [Sample] = []

    init(
        probe: ChatHostedProbe,
        nativeGeometryMatches: @escaping @MainActor (ChatTranscriptGeometry) -> Bool
    ) {
        self.probe = probe
        self.nativeGeometryMatches = nativeGeometryMatches
    }

    func start() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayFrame))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    func waitUntil(_ predicate: @escaping @MainActor (Sample) -> Bool) async throws -> Sample {
        if let sample = samples.last(where: predicate) { return sample }
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id: id) }
        }
    }

    @objc private func displayFrame() {
        frameIndex += 1
        let observation = probe.observation
        guard observation.revision != lastRevision else { return }
        lastRevision = observation.revision
        let sample = Sample(
            frameIndex: frameIndex,
            observation: observation,
            nativeGeometryMatches: nativeGeometryMatches(observation.geometry)
        )
        samples.append(sample)
        if samples.count > 256 { samples.removeFirst(samples.count - 256) }

        var ready: [Waiter] = []
        var pending: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(sample) {
                ready.append(waiter)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
        for waiter in ready { waiter.continuation.resume(returning: sample) }
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum HarnessError: Error {
    case invalidAuthorityBoundary
    case missingTranscript
    case missingWindowScene
}
