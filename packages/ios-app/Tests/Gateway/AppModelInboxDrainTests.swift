import Foundation
import Observation
import Testing
@testable import TronMobile

@MainActor
struct AppModelInboxDrainTests {
    @Test("inbox reads stay off event drain and foreground readiness, with fresh demand after reconnect")
    func stalledOptionalRead() async throws {
        try await withTestWatchdog { @MainActor in
            let suite = "TronInboxDrain.\(UUID())"
            let root = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let defaults = try #require(UserDefaults(suiteName: suite))
            let profile = GatewayProfile(id: "profile-fixture", label: "Fixture", host: "fixture.invalid", port: 9847, machineId: "machine")
            defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
            defaults.set(profile.id, forKey: "selectedGateway.v1")
            let socket = ScriptedGatewaySocket()
            let replacement = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket, replacement]).factory)
            let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults),
                cache: SnapshotCache(root: root.appending(path: "cache")),
                profileTokenLookup: { _ in "synthetic-token" },
                composerDraftStore: ComposerDraftStore(root: root.appending(path: "drafts")),
                extensionInteractionDrafts: ExtensionInteractionDraftStore(defaults: defaults),
                exportArtifacts: SessionExportArtifactStore(root: root.appending(path: "exports")),
                notificationInbox: NotificationInboxCoordinator())
            var flight: Task<Void, Never>?
            var foreground: Task<Void, Error>?
            let foregroundFinished = AsyncStream<Result<Void, Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { foregroundFinished.continuation.finish() }
            let changed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { changed.continuation.finish() }
            do {
                await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
                try await model.connectHostedGateway(profile: profile, token: "synthetic-token")
                withObservationTracking { _ = model.noticeCenter.notices } onChange: { changed.continuation.yield(()) }
                await socket.enqueue(Data(#"{"type":"event","topic":"notification.inbox.changed","payload":{}}"#.utf8))
                try await socket.waitUntilSent(count: 2)
                flight = model.notificationInbox.scheduleRefresh(profile: profile) { _, _ in
                    Issue.record("The active refresh must retain its operation owner")
                }
                // The Gateway always states the outcome of a completed package
                // operation (`{operationId, success}`), and an absent `success` is
                // deliberately read as failure rather than claimed as success.
                await socket.enqueue(Data(#"{"type":"event","topic":"packages.completed","payload":{"success":true}}"#.utf8))
                var iterator = changed.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
                #expect(model.noticeCenter.notices.contains { $0.title == "Package operation completed" })
                #expect(model.notificationInbox.isLoading)
                #expect(await socket.sentFrames().count == 2)
                let local = await model.loadGatewayLogsResult(includeRemote: false)
                #expect(!local.records.isEmpty)
                #expect(await socket.sentFrames().count == 2)
                let connectionID = try #require(await client.activeConnectionID())
                foreground = Task {
                    do {
                        try await model.lifecycleReconcileForeground(admission: .init(generation: 0, connectionID: connectionID))
                        foregroundFinished.continuation.yield(.success(()))
                    } catch {
                        foregroundFinished.continuation.yield(.failure(error))
                        throw error
                    }
                }
                var requestIndex = 0
                var catalog: [String: JSONValue]?
                while catalog == nil {
                    try await socket.waitUntilSent(count: requestIndex + 1)
                    let frame = await socket.sentFrames()[requestIndex]
                    let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame).objectValue
                    if request?["method"]?.stringValue == "session.list" { catalog = request }
                    requestIndex += 1
                }
                let catalogRequest = try #require(catalog)
                let requestID = try #require(catalogRequest["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
                    "result": .object(["sessions": .array([]), "listRevision": .number(1)])
                ])))
                var completion = foregroundFinished.stream.makeAsyncIterator()
                guard let result = await completion.next() else { throw CancellationError() }
                try result.get()
                try await foreground?.value
                #expect(model.diagnosticsAreReady)
                #expect(model.notificationInbox.isLoading)

                model.notificationInbox.cancelRefreshes()
                await flight?.value
                await replacement.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
                try await model.connectHostedGateway(profile: profile, token: "synthetic-token")
                let replacementID = try #require(await client.activeConnectionID())
                #expect(replacementID != connectionID)
                foreground = Task {
                    do {
                        try await model.lifecycleReconcileForeground(admission: .init(generation: 0, connectionID: replacementID))
                        foregroundFinished.continuation.yield(.success(()))
                    } catch {
                        foregroundFinished.continuation.yield(.failure(error))
                        throw error
                    }
                }
                // Both optional reads may start first; neither is a readiness
                // barrier, and responses must be correlated by method/ID.
                guard let replacementResult = await completion.next() else { throw CancellationError() }
                try replacementResult.get()
                try await foreground?.value
                var replacementRequests: [[String: JSONValue]?] = []
                var replacementFrameIndex = 1
                var replacementMethods: Set<String> = []
                while !replacementMethods.isSuperset(of: Set(["session.list", "notification.inbox.list"])) {
                    try await replacement.waitUntilSent(count: replacementFrameIndex + 1)
                    let request = try JSONDecoder.gateway.decode(
                        JSONValue.self,
                        from: await replacement.sentFrames()[replacementFrameIndex]
                    ).objectValue
                    replacementRequests.append(request)
                    if let method = request?["method"]?.stringValue {
                        replacementMethods.insert(method)
                    }
                    replacementFrameIndex += 1
                }
                #expect(replacementRequests.filter { $0?["method"]?.stringValue == "session.list" }.count == 1)
                #expect(replacementRequests.filter { $0?["method"]?.stringValue == "notification.inbox.list" }.count == 1)
                let replacementCatalog = try #require(replacementRequests.first { $0?["method"]?.stringValue == "session.list" })
                let replacementRequestID = try #require(replacementCatalog?["id"]?.stringValue)
                await replacement.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(replacementRequestID), "ok": .bool(true),
                    "result": .object(["sessions": .array([]), "listRevision": .number(2)])
                ])))
                #expect(model.notificationInbox.isLoading)
                await model.teardown()
                await flight?.value
                await client.close()
            } catch {
                foreground?.cancel()
                await model.teardown()
                if let foreground { _ = await foreground.result }
                await flight?.value
                await client.close()
                if FileManager.default.fileExists(atPath: root.path) {
                    do { try FileManager.default.removeItem(at: root) }
                    catch { Issue.record(error) }
                }
                throw error
            }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }
}
