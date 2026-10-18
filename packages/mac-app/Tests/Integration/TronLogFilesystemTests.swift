import Foundation
import Testing
@testable import TronMac

@Suite("Mac diagnostic JSONL publication")
struct TronLogFilesystemTests {
    @Test func byteBoundPreservesUnicodeContextAndRedaction() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let directory = root.appendingPathComponent("logs")
        let log = TronLog(logsDirectory: directory)
        let messages = [
            "Short diagnostic",
            "诊断 ✓",
            String(repeating: "é", count: 1_000), // Exactly the byte cap; no truncation.
            "Cause:" + String(repeating: "a", count: 2_100),
            "Cause:" + String(repeating: "é", count: 1_100),
            "Cause:" + String(repeating: "界", count: 1_000),
            "Cause:" + String(repeating: "😀", count: 1_000)
        ]
        for (index, message) in messages.enumerated() {
            log.record(.info, event: "log.boundary.\(index)", source: "integration", message: message)
        }
        log.record(.error, event: "log.redaction", source: "integration",
                   message: "Cause: token=synthetic-secret\n" + String(repeating: "界", count: 1_000),
                   why: "Cause:" + String(repeating: "😀", count: 1_000))
        await log.flush()
        let file = directory.appendingPathComponent("mac.jsonl")
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(TronLog.Record.self, from: Data($0.utf8))
        }
        try #require(rows.count == messages.count + 1)
        for (index, original) in messages.enumerated() {
            let published = rows[index].message
            #expect(rows[index].event == "log.boundary.\(index)")
            if original.utf8.count <= 2_000 {
                #expect(published == original)
            } else {
                #expect(published.hasPrefix("Cause:"), "Byte clipping must not erase the diagnostic's leading context")
                #expect(published.hasSuffix("…"))
                #expect(original.hasPrefix(String(published.dropLast())))
                // At most three bytes may be discarded to complete a scalar;
                // don't satisfy the ceiling by throwing the whole message away.
                #expect((1_997...2_000).contains(published.utf8.count))
            }
        }
        let redacted = try #require(rows.last)
        #expect(!redacted.message.contains("synthetic-secret"))
        #expect(redacted.message.contains("[redacted:len="))
        #expect(redacted.message.hasPrefix("Cause:"))
        #expect(redacted.message.utf8.count <= 2_000)
        #expect(redacted.why?.hasPrefix("Cause:") == true)
        #expect(redacted.why?.count == 160)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
