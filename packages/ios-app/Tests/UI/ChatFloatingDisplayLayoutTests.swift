import SwiftUI
import Testing
@testable import TronMobileCore
import UIKit
@testable import TronMobile

@MainActor
@Suite("Mounted floating chat layout", .serialized)
struct ChatFloatingDisplayLayoutTests {
    @Test("floating panel reaches the native toolbar and complete composer")
    func fullChatReachability() async throws {
        try await withHarness { harness in
            let initial = try await layout(harness)
            initial.marker.move?(.topLeading)
            try await settle()
            let top = try #require(harness.floatingLayout())
            print("Floating top: \(top.frame), toolbar bottom: \(top.toolbarBottom), composer: \(top.composer)")
            #expect(abs(top.frame.minY - top.toolbarBottom - 8) <= 2)
            #expect(abs(top.frame.minX - 8) <= 2)
            top.marker.move?(.bottomTrailing)
            try await settle()
            let bottom = try #require(harness.floatingLayout())
            print("Floating bottom: \(bottom.frame), composer: \(bottom.composer)")
            #expect(abs(bottom.composer.minY - bottom.frame.maxY - 8) <= 2)
            #expect(bottom.marker === initial.marker)
        }
    }

    /// Failure modes: the floating panel leaves the band between the toolbar
    /// and the composer (or is remounted) on some frame while the keyboard,
    /// accessory chips or a taller draft move the composer; or it jumps to the
    /// accessories' final placement instead of following their animation.
    /// Every phase waits for its own settled layout, bounded in display frames:
    /// fixed 90-frame waits cost more wall time than the watchdog allowed on a
    /// slow runner.
    @Test("keyboard, skill and photo chips share the same animated placement boundary")
    func keyboardAndAccessories() async throws {
        try await withHarness { harness in
            let initial = try await layout(harness)
            func withinBand(_ frame: ChatViewScrollHarness.FloatingLayout) {
                #expect(frame.marker === initial.marker)
                #expect(frame.frame.minY >= frame.toolbarBottom + 7)
                #expect(frame.frame.maxY <= frame.composer.minY - 7)
            }
            func dockedAboveComposer(_ frame: ChatViewScrollHarness.FloatingLayout) -> Bool {
                abs(frame.composer.minY - frame.frame.maxY - 8) <= 2
            }
            initial.marker.move?(.bottomTrailing)
            let docked = try await settleLayout(harness, until: dockedAboveComposer).final
            try harness.focusComposer(true)
            let keyboard = try await settleLayout(harness, each: withinBand) {
                // A genuine keyboard-driven inset, not a synthetic notification.
                $0.composer.minY < docked.composer.minY - 100
            }.final
            #expect(keyboard.marker === initial.marker, "The native keyboard must not remove the panel")
            #expect(dockedAboveComposer(keyboard))
            try harness.setComposerAccessories(true)
            let (chips, frames) = try await settleLayout(harness, each: withinBand) {
                $0.composer.height > keyboard.composer.height + 50
            }
            #expect(frames.contains { $0.frame.maxY < keyboard.frame.maxY - 2 && $0.frame.maxY > chips.frame.maxY + 2 }, "The panel must follow intermediate accessory animation frames")
            try harness.setComposerDraftText(String(repeating: "Type into the taller composer. ", count: 12))
            let tall = try await settleLayout(harness) { $0.composer.height > chips.composer.height }.final
            #expect(tall.marker === initial.marker)
            #expect(tall.frame.minY >= tall.toolbarBottom + 7)
            #expect(dockedAboveComposer(tall))
            #expect(tall.frame.height < keyboard.frame.height)
            try harness.setComposerDraftText("")
            try harness.setComposerAccessories(false)
            try harness.focusComposer(false)
            let restored = try await settleLayout(harness) { $0.composer.minY >= docked.composer.minY - 2 }.final
            #expect(restored.marker === initial.marker)
            #expect(dockedAboveComposer(restored))
        }
    }

    @Test("drag release settles from the last presented finger position without an origin frame")
    func dragReleaseContinuity() async throws {
        try await withHarness { harness in
            let initial = try await layout(harness)
            let grab = CGPoint(x: 30, y: 30)
            let start = CGPoint(x: initial.frame.minX + grab.x,
                                y: initial.frame.minY - initial.toolbarBottom + grab.y)
            initial.marker.pan?(.init(state: .began, location: start, locationInWindow: grab, velocity: .zero))
            for step in 1...12 {
                let delta = CGSize(width: -35 * CGFloat(step) / 12, height: 260 * CGFloat(step) / 12)
                initial.marker.pan?(.init(state: .changed,
                    location: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
                    locationInWindow: grab, velocity: .zero))
                try await DisplayFrameScheduler.displayLink.nextFrame()
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let frame = try #require(harness.floatingLayout())
                #expect(frame.marker === initial.marker)
                #expect(abs(frame.frame.minX - initial.frame.minX - delta.width) <= 2)
                #expect(abs(frame.frame.minY - initial.frame.minY - delta.height) <= 2)
            }
            let released = try #require(harness.floatingLayout())
            initial.marker.pan?(.init(state: .ended,
                location: CGPoint(x: start.x - 35, y: start.y + 260),
                locationInWindow: grab, velocity: CGPoint(x: -300, y: 120)))
            var settling: [CGRect] = []
            for _ in 0..<90 {
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let frame = try #require(harness.floatingLayout())
                #expect(frame.marker === initial.marker)
                settling.append(frame.frame)
            }
            // The projected path heads left/down. Even its first frame must
            // never return towards the original top-right placement.
            #expect(settling.allSatisfy { $0.minY >= released.frame.minY - 2 })
            #expect(settling.allSatisfy { $0.minX <= released.frame.minX + 2 && $0.minX >= 7 })
            #expect(settling.contains { $0.minX > 10 && $0.minX < released.frame.minX - 2 }, "Observe intermediate docking, not just its destination")
            let final = try #require(settling.last)
            #expect(abs(final.minX - 8) <= 2)
            #expect(final.minY >= released.frame.minY && final.minY <= released.frame.minY + 35)
            print("Drag release native frames: released=\(released.frame), first=\(settling.first!), last=\(final)")
            // Negative outcome control, not a platform-touch simulation: force
            // an old-origin publication through the same mounted position owner
            // and require the exact continuity oracle to reject its native frame.
            initial.marker.pan?(.init(state: .began, location: start, locationInWindow: grab, velocity: .zero))
            try await DisplayFrameScheduler.displayLink.nextFrame()
            try await DisplayFrameScheduler.displayLink.nextFrame()
            let reset = try #require(harness.floatingLayout())
            #expect(![reset.frame].allSatisfy { $0.minY >= released.frame.minY - 2 })
            initial.marker.pan?(.init(state: .cancelled, location: .zero, locationInWindow: grab, velocity: .zero))
        }
    }

    @Test("an interrupted dock grabs its visible location and cancellation still settles once")
    func interruptedDockAndCancellation() async throws {
        try await withHarness { harness in
            let initial = try await layout(harness)
            let grab = CGPoint(x: 30, y: 30)
            let start = CGPoint(x: initial.frame.minX + grab.x, y: initial.frame.minY - initial.toolbarBottom + grab.y)
            initial.marker.pan?(.init(state: .began, location: start, locationInWindow: grab, velocity: .zero))
            initial.marker.pan?(.init(state: .changed, location: CGPoint(x: start.x - 35, y: start.y + 230), locationInWindow: grab, velocity: .zero))
            try await DisplayFrameScheduler.displayLink.nextFrame()
            try await DisplayFrameScheduler.displayLink.nextFrame()
            initial.marker.pan?(.init(state: .ended, location: .zero, locationInWindow: grab, velocity: CGPoint(x: -900, y: 600)))
            try await DisplayFrameScheduler.displayLink.nextFrame()
            try await DisplayFrameScheduler.displayLink.nextFrame()
            let moving = try #require(harness.floatingLayout())
            let pointer = CGPoint(x: moving.frame.minX + grab.x, y: moving.frame.minY - moving.toolbarBottom + grab.y)
            moving.marker.pan?(.init(state: .began, location: pointer, locationInWindow: grab, velocity: .zero))
            try await DisplayFrameScheduler.displayLink.nextFrame()
            try await DisplayFrameScheduler.displayLink.nextFrame()
            let grabbed = try #require(harness.floatingLayout())
            #expect(abs(grabbed.frame.minX - moving.frame.minX) <= 2)
            #expect(abs(grabbed.frame.minY - moving.frame.minY) <= 2)
            moving.marker.pan?(.init(state: .changed, location: CGPoint(x: pointer.x + 10, y: pointer.y + 40), locationInWindow: grab, velocity: .zero))
            try await DisplayFrameScheduler.displayLink.nextFrame()
            try await DisplayFrameScheduler.displayLink.nextFrame()
            let cancelled = try #require(harness.floatingLayout())
            moving.marker.pan?(.init(state: .cancelled, location: .zero, locationInWindow: grab, velocity: CGPoint(x: -900, y: -900)))
            // A second terminal callback must not apply momentum after cancel.
            moving.marker.pan?(.init(state: .ended, location: .zero, locationInWindow: grab, velocity: CGPoint(x: -900, y: -900)))
            for _ in 0..<90 {
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let frame = try #require(harness.floatingLayout())
                #expect(frame.marker === initial.marker)
                #expect(abs(frame.frame.minY - cancelled.frame.minY) <= 2)
            }
            let final = try #require(harness.floatingLayout())
            #expect(abs(final.frame.maxX - 382) <= 2 || abs(final.frame.minX - 8) <= 2)
        }
    }

    private func withHarness(operation: @escaping @MainActor @Sendable (ChatViewScrollHarness) async throws -> Void) async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let builder = SessionScenarioBuilder(seed: 1_360)
            let snapshot = try builder.openingTail(targetEncodedBytes: 10_000)
            let harness = try await ChatViewScrollHarness.composerSubmissionHarness(snapshot: snapshot, displayFrameScheduler: .displayLink)
            do {
                _ = try await harness.recorder.waitUntil { $0.observation.isReady }
                let display = DisplayProjection(
                    displayId: "floating-layout", title: "Browser", altText: "Live browser viewport", kind: .browserLive,
                    presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet),
                    eligibleSurfaces: [.sheet, .floating], fallbackText: "The original browser is no longer available.",
                    liveView: .init(schema: "tron.browser-live-view.v1", viewId: "view-layout", generation: "generation-layout", title: "Browser", fallbackText: "Unavailable")
                )
                harness.probe.presentDisplay(.showFloating(.init(sessionID: snapshot.sessionId, display: display)))
                try await operation(harness)
            } catch { await harness.close(); throw error }
            await harness.close()
        }
    }

    private func layout(_ harness: ChatViewScrollHarness) async throws -> ChatViewScrollHarness.FloatingLayout {
        for _ in 0..<120 {
            if harness.floatingLayout() != nil {
                return try await settleLayout(harness) { _ in true }.final
            }
            try await DisplayFrameScheduler.displayLink.nextFrame()
        }
        throw HarnessError.missingTranscript
    }

    /// Display frames until `condition` holds on a layout that stayed identical
    /// for three consecutive frames, with `each` checking every frame on the
    /// way. The bound is a display-frame budget, so a slower machine spends
    /// fewer frames per animation instead of running out of wall time.
    private func settleLayout(
        _ harness: ChatViewScrollHarness,
        frameBudget: Int = 240,
        each check: (ChatViewScrollHarness.FloatingLayout) -> Void = { _ in },
        until condition: (ChatViewScrollHarness.FloatingLayout) -> Bool
    ) async throws -> (final: ChatViewScrollHarness.FloatingLayout, frames: [ChatViewScrollHarness.FloatingLayout]) {
        var frames: [ChatViewScrollHarness.FloatingLayout] = []
        var unchanged = 0
        for _ in 0..<frameBudget {
            try await DisplayFrameScheduler.displayLink.nextFrame()
            let frame = try #require(harness.floatingLayout(), "The panel must stay mounted")
            check(frame)
            if let previous = frames.last, previous.marker === frame.marker, previous.frame == frame.frame,
               previous.composer == frame.composer, previous.toolbarBottom == frame.toolbarBottom {
                unchanged += 1
            } else {
                unchanged = 0
            }
            frames.append(frame)
            if unchanged >= 2, condition(frame) { return (frame, frames) }
        }
        throw FloatingLayoutDidNotSettle(frameBudget: frameBudget, last: frames.last)
    }

    private func settle() async throws {
        // Bounded display boundaries, not proof of touch gesture delivery.
        for _ in 0..<90 { try await DisplayFrameScheduler.displayLink.nextFrame() }
    }
}

private struct FloatingLayoutDidNotSettle: Error, CustomStringConvertible {
    let frameBudget: Int
    let last: ChatViewScrollHarness.FloatingLayout?

    var description: String {
        "The floating layout did not settle within \(frameBudget) display frames; last panel "
            + "\(String(describing: last?.frame)), composer \(String(describing: last?.composer))"
    }
}
