import Foundation
import Testing
@testable import TronMobile
@testable import TronMobileCore

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

    @Test("an operation interval still open at background is signed once, as backgrounded")
    func backgroundedIntervalIsSignedOnce() async throws {
        let (log, _, directory) = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signposts = AppLogSignposts(base: RecordingPerformanceSignposts(), log: log)

        let retired = signposts.begin(.sessionOpen)
        try await Task.sleep(for: .milliseconds(400))
        signposts.endOpenIntervalsAtBackground()
        let backgrounded = await signedOperationRecords(in: log, count: 1)
        #expect(backgrounded.map(\.event) == ["operation.sessionOpen"])
        #expect(backgrounded.first?.outcome == "backgrounded")
        #expect(backgrounded.first?.level == "warning")
        #expect((backgrounded.first?.durationMs ?? 0) >= 250)

        // The owner ending a retired interval writes no second record.
        signposts.end(retired, result: .failure, metrics: .none)
        // An interval opened after the background is not one the scene retired;
        // its own end still writes its single record past the threshold.
        let later = signposts.begin(.cacheLoad)
        try await Task.sleep(for: .milliseconds(400))
        signposts.end(later, result: .failure, metrics: .none)
        let records = await signedOperationRecords(in: log, count: 2)
        #expect(records.map(\.event) == ["operation.sessionOpen", "operation.cacheLoad"])
        #expect(records.map(\.outcome) == ["backgrounded", "failure"])
        #expect(records[1].level == "error")
    }

    @Test("a short interval the scene retired is signed backgrounded, never as its owner's failure")
    func backgroundedShortIntervalIsNotAFailure() async throws {
        let (log, _, directory) = try temporaryLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signposts = AppLogSignposts(base: RecordingPerformanceSignposts(), log: log)

        // The scene goes to the background while the operation is younger than the
        // record threshold, and the operation then unwinds as a failure because
        // the scene retired it. That failure is the background's, not the
        // operation's, so it must not read as an error-level failure.
        let retired = signposts.begin(.chatProjection)
        signposts.endOpenIntervalsAtBackground()
        try await Task.sleep(for: .milliseconds(400))
        signposts.end(retired, result: .failure, metrics: .none)

        let records = await signedOperationRecords(in: log, count: 1)
        #expect(records.count == 1)
        #expect(records.first?.event == "operation.chatProjection")
        #expect(records.first?.outcome == "backgrounded")
        #expect(records.first?.level == "warning")
        #expect((records.first?.durationMs ?? 0) >= 250)
    }

    private func signedOperationRecords(in log: AppLog, count: Int) async -> [AppLogRecord] {
        for _ in 0..<600 {
            let values = await log.snapshot().filter { $0.event.hasPrefix("operation.") }
            if values.count >= count { return values }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(count) operation record(s)")
        return await log.snapshot().filter { $0.event.hasPrefix("operation.") }
    }
}
