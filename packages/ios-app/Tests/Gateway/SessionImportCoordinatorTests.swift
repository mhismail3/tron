import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Session import lifecycle owner")
struct SessionImportCoordinatorTests {
    @Test("same lifecycle admission imports and balances file access")
    func sameAdmissionSuccess() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("session".utf8))
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { name, mimeType, fileURL, byteCount in
                    #expect(name == "session.jsonl")
                    #expect(mimeType == "application/x-ndjson")
                    #expect(byteCount == 7)
                    let stagedData = try Data(contentsOf: fileURL)
                    #expect(stagedData == Data("session".utf8))
                    #expect(access.stopCount == 1)
                    return "upload-a"
                }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/session.jsonl"),
                    cwd: "/workspace"
                )
            }
            defer { importing.cancel() }

            let request = try await request(in: harness.socket, frameIndex: 1)
            #expect(request.method == "session.import")
            #expect(request.params?["uploadId"] == .string("upload-a"))
            #expect(request.params?["cwd"] == .string("/workspace"))
            await harness.socket.enqueue(successResponse(
                id: request.id,
                result: .object(["sessionId": .string("imported-session")])
            ))

            #expect(try await valueOfOwnedTask(importing).sessionID == "imported-session")
            #expect(access.startCount == 1)
            #expect(access.readCount == 1)
            #expect(access.stopCount == 1)
            #expect(access.stagingIsClean)
            await harness.client.close()
        }
    }

    @Test("oversized imports fail before file materialization or upload")
    func oversizedImportPreflight() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(
                data: Data("small".utf8),
                declaredSize: SessionImportPolicy.maximumBytes + 1
            )
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { _, _, _, _ in
                    Issue.record("oversized import unexpectedly uploaded")
                    return "unused"
                }
            )

            await #expect(throws: GatewayFailure.self) {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/oversized.jsonl"),
                    cwd: "/workspace"
                )
            }
            #expect(access.sizeCount == 1)
            #expect(access.readCount == 0)
            #expect(access.stopCount == 1)
            #expect(await harness.socket.sentFrames().count == 1)
            await harness.client.close()
        }
    }

    @Test("empty imports fail during preflight")
    func emptyImportPreflight() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data())
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { _, _, _, _ in
                    Issue.record("empty import unexpectedly uploaded")
                    return "unused"
                }
            )

            await #expect(throws: GatewayFailure.self) {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/empty.jsonl"),
                    cwd: "/workspace"
                )
            }
            #expect(access.sizeCount == 1)
            #expect(access.readCount == 0)
            #expect(access.stopCount == 1)
            await harness.client.close()
        }
    }

    @Test("replacement profile during suspended upload cannot emit session import")
    func replacementDuringUpload() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("old-profile".utf8))
            let gate = UploadGate()
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { name, mimeType, fileURL, byteCount in
                    try await gate.upload(name: name, mimeType: mimeType, fileURL: fileURL, byteCount: byteCount)
                }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/old.jsonl"),
                    cwd: "/old"
                )
            }
            defer { importing.cancel() }
            try await gate.waitUntilStarted()
            #expect(access.stopCount == 1)

            try harness.profiles.select(harness.replacementProfile)
            await gate.succeed(with: "old-upload")

            await expectCancellation(importing)
            #expect(await harness.socket.sentFrames().count == 1)
            #expect(access.stopCount == 1)
            await harness.client.close()
        }
    }

    @Test("same-profile reconnect during upload preserves import admission")
    func sameProfileReconnectDuringUpload() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("reconnect".utf8))
            let gate = UploadGate()
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { name, mimeType, fileURL, byteCount in
                    try await gate.upload(name: name, mimeType: mimeType, fileURL: fileURL, byteCount: byteCount)
                }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/reconnect.jsonl"),
                    cwd: "/reconnect"
                )
            }
            defer { importing.cancel() }
            try await gate.waitUntilStarted()

            await harness.reconnectSocket.enqueue(helloFrame())
            try await harness.lifecycle.connectHosted(
                profile: harness.profiles.selected!,
                token: "token"
            )
            await gate.succeed(with: "reconnected-upload")

            let mutation = try await request(in: harness.reconnectSocket, frameIndex: 1)
            #expect(mutation.method == "session.import")
            #expect(mutation.params?["uploadId"] == .string("reconnected-upload"))
            await harness.reconnectSocket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("reconnected-session")])
            ))

            #expect(try await valueOfOwnedTask(importing).sessionID == "reconnected-session")
            #expect(access.stopCount == 1)
            await harness.client.close()
        }
    }

    @Test("profile replacement during synchronous read rejects before upload")
    func replacementDuringRead() async throws {
        try await withTestWatchdog { @MainActor in
            let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
            let initial = gatewayProfile(id: "read-initial")
            let replacement = gatewayProfile(id: "read-replacement")
            installProfiles([initial, replacement], selected: initial, defaults: defaults)
            let profiles = GatewayProfileStore(defaults: defaults)
            let access = FileAccessRecorder(
                data: Data("read".utf8),
                onRead: {
                    do { try profiles.select(replacement) }
                    catch { Issue.record("profile replacement failed: \(error)") }
                }
            )
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let lifecycle = GatewayLifecycleCoordinator(
                client: client,
                profiles: profiles,
                clock: .continuous,
                reconnectDelayPolicy: .standard,
                uuidSource: .random,
                pairer: GatewayPairer(),
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" }
            )
            let executor = ConfirmedMutationExecutor(
                client: client,
                lifecycle: lifecycle,
                clock: .continuous,
                performanceSignposts: RecordingPerformanceSignposts()
            )
            let coordinator = SessionImportCoordinator(
                lifecycle: lifecycle,
                mutations: SessionMutationService(
                    client: client,
                    executor: executor,
                    uuidSource: .random
                ),
                fileAccess: access.seam,
                upload: { _, _, _, _ in
                    Issue.record("upload unexpectedly ran after profile replacement")
                    return "unused"
                }
            )

            let importing = Task {
                try await coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/read-replacement.jsonl"),
                    cwd: "/read"
                )
            }
            await expectCancellation(importing)
            #expect(access.readCount == 1)
            #expect(access.stopCount == 1)
            #expect(await socket.sentFrames().isEmpty)
        }
    }

    @Test("replacement after mutation send rejects the old profile result")
    func replacementRejectsMutationCompletion() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("mutation".utf8))
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { _, _, _, _ in "mutation-upload" }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/mutation.jsonl"),
                    cwd: "/mutation"
                )
            }
            defer { importing.cancel() }

            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.import")
            try harness.profiles.select(harness.replacementProfile)
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("old-profile-result")])
            ))

            await expectCancellation(importing)
            #expect(access.stopCount == 1)
            await harness.client.close()
        }
    }

    @Test("possibly-sent import replays the exact command only after confirmed missing")
    func possiblySentReceiptReplay() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("receipt".utf8))
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { _, _, _, _ in "receipt-upload" }
            )
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic send failure",
                retryable: true,
                details: nil
            ))
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/receipt.jsonl"),
                    cwd: "/receipt"
                )
            }
            defer { importing.cancel() }

            let status = try await request(in: harness.socket, frameIndex: 1)
            #expect(status.method == "command.status")
            #expect(status.params?["method"] == .string("session.import"))
            let commandID = try #require(status.params?["commandId"]?.stringValue)
            await harness.socket.enqueue(successResponse(
                id: status.id,
                result: .object(["status": .string("missing")])
            ))

            let replay = try await request(in: harness.socket, frameIndex: 2)
            #expect(replay.method == "session.import")
            #expect(replay.params?["commandId"] == .string(commandID))
            #expect(replay.params?["uploadId"] == .string("receipt-upload"))
            await harness.socket.enqueue(successResponse(
                id: replay.id,
                result: .object(["sessionId": .string("receipt-session")])
            ))

            #expect(try await valueOfOwnedTask(importing).sessionID == "receipt-session")
            #expect(access.stopCount == 1)
            await harness.client.close()
        }
    }

    @Test("mutation rejection balances security-scoped access")
    func mutationFailureBalance() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("mutation-failure".utf8))
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { _, _, _, _ in "mutation-failure-upload" }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/mutation-failure.jsonl"),
                    cwd: "/mutation-failure"
                )
            }
            defer { importing.cancel() }

            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.import")
            await harness.socket.enqueue(errorResponse(
                id: mutation.id,
                code: "synthetic_mutation_failure",
                retryable: false
            ))
            do {
                _ = try await valueOfOwnedTask(importing)
                Issue.record("failed import mutation unexpectedly completed")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "synthetic_mutation_failure")
            }
            #expect(access.startCount == 1)
            #expect(access.readCount == 1)
            #expect(access.stopCount == 1)
            await harness.client.close()
        }
    }

    @Test("upload ID from a retired lifecycle generation cannot cross into mutation")
    func retiredGenerationRejectsUploadID() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("retired".utf8))
            let gate = UploadGate()
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { name, mimeType, fileURL, byteCount in
                    try await gate.upload(name: name, mimeType: mimeType, fileURL: fileURL, byteCount: byteCount)
                }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/retired.jsonl"),
                    cwd: "/retired"
                )
            }
            defer { importing.cancel() }
            try await gate.waitUntilStarted()

            await harness.lifecycle.teardown()
            await gate.succeed(with: "retired-upload")

            await expectCancellation(importing)
            #expect(await harness.socket.sentFrames().count == 1)
            #expect(access.stopCount == 1)
        }
    }

    @Test("security scoped access balances read and upload failures")
    func failureBalance() async throws {
        try await withTestWatchdog { @MainActor in
            let readAccess = FileAccessRecorder(
                data: Data(),
                declaredSize: 1,
                readError: ImportTestFailure.read
            )
            let readHarness = try await makeHarness(
                fileAccess: readAccess.seam,
                upload: { _, _, _, _ in
                    Issue.record("upload unexpectedly ran after read failure")
                    return "unused"
                },
                connect: false
            )
            do {
                _ = try await readHarness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/read.jsonl"),
                    cwd: "/read"
                )
                Issue.record("read failure unexpectedly imported")
            } catch ImportTestFailure.read {}
            #expect(readAccess.startCount == 1)
            #expect(readAccess.stopCount == 1)

            let uploadAccess = FileAccessRecorder(data: Data("upload".utf8))
            let uploadHarness = try await makeHarness(
                fileAccess: uploadAccess.seam,
                upload: { _, _, _, _ in throw ImportTestFailure.upload },
                connect: false
            )
            do {
                _ = try await uploadHarness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/upload.jsonl"),
                    cwd: "/upload"
                )
                Issue.record("upload failure unexpectedly imported")
            } catch ImportTestFailure.upload {}
            #expect(uploadAccess.startCount == 1)
            #expect(uploadAccess.readCount == 1)
            #expect(uploadAccess.stopCount == 1)
            #expect(uploadAccess.stagingIsClean)
        }
    }

    @Test("cancellation balances access and cannot publish an upload ID")
    func cancellationBalance() async throws {
        try await withTestWatchdog { @MainActor in
            let access = FileAccessRecorder(data: Data("cancel".utf8))
            let gate = UploadGate()
            let harness = try await makeHarness(
                fileAccess: access.seam,
                upload: { name, mimeType, fileURL, byteCount in
                    try await gate.upload(name: name, mimeType: mimeType, fileURL: fileURL, byteCount: byteCount)
                }
            )
            let importing = Task {
                try await harness.coordinator.importSession(
                    from: URL(fileURLWithPath: "/tmp/cancel.jsonl"),
                    cwd: "/cancel"
                )
            }
            try await gate.waitUntilStarted()
            importing.cancel()
            await expectCancellation(importing)
            #expect(access.stopCount == 1)
            #expect(access.stagingIsClean)
            #expect(await harness.socket.sentFrames().count == 1)
            await harness.client.close()
        }
    }

    @Test("AppModel returns imported identity when catalog refresh fails")
    func resultSurvivesRefreshFailure() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
            let profile = gatewayProfile(id: "app-model")
            installProfiles([profile], selected: profile, defaults: defaults)
            let profiles = GatewayProfileStore(defaults: defaults)
            let access = FileAccessRecorder(data: Data("app-model".utf8))
            let model = AppModel(
                client: client,
                profiles: profiles,
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" },
                sessionImportFileAccess: access.seam,
                sessionImportUpload: { _, _, _, _ in "app-upload" }
            )
            await socket.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: profile, token: "token")

            let importing = Task {
                try await model.importSession(
                    from: URL(fileURLWithPath: "/tmp/model.jsonl"),
                    cwd: "/workspace"
                )
            }
            defer { importing.cancel() }
            let mutation = try await request(in: socket, frameIndex: 1)
            #expect(mutation.method == "session.import")
            await socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("navigation-result")])
            ))
            let refresh = try await request(in: socket, frameIndex: 2)
            #expect(refresh.method == "session.list")
            await socket.enqueue(errorResponse(
                id: refresh.id,
                code: "synthetic_refresh_failure",
                retryable: false
            ))

            let route = try await valueOfOwnedTask(importing)
            #expect(route.sessionID == "navigation-result")
            #expect(model.ownsNavigationRoute(route))
            #expect(model.selectedSessionID == nil)
            #expect(access.stopCount == 1)
            await client.close()
        }
    }

    @Test("AppModel rejects imported identity after replacement during catalog refresh")
    func replacementDuringAppModelRefresh() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
            let initial = gatewayProfile(id: "refresh-initial")
            let replacement = gatewayProfile(id: "refresh-replacement")
            installProfiles([initial, replacement], selected: initial, defaults: defaults)
            let profiles = GatewayProfileStore(defaults: defaults)
            let access = FileAccessRecorder(data: Data("refresh".utf8))
            let model = AppModel(
                client: client,
                profiles: profiles,
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" },
                sessionImportFileAccess: access.seam,
                sessionImportUpload: { _, _, _, _ in "refresh-upload" }
            )
            await socket.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: initial, token: "token")

            let importing = Task {
                try await model.importSession(
                    from: URL(fileURLWithPath: "/tmp/refresh.jsonl"),
                    cwd: "/refresh"
                )
            }
            defer { importing.cancel() }
            let mutation = try await request(in: socket, frameIndex: 1)
            await socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("old-profile-session")])
            ))
            let refresh = try await request(in: socket, frameIndex: 2)
            #expect(refresh.method == "session.list")
            try profiles.select(replacement)
            await socket.enqueue(errorResponse(
                id: refresh.id,
                code: "synthetic_refresh_failure",
                retryable: false
            ))

            do {
                _ = try await valueOfOwnedTask(importing)
                Issue.record("old-profile import unexpectedly returned after replacement")
            } catch is CancellationError {
            } catch {
                Issue.record("unexpected import error: \(error)")
            }
            #expect(access.stopCount == 1)
            await client.close()
        }
    }

    @Test("import route handoff rejects exact lifecycle replacement even after A-B-A profile cycle")
    func routeHandoffAdmission() async throws {
        try await withTestWatchdog { @MainActor in
            let sockets = [
                ScriptedGatewaySocket(),
                ScriptedGatewaySocket(),
                ScriptedGatewaySocket(),
            ]
            let socketFactory = ScriptedGatewaySocketFactory(sockets: sockets)
            let client = GatewayClient(socketFactory: socketFactory.factory)
            let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
            let initial = gatewayProfile(id: "route-initial")
            let replacement = gatewayProfile(id: "route-replacement")
            installProfiles([initial, replacement], selected: initial, defaults: defaults)
            let profiles = GatewayProfileStore(defaults: defaults)
            let access = FileAccessRecorder(data: Data("route".utf8))
            let model = AppModel(
                client: client,
                profiles: profiles,
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" },
                sessionImportFileAccess: access.seam,
                sessionImportUpload: { _, _, _, _ in "route-upload" }
            )
            await sockets[0].enqueue(helloFrame())
            try await model.connectHostedGateway(profile: initial, token: "token")

            let importing = Task {
                try await model.importSession(
                    from: URL(fileURLWithPath: "/tmp/route.jsonl"),
                    cwd: "/route"
                )
            }
            defer { importing.cancel() }
            let mutation = try await request(in: sockets[0], frameIndex: 1)
            await sockets[0].enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("route-session")])
            ))
            let refresh = try await request(in: sockets[0], frameIndex: 2)
            await sockets[0].enqueue(errorResponse(
                id: refresh.id,
                code: "synthetic_refresh_failure",
                retryable: false
            ))
            let route = try await valueOfOwnedTask(importing)
            #expect(model.ownsNavigationRoute(route))

            let switchingToReplacement = Task { await model.switchGateway(replacement) }
            defer { switchingToReplacement.cancel() }
            try await sockets[0].waitUntilClosed()
            try await sockets[1].waitUntilSent(count: 1)
            #expect(profiles.selected?.id == replacement.id)
            #expect(!model.ownsNavigationRoute(route))

            let switchingBack = Task { await model.switchGateway(initial) }
            defer { switchingBack.cancel() }
            try await sockets[1].waitUntilClosed()
            try await sockets[2].waitUntilSent(count: 1)
            #expect(profiles.selected?.id == initial.id)
            #expect(!model.ownsNavigationRoute(route))

            await model.teardown()
            await switchingToReplacement.value
            await switchingBack.value
            #expect(await sockets[2].closed())
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let reconnectSocket: ScriptedGatewaySocket
        let client: GatewayClient
        let lifecycle: GatewayLifecycleCoordinator
        let profiles: GatewayProfileStore
        let replacementProfile: GatewayProfile
        let coordinator: SessionImportCoordinator
    }

    private struct Request {
        let id: String
        let method: String
        let params: JSONValue?
    }

    private func makeHarness(
        fileAccess: SessionImportFileAccess,
        upload: @escaping SessionImportUpload,
        connect: Bool = true
    ) async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let reconnectSocket = ScriptedGatewaySocket()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(
                sockets: [socket, reconnectSocket]
            ).factory
        )
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let profile = gatewayProfile(id: "initial")
        let replacement = gatewayProfile(id: "replacement")
        installProfiles([profile, replacement], selected: profile, defaults: defaults)
        let profiles = GatewayProfileStore(defaults: defaults)
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in "token" }
        )
        let executor = ConfirmedMutationExecutor(
            client: client,
            lifecycle: lifecycle,
            clock: .continuous,
            performanceSignposts: RecordingPerformanceSignposts()
        )
        let mutations = SessionMutationService(
            client: client,
            executor: executor,
            uuidSource: .random
        )
        let coordinator = SessionImportCoordinator(
            lifecycle: lifecycle,
            mutations: mutations,
            fileAccess: fileAccess,
            upload: upload
        )
        if connect {
            await socket.enqueue(helloFrame())
            try await lifecycle.connectHosted(profile: profile, token: "token")
        }
        return Harness(
            socket: socket,
            reconnectSocket: reconnectSocket,
            client: client,
            lifecycle: lifecycle,
            profiles: profiles,
            replacementProfile: replacement,
            coordinator: coordinator
        )
    }

    private func expectCancellation(
        _ task: Task<SessionImportCoordinator.ImportedSession, Error>
    ) async {
        do {
            _ = try await valueOfOwnedTask(task)
            Issue.record("retired import unexpectedly completed")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected import error: \(error)")
        }
    }

    private func request(in socket: ScriptedGatewaySocket, frameIndex: Int) async throws -> Request {
        try await socket.waitUntilSent(count: frameIndex + 1)
        let data = await socket.sentFrames()[frameIndex]
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        let object = try #require(frame.objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue),
            params: object["params"]
        )
    }

    private func installProfiles(
        _ profiles: [GatewayProfile],
        selected: GatewayProfile,
        defaults: UserDefaults
    ) {
        defaults.set(try! JSONEncoder.gateway.encode(profiles), forKey: "gatewayProfiles.v1")
        defaults.set(selected.id, forKey: "selectedGateway.v1")
    }

    private func gatewayProfile(id: String) -> GatewayProfile {
        GatewayProfile(
            id: id,
            label: id,
            host: "gateway.test",
            port: 9_847,
            machineId: id,
            deviceId: "device-\(id)"
        )
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }

    private func successResponse(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func errorResponse(id: String, code: String, retryable: Bool) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string(code),
                "message": .string(code),
                "retryable": .bool(retryable),
            ]),
        ]))
    }
}

@MainActor
private final class FileAccessRecorder {
    private let data: Data
    private let declaredSize: Int
    private let readError: Error?
    private let onRead: (() -> Void)?
    private(set) var startCount = 0
    private(set) var sizeCount = 0
    private(set) var readCount = 0
    private(set) var stopCount = 0
    private(set) var copiedDestinations: [URL] = []

    init(
        data: Data,
        declaredSize: Int? = nil,
        readError: Error? = nil,
        onRead: (() -> Void)? = nil
    ) {
        self.data = data
        self.declaredSize = declaredSize ?? data.count
        self.readError = readError
        self.onRead = onRead
    }

    var stagingIsClean: Bool {
        copiedDestinations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    var seam: SessionImportFileAccess {
        SessionImportFileAccess(
            startAccessing: { [weak self] _ in
                self?.startCount += 1
                return true
            },
            size: { [weak self] _ in
                guard let self else { throw CancellationError() }
                self.sizeCount += 1
                return self.declaredSize
            },
            copy: { [weak self] _, destination, _ in
                guard let self else { throw CancellationError() }
                self.readCount += 1
                self.copiedDestinations.append(destination)
                self.onRead?()
                if let readError = self.readError { throw readError }
                try self.data.write(to: destination, options: .withoutOverwriting)
            },
            stopAccessing: { [weak self] _ in self?.stopCount += 1 }
        )
    }
}

private actor UploadGate {
    private struct StartWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Completion {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
    }

    private var started = false
    private var startWaiters: [StartWaiter] = []
    private var completion: Completion?

    func upload(name: String, mimeType: String, fileURL: URL, byteCount: Int) async throws -> String {
        #expect((try? Data(contentsOf: fileURL).count) == byteCount)
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume() }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    completion = Completion(id: id, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelUpload(id: id) }
        }
    }

    func waitUntilStarted() async throws {
        if started { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    startWaiters.append(StartWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(id: id) }
        }
    }

    func succeed(with uploadID: String) {
        let continuation = completion?.continuation
        completion = nil
        continuation?.resume(returning: uploadID)
    }

    private func cancelUpload(id: UUID) {
        guard completion?.id == id else { return }
        let continuation = completion?.continuation
        completion = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelStartWaiter(id: UUID) {
        guard let index = startWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = startWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private enum ImportTestFailure: Error {
    case read
    case upload
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { objectValue?[key] }
}
