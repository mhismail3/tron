import SwiftUI
@testable import TronMobileCore
import UIKit
@testable import TronMobile

@MainActor
final class ChatViewScrollHarness {
    let lastTranscriptID: String
    let recorder: PresentedFrameRecorder
    private let probe: ChatHostedProbe
    private let suiteName: String
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let window: UIWindow
    private let hostingController: UIHostingController<AnyView>

    init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: any PerformanceSignposting
    ) throws {
        let suiteName = "ChatViewScrollHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        let model = AppModel(
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot),
            composerDraftStore: ComposerDraftStore(root: cacheRoot.appending(path: "drafts"))
        )
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == nil else {
            throw HarnessError.invalidAuthorityBoundary
        }
        model.invalidateHostedPendingPresentation()
        model.installHostedSubscribedSnapshot(snapshot, token: "hosted-session-token")
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot else {
            throw HarnessError.invalidAuthorityBoundary
        }

        let probe = ChatHostedProbe()
        probe.fixtureOpenPresentation = { [model] in
            guard let target = model.presentationTarget(for: snapshot.sessionId),
                  model.hasMountedSessionAuthority(target) else { throw CancellationError() }
            return target.generation
        }
        self.probe = probe
        let sessionID = snapshot.sessionId
        let root = AnyView(
            NavigationStack {
                ChatView(
                    sessionID: sessionID,
                    hostedProbe: probe,
                    displayFrameScheduler: displayFrameScheduler,
                    performanceSignposts: performanceSignposts,
                    transcriptOrientation: .newestAtOrigin
                )
            }
            .environment(model)
            .environment(\.hostedToolActionProbe, HostedToolActionProbe())
            .environment(\._accessibilityReduceMotion, false)
        )
        hostingController = UIHostingController(rootView: AnyView(root.environment(\.scenePhase, .active)))
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
        recorder = PresentedFrameRecorder(
            probe: probe,
            windowState: { TranscriptWindowOracle.state(in: hostedView) }
        )
        recorder.start()
        self.suiteName = suiteName
        self.defaults = defaults
        self.cacheRoot = cacheRoot
        lastTranscriptID = snapshot.transcript.last?.id ?? "transcript-bottom"
    }

    func cleanup() {
        probe.retirePresentation()
        recorder.stop()
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}

enum TranscriptWindowOracle {
    static let tailSpacing = ChatTranscriptLayoutConstants.tailAffordanceHeight
    static let bottomBandHeight = tailSpacing + 24
    static let profilingTolerance: CGFloat = 24
    static let pinnedTolerance: CGFloat = 6

    struct Row: Sendable, Equatable {
        let windowFrame: CGRect
        let isInBottomBand: Bool
    }

    struct Bottom: Sendable, Equatable {
        let composerTop: CGFloat?
        let newestRowBottomEdge: CGFloat?
        let visibleRowFraction: CGFloat
        let isBandCovered: Bool
        let pinnedError: CGFloat?

        var clearance: CGFloat? {
            guard let composerTop, let newestRowBottomEdge else { return nil }
            return composerTop - newestRowBottomEdge
        }
    }

    struct State: Sendable, Equatable {
        let rows: [Row]
        let bottom: Bottom
        let contentHeight: CGFloat?
    }

    static func bottom(in root: UIView) -> Bottom { state(in: root).bottom }

    static func isPinned(in root: UIView, tolerance: CGFloat) -> Bool {
        guard let pinnedError = bottom(in: root).pinnedError else { return false }
        return abs(pinnedError) <= tolerance
    }

    static func state(in root: UIView) -> State {
        guard let window = root.window, let scroll = transcriptScrollView(in: root) else {
            return State(rows: [], bottom: emptyBottom, contentHeight: nil)
        }
        let windowLayer = window.layer
        let composerTop = markers(in: root)
            .first { $0.physicalID == ChatHostedNativeRowProbe.composerID }
            .map { $0.layer.convert($0.bounds, to: windowLayer).standardized.minY }
        var visible = scroll.layer.convert(scroll.bounds, to: windowLayer).standardized
            .intersection(window.bounds)
        if let composerTop, composerTop > visible.minY {
            visible = visible.intersection(CGRect(
                x: visible.minX, y: visible.minY,
                width: visible.width, height: composerTop - visible.minY
            ))
        }
        let band = composerTop.map { top in
            CGRect(
                x: visible.minX, y: top - bottomBandHeight,
                width: visible.width, height: bottomBandHeight
            )
        }
        let hasVisibleArea = !visible.isNull && visible.height > 0
        var rows: [Row] = []
        var coveredHeight: CGFloat = 0
        for marker in markers(in: scroll) where marker.window == window && !marker.isHidden {
            let frame = marker.layer.convert(marker.bounds, to: windowLayer).standardized
            guard frame.height > 0 else { continue }
            if hasVisibleArea, frame.intersects(visible) {
                coveredHeight += frame.intersection(visible).height
            }
            rows.append(Row(
                windowFrame: frame,
                isInBottomBand: band.map { frame.intersects($0) } ?? false
            ))
        }
        let newestRowBottomEdge = rows.map(\.windowFrame.maxY).max()
        let clearance = composerTop.flatMap { top in
            newestRowBottomEdge.map { top - $0 }
        }
        let bottom = Bottom(
            composerTop: composerTop,
            newestRowBottomEdge: newestRowBottomEdge,
            visibleRowFraction: hasVisibleArea
                ? min(1, max(0, coveredHeight / visible.height)) : 0,
            isBandCovered: rows.contains { $0.isInBottomBand },
            pinnedError: clearance.map(Self.pinnedError(forClearance:))
        )
        return State(rows: rows, bottom: bottom, contentHeight: scroll.contentSize.height)
    }

    static func transcriptScrollView(in root: UIView) -> UIScrollView? {
        scrollViews(in: root).filter { !($0 is UITextView) }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
    }

    private static func pinnedError(forClearance clearance: CGFloat) -> CGFloat {
        if clearance > tailSpacing + pinnedTolerance {
            return (tailSpacing + pinnedTolerance) - clearance
        }
        if clearance < -pinnedTolerance { return -pinnedTolerance - clearance }
        return 0
    }

    private static let emptyBottom = Bottom(
        composerTop: nil,
        newestRowBottomEdge: nil,
        visibleRowFraction: 0,
        isBandCovered: false,
        pinnedError: nil
    )

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }

    private static func markers(in view: UIView) -> [ChatHostedNativeRowMarker] {
        (view as? ChatHostedNativeRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }
}

@MainActor
final class PresentedFrameRecorder: NSObject {
    private static let retainedSampleLimit = 256

    private let probe: ChatHostedProbe
    private let windowState: @MainActor () -> TranscriptWindowOracle.State
    private var lastWindowState: TranscriptWindowOracle.State?
    private var displayLink: CADisplayLink?
    private var lastRevision = -1
    private(set) var samples: [ChatHostedObservation] = []

    init(
        probe: ChatHostedProbe,
        windowState: @escaping @MainActor () -> TranscriptWindowOracle.State
    ) {
        self.probe = probe
        self.windowState = windowState
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
    }

    @objc private func displayFrame() {
        let observation = probe.observation
        let state = windowState()
        guard observation.revision != lastRevision || state != lastWindowState else { return }
        lastRevision = observation.revision
        lastWindowState = state
        samples.append(observation)
        if samples.count > Self.retainedSampleLimit {
            samples.removeFirst(samples.count - Self.retainedSampleLimit)
        }
    }
}

enum HarnessError: Error {
    case invalidAuthorityBoundary
    case missingWindowScene
}
