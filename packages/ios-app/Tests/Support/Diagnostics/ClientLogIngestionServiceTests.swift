import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Client Log Ingestion Service")
struct ClientLogIngestionServiceTests {

    @Test("planner builds deterministic bounded batches")
    func plannerBuildsDeterministicBatches() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let logs: [(Date, LogCategory, LogLevel, String)] = [
            (date.addingTimeInterval(2), .engine, .info, "second"),
            (date, .websocket, .debug, "first"),
            (date.addingTimeInterval(1), .database, .warning, "middle"),
        ]

        let batch = ClientLogIngestionPlanner.makeBatch(from: logs, maxEntries: 2)
        let replay = ClientLogIngestionPlanner.makeBatch(from: logs, maxEntries: 2)

        #expect(batch?.entries.map(\.message) == ["middle", "second"])
        #expect(batch?.fingerprint == replay?.fingerprint)
        #expect(batch?.visibleEntryFingerprints.count == 2)
        #expect(batch?.idempotencyKey.rawValue.hasPrefix("ios:client-log-ingest:") == true)
    }

    @Test("planner suppresses already uploaded entries")
    func plannerSuppressesAlreadyUploadedEntries() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let logs: [(Date, LogCategory, LogLevel, String)] = [
            (date, .engine, .info, "same"),
            (date.addingTimeInterval(1), .engine, .warning, "new")
        ]

        let first = try #require(ClientLogIngestionPlanner.makeBatch(from: logs))
        let second = ClientLogIngestionPlanner.makeBatch(
            from: logs,
            uploadedEntryFingerprints: first.visibleEntryFingerprints
        )

        #expect(second == nil)

        let third = try #require(ClientLogIngestionPlanner.makeBatch(
            from: logs + [(date.addingTimeInterval(2), .engine, .error, "latest")],
            uploadedEntryFingerprints: first.visibleEntryFingerprints
        ))
        #expect(third.entries.map(\.message) == ["latest"])
    }

    @Test("planner redacts and orders entries deterministically")
    func plannerRedactsAndOrdersEntriesDeterministically() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let logs: [(Date, LogCategory, LogLevel, String)] = [
            (date, .engine, .info, #"Authorization: Bearer abcdefghijklmnopqrstuvwxyz"#),
            (date, .database, .warning, "z"),
            (date, .database, .warning, "a")
        ]

        let first = try #require(ClientLogIngestionPlanner.makeBatch(from: logs))
        let second = try #require(ClientLogIngestionPlanner.makeBatch(from: logs.reversed()))

        #expect(first.fingerprint == second.fingerprint)
        #expect(first.entries.map(\.message) == second.entries.map(\.message))
        #expect(first.entries.map(\.message) == [
            "a",
            "z",
            "Authorization: Bearer [redacted:len=26]"
        ])
    }

    @Test("planner omits successful ingestion plumbing without hiding failures")
    func plannerOmitsSuccessfulIngestionPlumbingWithoutHidingFailures() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let requestId = "A1B2C3"
        let logs: [(Date, LogCategory, LogLevel, String)] = [
            (date, .engine, .verbose, "→ Engine Invoke [\(requestId)] logs::ingest payload=redacted"),
            (date.addingTimeInterval(1), .websocket, .verbose, "→ SEND [logs::ingest] 128 bytes preview=redacted"),
            (date.addingTimeInterval(2), .websocket, .verbose, "Message sent successfully for logs::ingest id=\(requestId)"),
            (date.addingTimeInterval(3), .websocket, .verbose, "Waiting for response to logs::ingest id=\(requestId)..."),
            (date.addingTimeInterval(4), .websocket, .verbose, "Registered pending request id=\(requestId), total pending: 1"),
            (date.addingTimeInterval(5), .websocket, .verbose, #"Received string message #3: {"id":"\#(requestId)","ok":true}"#),
            (date.addingTimeInterval(6), .websocket, .debug, "Resolved engine response for id=\(requestId), remaining pending: 0"),
            (date.addingTimeInterval(7), .engine, .debug, "← Engine Response [\(requestId)] logs::ingest ✓ (12.3ms) result=redacted"),
            (date.addingTimeInterval(8), .websocket, .error, "Failed to send message for logs::ingest: connection lost"),
            (date.addingTimeInterval(9), .general, .warning, "Automatic client log ingestion failed after periodic: connection lost"),
            (date.addingTimeInterval(10), .engine, .debug, "← Engine Response [CAPABILITY] capability::execute ✓ (80.0ms) result=redacted"),
        ]

        let batch = try #require(ClientLogIngestionPlanner.makeBatch(from: logs))

        #expect(batch.entries.map(\.message) == [
            "Failed to send message for logs::ingest: connection lost",
            "Automatic client log ingestion failed after periodic: connection lost",
            "← Engine Response [CAPABILITY] capability::execute ✓ (80.0ms) result=redacted",
        ])
    }

    @Test("service uploads only when connected and avoids duplicate snapshot uploads")
    func serviceUploadsOnlyWhenConnectedAndAvoidsDuplicateSnapshots() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let state = ClientLogIngestionTestState(date: date)

        let endpoint = ClientLogIngestionEndpoint(
            isConnected: { state.connected },
            ingest: { entries, idempotencyKey in
                state.uploads.append((entries, idempotencyKey))
            }
        )
        let service = ClientLogIngestionService(
            endpoint: endpoint,
            logsProvider: { state.logs },
            retryDelay: 0
        )

        await service.flushNow(reason: "test-disconnected")
        #expect(state.uploads.isEmpty)

        state.connected = true
        await service.flushNow(reason: "test-connected")
        await service.flushNow(reason: "test-duplicate")
        #expect(state.uploads.count == 1)
        #expect(state.uploads[0].entries.map(\.message) == ["initial"])

        state.logs.append((date.addingTimeInterval(1), .engine, .warning, "next"))
        await service.flushNow(reason: "test-new-log")
        #expect(state.uploads.count == 2)
        #expect(state.uploads[1].entries.map(\.message) == ["next"])
    }

    @Test("endpoint changes cancel stale scheduled uploads")
    func endpointChangesCancelStaleScheduledUploads() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let state = ClientLogIngestionTestState(date: date)
        state.connected = true

        let oldEndpoint = ClientLogIngestionEndpoint(
            isConnected: { state.connected },
            ingest: { _, _ in
                state.oldEndpointUploads += 1
            }
        )
        let newEndpoint = ClientLogIngestionEndpoint(
            isConnected: { state.connected },
            ingest: { _, _ in
                state.newEndpointUploads += 1
            }
        )
        let service = ClientLogIngestionService(
            endpoint: oldEndpoint,
            logsProvider: { state.logs },
            retryDelay: 0
        )

        service.flushSoon(reason: "old")
        service.updateEndpoint(newEndpoint)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(state.oldEndpointUploads == 0)
        #expect(state.newEndpointUploads == 1)
    }

    @Test("endpoint changes do not let stale in-flight uploads block the new server")
    func endpointChangesDoNotLetStaleInflightUploadsBlockNewServer() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let state = ClientLogIngestionTestState(date: date)
        state.connected = true

        let oldEndpoint = ClientLogIngestionEndpoint(
            isConnected: { state.connected },
            ingest: { _, _ in
                state.oldEndpointStarted = true
                try await Task.sleep(for: .milliseconds(200))
                state.oldEndpointUploads += 1
            }
        )
        let newEndpoint = ClientLogIngestionEndpoint(
            isConnected: { state.connected },
            ingest: { _, _ in
                state.newEndpointUploads += 1
            }
        )
        let service = ClientLogIngestionService(
            endpoint: oldEndpoint,
            logsProvider: { state.logs },
            retryDelay: 0
        )

        service.flushSoon(reason: "old")
        while !state.oldEndpointStarted {
            await Task.yield()
        }
        service.updateEndpoint(newEndpoint)
        try? await Task.sleep(for: .milliseconds(250))

        #expect(state.oldEndpointUploads == 0)
        #expect(state.newEndpointUploads == 1)
    }
}

@MainActor
private final class ClientLogIngestionTestState {
    var connected = false
    var logs: [(Date, LogCategory, LogLevel, String)]
    var uploads: [(entries: [ClientLogEntry], key: EngineIdempotencyKey)] = []
    var oldEndpointStarted = false
    var oldEndpointUploads = 0
    var newEndpointUploads = 0

    init(date: Date) {
        logs = [
            (date, .engine, .info, "initial")
        ]
    }
}
