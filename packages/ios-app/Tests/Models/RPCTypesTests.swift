import XCTest
@testable import TronMobile

/// Comprehensive tests for RPC types to ensure zero regressions during refactoring.
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
            "messageCount": 10,
            "inputTokens": 1500,
            "outputTokens": 500,
            "lastTurnInputTokens": 2000,
            "cacheReadTokens": 100,
            "cacheCreationTokens": 50,
            "cost": 0.05,
            "isActive": true,
            "workingDirectory": "/Users/test/project",
            "parentSessionId": null,
            "lastUserPrompt": "Hello",
            "lastAssistantResponse": "Hi there!"
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(SessionInfo.self, from: json)

        XCTAssertEqual(info.sessionId, "sess_123")
        XCTAssertEqual(info.model, "claude-opus-4-5-20251101")
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
            "rootEventId": "evt_root",
            "worktree": {
                "isolated": true,
                "branch": "session/fork-123",
                "baseCommit": "abc123",
                "path": "/path/to/worktree"
            }
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(SessionForkResult.self, from: json)

        XCTAssertEqual(result.newSessionId, "sess_new")
        XCTAssertEqual(result.forkedFromEventId, "evt_123")
        XCTAssertEqual(result.worktree?.isolated, true)
        XCTAssertEqual(result.worktree?.branch, "session/fork-123")
    }

    // MARK: - HistoryMessage Tests

    func testHistoryMessageDecoding() throws {
        let json = """
        {
            "id": "msg_123",
            "role": "assistant",
            "content": "Hello, how can I help?",
            "timestamp": "2026-01-26T00:00:00.000Z",
            "toolUse": [
                {
                    "toolName": "Read",
                    "toolCallId": "toolu_123",
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
        XCTAssertEqual(message.toolUse?.count, 1)
        XCTAssertEqual(message.toolUse?[0].toolName, "Read")
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

    func testAgentStateTokenUsage() throws {
        let json = """
        {"input": 1000, "output": 500}
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(AgentStateTokenUsage.self, from: json)

        XCTAssertEqual(usage.input, 1000)
        XCTAssertEqual(usage.output, 500)
        XCTAssertEqual(usage.totalTokens, 1500)
    }
}

// MARK: - Worktree Types Tests

@MainActor
final class WorktreeTypesTests: XCTestCase {

    func testWorktreeInfoDecoding() throws {
        let json = """
        {
            "isolated": true,
            "branch": "session/test-branch",
            "baseCommit": "abc123def456",
            "path": "/path/to/worktree",
            "hasUncommittedChanges": true,
            "commitCount": 3
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(WorktreeInfo.self, from: json)

        XCTAssertTrue(info.isolated)
        XCTAssertEqual(info.branch, "session/test-branch")
        XCTAssertEqual(info.shortBranch, "test-branch")
        XCTAssertEqual(info.hasUncommittedChanges, true)
    }

    func testWorktreeInfoShortBranchWithoutPrefix() throws {
        let json = """
        {
            "isolated": false,
            "branch": "main",
            "baseCommit": "abc123",
            "path": "/path"
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(WorktreeInfo.self, from: json)
        XCTAssertEqual(info.shortBranch, "main")
    }
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

// MARK: - Filesystem Types Tests

@MainActor
final class FilesystemTypesTests: XCTestCase {

    func testDirectoryEntryDecoding() throws {
        let json = """
        {
            "name": "test.txt",
            "path": "/path/to/test.txt",
            "isDirectory": false,
            "isSymlink": false,
            "size": 1024,
            "modifiedAt": "2026-01-26T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(DirectoryEntry.self, from: json)

        XCTAssertEqual(entry.name, "test.txt")
        XCTAssertEqual(entry.id, "/path/to/test.txt")
        XCTAssertFalse(entry.isDirectory)
    }

    func testSuggestedPathDecoding() throws {
        let json = """
        {"name": "Projects", "path": "/Users/test/Projects", "exists": true}
        """.data(using: .utf8)!

        let path = try JSONDecoder().decode(SuggestedPath.self, from: json)

        XCTAssertEqual(path.name, "Projects")
        XCTAssertEqual(path.id, "/Users/test/Projects")
        XCTAssertEqual(path.exists, true)
    }
}

// MARK: - Browser Types Tests

@MainActor
final class BrowserTypesTests: XCTestCase {

    func testBrowserGetStatusResultInit() {
        let status = BrowserGetStatusResult(
            hasBrowser: true,
            isStreaming: true,
            currentUrl: "https://example.com"
        )

        XCTAssertTrue(status.hasBrowser)
        XCTAssertTrue(status.isStreaming)
        XCTAssertEqual(status.currentUrl, "https://example.com")
    }

    func testBrowserFrameEventDecoding() throws {
        let json = """
        {
            "type": "browser.frame",
            "sessionId": "sess_123",
            "timestamp": "2026-01-26T00:00:00.000Z",
            "data": {
                "sessionId": "sess_123",
                "data": "base64encodeddata",
                "frameId": 42,
                "timestamp": 1706234567890.0,
                "metadata": {
                    "offsetTop": 0.0,
                    "pageScaleFactor": 1.0,
                    "deviceWidth": 1280.0,
                    "deviceHeight": 800.0
                }
            }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(BrowserFrameEvent.self, from: json)

        XCTAssertEqual(event.type, "browser.frame")
        XCTAssertEqual(event.frameData, "base64encodeddata")
        XCTAssertEqual(event.frameId, 42)
        XCTAssertEqual(event.metadata?.deviceWidth, 1280.0)
    }
}

// MARK: - Todo Types Tests

@MainActor
final class TodoTypesTests: XCTestCase {

    func testRpcTodoItemDecoding() throws {
        let json = """
        {
            "id": "todo_123",
            "content": "Fix the bug",
            "activeForm": "Fixing the bug",
            "status": "in_progress",
            "source": "agent",
            "createdAt": "2026-01-26T00:00:00.000Z",
            "completedAt": null,
            "metadata": null
        }
        """.data(using: .utf8)!

        let todo = try JSONDecoder().decode(RpcTodoItem.self, from: json)

        XCTAssertEqual(todo.id, "todo_123")
        XCTAssertEqual(todo.content, "Fix the bug")
        XCTAssertEqual(todo.status, .inProgress)
        XCTAssertEqual(todo.source, .agent)
    }

    func testTodoStatusDisplayName() {
        XCTAssertEqual(RpcTodoItem.TodoStatus.pending.displayName, "Pending")
        XCTAssertEqual(RpcTodoItem.TodoStatus.inProgress.displayName, "In Progress")
        XCTAssertEqual(RpcTodoItem.TodoStatus.completed.displayName, "Completed")
    }

    func testTodoStatusIcon() {
        XCTAssertEqual(RpcTodoItem.TodoStatus.pending.icon, "circle")
        XCTAssertEqual(RpcTodoItem.TodoStatus.inProgress.icon, "circle.fill")
        XCTAssertEqual(RpcTodoItem.TodoStatus.completed.icon, "checkmark.circle.fill")
    }

    func testBacklogReasonDisplayName() {
        XCTAssertEqual(RpcBackloggedTask.BacklogReason.sessionClear.displayName, "Session Cleared")
        XCTAssertEqual(RpcBackloggedTask.BacklogReason.contextCompact.displayName, "Context Compacted")
        XCTAssertEqual(RpcBackloggedTask.BacklogReason.sessionEnd.displayName, "Session Ended")
    }
}

// MARK: - Attachment Types Tests

@MainActor
final class AttachmentTypesTests: XCTestCase {

    func testImageAttachmentEncoding() throws {
        let imageData = "test image data".data(using: .utf8)!
        let attachment = ImageAttachment(data: imageData, mimeType: "image/png")

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        XCTAssertEqual(decoded["mimeType"] as? String, "image/png")
        XCTAssertNotNil(decoded["data"] as? String)
    }

    func testFileAttachmentEncoding() throws {
        let fileData = "test file data".data(using: .utf8)!
        let attachment = FileAttachment(data: fileData, mimeType: "application/pdf", fileName: "test.pdf")

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        XCTAssertEqual(decoded["mimeType"] as? String, "application/pdf")
        XCTAssertEqual(decoded["fileName"] as? String, "test.pdf")
    }
}

// MARK: - VoiceNotes Types Tests

@MainActor
final class VoiceNotesTypesTests: XCTestCase {

    func testVoiceNoteMetadataDecoding() throws {
        let json = """
        {
            "filename": "note_123.m4a",
            "filepath": "/path/to/note_123.m4a",
            "createdAt": "2026-01-26T00:00:00.000Z",
            "durationSeconds": 125.5,
            "language": "en",
            "preview": "This is a preview...",
            "transcript": "This is the full transcript of the voice note."
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(VoiceNoteMetadata.self, from: json)

        XCTAssertEqual(metadata.id, "note_123.m4a")
        XCTAssertEqual(metadata.durationSeconds, 125.5)
        XCTAssertEqual(metadata.formattedDuration, "2:05")
    }

    func testVoiceNoteMetadataDurationFormatting() throws {
        // Test minutes and seconds
        let json1 = """
        {"filename": "t1", "filepath": "/t1", "createdAt": "2026-01-26T00:00:00Z", "durationSeconds": 90.0, "preview": "p", "transcript": "t"}
        """.data(using: .utf8)!
        let m1 = try JSONDecoder().decode(VoiceNoteMetadata.self, from: json1)
        XCTAssertEqual(m1.formattedDuration, "1:30")

        // Test nil duration
        let json2 = """
        {"filename": "t2", "filepath": "/t2", "createdAt": "2026-01-26T00:00:00Z", "preview": "p", "transcript": "t"}
        """.data(using: .utf8)!
        let m2 = try JSONDecoder().decode(VoiceNoteMetadata.self, from: json2)
        XCTAssertEqual(m2.formattedDuration, "--:--")
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

    func testDeviceTokenRegisterParamsEncoding() throws {
        let params = DeviceTokenRegisterParams(
            deviceToken: "abc123",
            sessionId: "sess_123",
            workspaceId: "ws_456",
            environment: "production"
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["deviceToken"] as? String, "abc123")
        XCTAssertEqual(decoded["environment"] as? String, "production")
    }
}

// MARK: - Model Types Extended Tests

@MainActor
final class ModelTypesExtendedTests: XCTestCase {

    func testModelInfoIs45Model() throws {
        // Claude 4.5
        let claude45 = createModelInfo(id: "claude-opus-4-5-20251101")
        XCTAssertTrue(claude45.is45Model)

        // Claude 4 (not 4.5)
        let claude4 = createModelInfo(id: "claude-sonnet-4-20250514")
        XCTAssertFalse(claude4.is45Model)

        // GPT-5.2 Codex
        let gpt52 = createModelInfo(id: "gpt-5.2-codex", provider: "openai-codex")
        XCTAssertTrue(gpt52.is45Model)

        // Gemini 3
        let gemini3 = createModelInfo(id: "gemini-3-pro-preview", provider: "google")
        XCTAssertTrue(gemini3.is45Model)
    }

    func testModelInfoProviderFlags() throws {
        let anthropic = createModelInfo(id: "claude-opus-4-5", provider: "anthropic")
        XCTAssertTrue(anthropic.isAnthropic)
        XCTAssertFalse(anthropic.isCodex)
        XCTAssertFalse(anthropic.isGemini)

        let codex = createModelInfo(id: "gpt-5-codex", provider: "openai-codex")
        XCTAssertFalse(codex.isAnthropic)
        XCTAssertTrue(codex.isCodex)

        let gemini = createModelInfo(id: "gemini-3-pro", provider: "google")
        XCTAssertTrue(gemini.isGemini)
        XCTAssertTrue(gemini.isGemini3)
    }

    func testModelInfoGeminiTier() throws {
        let pro = createModelInfo(id: "gemini-3-pro-preview", provider: "google")
        XCTAssertEqual(pro.geminiTier, "pro")

        let flash = createModelInfo(id: "gemini-3-flash", provider: "google")
        XCTAssertEqual(flash.geminiTier, "flash")

        let flashLite = createModelInfo(id: "gemini-3-flash-lite", provider: "google")
        XCTAssertEqual(flashLite.geminiTier, "flash-lite")

        let notGemini = createModelInfo(id: "claude-opus", provider: "anthropic")
        XCTAssertNil(notGemini.geminiTier)
    }

    func testModelInfoIsPreview() throws {
        let preview = createModelInfo(id: "gemini-3-pro-preview")
        XCTAssertTrue(preview.isPreview)

        let stable = createModelInfo(id: "claude-opus-4-5-20251101")
        XCTAssertFalse(stable.isPreview)
    }

    private func createModelInfo(id: String, provider: String = "anthropic") -> ModelInfo {
        ModelInfo(
            id: id,
            name: id,
            provider: provider,
            contextWindow: 200_000,
            maxOutputTokens: nil,
            supportsThinking: nil,
            supportsImages: nil,
            tier: nil,
            isLegacy: nil,
            supportsReasoning: nil,
            reasoningLevels: nil,
            defaultReasoningLevel: nil,
            thinkingLevel: nil,
            supportedThinkingLevels: nil
        )
    }
}

// MARK: - RPC Base Types Tests

@MainActor
final class RPCBaseTypesTests: XCTestCase {

    func testRPCRequestEncoding() throws {
        struct TestParams: Encodable {
            let name: String
            let value: Int
        }

        let request = RPCRequest(method: "test.method", params: TestParams(name: "test", value: 42))

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(decoded["method"] as? String, "test.method")
        XCTAssertNotNil(decoded["id"] as? String)

        let params = decoded["params"] as! [String: Any]
        XCTAssertEqual(params["name"] as? String, "test")
        XCTAssertEqual(params["value"] as? Int, 42)
    }

    func testRPCResponseDecoding() throws {
        struct TestResult: Decodable {
            let data: String
        }

        let json = """
        {"id": "123", "success": true, "result": {"data": "hello"}, "error": null}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RPCResponse<TestResult>.self, from: json)

        XCTAssertEqual(response.id, "123")
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result?.data, "hello")
        XCTAssertNil(response.error)
    }

    func testRPCErrorDecoding() throws {
        let json = """
        {"code": "SESSION_NOT_FOUND", "message": "Session not found", "details": null}
        """.data(using: .utf8)!

        let error = try JSONDecoder().decode(RPCError.self, from: json)

        XCTAssertEqual(error.code, "SESSION_NOT_FOUND")
        XCTAssertEqual(error.message, "Session not found")
        XCTAssertEqual(error.errorDescription, "Session not found")
    }
}
