import SwiftUI
@testable import TronMobileCore
import UIKit
@testable import TronMobile

/// A real `ChatView` mounted in a hosted window over a memory-only session, for
/// the pinned performance baseline. The recorder samples the chat's own probe
/// and window geometry at each display frame.
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
        // Hosted presentation generations are authoritative and need not match
        // ChatOpenPresentationState's local opening epoch.
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

/// The transcript's bottom, measured in window coordinates: the one oracle for
/// "is the newest row where the pinned tail puts it?".
///
/// Window coordinates carry what the reader sees, so every quantity here means
/// the same thing whichever way the transcript's scroll view is oriented. The
/// rects come from the layer chain (`CALayer.convert`), not `UIView.convert`:
/// SwiftUI applies its own transforms on layers, which `UIView.convert` does not
/// walk.
enum TranscriptWindowOracle {
    /// The tail spacing a pinned transcript keeps between its newest row and the
    /// composer.
    static let tailSpacing = ChatTranscriptLayoutConstants.tailAffordanceHeight
    /// The band above the composer a pinned transcript keeps covered: the tail
    /// spacing plus 24 pt of the newest row.
    static let bottomBandHeight = tailSpacing + 24
    /// The tolerance the profiling scenarios allow a measured window's pinned
    /// bottom: the window ends while the transcript may still be settling.
    static let profilingTolerance: CGFloat = 24
    /// How far the newest row's rendered bottom edge may sit outside the pinned
    /// band and still count as pinned. The edge is read from the render tree, so
    /// it carries a row's own animated transforms: the queued card's 80 → 44 pt
    /// shrink measured 4.1-13.5 pt excursions below the band, while a detached
    /// reader or a blank is tens or hundreds of points away.
    static let pinnedTolerance: CGFloat = 6

    /// One mounted transcript row, in window coordinates.
    struct Row: Sendable, Equatable {
        /// The row marker's frame in window coordinates.
        let windowFrame: CGRect
        /// Whether the row intersects the pinned bottom band.
        let isInBottomBand: Bool
    }

    /// The transcript's bottom in window coordinates.
    struct Bottom: Sendable, Equatable {
        /// The composer marker's top edge.
        let composerTop: CGFloat?
        /// The bottom edge of the bottom-most mounted row, which is the newest row
        /// when the origin-anchored viewport is pinned.
        let newestRowBottomEdge: CGFloat?
        /// The fraction of the visible transcript rect that mounted rows cover.
        let visibleRowFraction: CGFloat
        /// Whether any mounted row intersects the bottom band.
        let isBandCovered: Bool
        /// The visual distance of the bottom-most row's bottom edge from the
        /// pinned band, signed: `0` anywhere inside the band, negative when the
        /// row rests above it (a detached reader, or a blank) and positive when
        /// it runs under it below the composer.
        let pinnedError: CGFloat?

        /// The visual gap between the bottom-most row's bottom edge and the
        /// composer's top edge.
        var clearance: CGFloat? {
            guard let composerTop, let newestRowBottomEdge else { return nil }
            return composerTop - newestRowBottomEdge
        }
    }

    /// Every mounted transcript row and the transcript's bottom, from one walk
    /// of the live hierarchy.
    struct State: Sendable, Equatable {
        let rows: [Row]
        let bottom: Bottom
        /// The transcript scroll view's own content height, which a sample's
        /// identity includes so a lazy-stack re-estimate is a new sample.
        let contentHeight: CGFloat?
    }

    static func bottom(in root: UIView) -> Bottom { state(in: root).bottom }

    /// Whether the newest row's bottom edge sits within `tolerance` points of
    /// the pinned band: the decision the profiling scenarios make about a
    /// measured window, which ends while the transcript may still be settling.
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
        // The composer is subtracted from the window rect rather than read from
        // `adjustedContentInset`, which a flipped scroll view would apply at the
        // other edge.
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

    /// This fixed-window harness has one full-size transcript viewport. Its
    /// identity cannot depend on overflowing content or a lazy child being
    /// mounted at the instant an entrance or compaction is sampled.
    static func transcriptScrollView(in root: UIView) -> UIScrollView? {
        scrollViews(in: root).filter { !($0 is UITextView) }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
    }

    /// The signed distance of a newest-row clearance from the pinned band: `0`
    /// inside it, negative above it, positive below it.
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

/// Samples the probe's observation at each display frame that changed it or the
/// transcript's window geometry, keeping the newest samples only.
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
