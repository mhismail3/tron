import Foundation
import SwiftUI
import Testing
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
            #expect(insertion.maximumTailDistance <= ChatMotionConformanceBounds.maximumTailDistance)
            #expect(removal.maximumTailDistance <= ChatMotionConformanceBounds.maximumTailDistance)
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
            #expect(insertion.maximumTailDistance <= ChatMotionConformanceBounds.maximumTailDistance)
            let removal = try await recordAttachmentChipChange(harness, attached: false)
            #expect(removal.changedFrames >= ChatMotionConformanceBounds.minimumAnimatedFrames)
            #expect(removal.maximumGeometryStep <= ChatMotionConformanceBounds.maximumGeometryStep)
            #expect(removal.maximumTailDistance <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([insertion, removal], named: "attachment-chip-motion.json")
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
            #expect(result.maximumTailDistance <= ChatMotionConformanceBounds.maximumTailDistance)
            try writeSurfaceMetrics([result], named: "composer-reduce-motion.json")
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()
    }
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
