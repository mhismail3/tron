import Foundation
import Testing
@testable import TronMac

@Suite("TronLog")
struct TronLogTests {
    @Test("diagnostics redaction covers TronLog secrets and preserves plain text")
    func diagnosticsRedactionCoversTronLogCorpus() {
        let redactor = DiagnosticsRedactor()
        let corpus: [(input: String, logSecrets: [String], diagnosticsOnlySecrets: [String])] = [
            ("Upgrade: Bearer bearer-secret-123", ["bearer-secret-123"], []),
            ("Authorization: Bearer punctuation:secret?123", ["punctuation:secret?123"], []),
            ("api-key=api-secret-123", ["api-secret-123"], []),
            ("authorization: auth-secret-123", ["auth-secret-123"], []),
            ("access_token=access-secret-123", ["access-secret-123"], []),
            ("refresh-token: refresh-secret-123", ["refresh-secret-123"], []),
            ("password=password-secret-123 secret=secret-value-123", ["password-secret-123", "secret-value-123"], []),
            (#"{"password":"json-password-123","secret":"json-secret-123","code":"pairing-code-123"}"#, [], ["json-password-123", "json-secret-123", "pairing-code-123"]),
            ("home=/Users/alice/.tron/settings.json state=/private/var/tmp/state.json", ["/Users/alice/.tron/settings.json", "/private/var/tmp/state.json"], []),
        ]
        for entry in corpus {
            let logOutput = TronLog.redact(entry.input)
            let diagnosticsOutput = redactor.redactMessage(entry.input)
            for secret in entry.logSecrets {
                #expect(!logOutput.contains(secret), "TronLog leaked \\(secret)")
                #expect(!diagnosticsOutput.contains(secret), "DiagnosticsRedactor leaked \\(secret)")
            }
            for secret in entry.diagnosticsOnlySecrets {
                #expect(!diagnosticsOutput.contains(secret), "DiagnosticsRedactor leaked \\(secret)")
            }
        }
        #expect(redactor.redactMessage("retry count=3 notBearer hello") == "retry count=3 notBearer hello")
        #expect(TronLog.redact("retry count=3 notBearer hello") == "retry count=3 notBearer hello")

        // A URL's userinfo is a credential, so the log writer masks it too.
        let userinfoURL = "url=https://alice:password@example.test/private"
        #expect(redactor.redactMessage(userinfoURL) == "url=https://[redacted:userinfo]@example.test/private")
        #expect(TronLog.redact(userinfoURL) == "url=https://[redacted:userinfo]@example.test/private")

        // A plain address has no scheme, so it is not userinfo.
        let email = "contact=alice@example.test"
        #expect(redactor.redactMessage(email) == email)
        #expect(TronLog.redact(email) == email)
    }
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
        #expect(debugRecords.last?.message.contains("Bearer [redacted:len=6]") == true)
        #expect(debugRecords.last?.message.contains("[redacted:path]") == true)

        let active = directory.appendingPathComponent("mac.jsonl")
        let rotated = directory.appendingPathComponent("mac.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let activeSize = try FileManager.default.attributesOfItem(atPath: active.path)[.size] as? NSNumber
        #expect((activeSize?.intValue ?? Int.max) <= 1_048_576)
        let persisted = try String(contentsOf: active, encoding: .utf8)
        #expect(persisted.contains("Bearer [redacted:len=6]"))
        for secret in [
            "Bearer abc123", "authorization: secret", "api-key=abc", "access_token=def",
            "refresh-token=ghi", "password=jkl", "secret=mno", "/Users/alice/private",
            "/private/var/tmp/secret",
        ] {
            #expect(!persisted.contains(secret), "persisted diagnostics leaked \\(secret)")
        }
        #expect(persisted.contains("[redacted:path]"))
    }
}
