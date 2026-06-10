import XCTest
@testable import TronMobile

/// Comprehensive tests for engine protocol types to ensure zero regressions during refactoring.
/// Tests cover Codable conformance, computed properties, and initializers.

// MARK: - Session Types Tests

@MainActor
final class SessionTypesTests: XCTestCase {

    // MARK: - SessionInfo Tests

    func testSessionInfoDecoding() throws {
        let json = """
        {
            "sessionId": "sess_123",
            "model": "claude-opus-4-5-20251101",
            "createdAt": "2026-01-26T00:00:00.000Z",
            "turnCount": 7,
            "messageCount": 10,
            "inputTokens": 1500,
            "outputTokens": 500,
            "lastTurnInputTokens": 2000,
            "cacheReadTokens": 100,
            "cacheCreationTokens": 50,
            "cost": 0.05,
            "isActive": true,
            "workingDirectory": "/tmp/tron-fixtures/test/project",
            "parentSessionId": null,
            "lastUserPrompt": "Hello",
            "lastAssistantResponse": "Hi there!"
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(SessionInfo.self, from: json)

        XCTAssertEqual(info.sessionId, "sess_123")
        XCTAssertEqual(info.model, "claude-opus-4-5-20251101")
        XCTAssertEqual(info.turnCount, 7)
        XCTAssertEqual(info.messageCount, 10)
        XCTAssertEqual(info.inputTokens, 1500)
        XCTAssertEqual(info.outputTokens, 500)
        XCTAssertEqual(info.lastTurnInputTokens, 2000)
        XCTAssertEqual(info.isActive, true)
        XCTAssertFalse(info.isFork)
    }

    func testSessionInfoIsFork() throws {
        let json = """
        {
            "sessionId": "sess_456",
            "model": "claude-sonnet-4-20250514",
            "createdAt": "2026-01-26T00:00:00.000Z",
            "messageCount": 5,
            "isActive": false,
            "parentSessionId": "sess_123"
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertTrue(info.isFork)
        XCTAssertEqual(info.parentSessionId, "sess_123")
    }

    func testSessionInfoDisplayName() throws {
        let json = """
        {
            "sessionId": "sess_abcdefghijklmnopqrstuvwxyz",
            "model": "test",
            "createdAt": "2026-01-26T00:00:00.000Z",
            "messageCount": 0,
            "isActive": true
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertEqual(info.displayName, "sess_abcdefghijklmno")
        XCTAssertEqual(info.displayName.count, 20)
    }

    func testSessionInfoFormattedTokens() throws {
        let json = """
        {
            "sessionId": "test",
            "model": "test",
            "createdAt": "2026-01-26T00:00:00.000Z",
            "messageCount": 0,
            "inputTokens": 1200,
            "outputTokens": 3400,
            "isActive": true
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertTrue(info.formattedTokens.contains("1.2k"))
        XCTAssertTrue(info.formattedTokens.contains("3.4k"))
    }

    func testSessionInfoFormattedCost() throws {
        let json1 = """
        {"sessionId": "t1", "model": "m", "createdAt": "2026-01-26T00:00:00Z", "messageCount": 0, "cost": 1.25, "isActive": true}
        """.data(using: .utf8)!
        let info1 = try JSONDecoder().decode(SessionInfo.self, from: json1)
        XCTAssertEqual(info1.formattedCost, "$1.25")

        let json2 = """
        {"sessionId": "t2", "model": "m", "createdAt": "2026-01-26T00:00:00Z", "messageCount": 0, "cost": 0.005, "isActive": true}
        """.data(using: .utf8)!
        let info2 = try JSONDecoder().decode(SessionInfo.self, from: json2)
        XCTAssertEqual(info2.formattedCost, "<$0.01")
    }

    // MARK: - SessionCreateParams Tests

    func testSessionCreateParamsEncoding() throws {
        let params = SessionCreateParams(
            workingDirectory: "/path/to/dir",
            model: "claude-opus-4-5-20251101",
            contextFiles: ["file1.md", "file2.md"]
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["workingDirectory"] as? String, "/path/to/dir")
        XCTAssertEqual(decoded["model"] as? String, "claude-opus-4-5-20251101")
        XCTAssertEqual(decoded["contextFiles"] as? [String], ["file1.md", "file2.md"])
    }

    // MARK: - SessionForkResult Tests

    func testSessionForkResultDecoding() throws {
        let json = """
        {
            "newSessionId": "sess_new",
            "forkedFromEventId": "evt_123",
            "forkedFromSessionId": "sess_old",
            "rootEventId": "evt_root"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(SessionForkResult.self, from: json)

        XCTAssertEqual(result.newSessionId, "sess_new")
        XCTAssertEqual(result.forkedFromEventId, "evt_123")
    }

    // MARK: - HistoryMessage Tests

    func testHistoryMessageDecoding() throws {
        let json = """
        {
            "id": "msg_123",
            "role": "assistant",
            "content": "Hello, how can I help?",
            "timestamp": "2026-01-26T00:00:00.000Z",
            "capabilityInvocations": [
                {
                    "id": "toolu_123",
                    "identity": {
                        "modelPrimitiveName": "execute",
                        "operationName": "file_read",
                        "traceId": "trace-file"
                    },
                    "input": {"file_path": "/test.txt"},
                    "result": "file contents",
                    "isError": false
                }
            ]
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(HistoryMessage.self, from: json)

        XCTAssertEqual(message.id, "msg_123")
        XCTAssertEqual(message.role, "assistant")
        XCTAssertEqual(message.capabilityInvocations?.count, 1)
        XCTAssertEqual(message.capabilityInvocations?[0].id, "toolu_123")
        XCTAssertEqual(message.capabilityInvocations?[0].identity?.operationName, "file_read")
        XCTAssertEqual(message.capabilityInvocations?[0].identity?.traceId, "trace-file")
    }
}

// MARK: - Token Types Tests

@MainActor
final class TokenTypesTests: XCTestCase {

    func testTokenUsageDecoding() throws {
        let json = """
        {
            "inputTokens": 1000,
            "outputTokens": 500,
            "cacheReadTokens": 100,
            "cacheCreationTokens": 50
        }
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(TokenUsage.self, from: json)

        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertEqual(usage.totalTokens, 1500)
        XCTAssertEqual(usage.cacheReadTokens, 100)
    }

    func testTokenUsageFormatting() throws {
        let json = """
        {"inputTokens": 12500, "outputTokens": 3400}
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(TokenUsage.self, from: json)

        XCTAssertEqual(usage.formattedInput, "12.5k")
        XCTAssertEqual(usage.formattedOutput, "3.4k")
        XCTAssertEqual(usage.formattedTotal, "15.9k")
    }

    // testAgentStateTokenUsage removed — AgentStateTokenUsage deleted in Phase 5
}

// MARK: - Event Types Tests

@MainActor
final class EventTypesTests: XCTestCase {

    func testRawEventDecoding() throws {
        let json = """
        {
            "id": "evt_123",
            "parentId": "evt_122",
            "sessionId": "sess_abc",
            "workspaceId": "ws_xyz",
            "type": "message.user",
            "timestamp": "2026-01-26T00:00:00.000Z",
            "sequence": 5,
            "payload": {"text": "Hello"}
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RawEvent.self, from: json)

        XCTAssertEqual(event.id, "evt_123")
        XCTAssertEqual(event.parentId, "evt_122")
        XCTAssertEqual(event.sessionId, "sess_abc")
        XCTAssertEqual(event.type, "message.user")
        XCTAssertEqual(event.sequence, 5)
    }
}

// MARK: - Attachment Types Tests

@MainActor
final class AttachmentTypesTests: XCTestCase {

    func testFileAttachmentEncoding() throws {
        let fileData = "test file data".data(using: .utf8)!
        let attachment = FileAttachment(data: fileData, mimeType: "application/pdf", fileName: "test.pdf")

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        XCTAssertEqual(decoded["mimeType"] as? String, "application/pdf")
        XCTAssertEqual(decoded["fileName"] as? String, "test.pdf")
    }
}

// MARK: - System Types Tests

@MainActor
final class SystemTypesTests: XCTestCase {

    func testSystemInfoResultDecoding() throws {
        let json = """
        {"version": "1.2.3", "uptime": 3600, "activeSessions": 5}
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(SystemInfoResult.self, from: json)

        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.uptime, 3600)
        XCTAssertEqual(info.activeSessions, 5)
    }

}

// MARK: - Model Types Extended Tests

@MainActor
final class ModelTypesExtendedTests: XCTestCase {

    func testModelInfoIsLatestGeneration_usesIsRetiredFlag() throws {
        // isRetiredGeneration: false → isLatestGeneration: true
        let latest = createModelInfo(id: "claude-opus-4-6", isRetiredGeneration: false)
        XCTAssertTrue(latest.isLatestGeneration)

        // isRetiredGeneration: true → isLatestGeneration: false
        let retired = createModelInfo(id: "claude-sonnet-4-20250514", isRetiredGeneration: true)
        XCTAssertFalse(retired.isLatestGeneration)

        let currentOpenAI = createModelInfo(id: "gpt-5.5", provider: "openai-codex")
        XCTAssertTrue(currentOpenAI.isLatestGeneration)
    }

    func testModelInfoProviderFlags() throws {
        let anthropic = createModelInfo(id: "claude-opus-4-5", provider: "anthropic")
        XCTAssertTrue(anthropic.isAnthropic)
        XCTAssertFalse(anthropic.isCodex)
        XCTAssertFalse(anthropic.isGemini)

        let codex = createModelInfo(id: "gpt-5-codex", provider: "openai-codex")
        XCTAssertFalse(codex.isAnthropic)
        XCTAssertTrue(codex.isCodex)

        let gemini = createModelInfo(id: "gemini-3-pro", provider: "google", family: "Gemini 3")
        XCTAssertTrue(gemini.isGemini)
        XCTAssertTrue(gemini.isGemini3)
    }

    func testModelInfoIsGemini3_usesFamily() throws {
        let gemini3 = createModelInfo(id: "gemini-3-pro", provider: "google", family: "Gemini 3")
        XCTAssertTrue(gemini3.isGemini3)

        let gemini25 = createModelInfo(id: "gemini-2.5-pro", provider: "google", family: "Gemini 2.5")
        XCTAssertFalse(gemini25.isGemini3)

        let noFamily = createModelInfo(id: "gemini-x", provider: "google")
        XCTAssertFalse(noFamily.isGemini3)
    }

    func testModelInfoGeminiTier_usesTierField() throws {
        let pro = createModelInfo(id: "gemini-3-pro-preview", provider: "google", tier: "pro")
        XCTAssertEqual(pro.geminiTier, "pro")

        let flash = createModelInfo(id: "gemini-3-flash", provider: "google", tier: "flash")
        XCTAssertEqual(flash.geminiTier, "flash")

        let flashLite = createModelInfo(id: "gemini-3-flash-lite", provider: "google", tier: "flash-lite")
        XCTAssertEqual(flashLite.geminiTier, "flash-lite")

        let notGemini = createModelInfo(id: "claude-opus", provider: "anthropic", tier: "opus")
        XCTAssertNil(notGemini.geminiTier)
    }

    func testModelInfoIsPreview() throws {
        let preview = createModelInfo(id: "gemini-3-pro-preview")
        XCTAssertTrue(preview.isPreview)

        let stable = createModelInfo(id: "claude-opus-4-5-20251101")
        XCTAssertFalse(stable.isPreview)
    }

    func testModelInfoSortOrderDecoding() throws {
        // I8: the five required fields must be present on the wire.
        let json = """
        {"id": "claude-opus-4-6", "name": "Opus 4.6", "provider": "anthropic", "contextWindow": 200000, "supportsThinking": true, "supportsImages": true, "supportsDocuments": true, "tier": "opus", "isLegacy": false, "sortOrder": 0}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(ModelInfo.self, from: json)
        XCTAssertEqual(model.sortOrder, 0)
    }

    func testModelInfoDisplayName() throws {
        let claude = createModelInfo(id: "claude-opus-4-6", provider: "anthropic", name: "Opus 4.6")
        XCTAssertEqual(claude.displayName, "Claude Opus 4.6")

        let gemini = createModelInfo(id: "gemini-3-pro", provider: "google", name: "Gemini 3 Pro")
        XCTAssertEqual(gemini.displayName, "Gemini 3 Pro")
    }

    private func createModelInfo(
        id: String,
        provider: String = "anthropic",
        name: String? = nil,
        tier: String = "sonnet",
        family: String? = nil,
        isRetiredGeneration: Bool = false,
        sortOrder: Int? = nil
    ) -> ModelInfo {
        // I8: the five required fields (supportsThinking/Images/Documents,
        // tier, isRetiredGeneration) have no defaults. The server always emits them.
        ModelInfo(
            id: id,
            name: name ?? id,
            provider: provider,
            contextWindow: 200_000,
            supportsThinking: false,
            supportsImages: false,
            supportsDocuments: false,
            tier: tier,
            isRetiredGeneration: isRetiredGeneration,
            family: family,
            sortOrder: sortOrder
        )
    }
}

// MARK: - Engine Protocol Base Types Tests

@MainActor
final class EngineProtocolBaseTypesTests: XCTestCase {

    func testEngineFunctionCallEncoding() throws {
        struct TestParams: Encodable {
            let name: String
            let value: Int
        }
        struct TestInvokeFrame<P: Encodable>: Encodable {
            let type = "invoke"
            let id = "test-id"
            let functionId: String
            let payload: P
            let idempotencyKey: String?
        }

        let request = TestInvokeFrame(
            functionId: "test::method",
            payload: TestParams(name: "test", value: 42),
            idempotencyKey: nil
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["type"] as? String, "invoke")
        XCTAssertEqual(decoded["id"] as? String, "test-id")
        XCTAssertEqual(decoded["functionId"] as? String, "test::method")

        let payload = decoded["payload"] as! [String: Any]
        XCTAssertEqual(payload["name"] as? String, "test")
        XCTAssertEqual(payload["value"] as? Int, 42)
    }

    func testEngineFunctionCallResponseDecoding() throws {
        struct TestResult: Decodable {
            let data: String
        }
        struct Response<T: Decodable>: Decodable {
            let id: String?
            let ok: Bool
            let result: T?
            let error: EngineProtocolError?
        }

        let json = """
        {"type":"response","id":"123","ok":true,"result":{"child":{"value":{"data":"hello"}}},"error":null}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(Response<EngineFunctionCallEnvelope<TestResult>>.self, from: json)

        XCTAssertEqual(response.id, "123")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.child.value?.data, "hello")
        XCTAssertNil(response.error)
    }

    func testEngineErrorDecoding() throws {
        let json = """
        {"code":"SESSION_NOT_FOUND","category":"not_found","message":"Session not found","retryable":false,"recoverable":true,"origin":"transport","details":null,"traceId":"trace-1"}
        """.data(using: .utf8)!

        let error = try JSONDecoder().decode(EngineProtocolError.self, from: json)

        XCTAssertEqual(error.code, "SESSION_NOT_FOUND")
        XCTAssertEqual(error.category, "not_found")
        XCTAssertEqual(error.message, "Session not found")
        XCTAssertFalse(error.retryable)
        XCTAssertTrue(error.recoverable)
        XCTAssertEqual(error.origin, "transport")
        XCTAssertEqual(error.failure.traceId, "trace-1")
        XCTAssertEqual(error.errorDescription, "Session not found")
    }

    func testEngineErrorCodeCoversFailureSemanticsMatrixCodes() {
        let requiredCodes: [EngineErrorCode] = [
            .sessionNotFound,
            .eventNotFound,
            .workspaceNotFound,
            .blobNotFound,
            .eventStoreBusy,
            .eventStoreFailure,
            .authNotConfigured,
            .authTokenExpired,
            .authOauthError,
            .authStorageError,
            .authTransportError,
        ]

        let rawValues = Set(EngineErrorCode.allCases.map(\.rawValue))

        for code in requiredCodes {
            XCTAssertTrue(rawValues.contains(code.rawValue), "missing \(code.rawValue)")
        }
    }

    func testEngineErrorDiagnosticSummaryIncludesContractContextAndRedactsPayload() throws {
        let error = EngineProtocolError(
            code: "INVALID_PARAMS",
            category: "invalid_request",
            message: "additional property is not allowed",
            retryable: false,
            recoverable: true,
            origin: "transport",
            details: [
                "direction": AnyCodable("request"),
                "functionId": AnyCodable("session::list"),
                "property": AnyCodable("workingDirectory"),
                "payload": AnyCodable(["workingDirectory": "/tmp/tron-fixtures/example/project"]),
            ]
        )

        let summary = error.diagnosticSummary

        XCTAssertTrue(summary.contains("INVALID_PARAMS"))
        XCTAssertTrue(summary.contains("functionId=session::list"))
        XCTAssertTrue(summary.contains("property=workingDirectory"))
        XCTAssertTrue(summary.contains("payload=redacted"))
        XCTAssertFalse(summary.contains("/tmp/tron-fixtures/example/project"))
    }
}
