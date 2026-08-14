import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Hosted ChatView scroll harness", .serialized)
struct ChatViewScrollHarnessTests {
    @Test("harness renders the production scroll view and semantic row geometry")
    func harnessFidelity() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 101) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.geometry.contentHeight > sample.observation.geometry.containerHeight
                        && !sample.observation.visibleRowIDs.isEmpty
                        && !sample.observation.rowFrames.isEmpty
                }

                #expect(harness.containsNativeTranscriptScrollView(matching: sample.observation.geometry))
                #expect(sample.observation.geometry.isValid)
                #expect(sample.observation.rowFrames.keys.allSatisfy(harness.transcriptIDs.contains))
                #expect(Set(sample.observation.visibleRowIDs).isSubset(of: harness.transcriptIDs))
            }
        }
    }

    @Test("an overflowing authoritative transcript opens at its latest tail")
    func opensAtTail() async throws {
        try await withTestWatchdog(timeout: .seconds(10)) {
            try await withHarness(seed: 102) { harness in
                let sample = try await harness.recorder.waitUntil { sample in
                    sample.observation.isReady
                        && sample.observation.geometry.isValid
                        && sample.observation.visibleRowIDs.contains(harness.lastTranscriptID)
                }

                #expect(sample.observation.geometry.distanceFromBottom < sample.observation.geometry.containerHeight)
                #expect(sample.observation.visibleRowIDs.contains(harness.lastTranscriptID))
                #expect(!sample.observation.visibleRowIDs.contains(harness.firstTranscriptID))
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
            }
        }
    }

    private func withHarness(
        seed: Int,
        operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void
    ) async throws {
        let harness = try ChatViewScrollHarness(seed: seed)
        do {
            try await operation(harness)
        } catch {
            harness.cleanup()
            throw error
        }
        harness.cleanup()
    }
}

@MainActor
private final class ChatViewScrollHarness {
    let snapshot: SessionSnapshot
    let transcriptIDs: Set<String>
    let firstTranscriptID: String
    let lastTranscriptID: String
    let recorder: PresentedFrameRecorder

    private let suiteName: String
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let window: UIWindow
    private let hostingController: UIHostingController<AnyView>

    init(seed: Int) throws {
        snapshot = try SessionScenarioBuilder(seed: seed).openingTail(targetEncodedBytes: 10_000)
        transcriptIDs = Set(snapshot.transcript.map(\.id))
        firstTranscriptID = try Self.require(snapshot.transcript.first?.id)
        lastTranscriptID = try Self.require(snapshot.transcript.last?.id)

        suiteName = "ChatViewScrollHarnessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let model = AppModel(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot)
        )
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == nil else {
            throw HarnessError.invalidAuthorityBoundary
        }
        model.installHostedAuthoritativeSnapshot(snapshot)
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot else {
            throw HarnessError.invalidAuthorityBoundary
        }

        let probe = ChatHostedProbe()
        let sessionID = snapshot.sessionId
        let root = AnyView(
            NavigationStack {
                ChatView(sessionID: sessionID, hostedProbe: probe)
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

        recorder = PresentedFrameRecorder(probe: probe)
        recorder.start()
    }

    func containsNativeTranscriptScrollView(matching geometry: ChatTranscriptGeometry) -> Bool {
        Self.scrollViews(in: hostingController.view).contains { scrollView in
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
private final class PresentedFrameRecorder: NSObject {
    struct Sample: Sendable {
        let frameIndex: Int
        let observation: ChatHostedObservation
    }

    private struct Waiter {
        let id: Int
        let predicate: @MainActor (Sample) -> Bool
        let continuation: CheckedContinuation<Sample, Error>
    }

    private let probe: ChatHostedProbe
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var lastRevision = -1
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private(set) var samples: [Sample] = []

    init(probe: ChatHostedProbe) {
        self.probe = probe
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
        let sample = Sample(frameIndex: frameIndex, observation: observation)
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

private enum HarnessError: Error {
    case invalidAuthorityBoundary
    case missingTranscript
    case missingWindowScene
}
