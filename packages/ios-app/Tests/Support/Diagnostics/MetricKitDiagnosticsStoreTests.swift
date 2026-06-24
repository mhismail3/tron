import Foundation
import Testing

@testable import TronMobile

@Suite("MetricKitDiagnosticsStore")
struct MetricKitDiagnosticsStoreTests {
    @Test("retention removes payloads older than max age")
    func retentionRemovesOldPayloads() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day: TimeInterval = 24 * 60 * 60
        let now = Date()
        let store = MetricKitDiagnosticsStore(
            directoryURL: directory,
            retention: MetricKitDiagnosticsRetention(maxAgeDays: 30, maxFiles: 50, maxTotalBytes: 10_000_000)
        )

        try store.storePayloadData(Data(#"{"old":true}"#.utf8), kind: .metrics, receivedAt: now.addingTimeInterval(-31 * day))
        try store.storePayloadData(Data(#"{"new":true}"#.utf8), kind: .diagnostics, receivedAt: now)

        let snapshot = try store.loadPayloads()
        #expect(snapshot.availableFileCount == 1)
        #expect(snapshot.files.first?.kind == .diagnostics)
    }

    @Test("retention caps file count")
    func retentionCapsFileCount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricKitDiagnosticsStore(
            directoryURL: directory,
            retention: MetricKitDiagnosticsRetention(maxAgeDays: 30, maxFiles: 2, maxTotalBytes: 10_000_000)
        )

        let now = Date()
        for i in 0..<4 {
            try store.storePayloadData(
                Data(#"{"index":\#(i)}"#.utf8),
                kind: .metrics,
                receivedAt: now.addingTimeInterval(TimeInterval(i))
            )
        }

        #expect(try store.storedPayloadFileCount() == 2)
        let snapshot = try store.loadPayloads()
        #expect(snapshot.files.count == 2)
    }

    @Test("load snapshot reports truncation")
    func loadSnapshotReportsTruncation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricKitDiagnosticsStore(
            directoryURL: directory,
            retention: MetricKitDiagnosticsRetention(maxAgeDays: 30, maxFiles: 10, maxTotalBytes: 10_000_000)
        )

        let now = Date()
        for i in 0..<3 {
            try store.storePayloadData(
                Data(#"{"index":\#(i)}"#.utf8),
                kind: .metrics,
                receivedAt: now.addingTimeInterval(TimeInterval(i))
            )
        }

        let snapshot = try store.loadPayloads(maxFiles: 1, maxBytes: 1_000_000)
        #expect(snapshot.truncated)
        #expect(snapshot.includedFileCount == 1)
        #expect(snapshot.availableFileCount == 3)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricKitDiagnosticsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
