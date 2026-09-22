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

    @Test("share availability explains empty, loading, and unsupported states")
    func shareAvailability() {
        #expect(GatewayLogShareAvailability.resolve(
            hasVisibleLogs: false, gatewayInfoAvailable: true, supportsExport: true
        ) == .unavailable("No logs are available to share yet."))
        #expect(GatewayLogShareAvailability.resolve(
            hasVisibleLogs: true, gatewayInfoAvailable: false, supportsExport: false
        ) == .unavailable("The Gateway connection is still loading. Try again shortly."))
        #expect(GatewayLogShareAvailability.resolve(
            hasVisibleLogs: true, gatewayInfoAvailable: true, supportsExport: false
        ) == .unavailable("This Gateway does not support log sharing."))
        #expect(GatewayLogShareAvailability.resolve(
            hasVisibleLogs: true, gatewayInfoAvailable: true, supportsExport: true
        ) == .available)
    }

    private func record(at date: Date = .now, message: String = "queuedBytes=44", event: String = "gateway.connection") -> GatewayProfileLogRecord {
        GatewayProfileLogRecord(profileID: "fixture:ios-client", profileLabel: "Private customer label",
            record: GatewayLogRecord(timestamp: GatewayTimestamp.preciseString(from: date), level: "warning",
                message: message, event: event, source: "ios-client"))
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

    @Test("server uploads remain UTF-8 safe and bounded")
    func uploadBounds() {
        let source = String(repeating: "é", count: GatewayLogExport.maximumUploadBytes)
        let upload = GatewayLogExport.uploadText(source)
        #expect(upload.utf8.count <= GatewayLogExport.maximumUploadBytes)
        #expect(upload.contains("diagnostic export truncated"))
        #expect(String(decoding: upload.data(using: .utf8)!, as: UTF8.self) == upload)
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
