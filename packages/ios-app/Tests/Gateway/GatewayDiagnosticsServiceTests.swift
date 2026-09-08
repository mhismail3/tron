import Foundation
import Testing
@testable import TronMobile

@Suite("Gateway diagnostics boundary")
struct GatewayDiagnosticsServiceTests {
    @Test("git inspection owns its exact target and typed projection")
    func gitInspection() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object([
                "isRepository": .bool(true),
                "branch": .string("main"),
                "dirty": .bool(true),
            ]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        let inspection = try await service.inspectGit(path: "/workspace/project")
        #expect(inspection == GitInspection(isRepository: true, branch: "main", isDirty: true))
        #expect(await recorder.requests == [DiagnosticsRecordedRequest(
            method: "git.inspect",
            params: .object(["path": .string("/workspace/project")])
        )])
    }

    @Test("logs remain newest-first and malformed records are skipped")
    func logs() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object(["records": .array([
                .object([
                    "timestamp": .string("2026-08-16T00:00:00Z"),
                    "level": .string("info"),
                    "message": .string("first"),
                ]),
                .object([
                    "timestamp": .string("malformed"),
                    "level": .string("warning"),
                ]),
                .object([
                    "timestamp": .string("2026-08-16T00:00:01Z"),
                    "level": .string("error"),
                    "message": .string("last"),
                ]),
            ])]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        let records = try await service.logs(limit: 300)
        #expect(records.map(\.message) == ["last", "first"])
        #expect(records.map(\.level) == ["error", "info"])
        #expect(await recorder.requests == [DiagnosticsRecordedRequest(
            method: "system.logs",
            params: .object(["limit": .number(300)])
        )])
    }

    @Test("profile-qualified logs keep identical records distinct")
    func profileQualifiedLogs() {
        let record = GatewayLogRecord(timestamp: "2026-08-16T00:00:00Z", level: "info", message: "ready")
        let first = GatewayProfileLogRecord(profileID: "server-a", profileLabel: "Server A", record: record)
        let second = GatewayProfileLogRecord(profileID: "server-b", profileLabel: "Server B", record: record)

        #expect(first.id != second.id)
        #expect(first.record == second.record)
    }

    @Test("log row identities remain unique for same-profile collisions")
    func logRowIdentityCollisions() {
        let first = GatewayProfileLogRecord(
            profileID: "server-a",
            profileLabel: "Server A",
            record: GatewayLogRecord(
                timestamp: "2026-08-16T00:00:00.000Z",
                level: "info",
                message: "ready",
                event: "server.ready",
                source: "transport"
            )
        )
        let differentSource = GatewayProfileLogRecord(
            profileID: first.profileID,
            profileLabel: first.profileLabel,
            record: GatewayLogRecord(
                timestamp: first.record.timestamp,
                level: first.record.level,
                message: first.record.message,
                event: first.record.event,
                source: "runtime"
            )
        )
        let index = GatewayLogRecordIndex(records: [first, differentSource, first])
        let all = index.items(for: "all")

        #expect(all.count == 3)
        #expect(Set(all.map(\.id)).count == 3)
        #expect(all.map(\.record.record.source) == ["transport", "runtime", "transport"])
        #expect(index.items(for: "info").map(\.id) == all.map(\.id))
        #expect(index.items(for: "error").isEmpty)
    }

    @Test("foreground log refresh retains useful rows until every profile is ready")
    func foregroundLogRefreshPolicy() {
        func profileRecord(_ profileID: String, timestamp: String, message: String) -> GatewayProfileLogRecord {
            GatewayProfileLogRecord(
                profileID: profileID,
                profileLabel: profileID,
                record: GatewayLogRecord(timestamp: timestamp, level: "info", message: message)
            )
        }
        let oldA = profileRecord("server-a", timestamp: "2026-08-16T00:00:01Z", message: "old-a")
        let oldB = profileRecord("server-b", timestamp: "2026-08-16T00:00:02Z", message: "old-b")
        let newA = profileRecord("server-a", timestamp: "2026-08-16T00:00:03Z", message: "new-a")
        let current = [oldB, oldA]

        let partial = GatewayLogsLoadPolicy.mergedRecords(
            current: current,
            loaded: GatewayLogsLoadResult(records: [newA], failedProfileIDs: ["server-b"]),
            preserveExistingOnEmpty: true,
            limit: 1_000
        )
        #expect(partial.map(\.record.message) == ["new-a", "old-b"])

        let automaticEmpty = GatewayLogsLoadPolicy.mergedRecords(
            current: current,
            loaded: GatewayLogsLoadResult(records: [], failedProfileIDs: []),
            preserveExistingOnEmpty: true,
            limit: 1_000
        )
        #expect(automaticEmpty == current)

        let manualEmpty = GatewayLogsLoadPolicy.mergedRecords(
            current: current,
            loaded: GatewayLogsLoadResult(records: [], failedProfileIDs: []),
            preserveExistingOnEmpty: false,
            limit: 1_000
        )
        #expect(manualEmpty.isEmpty)

        let background = GatewayLogsLoadID(readinessGeneration: 4, isReady: false)
        let transientConnected = GatewayLogsLoadID(readinessGeneration: 4, isReady: false)
        let completion = GatewayLogsLoadID(readinessGeneration: 5, isReady: true)
        #expect(background == transientConnected)
        #expect(background != completion)
    }

    @Test("iOS response diagnostics are bounded, profile-qualified, and noncanonical")
    func iosClientDiagnostics() {
        var buffer = IOSClientDiagnosticBuffer()
        let invalid = GatewayFailure(
            code: "invalid_response",
            message: "The Gateway response for session.open is missing required data at session.stats.tokens.",
            retryable: false,
            details: nil
        )
        buffer.record(
            GatewayFailure(code: "offline", message: "offline", retryable: true, details: nil),
            profileID: "stable",
            profileLabel: "Stable",
            timestamp: "2026-08-16T00:00:00Z"
        )
        #expect(buffer.records.isEmpty)

        for index in 0..<(IOSClientDiagnosticBuffer.maximumRecords + 5) {
            buffer.record(
                invalid,
                profileID: "stable",
                profileLabel: "Stable",
                timestamp: String(format: "2026-08-16T00:00:%02dZ", index)
            )
        }
        #expect(buffer.records.count == IOSClientDiagnosticBuffer.maximumRecords)
        #expect(buffer.records.first?.profileID == "stable:ios-client")
        #expect(buffer.records.first?.profileLabel == "Stable · iOS client")
        #expect(buffer.records.first?.record.event == "gateway.response.invalid")
        #expect(buffer.records.first?.record.source == "ios-client")
        #expect(buffer.records.last?.record.timestamp != "2026-08-16T00:00:00Z")

        buffer.record(
            GatewayFailure(
                code: "invalid_response",
                message: String(repeating: "🛠️", count: 1_000),
                retryable: false,
                details: nil
            ),
            profileID: nil,
            profileLabel: nil,
            timestamp: "2026-08-16T01:00:00Z"
        )
        #expect((buffer.records.first?.record.message.utf8.count ?? 0) <= 2_000)
        #expect(buffer.records.first?.record.message == "code=invalid_response")

        buffer.record(
            invalid,
            profileID: String(repeating: "profile", count: 100),
            profileLabel: String(repeating: "Gateway", count: 200),
            timestamp: String(repeating: "timestamp", count: 100)
        )
        #expect((buffer.records.first?.profileID.utf8.count ?? 0) <= 267)
        #expect((buffer.records.first?.profileLabel.utf8.count ?? 0) <= 512)
        #expect((buffer.records.first?.record.timestamp.utf8.count ?? 0) <= 128)
    }

    @Test("connection diagnostics retain profile ownership and same-time sequence identity")
    func connectionDiagnosticsAreOwnedAndDistinct() {
        let first = GatewayConnectionDiagnostic(
            sequence: 1,
            timestamp: "2026-08-16T01:00:00Z",
            profileID: "stable",
            profileLabel: "Stable",
            stage: .helloSend,
            outcome: .failure,
            durationMilliseconds: 15,
            reason: .timeout,
            platformCode: -1001,
            overflowCount: nil
        )
        let second = GatewayConnectionDiagnostic(
            sequence: 10,
            timestamp: first.timestamp,
            profileID: "debug",
            profileLabel: "Debug",
            stage: .transport,
            outcome: .failure,
            durationMilliseconds: 2,
            reason: .eventOverflow,
            platformCode: nil,
            overflowCount: 1_024
        )
        let firstRecord = IOSClientDiagnosticBuffer.logRecord(first)
        let secondRecord = IOSClientDiagnosticBuffer.logRecord(second)
        #expect(firstRecord.profileID == "stable:ios-client")
        #expect(secondRecord.profileID == "debug:ios-client")
        #expect(firstRecord.record.timestamp == secondRecord.record.timestamp)
        #expect(firstRecord.record.message.contains("sequence=1 "))
        #expect(!firstRecord.record.message.contains("sequence=10"))
        #expect(secondRecord.record.message.contains("reason=event_overflow"))
        #expect(secondRecord.record.message.contains("overflowCount=1024"))
        #expect(firstRecord.record.message.contains("platformCode=-1001"))
    }

    @Test("frame decode-limit diagnostics preserve typed bounds and privacy through export")
    func frameDecodeLimitDiagnosticsAreExportedSafely() async throws {
        let limits = JSONValueDecodingLimits(
            maximumDepth: 8,
            maximumNodes: 3,
            maximumCollectionMembers: 10,
            maximumStringBytes: 64,
            maximumTotalStringBytes: 64
        )
        let violation: JSONValueDecodingLimitViolation
        do {
            _ = try JSONDecoder.gateway(jsonValueLimits: limits).decode(
                JSONValue.self,
                from: Data(#"{"secret-key":{"nested":{"leaf":0}}}"#.utf8)
            )
            Issue.record("limit violation unexpectedly decoded")
            return
        } catch let decoded as JSONValueDecodingLimitViolation {
            violation = decoded
        }

        let timestamp = Date.now.formatted(.iso8601)
        let diagnostic = GatewayConnectionDiagnostic(
            sequence: 7,
            clientID: "client-id",
            attemptID: "attempt-id",
            connectionID: 3,
            timestamp: timestamp,
            profileID: "stable",
            profileLabel: "Stable",
            stage: .transport,
            outcome: .failure,
            durationMilliseconds: 9,
            reason: .decodeLimit,
            platformCode: nil,
            overflowCount: nil,
            frameBytes: 597_822,
            decodeLimitKind: violation.kind,
            decodeActual: violation.actual,
            decodeMaximum: violation.maximum,
            decodeCodingPath: violation.codingPath
        )
        let record = IOSClientDiagnosticBuffer.logRecord(diagnostic)
        #expect(record.record.event == "gateway.connection")
        #expect(record.record.message.contains("reason=decode_limit"))
        #expect(record.record.message.contains("frameBytes=597822"))
        #expect(record.record.message.contains("decodeLimit=nodes"))
        #expect(record.record.message.contains("decodeActual=4"))
        #expect(record.record.message.contains("decodeMaximum=3"))
        #expect(record.record.message.contains("decodePath=dynamic"))
        #expect(!record.record.message.contains("secret-key"))

        let suite = "GatewayDecodeLimitDiagnostics.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        await store.save([record])
        let loaded = await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].record.message == record.record.message)
        #expect(loaded[0].profileLabel == "iOS client")
    }

    @MainActor
    @Test("offline Logs never sends RPCs into a pending handshake and retains local evidence")
    func offlineLogsDoNotUsePendingHandshake() async throws {
        try await withTestWatchdog { @MainActor in
            let suiteName = "OfflineGatewayLogs.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let profile = GatewayProfile(
                id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
            defaults.set(profile.id, forKey: "selectedGateway.v1")
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults))
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            defer { connecting.cancel() }
            try await socket.waitUntilSent(count: 1)

            let pending = await model.loadGatewayLogsResult()
            #expect(pending.failedProfileIDs == [profile.id])
            #expect(await socket.sentFrames().count == 1)

            connecting.cancel()
            do { _ = try await valueOfOwnedTask(connecting) }
            catch {}
            let offline = await model.loadGatewayLogsResult()
            #expect(offline.failedProfileIDs == [profile.id])
            #expect(offline.records.contains { $0.record.event == "gateway.connection" })
            #expect(await socket.sentFrames().count == 1)
            await model.teardown()
            await client.close()
        }
    }

    @Test("incident retention is bounded and requires an injected owner")
    func incidentRetentionIsBounded() async throws {
        let suite = "GatewayDiagnosticsStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let records = (0..<IOSClientDiagnosticStore.maximumRecords + 8).map { index in
            GatewayProfileLogRecord(
                profileID: "stable:ios-client",
                profileLabel: "Stable · iOS client",
                record: GatewayLogRecord(
                    timestamp: Date.now.formatted(.iso8601),
                    level: "warning",
                    message: "bounded incident \(index)",
                    event: "gateway.connection",
                    source: "ios-client"
                )
            )
        }
        await store.save(records)
        let loaded = await store.load()
        #expect(loaded.count == IOSClientDiagnosticStore.maximumRecords)
    }

    @Test("persisted invalid-response incidents use typed-safe fields")
    func persistedInvalidResponseIncidentsAreTypedSafe() async throws {
        let suite = "GatewayDiagnosticsSafeStore.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let record = GatewayProfileLogRecord(
            profileID: "profile:ios-client",
            profileLabel: "Secret customer at /Users/private",
            record: GatewayLogRecord(
                timestamp: Date.now.formatted(.iso8601),
                level: "error",
                message: "request failed https://secret.example/token=abc",
                event: "gateway.response.invalid",
                source: "ios-client"
            )
        )
        await store.save([record])
        let loaded = await store.load()
        #expect(loaded.first?.profileLabel == "iOS client")
        #expect(loaded.first?.record.message == "code=invalid_response")
    }

    @Test("Gateway queue evidence survives remote logs decoding into export rows")
    func remoteQueueEvidenceSurvivesLogsDecode() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object(["records": .array([
                .object([
                    "timestamp": .string("2026-01-01T00:00:00Z"),
                    "level": .string("warning"),
                    "message": .string("lastInboundAgeMs=12 lastWriteProgressAgeMs=3 queuedFrames=2 queuedBytes=44 completedFrames=8"),
                    "event": .string("connection.closed"),
                    "source": .string("transport"),
                ])
            ])])
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })
        let logs = try await service.logs(limit: 10)
        #expect(logs.count == 1)
        #expect(logs[0].message.contains("queuedBytes=44"))
        #expect(logs[0].event == "connection.closed")
    }

    @Test("non-repository and absent records retain empty presentation semantics")
    func emptyValues() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object(["isRepository": .bool(false)]),
            .object([:]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        #expect(try await service.inspectGit(path: "/tmp").isRepository == false)
        #expect(try await service.logs(limit: 0).isEmpty)
    }
}

private struct DiagnosticsRecordedRequest: Equatable, Sendable {
    let method: String
    let params: JSONValue
}

private actor DiagnosticsRequestRecorder {
    private var responses: [JSONValue]
    private(set) var requests: [DiagnosticsRecordedRequest] = []

    init(responses: [JSONValue]) { self.responses = responses }

    func request(method: String, params: JSONValue) throws -> JSONValue {
        requests.append(DiagnosticsRecordedRequest(method: method, params: params))
        guard !responses.isEmpty else {
            throw GatewayFailure(code: "missing_fixture", message: "Missing fixture", retryable: false, details: nil)
        }
        return responses.removeFirst()
    }
}
