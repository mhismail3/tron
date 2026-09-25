import SwiftUI
import Testing
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

    @Test("keyboard, skill and photo chips share the same animated placement boundary")
    func keyboardAndAccessories() async throws {
        try await withHarness { harness in
            let initial = try await layout(harness)
            initial.marker.move?(.bottomTrailing)
            try await settle()
            let docked = try #require(harness.floatingLayout())
            try harness.focusComposer(true)
            for _ in 0..<90 {
                try await DisplayFrameScheduler.displayLink.nextFrame()
                let frame = try #require(harness.floatingLayout(), "Keyboard movement must retain the window")
                #expect(frame.marker === initial.marker)
                #expect(frame.frame.minY >= frame.toolbarBottom + 7)
                #expect(frame.frame.maxY <= frame.composer.minY - 7)
            }
            let keyboard = try #require(harness.floatingLayout(), "The native keyboard must not remove the panel")
            #expect(keyboard.marker === initial.marker)
            #expect(keyboard.composer.minY < docked.composer.minY - 100, "Require a genuine keyboard-driven inset, not a synthetic notification")
            #expect(abs(keyboard.composer.minY - keyboard.frame.maxY - 8) <= 2)
            try harness.setComposerAccessories(true)
            var frames: [ChatViewScrollHarness.FloatingLayout] = []
            for _ in 0..<90 {
                try await DisplayFrameScheduler.displayLink.nextFrame()
                if let frame = harness.floatingLayout() { frames.append(frame) }
            }
            let chips = try #require(frames.last)
            #expect(chips.composer.height > keyboard.composer.height + 50)
            #expect(chips.marker === initial.marker)
            for frame in frames {
                #expect(frame.frame.minY >= frame.toolbarBottom + 7)
                #expect(frame.frame.maxY <= frame.composer.minY - 7)
            }
            #expect(frames.contains { $0.frame.maxY < keyboard.frame.maxY - 2 && $0.frame.maxY > chips.frame.maxY + 2 }, "The panel must follow intermediate accessory animation frames")
            try harness.setComposerDraftText(String(repeating: "Type into the taller composer. ", count: 12))
            try await settle()
            let tall = try #require(harness.floatingLayout())
            #expect(tall.marker === initial.marker)
            #expect(tall.frame.minY >= tall.toolbarBottom + 7)
            #expect(abs(tall.composer.minY - tall.frame.maxY - 8) <= 2)
            #expect(tall.frame.height < keyboard.frame.height)
            try harness.setComposerDraftText("")
            try harness.setComposerAccessories(false)
            try harness.focusComposer(false)
            try await settle()
            let restored = try #require(harness.floatingLayout())
            #expect(restored.marker === initial.marker)
            #expect(abs(restored.composer.minY - restored.frame.maxY - 8) <= 2)
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
                try await settle()
                return try #require(harness.floatingLayout())
            }
            try await DisplayFrameScheduler.displayLink.nextFrame()
        }
        throw HarnessError.missingTranscript
    }

    private func settle() async throws {
        // Bounded display boundaries, not proof of touch gesture delivery.
        for _ in 0..<90 { try await DisplayFrameScheduler.displayLink.nextFrame() }
    }
}
