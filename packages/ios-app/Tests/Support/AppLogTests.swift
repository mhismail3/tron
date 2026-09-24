import Foundation
import Testing
@testable import TronMobile

@Suite("Always-on AppLog")
struct AppLogTests {
    private func temporaryLog() throws -> (AppLog, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "app-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AppLog(fileURL: directory.appending(path: "app.jsonl")), directory.appending(path: "app.jsonl"), directory)
    }

    @Test("the AppLog ring evicts oldest entries within its count bound")
    func ringCountBound() async throws {
        let (log, _, directory) = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<(AppLog.maximumRecords + 3) {
            await log.recordCausal(name: "fixture.\(index)")
        }
        let records = await log.snapshot()
        #expect(records.count == AppLog.maximumRecords)
        #expect(records.first?.event == "fixture.3")
        #expect(records.last?.event == "fixture.\(AppLog.maximumRecords + 2)")
        await log.flush()
    }

    @Test("the AppLog ring also evicts oldest entries to stay within its byte bound")
    func ringByteBound() async throws {
        let (log, _, directory) = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<AppLog.maximumRecords {
            await log.recordCausal(name: "fixture.\(index)", details: String(repeating: "x", count: 512))
        }
        let records = await log.snapshot()
        let bytes = records.reduce(0) { $0 + $1.timestamp.utf8.count + $1.event.utf8.count + $1.source.utf8.count + $1.message.utf8.count + 128 }
        #expect(bytes <= AppLog.maximumBufferBytes)
        #expect(records.last?.event == "fixture.\(AppLog.maximumRecords - 1)")
        await log.flush()
    }

    @Test("flushed info records are restored by a new AppLog instance")
    func relaunchRestoresInfoRecords() async throws {
        let (_, url, directory) = try temporaryLog()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
            try? FileManager.default.removeItem(at: directory)
        }
        let first = AppLog(fileURL: url)
        await first.recordCausal(name: "app.foregrounded", outcome: "success")
        await first.flush()

        let relaunched = AppLog(fileURL: url)
        let records = await relaunched.snapshot()
        #expect(records.map(\.event) == ["app.foregrounded"])
        #expect(records.first?.level == "info")
    }

    @Test("rotation retains newest records across two bounded segments")
    func rotationKeepsNewestRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "app-log-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "app.jsonl")
        let segmentCap = 2_000
        let log = AppLog(fileURL: url, maximumSegmentBytes: segmentCap)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<16 {
            await log.recordCausal(name: "rotation.\(index)", details: String(repeating: "x", count: 400))
            await log.flush()
        }
        let previousURL = url.appendingPathExtension("1")
        let currentSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let previousSize = (try FileManager.default.attributesOfItem(atPath: previousURL.path)[.size] as? Int) ?? 0
        let restored = await AppLog(fileURL: url, maximumSegmentBytes: segmentCap).snapshot()
        #expect(currentSize <= segmentCap)
        #expect(previousSize <= segmentCap)
        #expect(currentSize + previousSize <= AppLog.maximumFileBytes)
        #expect(restored.last?.event == "rotation.15")
        #expect(restored.contains { $0.event == "rotation.14" })
    }

    @Test("debug RPC records stay in the ring but are never persisted")
    func debugRPCIsRingOnly() async throws {
        let (log, url, directory) = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        await log.recordRPC(method: "system.logs.list", requestID: "request-1", outcome: "success",
            code: nil, durationMilliseconds: 4, profileID: "profile-1", connectionID: 7)
        #expect((await log.snapshot()).map(\.event) == ["rpc.completed"])
        await log.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
