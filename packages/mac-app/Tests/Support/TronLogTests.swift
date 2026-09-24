import Foundation
import Testing
@testable import TronMac

@Suite("TronLog")
struct TronLogTests {
    @Test("debug memory stays bounded and redacted files rotate within their segment cap")
    func debugMemoryAndPersistedRotation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = TronLog(logsDirectory: directory)
        let sensitiveMessage = "Bearer abc123 authorization: secret api-key=abc access_token=def "
            + "refresh-token=ghi password=jkl secret=mno /Users/alice/private /private/var/tmp/secret "
            + String(repeating: "x", count: 1_900)

        for index in 0..<1_200 {
            logger.record(.debug, event: "debug.detail", source: "test", message: sensitiveMessage)
            if index < 700 {
                logger.record(.info, event: "persisted.detail", source: "test", message: sensitiveMessage)
            }
        }
        await logger.flush()

        let debugRecords = await logger.debugBuffer()
        #expect(!debugRecords.isEmpty)
        #expect(debugRecords.count < 1_000)
        #expect(debugRecords.last?.message.contains("Bearer [REDACTED]") == true)
        #expect(debugRecords.last?.message.contains("[USER_PATH]") == true)

        let active = directory.appendingPathComponent("mac.jsonl")
        let rotated = directory.appendingPathComponent("mac.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let activeSize = try FileManager.default.attributesOfItem(atPath: active.path)[.size] as? NSNumber
        #expect((activeSize?.intValue ?? Int.max) <= 1_048_576)
        let persisted = try String(contentsOf: active, encoding: .utf8)
        #expect(persisted.contains("Bearer [REDACTED]"))
        #expect(persisted.contains("authorization: [REDACTED]"))
        #expect(persisted.contains("api-key=[REDACTED]"))
        #expect(persisted.contains("access_token=[REDACTED]"))
        #expect(persisted.contains("refresh-token=[REDACTED]"))
        #expect(persisted.contains("password=[REDACTED]"))
        #expect(persisted.contains("secret=[REDACTED]"))
        #expect(persisted.contains("[USER_PATH]"))
        #expect(persisted.contains("[PRIVATE_PATH]"))
        #expect(persisted.contains("/Users/alice") == false)
        #expect(persisted.contains("Bearer abc123") == false)
    }
}
