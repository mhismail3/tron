//! Tests for `SessionEvent`, `typed_payload`, type guards, and state types.

#[cfg(test)]
mod session_event_tests {
    use serde_json::json;

    use crate::domains::session::event_store::types::base::SessionEvent;
    use crate::domains::session::event_store::types::payloads::message::AssistantMessagePayload;
    use crate::domains::session::event_store::types::{EventType, SessionEventPayload};
    use crate::shared::protocol::model_audit::ModelProviderReasoningStatusPhase;

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
                assert_eq!(p.turn, Some(1));
            }
            other => panic!("expected MessageUser, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_message_user_without_turn() {
        let event = make_event(EventType::MessageUser, json!({ "content": "Hello" }));
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MessageUser(p) => {
                assert_eq!(p.content, json!("Hello"));
                assert_eq!(p.turn, None);
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
                assert_eq!(p.token_usage.unwrap().input_tokens, 100);
                assert_eq!(p.model, "claude-opus-4-6");
                assert!(p.reasoning_status_evidence.is_none());
            }
            other => panic!("expected MessageAssistant, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_message_assistant_round_trips_reasoning_status_evidence() {
        let event = make_event(
            EventType::MessageAssistant,
            json!({
                "content": [{"type": "text", "text": "Hi there"}],
                "turn": 2,
                "tokenUsage": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "reasoningOutputTokens": 7,
                    "thoughtTokens": 3,
                    "totalTokens": 150
                },
                "stopReason": "end_turn",
                "model": "gpt-5.5",
                "hasThinking": true,
                "reasoningStatusEvidence": {
                    "format": "tron.model_provider_reasoning_status_evidence.v1",
                    "phase": "message_assistant",
                    "providerType": "openai",
                    "providerName": "openai",
                    "model": "gpt-5.5",
                    "requestedReasoningLevel": "high",
                    "status": {
                        "statusEmitted": true,
                        "stopReason": "end_turn",
                        "thinkingEmitted": true
                    },
                    "tokens": {
                        "tokenUsageAvailable": true,
                        "reasoningOutputTokens": 7,
                        "thoughtTokens": 3,
                        "totalTokens": 150
                    },
                    "refs": {
                        "providerAuditEventType": "model.provider_request",
                        "providerAuditFormat": "tron.model_provider_request.v1",
                        "traceId": "trace-17a",
                        "parentInvocationId": "invoke-17a",
                        "replaySource": "session_event_log"
                    },
                    "safety": {
                        "projection": "metadata_only",
                        "rawReasoningText": "omitted",
                        "syntheticReasoningSummary": "omitted",
                        "providerReasoningPayload": "redacted_or_omitted",
                        "sensitiveMaterial": "redacted",
                        "pathMaterial": "redacted"
                    }
                }
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MessageAssistant(p) => {
                let json = serde_json::to_value(&p).unwrap();
                assert_eq!(
                    json["reasoningStatusEvidence"]["phase"],
                    "message_assistant"
                );
                let round_trip: AssistantMessagePayload = serde_json::from_value(json).unwrap();
                let evidence = round_trip
                    .reasoning_status_evidence
                    .expect("assistant payload should preserve reasoning evidence");
                assert_eq!(
                    evidence.phase,
                    ModelProviderReasoningStatusPhase::MessageAssistant
                );
                assert_eq!(evidence.provider_type.as_str(), "openai");
                assert_eq!(evidence.requested_reasoning_level.as_deref(), Some("high"));
                assert_eq!(evidence.status.thinking_emitted, Some(true));
                assert_eq!(evidence.tokens.reasoning_output_tokens, Some(7));
                assert_eq!(evidence.tokens.thought_tokens, Some(3));
                assert_eq!(evidence.refs.trace_id.as_deref(), Some("trace-17a"));
                assert_eq!(evidence.safety.raw_reasoning_text, "omitted");
                assert_eq!(evidence.safety.synthetic_reasoning_summary, "omitted");
            }
            other => panic!("expected MessageAssistant, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_message_assistant_without_provider_usage() {
        let event = make_event(
            EventType::MessageAssistant,
            json!({
                "content": [{"type": "text", "text": "Interrupted"}],
                "turn": 1,
                "stopReason": "interrupted",
                "model": "claude-opus-4-6",
                "tokenUsageAvailable": false
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::MessageAssistant(p) => {
                assert_eq!(p.stop_reason, "interrupted");
                assert_eq!(p.token_usage, None);
                assert_eq!(p.token_record, None);
                assert!(p.reasoning_status_evidence.is_none());
            }
            other => panic!("expected MessageAssistant, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_model_provider_request() {
        let event = make_event(
            EventType::ModelProviderRequest,
            json!({
                "format": "tron.model_provider_request.v1",
                "providerType": "openai",
                "providerName": "openai",
                "model": "gpt-5.5-codex",
                "contextWindow": 272000,
                "sessionId": "sess-1",
                "reasoningLevel": "x_high",
                "messageCount": 1,
                "capabilityCount": 0,
                "streamOptions": {
                    "promptCacheKey": "tron-session-sess-1",
                    "reasoningEffort": "xhigh"
                },
                "providerRequest": {
                    "kind": "exact_provider_envelope",
                    "body": {
                        "model": "gpt-5.5-codex"
                    }
                }
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ModelProviderRequest(p) => {
                assert_eq!(p.format, "tron.model_provider_request.v1");
                assert_eq!(
                    p.provider_type,
                    crate::shared::protocol::messages::Provider::OpenAi
                );
                assert_eq!(p.reasoning_level.as_deref(), Some("x_high"));
                assert_eq!(p.message_count, 1);
                assert_eq!(p.stream_options["reasoningEffort"], json!("xhigh"));
                assert_eq!(
                    p.provider_request.kind,
                    crate::shared::protocol::model_audit::ProviderAuditPayloadKind::ExactProviderEnvelope
                );
            }
            other => panic!("expected ModelProviderRequest, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_capability_invocation_started() {
        let event = make_event(
            EventType::CapabilityInvocationStarted,
            json!({
                "invocationId": "tc-1",
                "name": "execute",
                "arguments": {"command": "ls"},
                "turn": 1
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::CapabilityInvocationStarted(p) => {
                assert_eq!(p.invocation_id, "tc-1");
                assert_eq!(p.name, "execute");
            }
            other => panic!("expected CapabilityInvocationStarted, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_capability_invocation_completed() {
        let event = make_event(
            EventType::CapabilityInvocationCompleted,
            json!({
                "invocationId": "tc-1",
                "content": "file.txt",
                "isError": false,
                "duration": 250
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::CapabilityInvocationCompleted(p) => {
                assert_eq!(p.invocation_id, "tc-1");
                assert!(!p.is_error);
                assert_eq!(p.duration, 250);
            }
            other => panic!("expected CapabilityInvocationCompleted, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_compact_summary_staging() {
        let event = make_event(
            EventType::CompactSummaryStaging,
            json!({
                "originalTokens": 50000,
                "compactedTokens": 5000,
                "reason": "threshold_exceeded",
                "summary": "The user asked about Rust...",
                "timestamp": "2026-05-31T00:00:00Z"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::CompactSummaryStaging(p) => {
                assert_eq!(p.original_tokens, 50000);
                assert_eq!(p.compacted_tokens, 5000);
                assert_eq!(p.reason, "threshold_exceeded");
                assert!(p.summary.contains("Rust"));
            }
            other => panic!("expected CompactSummaryStaging, got {other:?}"),
        }
    }

    #[test]
    fn typed_payload_compact_boundary() {
        let event = make_event(
            EventType::CompactBoundary,
            json!({
                "range": {"from": "evt-1", "to": "evt-10"},
                "originalTokens": 50000,
                "compactedTokens": 5000,
                "reason": "threshold_exceeded"
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::CompactBoundary(p) => {
                let range = p.range.unwrap();
                assert_eq!(range.from, "evt-1");
                assert_eq!(range.to, "evt-10");
                assert_eq!(p.original_tokens, 50000);
                assert_eq!(p.reason, "threshold_exceeded");
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
    fn typed_payload_error_provider() {
        let event = make_event(
            EventType::ErrorProvider,
            json!({
                "provider": "anthropic",
                "error": "rate limited",
                "category": "rate_limit",
                "retryable": true
            }),
        );
        let payload = event.typed_payload().unwrap();
        match payload {
            SessionEventPayload::ErrorProvider(p) => {
                assert_eq!(p.provider, "anthropic");
                assert_eq!(p.category, "rate_limit");
                assert!(p.retryable);
            }
            other => panic!("expected ErrorProvider, got {other:?}"),
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
            (EventType::MessageUser, json!({"content": "hi"})),
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
                EventType::CapabilityInvocationStarted,
                json!({"invocationId": "tc", "name": "execute", "arguments": {}, "turn": 1}),
            ),
            (
                EventType::CapabilityInvocationCompleted,
                json!({"invocationId": "tc", "content": "ok", "isError": false, "duration": 100}),
            ),
            (
                EventType::CapabilityInvocationProgress,
                json!({"invocationId": "tc", "message": "running", "turn": 1}),
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
                EventType::CompactBoundary,
                json!({"range": {"from": "a", "to": "b"}, "originalTokens": 100, "compactedTokens": 10, "reason": "manual"}),
            ),
            (
                EventType::CompactSummaryStaging,
                json!({"originalTokens": 100, "compactedTokens": 10, "reason": "manual", "summary": "s", "timestamp": "t"}),
            ),
            (
                EventType::ContextCleared,
                json!({"tokensBefore": 100, "tokensAfter": 0, "reason": "manual"}),
            ),
            (
                EventType::MetadataUpdate,
                json!({"key": "k", "newValue": "v"}),
            ),
            (EventType::MetadataTag, json!({"action": "add", "tag": "t"})),
            (
                EventType::ErrorAgent,
                json!({"error": "e", "recoverable": true}),
            ),
            (
                EventType::ErrorCapability,
                json!({"modelPrimitiveName": "execute", "invocationId": "tc", "error": "e"}),
            ),
            (
                EventType::ErrorProvider,
                json!({"provider": "p", "error": "e", "category": "unknown", "retryable": false}),
            ),
            (
                EventType::TurnFailed,
                json!({"turn": 1, "error": "e", "recoverable": false}),
            ),
        ];

        assert_eq!(cases.len(), 23, "must cover all 23 event types");

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
    use crate::domains::session::event_store::types::EventType;

    #[test]
    fn message_guards() {
        assert!(EventType::MessageUser.is_message_type());
        assert!(EventType::MessageAssistant.is_message_type());
        assert!(EventType::MessageSystem.is_message_type());
        assert!(!EventType::CapabilityInvocationStarted.is_message_type());
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
        assert!(EventType::ErrorCapability.is_error_type());
        assert!(EventType::ErrorProvider.is_error_type());
        assert!(!EventType::CapabilityInvocationCompleted.is_error_type());
    }

    #[test]
    fn capability_invocation_guards() {
        assert_eq!(
            EventType::CapabilityInvocationStarted,
            EventType::CapabilityInvocationStarted
        );
        assert_eq!(
            EventType::CapabilityInvocationCompleted,
            EventType::CapabilityInvocationCompleted
        );
        assert_ne!(
            EventType::CapabilityInvocationStarted,
            EventType::CapabilityInvocationCompleted
        );
    }

    #[test]
    fn compact_guards() {
        assert_eq!(EventType::CompactBoundary, EventType::CompactBoundary);
        assert_eq!(
            EventType::CompactSummaryStaging,
            EventType::CompactSummaryStaging
        );
    }

    #[test]
    fn context_guards() {
        assert_eq!(EventType::ContextCleared, EventType::ContextCleared);
        assert_ne!(EventType::ContextCleared, EventType::CompactBoundary);
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

    use crate::domains::session::event_store::types::payloads::TokenUsage;
    use crate::domains::session::event_store::types::state::*;

    #[test]
    fn message_serde_roundtrip() {
        let msg = Message {
            role: "user".into(),
            content: json!("Hello"),
            invocation_id: None,
            is_error: None,
        };
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "user");
        assert!(json.get("invocationId").is_none());
        let back: Message = serde_json::from_value(json).unwrap();
        assert_eq!(msg, back);
    }

    #[test]
    fn message_capability_result() {
        let msg = Message {
            role: "capabilityResult".into(),
            content: json!("ls output"),
            invocation_id: Some("tc-1".into()),
            is_error: Some(false),
        };
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["invocationId"], "tc-1");
        assert_eq!(json["isError"], false);
    }

    #[test]
    fn message_with_event_id_serde() {
        let mwei = MessageWithEventId {
            message: Message {
                role: "assistant".into(),
                content: json!([{"type": "text", "text": "Hi"}]),
                invocation_id: None,
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
