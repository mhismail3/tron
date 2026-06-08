import Foundation
import Testing
@testable import TronMac

@Suite("OnboardedSentinelWriter")
struct OnboardedSentinelWriterTests {
    @Test("touch creates the sentinel file")
    func touchCreates() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent(".onboarded", isDirectory: false)

        try OnboardedSentinelWriter.touch(at: path)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("touch is idempotent")
    func touchIsIdempotent() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent(".onboarded", isDirectory: false)

        try OnboardedSentinelWriter.touch(at: path)
        let first = try Data(contentsOf: path)

        // Sleep 20 ms to ensure ISO8601 timestamp differs.
        try await Task.sleep(nanoseconds: 20_000_000)
        try OnboardedSentinelWriter.touch(at: path)
        let second = try Data(contentsOf: path)

        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(second.isEmpty == false)
        #expect(first != second, "touch should rewrite the file with a fresh timestamp")
    }

    @Test("touch creates parent directory if missing")
    func parentCreated() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let nested = tmp.appendingPathComponent("a/b/c", isDirectory: true)
        let sentinel = nested.appendingPathComponent(".onboarded", isDirectory: false)

        try OnboardedSentinelWriter.touch(at: sentinel)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("no temp file leaks after successful write")
    func noLeakedTempFiles() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent(".onboarded", isDirectory: false)

        try OnboardedSentinelWriter.touch(at: path)

        let leftover = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
            .filter { $0.hasPrefix(".onboarded.") && $0.hasSuffix(".tmp") }
        #expect(leftover.isEmpty, "temp files left behind: \(leftover)")
    }

    @Test("written body is non-empty UTF-8 (timestamp)")
    func bodyIsTimestamp() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent(".onboarded", isDirectory: false)
        try OnboardedSentinelWriter.touch(at: path)

        let data = try Data(contentsOf: path)
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(body.contains("T"), "body should look like ISO8601: \(body)")
    }
}
