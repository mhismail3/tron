use super::*;

// -- drain mode tests --

fn execute_stopping_capabilities() -> HashSet<String> {
    HashSet::from(["execute".to_string()])
}

fn unrelated_stopping_capabilities() -> HashSet<String> {
    HashSet::from(["other".to_string()])
}

/// Helper: build a Done event with token usage.
fn done_with_usage(content: Vec<AssistantContent>, stop_reason: &str) -> StreamEvent {
    StreamEvent::Done {
        message: AssistantMessage {
            content,
            token_usage: Some(TokenUsage {
                input_tokens: 100,
                output_tokens: 42,
                ..Default::default()
            }),
        },
        stop_reason: stop_reason.into(),
    }
}

#[tokio::test]
async fn drain_after_turn_stopping_execute_drops_trailing_text() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "hello".into() });
        yield Ok(StreamEvent::TextEnd { text: "hello".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"operation":"observe","input":"q1"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("q1"));
                m
            }),
        });
        // Trailing text — should be drained
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " trailing garbage".into() });
        yield Ok(StreamEvent::TextEnd { text: " trailing garbage".into(), signature: None });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &execute_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");

    // Token usage captured from Done event
    let usage = result.token_usage.expect("should have token usage");
    assert_eq!(usage.input_tokens, 100);
    assert_eq!(usage.output_tokens, 42);

    // Message should have text + capability invocation, no trailing text
    let text_blocks: Vec<_> = result
        .message
        .content
        .iter()
        .filter(|c| matches!(c, AssistantContent::Text { .. }))
        .collect();
    assert_eq!(text_blocks.len(), 1);
    if let AssistantContent::Text { text, .. } = &text_blocks[0] {
        assert_eq!(text, "hello");
    }
    let capability_blocks: Vec<_> = result
        .message
        .content
        .iter()
        .filter(|c| matches!(c, AssistantContent::CapabilityInvocation { .. }))
        .collect();
    assert_eq!(capability_blocks.len(), 1);
}

#[tokio::test]
async fn drain_after_execute_primitive_operation() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "before".into() });
        yield Ok(StreamEvent::TextEnd { text: "before".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-execute-ask".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-execute-ask".into(),
            arguments_delta: r#"{"operation":"observe","input":"Proceed?"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-execute-ask", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("Proceed?"));
                m
            }),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " should not appear".into() });
        yield Ok(StreamEvent::TextEnd { text: " should not appear".into(), signature: None });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &execute_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
    let text = result
        .message
        .content
        .iter()
        .find_map(|content| match content {
            AssistantContent::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .expect("pre-invocation text");
    assert_eq!(text, "before");
}

#[tokio::test]
async fn drain_preserves_thinking_and_text_before_stopping_execute() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ThinkingStart);
        yield Ok(StreamEvent::ThinkingDelta { delta: "deep thought".into() });
        yield Ok(StreamEvent::ThinkingEnd { thinking: "deep thought".into(), signature: Some("sig-1".into()) });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "answer".into() });
        yield Ok(StreamEvent::TextEnd { text: "answer".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask-confirm".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask-confirm".into(),
            arguments_delta: r#"{"operation":"observe","input":"Proceed?"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask-confirm", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("Proceed?"));
                m
            }),
        });
        // Trailing text — drained
        yield Ok(StreamEvent::TextDelta { delta: "extra".into() });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &execute_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    // Thinking preserved
    let thinking = result
        .message
        .content
        .iter()
        .find(|c| matches!(c, AssistantContent::Thinking { .. }));
    assert!(thinking.is_some());
    if let AssistantContent::Thinking {
        thinking: t,
        signature,
    } = thinking.unwrap()
    {
        assert_eq!(t, "deep thought");
        assert_eq!(signature.as_deref(), Some("sig-1"));
    }
    // Text preserved
    let text = result
        .message
        .content
        .iter()
        .find(|c| matches!(c, AssistantContent::Text { .. }));
    assert!(text.is_some());
    if let AssistantContent::Text { text: t, .. } = text.unwrap() {
        assert_eq!(t, "answer");
    }
    // Capability invocation preserved
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
}

#[tokio::test]
async fn drain_after_first_stopping_execute_drops_following_invocations() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-observe".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-observe".into(),
            arguments_delta: r#"{"operation":"observe","input":"first"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-observe", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("first"));
                m
            }),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"operation":"observe","input":"second"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("second"));
                m
            }),
        });
        // Capability invocation after the stopping call should be drained.
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-write".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-write".into(),
            arguments_delta: r#"{"operation":"file_write","path":"x","content":"y"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-write", "execute", serde_json::Map::new()),
        });
        yield Ok(done_with_usage(vec![], "capability_invocation"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &execute_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
    // The later execute call should NOT be in capability_invocations.
    assert!(
        !result
            .capability_invocations
            .iter()
            .any(|tc| tc.id == "tc-write")
    );
}

#[tokio::test]
async fn no_drain_for_non_stopping_capabilities() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "hello".into() });
        yield Ok(StreamEvent::TextEnd { text: "hello".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-1".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-1".into(),
            arguments_delta: r#"{"operation":"process_run","command":"ls"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-1", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("process_run"));
                let _ = m.insert("command".into(), serde_json::json!("ls"));
                m
            }),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " world".into() });
        yield Ok(StreamEvent::TextEnd { text: " world".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::text("hello world"),
                    AssistantContent::CapabilityInvocation {
                        id: "tc-1".into(),
                        name: "execute".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                ],
                token_usage: Some(TokenUsage { input_tokens: 50, output_tokens: 20, ..Default::default() }),
            },
            stop_reason: "capability_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    // execute is not in the stopping set, so no drain happens.
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &unrelated_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
    // Message should come from final_message (has combined text)
    let usage = result.token_usage.unwrap();
    assert_eq!(usage.input_tokens, 50);
}

#[tokio::test]
async fn cancel_during_drain_returns_interrupted() {
    let cancel = CancellationToken::new();
    let cancel_clone = cancel.clone();

    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"operation":"observe","input":"q"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("q"));
                m
            }),
        });
        // Now draining — cancel before Done arrives
        cancel_clone.cancel();
        yield Ok(StreamEvent::TextDelta { delta: "never seen".into() });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &execute_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(result.interrupted);
    assert_eq!(result.stop_reason, "interrupted");
    // Capability invocation should still be in the result (was finalized before drain)
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
}

#[tokio::test]
async fn drain_empty_stopping_set_no_change() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "hello".into() });
        yield Ok(StreamEvent::TextEnd { text: "hello".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"operation":"observe","input":"q"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("operation".into(), serde_json::json!("observe"));
                let _ = m.insert("input".into(), serde_json::json!("q"));
                m
            }),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " trailing".into() });
        yield Ok(StreamEvent::TextEnd { text: " trailing".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::text("hello trailing")],
                token_usage: Some(TokenUsage { input_tokens: 10, output_tokens: 5, ..Default::default() }),
            },
            stop_reason: "capability_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    // Empty set — no drain should happen
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    // Trailing text should be present (from final_message)
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    // Message comes from final_message which has combined text
    let has_text = result
        .message
        .content
        .iter()
        .any(|c| matches!(c, AssistantContent::Text { text, .. } if text.contains("trailing")));
    assert!(has_text, "trailing text should be preserved when no drain");
}
