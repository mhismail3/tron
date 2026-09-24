import Foundation
import Testing
@testable import TronMobile

@Suite("Gateway diagnostics boundary")
struct GatewayDiagnosticsServiceTests {
    @Test("logs automatic refresh uses a quiet fifteen-second cadence")
    func logsAutomaticRefreshCadence() {
        #expect(GatewayLogsLoadPolicy.refreshInterval == 15)
    }

    @Test("logs refresh callers join one local and remote read")
    @MainActor
    func logsRefreshCallersJoinOneRead() async {
        let coordinator = GatewayLogsLoadCoordinator()
        let owner = coordinator.acquire()
        let gate = GatewayLogsTestGate()
        var localCalls = 0
        let operation: @MainActor () async -> GatewayLogsLoadResult = {
            localCalls += 1
            await gate.wait()
            return GatewayLogsLoadResult(records: [], failedProfileIDs: [])
        }
        let first = Task { await coordinator.local(for: owner, operation: operation) }
        await Task.yield()
        let joiner = coordinator.acquire()
        let second = Task { await coordinator.local(for: joiner, operation: operation) }
        await Task.yield()
        #expect(localCalls == 1)
        await gate.signal()
        #expect(await first.value != nil)
        coordinator.release(owner)
        // A manual caller that joined the automatic load still receives the
        // raw result and can apply its own empty-response policy.
        #expect(await second.value != nil)
        coordinator.release(joiner)

        // A fresh lease owns the remote phase for this independent assertion.
        let remoteOwner = coordinator.acquire()
        let remoteJoiner = coordinator.acquire()
        let remoteGate = GatewayLogsTestGate()
        var remoteCalls = 0
        let remoteOperation: @MainActor () async -> GatewayLogsLoadResult = {
            remoteCalls += 1
            await remoteGate.wait()
            return GatewayLogsLoadResult(records: [], failedProfileIDs: [])
        }
        let remoteFirst = Task { await coordinator.remote(for: remoteOwner, operation: remoteOperation) }
        await Task.yield()
        let remoteSecond = Task { await coordinator.remote(for: remoteJoiner, operation: remoteOperation) }
        await Task.yield()
        #expect(remoteCalls == 1)
        await remoteGate.signal()
        #expect(await remoteFirst.value != nil)
        coordinator.release(remoteOwner)
        #expect(await remoteSecond.value != nil)
        coordinator.release(remoteJoiner)
    }

    @Test("retiring logs refresh rejects the old lease and cancels its work")
    @MainActor
    func retiringLogsRefreshCancelsOldLease() async {
        let coordinator = GatewayLogsLoadCoordinator()
        let lease = coordinator.acquire()
        let gate = GatewayLogsTestGate()
        let task = Task {
            await coordinator.local(for: lease, operation: {
                await gate.wait()
                return GatewayLogsLoadResult(records: [], failedProfileIDs: [])
            })
        }
        await Task.yield()
        coordinator.cancel()
        #expect(coordinator.acquire().owner)
        await gate.signal()
        #expect(await task.value == nil)
    }

    @Test("git inspection owns its exact target and typed projection")
    func gitInspection() async throws {
        let recorder = DiagnosticsRequestRecorder(responses: [
            .object([
                "isRepository": .bool(true),
                "branch": .string("main"),
                "dirty": .bool(true),
                "branches": .array([
                    .object(["name": .string("main"), "checkedOut": .bool(true)]),
                    .object(["name": .string("feature"), "checkedOut": .bool(false)]),
                    .object(["name": .string("malformed")]),
                ]),
                "commits": .array([.object(["oid": .string("abc123"), "subject": .string("Initial commit")])]),
            ]),
        ])
        let service = GatewayDiagnosticsService(request: { method, params in
            try await recorder.request(method: method, params: params)
        })

        let inspection = try await service.inspectGit(path: "/workspace/project")
        #expect(inspection == GitInspection(isRepository: true, branch: "main", isDirty: true,
            branches: [.init(name: "main", checkedOut: true), .init(name: "feature", checkedOut: false)],
            commits: [.init(oid: "abc123", subject: "Initial commit")]))
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

    @Test("persisted diagnostics retain the first fault and redact private transport content")
    func persistedDiagnosticsRetainFirstFault() async throws {
        let suite = "GatewayDiagnosticsRetentionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let now = Date.now
        let records = (0..<120).map { index in
            let timestamp = GatewayTimestamp.preciseString(from: now.addingTimeInterval(TimeInterval(index - 119)))
            return GatewayProfileLogRecord(
                profileID: "profile:ios-client",
                profileLabel: "private profile label",
                record: GatewayLogRecord(
                    timestamp: timestamp,
                    level: index == 0 ? "warning" : "info",
                    message: index == 0 ? "first https://private.example/path token=secret" : "routine-\(index)",
                    event: "gateway.connection",
                    source: "ios-client"
                ), incidentID: "client:attempt"
            )
        }
        await store.save(records)
        let retained = await store.load(now: now.addingTimeInterval(1))
        #expect(retained.count <= IOSClientDiagnosticStore.maximumRecords)
        #expect(retained.contains { $0.record.message.contains("first") })
        #expect(retained.allSatisfy { !$0.record.message.contains("private.example") && !$0.record.message.contains("secret") })
        #expect(retained.allSatisfy { $0.profileLabel == "iOS client" })
    }

    @Test("diagnostic reservations stay bounded while the newest success remains retained")
    func diagnosticReservationsStayBounded() async throws {
        let suite = "GatewayDiagnosticsReservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let now = Date.now
        let records = (0..<140).map { index in
            let timestamp = GatewayTimestamp.preciseString(from: now.addingTimeInterval(TimeInterval(index - 139)))
            return GatewayProfileLogRecord(
                profileID: "profile-\(index % 12):ios-client",
                profileLabel: "profile",
                record: GatewayLogRecord(
                    timestamp: timestamp,
                    level: index == 139 ? "info" : "warning",
                    message: index == 139 ? "newest-success" : "fault-\(index)",
                    event: ["gateway.connection", "gateway.lifecycle", "gateway.client-work"][index % 3],
                    source: "ios-client"
                ), incidentID: "attempt-\(index % 12)"
            )
        }
        await store.save(records)
        let retained = await store.load(now: now.addingTimeInterval(1))
        #expect(retained.count <= IOSClientDiagnosticStore.maximumRecords)
        #expect(retained.contains { $0.record.message == "newest-success" })
        let oldestReservations = retained.filter { record in
            guard record.record.message.hasPrefix("fault-"),
                  let index = Int(record.record.message.dropFirst("fault-".count)) else { return false }
            return index < 50
        }
        #expect(oldestReservations.count == 8)
        #expect(Set(oldestReservations.map(\.record.message)) == Set((0..<8).map { "fault-\($0)" }))
    }

    @Test("a new incident retains its own first cause through count and byte pressure")
    func distinctIncidentsRetainFirstCause() async throws {
        let suite = "GatewayIncidentBoundaryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let now = Date.now
        let records: [GatewayProfileLogRecord] = (0..<250).map { index in
            let timestamp = GatewayTimestamp.preciseString(from: now.addingTimeInterval(Double(index - 250)))
            let level = index == 0 || index == 50 ? "warning" : "info"
            let message: String
            if index == 0 { message = "old-first" }
            else if index == 50 { message = "new-first" }
            else { message = "routine-\(index) " + String(repeating: "x", count: 1_400) }
            let record = GatewayLogRecord(timestamp: timestamp, level: level, message: message,
                                          event: "gateway.connection", source: "ios-client")
            return GatewayProfileLogRecord(profileID: "profile:ios-client", profileLabel: "fixture",
                record: record, incidentID: index < 50 ? "client:old-attempt" : "client:new-attempt")
        }
        await store.save(records, now: now)
        let result = await store.load(now: now)
        #expect(result.contains { $0.record.message == "new-first" && $0.incidentID == "client:new-attempt" })
        #expect(result.contains { $0.record.message == "old-first" })
        #expect(result.contains { $0.record.message.hasPrefix("routine-249 ") })
        #expect(try JSONEncoder.gateway.encode(result).count <= IOSClientDiagnosticStore.maximumBytes)
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

    @Test("catalog diagnostics retain bounded causal fields without payloads")
    func catalogDiagnosticsAreBoundedAndRedacted() {
        var buffer = IOSClientDiagnosticBuffer()
        for index in 0..<(IOSClientDiagnosticBuffer.maximumRecords + 3) {
            buffer.recordCatalog(
                trigger: "automatic-retry",
                outcome: index == 0 ? "failure" : "published",
                profileID: "stable",
                profileLabel: "Stable",
                connectionID: 7,
                lifecycleGeneration: 11,
                requestGeneration: index,
                durationMilliseconds: 123,
                code: "timeout",
                reason: "current-owner",
                level: "warning",
                incidentID: index == 0 ? "catalog:1" : nil,
                timestamp: "2026-08-16T01:00:\(String(format: "%02d", index % 60))Z"
            )
        }
        #expect(buffer.records.count == IOSClientDiagnosticBuffer.maximumRecords)
        let record = buffer.records[0]
        #expect(record.record.event == "gateway.catalog")
        #expect(record.record.message.contains("trigger=automatic-retry"))
        #expect(record.record.message.contains("requestGeneration="))
        #expect(record.record.message.contains("durationMs=123"))
        #expect(!record.record.message.contains("session text"))
        #expect(!record.record.message.contains("/private/"))
    }

    @Test("RPC diagnostics preserve request correlation without sensitive values")
    func rpcDiagnosticsAreCorrelatedAndRedacted() {
        let record = IOSClientDiagnosticBuffer.logRecord(GatewayRPCDiagnostic(
            method: "session.list",
            requestID: "request-42",
            outcome: .timeout,
            code: "possibly_sent",
            durationMilliseconds: 10_001,
            timestamp: "2026-08-16T01:00:00Z",
            profileID: "stable",
            profileLabel: "Stable",
            incidentID: "rpc:request-42"
        ))
        #expect(record.record.event == "gateway.rpc")
        #expect(record.record.message.contains("method=session.list"))
        #expect(record.record.message.contains("requestID=request-42"))
        #expect(record.record.message.contains("outcome=timeout"))
        #expect(record.incidentID == "rpc:request-42")
        #expect(!record.record.message.contains("session text"))
        #expect(!record.record.message.contains("/private/"))
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

    @Test("two never-opened attempts report the known path while one is insufficient")
    func noPathRequiresTwoNeverOpenedAttempts() {
        var classifier = GatewayConnectionFailureClassifier()
        let neverOpened = connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: true, networkInterfaces: "wifi,other"
            )
        )
        classifier.failedAttempt(neverOpened, code: "timeout")
        #expect(classifier.noPath == nil)
        classifier.failedAttempt(neverOpened, code: "timeout")
        #expect(classifier.noPath?.label == "No path to this Mac over Wi-Fi")

        var negativeControl = GatewayConnectionFailureClassifier()
        let opened = connectionDiagnostic(
            stage: .helloReceive,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: true, transportOpenMilliseconds: 42,
                waitedForConnectivity: false, networkInterfaces: "wifi,other"
            )
        )
        negativeControl.failedAttempt(opened, code: "timeout")
        negativeControl.failedAttempt(neverOpened, code: "timeout")
        #expect(negativeControl.noPath == nil)
    }

    @Test("opened and ping-timeout recovery episodes stay reconnecting and success resets classification")
    func reconnectingEpisodesAndReset() {
        var openedClassifier = GatewayConnectionFailureClassifier()
        let opened = connectionDiagnostic(
            stage: .helloReceive,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: true, transportOpenMilliseconds: 42,
                waitedForConnectivity: false, networkInterfaces: "wifi"
            )
        )
        openedClassifier.failedAttempt(opened, code: "timeout")
        openedClassifier.failedAttempt(connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: false, networkInterfaces: "wifi"
            )
        ), code: "timeout")
        #expect(openedClassifier.noPath == nil)

        var pingClassifier = GatewayConnectionFailureClassifier()
        pingClassifier.failedAttempt(nil, code: "ping_timeout")
        pingClassifier.failedAttempt(connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: false, networkInterfaces: "wifi"
            )
        ), code: "timeout")
        pingClassifier.failedAttempt(connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: false, networkInterfaces: "wifi"
            )
        ), code: "timeout")
        #expect(pingClassifier.noPath == nil)
        pingClassifier.reset()
        #expect(pingClassifier.noPath == nil)
        #expect(pingClassifier.consecutiveNeverOpened == 0)

        var negativeControl = GatewayConnectionFailureClassifier()
        negativeControl.failedAttempt(connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: false, networkInterfaces: nil
            )
        ), code: "timeout")
        negativeControl.failedAttempt(connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: false, networkInterfaces: nil
            )
        ), code: "timeout")
        #expect(negativeControl.noPath?.label == "No path to this Mac")
    }

    private func connectionDiagnostic(
        stage: GatewayConnectionDiagnosticStage,
        handshake: GatewayHandshakeDiagnostic
    ) -> GatewayConnectionDiagnostic {
        GatewayConnectionDiagnostic(
            sequence: 1,
            timestamp: "2026-08-16T01:00:00Z",
            profileID: "stable",
            profileLabel: "Stable",
            stage: stage,
            outcome: .failure,
            durationMilliseconds: 15,
            reason: .timeout,
            platformCode: nil,
            handshake: handshake
        )
    }

    @Test("late failure classification cannot overwrite a connected presentation")
    func staleFailureClassificationAfterConnectionIsIgnored() {
        var classifier = GatewayConnectionFailureClassifier()
        let staleAttempt = classifier.beginAttempt()
        let neverOpened = connectionDiagnostic(
            stage: .transportOpen,
            handshake: GatewayHandshakeDiagnostic(
                transportOpened: false, transportOpenMilliseconds: nil,
                waitedForConnectivity: false, networkInterfaces: "wifi"
            )
        )
        let firstFailureApplied = classifier.failedAttempt(
            neverOpened, code: "timeout", attemptGeneration: staleAttempt
        )
        #expect(firstFailureApplied)
        #expect(classifier.noPath == nil)

        // A newer successful connection retires the old attempt's publication right.
        classifier.reset()
        let staleFailureApplied = classifier.failedAttempt(
            neverOpened, code: "timeout", attemptGeneration: staleAttempt
        )
        #expect(!staleFailureApplied)
        #expect(classifier.noPath == nil)

        var negativeControl = GatewayConnectionFailureClassifier()
        _ = negativeControl.failedAttempt(neverOpened, code: "timeout")
        _ = negativeControl.failedAttempt(neverOpened, code: "timeout")
        #expect(negativeControl.noPath != nil)
    }

    @Test("close and HTTP metadata remain separate numeric fields")
    func transportMetadataRemainsTypedAndSeparate() {
        let close = GatewayConnectionDiagnostic(
            sequence: 21,
            timestamp: "2026-08-16T01:00:00Z",
            profileID: "stable",
            profileLabel: "Stable",
            stage: .transport,
            outcome: .failure,
            durationMilliseconds: 1,
            reason: .closed,
            platformCode: nil,
            closeCode: 1001,
            httpStatusCode: nil
        )
        let http = GatewayConnectionDiagnostic(
            sequence: 22,
            timestamp: "2026-08-16T01:00:01Z",
            profileID: "stable",
            profileLabel: "Stable",
            stage: .helloReceive,
            outcome: .failure,
            durationMilliseconds: 1,
            reason: .timeout,
            platformCode: nil,
            closeCode: nil,
            httpStatusCode: 503
        )
        let closeMessage = IOSClientDiagnosticBuffer.logRecord(close).record.message
        let httpMessage = IOSClientDiagnosticBuffer.logRecord(http).record.message
        #expect(closeMessage.contains("closeCode=1001"))
        #expect(!closeMessage.contains("httpStatusCode="))
        #expect(httpMessage.contains("httpStatusCode=503"))
        #expect(!httpMessage.contains("closeCode="))
        #expect(!httpMessage.contains("platformCode=503"))
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

private actor GatewayLogsTestGate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        _ = await stream.first(where: { _ in true })
    }

    func signal() {
        continuation.yield(())
    }
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
