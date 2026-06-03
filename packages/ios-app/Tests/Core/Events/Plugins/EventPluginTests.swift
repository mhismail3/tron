import XCTest
@testable import TronMobile

final class EventPluginTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EventRegistry.shared.clearForTesting()
    }

    // MARK: - Protocol Conformance Tests

    func testAllPluginsConformToProtocol() {
        // Verify that all plugins have a non-empty event type
        EventRegistry.shared.registerAll()
        XCTAssertGreaterThan(EventRegistry.shared.pluginCount, 0)
    }

    func testEventTypesAreUnique() {
        EventRegistry.shared.registerAll()
        let types = EventRegistry.shared.registeredTypes
        let uniqueTypes = Set(types)
        XCTAssertEqual(types.count, uniqueTypes.count, "Event types must be unique")
    }

    func testAllPluginsHaveNonEmptyEventType() {
        // Test a sample of plugins
        XCTAssertFalse(TextDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(ThinkingDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(CapabilityInvocationStartedPlugin.eventType.isEmpty)
        XCTAssertFalse(CapabilityInvocationCompletedPlugin.eventType.isEmpty)
        XCTAssertFalse(TurnStartPlugin.eventType.isEmpty)
        XCTAssertFalse(TurnEndPlugin.eventType.isEmpty)
        XCTAssertFalse(CompletePlugin.eventType.isEmpty)
        XCTAssertFalse(ErrorPlugin.eventType.isEmpty)
    }

    // MARK: - Registry Tests

    func testRegisterPlugin() {
        EventRegistry.shared.register(TextDeltaPlugin.self)
        XCTAssertTrue(EventRegistry.shared.hasPlugin(for: "agent.text_delta"))
        XCTAssertEqual(EventRegistry.shared.pluginCount, 1)
    }

    func testParseKnownEventType() {
        EventRegistry.shared.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "delta": "Hello, world!"
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "agent.text_delta", data: json)
        XCTAssertNotNil(result)

        if case .plugin(let type, _, let sessionId, _, let transform) = result {
            XCTAssertEqual(type, "agent.text_delta")
            XCTAssertEqual(sessionId, "session-123")

            let eventResult = transform()
            XCTAssertNotNil(eventResult)
            if let textResult = eventResult as? TextDeltaPlugin.Result {
                XCTAssertEqual(textResult.delta, "Hello, world!")
            } else {
                XCTFail("Expected TextDeltaPlugin.Result")
            }
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testParseUnknownEventType() {
        EventRegistry.shared.registerAll()

        let json = """
        {"type": "some.unknown.event"}
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "some.unknown.event", data: json)

        if case .unknown(let type) = result {
            XCTAssertEqual(type, "some.unknown.event")
        } else {
            XCTFail("Expected .unknown case")
        }
    }

    func testSessionIdExtraction() {
        EventRegistry.shared.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-456",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "agent.text_delta", data: json)
        XCTAssertEqual(result?.sessionId, "session-456")
    }

    func testSessionIdNilWhenMissing() {
        EventRegistry.shared.register(ConnectedPlugin.self)

        let json = """
        {
            "type": "connection.established",
            "data": { "serverId": "server-1" }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "connection.established", data: json)
        XCTAssertNil(result?.sessionId)
    }

    func testMatchesSession() {
        EventRegistry.shared.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-789",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "agent.text_delta", data: json)!

        XCTAssertTrue(result.matchesSession("session-789"))
        XCTAssertFalse(result.matchesSession("other-session"))
        XCTAssertFalse(result.matchesSession(nil))
    }

    func testMatchesSessionGlobalEvent() {
        EventRegistry.shared.register(ConnectedPlugin.self)

        let json = """
        {
            "type": "connection.established",
            "data": {}
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "connection.established", data: json)!

        // Global events (no sessionId) match any session
        XCTAssertTrue(result.matchesSession("any-session"))
        XCTAssertTrue(result.matchesSession(nil))
    }

    func testRegisteredPluginCount() {
        EventRegistry.shared.registerAll()
        // Should have all 27+ plugins registered
        XCTAssertGreaterThanOrEqual(EventRegistry.shared.pluginCount, 27)
    }

    func testApprovalPendingPluginParsesEngineStreamPayload() {
        EventRegistry.shared.registerAll()

        let json = """
        {
            "type": "approval.pending",
            "sessionId": "session-1",
            "timestamp": "2026-05-10T00:00:00Z",
            "data": {
                "type": "approval.pending",
                "approval": {
                    "approvalId": "approval-1",
                    "functionId": "worker::spawn",
                    "payload": {"workerId": "demo-worker"},
                    "authorityGrantId": "grant-1",
                    "authorityScopes": ["worker.write"],
                    "idempotencyKey": "spawn-key",
                    "targetMetadata": {
                        "effectClass": "ExternalSideEffect",
                        "riskLevel": "High",
                        "requiredAuthority": {
                            "scopes": ["worker.write"],
                            "approvalRequired": true
                        },
                        "idempotency": {
                            "keySource": "Caller",
                            "dedupeScope": "System",
                            "replayBehavior": "ReturnPrevious",
                            "ledgerKind": "EngineLedger"
                        },
                        "resourceLease": {
                            "resolverId": "payload_template",
                            "resourceKind": "worker",
                            "resourceIdTemplate": "worker:{workerId}",
                            "ttlMs": 60000,
                            "exclusive": true,
                            "streamTopic": "resource.leases",
                            "failureBehavior": "failClosed"
                        },
                        "compensation": {
                            "kind": "eventSourced",
                            "notes": "worker spawn is event sourced"
                        }
                    },
                    "status": "pending",
                    "sessionId": "session-1",
                    "traceId": "trace-1"
                }
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "approval.pending", data: json)
        XCTAssertEqual(result?.eventType, "approval.pending")
        XCTAssertEqual(result?.sessionId, "session-1")
        let pluginResult = result?.getResult() as? ApprovalPendingPlugin.Result
        XCTAssertEqual(pluginResult?.approval.authorityGrantId, "grant-1")
        XCTAssertEqual(pluginResult?.approval.authorityScopes, ["worker.write"])
        XCTAssertEqual(pluginResult?.approval.idempotencyKey, "spawn-key")
        XCTAssertEqual(pluginResult?.approval.targetMetadata?.effectClass, "ExternalSideEffect")
        XCTAssertEqual(pluginResult?.approval.targetMetadata?.requiredAuthority.approvalRequired, true)
        XCTAssertEqual(pluginResult?.approval.targetMetadata?.resourceLease?.resourceIdTemplate, "worker:{workerId}")
        XCTAssertEqual(pluginResult?.approval.targetMetadata?.compensation?.kind, "eventSourced")
    }

    func testApprovalPendingPluginUsesPlainWorkspaceAutonomyTextForSelfExtensionGrant() {
        EventRegistry.shared.registerAll()

        let json = """
        {
            "type": "approval.pending",
            "sessionId": "session-1",
            "timestamp": "2026-05-10T00:00:00Z",
            "data": {
                "type": "approval.pending",
                "approval": {
                    "approvalId": "approval-1",
                    "functionId": "self_extension::grant_workspace_autonomy",
                    "payload": {
                        "workspaceId": "workspace-1",
                        "workspacePath": "/Users/example/project"
                    },
                    "authorityGrantId": "grant-1",
                    "authorityScopes": ["self_extension.write"],
                    "idempotencyKey": "workspace-autonomy-key",
                    "status": "pending",
                    "sessionId": "session-1",
                    "workspaceId": "workspace-1",
                    "traceId": "trace-1"
                }
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "approval.pending", data: json)
        let pluginResult = result?.getResult() as? ApprovalPendingPlugin.Result

        XCTAssertEqual(pluginResult?.actionText, "Allow local capability work in this workspace")
        XCTAssertEqual(
            pluginResult?.reasonText,
            "Tron needs your approval before creating or updating a local capability in this workspace."
        )
        XCTAssertFalse(pluginResult?.actionText.contains("self_extension::grant_workspace_autonomy") == true)
        XCTAssertFalse(pluginResult?.reasonText.contains("approval-1") == true)
    }

    func testApprovalPendingPluginUsesPlainCleanupTextForWorkerDisconnect() {
        EventRegistry.shared.registerAll()

        let json = """
        {
            "type": "approval.pending",
            "sessionId": "session-1",
            "timestamp": "2026-05-10T00:00:00Z",
            "data": {
                "type": "approval.pending",
                "approval": {
                    "approvalId": "approval-1",
                    "functionId": "worker::disconnect",
                    "payload": {
                        "workerId": "disposable-helper",
                        "reason": "Clean up the disposable helper after the test run."
                    },
                    "authorityGrantId": "grant-1",
                    "authorityScopes": ["worker.write"],
                    "idempotencyKey": "disconnect-disposable-helper-v1",
                    "status": "pending",
                    "sessionId": "session-1",
                    "workspaceId": "workspace-1",
                    "traceId": "trace-1"
                }
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "approval.pending", data: json)
        let pluginResult = result?.getResult() as? ApprovalPendingPlugin.Result

        XCTAssertEqual(pluginResult?.actionText, "Stop local helper capability")
        XCTAssertEqual(
            pluginResult?.reasonText,
            "Tron needs your approval before stopping a local helper capability."
        )
        XCTAssertFalse(pluginResult?.actionText.contains("worker::disconnect") == true)
        XCTAssertFalse(pluginResult?.actionText.contains("disposable-helper") == true)
        XCTAssertFalse(pluginResult?.reasonText.contains("approval-1") == true)
    }

    func testApprovalPendingPluginUsesPlainLocalCommandTextForProcessRun() {
        EventRegistry.shared.registerAll()

        let json = """
        {
            "type": "approval.pending",
            "sessionId": "session-1",
            "timestamp": "2026-05-10T00:00:00Z",
            "data": {
                "type": "approval.pending",
                "approval": {
                    "approvalId": "approval-1",
                    "functionId": "process::run",
                    "payload": {
                        "command": "python3 -m py_compile /repo/disposable_tiny_helper.py > pycheck.txt 2>&1 || true",
                        "executionMode": "sandbox_materialized",
                        "expectedOutputs": [{"path": "pycheck.txt"}],
                        "timeoutMs": 10000
                    },
                    "authorityGrantId": "grant-1",
                    "authorityScopes": ["process.run"],
                    "idempotencyKey": "pycheck-disposable-helper",
                    "status": "pending",
                    "sessionId": "session-1",
                    "workspaceId": "workspace-1",
                    "traceId": "trace-1"
                }
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "approval.pending", data: json)
        let pluginResult = result?.getResult() as? ApprovalPendingPlugin.Result

        XCTAssertEqual(pluginResult?.actionText, "Run local command in a sandbox")
        XCTAssertEqual(
            pluginResult?.reasonText,
            "Tron needs your approval before running a local command for this workspace."
        )
        XCTAssertFalse(pluginResult?.actionText.contains("process::run") == true)
        XCTAssertFalse(pluginResult?.actionText.contains("py_compile") == true)
        XCTAssertFalse(pluginResult?.reasonText.contains("approval-1") == true)
    }

    @MainActor
    func testApprovalPendingPluginDispatchesPendingRecordsAsPending() {
        let context = MockEventDispatchContext()
        let approval = makeApprovalRecord(status: .pending)
        let result = ApprovalPendingPlugin.Result(approval: approval)

        ApprovalPendingPlugin.dispatch(result: result, context: context)

        XCTAssertEqual(context.handleApprovalPendingCalledWith?.approval.approvalId, "approval-1")
        XCTAssertNil(context.handleApprovalResolvedCalledWith)
    }

    @MainActor
    func testApprovalPendingPluginDispatchesTerminalRecordsAsResolved() {
        let context = MockEventDispatchContext()
        let approval = makeApprovalRecord(status: .executed)
        let result = ApprovalPendingPlugin.Result(approval: approval)

        ApprovalPendingPlugin.dispatch(result: result, context: context)

        XCTAssertNil(context.handleApprovalPendingCalledWith)
        XCTAssertEqual(context.handleApprovalResolvedCalledWith?.approval.status, .executed)
        XCTAssertNil(context.handleApprovalResolvedCalledWith?.child)
    }

    // MARK: - Source Control Plugin Contract Tests

    func testWorktreeMainSyncedPlugin_rejectsMissingRequiredPayloadField() {
        EventRegistry.shared.register(WorktreeMainSyncedPlugin.self)

        let json = """
        {
            "type": "worktree.main_synced",
            "sessionId": "session-1",
            "data": {
                "mainBranch": "main",
                "newHead": "def456",
                "advancedBy": 1
            }
        }
        """.data(using: .utf8)!

        XCTAssertNil(EventRegistry.shared.parse(type: "worktree.main_synced", data: json))
    }

    func testRepoMainAdvancedPlugin_rejectsMissingRequiredPayloadField() {
        EventRegistry.shared.register(RepoMainAdvancedPlugin.self)

        let json = """
        {
            "type": "repo.main_advanced",
            "data": {
                "repoRoot": "/repo",
                "oldHead": "abc123",
                "newHead": "def456",
                "cause": "sync"
            }
        }
        """.data(using: .utf8)!

        XCTAssertNil(EventRegistry.shared.parse(type: "repo.main_advanced", data: json))
    }

    func testWorktreePendingMergeDetectedPlugin_parsesOrigin() {
        EventRegistry.shared.register(WorktreePendingMergeDetectedPlugin.self)

        let json = """
        {
            "type": "worktree.pending_merge_detected",
            "sessionId": "session-1",
            "data": {
                "sourceBranch": "main",
                "targetBranch": "session/one",
                "strategy": "rebase",
                "origin": "rebase_on_main",
                "startedAtMs": 10,
                "autoAbortAtMs": 20
            }
        }
        """.data(using: .utf8)!

        let event = EventRegistry.shared.parse(type: "worktree.pending_merge_detected", data: json)
        let result = event?.getResult() as? WorktreePendingMergeDetectedPlugin.Result
        XCTAssertEqual(result?.origin, "rebase_on_main")
    }

    // MARK: - Session Archive/Unarchive Plugin Tests

    func testSessionArchivedPlugin_parsesFromTopLevelSessionId() {
        EventRegistry.shared.register(SessionArchivedPlugin.self)

        let json = """
        {
            "type": "session.archived",
            "sessionId": "sess-123",
            "timestamp": "2026-02-12T00:00:00Z",
            "data": {"sessionId": "sess-123"}
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "session.archived", data: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, "sess-123")

        if case .plugin(let type, _, _, _, let transform) = result {
            XCTAssertEqual(type, "session.archived")
            let eventResult = transform() as? SessionArchivedPlugin.Result
            XCTAssertEqual(eventResult?.sessionId, "sess-123")
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testSessionArchivedPlugin_parsesFromDataSessionId() {
        EventRegistry.shared.register(SessionArchivedPlugin.self)

        let json = """
        {
            "type": "session.archived",
            "data": {"sessionId": "sess-456"}
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "session.archived", data: json)
        if case .plugin(_, _, _, _, let transform) = result {
            let eventResult = transform() as? SessionArchivedPlugin.Result
            XCTAssertEqual(eventResult?.sessionId, "sess-456")
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testSessionUnarchivedPlugin_parses() {
        EventRegistry.shared.register(SessionUnarchivedPlugin.self)

        let json = """
        {
            "type": "session.unarchived",
            "sessionId": "sess-789",
            "data": {"sessionId": "sess-789"}
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "session.unarchived", data: json)
        XCTAssertNotNil(result)

        if case .plugin(let type, _, _, _, let transform) = result {
            XCTAssertEqual(type, "session.unarchived")
            let eventResult = transform() as? SessionUnarchivedPlugin.Result
            XCTAssertEqual(eventResult?.sessionId, "sess-789")
        } else {
            XCTFail("Expected .plugin case")
        }
    }
}

private func makeApprovalRecord(status: EngineApprovalStatus) -> EngineApprovalRecordDTO {
    EngineApprovalRecordDTO(
        approvalId: "approval-1",
        functionId: "process::run",
        payload: nil,
        actorId: "agent",
        actorKind: "Agent",
        authorityGrantId: "grant-1",
        authorityScopes: ["process.run"],
        traceId: "trace-1",
        parentInvocationId: "parent-1",
        sessionId: "session-1",
        workspaceId: nil,
        idempotencyKey: "approval-key",
        targetMetadata: nil,
        status: status,
        decisionActorId: status == .pending ? nil : "engine-user",
        decidedAt: status == .pending ? nil : "2026-05-10T00:00:00Z",
        createdAt: "2026-05-10T00:00:00Z",
        updatedAt: "2026-05-10T00:00:01Z"
    )
}
