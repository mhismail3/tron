import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Session presentation ownership")
struct SessionPresentationStoreTests {
    @Test("AppModel authoritative snapshot façade remains observable")
    func observationForwarding() throws {
        let model = AppModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.authoritativeSnapshot(for: "session")
        } onChange: {
            changed.withLock { $0 = true }
        }
        let snapshot = try SessionScenarioBuilder(seed: 81).openingTail(targetEncodedBytes: 4_096)
        model.installHostedAuthoritativeSnapshot(snapshot)
        #expect(changed.withLock { $0 })
        #expect(model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot)
    }

    @Test("cold cached snapshots never acquire live authority")
    func coldSnapshotIsNotAuthoritative() throws {
        let model = AppModel()
        let snapshot = try SessionScenarioBuilder(seed: 82).openingTail(targetEncodedBytes: 4_096)
        model.installHostedSnapshotWithoutPresentation(snapshot)
        #expect(model.authoritativeSnapshot(for: snapshot.sessionId) == nil)
        #expect(model.mountedPresentationTarget == nil)
    }

    @Test("disconnect retires lease authority while profile reset clears the projection")
    func disconnectAndProfileReset() throws {
        let snapshot = try SessionScenarioBuilder(seed: 83).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedAuthoritativeSnapshot(snapshot)
        let target = try #require(store.mountedTarget)
        store.retireConnection()
        #expect(store.mountedTarget == target)
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == snapshot)
        #expect(!store.hasInstalledSubscription(for: snapshot.sessionId))

        store.clearProfile()
        #expect(store.mountedTarget == nil)
        #expect(store.snapshot == nil)
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == nil)
    }

    @Test("confirmed queue clear removes both rich and legacy projections")
    func confirmedQueueClear() throws {
        var snapshot = try SessionScenarioBuilder(seed: 84).openingTail(targetEncodedBytes: 4_096)
        snapshot.queued = .init(steering: ["duplicate", "duplicate"], followUp: ["later"])
        snapshot.queueRevision = 7
        snapshot.queuedItems = [
            .init(id: "first", behavior: .steer, text: "duplicate", attachmentCount: 0),
            .init(id: "second", behavior: .steer, text: "duplicate", attachmentCount: 1),
            .init(id: "third", behavior: .followUp, text: "later", attachmentCount: 0),
        ]
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedAuthoritativeSnapshot(snapshot)
        let generation = store.chatTimelineGeneration

        store.clearConfirmedQueue(sessionID: snapshot.sessionId)

        #expect(store.chatTimelineGeneration == generation + 1)
        #expect(store.snapshot?.queued.steering == [])
        #expect(store.snapshot?.queued.followUp == [])
        #expect(store.snapshot?.queuedItems == [])
        #expect(store.snapshot?.displayedQueuedMessages == [])
    }

    @Test("revocation rejects every sequenced event before cursor reduction")
    func revokedSequencedEvent() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 85).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        let target = try #require(store.mountedTarget)
        store.revokeIntake(target)
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.retry",
            sessionId: snapshot.sessionId,
            payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration),
                "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                "revision": .number(Double(snapshot.revision + 1)),
                "data": .object(["attempt": .number(2)]),
            ])
        ))
        #expect(store.snapshot?.eventSequence == snapshot.eventSequence)
        #expect(store.mountedTarget == nil)
    }

    @Test("status, working, and thinking-label value changes advance timeline generation")
    func runtimePresentationGeneration() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_501)
            .openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 10
        snapshot.revision = 20
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        let baseline = store.chatTimelineGeneration

        func event(topic: String, sequence: Int, data: JSONValue) -> GatewayEvent {
            GatewayEvent(
                type: "event", topic: topic, sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "eventSequence": .number(Double(sequence)),
                    "revision": .number(Double(snapshot.revision)),
                    "data": data,
                ])
            )
        }

        await store.admit(event(
            topic: "session.status", sequence: 11,
            data: .object(["key": .string("sync"), "text": .string("Synchronizing")])
        ))
        #expect(store.snapshot?.extensionUI.statuses["sync"] == "Synchronizing")
        #expect(store.chatTimelineGeneration == baseline + 1)

        await store.admit(event(
            topic: "session.status", sequence: 12,
            data: .object(["key": .string("sync"), "text": .string("Synchronizing")])
        ))
        #expect(store.chatTimelineGeneration == baseline + 1)

        await store.admit(event(
            topic: "session.working", sequence: 13,
            data: .object(["message": .string("Compacting context"), "visible": .bool(true)])
        ))
        #expect(store.chatTimelineGeneration == baseline + 2)

        await store.admit(event(
            topic: "session.thinkingLabel", sequence: 14,
            data: .object(["label": .string("Reasoning")])
        ))
        #expect(store.snapshot?.extensionUI.hiddenThinkingLabel == "Reasoning")
        #expect(store.chatTimelineGeneration == baseline + 3)

        await store.admit(event(
            topic: "session.thinkingLabel", sequence: 15,
            data: .object(["label": .string("Reasoning")])
        ))
        #expect(store.chatTimelineGeneration == baseline + 3)

        await store.admit(event(
            topic: "session.thinkingLabel", sequence: 16,
            data: .object(["label": .null])
        ))
        #expect(store.snapshot?.extensionUI.hiddenThinkingLabel == nil)
        #expect(store.chatTimelineGeneration == baseline + 4)
    }

    @Test("stale reconnect retains the newer authoritative tail for history discard")
    func staleReconnectRetainsTail() throws {
        var retained = try SessionScenarioBuilder(seed: 8_502)
            .openingTail(targetEncodedBytes: 4_096)
        retained.eventSequence = 20
        retained.revision = 30
        var stale = retained
        stale.eventSequence = 18
        stale.revision = 28
        stale.transcript.removeLast()
        stale.transcriptTotal = max(0, (stale.transcriptTotal ?? stale.transcript.count + 1) - 1)

        let installedTail = SessionPresentationStore.installingAuthoritativeTail(
            current: retained,
            authoritative: stale,
            mode: .reconnect
        )
        #expect(installedTail == retained)
        #expect(SessionPresentationStore.installingAuthoritativeTail(
            current: retained,
            authoritative: stale,
            mode: .freshPresentation
        ) == stale)

        var visible = retained
        let earlier = try #require(
            SessionScenarioBuilder(seed: 8_503).historyPage(count: 1, longRowBytes: 16).first
        )
        visible.transcript.insert(earlier, at: 0)
        visible.transcriptStart = max(0, (visible.transcriptStart ?? 1) - 1)

        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: retained, token: "token")
        let target = try #require(store.mountedTarget)
        store.installHostedLoadedHistory(visible: visible, authoritativeTail: installedTail)
        store.discardLoadedTranscriptHistory(
            sessionID: retained.sessionId,
            presentationGeneration: target.generation
        )
        #expect(store.snapshot == retained)
        #expect(store.disposableCacheSnapshot == retained)
    }

    @Test("runtime replacement clears secondary projections and advances their reload owners")
    func runtimeReplacementClearsSecondaryProjection() throws {
        var current = try SessionScenarioBuilder(seed: 8_504).openingTail(targetEncodedBytes: 4_096)
        current.runtimeGeneration = "runtime-a"
        var replacement = current
        replacement.runtimeGeneration = "runtime-b"
        replacement.revision += 1

        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: current, token: "token")
        store.installHostedSecondaryProjection(
            context: .object(["runtime": .string("a")]),
            tree: [SessionTreeNode(
                id: "entry",
                parentId: nil,
                timestamp: "2026-08-17T00:00:00.000Z",
                kind: "message",
                label: nil,
                preview: "Entry",
                role: .user,
                depth: 0,
                childCount: 0,
                isCurrentPath: true
            )],
            commands: [.init(name: "command", description: nil, argumentHint: nil, source: .extension, sourcePath: "/extension")],
            resources: .object(["runtime": .string("a")])
        )
        let structureRevision = store.structureRevision(for: current.sessionId)
        let contextRevision = store.contextRevision(for: current.sessionId)
        let resourceRevision = store.resourceRevision(for: current.sessionId)

        #expect(store.prepareSecondaryProjectionForRuntimeInstallation(replacement))
        #expect(store.context == nil)
        #expect(store.sessionTree.isEmpty)
        #expect(store.commands.isEmpty)
        #expect(store.resources == nil)
        #expect(store.structureRevision(for: current.sessionId) == structureRevision + 1)
        #expect(store.contextRevision(for: current.sessionId) == contextRevision + 1)
        #expect(store.resourceRevision(for: current.sessionId) == resourceRevision + 1)
        #expect(!store.prepareSecondaryProjectionForRuntimeInstallation(current))
    }

    @Test("a secondary response cannot publish after exact token replacement")
    func staleSecondaryResponse() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let snapshot = try SessionScenarioBuilder(seed: 84).openingTail(targetEncodedBytes: 4_096)
            let store = await MainActor.run {
                let store = SessionPresentationStore(
                    client: client,
                    performanceSignposts: SystemPerformanceSignposts.shared
                )
                store.installHostedSubscription(snapshot: snapshot, token: "first")
                return store
            }
            let loading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let frame = await socket.sentFrames()[1]
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            let requestID = try #require(request.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object(["stale": .bool(true)]),
            ])))
            await loading.value
            #expect(await MainActor.run { store.context } == nil)

            let errorProbe = SecondaryErrorProbe()
            await MainActor.run {
                store.delegate = errorProbe
                store.installHostedSubscription(snapshot: snapshot, token: "error-old")
            }
            let rejectedLoading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 3)
            let rejectedFrame = await socket.sentFrames()[2]
            let rejectedRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: rejectedFrame)
            let rejectedRequestID = try #require(rejectedRequest.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("error-replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(rejectedRequestID),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("busy"),
                    "message": .string("obsolete failure"),
                    "retryable": .bool(true),
                ]),
            ])))
            await rejectedLoading.value
            #expect(await MainActor.run { errorProbe.errors.isEmpty })

            await MainActor.run {
                store.installHostedSubscription(snapshot: snapshot, token: "revoked")
            }
            let revokedLoading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 4)
            let revokedFrame = await socket.sentFrames()[3]
            let revokedRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: revokedFrame)
            let revokedRequestID = try #require(revokedRequest.objectValue?["id"]?.stringValue)
            await MainActor.run {
                if let target = store.mountedTarget { store.revokeIntake(target) }
            }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(revokedRequestID),
                "ok": .bool(true),
                "result": .object(["revoked": .bool(true)]),
            ])))
            await revokedLoading.value
            #expect(await MainActor.run { store.context } == nil)

            await MainActor.run {
                store.installHostedSubscription(snapshot: snapshot, token: "command-old")
            }
            let rejectedCommands = Task { await store.loadCommands(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 5)
            let commandFrame = await socket.sentFrames()[4]
            let commandRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: commandFrame)
            let commandRequestID = try #require(commandRequest.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("command-replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(commandRequestID),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("busy"),
                    "message": .string("obsolete command failure"),
                    "retryable": .bool(true),
                ]),
            ])))
            await rejectedCommands.value
            #expect(await MainActor.run { errorProbe.errors.isEmpty })
            await client.close()
        }
    }

    @Test("newer same-subscription context load rejects an older completion")
    func newestSecondaryLoadWins() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let snapshot = try SessionScenarioBuilder(seed: 841).openingTail(targetEncodedBytes: 4_096)
            let store = await MainActor.run {
                let store = SessionPresentationStore(
                    client: client,
                    performanceSignposts: SystemPerformanceSignposts.shared
                )
                store.installHostedSubscription(snapshot: snapshot, token: "subscription")
                return store
            }

            let older = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let olderFrame = await socket.sentFrames()[1]
            let olderRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: olderFrame)
            let olderID = try #require(olderRequest.objectValue?["id"]?.stringValue)

            let newer = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 3)
            let newerFrame = await socket.sentFrames()[2]
            let newerRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: newerFrame)
            let newerID = try #require(newerRequest.objectValue?["id"]?.stringValue)

            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(newerID),
                "ok": .bool(true),
                "result": .object(["generation": .string("newer")]),
            ])))
            await newer.value
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(olderID),
                "ok": .bool(true),
                "result": .object(["generation": .string("older")]),
            ])))
            await older.value

            #expect(await MainActor.run { store.context } == .object(["generation": .string("newer")]))
            await client.close()
        }
    }

    @Test("closing an old mount cannot clear a newer suspended open intent")
    func oldClosePreservesNewOpen() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let oldSnapshot = try SessionScenarioBuilder(seed: 87).openingTail(targetEncodedBytes: 4_096)
            var newSnapshot = try SessionScenarioBuilder(seed: 88).openingTail(targetEncodedBytes: 4_096)
            newSnapshot.sessionId = "replacement-session"
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )
            store.installHostedSubscription(snapshot: oldSnapshot, token: "old-token")
            let oldTarget = try #require(store.mountedTarget)
            let opening = Task { try await store.open(newSnapshot.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object(["closed": .bool(true)]),
            ])))

            try await socket.waitUntilSent(count: 3)
            await store.close(oldTarget)
            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(newSnapshot),
                    "syncToken": .string("new-sync"),
                    "subscriptionToken": .string("new-token"),
                ]),
            ])))

            try await socket.waitUntilSent(count: 4)
            frame = await socket.sentFrames()[3]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            _ = try await opening.value
            #expect(store.mountedTarget?.sessionID == newSnapshot.sessionId)
            #expect(store.authoritativeSnapshot(for: newSnapshot.sessionId) == newSnapshot)
            await client.close()
        }
    }

    @Test("synchronization replay keeps the cache tail bounded to the incoming snapshot")
    func synchronizationReplayKeepsBoundedTail() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var baseline = try SessionScenarioBuilder(seed: 8_901)
                .openingTail(targetEncodedBytes: 8_000)
            baseline.transcriptStart = 10
            baseline.transcriptTotal = baseline.transcript.count + 10
            var shifted = baseline
            shifted.eventSequence += 1
            shifted.revision += 1
            shifted.transcript.removeFirst()
            shifted.transcriptStart = 11
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )
            let opening = Task { try await store.open(baseline.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline),
                    "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"),
                ]),
            ])))

            try await socket.waitUntilSent(count: 3)
            await store.admit(GatewayEvent(
                type: "event",
                topic: "session.snapshot",
                sessionId: baseline.sessionId,
                payload: try JSONValue.encode(shifted)
            ))
            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))

            _ = try await opening.value
            #expect(store.snapshot?.transcript.map(\.id) == baseline.transcript.map(\.id))
            #expect(store.disposableCacheSnapshot == shifted)
            await client.close()
        }
    }

    @Test("fresh-open replay publishes editor effects against the installed target")
    func freshOpenReplayEditorTarget() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let model = AppModel(
                client: client,
                cache: SnapshotCache(
                    root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                )
            )
            let connecting = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let snapshot = try SessionScenarioBuilder(seed: 90).openingTail(targetEncodedBytes: 4_096)
            let opening = Task { try await model.openSessionPresentation(snapshot.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(snapshot),
                    "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"),
                ]),
            ])))

            try await socket.waitUntilSent(count: 3)
            await model.handle(GatewayEvent(
                type: "event",
                topic: "session.editorText",
                sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                    "revision": .number(Double(snapshot.revision + 1)),
                    "data": .object([
                        "action": .string("set"),
                        "text": .string("draft"),
                        "fullText": .string("draft"),
                        "revision": .number(7),
                    ]),
                ])
            ))
            #expect(model.presentationTarget(for: snapshot.sessionId) == nil)

            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))

            let generation = try await opening.value
            let target = SessionPresentationIdentity(
                sessionID: snapshot.sessionId,
                generation: generation
            )
            let scope = model.composerDrafts.prepareDraft(
                profileID: "gateway",
                sessionID: snapshot.sessionId,
                initialText: nil
            )
            #expect(model.composerDrafts.editorRequest(for: target) == nil)
            #expect(model.composerDrafts.text(for: scope) == "draft")
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.extensionUI.editorText == "draft")
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.eventSequence == snapshot.eventSequence + 1)
            await model.teardown()
            await client.close()
        }
    }

    @Test("paging compacts back to the authoritative tail and rejects stale leases")
    func pagingRevalidatesLease() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var snapshot = try SessionScenarioBuilder(seed: 86).openingTail(targetEncodedBytes: 4_096)
            snapshot.transcriptStart = 10
            snapshot.transcriptTotal = snapshot.transcript.count + 10
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )

            func respond(
                index: Int,
                items: [TranscriptItem] = [],
                start: Int = 10,
                end: Int = 10
            ) async throws {
                try await socket.waitUntilSent(count: index + 1)
                let frame = await socket.sentFrames()[index]
                let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
                let id = try #require(request.objectValue?["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"),
                    "id": .string(id),
                    "ok": .bool(true),
                    "result": .object([
                        "items": try JSONValue.encode(items),
                        "start": .number(Double(start)),
                        "end": .number(Double(end)),
                        "total": .number(Double(snapshot.transcriptTotal ?? 10)),
                    ]),
                ])))
            }

            store.installHostedSubscription(snapshot: snapshot, token: "current")
            var target = try #require(store.mountedTarget)
            let earlierItem = try #require(
                SessionScenarioBuilder(seed: 8_600).historyPage(count: 1, longRowBytes: 16).first
            )
            let loaded = Task {
                await store.loadEarlier(
                    sessionID: snapshot.sessionId,
                    presentationGeneration: target.generation
                )
            }
            try await socket.waitUntilSent(count: 2)
            try await respond(index: 1, items: [earlierItem], start: 9, end: 10)
            await loaded.value
            #expect(store.snapshot?.transcriptStart == 9)
            #expect(store.snapshot?.transcript.first?.id == earlierItem.id)
            store.discardLoadedTranscriptHistory(
                sessionID: snapshot.sessionId,
                presentationGeneration: target.generation
            )
            #expect(store.snapshot?.transcriptStart == 10)
            #expect(store.snapshot?.transcript.map(\.id) == snapshot.transcript.map(\.id))

            let returningWhileLoading = Task {
                await store.loadEarlier(
                    sessionID: snapshot.sessionId,
                    presentationGeneration: target.generation
                )
            }
            try await socket.waitUntilSent(count: 3)
            store.discardLoadedTranscriptHistory(
                sessionID: snapshot.sessionId,
                presentationGeneration: target.generation
            )
            try await respond(index: 2, items: [earlierItem], start: 9, end: 10)
            await returningWhileLoading.value
            #expect(store.snapshot?.transcriptStart == 10)
            #expect(store.snapshot?.transcript.map(\.id) == snapshot.transcript.map(\.id))

            store.installHostedSubscription(snapshot: snapshot, token: "revoked")
            target = try #require(store.mountedTarget)
            let revoked = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 4)
            store.revokeIntake(target)
            try await respond(index: 3)
            await revoked.value
            #expect(store.snapshot?.transcriptStart == 10)

            store.installHostedSubscription(snapshot: snapshot, token: "original")
            target = try #require(store.mountedTarget)
            let replaced = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 5)
            store.replaceHostedSubscriptionToken("replacement")
            try await respond(index: 4)
            await replaced.value
            #expect(store.snapshot?.transcriptStart == 10)

            store.installHostedSubscription(snapshot: snapshot, token: "disconnect")
            target = try #require(store.mountedTarget)
            let disconnected = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 6)
            store.retireConnection()
            try await respond(index: 5)
            await disconnected.value
            #expect(store.snapshot?.transcriptStart == 10)
            await client.close()
        }
    }

    @Test("subscription and paging admissions require every captured identity")
    func exactAdmissionMatrices() throws {
        let snapshot = try SessionScenarioBuilder(seed: 89).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "export-token")
        #expect(store.ownsInstalledSubscription(
            sessionID: snapshot.sessionId,
            token: "export-token"
        ))
        store.revokeIntake(try #require(store.target))
        #expect(!store.ownsInstalledSubscription(
            sessionID: snapshot.sessionId,
            token: "export-token"
        ))

        #expect(SessionPresentationStore.ownsSubscription(
            sessionID: "session",
            subscribedSessionID: "session",
            installedToken: "new",
            requestedToken: "new"
        ))
        #expect(!SessionPresentationStore.ownsSubscription(
            sessionID: "session",
            subscribedSessionID: "session",
            installedToken: "new",
            requestedToken: "stale"
        ))

        let request = ChatTranscriptPageRequest(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            before: 20,
            expectedTotal: 28,
            expectedNextEntryID: "first"
        )
        #expect(request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "other",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 5,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "replacement",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 19,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "replacement"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 27,
            firstTranscriptID: "first"
        ))
        #expect(request.canInstallPage(
            start: 12, end: 20, total: 28, itemCount: 8, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 19, total: 28, itemCount: 7, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 28, itemCount: 7, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: -1, end: 20, total: 28, itemCount: 21, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 0, end: 20, total: 28, itemCount: 513, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 27, itemCount: 8, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 29, itemCount: 8, visibleItemCount: 8
        ))
    }
}

@MainActor
private final class SecondaryErrorProbe: SessionPresentationStoreDelegate {
    var errors: [String] = []

    func sessionPresentationStoreDidRequestCatalogRefresh() {}
    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationIdentity,
        action: SessionEditorAction,
        text: String,
        fullText: String,
        revision: Int
    ) {}
    func sessionPresentationStoreDidOpen(_ target: SessionPresentationIdentity) {}
    func sessionPresentationStorePostNotice(_ message: String, replacing key: GlobalNoticeKey?) {}
    func sessionPresentationStoreRemoveNotice(_ key: GlobalNoticeKey) {}
    func sessionPresentationStoreSurface(_ error: Error) { errors.append(error.localizedDescription) }
    func sessionPresentationStoreCheckpointCache() {}
}
