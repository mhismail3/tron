use super::*;

// -- StreamEvent --

#[test]
fn stream_event_start_serde() {
    let e = StreamEvent::Start;
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json, json!({"type": "start"}));
    let back: StreamEvent = serde_json::from_value(json).unwrap();
    assert_eq!(e, back);
}

#[test]
fn stream_event_text_delta_serde() {
    let e = StreamEvent::TextDelta {
        delta: "hello".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "text_delta");
    assert_eq!(json["delta"], "hello");
}

#[test]
fn stream_event_text_end_serde() {
    let e = StreamEvent::TextEnd {
        text: "full text".into(),
        signature: Some("sig123".into()),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "text_end");
    assert_eq!(json["text"], "full text");
    assert_eq!(json["signature"], "sig123");
}

#[test]
fn stream_event_text_end_no_signature() {
    let e = StreamEvent::TextEnd {
        text: "text".into(),
        signature: None,
    };
    let json = serde_json::to_value(&e).unwrap();
    assert!(json.get("signature").is_none());
}

#[test]
fn stream_event_thinking_delta() {
    let e = StreamEvent::ThinkingDelta {
        delta: "hmm".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "thinking_delta");
}

#[test]
fn stream_event_capability_invocation_start() {
    let e = StreamEvent::CapabilityInvocationDraftStart {
        invocation_id: "tc-1".into(),
        name: "execute".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "capability_invocation_start");
    assert_eq!(json["invocationId"], "tc-1");
    assert_eq!(json["name"], "execute");
}

#[test]
fn stream_event_capability_invocation_delta() {
    let e = StreamEvent::CapabilityInvocationDraftDelta {
        invocation_id: "tc-1".into(),
        arguments_delta: r#"{"comm"#.into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["argumentsDelta"], r#"{"comm"#);
}

#[test]
fn stream_event_done() {
    let msg = AssistantMessage {
        content: vec![crate::shared::protocol::content::AssistantContent::text(
            "response",
        )],
        token_usage: None,
    };
    let e = StreamEvent::Done {
        message: msg,
        stop_reason: "end_turn".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "done");
    assert_eq!(json["stopReason"], "end_turn");
}

#[test]
fn stream_event_error() {
    let e = StreamEvent::Error {
        error: "connection reset".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "error");
}

#[test]
fn stream_event_retry() {
    let e = StreamEvent::Retry {
        attempt: 2,
        max_retries: 5,
        delay_ms: 2000,
        error: RetryErrorInfo {
            category: "rate_limit".into(),
            message: "too many requests".into(),
            is_retryable: true,
        },
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "retry");
    assert_eq!(json["attempt"], 2);
    assert_eq!(json["maxRetries"], 5);
}

#[test]
fn stream_event_safety_block() {
    let e = StreamEvent::SafetyBlock {
        blocked_categories: vec!["HARM_CATEGORY_DANGEROUS".into()],
        error: "blocked by safety filter".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "safety_block");
}

#[test]
fn stream_event_all_variants_serialize() {
    let events: Vec<StreamEvent> = vec![
        StreamEvent::Start,
        StreamEvent::TextStart,
        StreamEvent::TextDelta { delta: "d".into() },
        StreamEvent::TextEnd {
            text: "t".into(),
            signature: None,
        },
        StreamEvent::ThinkingStart,
        StreamEvent::ThinkingDelta { delta: "d".into() },
        StreamEvent::ThinkingEnd {
            thinking: "t".into(),
            signature: None,
        },
        StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "id".into(),
            name: "n".into(),
        },
        StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "id".into(),
            arguments_delta: "d".into(),
        },
        StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::default(),
        },
        StreamEvent::Done {
            message: AssistantMessage {
                content: vec![],
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
        },
        StreamEvent::Error { error: "e".into() },
        StreamEvent::Retry {
            attempt: 1,
            max_retries: 3,
            delay_ms: 1000,
            error: RetryErrorInfo {
                category: "c".into(),
                message: "m".into(),
                is_retryable: true,
            },
        },
        StreamEvent::SafetyBlock {
            blocked_categories: vec![],
            error: "e".into(),
        },
    ];
    for event in &events {
        let json = serde_json::to_value(event).unwrap();
        assert!(json.get("type").is_some());
    }
    assert_eq!(events.len(), 14);
}
