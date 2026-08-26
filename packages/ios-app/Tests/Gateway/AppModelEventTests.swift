import Foundation
import Testing
@testable import TronMobile

private final class EventFixtureBundleMarker {}

@Suite("Authoritative gateway event projection")
@MainActor
struct AppModelEventTests {
    @Test("onboarding waits for launch credential resolution")
    func onboardingLaunchResolution() {
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: false,
            connectionState: .unpaired,
            setupComplete: true
        ))
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: true
        ))
        #expect(OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .unpaired,
            setupComplete: true
        ))
        #expect(OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: false
        ))
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: false,
            suppressSetup: true
        ))
    }

    @Test("compact extension activity deltas update the hub without rebuilding chat")
    func compactExtensionActivityDelta() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)
        let initialProjection = try #require(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        ))
        let activity: JSONValue = .object([
            "id": .string("tool:subagent"),
            "activityId": .string("extension-activity:test"),
            "runId": .string("run-test"),
            "toolCallId": .string("tool:subagent"),
            "source": .object([
                "source": .string("npm:pi-subagents@test"),
                "owner": .object([
                    "id": .string("extension:test"),
                    "title": .string("Subagents"),
                    "source": .string("npm:pi-subagents@test"),
                ]),
            ]),
            "title": .string("subagent"),
            "mode": .string("workflow"),
            "status": .string("running"),
            "startedAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:01.000Z"),
            "currentTool": .string("bash"),
            "children": .array([]),
            "lifecycle": .object([
                "version": .number(1),
                "state": .string("running"),
                "attention": .string("none"),
                "sequence": .number(1),
                "observedAt": .string("2026-01-01T00:00:01.000Z"),
                "visibility": .string("current"),
            ]),
        ])
        await model.handle(event(
            topic: "session.extensionActivity",
            snapshot: snapshot,
            sequence: snapshot.eventSequence + 1,
            data: .object([
                "activity": activity,
                "liveActivityRevision": .number(1),
                "extensionActivityAsOf": .string("2026-01-01T00:00:01.000Z"),
            ])
        ))
        #expect(model.selectedSnapshot?.extensionActivities?.first?.stableID == "extension-activity:test")
        #expect(model.selectedSnapshot?.extensionActivities?.first?.currentTool == "bash")
        let afterDelta = try #require(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        ))
        #expect(afterDelta == initialProjection)

        var staleFullFrame = snapshot
        staleFullFrame.eventSequence = snapshot.eventSequence + 2
        staleFullFrame.revision = snapshot.revision + 2
        staleFullFrame.liveActivityRevision = 0
        staleFullFrame.extensionActivityAsOf = "2026-01-01T00:00:00.000Z"
        staleFullFrame.extensionActivities = nil
        await model.handle(snapshotEvent(staleFullFrame, sessionID: snapshot.sessionId))
        #expect(model.selectedSnapshot?.extensionActivities?.first?.stableID == "extension-activity:test")
        #expect(model.selectedSnapshot?.liveActivityRevision == 1)
    }

    @Test("process deltas atomically update overview without rebuilding chat")
    func compactProcessDelta() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)
        let initialProjection = try #require(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        ))
        let processRevision = (snapshot.processOverview?.revision ?? 0) + 1
        let previousProcessIDs = snapshot.processActivities?.map(\.processId) ?? []
        let process: JSONValue = .object([
            "version": .number(1),
            "processId": .string("subagent:delta-call"),
            "kind": .string("subagent"),
            "executionMode": .string("asynchronous"),
            "source": .string("delegatedAgent"),
            "lifecycle": .object([
                "version": .number(1),
                "state": .string("running"),
                "attention": .string("none"),
                "sequence": .number(10),
                "observedAt": .string("2026-01-01T00:00:01Z"),
            ]),
            "visibility": .string("active"),
            "title": .string("worker"),
            "startedAt": .string("2026-01-01T00:00:00Z"),
            "outputTail": .string("running"),
            "outputTruncated": .bool(false),
            "toolCallId": .string("delta-call"),
            "runId": .string("run-1"),
        ])
        let overview: JSONValue = .object([
            "version": .number(1),
            "revision": .number(Double(processRevision)),
            "asOf": .string("2026-01-01T00:00:01Z"),
            "activeCount": .number(1),
            "recentCount": .number(0),
            "problemCount": .number(0),
            "visibility": .string("active"),
        ])
        await model.handle(event(
            topic: "session.processActivity",
            snapshot: snapshot,
            sequence: snapshot.eventSequence + 1,
            data: .object([
                "activity": process,
                "removedProcessIds": .array(previousProcessIDs.map(JSONValue.string)),
                "processRevision": .number(Double(processRevision)),
                "processAsOf": .string("2026-01-01T00:00:01Z"),
                "overview": overview,
            ])
        ))
        #expect(model.selectedSnapshot?.processOverview?.activeCount == 1)
        #expect(model.selectedSnapshot?.processActivities?.map(\.processId) == ["subagent:delta-call"])
        #expect(model.selectedSnapshot?.processActivities?.first?.title == "worker")
        let afterDelta = try #require(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        ))
        #expect(afterDelta == initialProjection)
    }

    @Test("settled launcher removal keeps asynchronous child solving")
    func settledLauncherKeepsAsyncChildActive() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)
        let firstRevision = (snapshot.processOverview?.revision ?? 0) + 1
        let previousProcessIDs = snapshot.processActivities?.map(\.processId) ?? []
        let childID = "subagent:async-child"
        let child: JSONValue = .object([
            "version": .number(1),
            "processId": .string(childID),
            "kind": .string("subagent"),
            "executionMode": .string("asynchronous"),
            "source": .string("delegatedAgent"),
            "lifecycle": .object([
                "version": .number(1),
                "state": .string("running"),
                "attention": .string("none"),
                "sequence": .number(4),
                "observedAt": .string("2026-01-01T00:00:04Z"),
            ]),
            "visibility": .string("active"),
            "title": .string("Subagent"),
            "outputTruncated": .bool(false),
            "runId": .string("async-child"),
        ])
        func overview(_ revision: Int) -> JSONValue {
            .object([
                "version": .number(1),
                "revision": .number(Double(revision)),
                "asOf": .string("2026-01-01T00:00:04Z"),
                "activeCount": .number(1),
                "recentCount": .number(0),
                "problemCount": .number(0),
                "visibility": .string("active"),
            ])
        }
        await model.handle(event(
            topic: "session.processActivity",
            snapshot: snapshot,
            sequence: snapshot.eventSequence + 1,
            data: .object([
                "activity": child,
                "removedProcessIds": .array(previousProcessIDs.map(JSONValue.string)),
                "processRevision": .number(Double(firstRevision)),
                "processAsOf": .string("2026-01-01T00:00:04Z"),
                "overview": overview(firstRevision),
            ])
        ))
        let secondRevision = firstRevision + 1
        await model.handle(event(
            topic: "session.processActivity",
            snapshot: snapshot,
            sequence: snapshot.eventSequence + 2,
            data: .object([
                "removedProcessIds": .array([.string("command:settled-launcher")]),
                "processRevision": .number(Double(secondRevision)),
                "processAsOf": .string("2026-01-01T00:00:04Z"),
                "overview": overview(secondRevision),
            ])
        ))
        #expect(model.selectedSnapshot?.processOverview?.visibility == .active)
        #expect(model.selectedSnapshot?.processActivities?.map(\.processId) == [childID])
        #expect(model.selectedSnapshot?.processActivities?.first?.executionMode == .asynchronous)
    }

    @Test("portable tool and extension events update native session state in sequence")
    func portableSessionEvents() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)
        let mountedTarget = AppModel.SessionPresentationTarget(
            sessionID: snapshot.sessionId,
            generation: 1
        )
        let composerScope = model.composerDrafts.installHostedPresentation(
            profileID: "hosted",
            target: mountedTarget,
            lifecycleGeneration: 0
        )
        let initialProjection = try #require(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        ))

        let completedTool: JSONValue = .object([
            "toolCallId": .string("live-tool"), "toolName": .string("bash"), "order": .number(0), "status": .string("completed"),
            "arguments": .object(["command": .string("build")]), "result": .object(["content": .string("done")]),
            "output": .string("done"), "isError": .bool(false),
            "startedAt": .string("2026-01-01T00:00:10Z"), "updatedAt": .string("2026-01-01T00:00:12Z"),
            "lastProgressAt": .string("2026-01-01T00:00:12Z"), "completedAt": .string("2026-01-01T00:00:12Z"),
            "durationMs": .number(2_000), "progressSequence": .number(4),
        ])
        await model.handle(event(topic: "session.toolProgress", snapshot: snapshot, sequence: 88, data: completedTool))
        #expect(model.selectedSnapshot?.toolExecutions.first?.status == .completed)
        let completedProjection = try #require(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        ))
        #expect(completedProjection.canonical == initialProjection.canonical)
        #expect(completedProjection.timeline == initialProjection.timeline + 1)

        let staleTool: JSONValue = .object([
            "toolCallId": .string("live-tool"), "toolName": .string("bash"), "order": .number(0), "status": .string("running"),
            "arguments": .object(["command": .string("build")]), "isError": .bool(false),
            "startedAt": .string("2026-01-01T00:00:10Z"), "updatedAt": .string("2026-01-01T00:00:13Z"),
            "lastProgressAt": .string("2026-01-01T00:00:13Z"), "progressSequence": .number(3),
        ])
        await model.handle(event(topic: "session.toolProgress", snapshot: snapshot, sequence: 89, data: staleTool))
        #expect(model.selectedSnapshot?.toolExecutions.first?.status == .completed)
        #expect(model.selectedSnapshot?.toolExecutions.first?.output == "done")
        #expect(model.selectedSnapshot?.toolExecutions.first?.durationMs == 2_000)
        #expect(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        )?.timeline == completedProjection.timeline)

        let interactions: JSONValue = .object([
            "version": .number(2), "hostEpoch": .string("fixture-host-epoch"),
            "revision": .number(10),
            "interactionList": .array([
                .object([
                    "id": .string("confirm"), "hostEpoch": .string("fixture-host-epoch"),
                    "presentationRevision": .number(10), "method": .string("confirm"),
                    "title": .string("Proceed?"), "message": .string("Check"),
                ]),
            ]),
        ])
        var afterStale = snapshot
        afterStale.eventSequence = 89
        await model.handle(event(topic: "session.extensionPresentation", snapshot: afterStale, sequence: 90, data: interactions))
        #expect(model.selectedSnapshot?.extensionPresentation.pendingInteractions.first?.method == .confirm)
        #expect(model.chatProjectionGenerations(
            for: snapshot.sessionId,
            presentationGeneration: 1
        )?.timeline == completedProjection.timeline)

        let editor: JSONValue = .object([
            "version": .number(2), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(11),
            "semantic": .object([
                "editorAction": .string("set"), "editorDelta": .string("replacement"),
                "editorText": .string("replacement"), "editorRevision": .number(4),
            ]),
        ])
        var afterInteraction = snapshot
        afterInteraction.eventSequence = 90
        await model.handle(event(topic: "session.extensionPresentation", snapshot: afterInteraction, sequence: 91, data: editor))
        #expect(model.composerDrafts.editorRequest(for: mountedTarget) == nil)
        #expect(model.composerDrafts.text(for: composerScope) == "replacement")
        #expect(model.selectedSnapshot?.extensionPresentation.semanticState.editorText == "replacement")
        #expect(model.selectedSnapshot?.eventSequence == 91)
    }

    @Test("editor debounce and native echoes remain presentation scoped")
    func editorSynchronizationScope() async throws {
        var snapshot = try loadSnapshot()
        snapshot.extensionPresentation.hostEpoch = "fixture-host-epoch"
        snapshot.extensionPresentation.revision = 9
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)
        let firstTarget = AppModel.SessionPresentationTarget(sessionID: snapshot.sessionId, generation: 1)
        let firstScope = model.composerDrafts.installHostedPresentation(
            profileID: "hosted", target: firstTarget, lifecycleGeneration: 0
        )
        model.composerDrafts.setText("local", for: firstScope)

        await model.handle(event(topic: "session.extensionPresentation", snapshot: snapshot, sequence: snapshot.eventSequence + 1, data: .object([
            "version": .number(2), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
            "semantic": .object([
                "editorAction": .string("native"), "editorOperationId": .string("local-operation"),
                "editorDelta": .string("local"), "editorText": .string("local"), "editorRevision": .number(4),
            ]),
        ])))
        #expect(model.composerDrafts.editorRequest(for: firstTarget) == nil)

        model.scheduleExtensionEditorUpdate(target: firstTarget, text: "old presentation")
        model.revokePresentationIntake(firstTarget)
        snapshot.eventSequence += 2
        snapshot.extensionPresentation.revision = 10
        model.installHostedSubscribedSnapshot(snapshot)
        let secondTarget = AppModel.SessionPresentationTarget(sessionID: snapshot.sessionId, generation: 2)
        let secondScope = model.composerDrafts.installHostedPresentation(
            profileID: "hosted", target: secondTarget, lifecycleGeneration: 0
        )
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.composerDrafts.text(for: secondScope) == "local")
        #expect(model.visibleNotices.isEmpty)
    }

    @Test("prepared snapshots install while malformed inner DTOs keep reducer semantics")
    func preparedPayloadCompatibility() async throws {
        var snapshot = try loadSnapshot()
        snapshot.extensionPresentation.semanticState.widgets = [ExtensionWidget(
            key: "existing",
            lines: ["old"],
            placement: .aboveEditor
        )]
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)

        await model.handle(event(
            topic: "session.extensionPresentation",
            snapshot: snapshot,
            sequence: snapshot.eventSequence + 1,
            data: .object([
                "version": .number(2), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
                "interactionList": .array([.object([
                    "id": .string("unscoped"), "method": .string("confirm"), "title": .string("Invalid"),
                ])]),
            ])
        ))
        #expect(model.selectedSnapshot?.extensionPresentation.pendingInteractions.first?.id != "unscoped")
        #expect(model.selectedSnapshot?.eventSequence == snapshot.eventSequence)

        await model.handle(event(
            topic: "session.extensionPresentation",
            snapshot: snapshot,
            sequence: snapshot.eventSequence + 1,
            data: .object([
                "version": .number(2), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
                "surfaceUpserts": .array([.object([
                    "id": .string("existing"), "kind": .string("widget"),
                    "lifecycle": .string("retained"), "revision": .number(1),
                    "focused": .bool(false), "inputMode": .string("none"),
                    "frame": .object(["width": .number(20), "height": .number(0), "lines": .array([]), "plainText": .string("fallback")]),
                ])]),
            ])
        ))
        #expect(model.selectedSnapshot?.extensionPresentation.semanticState.widgets.first?.lines == ["old"])
        #expect(model.selectedSnapshot?.eventSequence == snapshot.eventSequence)

        var afterWidget = try #require(model.selectedSnapshot)
        await model.handle(event(
            topic: "session.toolProgress",
            snapshot: afterWidget,
            sequence: afterWidget.eventSequence + 1,
            data: .object(["toolCallId": .string("incomplete")])
        ))
        #expect(model.selectedSnapshot?.eventSequence == afterWidget.eventSequence)

        let admittedBeforeSnapshot = afterWidget
        if let target = model.mountedPresentationTarget {
            model.revokePresentationIntake(target)
        }
        afterWidget.eventSequence += 1
        afterWidget.phase = .running
        await model.handle(GatewayEvent(
            type: "event",
            topic: "session.snapshot",
            sessionId: snapshot.sessionId,
            payload: try JSONValue.encode(afterWidget)
        ))
        #expect(model.selectedSnapshot == admittedBeforeSnapshot)
    }

    @Test("live snapshot events reject stale, duplicate, replacement-runtime, and mismatched payloads")
    func liveSnapshotAdmission() async throws {
        let current = try loadSnapshot()
        let model = AppModel()
        model.installHostedSnapshotWithoutPresentation(current)

        var duplicate = current
        duplicate.phase = current.phase == .running ? .idle : .running
        duplicate.name = "duplicate cursor"
        await model.handle(snapshotEvent(duplicate, sessionID: current.sessionId))
        #expect(model.selectedSnapshot == current)

        var stale = current
        stale.eventSequence -= 1
        stale.name = "stale cursor"
        await model.handle(snapshotEvent(stale, sessionID: current.sessionId))
        #expect(model.selectedSnapshot == current)

        var replacement = current
        replacement.runtimeGeneration = "replacement-runtime"
        replacement.eventSequence = 1
        replacement.name = "replacement without sync"
        await model.handle(snapshotEvent(replacement, sessionID: current.sessionId))
        #expect(model.selectedSnapshot == current)

        var mismatched = current
        mismatched.eventSequence += 1
        mismatched.name = "wrong route"
        await model.handle(snapshotEvent(mismatched, sessionID: "other-session"))
        #expect(model.selectedSnapshot == current)
        #expect(model.selectedSnapshot?.sessionId != "other-session")
    }

    @Test("v3 session.open requires explicit subscription ownership")
    func missingSessionOpenTokenIsRejected() throws {
        let snapshot = try loadSnapshot()
        #expect(throws: (any Error).self) {
            try JSONValue.object([
                "session": try JSONValue.encode(snapshot),
                "syncToken": .string("sync-token"),
            ]).decode(AppModel.SessionOpenResponse.self)
        }
    }

    @Test("explicit subscription ownership wins when the gateway sends it")
    func currentSessionOpenToken() throws {
        let snapshot = try loadSnapshot()
        let open = try JSONValue.object([
            "session": try JSONValue.encode(snapshot),
            "syncToken": .string("sync-token"),
            "subscriptionToken": .string("subscription-token"),
        ]).decode(AppModel.SessionOpenResponse.self)

        #expect(open.syncToken == "sync-token")
        #expect(open.subscriptionToken == "subscription-token")
    }

    @Test("subscription cleanup clears only the exact gateway-confirmed owner")
    func subscriptionOwnership() {
        #expect(AppModel.shouldClearSubscription(
            installedToken: "current", closingToken: "current", gatewayClosed: true
        ))
        #expect(!AppModel.shouldClearSubscription(
            installedToken: "current", closingToken: "stale", gatewayClosed: true
        ))
        #expect(!AppModel.shouldClearSubscription(
            installedToken: "current", closingToken: "current", gatewayClosed: false
        ))
        #expect(AppModel.ownsPresentation(
            mountedGeneration: 7,
            requestedGeneration: 7
        ))
        #expect(!AppModel.ownsPresentation(
            mountedGeneration: 8,
            requestedGeneration: 7
        ))
        #expect(!AppModel.admitsPresentationIntake(
            mountedGeneration: 7,
            requestedGeneration: 7,
            isRevoked: true
        ))
        #expect(AppModel.ownsSubscription(
            sessionID: "session",
            subscribedSessionID: "session",
            installedToken: "current",
            requestedToken: "current"
        ))
        #expect(!AppModel.ownsSubscription(
            sessionID: "session",
            subscribedSessionID: "session",
            installedToken: "replacement",
            requestedToken: "stale"
        ))
        let departing = AppModel.SessionPresentationTarget(sessionID: "old", generation: 7)
        #expect(AppModel.soleAdmittedPresentationTarget(
            generations: ["old": 7],
            revoked: [departing]
        ) == nil)
        #expect(AppModel.soleAdmittedPresentationTarget(
            generations: ["old": 7, "new": 8],
            revoked: [departing]
        ) == AppModel.SessionPresentationTarget(sessionID: "new", generation: 8))
    }

    @Test("fresh presentation replaces expanded history while reconnect preserves it")
    func snapshotInstallModes() throws {
        let baseline = try loadSnapshot()
        var expanded = baseline
        expanded.transcriptStart = 10
        expanded.transcriptTotal = 10 + expanded.transcript.count
        var authoritative = baseline
        authoritative.eventSequence += 1
        authoritative.transcript = Array(baseline.transcript.suffix(3))
        authoritative.transcriptStart = 15
        authoritative.transcriptTotal = 18

        let fresh = AppModel.installingSnapshot(
            current: expanded,
            authoritative: authoritative,
            mode: .freshPresentation
        )
        #expect(fresh.transcript.map(\.id) == authoritative.transcript.map(\.id))
        #expect(fresh.transcriptStart == 15)

        let reconnected = AppModel.installingSnapshot(
            current: expanded,
            authoritative: authoritative,
            mode: .reconnect
        )
        #expect(reconnected.transcript.count >= authoritative.transcript.count)
        #expect(reconnected.eventSequence == authoritative.eventSequence)

        var stale = authoritative
        stale.eventSequence = expanded.eventSequence - 1
        stale.runtimeGeneration = expanded.runtimeGeneration
        let rejectedStale = AppModel.installingSnapshot(
            current: expanded,
            authoritative: stale,
            mode: .reconnect
        )
        #expect(rejectedStale.eventSequence == expanded.eventSequence)
        #expect(rejectedStale.transcript.map(\.id) == expanded.transcript.map(\.id))
    }

    @Test("global summaries update dashboard activity without opening that chat")
    func dashboardSummaryUpdates() async {
        let model = AppModel()
        model.sessions = [SessionSummary(
            id: "background", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1, firstMessage: "Original", phase: .idle
        )]

        await model.handle(GatewayEvent(
            type: "event", topic: "session.summary", sessionId: nil,
            payload: .object([
                "sessionId": .string("background"), "summaryRevision": .number(1), "phase": .string("running"),
                "updatedAt": .string("2026-01-01T00:00:01Z"), "messageCount": .number(2),
                "firstMessage": .string("Original")
            ])
        ))

        #expect(model.sessions.first?.phase == .running)
        #expect(model.sessions.first?.messageCount == 2)

        await model.handle(GatewayEvent(
            type: "event", topic: "session.summary", sessionId: nil,
            payload: .object([
                "sessionId": .string("background"), "summaryRevision": .number(1), "phase": .string("idle"),
                "updatedAt": .string("2026-01-01T00:00:00Z"), "messageCount": .number(1),
                "firstMessage": .string("Stale")
            ])
        ))
        #expect(model.sessions.first?.phase == .running)
        #expect(model.sessions.first?.firstMessage == "Original")
    }

    @Test("disconnect marks dashboard activity as resuming without fabricating interruption")
    func disconnectClearsLiveDashboardPhase() async {
        let model = AppModel()
        model.sessions = [SessionSummary(
            id: "active", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 1, firstMessage: "Active", phase: .running
        )]
        await model.handle(GatewayEvent(
            type: "event", topic: "transport.disconnected", sessionId: nil,
            payload: .object(["message": .string("offline")])
        ))
        #expect(model.sessions.first?.phase == .running)
        #expect(model.dashboardActivity(for: "active") == .resuming)
    }

    @Test("structure, context, and resource events invalidate their live surfaces")
    func surfaceInvalidations() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)

        await model.handle(event(topic: "session.structureChanged", snapshot: snapshot, sequence: 88, data: .object([
            "branchChanged": .bool(false)
        ])))
        #expect(model.sessionStructureRevision(for: snapshot.sessionId) == 1)
        #expect(model.sessionContextRevision(for: snapshot.sessionId) == 1)

        var advanced = snapshot
        advanced.eventSequence = 88
        await model.handle(event(topic: "session.resourcesChanged", snapshot: advanced, sequence: 89, data: .object([:])))
        #expect(model.sessionResourceRevision(for: snapshot.sessionId) == 1)
        #expect(model.sessionContextRevision(for: snapshot.sessionId) == 2)
    }

    @Test("terminal events without an attached presentation are ignored")
    func detachedTerminalEventsAreIgnored() async {
        let model = AppModel()
        await model.handle(GatewayEvent(
            type: "event",
            topic: "terminal.output",
            sessionId: nil,
            payload: .object([
                "terminalId": .string("terminal"),
                "sequence": .number(1),
                "data": .string("unowned"),
            ])
        ))
        await model.handle(GatewayEvent(
            type: "event",
            topic: "terminal.exit",
            sessionId: nil,
            payload: .object([
                "terminalId": .string("terminal"),
                "sequence": .number(2),
                "exitCode": .number(0),
            ])
        ))
        #expect(model.terminalReplay(for: "terminal") == .empty)
        #expect(!model.terminalHasExited("terminal"))
    }

    @Test("unrendered sequenced events still advance the authoritative cursor")
    func unrenderedEventsAdvanceCursor() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)

        await model.handle(event(topic: "session.futureEvent", snapshot: snapshot, sequence: 88, data: .object([:])))
        await model.handle(event(topic: "session.extensionPresentation", snapshot: snapshot, sequence: 89, data: .object([
            "version": .number(2), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
            "notification": .object(["type": .string("info"), "message": .string("Caught up")]),
        ])))

        #expect(model.selectedSnapshot?.eventSequence == 89)
        #expect(model.visibleNotices.last?.title == "Caught up")
    }

    @Test("configured default model is preferred over catalog order")
    func configuredDefaultModel() async {
        let model = AppModel()
        model.installHostedProviderCatalog(ProviderCatalog(providers: [], models: [
            ModelSummary(provider: "openai-codex", id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark", reasoning: true, input: ["text"], contextWindow: 1, maxTokens: 1, available: true),
            ModelSummary(provider: "openai-codex", id: "gpt-5.6-sol", name: "GPT-5.6 Sol", reasoning: true, input: ["text"], contextWindow: 1, maxTokens: 1, available: true),
        ]), for: .global)
        model.installHostedSettings(.object([
            "effective": .object([
                "defaultModel": .object(["provider": .string("openai-codex"), "id": .string("gpt-5.6-sol")]),
            ]),
        ]), for: .global)

        #expect(model.configuredDefaultModel(for: .global)?.id == "gpt-5.6-sol")
        #expect(model.preferredAvailableModel(for: .global)?.id == "gpt-5.6-sol")
    }

    @Test("global configuration invalidations are accepted without session sequencing")
    func globalConfigurationInvalidations() async {
        let model = AppModel()
        await model.handle(GatewayEvent(type: "event", topic: "settings.changed", sessionId: nil, payload: .object([:])))
        await model.handle(GatewayEvent(type: "event", topic: "providers.changed", sessionId: nil, payload: .object([:])))
        await model.handle(GatewayEvent(type: "event", topic: "packages.changed", sessionId: nil, payload: .object([:])))
        await model.handle(GatewayEvent(type: "event", topic: "models.customChanged", sessionId: nil, payload: .object([:])))
        // These events invalidate each scoped owner rather than being mistaken
        // for session-sequenced events. Visible surfaces then reload their scope.
        #expect(model.settingsInvalidationGeneration == 1)
        #expect(model.providerInvalidationGeneration == 1)
        #expect(model.packageInvalidationGeneration == 1)
        #expect(model.customModelInvalidationGeneration == 1)
        #expect(model.visibleNotices.isEmpty)
    }

    @Test("receipt replay admission rejects cancellation after confirmed missing")
    func receiptReplayCancellationAdmission() {
        #expect(ConfirmedMutationExecutor.admitsReplay(taskIsCancelled: false))
        #expect(!ConfirmedMutationExecutor.admitsReplay(taskIsCancelled: true))
    }

    @Test("foreground transport interruption reconnects without a user error alert")
    func foregroundTransportErrorPresentation() {
        #expect(!AppModel.shouldSurface(GatewayFailure(
            code: "disconnected",
            message: "Software caused connection abort",
            retryable: true,
            details: nil
        )))
        #expect(!AppModel.shouldSurface(URLError(.networkConnectionLost)))
        #expect(!AppModel.shouldSurface(NSError(domain: NSPOSIXErrorDomain, code: 53)))
        #expect(AppModel.shouldSurface(GatewayFailure(
            code: "invalid_request",
            message: "Choose a valid setting.",
            retryable: false,
            details: nil
        )))
    }

    @Test("cached active dashboard rows retain phase but present as resuming")
    func cachedActivityIsResuming() {
        let summary = SessionSummary(
            id: "cached", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 1, firstMessage: "Cached", phase: .running
        )
        var catalog = SessionCatalogCoordinator()
        catalog.installCached([summary])
        #expect(catalog.sessions.first?.phase == .running)
        #expect(catalog.activity(for: "cached") == .resuming)
    }

    @Test("changing sessions clears secondary projections before their authoritative reload")
    func switchingSessionClearsSecondaryProjections() {
        let model = AppModel()
        model.selectHostedCompatibilitySession("first")
        model.installHostedSecondaryProjection(
            context: .object(["session": .string("first")]),
            tree: [SessionTreeNode(
                id: "entry", parentId: nil, timestamp: "2026-01-01T00:00:00Z", kind: "message",
                label: nil, preview: "First", role: .user, depth: 0, childCount: 0, isCurrentPath: true
            )],
            resources: .object(["session": .string("first")])
        )

        model.selectHostedCompatibilitySession("second")

        #expect(model.context == nil)
        #expect(model.resources == nil)
        #expect(model.sessionTree.isEmpty)
        #expect(model.commands.isEmpty)
    }

    @Test("transport loss retires provider authentication before reconnect")
    func authPresentationRetiresOnDisconnect() async {
        let model = AppModel()
        model.installHostedProviderAuthOperation("auth-operation")
        await model.handle(GatewayEvent(
            type: "event", topic: "auth.prompt", sessionId: nil,
            payload: .object([
                "operationId": .string("auth-operation"),
                "promptId": .string("prompt"),
                "prompt": .object([
                    "type": .string("secret"),
                    "message": .string("API key"),
                ]),
            ])
        ))
        #expect(model.authPrompt?.operationId == "auth-operation")

        await model.handle(GatewayEvent(
            type: "event", topic: "transport.disconnected", sessionId: nil,
            payload: .null
        ))
        #expect(model.authPrompt == nil)
        #expect(model.authEvent == nil)
    }

    @Test("OAuth URL and device-code notifications are retained for native presentation")
    func authEvents() async {
        let model = AppModel()
        model.installHostedProviderAuthOperation("auth-operation")
        await model.handle(GatewayEvent(
            type: "event", topic: "auth.event", sessionId: nil,
            payload: .object([
                "operationId": .string("auth-operation"),
                "event": .object([
                    "type": .string("device_code"), "userCode": .string("ABCD-EFGH"),
                    "verificationUri": .string("https://example.invalid/device"), "expiresInSeconds": .number(600),
                ]),
            ])
        ))
        #expect(model.authEvent?.kind == .deviceCode)
        #expect(model.authEvent?.userCode == "ABCD-EFGH")
    }

    @Test("process transcript invalidation bypasses parent session cursor")
    func processTranscriptInvalidationIsLeaseScoped() async throws {
        let model = AppModel()
        let snapshot = try loadSnapshot()
        model.installHostedSubscribedSnapshot(snapshot)
        let changed = GatewayEvent(
            type: "event",
            topic: "session.processTranscript.changed",
            sessionId: snapshot.sessionId,
            payload: .object([
                "leaseId": .string("lease-1"),
                "processId": .string("process-1"),
                "revision": .string("revision-2"),
                "total": .number(4),
            ])
        )
        #expect(changed.sessionCursor == nil)
        guard case .processTranscriptChanged(let prepared) = changed.preparation else {
            Issue.record("expected lease-scoped process transcript invalidation")
            return
        }
        #expect(prepared.revision == "revision-2")
        await model.handle(changed)
        #expect(model.processTranscriptInvalidation?.leaseId == "lease-1")

        let closed = GatewayEvent(
            type: "event",
            topic: "session.processTranscript.changed",
            sessionId: snapshot.sessionId,
            payload: .object([
                "leaseId": .string("lease-1"),
                "processId": .string("process-1"),
                "closed": .bool(true),
                "reason": .string("observer closed"),
            ])
        )
        guard case .processTranscriptChanged(let closeFrame) = closed.preparation else {
            Issue.record("expected close invalidation without revision")
            return
        }
        #expect(closeFrame.closed == true)
    }

    private func snapshotEvent(_ snapshot: SessionSnapshot, sessionID: String) -> GatewayEvent {
        GatewayEvent(
            type: "event",
            topic: "session.snapshot",
            sessionId: sessionID,
            payload: try! JSONValue.encode(snapshot)
        )
    }

    private func event(topic: String, snapshot: SessionSnapshot, sequence: Int, data: JSONValue) -> GatewayEvent {
        GatewayEvent(type: "event", topic: topic, sessionId: snapshot.sessionId, payload: .object([
            "runtimeGeneration": .string(snapshot.runtimeGeneration),
            "eventSequence": .number(Double(sequence)),
            "revision": .number(Double(snapshot.revision + sequence)),
            "data": data,
        ]))
    }

    private func loadSnapshot() throws -> SessionSnapshot {
        let bundle = Bundle(for: EventFixtureBundleMarker.self)
        let url = bundle.url(forResource: "session-snapshot-v3", withExtension: "json")
            ?? bundle.url(forResource: "session-snapshot-v3", withExtension: "json", subdirectory: "protocol-fixtures")
        return try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data(contentsOf: #require(url)))
    }
}
