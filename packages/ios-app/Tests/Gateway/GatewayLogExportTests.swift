import Foundation
import Testing
@testable import TronMobile

struct GatewayLogExportTests {
    @Test("built app carries a validated source identity independently of Gateway metadata")
    func bundledSourceIdentity() {
        #expect(IOSBuildIdentity.sourceRevision() != nil)
    }

    @Test("structured RPC correlation survives decoding and export without arbitrary data")
    func structuredCorrelation() throws {
        let data = Data(#"{"timestamp":"2026-01-01T00:00:00Z","level":"error","message":"RPC failed","method":"session.processTranscript.open","requestID":"request-7","code":"busy","reason":"viewer_capacity","outcome":"failure","durationMs":1542,"params":{"prompt":"private-prompt"}}"#.utf8)
        let row = try JSONDecoder().decode(GatewayLogRecord.self, from: data)
        var metadata = GatewayLogCaptureMetadata.empty
        metadata.appSourceRevision = String(repeating: "a", count: 40) + "-dirty"
        let exported = GatewayLogExport.text(records: [GatewayProfileLogRecord(profileID: "fixture", profileLabel: "fixture", record: row)], metadata: metadata)
        for field in ["method=session.processTranscript.open", "requestID=request-7", "code=busy", "reason=viewer_capacity", "outcome=failure", "durationMs=1542", "appSourceRevision=" + String(repeating: "a", count: 40) + "-dirty"] {
            #expect(exported.contains(field))
        }
        #expect(!exported.contains("private-prompt"))
        let concurrent = try JSONDecoder().decode(GatewayLogRecord.self, from: Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "request-7", with: "request-8").utf8))
        #expect(row.id != concurrent.id)
        let unsafe = GatewayLogRecord(timestamp: "now", level: "error", message: "safe", method: "/Users/private/path", requestID: String(repeating: "x", count: 161), code: "line\nbreak", durationMs: -1)
        let rejected = GatewayLogExport.text(records: [GatewayProfileLogRecord(profileID: "fixture", profileLabel: "fixture", record: unsafe)], metadata: .empty)
        for field in ["method=", "requestID=", "code=", "durationMs=", "/Users/private"] { #expect(!rejected.contains(field)) }
    }

    private func record(at date: Date = .now, message: String = "queuedBytes=44", event: String = "gateway.connection") -> GatewayProfileLogRecord {
        GatewayProfileLogRecord(profileID: "fixture:ios-client", profileLabel: "Private customer label",
            record: GatewayLogRecord(timestamp: GatewayTimestamp.preciseString(from: date), level: "warning",
                message: message, event: event, source: "ios-client"))
    }

    @Test("diagnostic JSONL export includes app provenance and redacts private log content")
    func diagnosticJSONL() throws {
        let row = record(at: Date(timeIntervalSince1970: 1_767_225_600), message: "path=/Users/private/token authorization=Bearer secret")
        let local = AppLogRecord(
            timestamp: "2026-01-01T00:00:00Z", level: "info", event: "app.started",
            source: "lifecycle", message: "build=fixture", process: "ios", requestID: nil,
            durationMs: nil, outcome: nil, code: nil, profileID: nil, connectionID: nil,
            lifecycleGeneration: nil
        )
        let metadata = GatewayLogCaptureMetadata(
            capturedAt: "fixture-load", representedFrom: "2026-01-01T00:00:00Z",
            representedThrough: "2026-01-01T00:00:01Z", appBuildIdentity: "fixture-build",
            gatewayIdentities: ["fixture": "runtime=fixture-epoch sourceRevision=abcdef"],
            sourceStatuses: ["fixture": "failed-retained"]
        )
        let text = GatewayLogExport.jsonLines(records: [row], metadata: metadata, appRecords: [local])
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(text.contains("diagnostics.exported"))
        #expect(text.contains("\"process\":\"gateway\""))
        #expect(text.contains("app.started"))
        let head = try JSONDecoder().decode(AppLogRecord.self, from: Data(lines[0].utf8))
        #expect(head.message.contains("failed-retained"))
        #expect(head.message.contains("runtime=fixture-epoch"))
        #expect(head.message.contains("representedFrom=2026-01-01T00:00:00.000Z"))
        #expect(!text.contains("/Users/private"))
        #expect(!text.contains("secret"))
        for line in lines { _ = try JSONDecoder().decode(AppLogRecord.self, from: Data(line.utf8)) }
    }

    @Test("export bounds describe exactly the copied subset and redact every rendered row")
    func visibleRangeAndPrivacy() {
        let shown = Date(timeIntervalSince1970: 1_700_000_000.875)
        let metadata = GatewayLogCaptureMetadata(capturedAt: "load-time", representedFrom: "hidden-old",
            representedThrough: "hidden-new", appBuildIdentity: "0.1.0 (7)",
            gatewayIdentities: ["fixture": "runtime=fixture-runtime sourceRevision=abcdef"],
            sourceStatuses: ["fixture": "failed-retained"])
        let value = record(at: shown, message: "queuedBytes=44 path=/Users/private/sensitive authorization=Bearer abc.def password=sentinel https://private.example/path")
        let text = GatewayLogExport.text(records: [value], metadata: metadata, copiedAt: shown.addingTimeInterval(1))
        #expect(text.contains("representedFrom=2023-11-14T22:13:20.875Z"))
        #expect(text.contains("representedThrough=2023-11-14T22:13:20.875Z"))
        #expect(text.contains("failed-retained"))
        #expect(text.contains("runtime=fixture-runtime"))
        #expect(text.contains("appSourceRevision=unknown"))
        #expect(text.contains("queuedBytes=44"))
        for secret in ["hidden-old", "hidden-new", "Private customer", "abc.def", "sentinel", "/Users/private", "private.example"] {
            #expect(!text.contains(secret))
        }
    }

    @MainActor
    @Test("one-tap export shares a bounded local bundle while Gateway is disconnected")
    func appModelOfflineExports() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "diagnostic-cache-\(UUID().uuidString)")
        let artifactRoot = FileManager.default.temporaryDirectory.appending(path: "diagnostic-artifact-\(UUID().uuidString)")
        let store = SessionExportArtifactStore(root: artifactRoot, maximumBytes: 4_096, maximumTotalBytes: 8_192, maximumArtifacts: 3)
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "diagnostic-app-log-\(UUID().uuidString).jsonl")
        let model = AppModel(
            client: client,
            cache: SnapshotCache(root: cacheRoot),
            exportArtifacts: store,
            appLog: AppLog(fileURL: appLogURL)
        )
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: artifactRoot)
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
            Task { await model.teardown(); await client.close() }
        }
        await client.close()

        let retained = GatewayLogExport.jsonLines(
            records: [record(message: "path=/Users/private/token authorization=Bearer secret")],
            metadata: GatewayLogCaptureMetadata(
                capturedAt: "fixture-load", representedFrom: "old", representedThrough: "new",
                appBuildIdentity: "fixture", gatewayIdentities: ["fixture": "runtime=fixture"],
                sourceStatuses: ["fixture": "failed-retained"]
            ),
            appRecords: []
        )
        let result = try await model.exportDiagnostics(retained)
        guard case .share(let logsURL) = result else { Issue.record("disconnected export uploaded"); return }
        let logs = try String(contentsOf: logsURL, encoding: .utf8)
        #expect(logs.contains("diagnostics.exported"))
        #expect(logs.contains("\"process\":\"gateway\""))
        #expect(!logs.contains("/Users/private"))
        #expect(!logs.contains("secret"))
        #expect(await socket.sentFrames().isEmpty)

        await model.discardExportArtifact(logsURL)
    }

    @MainActor
    @Test("connected diagnostics export uses the advertised Gateway capability")
    func connectedExportIsSaved() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "diagnostic-cache-\(UUID().uuidString)")
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "diagnostic-app-log-\(UUID().uuidString).jsonl")
        let suite = "GatewayLogExport.connected.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profiles = GatewayProfileStore(defaults: defaults)
        let profile = GatewayProfile(id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device")
        try profiles.save(profile, token: "token", selecting: true)
        let model = AppModel(client: client, profiles: profiles, cache: SnapshotCache(root: cacheRoot), appLog: AppLog(fileURL: appLogURL))
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
            defaults.removePersistentDomain(forName: suite)
            Task { await model.teardown(); await client.close() }
        }
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["diagnostic-export.v1"]}"#.utf8))
        let responder = respondToConnectedExport(socket, failure: false)
        await model.start()
        #expect(model.diagnosticsAreReady)
        let exporting = Task { try await model.exportDiagnostics("fixture-jsonl") }
        let request = try #require(await responder.value)
        let result = try await exporting.value
        guard case .saved(let path) = result else { Issue.record("connected export did not return saved path"); return }
        #expect(path == "/tmp/device-exports/fixture.jsonl")
        #expect(request.method == "system.logs.export")
        await model.appLog.flush()
    }

    @MainActor
    @Test("connected export failure is logged and falls back to local sharing")
    func failedUploadSharesAndRecordsWarning() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "diagnostic-cache-\(UUID().uuidString)")
        let artifactRoot = FileManager.default.temporaryDirectory.appending(path: "diagnostic-artifact-\(UUID().uuidString)")
        let appLogURL = FileManager.default.temporaryDirectory.appending(path: "diagnostic-app-log-\(UUID().uuidString).jsonl")
        let suite = "GatewayLogExport.failed.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profiles = GatewayProfileStore(defaults: defaults)
        let profile = GatewayProfile(id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device")
        try profiles.save(profile, token: "token", selecting: true)
        let model = AppModel(client: client, profiles: profiles, cache: SnapshotCache(root: cacheRoot),
            exportArtifacts: SessionExportArtifactStore(root: artifactRoot, maximumBytes: 4_096, maximumTotalBytes: 8_192, maximumArtifacts: 3),
            appLog: AppLog(fileURL: appLogURL))
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: artifactRoot)
            try? FileManager.default.removeItem(at: appLogURL)
            try? FileManager.default.removeItem(at: appLogURL.appendingPathExtension("1"))
            defaults.removePersistentDomain(forName: suite)
            Task { await model.teardown(); await client.close() }
        }
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["diagnostic-export.v1"]}"#.utf8))
        let responder = respondToConnectedExport(socket, failure: true)
        await model.start()
        #expect(model.diagnosticsAreReady)
        let exporting = Task { try await model.exportDiagnostics("fixture-jsonl") }
        let request = try #require(await responder.value)
        let result = try await exporting.value
        guard case .share(let file) = result else { Issue.record("failed upload did not fall back to share"); return }
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents == "fixture-jsonl")
        let records = await model.appLog.snapshot()
        #expect(records.contains { $0.event == "diagnostics.upload-failed" && $0.level == "warning" && $0.message.contains("code=timeout") })
        await model.discardExportArtifact(file)
        await model.appLog.flush()
    }

    private struct ExportRequest: Decodable { let id: String; let method: String }

    private func respondToConnectedExport(_ socket: ScriptedGatewaySocket, failure: Bool) -> Task<ExportRequest?, Never> {
        Task {
            var index = 1
            for _ in 0..<64 {
                do { try await socket.waitUntilSent(count: index + 1) } catch { return nil }
                let frames = await socket.sentFrames()
                guard index < frames.count,
                      let request = try? JSONDecoder().decode(ExportRequest.self, from: frames[index]) else {
                    index += 1
                    continue
                }
                if request.method == "system.logs.export" {
                    let result: [String: Any] = failure
                        ? ["code": "timeout", "message": "fixture failure", "retryable": true]
                        : ["path": "/tmp/device-exports/fixture.jsonl", "exportedAt": "2026-01-01T00:00:00Z"]
                    await socket.enqueue(response(id: request.id, ok: !failure, result: result))
                    return request
                }
                await socket.enqueue(response(id: request.id, ok: false,
                    result: ["code": "unsupported", "message": "unneeded fixture request", "retryable": false]))
                index += 1
            }
            return nil
        }
    }

    private func response(id: String, ok: Bool, result: [String: Any]) -> Data {
        let object: [String: Any] = ok
            ? ["type": "response", "id": id, "ok": true, "result": result]
            : ["type": "response", "id": id, "ok": false, "error": result]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("artifact retirement releases the bounded diagnostics share lease")
    func artifactRetirement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diagnostic-artifact-\(UUID().uuidString)")
        let store = SessionExportArtifactStore(root: root, maximumBytes: 4_096, maximumTotalBytes: 8_192, maximumArtifacts: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.writeText("local evidence", suggestedName: "capture.txt")
        await #expect(throws: URLError.self) {
            try await store.writeText("replacement", suggestedName: "replacement.txt")
        }
        await store.discard(first)
        let replacement = try await store.writeText("replacement", suggestedName: "replacement.txt")
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        await store.discard(replacement)
    }

    @Test("server uploads remain UTF-8 safe and bounded")
    func uploadBounds() throws {
        let encoder = JSONEncoder()
        let head = AppLogRecord(timestamp: "2026-01-01T00:00:00Z", level: "info", event: "diagnostics.exported",
            source: "lifecycle", message: "header=true", process: "ios", requestID: nil, durationMs: nil,
            outcome: nil, code: nil, profileID: nil, connectionID: nil, lifecycleGeneration: nil)
        let large = AppLogRecord(timestamp: "2026-01-01T00:00:00Z", level: "info", event: "fixture.large",
            source: "test", message: String(repeating: "é", count: 400), process: "ios", requestID: nil,
            durationMs: nil, outcome: nil, code: nil, profileID: nil, connectionID: nil, lifecycleGeneration: nil)
        let source = ([head] + Array(repeating: large, count: 1_000)).compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        let upload = GatewayLogExport.uploadText(source)
        #expect(upload.utf8.count <= GatewayLogExport.maximumUploadBytes)
        #expect(upload.contains("diagnostics.truncated"))
        #expect(String(decoding: upload.data(using: .utf8)!, as: UTF8.self) == upload)
        let lines = upload.split(separator: "\n")
        #expect(try JSONDecoder().decode(AppLogRecord.self, from: Data(try #require(lines.first).utf8)).event == "diagnostics.exported")
        #expect(try JSONDecoder().decode(AppLogRecord.self, from: Data(try #require(lines.last).utf8)).event == "diagnostics.truncated")
        for line in lines { _ = try JSONDecoder().decode(AppLogRecord.self, from: Data(line.utf8)) }
        #expect(GatewayLogExport.uploadText("small") == "small")
    }

    @Test("empty exports never reuse a prior represented range")
    func emptyRange() {
        let metadata = GatewayLogCaptureMetadata(capturedAt: "load", representedFrom: "old",
            representedThrough: "new", appBuildIdentity: "test", gatewayIdentities: [:], sourceStatuses: [:])
        let text = GatewayLogExport.text(records: [], metadata: metadata)
        #expect(text.contains("representedFrom=unknown"))
        #expect(text.contains("representedThrough=unknown"))
    }

    @Test("new store instances recover bounded incident and consumer context without Logs opening")
    func mailboxRetentionAndReload() async throws {
        let suite = "TronIncidentMailbox.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let now = Date.now
        let values = (0..<140).map { record(at: now.addingTimeInterval(-Double($0)), message: "sequence=\($0)") }
        store.record(values)
        let aggregate = GatewayEventConsumerDiagnostic(category: "session", phase: .wholeHandler,
            count: 40, slowCount: 1, maximumDuration: .milliseconds(250), totalDuration: .milliseconds(300),
            firstObservedAt: now.addingTimeInterval(-60), lastObservedAt: now)
        store.record(IOSClientDiagnosticBuffer.logRecord(aggregate))
        await store.flush()
        let reloaded = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let retained = await reloaded.load()
        #expect(retained.count <= IOSClientDiagnosticStore.maximumRecords)
        #expect(retained.contains { $0.record.event == "gateway.client-work" })
        #expect(retained.contains { $0.record.message == "sequence=0" })
        let data = try #require(UserDefaults(suiteName: suite)?.data(forKey: "tron.diagnostics.incidents.v1"))
        #expect(data.count <= IOSClientDiagnosticStore.maximumBytes)
        var buffer = IOSClientDiagnosticBuffer()
        buffer.mergePersisted(retained)
        #expect(buffer.records.allSatisfy { $0.record.source == "ios-client-retained" })
    }

    @Test("stalled mailbox eviction keeps the newest occurrence rather than arrival order")
    func mailboxOrdersByOccurrence() throws {
        let mailbox = IOSDiagnosticMailbox()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = record(at: now, message: "old")
        let baseNewer = record(at: now.addingTimeInterval(0.9), message: "newer")
        let newer = GatewayProfileLogRecord(profileID: baseNewer.profileID, profileLabel: baseNewer.profileLabel,
            record: GatewayLogRecord(timestamp: GatewayTimestamp.preciseString(from: now.addingTimeInterval(0.9)), level: baseNewer.record.level,
                message: baseNewer.record.message, event: baseNewer.record.event, source: baseNewer.record.source))
        mailbox.enqueue([old], drain: {})
        mailbox.enqueue([newer], drain: {})
        #expect(mailbox.take()?.first?.record.message == "newer")
    }

    @Test("expired, malformed and sensitive incidents cannot become retained diagnostics")
    func invalidStorageAndAgeBounds() async throws {
        let suite = "TronIncidentCorruption.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)?.set(Data("not-json".utf8), forKey: "tron.diagnostics.incidents.v1")
        let store = IOSClientDiagnosticStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(await store.load().isEmpty)
        let now = Date.now
        await store.save([
            record(at: now.addingTimeInterval(-IOSClientDiagnosticStore.maximumAge - 1), message: "expired-marker"),
            record(at: now, message: "path=/Users/private/file token=private-sentinel", event: "gateway.lifecycle"),
            record(at: now, message: "arbitrary payload", event: "unsupported.event")
        ], now: now)
        let retained = await store.load(now: now)
        #expect(retained.count == 1)
        #expect(retained.allSatisfy { !$0.record.message.contains("private-sentinel") && !$0.record.message.contains("/Users/private") })
    }

    @Test("consumer sample time is occurrence time rather than the time Logs opens")
    func consumerOccurrenceTimestamp() {
        let observed = Date(timeIntervalSince1970: 1_700_000_000.875)
        let value = GatewayEventConsumerDiagnostic(category: "session", phase: .synchronizationReadWait,
            count: 2, slowCount: 1, maximumDuration: .milliseconds(500), totalDuration: .milliseconds(510),
            firstObservedAt: observed.addingTimeInterval(-30), lastObservedAt: observed)
        let record = IOSClientDiagnosticBuffer.logRecord(value)
        #expect(GatewayTimestamp.parse(record.record.timestamp) == observed)
        #expect(record.record.message.contains("windowStartedAt=2023-11-14T22:12:50.875Z"))
        #expect(record.profileID.hasSuffix(":ios-client"))
    }
}
