import SwiftUI
@testable import TronMobileCore
import XCTest
@testable import TronMobile

/// Continuous indicators must keep drawing new frames while every gate is open
/// and hold one frame while a gate is closed. Pixel tests at fixed timestamps
/// cannot see a frozen animation: an indicator whose TimelineView ticks but
/// whose Canvas is never asked to redraw renders a correct first frame forever.
/// Failure modes guarded here:
/// - a restructured Canvas drawing stops being re-run per tick although its
///   TimelineView still ticks (observed when the pulse resolved its accent
///   once per frame), freezing the indicator on a correct-looking frame;
/// - an indicator mounted inside production chrome (dashboard row, compact
///   pill) is frozen by its container although it animates alone;
/// - Reduce Motion, an inactive scene, a covered surface or a hidden orb keeps
///   animating instead of holding its static frame.
@MainActor
final class ContinuousIndicatorLivenessTests: XCTestCase {
    private static let frameCount = 8
    private static let frameInterval: Duration = .milliseconds(40)
    /// A frozen indicator yields one distinct frame. The loading line's sine
    /// opacity barely moves near its peaks, so neighbouring frames there can
    /// quantize to the same pixels; it needs fewer distinct frames.
    private static let minimumDistinctAnimatedFrames = 6
    private static let minimumDistinctLoadingLineFrames = 3

    func testIndicatorsKeepDrawingNewFramesWhileGatesAreOpen() async throws {
        let canvasCases: [(String, AnyView)] = [
            ("pulse", AnyView(TronPulseLoadingIndicator(accent: .tronEmerald, size: 44))),
            ("pulse, settings theme", AnyView(
                TronPulseLoadingIndicator(size: 44).tronSettingsVisualTheme(accent: .tronBlue)
            )),
            ("pulse in compact pill icon", AnyView(
                ChatCompactPillLeadingIcon(icon: "terminal", accent: .tronAccentText, showsProgress: true)
                    .scaleEffect(3)
            )),
            ("pulse in active dashboard row", AnyView(
                HistoricalSessionRow(session: Self.session, activity: .active, showsContext: true)
            )),
            ("orb in subagent dashboard row", AnyView(
                HistoricalSessionRow(session: Self.session, activity: .subagentsWorking, showsContext: true)
            )),
            ("orb solving", AnyView(ProcessActivityOrb(mode: .solving, size: 60))),
            ("orb thinking", AnyView(ProcessActivityOrb(mode: .thinking, size: 60, accent: .tronSubagent))),
        ]
        let cases = canvasCases.map { ($0.0, $0.1, Self.minimumDistinctAnimatedFrames) }
            + [("provider usage loading line", AnyView(ProviderUsageLoadingLine()),
                Self.minimumDistinctLoadingLineFrames)]
        for (name, view, minimum) in cases {
            let frames = try await capturedFrames(of: view)
            print("indicator liveness: \(name): \(Set(frames).count) distinct of \(frames.count)")
            XCTAssertGreaterThanOrEqual(Set(frames).count, minimum, "\(name) must keep animating with every gate open")
            if Set(frames).count < minimum { attach(frames, name: name) }
        }
    }

    func testIndicatorsHoldOneFrameWhileAGateIsClosed() async throws {
        let cases: [(String, AnyView)] = [
            ("pulse, Reduce Motion", AnyView(
                TronPulseLoadingIndicator(size: 44).environment(\._accessibilityReduceMotion, true)
            )),
            ("pulse, inactive scene", AnyView(
                TronPulseLoadingIndicator(size: 44).environment(\.scenePhase, .inactive)
            )),
            ("pulse, covered surface", AnyView(
                TronPulseLoadingIndicator(size: 44).environment(\.tronPresentationActivity, .covered)
            )),
            ("active dashboard row, covered surface", AnyView(
                HistoricalSessionRow(session: Self.session, activity: .active, showsContext: true)
                    .environment(\.tronPresentationActivity, .covered)
            )),
            ("orb, Reduce Motion", AnyView(
                ProcessActivityOrb(mode: .solving, size: 60).environment(\._accessibilityReduceMotion, true)
            )),
            ("orb, hidden", AnyView(ProcessActivityOrb(mode: .thinking, size: 60, isVisible: false))),
            ("provider usage loading line, Reduce Motion", AnyView(
                ProviderUsageLoadingLine().environment(\._accessibilityReduceMotion, true)
            )),
        ]
        let blank = try await capturedFrames(of: AnyView(Color.clear), count: 1)
        for (name, view) in cases {
            let frames = try await capturedFrames(of: view)
            print("indicator liveness: \(name): \(Set(frames).count) distinct of \(frames.count)")
            XCTAssertEqual(Set(frames).count, 1, "\(name) must hold a static frame")
            if Set(frames).count != 1 { attach(frames, name: name) }
            XCTAssertNotEqual(frames.first, blank.first, "\(name) must still draw its static frame")
        }
    }

    /// Keeps the captured sequence of a failing case in the xcresult.
    private func attach(_ frames: [Data], name: String) {
        for (index, frame) in frames.enumerated() {
            let attachment = XCTAttachment(data: frame, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name) frame \(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private static let session = SessionSummary(
        id: "liveness-session", name: "Review the project", cwd: "/workspace/project", parentSessionId: nil,
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
        messageCount: 1, firstMessage: "Example conversation", phase: .idle, summaryRevision: 1
    )

    /// Mounts `content` in a hosted window with the production gates open
    /// (active scene and surface, visible, Reduce Motion from the simulator,
    /// which is off) and captures committed frames at a fixed interval.
    private func capturedFrames(of content: AnyView, count: Int = frameCount) async throws -> [Data] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content
            .frame(width: 360, height: 180)
            // A hosted fixture has no SwiftUI Scene; provide the scene input.
            // Closed-gate cases override it closer to the indicator.
            .environment(\.scenePhase, .active)
            .tronPresentation())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 180)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        // Appearance, visibility gating, glass settling and the first timeline
        // tick; no model I/O.
        try await Task.sleep(for: .milliseconds(800))
        func capture() throws -> Data {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try XCTUnwrap(image.pngData())
        }
        // The first snapshot of glass chrome differs by one channel step at its
        // shadow edge from every later one, animation or not; discard it.
        _ = try capture()
        var frames: [Data] = []
        for index in 0..<count {
            try await Task.sleep(for: index == 0 ? .milliseconds(100) : Self.frameInterval)
            frames.append(try capture())
        }
        return frames
    }
}
