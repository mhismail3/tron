import Foundation
import Observation
import Testing
@testable import TronMobile

private final class EventFixtureBundleMarker {}

@Suite("Authoritative gateway event projection")
@MainActor
struct AppModelEventTests {
    @Test("package completion notices distinguish success from failure")
    func packageCompletionNoticeOutcome() async {
        let model = AppModel()
        await model.handle(GatewayEvent(
            type: "event",
            topic: "packages.completed",
            sessionId: nil,
            payload: .object([
                "success": .bool(false),
                "error": .string("spawn npm ENOENT"),
            ])
        ))
        #expect(model.noticeCenter.notices.first?.role == .error)
        #expect(model.noticeCenter.notices.first?.title == "Package operation failed: spawn npm ENOENT")

        await model.handle(GatewayEvent(
            type: "event",
            topic: "packages.completed",
            sessionId: nil,
            payload: .object(["success": .bool(true)])
        ))
        #expect(model.noticeCenter.notices.first?.role == .success)
        #expect(model.noticeCenter.notices.first?.title == "Package operation completed")
    }

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

    @Test("held session synchronization does not block unrelated control event intake")
    func heldSessionSyncLeavesControlIntakeLive() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let model = AppModel(client: client)
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        let connected = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
        try await socket.waitUntilSent(count: 1)
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
        try await connected.value

        let snapshot = try SessionScenarioBuilder(seed: 9_301).openingTail(targetEncodedBytes: 4_096)
        model.installHostedSubscribedSnapshot(snapshot)
        let target = try #require(model.presentationTarget(for: snapshot.sessionId))
        var gap = snapshot
        gap.eventSequence += 2
        gap.revision += 2
        let encodedSnapshot = try JSONEncoder.gateway.encode(gap)
        let snapshotValue = try JSONDecoder.gateway.decode(JSONValue.self, from: encodedSnapshot)
        await socket.enqueue(Self.eventFrame(topic: "session.snapshot", sessionID: snapshot.sessionId, payload: snapshotValue))
        try await socket.waitUntilSent(count: 2)
        #expect(!model.admitsLiveSessionCommands(target))
        let settingsBefore = model.settingsInvalidationGeneration
        let providersBefore = model.providerInvalidationGeneration
        let delivered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withObservationTracking { _ = model.providerInvalidationGeneration } onChange: {
            delivered.continuation.yield(())
            delivered.continuation.finish()
        }
        await socket.enqueue(Self.eventFrame(topic: "settings.changed", sessionID: nil, payload: .object([:])))
        await socket.enqueue(Self.eventFrame(topic: "providers.changed", sessionID: nil, payload: .object([:])))
        try await withTestWatchdog {
            var iterator = delivered.stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
        }
        #expect(model.settingsInvalidationGeneration > settingsBefore)
        #expect(model.providerInvalidationGeneration > providersBefore)
        await model.teardown()
        await client.close()
    }

    @Test("failed event or foreground resync retains the healthy socket and retries only its conversation", arguments: [false, true])
    func resyncFailureHasScopedRecovery(foreground: Bool) async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let model = AppModel(client: client)
            do {
                let profile = GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device")
                await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#.utf8))
                try await model.connectHostedGateway(profile: profile, token: "fixture")
                let snapshot = try SessionScenarioBuilder(seed: 9302).openingTail(targetEncodedBytes: 4096)
                model.installHostedSubscribedSnapshot(snapshot)
                let target = try #require(model.presentationTarget(for: snapshot.sessionId))
                let reconciliation = foreground ? model.becameActive() : nil
                if !foreground {
                    await socket.enqueue(Self.eventFrame(topic: "transport.resyncRequired", sessionID: snapshot.sessionId, payload: .object([:])))
                }
                try await socket.waitUntilSent(count: 2)
                let open = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[1])
                let id = try #require(open.objectValue?["id"]?.stringValue)
                // These invalidations join the in-flight transaction. Its
                // failure cannot turn them into a fresh automatic transaction.
                for _ in 0..<5 { await model.handle(GatewayEvent(type: "event", topic: "transport.resyncRequired", sessionId: snapshot.sessionId, payload: .object([:]))) }
                let noticed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                withObservationTracking { _ = model.visibleNotices } onChange: { noticed.continuation.yield(()); noticed.continuation.finish() }
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(id), "ok": .bool(false),
                    "error": .object(["code": .string("response_too_large"), "message": .string("fixture"), "retryable": .bool(false)])
                ])))
                var noticeIterator = noticed.stream.makeAsyncIterator()
                _ = await noticeIterator.next()
                await reconciliation?.value
                #expect(model.connectionState == .connected)
                #expect(!model.visibleNotices.contains { $0.replacement?.key == .gatewayRecovery })
                #expect(await socket.closeInvocationCount() == 0)
                let notice = try #require(model.noticeCenter.notices.first { $0.replacement?.key == .sessionCatchUp })
                #expect(notice.lifetime == .automatic(.seconds(12)))
                #expect(!model.admitsLiveSessionCommands(target))
                #expect(model.selectedSnapshot?.transcript.map(\.id) == snapshot.transcript.map(\.id))
                for _ in 0..<20 { await model.handle(GatewayEvent(type: "event", topic: "transport.resyncRequired", sessionId: snapshot.sessionId, payload: .object([:]))) }
                #expect(await socket.sentFrames().count == 2)
                // Recovery belongs to Manage Session, not the transient notice.
                let retryTask = Task { await model.retryConversationSynchronization(target: target) }
                defer { retryTask.cancel() }
                try await socket.waitUntilSent(count: 3)
                let retried = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[2])
                let snapshotValue = try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(snapshot))
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": retried.objectValue!["id"]!, "ok": .bool(true),
                    "result": .object(["session": snapshotValue, "syncToken": .string("retry-token"), "subscriptionToken": .string("retry-token"), "completionRevision": .number(0)])
                ])))
                try await socket.waitUntilSent(count: 4)
                let sync = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[3])
                let installed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                withObservationTracking { _ = model.admitsLiveSessionCommands(target) } onChange: { installed.continuation.yield(()); installed.continuation.finish() }
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": sync.objectValue!["id"]!, "ok": .bool(true), "result": .object(["synchronized": .bool(true)])
                ])))
                var installation = installed.stream.makeAsyncIterator()
                _ = await installation.next()
                #expect(model.hasMountedSessionAuthority(target))
            } catch { await client.close(); await model.teardown(); throw error }
            await client.close(); await model.teardown()
        }
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
        let activityRevision = (snapshot.liveActivityRevision ?? 0) + 1
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
                "liveActivityRevision": .number(Double(activityRevision)),
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
        #expect(model.selectedSnapshot?.liveActivityRevision == activityRevision)
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
            "version": .number(3), "hostEpoch": .string("fixture-host-epoch"),
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
            "version": .number(3), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(11),
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
            "version": .number(3), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
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
                "version": .number(3), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
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
                "version": .number(3), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
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

    @Test("session.open requires explicit subscription ownership")
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

        let fresh = SessionPresentationStore.installingSnapshot(
            current: expanded,
            authoritative: authoritative,
            mode: .freshPresentation
        )
        #expect(fresh.transcript.map(\.id) == authoritative.transcript.map(\.id))
        #expect(fresh.transcriptStart == 15)

        let reconnected = SessionPresentationStore.installingSnapshot(
            current: expanded,
            authoritative: authoritative,
            mode: .reconnect
        )
        #expect(reconnected.transcript.count >= authoritative.transcript.count)
        #expect(reconnected.eventSequence == authoritative.eventSequence)

        var stale = authoritative
        stale.eventSequence = expanded.eventSequence - 1
        stale.runtimeGeneration = expanded.runtimeGeneration
        let rejectedStale = SessionPresentationStore.installingSnapshot(
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

    @Test("knowledge invalidations advance the live dashboard revision")
    func knowledgeInvalidation() async {
        let model = AppModel()
        let before = model.knowledgeInvalidationRevision
        await model.handle(GatewayEvent(
            type: "event", topic: "knowledge.changed", sessionId: nil,
            payload: .object([:])
        ))
        #expect(model.knowledgeInvalidationRevision == before + 1)
    }

    @Test("alternating active summaries update rows without changing their order")
    func activeDashboardOrderIsStable() async {
        let model = AppModel()
        model.sessions = [
            SessionSummary(
                id: "older-active", name: "Older", cwd: "/workspace", parentSessionId: nil,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:10:00Z",
                activeSince: "2026-01-01T00:00:00Z", messageCount: 1,
                firstMessage: "Older", phase: .running, summaryRevision: 1
            ),
            SessionSummary(
                id: "newer-active", name: "Newer", cwd: "/workspace", parentSessionId: nil,
                createdAt: "2026-01-01T00:05:00Z", updatedAt: "2026-01-01T00:09:00Z",
                activeSince: "2026-01-01T00:05:00Z", messageCount: 1,
                firstMessage: "Newer", phase: .running, summaryRevision: 1
            ),
        ]
        #expect(model.visibleSessions.map(\.id) == ["newer-active", "older-active"])

        for (sessionID, revision, timestamp) in [
            ("older-active", 2, "2026-01-01T00:20:00Z"),
            ("newer-active", 2, "2026-01-01T00:21:00Z"),
            ("older-active", 3, "2026-01-01T00:22:00Z"),
        ] {
            await model.handle(GatewayEvent(
                type: "event", topic: "session.summary", sessionId: nil,
                payload: .object([
                    "sessionId": .string(sessionID), "summaryRevision": .number(Double(revision)),
                    "phase": .string("running"),
                    "updatedAt": .string(timestamp),
                    "activeSince": .string(sessionID == "older-active"
                        ? "2026-01-01T00:00:00Z"
                        : "2026-01-01T00:05:00Z"),
                    "messageCount": .number(Double(revision)), "firstMessage": .string(sessionID),
                ])
            ))
            #expect(model.visibleSessions.map(\.id) == ["newer-active", "older-active"])
        }

        await model.handle(GatewayEvent(
            type: "event", topic: "session.summary", sessionId: nil,
            payload: .object([
                "sessionId": .string("newer-active"), "summaryRevision": .number(3),
                "phase": .string("idle"), "updatedAt": .string("2026-01-01T00:23:00Z"),
                "messageCount": .number(3), "firstMessage": .string("newer-active"),
            ])
        ))
        #expect(model.visibleSessions.map(\.id) == ["older-active", "newer-active"])
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

    @Test("unrendered sequenced events still advance the authoritative cursor without creating app notices")
    func unrenderedEventsAdvanceCursor() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.installHostedSubscribedSnapshot(snapshot)

        await model.handle(event(topic: "session.futureEvent", snapshot: snapshot, sequence: 88, data: .object([:])))
        await model.handle(event(topic: "session.extensionPresentation", snapshot: snapshot, sequence: 89, data: .object([
            "version": .number(3), "hostEpoch": .string("fixture-host-epoch"), "revision": .number(10),
            "notification": .object(["type": .string("info"), "message": .string("Caught up")]),
        ])))

        #expect(model.selectedSnapshot?.eventSequence == 89)
        #expect(model.visibleNotices.allSatisfy { $0.title != "Caught up" })
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

    @Test("transport loss detaches provider prompt presentation before resumable reconnect")
    func authPresentationDetachesOnDisconnect() async {
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
        var received: [ProcessTranscriptChanged] = []
        let sink = model.registerProcessTranscriptInvalidationSink { received.append($0) }
        await model.handle(changed)
        await model.handle(changed)
        #expect(received.map(\.leaseId) == ["lease-1", "lease-1"])
        model.removeProcessTranscriptInvalidationSink(sink)
        await model.handle(changed)
        #expect(received.count == 2)

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

    private static func eventFrame(topic: String, sessionID: String?, payload: JSONValue) -> Data {
        var object: [String: JSONValue] = [
            "type": .string("event"),
            "topic": .string(topic),
            "payload": payload,
        ]
        if let sessionID { object["sessionId"] = .string(sessionID) }
        return try! JSONEncoder.gateway.encode(JSONValue.object(object))
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
        let url = bundle.url(forResource: "session-snapshot-v4", withExtension: "json")
            ?? bundle.url(forResource: "session-snapshot-v4", withExtension: "json", subdirectory: "protocol-fixtures")
        return try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data(contentsOf: #require(url)))
    }
}
