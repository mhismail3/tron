//! Tests for SessionEvent, typed_payload, type guards, and state types.

#[cfg(test)]
mod session_event_tests {
    use serde_json::json;

    use crate::types::base::SessionEvent;
    use crate::types::{EventType, SessionEventPayload};

    fn make_event(event_type: EventType, payload: serde_json::Value) -> SessionEvent {
        SessionEvent {
            id: "evt-1".into(),
            parent_id: Some("evt-0".into()),
            session_id: "sess-1".into(),
            workspace_id: "ws-1".into(),
            timestamp: "2026-02-12T00:00:00.000Z".into(),
            event_type,
            sequence: 1,
            checksum: None,
            payload,
        }
    }

    #[test]
    fn serde_roundtrip_session_start() {
        let event = make_event(
            EventType::SessionStart,
            json!({
                "workingDirectory": "/Users/test/project",
                "model": "claude-opus-4-6",
                "provider": "anthropic"
            }),
        );
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "session.start");
        assert_eq!(json["id"], "evt-1");
        assert_eq!(json["parentId"], "evt-0");
        assert_eq!(json["sessionId"], "sess-1");
        assert_eq!(json["workspaceId"], "ws-1");
        assert_eq!(json["sequence"], 1);
        assert!(json.get("checksum").is_none());

        let back: SessionEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event, back);
    }

    #[test]
    fn serde_null_parent_id() {
        let mut event = make_event(
            EventType::SessionStart,
            json!({"workingDirectory": "/", "model": "m"}),
        );
        event.parent_id = None;
        let json = serde_json::to_value(&event).unwrap();
        assert!(json["parentId"].is_null());
    }

    #[test]
    fn serde_with_checksum() {
        let mut event = make_event(
            EventType::SessionStart,
            json!({"workingDirectory": "/", "model": "m"}),
        );
        event.checksum = Some("abc123".into());
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["checksum"], "abc123");
    }

    #[test]
    fn typed_payload_session_start() {
        let event = make_event(
            EventType::SessionStart,
            json!({
                "workingDirectory": "/test",
                "model": "claude-opus-4-6",
                "provider": "anthropic",
                "title": "My Session"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::SessionStart(p) => {
                assert_eq!(p.working_directory, "/test");
                assert_eq!(p.model, "claude-opus-4-6");
                assert_eq!(p.provider.as_deref(), Some("anthropic"));
                assert_eq!(p.title.as_deref(), Some("My Session"));
            }
            other => panic!("expected SessionStart, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_message_user() {
        let event = make_event(
            EventType::MessageUser,
            json!({ "content": "Hello", "turn": 1 }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MessageUser(p) => {
                assert_eq!(p.content, json!("Hello"));
                assert_eq!(p.turn, 1);
            }
            other => panic!("expected MessageUser, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_message_assistant() {
        let event = make_event(
            EventType::MessageAssistant,
            json!({
                "content": [{"type": "text", "text": "Hi there"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50},
                "stopReason": "end_turn",
                "model": "claude-opus-4-6"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MessageAssistant(p) => {
                assert_eq!(p.stop_reason, "end_turn");
                assert_eq!(p.token_usage.input_tokens, 100);
                assert_eq!(p.model, "claude-opus-4-6");
            }
            other => panic!("expected MessageAssistant, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_tool_call() {
        let event = make_event(
            EventType::ToolCall,
            json!({
                "toolCallId": "tc-1",
                "name": "bash",
                "arguments": {"command": "ls"},
                "turn": 1
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ToolCall(p) => {
                assert_eq!(p.tool_call_id, "tc-1");
                assert_eq!(p.name, "bash");
            }
            other => panic!("expected ToolCall, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_tool_result() {
        let event = make_event(
            EventType::ToolResult,
            json!({
                "toolCallId": "tc-1",
                "content": "file.txt",
                "isError": false,
                "duration": 250
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ToolResult(p) => {
                assert_eq!(p.tool_call_id, "tc-1");
                assert!(!p.is_error);
                assert_eq!(p.duration, 250);
            }
            other => panic!("expected ToolResult, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_compact_summary() {
        let event = make_event(
            EventType::CompactSummary,
            json!({
                "summary": "The user asked about Rust...",
                "boundaryEventId": "evt-42"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::CompactSummary(p) => {
                assert_eq!(p.boundary_event_id, "evt-42");
                assert!(p.summary.contains("Rust"));
            }
            other => panic!("expected CompactSummary, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_compact_boundary() {
        let event = make_event(
            EventType::CompactBoundary,
            json!({
                "range": {"from": "evt-1", "to": "evt-10"},
                "originalTokens": 50000,
                "compactedTokens": 5000
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::CompactBoundary(p) => {
                let range = p.range.unwrap();
                assert_eq!(range.from, "evt-1");
                assert_eq!(range.to, "evt-10");
                assert_eq!(p.original_tokens, 50000);
            }
            other => panic!("expected CompactBoundary, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_message_deleted() {
        let event = make_event(
            EventType::MessageDeleted,
            json!({
                "targetEventId": "evt-5",
                "targetType": "message.user"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MessageDeleted(p) => {
                assert_eq!(p.target_event_id, "evt-5");
                assert_eq!(p.target_type, "message.user");
            }
            other => panic!("expected MessageDeleted, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_config_model_switch() {
        let event = make_event(
            EventType::ConfigModelSwitch,
            json!({
                "previousModel": "claude-sonnet-4-5-20250929",
                "newModel": "claude-opus-4-6"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ConfigModelSwitch(p) => {
                assert_eq!(p.new_model, "claude-opus-4-6");
            }
            other => panic!("expected ConfigModelSwitch, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_config_reasoning_level() {
        let event = make_event(
            EventType::ConfigReasoningLevel,
            json!({
                "previousLevel": "medium",
                "newLevel": "high"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ConfigReasoningLevel(p) => {
                assert_eq!(p.new_level.as_deref(), Some("high"));
            }
            other => panic!("expected ConfigReasoningLevel, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_error_provider() {
        let event = make_event(
            EventType::ErrorProvider,
            json!({
                "provider": "anthropic",
                "error": "rate limited",
                "retryable": true
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ErrorProvider(p) => {
                assert_eq!(p.provider, "anthropic");
                assert!(p.retryable);
            }
            other => panic!("expected ErrorProvider, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_subagent_spawned() {
        let event = make_event(
            EventType::SubagentSpawned,
            json!({
                "subagentSessionId": "sess-child",
                "spawnType": "subsession",
                "task": "fix the bug",
                "model": "claude-opus-4-6",
                "workingDirectory": "/project"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::SubagentSpawned(p) => {
                assert_eq!(p.subagent_session_id, "sess-child");
                assert_eq!(p.spawn_type, "subsession");
            }
            other => panic!("expected SubagentSpawned, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_memory_ledger() {
        let event = make_event(
            EventType::MemoryLedger,
            json!({
                "eventRange": {"firstEventId": "e1", "lastEventId": "e10"},
                "turnRange": {"firstTurn": 1, "lastTurn": 5},
                "title": "Test session",
                "entryType": "feature",
                "status": "completed",
                "tags": ["rust"],
                "input": "implement types",
                "actions": ["created types"],
                "files": [{"path": "src/lib.rs", "op": "M", "why": "add module"}],
                "decisions": [{"choice": "flat struct", "reason": "wire compat"}],
                "lessons": ["use serde rename"],
                "thinkingInsights": [],
                "tokenCost": {"input": 1000, "output": 500},
                "model": "claude-opus-4-6",
                "workingDirectory": "/project"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MemoryLedger(p) => {
                assert_eq!(p.title, "Test session");
                assert_eq!(p.files.len(), 1);
                assert_eq!(p.files[0].op, "M");
            }
            other => panic!("expected MemoryLedger, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_memory_loaded() {
        let event = make_event(EventType::MemoryLoaded, json!({"some": "data"}));
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MemoryLoaded(v) => {
                assert_eq!(v["some"], "data");
            }
            other => panic!("expected MemoryLoaded, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_invalid_payload_returns_err() {
        let event = make_event(EventType::SessionStart, json!({"invalid": true}));
        assert!(event.typed_payload().is_err());
    }

    #[test]
    fn serde_roundtrip_every_event_type_with_minimal_payload() {
        // For each event type, create a minimal valid event and verify roundtrip
        let cases: Vec<(EventType, serde_json::Value)> = vec![
            (
                EventType::SessionStart,
                json!({"workingDirectory": "/", "model": "m"}),
            ),
            (EventType::SessionEnd, json!({"reason": "completed"})),
            (
                EventType::SessionFork,
                json!({"sourceSessionId": "s", "sourceEventId": "e"}),
            ),
            (EventType::MessageUser, json!({"content": "hi", "turn": 1})),
            (
                EventType::MessageAssistant,
                json!({"content": [], "turn": 1, "tokenUsage": {"inputTokens": 0, "outputTokens": 0}, "stopReason": "end_turn", "model": "m"}),
            ),
            (
                EventType::MessageSystem,
                json!({"content": "sys", "source": "context"}),
            ),
            (
                EventType::MessageDeleted,
                json!({"targetEventId": "e", "targetType": "message.user"}),
            ),
            (
                EventType::ToolCall,
                json!({"toolCallId": "tc", "name": "bash", "arguments": {}, "turn": 1}),
            ),
            (
                EventType::ToolResult,
                json!({"toolCallId": "tc", "content": "ok", "isError": false, "duration": 100}),
            ),
            (EventType::StreamTurnStart, json!({"turn": 1})),
            (
                EventType::StreamTurnEnd,
                json!({"turn": 1, "tokenUsage": {"inputTokens": 0, "outputTokens": 0}}),
            ),
            (
                EventType::StreamTextDelta,
                json!({"delta": "hi", "turn": 1}),
            ),
            (
                EventType::StreamThinkingDelta,
                json!({"delta": "hmm", "turn": 1}),
            ),
            (
                EventType::ConfigModelSwitch,
                json!({"previousModel": "a", "newModel": "b"}),
            ),
            (EventType::ConfigPromptUpdate, json!({"newHash": "abc"})),
            (EventType::ConfigReasoningLevel, json!({})),
            (
                EventType::NotificationInterrupted,
                json!({"timestamp": "t", "turn": 1}),
            ),
            (
                EventType::NotificationSubagentResult,
                json!({"parentSessionId": "p", "subagentSessionId": "s", "task": "t", "resultSummary": "r", "success": true, "totalTurns": 1, "duration": 100, "tokenUsage": {"inputTokens": 0, "outputTokens": 0}, "completedAt": "t"}),
            ),
            (
                EventType::CompactBoundary,
                json!({"range": {"from": "a", "to": "b"}, "originalTokens": 100, "compactedTokens": 10}),
            ),
            (
                EventType::CompactSummary,
                json!({"summary": "s", "boundaryEventId": "e"}),
            ),
            (
                EventType::ContextCleared,
                json!({"tokensBefore": 100, "tokensAfter": 0, "reason": "manual"}),
            ),
            (
                EventType::SkillAdded,
                json!({"skillName": "s", "source": "global", "addedVia": "mention"}),
            ),
            (
                EventType::SkillRemoved,
                json!({"skillName": "s", "removedVia": "manual"}),
            ),
            (
                EventType::RulesLoaded,
                json!({"files": [], "totalFiles": 0, "mergedTokens": 0}),
            ),
            (
                EventType::RulesIndexed,
                json!({"totalRules": 0, "globalRules": 0, "scopedRules": 0, "files": []}),
            ),
            (
                EventType::RulesActivated,
                json!({"rules": [], "totalActivated": 0}),
            ),
            (
                EventType::MetadataUpdate,
                json!({"key": "k", "newValue": "v"}),
            ),
            (EventType::MetadataTag, json!({"action": "add", "tag": "t"})),
            (EventType::FileRead, json!({"path": "/f"})),
            (
                EventType::FileWrite,
                json!({"path": "/f", "size": 100, "contentHash": "h"}),
            ),
            (
                EventType::FileEdit,
                json!({"path": "/f", "oldString": "a", "newString": "b"}),
            ),
            (
                EventType::WorktreeAcquired,
                json!({"path": "/w", "branch": "b", "baseCommit": "c", "isolated": true}),
            ),
            (
                EventType::WorktreeCommit,
                json!({"commitHash": "h", "message": "m", "filesChanged": []}),
            ),
            (
                EventType::WorktreeReleased,
                json!({"deleted": false, "branchPreserved": true}),
            ),
            (
                EventType::WorktreeMerged,
                json!({"sourceBranch": "s", "targetBranch": "t", "mergeCommit": "m", "strategy": "merge"}),
            ),
            (
                EventType::ErrorAgent,
                json!({"error": "e", "recoverable": true}),
            ),
            (
                EventType::ErrorTool,
                json!({"toolName": "t", "toolCallId": "tc", "error": "e"}),
            ),
            (
                EventType::ErrorProvider,
                json!({"provider": "p", "error": "e", "retryable": false}),
            ),
            (
                EventType::SubagentSpawned,
                json!({"subagentSessionId": "s", "spawnType": "subsession", "task": "t", "model": "m", "workingDirectory": "/"}),
            ),
            (
                EventType::SubagentStatusUpdate,
                json!({"subagentSessionId": "s", "status": "running", "currentTurn": 1}),
            ),
            (
                EventType::SubagentCompleted,
                json!({"subagentSessionId": "s", "resultSummary": "r", "totalTurns": 1, "totalTokenUsage": {"inputTokens": 0, "outputTokens": 0}, "duration": 100}),
            ),
            (
                EventType::SubagentFailed,
                json!({"subagentSessionId": "s", "error": "e", "recoverable": false}),
            ),
            (
                EventType::SubagentResultsConsumed,
                json!({"consumedEventIds": ["evt-1"], "count": 1}),
            ),
            (
                EventType::TodoWrite,
                json!({"todos": [], "trigger": "tool"}),
            ),
            (
                EventType::TaskCreated,
                json!({"taskId": "t", "title": "t", "status": "pending", "projectId": null}),
            ),
            (
                EventType::TaskUpdated,
                json!({"taskId": "t", "title": "t", "status": "done", "changedFields": ["status"]}),
            ),
            (EventType::TaskDeleted, json!({"taskId": "t", "title": "t"})),
            (
                EventType::ProjectCreated,
                json!({"projectId": "p", "title": "t", "status": "active", "areaId": null}),
            ),
            (
                EventType::ProjectUpdated,
                json!({"projectId": "p", "title": "t", "status": "active"}),
            ),
            (
                EventType::ProjectDeleted,
                json!({"projectId": "p", "title": "t"}),
            ),
            (
                EventType::AreaCreated,
                json!({"areaId": "a", "title": "t", "status": "active"}),
            ),
            (
                EventType::AreaUpdated,
                json!({"areaId": "a", "title": "t", "status": "active", "changedFields": []}),
            ),
            (EventType::AreaDeleted, json!({"areaId": "a", "title": "t"})),
            (
                EventType::TurnFailed,
                json!({"turn": 1, "error": "e", "recoverable": false}),
            ),
            (
                EventType::HookTriggered,
                json!({"hookNames": ["h"], "hookEvent": "PreToolUse", "timestamp": "t"}),
            ),
            (
                EventType::HookCompleted,
                json!({"hookNames": ["h"], "hookEvent": "PreToolUse", "result": "continue", "timestamp": "t"}),
            ),
            (
                EventType::HookBackgroundStarted,
                json!({"hookNames": ["h"], "hookEvent": "PostToolUse", "executionId": "x", "timestamp": "t"}),
            ),
            (
                EventType::HookBackgroundCompleted,
                json!({"hookNames": ["h"], "hookEvent": "PostToolUse", "executionId": "x", "result": "continue", "duration": 50, "timestamp": "t"}),
            ),
            (
                EventType::MemoryLedger,
                json!({"eventRange": {"firstEventId": "e1", "lastEventId": "e2"}, "turnRange": {"firstTurn": 1, "lastTurn": 2}, "title": "t", "entryType": "feature", "status": "completed", "tags": [], "input": "i", "actions": [], "files": [], "decisions": [], "lessons": [], "thinkingInsights": [], "tokenCost": {"input": 0, "output": 0}, "model": "m", "workingDirectory": "/"}),
            ),
            (EventType::MemoryLoaded, json!({})),
        ];

        assert_eq!(cases.len(), 60, "must cover all 60 event types");

        for (event_type, payload) in &cases {
            let event = make_event(*event_type, payload.clone());

            // Serde roundtrip
            let json = serde_json::to_value(&event).unwrap();
            let back: SessionEvent = serde_json::from_value(json).unwrap();
            assert_eq!(event, back, "roundtrip failed for {event_type}");

            // typed_payload should succeed
            let typed = event.typed_payload();
            assert!(
                typed.is_ok(),
                "typed_payload failed for {event_type}: {:?}",
                typed.err()
            );
        }
    }
}

#[cfg(test)]
mod type_guard_tests {
    use crate::types::EventType;

    #[test]
    fn message_guards() {
        assert!(EventType::MessageUser.is_message_type());
        assert!(EventType::MessageAssistant.is_message_type());
        assert!(EventType::MessageSystem.is_message_type());
        assert!(!EventType::ToolCall.is_message_type());
    }

    #[test]
    fn specific_message_guards() {
        assert_eq!(EventType::MessageUser, EventType::MessageUser);
        assert_ne!(EventType::MessageUser, EventType::MessageAssistant);
        assert_eq!(EventType::MessageAssistant, EventType::MessageAssistant);
    }

    #[test]
    fn streaming_guards() {
        assert!(EventType::StreamTextDelta.is_streaming_type());
        assert!(EventType::StreamTurnEnd.is_streaming_type());
        assert!(!EventType::MessageUser.is_streaming_type());
    }

    #[test]
    fn error_guards() {
        assert!(EventType::ErrorAgent.is_error_type());
        assert!(EventType::ErrorTool.is_error_type());
        assert!(EventType::ErrorProvider.is_error_type());
        assert!(!EventType::ToolResult.is_error_type());
    }

    #[test]
    fn tool_guards() {
        assert_eq!(EventType::ToolCall, EventType::ToolCall);
        assert_eq!(EventType::ToolResult, EventType::ToolResult);
        assert_ne!(EventType::ToolCall, EventType::ToolResult);
    }

    #[test]
    fn compact_guards() {
        assert_eq!(EventType::CompactBoundary, EventType::CompactBoundary);
        assert_eq!(EventType::CompactSummary, EventType::CompactSummary);
    }

    #[test]
    fn context_guards() {
        assert_eq!(EventType::ContextCleared, EventType::ContextCleared);
        assert_ne!(EventType::ContextCleared, EventType::CompactBoundary);
    }

    #[test]
    fn config_guards() {
        assert!(EventType::ConfigModelSwitch.is_config_type());
        assert_eq!(
            EventType::ConfigReasoningLevel,
            EventType::ConfigReasoningLevel
        );
        assert_eq!(
            EventType::ConfigPromptUpdate,
            EventType::ConfigPromptUpdate
        );
    }

    #[test]
    fn worktree_guards() {
        assert!(EventType::WorktreeAcquired.is_worktree_type());
        assert!(EventType::WorktreeMerged.is_worktree_type());
    }

    #[test]
    fn subagent_guards() {
        assert!(EventType::SubagentSpawned.is_subagent_type());
        assert!(EventType::SubagentCompleted.is_subagent_type());
    }

    #[test]
    fn hook_guards() {
        assert!(EventType::HookTriggered.is_hook_type());
        assert!(EventType::HookBackgroundCompleted.is_hook_type());
    }

    #[test]
    fn skill_guards() {
        assert!(EventType::SkillAdded.is_skill_type());
        assert!(EventType::SkillRemoved.is_skill_type());
    }

    #[test]
    fn rules_guards() {
        assert!(EventType::RulesLoaded.is_rules_type());
        assert!(EventType::RulesIndexed.is_rules_type());
    }

    #[test]
    fn memory_guards() {
        assert!(EventType::MemoryLedger.is_memory_type());
        assert!(EventType::MemoryLoaded.is_memory_type());
    }

    #[test]
    fn session_start_guard() {
        assert_eq!(EventType::SessionStart, EventType::SessionStart);
        assert_ne!(EventType::SessionStart, EventType::SessionEnd);
    }

    #[test]
    fn message_deleted_guard() {
        assert_eq!(EventType::MessageDeleted, EventType::MessageDeleted);
        assert_ne!(EventType::MessageDeleted, EventType::MessageUser);
    }
}

#[cfg(test)]
mod state_type_tests {
    use serde_json::json;

    use crate::types::payloads::TokenUsage;
    use crate::types::state::*;

    #[test]
    fn message_serde_roundtrip() {
        let msg = Message {
            role: "user".into(),
            content: json!("Hello"),
            tool_call_id: None,
            is_error: None,
        };
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "user");
        assert!(json.get("toolCallId").is_none());
        let back: Message = serde_json::from_value(json).unwrap();
        assert_eq!(msg, back);
    }

    #[test]
    fn message_tool_result() {
        let msg = Message {
            role: "toolResult".into(),
            content: json!("ls output"),
            tool_call_id: Some("tc-1".into()),
            is_error: Some(false),
        };
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["toolCallId"], "tc-1");
        assert_eq!(json["isError"], false);
    }

    #[test]
    fn message_with_event_id_serde() {
        let mwei = MessageWithEventId {
            message: Message {
                role: "assistant".into(),
                content: json!([{"type": "text", "text": "Hi"}]),
                tool_call_id: None,
                is_error: None,
            },
            event_ids: vec![Some("evt-1".into()), None],
        };
        let json = serde_json::to_value(&mwei).unwrap();
        assert_eq!(json["eventIds"][0], "evt-1");
        assert!(json["eventIds"][1].is_null());
    }

    #[test]
    fn workspace_serde_roundtrip() {
        let ws = Workspace {
            id: "ws-1".into(),
            path: "/Users/test/project".into(),
            name: Some("project".into()),
            created: "2026-01-01T00:00:00Z".into(),
            last_activity: "2026-02-12T00:00:00Z".into(),
            session_count: 5,
        };
        let json = serde_json::to_value(&ws).unwrap();
        assert_eq!(json["sessionCount"], 5);
        let back: Workspace = serde_json::from_value(json).unwrap();
        assert_eq!(ws, back);
    }

    #[test]
    fn session_summary_serde_roundtrip() {
        let ss = SessionSummary {
            session_id: "sess-1".into(),
            workspace_id: "ws-1".into(),
            title: Some("My Session".into()),
            event_count: 42,
            message_count: 10,
            branch_count: 1,
            token_usage: TokenUsage {
                input_tokens: 5000,
                output_tokens: 2000,
                ..Default::default()
            },
            created: "2026-01-01T00:00:00Z".into(),
            last_activity: "2026-02-12T00:00:00Z".into(),
            is_ended: false,
            tags: vec!["rust".into()],
        };
        let json = serde_json::to_value(&ss).unwrap();
        assert_eq!(json["eventCount"], 42);
        assert_eq!(json["tags"][0], "rust");
        let back: SessionSummary = serde_json::from_value(json).unwrap();
        assert_eq!(ss, back);
    }

    #[test]
    fn search_result_serde() {
        let sr = SearchResult {
            event_id: "evt-1".into(),
            session_id: "sess-1".into(),
            event_type: crate::types::EventType::MessageUser,
            timestamp: "2026-01-01T00:00:00Z".into(),
            snippet: "Hello <mark>world</mark>".into(),
            score: 0.95,
        };
        let json = serde_json::to_value(&sr).unwrap();
        assert_eq!(json["type"], "message.user");
        assert_eq!(json["score"], 0.95);
    }

    #[test]
    fn branch_serde_roundtrip() {
        let b = Branch {
            id: "br-1".into(),
            name: "main".into(),
            session_id: "sess-1".into(),
            root_event_id: "evt-0".into(),
            head_event_id: "evt-10".into(),
            event_count: 10,
            created: "2026-01-01T00:00:00Z".into(),
            last_activity: "2026-02-12T00:00:00Z".into(),
            is_default: true,
        };
        let json = serde_json::to_value(&b).unwrap();
        assert_eq!(json["isDefault"], true);
        let back: Branch = serde_json::from_value(json).unwrap();
        assert_eq!(b, back);
    }
}
