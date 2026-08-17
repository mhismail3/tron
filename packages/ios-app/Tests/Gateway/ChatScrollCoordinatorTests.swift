import SwiftUI
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat scroll coordinator")
struct ChatScrollCoordinatorTests {
    private let bottom = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400)
    private let away = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_000, containerHeight: 400)

    @Test("pinned streaming growth coalesces to one command per displayed frame")
    func pinnedGrowthCoalesces() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let first = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_080, containerHeight: 400)
            let second = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_160, containerHeight: 400)
            coordinator.geometryChanged(previous: bottom, current: first)
            coordinator.geometryChanged(previous: first, current: second)
            await frames.waitForRequest(count: 1)
            #expect(coordinator.command == nil)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .tail)
            #expect(frames.requestCount == 1)
        }
    }

    @Test("discrete and continuous automatic follows are coalesced and nonanimated")
    func discreteInsertionMotion() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            coordinator.discreteContentInserted(renderedID: "inserted-row")
            let inserted = ChatTranscriptGeometry(
                offsetY: 600, contentHeight: 1_100, containerHeight: 400
            )
            coordinator.geometryChanged(previous: bottom, current: inserted)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let discrete = try await coordinator.hostedNextCommand()
            #expect(discrete.origin == .automaticFollow)
            #expect(discrete.animation == .disabled)
            coordinator.commandApplied(discrete)

            let streaming = ChatTranscriptGeometry(
                offsetY: 700, contentHeight: 1_180, containerHeight: 400
            )
            coordinator.geometryChanged(previous: inserted, current: streaming)
            await frames.waitForRequest(count: 2)
            frames.releaseNext()
            let immediate = try await coordinator.hostedNextCommand()
            #expect(immediate.animation == .disabled)
        }
    }

    @Test("near-boundary insertion expires follow entitlement before later streaming")
    func nearBoundaryDiscreteInsertionExpires() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let decision = coordinator.hostedFollowDecisionRevision
            coordinator.discreteContentInserted(renderedID: "near-boundary-row")
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            await coordinator.hostedWaitForFollowDecision(after: decision)
            #expect(coordinator.command == nil)

            let streaming = ChatTranscriptGeometry(
                offsetY: 600, contentHeight: 1_100, containerHeight: 400
            )
            coordinator.geometryChanged(previous: bottom, current: streaming)
            await frames.waitForRequest(count: 2)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.animation == .disabled)
        }
    }

    @Test("installed same-row completion retains one nonanimated discrete follow")
    func installedSameRowRetainsDiscreteFollow() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            coordinator.discreteContentInserted(renderedID: "tool-run-one")
            #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["tool-run-one"])
            coordinator.installedTranscriptChanged(try installedToolTranscript(
                ids: ["one"],
                statuses: [.completed],
                timelineGeneration: 2
            ))
            #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["tool-run-one"])
            coordinator.geometryChanged(
                previous: bottom,
                current: ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_100, containerHeight: 400
                )
            )
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.animation == .disabled)
            #expect(coordinator.hostedDiscreteFollowRenderedIDs.isEmpty)
        }
    }

    @Test("installed removal clears discrete follow while stable multi-tool group retains it")
    func installedIdentityFiltersDiscreteFollow() throws {
        let frames = ManualScrollFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.discreteContentInserted(renderedID: "tool-run-one")
        coordinator.installedTranscriptChanged(try installedToolTranscript(
            ids: ["one", "two"],
            statuses: [.running, .running],
            timelineGeneration: 2
        ))
        #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["tool-run-one"])
        coordinator.installedTranscriptChanged(try installedToolTranscript(
            ids: ["one", "two"],
            statuses: [.completed, .completed],
            timelineGeneration: 3
        ))
        #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["tool-run-one"])

        coordinator.installedTranscriptChanged(try installedToolTranscript(
            ids: ["two"],
            statuses: [.completed],
            timelineGeneration: 4
        ))
        #expect(coordinator.hostedDiscreteFollowRenderedIDs.isEmpty)
        #expect(coordinator.command == nil)
    }

    @Test("pinned projection topology change coalesces to one nonanimated tail settlement")
    func pinnedProjectionMutationSettlesOnce() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let previous = try installedToolTranscript(
                ids: ["one"], statuses: [.running], timelineGeneration: 1
            )
            let grouped = try installedToolTranscript(
                ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
            )

            coordinator.transcriptProjectionWillChange(from: previous)
            coordinator.installedTranscriptChanged(grouped)
            coordinator.geometryChanged(
                previous: bottom,
                current: ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_120, containerHeight: 400
                )
            )
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.origin == .automaticFollow)
            #expect(command.destination == .tail)
            #expect(command.animation == .disabled)
            #expect(frames.requestCount == 1)
        }
    }

    @Test("detached projection topology change preserves a fresh surviving semantic anchor")
    func detachedProjectionMutationPreservesAnchor() throws {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        #expect(coordinator.hostedIsNativeUserOwned)
        let previous = try installedToolTranscript(
            ids: ["one"], statuses: [.running], timelineGeneration: 1
        )
        let grouped = try installedToolTranscript(
            ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
        )
        let latest = try installedToolTranscript(
            ids: ["one", "two", "three"],
            statuses: [.completed, .completed, .completed],
            timelineGeneration: 3
        )
        let previousEpoch = coordinator.layoutEpoch
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: previousEpoch,
            frame: CGRect(x: 0, y: 40, width: 300, height: 44)
        )

        coordinator.transcriptProjectionWillChange(from: previous)
        // Identity-changing projection work temporarily clears the installed
        // value before publishing its replacement; the captured locus survives.
        coordinator.installedTranscriptChanged(nil)
        coordinator.installedTranscriptChanged(grouped)
        let supersededEpoch = coordinator.layoutEpoch
        #expect(supersededEpoch == previousEpoch + 1)

        // A newer desired/install pair coalesces around the original semantic
        // locus and retires the first installed generation before it measures.
        coordinator.transcriptProjectionWillChange(from: grouped)
        coordinator.installedTranscriptChanged(latest)
        let installedEpoch = coordinator.layoutEpoch
        #expect(installedEpoch == supersededEpoch + 1)
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: supersededEpoch,
            frame: CGRect(x: 0, y: 80, width: 300, height: 44)
        )
        #expect(coordinator.command == nil)

        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: installedEpoch,
            frame: CGRect(x: 0, y: 75, width: 300, height: 44)
        )
        #expect(coordinator.command == nil)
        coordinator.geometryChanged(previous: away, current: away)
        let correction = try #require(coordinator.command)
        #expect(correction.origin == .layout)
        #expect(correction.destination == .offsetY(335))
        #expect(correction.animation == .disabled)
        coordinator.commandApplied(correction)

        // A post-correction semantic sample cannot release against stale geometry.
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: installedEpoch,
            frame: CGRect(x: 0, y: 40.5, width: 300, height: 44)
        )
        #expect(coordinator.command == nil)
        coordinator.geometryChanged(
            previous: away,
            current: ChatTranscriptGeometry(
                offsetY: 335, contentHeight: 1_000, containerHeight: 400
            )
        )
        let release = try #require(coordinator.command)
        #expect(release.origin == .binding)
        #expect(release.destination == .releaseBinding)
        coordinator.commandApplied(release)
        #expect(coordinator.command == nil)
        #expect(coordinator.userScrolledAway)
    }

    @Test("ordinary correction waits for a newer semantic sample after geometry-first settlement")
    func layoutCorrectionGeometryFirstSettlement() throws {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        let previous = try installedToolTranscript(
            ids: ["one"], statuses: [.running], timelineGeneration: 1
        )
        let grouped = try installedToolTranscript(
            ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
        )
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 40, width: 300, height: 44)
        )
        coordinator.transcriptProjectionWillChange(from: previous)
        // Geometry may settle after submission but before the installed-value
        // observer starts the new semantic layout epoch.
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.installedTranscriptChanged(grouped)
        let installedEpoch = coordinator.layoutEpoch
        #expect(coordinator.command == nil)
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: installedEpoch,
            frame: CGRect(x: 0, y: 75, width: 300, height: 44)
        )
        let correction = try #require(coordinator.command)
        coordinator.commandApplied(correction)

        coordinator.geometryChanged(
            previous: away,
            current: ChatTranscriptGeometry(
                offsetY: 335, contentHeight: 1_000, containerHeight: 400
            )
        )
        #expect(coordinator.command == nil)
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: installedEpoch,
            frame: CGRect(x: 0, y: 40.5, width: 300, height: 44)
        )
        let release = try #require(coordinator.command)
        #expect(release.destination == .releaseBinding)
        coordinator.commandApplied(release)
        #expect(coordinator.userScrolledAway)
    }

    @Test("native ownership callback cancels an ordinary layout correction immediately")
    func interactionCancelsProjectionMutation() throws {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        coordinator.scrollPositionChanged(isPositionedByUser: false)
        let previous = try installedToolTranscript(
            ids: ["one"], statuses: [.running], timelineGeneration: 1
        )
        let grouped = try installedToolTranscript(
            ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
        )
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 40, width: 300, height: 44)
        )
        coordinator.transcriptProjectionWillChange(from: previous)
        coordinator.installedTranscriptChanged(grouped)
        let installedEpoch = coordinator.layoutEpoch

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: installedEpoch,
            frame: CGRect(x: 0, y: 90, width: 300, height: 44)
        )
        #expect(coordinator.command == nil)
    }

    @Test("superseding layout releases an applied point binding and stale release cannot survive native takeover")
    func layoutSupersessionReleasesAppliedBinding() throws {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        let previous = try installedToolTranscript(
            ids: ["one"], statuses: [.running], timelineGeneration: 1
        )
        let grouped = try installedToolTranscript(
            ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
        )
        let latest = try installedToolTranscript(
            ids: ["one", "two", "three"],
            statuses: [.completed, .completed, .completed],
            timelineGeneration: 3
        )
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 40, width: 300, height: 44)
        )
        coordinator.transcriptProjectionWillChange(from: previous)
        coordinator.installedTranscriptChanged(grouped)
        let groupedEpoch = coordinator.layoutEpoch
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: groupedEpoch,
            frame: CGRect(x: 0, y: 75, width: 300, height: 44)
        )
        coordinator.geometryChanged(previous: away, current: away)
        let correction = try #require(coordinator.command)
        #expect(correction.origin == .layout)
        coordinator.commandApplied(correction)

        coordinator.transcriptProjectionWillChange(from: grouped)
        coordinator.installedTranscriptChanged(latest)
        let release = try #require(coordinator.command)
        #expect(release.origin == .binding)
        #expect(release.destination == .releaseBinding)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.command == nil)
        coordinator.commandApplied(release)
        #expect(coordinator.command == nil)
    }

    @Test("ordinary anchor disappearance releases an applied point binding")
    func layoutAnchorDisappearanceReleasesAppliedBinding() throws {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        let previous = try installedToolTranscript(
            ids: ["one"], statuses: [.running], timelineGeneration: 1
        )
        let grouped = try installedToolTranscript(
            ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
        )
        let withoutAnchor = try installedToolTranscript(
            ids: ["two"], statuses: [.completed], timelineGeneration: 3
        )
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 40, width: 300, height: 44)
        )
        coordinator.transcriptProjectionWillChange(from: previous)
        coordinator.installedTranscriptChanged(grouped)
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 75, width: 300, height: 44)
        )
        coordinator.geometryChanged(previous: away, current: away)
        let correction = try #require(coordinator.command)
        coordinator.commandApplied(correction)

        coordinator.transcriptProjectionWillChange(from: grouped)
        coordinator.installedTranscriptChanged(withoutAnchor)
        let release = try #require(coordinator.command)
        #expect(release.origin == .binding)
        #expect(release.destination == .releaseBinding)
    }

    @Test("catch-up cancellation replaces an applied layout binding without publishing release")
    func catchUpCancelsAppliedLayoutBinding() throws {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        let previous = try installedToolTranscript(
            ids: ["one"], statuses: [.running], timelineGeneration: 1
        )
        let grouped = try installedToolTranscript(
            ids: ["one", "two"], statuses: [.completed, .completed], timelineGeneration: 2
        )
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 40, width: 300, height: 44)
        )
        coordinator.transcriptProjectionWillChange(from: previous)
        coordinator.installedTranscriptChanged(grouped)
        coordinator.semanticFrameChanged(
            renderedID: "tool-run-one",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 75, width: 300, height: 44)
        )
        coordinator.geometryChanged(previous: away, current: away)
        let correction = try #require(coordinator.command)
        coordinator.commandApplied(correction)

        coordinator.requestCatchUp(reduceMotion: true)
        let catchUp = try #require(coordinator.command)
        #expect(catchUp.origin == .catchUp)
        #expect(catchUp.destination == .tail)
    }

    @Test("installed removal clears only discrete motion when continuous growth is pending")
    func installedRemovalPreservesContinuousFollow() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            coordinator.discreteContentInserted(renderedID: "tool-run-one")
            coordinator.geometryChanged(
                previous: bottom,
                current: ChatTranscriptGeometry(
                    offsetY: 600, contentHeight: 1_100, containerHeight: 400
                )
            )
            coordinator.installedTranscriptChanged(try installedToolTranscript(
                ids: ["two"],
                statuses: [.completed],
                timelineGeneration: 2
            ))
            #expect(coordinator.hostedDiscreteFollowRenderedIDs.isEmpty)

            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.animation == .disabled)
        }
    }

    @Test("detached reader and direct interaction cancel discrete insertion motion")
    func detachedDiscreteInsertionIsInert() {
        let frames = ManualScrollFrameScheduler()
        let coordinator = detachedCoordinator(at: away, withUnread: false, frames: frames)
        coordinator.discreteContentInserted(renderedID: "detached-row")
        coordinator.geometryChanged(
            previous: away,
            current: ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_100, containerHeight: 400)
        )
        #expect(frames.requestCount == 0)
        #expect(coordinator.command == nil)
    }

    @Test("growth arriving before an earlier tail command settles remains logically pinned")
    func continuousGrowthWhileSettling() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let first = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_120, containerHeight: 400)
            coordinator.geometryChanged(previous: bottom, current: first)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let firstCommand = try await coordinator.hostedNextCommand()
            coordinator.commandApplied(firstCommand)

            let second = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_200, containerHeight: 400)
            coordinator.geometryChanged(previous: first, current: second)
            await frames.waitForRequest(count: 2)
            frames.releaseNext()
            let secondCommand = try await coordinator.hostedNextCommand()
            #expect(secondCommand.destination == .tail)
            #expect(!coordinator.userScrolledAway)
        }
    }

    @Test("growth inside practical bottom tolerance emits no command")
    func noWriteInsideTolerance() async throws {
        let frames = ManualScrollFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        let near = ChatTranscriptGeometry(offsetY: 675, contentHeight: 1_080, containerHeight: 400)
        coordinator.geometryChanged(previous: bottom, current: near)
        #expect(frames.requestCount == 0)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("pinned and detached shrink geometry emits no automatic write")
    func shrinkIsInert() {
        let pinnedFrames = ManualScrollFrameScheduler()
        let pinned = ChatScrollCoordinator(frameScheduler: pinnedFrames.scheduler)
        let pinnedBefore = ChatTranscriptGeometry(
            offsetY: 600, contentHeight: 1_200, containerHeight: 400
        )
        let pinnedAfter = ChatTranscriptGeometry(
            offsetY: 600, contentHeight: 1_150, containerHeight: 400
        )
        pinned.geometryChanged(previous: pinnedBefore, current: pinnedAfter)
        #expect(pinnedFrames.requestCount == 0)
        #expect(pinned.command == nil)

        let detachedFrames = ManualScrollFrameScheduler()
        let detached = detachedCoordinator(at: away, frames: detachedFrames)
        let detachedAfter = ChatTranscriptGeometry(
            offsetY: 300, contentHeight: 950, containerHeight: 400
        )
        detached.geometryChanged(previous: away, current: detachedAfter)
        #expect(detachedFrames.requestCount == 0)
        #expect(detached.command == nil)
        #expect(detached.userScrolledAway)
    }

    @Test("composer measurement preserves fresh native authority through pending final geometry")
    func composerPreservesFreshNativeAuthority() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: .zero, current: bottom)
        if let release = coordinator.command { coordinator.commandApplied(release) }

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.hostedIsNativeUserOwned)
        #expect(coordinator.hostedPendingNativeUserGeometry)
        #expect(coordinator.hostedDirectTailReturnArmed)
        coordinator.composerViewportTransitionBegan()
        #expect(coordinator.hostedIsNativeUserOwned)
        #expect(coordinator.hostedPendingNativeUserGeometry)
        #expect(coordinator.hostedDirectTailReturnArmed)

        // Native ownership may end before its final geometry callback. Composer
        // measurement cannot consume the still-pending directional evidence.
        coordinator.scrollPositionChanged(isPositionedByUser: false)
        #expect(!coordinator.hostedIsNativeUserOwned)
        #expect(coordinator.hostedPendingNativeUserGeometry)
        #expect(coordinator.hostedDirectTailReturnArmed)
        coordinator.composerViewportTransitionBegan()
        #expect(coordinator.hostedPendingNativeUserGeometry)
        #expect(coordinator.hostedDirectTailReturnArmed)
        coordinator.geometryChanged(previous: bottom, current: away)
        #expect(coordinator.userScrolledAway)
    }

    @Test("composer measurement preserves user-driven settling authority")
    func composerPreservesUserSettlingAuthority() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: .zero, current: bottom)
        if let release = coordinator.command { coordinator.commandApplied(release) }
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPhaseChanged(from: .interacting, to: .animating, finalGeometry: bottom)
        #expect(coordinator.hostedIsUserDrivenSettling)
        coordinator.composerViewportTransitionBegan()
        #expect(coordinator.hostedIsUserDrivenSettling)
        #expect(coordinator.hostedDirectTailReturnArmed)
    }

    @Test("geometry and native ownership callback permutations both detach")
    func callbackOrdering() {
        let nativeFirst = ChatScrollCoordinator()
        nativeFirst.scrollPositionChanged(isPositionedByUser: true)
        nativeFirst.geometryChanged(previous: bottom, current: away)
        nativeFirst.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        #expect(nativeFirst.userScrolledAway)

        let geometryFirst = ChatScrollCoordinator()
        geometryFirst.geometryChanged(previous: bottom, current: away)
        geometryFirst.scrollPositionChanged(isPositionedByUser: true)
        #expect(geometryFirst.userScrolledAway)
    }

    @Test("geometry-first detachment consumes direct return through later viewport settlement")
    func geometryFirstDetachmentConsumesDirectReturn() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.userScrolledAway)

        let expanded = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expanded)
        coordinator.geometryChanged(previous: expanded, current: expanded)
        coordinator.scrollPhaseChanged(from: .idle, to: .idle, finalGeometry: expanded)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.isAtBottom)
        #expect(coordinator.command == nil)
    }

    @Test("geometry-first manual return to tail immediately clears catch-up state")
    func geometryFirstManualReturnClearsCatchUp() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.tailSettlementGeneration == 0)

        coordinator.geometryChanged(previous: away, current: bottom)
        #expect(coordinator.shouldShowCatchUpButton)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
        #expect(coordinator.tailSettlementGeneration == 1)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("native visible edge admits manual tail despite stale inset arithmetic")
    func nativeVisibleEdgeAdmitsManualTail() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        let visibleTail = ChatTranscriptGeometry(
            offsetY: 400,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleBottomY: 1_200
        )
        coordinator.geometryChanged(previous: away, current: visibleTail)
        coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: visibleTail
        )

        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("manual return to tail remains pinned through keyboard viewport contraction")
    func manualReturnThenKeyboardFollowsTail() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = detachedCoordinator(at: away, withUnread: true, frames: frames)
            coordinator.geometryChanged(previous: away, current: bottom)
            coordinator.scrollPositionChanged(isPositionedByUser: true)
            if let release = coordinator.command { coordinator.commandApplied(release) }

            coordinator.composerViewportTransitionBegan()
            let keyboard = ChatTranscriptGeometry(
                offsetY: 600,
                contentHeight: 1_000,
                containerHeight: 300,
                bottomInset: 100
            )
            coordinator.viewportChanged(previous: bottom, current: keyboard)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()

            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .tail)
            #expect(command.origin == .automaticFollow)
            #expect(!coordinator.shouldShowCatchUpButton)
        }
    }

    @Test("direct mixed viewport geometry return to tail clears catch-up")
    func mixedViewportManualReturnClearsCatchUp() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        let intermediateViewport = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 350
        )
        coordinator.viewportChanged(previous: away, current: intermediateViewport)
        #expect(coordinator.shouldShowCatchUpButton)

        // SwiftUI may coalesce the final scroll geometry into the idle phase.
        let mixedBottom = ChatTranscriptGeometry(
            offsetY: 700,
            contentHeight: 1_000,
            containerHeight: 300
        )
        coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: mixedBottom
        )

        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
    }

    @Test("active keyboard viewport settlement without content motion preserves detachment")
    func activeKeyboardViewportDoesNotRepin() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        let expandedToBoundary = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expandedToBoundary)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        let streamedWithinBoundary = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_005,
            containerHeight: 700
        )
        coordinator.geometryChanged(
            previous: expandedToBoundary,
            current: streamedWithinBoundary
        )
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.hasUnreadContent)
        let measuredReturn = ChatTranscriptGeometry(
            offsetY: 305,
            contentHeight: 1_005,
            containerHeight: 700
        )
        coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: measuredReturn
        )

        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)

        let lateNative = detachedCoordinator(at: away, withUnread: true)
        lateNative.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        lateNative.viewportChanged(previous: away, current: expandedToBoundary)
        lateNative.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: expandedToBoundary
        )
        lateNative.scrollPositionChanged(isPositionedByUser: true)
        lateNative.geometryChanged(
            previous: expandedToBoundary,
            current: streamedWithinBoundary
        )
        #expect(lateNative.shouldShowCatchUpButton)
        #expect(lateNative.hasUnreadContent)
        #expect(lateNative.command == nil)
    }

    @Test("native positioning after released binding emits a new typed release at tail")
    func nativePositioningRearmsBindingRelease() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: bottom, current: bottom)
        let firstRelease = coordinator.command!
        #expect(firstRelease.destination == .releaseBinding)
        coordinator.commandApplied(firstRelease)
        #expect(coordinator.command == nil)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: bottom)
        #expect(coordinator.command?.destination == .releaseBinding)
        #expect(coordinator.command?.origin == .binding)
    }

    @Test("detached stream viewport composer and image-like settlement emit zero writes")
    func detachedLayoutNeverWrites() {
        let frames = ManualScrollFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        let stream = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_080, containerHeight: 400)
        coordinator.geometryChanged(previous: away, current: stream)
        let composer = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_080, containerHeight: 320, bottomInset: 80)
        coordinator.viewportChanged(previous: stream, current: composer)
        let image = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_240, containerHeight: 320, bottomInset: 80)
        coordinator.geometryChanged(previous: composer, current: image)
        coordinator.composerViewportTransitionBegan()
        coordinator.semanticResponseArrived()
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.hasUnreadContent)
        #expect(frames.requestCount == 0)
        #expect(coordinator.command == nil)
    }

    @Test("viewport expansion and later unattributed boundary settlement preserve detachment")
    func viewportExpansionPreservesDetachment() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        coordinator.semanticResponseArrived()

        let expanded = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expanded)
        coordinator.geometryChanged(previous: expanded, current: expanded)
        coordinator.scrollPhaseChanged(from: .idle, to: .idle, finalGeometry: expanded)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(!coordinator.isAtBottom)
        #expect(coordinator.command == nil)

        let taller = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_200,
            containerHeight: 700
        )
        coordinator.geometryChanged(previous: expanded, current: taller)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        let manuallyReturned = ChatTranscriptGeometry(
            offsetY: 500,
            contentHeight: 1_200,
            containerHeight: 700
        )
        coordinator.geometryChanged(previous: taller, current: manuallyReturned)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("native ownership end and accessibility phase preserve one-shot direct tail return")
    func directTailReturnAdmission() {
        let native = detachedCoordinator(at: away, withUnread: false)
        native.scrollPositionChanged(isPositionedByUser: true)
        native.scrollPositionChanged(isPositionedByUser: false)
        native.geometryChanged(previous: away, current: bottom)
        #expect(!native.userScrolledAway)
        #expect(native.command?.destination == .releaseBinding)

        let accessibility = detachedCoordinator(at: away, withUnread: false)
        accessibility.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        accessibility.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        #expect(!accessibility.userScrolledAway)
        #expect(accessibility.command?.destination == .releaseBinding)
    }

    @Test("direct interaction cancels a pending automatic frame command")
    func interactionCancelsPendingFollow() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let grown = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_100, containerHeight: 400)
            coordinator.geometryChanged(previous: bottom, current: grown)
            coordinator.discreteContentInserted(renderedID: "interaction-row")
            #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["interaction-row"])
            await frames.waitForRequest(count: 1)
            coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: grown)
            #expect(coordinator.hostedDiscreteFollowRenderedIDs.isEmpty)
            frames.releaseNext()
            #expect(coordinator.command == nil)
            #expect(coordinator.isUserInteracting)
        }
    }

    @Test("long catch-up stages and finishes on separate display frames")
    func catchUpFrameSeparation() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let farAway = ChatTranscriptGeometry(offsetY: 0, contentHeight: 1_000, containerHeight: 400)
            coordinator.geometryChanged(previous: farAway, current: farAway)
            coordinator.requestCatchUp(reduceMotion: false)
            let staged = try await coordinator.hostedNextCommand()
            guard case .offsetY = staged.destination else {
                Issue.record("expected staged point command")
                return
            }
            #expect(frames.requestCount == 0)
            coordinator.commandApplied(staged)
            await frames.waitForRequest(count: 1)
            #expect(coordinator.command == nil)
            frames.releaseNext()
            let final = try await coordinator.hostedNextCommand()
            #expect(final.destination == .tail)
            #expect(final.animation == .smooth(duration: 0.30))
        }
    }

    @Test("response during staged catch-up survives interruption as unread")
    func stagedCatchUpInterruption() {
        let farAway = ChatTranscriptGeometry(offsetY: 0, contentHeight: 1_000, containerHeight: 400)
        let coordinator = detachedCoordinator(at: farAway, withUnread: false)
        coordinator.requestCatchUp(reduceMotion: false)
        #expect(coordinator.command?.destination == .offsetY(520))
        #expect(!coordinator.hasUnreadContent)
        coordinator.semanticResponseArrived()
        #expect(coordinator.hasUnreadContent)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: farAway)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("response during final catch-up command survives interruption as unread")
    func finalCatchUpInterruption() {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        coordinator.requestCatchUp(reduceMotion: false)
        #expect(coordinator.command?.destination == .tail)
        coordinator.semanticResponseArrived()
        #expect(coordinator.hasUnreadContent)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("interaction during catch-up physical settlement restores detachment; exact boundary settles")
    func settlingCatchUpInterruptionAndSuccess() {
        let interrupted = detachedCoordinator(at: away, withUnread: false)
        interrupted.requestCatchUp(reduceMotion: true)
        #expect(interrupted.tailSettlementGeneration == 0)
        let command = interrupted.command!
        interrupted.commandApplied(command)
        interrupted.semanticResponseArrived()
        #expect(interrupted.hasUnreadContent)
        interrupted.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(interrupted.userScrolledAway)
        #expect(interrupted.hasUnreadContent)
        #expect(interrupted.tailSettlementGeneration == 0)
        #expect(interrupted.command == nil)

        let settled = detachedCoordinator(at: away)
        settled.requestCatchUp(reduceMotion: true)
        #expect(settled.hasUnreadContent)
        #expect(settled.tailSettlementGeneration == 0)
        settled.commandApplied(settled.command!)
        settled.semanticResponseArrived()
        #expect(settled.hasUnreadContent)
        settled.geometryChanged(previous: away, current: bottom)
        #expect(!settled.userScrolledAway)
        #expect(!settled.hasUnreadContent)
        #expect(settled.tailSettlementGeneration == 1)
        #expect(settled.command?.destination == .releaseBinding)
    }

    @Test("presentation reset revokes an unacknowledged opening command")
    func presentationResetRevokesCommand() {
        let coordinator = ChatScrollCoordinator()
        coordinator.resetForPresentation(1)
        coordinator.requestOpeningTail(targetRenderedID: "old-tail")
        let stale = coordinator.command
        #expect(stale?.presentation == 1)
        coordinator.discreteContentInserted(renderedID: "old-entrance")
        #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["old-entrance"])
        coordinator.resetForPresentation(2)
        #expect(coordinator.hostedDiscreteFollowRenderedIDs.isEmpty)
        let current = coordinator.command
        if let stale { coordinator.commandApplied(stale) }
        #expect(current?.destination == .resetToBottom)
        #expect(coordinator.command == current)
    }

    @Test("unrealized opening tail receives one frame-gated correction and physical proof")
    func openingTailCorrectsUnrealizedTarget() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            coordinator.resetForPresentation(1)
            coordinator.commandApplied(coordinator.command!)
            let positioning = Task { await coordinator.positionOpeningTail(targetRenderedID: "expected-tail") }

            coordinator.geometryChanged(previous: .zero, current: away)
            #expect(coordinator.command == nil)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let tail = try await coordinator.hostedNextCommand()
            #expect(tail.destination == .openingTail("expected-tail"))
            #expect(tail.origin == .presentation)
            #expect(tail.animation == .disabled)
            coordinator.geometryChanged(previous: away, current: away)
            #expect(frames.requestCount == 1)
            #expect(coordinator.command == tail)
            coordinator.commandApplied(tail)

            let overshoot = ChatTranscriptGeometry(
                offsetY: 1_200,
                contentHeight: 1_000,
                containerHeight: 400,
                visibleBottomY: 1_600
            )
            coordinator.semanticFrameChanged(
                renderedID: "expected-tail",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: -500, width: 100, height: 40)
            )
            coordinator.geometryChanged(previous: away, current: overshoot)
            #expect(coordinator.command == nil)
            #expect(!overshoot.isPlausibleOpeningViewport)

            let bottom = ChatTranscriptGeometry(
                offsetY: 600,
                contentHeight: 1_000,
                containerHeight: 400,
                visibleBottomY: 1_000
            )
            coordinator.semanticFrameChanged(
                renderedID: "expected-tail",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 350, width: 100, height: 40)
            )
            coordinator.geometryChanged(previous: overshoot, current: bottom)
            #expect(await positioning.value)

            let revealRequest = frames.requestCount + 1
            coordinator.openingRevealCompleted()
            await frames.waitForRequest(count: revealRequest)
            frames.releaseAll()
            await frames.waitForRequest(count: revealRequest + 1)
            frames.releaseAll()
            let release = try await coordinator.hostedNextCommand()
            #expect(release.destination == .releaseBinding)
        }
    }

    @Test("opening tail admits exact physical evidence in either callback order")
    func openingTailExactEvidencePermutations() {
        let geometryFirst = ChatScrollCoordinator()
        defer { geometryFirst.cancel() }
        geometryFirst.resetForPresentation(1)
        geometryFirst.commandApplied(geometryFirst.command!)
        geometryFirst.requestOpeningTail(targetRenderedID: "tail")
        geometryFirst.geometryChanged(previous: .zero, current: away)
        #expect(geometryFirst.command == nil)
        geometryFirst.semanticFrameChanged(
            renderedID: "tail",
            layoutEpoch: geometryFirst.layoutEpoch,
            frame: CGRect(x: 0, y: 900, width: 100, height: 40)
        )
        #expect(geometryFirst.command?.destination == .openingTail("tail"))

        let frameFirst = ChatScrollCoordinator()
        defer { frameFirst.cancel() }
        frameFirst.resetForPresentation(2)
        frameFirst.commandApplied(frameFirst.command!)
        frameFirst.requestOpeningTail(targetRenderedID: "tail")
        frameFirst.semanticFrameChanged(
            renderedID: "tail",
            layoutEpoch: frameFirst.layoutEpoch,
            frame: CGRect(x: 0, y: 900, width: 100, height: 40)
        )
        #expect(frameFirst.command == nil)
        frameFirst.geometryChanged(previous: .zero, current: away)
        #expect(frameFirst.command?.destination == .openingTail("tail"))
        #expect(frameFirst.command?.origin == .presentation)
    }

    @Test("opening tail leaves undersized and empty transcripts top aligned")
    func openingTailClearsForUndersizedOrEmptyTimeline() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            coordinator.resetForPresentation(1)
            coordinator.commandApplied(coordinator.command!)
            let positioning = Task { await coordinator.positionOpeningTail(targetRenderedID: "short-tail") }
            await frames.waitForRequest(count: 1)
            coordinator.semanticFrameChanged(
                renderedID: "short-tail",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 10, width: 100, height: 40)
            )
            let short = ChatTranscriptGeometry(offsetY: 0, contentHeight: 180, containerHeight: 400)
            coordinator.geometryChanged(previous: .zero, current: short)
            #expect(await positioning.value)
            #expect(coordinator.command == nil)
            let revealRequest = frames.requestCount + 1
            coordinator.openingRevealCompleted()
            await frames.waitForRequest(count: revealRequest)
            frames.releaseAll()
            await frames.waitForRequest(count: revealRequest + 1)
            frames.releaseAll()
            let release = try await coordinator.hostedNextCommand()
            #expect(release.destination == .releaseBinding)

            let empty = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            empty.resetForPresentation(2)
            let emptyReset = empty.command!
            #expect(await empty.positionOpeningTail(targetRenderedID: nil))
            empty.commandApplied(emptyReset)
            empty.geometryChanged(previous: .zero, current: away)
            #expect(empty.command == nil)
        }
    }

    @Test("native interaction cancels exact pending opening tail")
    func nativeInteractionCancelsOpeningTail() {
        let coordinator = ChatScrollCoordinator()
        coordinator.resetForPresentation(1)
        coordinator.requestOpeningTail(targetRenderedID: "tail")
        coordinator.commandApplied(coordinator.command!)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: .zero, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "tail",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 900, width: 100, height: 40)
        )
        #expect(coordinator.command == nil)
    }

    @Test("stale opening target cannot repin a replacement presentation")
    func staleOpeningLayoutCannotRepinReplacement() {
        let coordinator = ChatScrollCoordinator()
        coordinator.resetForPresentation(1)
        let staleReset = coordinator.command!
        let staleEpoch = coordinator.layoutEpoch
        coordinator.requestOpeningTail(targetRenderedID: "stale-tail")

        coordinator.resetForPresentation(2)
        let replacementReset = coordinator.command!
        coordinator.commandApplied(staleReset)
        coordinator.geometryChanged(previous: .zero, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "stale-tail",
            layoutEpoch: staleEpoch,
            frame: CGRect(x: 0, y: 900, width: 100, height: 40)
        )
        #expect(coordinator.command == replacementReset)
    }

    @Test("semantic frame projection is count bounded")
    func semanticFramesAreBounded() {
        let coordinator = ChatScrollCoordinator()
        for index in 0..<300 {
            coordinator.semanticFrameChanged(
                renderedID: "row-\(index)",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: index, width: 100, height: 40)
            )
        }
        #expect(coordinator.hostedSemanticFrameCount == 256)
    }

    @Test("Reduce Motion catch-up is one nonanimated tail command")
    func reduceMotionCatchUp() async throws {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.requestCatchUp(reduceMotion: true)
        let command = try await coordinator.hostedNextCommand()
        #expect(command.destination == .tail)
        #expect(command.animation == .disabled)
    }

    @Test("prepend growth cannot arm a later automatic tail follow")
    func prependGrowthDoesNotFollowTail() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let undersized = ChatTranscriptGeometry(
                offsetY: 0, contentHeight: 280, containerHeight: 400
            )
            coordinator.geometryChanged(previous: .zero, current: undersized)
            if let release = coordinator.command { coordinator.commandApplied(release) }
            coordinator.semanticFrameChanged(
                renderedID: "anchor",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 40, width: 100, height: 40)
            )
            let anchor = ChatSemanticAnchor(
                semanticID: "anchor", renderedID: "anchor",
                layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 40
            )
            coordinator.discreteContentInserted(renderedID: "prepend-row")
            #expect(coordinator.hostedDiscreteFollowRenderedIDs == ["prepend-row"])
            let results = ScrollResultRecorder()
            let began = coordinator.beginPrepend(
                anchor: anchor,
                load: {
                    let installed = coordinator.beginInstalledLayoutEpoch()
                    return ChatPrependPage(renderedAnchorID: "anchor", installedLayout: installed)
                },
                completion: { results.record($0) }
            )
            #expect(began)
            #expect(coordinator.hostedDiscreteFollowRenderedIDs.isEmpty)
            try await coordinator.hostedWaitForPrependSemanticSample()

            let overflow = ChatTranscriptGeometry(
                offsetY: 0, contentHeight: 800, containerHeight: 400
            )
            coordinator.geometryChanged(previous: undersized, current: overflow)
            coordinator.semanticFrameChanged(
                renderedID: "anchor",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 40, width: 100, height: 40)
            )
            #expect(results.values == [.success])
            #expect(frames.requestCount == 1)
            #expect(coordinator.command == nil)
        }
    }

    @Test("missing measured anchor discards without starting page load")
    func missingAnchorDoesNotLoad() {
        let coordinator = ChatScrollCoordinator()
        let results = ScrollResultRecorder()
        let loads = ScrollCounter()
        let began = coordinator.beginPrepend(
            anchor: nil,
            load: { loads.value &+= 1; return nil },
            completion: { results.record($0) }
        )
        #expect(!began)
        #expect(loads.value == 0)
        #expect(results.values == [.discarded])
    }

    @Test("prepend cannot overwrite catch-up command ownership")
    func prependRejectsCatchUpOverlap() throws {
        let coordinator = detachedCoordinator(at: away)
        coordinator.semanticFrameChanged(
            renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 20, width: 100, height: 40)
        )
        coordinator.requestCatchUp(reduceMotion: true)
        let catchUp = try #require(coordinator.command)
        let results = ScrollResultRecorder()
        let began = coordinator.beginPrepend(
            anchor: ChatSemanticAnchor(
                semanticID: "semantic", renderedID: "row",
                layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 20
            ),
            load: { nil },
            completion: { results.record($0) }
        )
        #expect(!began)
        #expect(results.values == [.discarded])
        #expect(coordinator.command == catchUp)
    }

    @Test("prepend cannot overlap opening-tail settlement")
    func prependRejectsOpeningOverlap() {
        let coordinator = detachedCoordinator(at: away)
        defer { coordinator.cancel() }
        coordinator.semanticFrameChanged(
            renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 20, width: 100, height: 40)
        )
        coordinator.requestOpeningTail(targetRenderedID: "expected-tail")
        let results = ScrollResultRecorder()
        let began = coordinator.beginPrepend(
            anchor: ChatSemanticAnchor(
                semanticID: "semantic", renderedID: "row",
                layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 20
            ),
            load: { nil },
            completion: { results.record($0) }
        )
        #expect(!began)
        #expect(results.values == [.discarded])
        #expect(coordinator.command == nil)
    }

    @Test("repeat prepend cannot cancel useful work")
    func prependOwnership() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 20, width: 100, height: 40)
        )
        let results = ScrollResultRecorder()
        let anchor = ChatSemanticAnchor(semanticID: "semantic", renderedID: "row", layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 20)
        let began = coordinator.beginPrepend(
            anchor: anchor,
            load: { nil },
            completion: { results.record($0) }
        )
        #expect(began)
        let repeated = coordinator.beginPrepend(anchor: anchor, load: { nil }, completion: { _ in })
        #expect(!repeated)
        coordinator.cancel()
        #expect(results.values == [.cancelled])
    }

    @Test("prepend passively waits for newer exact-epoch semantic samples after every correction")
    func prependEpochAndLateCorrection() async throws {
        try await withTestWatchdog { @MainActor in
            let coordinator = ChatScrollCoordinator()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            let anchor = ChatSemanticAnchor(
                semanticID: "semantic",
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                viewportOffsetY: 20
            )
            let results = ScrollResultRecorder()
            let oldEpoch = coordinator.layoutEpoch
            let began = coordinator.beginPrepend(anchor: anchor, load: {
                let installedLayout = coordinator.beginInstalledLayoutEpoch()
                return ChatPrependPage(
                    renderedAnchorID: "new-row",
                    installedLayout: installedLayout
                )
            }, completion: { results.record($0) })
            #expect(began)

            try await coordinator.hostedWaitForPrependSemanticSample()
            #expect(coordinator.isWaitingForPrependSemanticFrame)
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: oldEpoch,
                frame: CGRect(x: 0, y: 220, width: 100, height: 40)
            )
            #expect(coordinator.command == nil)

            let installedEpoch = coordinator.layoutEpoch
            let unchangedFrame = CGRect(x: 0, y: 220, width: 100, height: 40)
            #expect(ChatSemanticFrameObservation(layoutEpoch: oldEpoch, frame: unchangedFrame)
                != ChatSemanticFrameObservation(layoutEpoch: installedEpoch, frame: unchangedFrame))
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: installedEpoch,
                frame: unchangedFrame
            )
            #expect(coordinator.command == nil)
            coordinator.geometryChanged(previous: away, current: away)
            let first = try await coordinator.hostedNextCommand()
            #expect(first.destination == .offsetY(500))
            coordinator.commandApplied(first)
            #expect(coordinator.command == nil)
            #expect(coordinator.isWaitingForPrependSemanticFrame)

            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: oldEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            #expect(coordinator.command == nil)
            // Semantic-first settlement must wait for geometry newer than the
            // applied point correction before issuing its bounded late correction.
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: installedEpoch,
                frame: CGRect(x: 0, y: 25, width: 100, height: 40)
            )
            #expect(coordinator.command == nil)
            coordinator.geometryChanged(
                previous: away,
                current: ChatTranscriptGeometry(offsetY: 500, contentHeight: 1_000, containerHeight: 400)
            )
            let late = try await coordinator.hostedNextCommand()
            #expect(late.destination == .offsetY(505))
            coordinator.commandApplied(late)
            #expect(coordinator.command == nil)
            #expect(coordinator.isWaitingForPrependSemanticFrame)

            coordinator.geometryChanged(
                previous: ChatTranscriptGeometry(offsetY: 500, contentHeight: 1_000, containerHeight: 400),
                current: ChatTranscriptGeometry(offsetY: 505, contentHeight: 1_000, containerHeight: 400)
            )
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: installedEpoch,
                frame: CGRect(x: 0, y: 20.5, width: 100, height: 40)
            )
            try await results.waitForValue()
            #expect(results.values == [.success])
            let release = try await coordinator.hostedNextCommand()
            #expect(release.origin == .binding)
            #expect(release.destination == .releaseBinding)
            #expect(release.animation == .disabled)
            coordinator.commandApplied(release)
        }
    }

    @Test("prepend bounded failure releases its applied point binding")
    func prependFailureReleasesAppliedBinding() async throws {
        try await withTestWatchdog { @MainActor in
            let coordinator = ChatScrollCoordinator()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            let results = ScrollResultRecorder()
            let began = coordinator.beginPrepend(
                anchor: ChatSemanticAnchor(
                    semanticID: "semantic",
                    renderedID: "old-row",
                    layoutEpoch: coordinator.layoutEpoch,
                    viewportOffsetY: 20
                ),
                load: {
                    ChatPrependPage(
                        renderedAnchorID: "new-row",
                        installedLayout: coordinator.beginInstalledLayoutEpoch()
                    )
                },
                completion: { results.record($0) }
            )
            #expect(began)
            try await coordinator.hostedWaitForPrependSemanticSample()
            let epoch = coordinator.layoutEpoch

            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "new-row", layoutEpoch: epoch,
                frame: CGRect(x: 0, y: 220, width: 100, height: 40)
            )
            let first = try #require(coordinator.command)
            #expect(first.origin == .prepend)
            coordinator.commandApplied(first)

            let firstApplied = ChatTranscriptGeometry(
                offsetY: 500, contentHeight: 1_000, containerHeight: 400
            )
            coordinator.geometryChanged(previous: away, current: firstApplied)
            coordinator.semanticFrameChanged(
                renderedID: "new-row", layoutEpoch: epoch,
                frame: CGRect(x: 0, y: 30, width: 100, height: 40)
            )
            let second = try #require(coordinator.command)
            #expect(second.origin == .prepend)
            coordinator.commandApplied(second)

            let secondApplied = ChatTranscriptGeometry(
                offsetY: 510, contentHeight: 1_000, containerHeight: 400
            )
            coordinator.semanticFrameChanged(
                renderedID: "new-row", layoutEpoch: epoch,
                frame: CGRect(x: 0, y: 30, width: 100, height: 40)
            )
            #expect(coordinator.command == nil)
            coordinator.geometryChanged(previous: firstApplied, current: secondApplied)
            #expect(results.values == [.failure])
            let release = try #require(coordinator.command)
            #expect(release.origin == .binding)
            #expect(release.destination == .releaseBinding)
        }
    }

    @Test("native cancellation of applied prepend does not publish a stale release")
    func nativeCancellationDoesNotReleasePrependBinding() async throws {
        try await withTestWatchdog { @MainActor in
            let coordinator = ChatScrollCoordinator()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            let results = ScrollResultRecorder()
            let began = coordinator.beginPrepend(
                anchor: ChatSemanticAnchor(
                    semanticID: "semantic", renderedID: "old-row",
                    layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 20
                ),
                load: {
                    ChatPrependPage(
                        renderedAnchorID: "new-row",
                        installedLayout: coordinator.beginInstalledLayoutEpoch()
                    )
                },
                completion: { results.record($0) }
            )
            #expect(began)
            try await coordinator.hostedWaitForPrependSemanticSample()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "new-row", layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 220, width: 100, height: 40)
            )
            let correction = try #require(coordinator.command)
            coordinator.commandApplied(correction)

            coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
            #expect(results.values == [.discarded])
            #expect(coordinator.command == nil)
        }
    }

    @Test("prepend admits fresh paired callbacks that arrive before the page continuation returns")
    func prependSampleBeforePageReturn() async throws {
        try await withTestWatchdog { @MainActor in
            let coordinator = ChatScrollCoordinator()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            let anchor = ChatSemanticAnchor(
                semanticID: "semantic",
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                viewportOffsetY: 20
            )
            let began = coordinator.beginPrepend(anchor: anchor, load: {
                let installedLayout = coordinator.beginInstalledLayoutEpoch()
                coordinator.geometryChanged(previous: away, current: away)
                coordinator.semanticFrameChanged(
                    renderedID: "new-row",
                    layoutEpoch: installedLayout.value,
                    frame: CGRect(x: 0, y: 220, width: 100, height: 40)
                )
                return ChatPrependPage(
                    renderedAnchorID: "new-row",
                    installedLayout: installedLayout
                )
            }, completion: { _ in })
            #expect(began)

            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .offsetY(500))
            coordinator.cancel()
        }
    }

    @Test("semantic anchor correction preserves viewport offset without total-height input")
    func semanticAnchorCorrection() {
        #expect(ChatScrollCoordinator.prependCorrectionOffset(
            currentOffsetY: 300,
            capturedViewportOffsetY: 20,
            installedFrameMinY: 220
        ) == 500)
    }

    @Test("gesture interruption synchronously suppresses pending prepend commands")
    func gestureInterruptsPrepend() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 10, width: 100, height: 40)
        )
        let completed = ScrollResultRecorder()
        let began = coordinator.beginPrepend(
            anchor: ChatSemanticAnchor(semanticID: "semantic", renderedID: "row", layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 10),
            load: { nil },
            completion: { completed.record($0) }
        )
        #expect(began)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.command == nil)
        #expect(!coordinator.isPrependingHistory)
        #expect(completed.values == [.discarded])
    }

    private func detachedCoordinator(
        at geometry: ChatTranscriptGeometry,
        withUnread: Bool = true,
        frames: ManualScrollFrameScheduler? = nil
    ) -> ChatScrollCoordinator {
        let coordinator = ChatScrollCoordinator(frameScheduler: frames?.scheduler ?? .displayLink)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: geometry)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: geometry)
        if withUnread { coordinator.semanticResponseArrived() }
        return coordinator
    }
}

private func installedToolTranscript(
    ids: [String],
    statuses: [ToolExecutionState.Status],
    timelineGeneration: Int
) throws -> InstalledChatTranscript {
    var snapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data("""
    {
      "sessionId":"scroll-session","runtimeGeneration":"runtime","revision":1,"eventSequence":1,"phase":"running","cwd":"/workspace",
      "model":{"provider":"test","id":"model"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
      "stats":{"userMessages":0,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
      "queued":{"steering":[],"followUp":[]},"transcript":[],"transcriptStart":0,"transcriptTotal":0,
      "toolExecutions":[],"extensionUI":{"statuses":{},"working":{"visible":false},"widgets":[],"editorRevision":0,"editorText":"","pendingInteractions":[]},"diagnostics":[]
    }
    """.utf8))
    snapshot.eventSequence = timelineGeneration
    snapshot.toolExecutions = zip(ids, statuses).enumerated().map { index, pair in
        ToolExecutionState(
            toolCallId: pair.0,
            toolName: "read",
            order: index,
            status: pair.1,
            arguments: .object([:]),
            partialResult: nil,
            result: pair.1 == .completed ? .object(["ok": .bool(true)]) : nil,
            output: pair.1 == .completed ? "done" : nil,
            isError: false,
            startedAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z",
            lastProgressAt: "2026-01-01T00:00:01Z",
            completedAt: pair.1 == .completed ? "2026-01-01T00:00:01Z" : nil,
            durationMs: pair.1 == .completed ? 1_000 : nil,
            progressSequence: pair.1 == .completed ? 2 : 1
        )
    }
    let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
    let tag = ChatTranscriptProjectionTag(
        snapshot: snapshot,
        presentationGeneration: 1,
        canonicalGeneration: 1,
        timelineGeneration: timelineGeneration
    )
    return InstalledChatTranscript(
        tag: tag,
        timeline: candidate.timeline,
        runtimeItems: candidate.runtimeItems,
        sourceWindow: .init(snapshot: snapshot)
    )
}

@MainActor
private final class ScrollCounter {
    var value = 0
}

@MainActor
private final class ScrollResultRecorder {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private(set) var values: [PerformanceResult] = []
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0

    func record(_ value: PerformanceResult) {
        values.append(value)
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    func waitForValue() async throws {
        guard values.isEmpty else { return }
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    private func cancel(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ManualScrollFrameScheduler {
    private struct RequestWaiter {
        let id: Int
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextContinuationID = 0
    private var requestWaiters: [RequestWaiter] = []
    private var nextRequestWaiterID = 0
    private(set) var requestCount = 0

    lazy var scheduler = DisplayFrameScheduler { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.wait()
    }

    private func wait() async throws {
        let id = nextContinuationID
        nextContinuationID &+= 1
        requestCount &+= 1
        let ready = requestWaiters.filter { $0.targetCount <= requestCount }
        requestWaiters.removeAll { $0.targetCount <= requestCount }
        ready.forEach { $0.continuation.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { continuations[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    func waitForRequest(count: Int) async {
        guard requestCount < count else { return }
        let id = nextRequestWaiterID
        nextRequestWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else {
                    requestWaiters.append(.init(
                        id: id,
                        targetCount: count,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRequestWaiter(id: id) }
        }
    }

    func releaseNext() {
        guard let id = continuations.keys.min(), let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    func releaseAll() {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    private func cancel(id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelRequestWaiter(id: Int) {
        guard let index = requestWaiters.firstIndex(where: { $0.id == id }) else { return }
        requestWaiters.remove(at: index).continuation.resume()
    }
}
