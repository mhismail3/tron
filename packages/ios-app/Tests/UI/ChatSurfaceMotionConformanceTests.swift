import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import TronMobileCore
@testable import TronMobile

@MainActor
@Suite("Chat surface motion conformance", .serialized, .enabled(if: UIValidationTier.isActive))
struct ChatSurfaceMotionConformanceTests {
    @Test("composer attachment strip insertion and removal spread inset changes across bounded frames")
    func composerAccessoryInsetMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_770).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<24 { try await harness.driveFrameBoundary() }
            let previousAnimationScale = ChatMotion.hostedTestAnimationScale
            ChatMotion.hostedTestAnimationScale = ChatMotionPixelSupport.animationScale
            defer { ChatMotion.hostedTestAnimationScale = previousAnimationScale }
            let insertion = try await recordComposerInsetChange(harness, accessoryEnabled: true)
            let removal = try await recordComposerInsetChange(harness, accessoryEnabled: false)
            #expect(insertion.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(removal.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(insertion.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect(removal.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect((insertion.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            #expect((removal.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([insertion, removal])
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("attachment chip insertion and removal animate the chip and preserve the pinned tail")
    func attachmentChipMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_772).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<24 { try await harness.driveFrameBoundary() }
            let previousAnimationScale = ChatMotion.hostedTestAnimationScale
            ChatMotion.hostedTestAnimationScale = ChatMotionPixelSupport.animationScale
            defer { ChatMotion.hostedTestAnimationScale = previousAnimationScale }
            let insertion = try await recordAttachmentChipChange(harness, attached: true)
            #expect(insertion.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            expectSurfaceAnimationFrames(insertion)
            #expect((insertion.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            let removal = try await recordAttachmentChipChange(harness, attached: false)
            #expect(removal.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            expectSurfaceAnimationFrames(removal)
            #expect((removal.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([insertion, removal], named: "attachment-chip-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("composer stop-to-send mode change remains bounded and visibly animated")
    func composerTrailingModeMotion() async throws {
        let builder = SessionScenarioBuilder(seed: 2_776)
        var snapshot = try builder.openingTail(targetEncodedBytes: 10_000)
        snapshot.phase = .running
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<24 { try await harness.driveFrameBoundary() }
            let marker = try #require(harness.composerTrailingMotionMarker)
            #expect(marker.mode == .stopAgent)
            var previousFrame = try #require(harness.composerTrailingMotionFrame)
            var previousImage = try ChatMotionPixelSupport.captureWindow(harness: harness)
            try harness.setComposerDraftText("Send control motion")

            var maximumStep: CGFloat = 0
            var maximumTail: CGFloat = 0
            var pixelChangingFrames = 0
            var identities: Set<ObjectIdentifier> = []
            var samples: [Double] = []
            for _ in 0..<24 {
                try await harness.driveFrameBoundary()
                let frame = try #require(harness.composerTrailingMotionFrame)
                let image = try ChatMotionPixelSupport.captureWindow(harness: harness)
                if ChatMotionPixelSupport.changedPixels(previousImage, image, in: frame) {
                    pixelChangingFrames += 1
                }
                let step = max(
                    max(abs(frame.minX - previousFrame.minX), abs(frame.minY - previousFrame.minY)),
                    max(abs(frame.width - previousFrame.width), abs(frame.height - previousFrame.height))
                )
                maximumStep = max(maximumStep, step)
                maximumTail = max(maximumTail, abs(harness.probeObservation.geometry.distanceFromBottom))
                identities.insert(ObjectIdentifier(try #require(harness.composerTrailingMotionMarker)))
                samples.append(contentsOf: [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)])
                previousFrame = frame
                previousImage = image
            }
            #expect(harness.composerTrailingMotionMarker?.mode == .send)
            #expect(maximumStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(pixelChangingFrames >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
            #expect(identities.count == 1)
            #expect(maximumTail <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([ChatMotionSurfaceMetrics(
                name: "composer-stop-to-send-mode",
                hostedMarkerID: "composer-trailing-control",
                maximumGeometryStep: Double(maximumStep),
                maximumTailDistance: Double(maximumTail),
                changedFrames: pixelChangingFrames,
                pixelChangingFrames: pixelChangingFrames,
                markerIdentityInstances: identities.count,
                samples: samples
            )], named: "composer-controls-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("composer process orb changes from solving to thinking on the real process event path")
    func composerProcessOrbModeMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_777).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            try await harness.deliverProcessActivity(composerProcessActivity(recent: false))
            _ = try await harness.recorder.waitUntil { _ in
                harness.composerProcessOrbMotionMarker?.mode == .solving
            }
            for _ in 0..<12 { try await harness.driveFrameBoundary() }
            let initialMarker = try #require(harness.composerProcessOrbMotionMarker)
            var previousFrame = try #require(harness.composerProcessOrbMotionFrame)
            var previousImage = try ChatMotionPixelSupport.captureWindow(harness: harness)
            try await harness.deliverProcessActivity(composerProcessActivity(recent: true))

            var maximumStep: CGFloat = 0
            var maximumTail: CGFloat = 0
            var pixelChangingFrames = 0
            var identities: Set<ObjectIdentifier> = []
            var samples: [Double] = []
            for _ in 0..<24 {
                try await harness.driveFrameBoundary()
                guard let marker = harness.composerProcessOrbMotionMarker,
                      let frame = harness.composerProcessOrbMotionFrame else { continue }
                let image = try ChatMotionPixelSupport.captureWindow(harness: harness)
                if ChatMotionPixelSupport.changedPixels(previousImage, image, in: frame) {
                    pixelChangingFrames += 1
                }
                let step = max(
                    max(abs(frame.minX - previousFrame.minX), abs(frame.minY - previousFrame.minY)),
                    max(abs(frame.width - previousFrame.width), abs(frame.height - previousFrame.height))
                )
                maximumStep = max(maximumStep, step)
                maximumTail = max(maximumTail, abs(harness.probeObservation.geometry.distanceFromBottom))
                identities.insert(ObjectIdentifier(marker))
                samples.append(contentsOf: [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)])
                previousFrame = frame
                previousImage = image
            }
            #expect(harness.composerProcessOrbMotionMarker?.mode == .thinking)
            #expect(maximumStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(pixelChangingFrames >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
            #expect(identities.count == 1)
            #expect(initialMarker === harness.composerProcessOrbMotionMarker)
            #expect(maximumTail <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([ChatMotionSurfaceMetrics(
                name: "composer-process-orb-solving-to-thinking",
                hostedMarkerID: "composer-process-orb",
                maximumGeometryStep: Double(maximumStep),
                maximumTailDistance: Double(maximumTail),
                changedFrames: pixelChangingFrames,
                pixelChangingFrames: pixelChangingFrames,
                markerIdentityInstances: identities.count,
                samples: samples
            )], named: "composer-process-orb-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("composer process orb mode change respects Reduce Motion")
    func composerProcessOrbModeReduceMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_779).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink,
            reduceMotionEnabled: true
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            try await harness.deliverProcessActivity(composerProcessActivity(recent: false))
            _ = try await harness.recorder.waitUntil { _ in
                harness.composerProcessOrbMotionMarker?.mode == .solving
            }
            let initialMarker = try #require(harness.composerProcessOrbMotionMarker)
            let before = try #require(harness.composerProcessOrbMotionFrame)
            try await harness.deliverProcessActivity(composerProcessActivity(recent: true))
            _ = try await harness.recorder.waitUntil { _ in
                harness.composerProcessOrbMotionMarker?.mode == .thinking
            }
            for _ in 0..<2 { try await harness.driveFrameBoundary() }
            let after = try #require(harness.composerProcessOrbMotionFrame)
            let step = max(
                max(abs(after.minX - before.minX), abs(after.minY - before.minY)),
                max(abs(after.width - before.width), abs(after.height - before.height))
            )
            let tail = abs(harness.probeObservation.geometry.distanceFromBottom)
            #expect(step <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(tail <= ChatMotionConformanceBounds.maximumTailDistance)
            #expect(initialMarker === harness.composerProcessOrbMotionMarker)
            try writeSurfaceMetrics([ChatMotionSurfaceMetrics(
                name: "composer-process-orb-mode-reduce-motion",
                hostedMarkerID: "composer-process-orb",
                maximumGeometryStep: Double(step),
                maximumTailDistance: Double(tail),
                changedFrames: 0,
                pixelChangingFrames: 0,
                markerIdentityInstances: 1,
                samples: [Double(before.minX), Double(before.minY), Double(before.width), Double(before.height),
                          Double(after.minX), Double(after.minY), Double(after.width), Double(after.height)]
            )], named: "composer-process-orb-reduce-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("floating display arrival, programmatic settling and dismissal stay bounded")
    func floatingDisplayMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_773).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<24 { try await harness.driveFrameBoundary() }
            let previousAnimationScale = ChatMotion.hostedTestAnimationScale
            ChatMotion.hostedTestAnimationScale = ChatMotionPixelSupport.animationScale
            defer { ChatMotion.hostedTestAnimationScale = previousAnimationScale }
            let display = DisplayProjection(
                displayId: "mo7-floating-motion", title: "Browser", altText: "Live browser viewport",
                kind: .browserLive,
                presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet),
                eligibleSurfaces: [.sheet, .floating], fallbackText: "Unavailable",
                liveView: .init(schema: "tron.browser-live-view.v1", viewId: "mo7-view",
                    generation: "mo7-generation", title: "Browser", fallbackText: "Unavailable")
            )
            let route = DisplayRoute(sessionID: snapshot.sessionId, display: display)
            let arrival = try await recordFloatingMotion(harness, name: "floating-arrive", samplePixels: true) {
                harness.probe.presentDisplay(.showFloating(route))
            }
            #expect(arrival.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            expectSurfaceAnimationFrames(arrival, requiresPixelMotion: true)
            #expect(arrival.markerIdentityInstances == 1)
            #expect((arrival.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)

            let initial = try #require(harness.floatingLayout())
            let move = try await recordFloatingMotion(harness, name: "floating-programmatic-move") {
                initial.marker.move?(.topLeading)
            }
            #expect(move.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(move.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect(move.markerIdentityInstances == 1)
            #expect((move.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)

            let current = try #require(harness.floatingLayout())
            let dismissal = try await recordFloatingMotion(harness, name: "floating-dismiss", samplePixels: true) {
                current.marker.dismiss?()
            }
            #expect(dismissal.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(dismissal.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect((dismissal.pixelChangingFrames ?? 0) >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
            #expect(dismissal.markerIdentityInstances == 1)
            #expect((dismissal.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([arrival, move, dismissal], named: "floating-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("catch-up affordance appears and disappears through bounded surface motion")
    func catchUpAffordanceMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_774).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<24 { try await harness.driveFrameBoundary() }
            let appearance = try await recordCatchUpMotion(harness, appeared: true)
            #expect(appearance.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(appearance.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect((appearance.pixelChangingFrames ?? 0) >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
            #expect(appearance.markerIdentityInstances == 1)
            let disappearance = try await recordCatchUpMotion(harness, appeared: false)
            #expect(disappearance.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(disappearance.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect((disappearance.pixelChangingFrames ?? 0) >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
            #expect(disappearance.markerIdentityInstances == 1)
            try writeSurfaceMetrics([appearance, disappearance], named: "catch-up-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("failed and retried opening overlays fade within bounded frames")
    func openingFailureAndRetryOverlayMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_775).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<12 { try await harness.driveFrameBoundary() }
            let previousAnimationScale = ChatMotion.hostedTestAnimationScale
            ChatMotion.hostedTestAnimationScale = ChatMotionPixelSupport.animationScale
            defer { ChatMotion.hostedTestAnimationScale = previousAnimationScale }
            let failure = try await recordOpeningOverlayMotion(harness, failed: true)
            #expect(failure.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            expectSurfaceAnimationFrames(failure, requiresPixelMotion: true)
            let retry = try await recordOpeningOverlayMotion(harness, failed: false)
            #expect(retry.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            expectSurfaceAnimationFrames(retry, requiresPixelMotion: true)
            try writeSurfaceMetrics([failure, retry], named: "opening-overlay-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }

    @Test("Reduce Motion installs composer attachment strip height atomically")
    func composerAttachmentReduceMotion() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 2_771).openingTail(targetEncodedBytes: 10_000)
        let harness = try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot,
            displayFrameScheduler: .displayLink,
            reduceMotionEnabled: true
        )
        do {
            _ = try await harness.recorder.waitUntil { $0.observation.isReady }
            for _ in 0..<24 { try await harness.driveFrameBoundary() }
            let result = try await recordComposerInsetChange(harness, accessoryEnabled: true, boundaries: 8)
            #expect(result.changedFrames <= 1, "Reduce Motion produced \(result.changedFrames) interpolated height frames")
            #expect((result.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([result], named: "composer-reduce-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }
}

@MainActor
private func expectSurfaceAnimationFrames(
    _ metrics: ChatMotionSurfaceMetrics,
    requiresPixelMotion: Bool = false
) {
    #expect(metrics.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
    if requiresPixelMotion {
        #expect((metrics.pixelChangingFrames ?? 0) >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
    }
}

private func composerProcessActivity(recent: Bool) -> SessionProcessActivity {
    let formatter = ISO8601DateFormatter()
    let now = Date()
    let observedAt = formatter.string(from: now)
    let terminalAt = recent ? observedAt : nil
    let recentUntil = recent ? formatter.string(from: now.addingTimeInterval(5 * 60)) : nil
    return SessionProcessActivity(
        processId: "motion-subagent",
        kind: .subagent,
        executionMode: .asynchronous,
        source: .delegatedAgent,
        lifecycle: SessionProcessLifecycle(
            state: recent ? .completed : .running,
            sequence: recent ? 2 : 1,
            observedAt: observedAt,
            terminalAt: terminalAt,
            recentUntil: recentUntil
        ),
        visibility: recent ? .recent : .active,
        title: "Motion fixture"
    )
}

@MainActor
private func recordOpeningOverlayMotion(
    _ harness: ChatViewScrollHarness,
    failed: Bool
) async throws -> ChatMotionSurfaceMetrics {
    var previousFrame = harness.openingOverlayMotionFrame
    var previousOpacity = harness.openingOverlayMotionOpacity
    var previousImage = try ChatMotionPixelSupport.captureWindow(harness: harness)
    var previousSampleTime = CACurrentMediaTime()
    harness.driveOpeningOverlay(failed: failed)
    var maximumStep: CGFloat = 0
    var rawMaximumStep: CGFloat = 0
    var maximumTail: CGFloat = 0
    var opacityChangingFrames = 0
    var pixelChangingFrames = 0
    var identities: Set<ObjectIdentifier> = []
    var samples: [Double] = []
    var sampleIntervals: [Double] = []
    for _ in 0..<24 {
        try await harness.driveFrameBoundary()
        let frame = harness.openingOverlayMotionFrame
        let opacity = harness.openingOverlayMotionOpacity
        let image = try ChatMotionPixelSupport.captureWindow(harness: harness)
        if ChatMotionPixelSupport.changedPixels(previousImage, image, in: frame) {
            pixelChangingFrames += 1
        }
        let rawStep = max(
            max(abs(frame.minX - previousFrame.minX), abs(frame.minY - previousFrame.minY)),
            max(abs(frame.width - previousFrame.width), abs(frame.height - previousFrame.height))
        )
        let sampledAt = CACurrentMediaTime()
        let elapsed = sampledAt - previousSampleTime
        let step = normalizedChatMotionStep(rawStep, elapsed: elapsed)
        maximumStep = max(maximumStep, step)
        rawMaximumStep = max(rawMaximumStep, rawStep)
        sampleIntervals.append(elapsed * 1_000)
        previousSampleTime = sampledAt
        if abs(opacity - previousOpacity) > 0.005 { opacityChangingFrames += 1 }
        if let marker = harness.openingOverlayMotionMarker { identities.insert(ObjectIdentifier(marker)) }
        maximumTail = max(maximumTail, abs(harness.probeObservation.geometry.distanceFromBottom))
        samples.append(contentsOf: [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height), Double(opacity), Double(rawStep), Double(step)])
        previousFrame = frame
        previousOpacity = opacity
        previousImage = image
    }
    return ChatMotionSurfaceMetrics(
        name: failed ? "opening-failed-overlay-fade" : "opening-retry-progress-fade",
        hostedMarkerID: "chat-opening-overlay",
        maximumGeometryStep: Double(maximumStep),
        maximumTailDistance: Double(maximumTail),
        changedFrames: opacityChangingFrames,
        pixelChangingFrames: pixelChangingFrames,
        markerIdentityInstances: identities.count,
        samples: samples,
        rawMaximumGeometryStep: Double(rawMaximumStep),
        sampleIntervalMilliseconds: sampleIntervals
    )
}

@MainActor
private func recordCatchUpMotion(
    _ harness: ChatViewScrollHarness,
    appeared: Bool
) async throws -> ChatMotionSurfaceMetrics {
    var previousFrame = harness.catchUpMotionFrame
    var previousImage = try ChatMotionPixelSupport.captureWindow(harness: harness)
    if appeared {
        try await harness.beginReaderDetachmentForMotion()
    } else {
        harness.driveCatchUp(reduceMotion: false)
    }
    var maximumStep: CGFloat = 0
    var pixelChangingFrames = 0
    var changedFrames = 0
    var identities: Set<ObjectIdentifier> = []
    var samples: [Double] = []
    for _ in 0..<24 {
        try await harness.driveFrameBoundary()
        let current = harness.catchUpMotionFrame
        let frame = current ?? previousFrame
        let image = try ChatMotionPixelSupport.captureWindow(harness: harness)
        if let frame, ChatMotionPixelSupport.changedPixels(previousImage, image, in: frame) {
            pixelChangingFrames += 1
        }
        if let current {
            let size = current.size
            if let previousFrame {
                let step = max(abs(size.width - previousFrame.width), abs(size.height - previousFrame.height))
                if step > 0.5 { changedFrames += 1 }
                maximumStep = max(maximumStep, step)
            }
            previousFrame = current
            identities.insert(ObjectIdentifier(try #require(harness.catchUpMotionMarker)))
            samples.append(Double(size.width))
        }
        previousImage = image
    }
    return ChatMotionSurfaceMetrics(
        name: appeared ? "catch-up-affordance-arrive" : "catch-up-affordance-dismiss",
        hostedMarkerID: "chat-catch-up",
        maximumGeometryStep: Double(maximumStep),
        maximumTailDistance: nil,
        changedFrames: max(changedFrames, pixelChangingFrames),
        pixelChangingFrames: pixelChangingFrames,
        markerIdentityInstances: identities.count,
        samples: samples
    )
}

@MainActor
private func recordFloatingMotion(
    _ harness: ChatViewScrollHarness,
    name: String,
    samplePixels: Bool = false,
    action: () -> Void
) async throws -> ChatMotionSurfaceMetrics {
    var previousFrame = harness.floatingLayout()?.frame
    var previousImage = try samplePixels ? ChatMotionPixelSupport.captureWindow(harness: harness) : nil
    action()
    var maximumStep: CGFloat = 0
    var maximumTail: CGFloat = 0
    var changedFrames = 0
    var pixelChangingFrames = 0
    var identities: Set<ObjectIdentifier> = []
    var samples: [Double] = []
    var rawMaximumStep: CGFloat = 0
    var sampleIntervals: [Double] = []
    var previousSampleTime = CACurrentMediaTime()
    for _ in 0..<24 {
        try await harness.driveFrameBoundary()
        let current = harness.floatingLayout()
        let frame = current?.frame ?? previousFrame
        let image = try samplePixels ? ChatMotionPixelSupport.captureWindow(harness: harness) : nil
        if let frame, let previousImage, let image,
           ChatMotionPixelSupport.changedPixels(previousImage, image, in: frame) {
            pixelChangingFrames += 1
        }
        if let current {
            identities.insert(ObjectIdentifier(current.marker))
            let next = current.frame
            if let previousFrame {
                let rawStep = max(
                    max(abs(next.minX - previousFrame.minX), abs(next.minY - previousFrame.minY)),
                    max(abs(next.width - previousFrame.width), abs(next.height - previousFrame.height))
                )
                let sampledAt = CACurrentMediaTime()
                let elapsed = sampledAt - previousSampleTime
                let step = normalizedChatMotionStep(rawStep, elapsed: elapsed)
                if step > 0.5 { changedFrames += 1 }
                maximumStep = max(maximumStep, step)
                rawMaximumStep = max(rawMaximumStep, rawStep)
                sampleIntervals.append(elapsed * 1_000)
                previousSampleTime = sampledAt
                samples.append(contentsOf: [Double(next.minX), Double(next.minY), Double(next.width), Double(next.height), Double(rawStep), Double(step)])
            }
            previousFrame = next
        }
        maximumTail = max(maximumTail, abs(harness.probeObservation.geometry.distanceFromBottom))
        previousImage = image
    }
    return ChatMotionSurfaceMetrics(
        name: name,
        hostedMarkerID: "floating-display",
        maximumGeometryStep: Double(maximumStep),
        maximumTailDistance: Double(maximumTail),
        changedFrames: samplePixels ? max(changedFrames, pixelChangingFrames) : changedFrames,
        pixelChangingFrames: samplePixels ? pixelChangingFrames : nil,
        markerIdentityInstances: identities.count,
        samples: samples,
        rawMaximumGeometryStep: Double(rawMaximumStep),
        sampleIntervalMilliseconds: sampleIntervals
    )
}

@MainActor
private func recordAttachmentChipChange(
    _ harness: ChatViewScrollHarness,
    attached: Bool
) async throws -> ChatMotionSurfaceMetrics {
    try harness.setMotionAccessory(attached ? .file : nil)
    var previous: CGSize?
    var maximumStep: CGFloat = 0
    var maximumTail: CGFloat = 0
    var changedFrames = 0
    var rawMaximumStep: CGFloat = 0
    var sizes: [Double] = []
    var sampleIntervals: [Double] = []
    var previousSampleTime = CACurrentMediaTime()
    for _ in 0..<24 {
        try await harness.driveFrameBoundary()
        if let frame = harness.pendingAttachmentMotionFrame(id: "motion-attachment") {
            let size = frame.size
            if let previous {
                let rawStep = max(abs(size.width - previous.width), abs(size.height - previous.height))
                let sampledAt = CACurrentMediaTime()
                let elapsed = sampledAt - previousSampleTime
                let step = normalizedChatMotionStep(rawStep, elapsed: elapsed)
                if step > 0.5 { changedFrames += 1 }
                maximumStep = max(maximumStep, step)
                rawMaximumStep = max(rawMaximumStep, rawStep)
                sampleIntervals.append(elapsed * 1_000)
                previousSampleTime = sampledAt
            }
            previous = size
            sizes.append(Double(size.width))
        }
        maximumTail = max(maximumTail, abs(harness.probeObservation.geometry.distanceFromBottom))
    }
    return ChatMotionSurfaceMetrics(
        name: attached ? "attachment-chip-insert" : "attachment-chip-remove",
        hostedMarkerID: "motion-attachment",
        maximumGeometryStep: Double(maximumStep),
        maximumTailDistance: Double(maximumTail),
        changedFrames: changedFrames,
        pixelChangingFrames: nil,
        markerIdentityInstances: 1,
        samples: sizes,
        rawMaximumGeometryStep: Double(rawMaximumStep),
        sampleIntervalMilliseconds: sampleIntervals
    )
}

@MainActor
private func recordComposerInsetChange(
    _ harness: ChatViewScrollHarness,
    accessoryEnabled: Bool,
    boundaries: Int = 24
) async throws -> ChatMotionSurfaceMetrics {
    let before = try #require(harness.composerMotionFrame?.height)
    try harness.setMotionAccessory(accessoryEnabled ? .photo : nil)
    var previous = before
    var maximumStep: CGFloat = 0
    var maximumTail: CGFloat = 0
    var changedFrames = 0
    var rawMaximumStep: CGFloat = 0
    var heights: [Double] = []
    var sampleIntervals: [Double] = []
    var previousSampleTime = CACurrentMediaTime()
    for _ in 0..<boundaries {
        try await harness.driveFrameBoundary()
        guard let sample = harness.recorder.samples.last else { continue }
        let height = try #require(harness.composerMotionFrame?.height)
        let rawStep = abs(height - previous)
        let sampledAt = CACurrentMediaTime()
        let elapsed = sampledAt - previousSampleTime
        let step = normalizedChatMotionStep(rawStep, elapsed: elapsed)
        if step > 0.5 { changedFrames += 1 }
        maximumStep = max(maximumStep, step)
        rawMaximumStep = max(rawMaximumStep, rawStep)
        sampleIntervals.append(elapsed * 1_000)
        previousSampleTime = sampledAt
        maximumTail = max(maximumTail, abs(sample.observation.geometry.distanceFromBottom))
        heights.append(Double(height))
        previous = height
    }
    let averageSampleInterval = sampleIntervals.isEmpty ? 0 : sampleIntervals.reduce(0, +) / Double(sampleIntervals.count)
    return ChatMotionSurfaceMetrics(
        name: accessoryEnabled ? "composer-attachment-strip-insert" : "composer-attachment-strip-remove",
        hostedMarkerID: ChatHostedNativeRowProbe.composerID,
        maximumGeometryStep: Double(maximumStep),
        maximumTailDistance: Double(maximumTail),
        changedFrames: changedFrames,
        pixelChangingFrames: nil,
        markerIdentityInstances: 1,
        samples: heights,
        rawMaximumGeometryStep: Double(rawMaximumStep),
        sampleIntervalMilliseconds: sampleIntervals
    )
}

private func writeSurfaceMetrics(
    _ metrics: [ChatMotionSurfaceMetrics],
    named filename: String = "surface-motion-conformance.json"
) throws {
    let directory = URL(fileURLWithPath: "/tmp/tron-fix-batch/270/mo7", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metrics).write(to: directory.appending(path: filename), options: .atomic)
}
