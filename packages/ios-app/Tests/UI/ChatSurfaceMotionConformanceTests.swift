import Foundation
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
            let insertion = try await recordAttachmentChipChange(harness, attached: true)
            #expect(insertion.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect(insertion.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect((insertion.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            let removal = try await recordAttachmentChipChange(harness, attached: false)
            #expect(removal.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect(removal.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect((removal.maximumTailDistance ?? 0) <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([insertion, removal], named: "attachment-chip-motion.json")
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
            #expect(arrival.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect((arrival.pixelChangingFrames ?? 0) >= ChatMotionConformanceBounds.minimumPixelChangingFrames)
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
                let step = max(
                    max(abs(next.minX - previousFrame.minX), abs(next.minY - previousFrame.minY)),
                    max(abs(next.width - previousFrame.width), abs(next.height - previousFrame.height))
                )
                if step > 0.5 { changedFrames += 1 }
                maximumStep = max(maximumStep, step)
            }
            previousFrame = next
            samples.append(contentsOf: [Double(next.minX), Double(next.minY), Double(next.width), Double(next.height)])
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
        samples: samples
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
    var sizes: [Double] = []
    for _ in 0..<24 {
        try await harness.driveFrameBoundary()
        if let frame = harness.pendingAttachmentMotionFrame(id: "motion-attachment") {
            let size = frame.size
            if let previous {
                let step = max(abs(size.width - previous.width), abs(size.height - previous.height))
                if step > 0.5 { changedFrames += 1 }
                maximumStep = max(maximumStep, step)
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
        samples: sizes
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
    var heights: [Double] = []
    for _ in 0..<boundaries {
        try await harness.driveFrameBoundary()
        guard let sample = harness.recorder.samples.last else { continue }
        let height = try #require(harness.composerMotionFrame?.height)
        let step = abs(height - previous)
        if step > 0.5 { changedFrames += 1 }
        maximumStep = max(maximumStep, step)
        maximumTail = max(maximumTail, abs(sample.observation.geometry.distanceFromBottom))
        heights.append(Double(height))
        previous = height
    }
    return ChatMotionSurfaceMetrics(
        name: accessoryEnabled ? "composer-attachment-strip-insert" : "composer-attachment-strip-remove",
        hostedMarkerID: ChatHostedNativeRowProbe.composerID,
        maximumGeometryStep: Double(maximumStep),
        maximumTailDistance: Double(maximumTail),
        changedFrames: changedFrames,
        pixelChangingFrames: nil,
        markerIdentityInstances: 1,
        samples: heights
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
