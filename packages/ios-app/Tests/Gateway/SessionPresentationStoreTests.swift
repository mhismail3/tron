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
            try await connecting.value

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

            await MainActor.run {
                store.installHostedSubscription(snapshot: snapshot, token: "revoked")
            }
            let revokedLoading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 3)
            let revokedFrame = await socket.sentFrames()[2]
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
            try await connecting.value

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
            try await connecting.value

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
            #expect(model.editorRequest(for: target)?.fullText == "draft")
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.extensionUI.editorText == "draft")
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.eventSequence == snapshot.eventSequence + 1)
            await model.teardown()
            await client.close()
        }
    }

    @Test("paging rejects revocation, token replacement, and disconnect after suspension")
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
            try await connecting.value

            var snapshot = try SessionScenarioBuilder(seed: 86).openingTail(targetEncodedBytes: 4_096)
            snapshot.transcriptStart = 10
            snapshot.transcriptTotal = snapshot.transcript.count + 10
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )

            func respond(index: Int) async throws {
                try await socket.waitUntilSent(count: index + 1)
                let frame = await socket.sentFrames()[index]
                let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
                let id = try #require(request.objectValue?["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"),
                    "id": .string(id),
                    "ok": .bool(true),
                    "result": .object([
                        "items": .array([]),
                        "start": .number(0),
                        "total": .number(Double(snapshot.transcriptTotal ?? 10)),
                    ]),
                ])))
            }

            store.installHostedSubscription(snapshot: snapshot, token: "revoked")
            var target = try #require(store.mountedTarget)
            let revoked = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 2)
            store.revokeIntake(target)
            try await respond(index: 1)
            await revoked.value
            #expect(store.snapshot?.transcriptStart == 10)

            store.installHostedSubscription(snapshot: snapshot, token: "original")
            target = try #require(store.mountedTarget)
            let replaced = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 3)
            store.replaceHostedSubscriptionToken("replacement")
            try await respond(index: 2)
            await replaced.value
            #expect(store.snapshot?.transcriptStart == 10)

            store.installHostedSubscription(snapshot: snapshot, token: "disconnect")
            target = try #require(store.mountedTarget)
            let disconnected = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 4)
            store.retireConnection()
            try await respond(index: 3)
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
            expectedNextEntryID: "first"
        )
        #expect(request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "other",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 5,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "replacement",
            transcriptStart: 20,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 19,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            firstTranscriptID: "replacement"
        ))
    }
}
