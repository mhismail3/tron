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

}
