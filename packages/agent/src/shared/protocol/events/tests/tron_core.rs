use super::*;

// -- TronEvent --

#[test]
fn tron_event_agent_start() {
    let e = agent_start_event("sess-1");
    assert_eq!(e.session_id(), "sess-1");
    assert_eq!(e.event_type(), "agent_start");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "agent_start");
    assert_eq!(json["sessionId"], "sess-1");
}

#[test]
fn tron_event_agent_end() {
    let e = agent_end_event("sess-1");
    assert_eq!(e.event_type(), "agent_end");
}

#[test]
fn tron_event_agent_ready() {
    let e = agent_ready_event("sess-1");
    assert_eq!(e.event_type(), "agent_ready");
}

#[test]
fn tron_event_turn_start() {
    let e = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 3,
    };
    assert_eq!(e.event_type(), "turn_start");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["turn"], 3);
}

#[test]
fn tron_event_turn_end_with_token_usage() {
    let e = TronEvent::TurnEnd {
        base: BaseEvent::now("s1"),
        turn: 1,
        duration: 5000,
        token_usage: Some(TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(20),
            cache_creation_tokens: None,
            ..TokenUsage::default()
        }),
        token_record: None,
        cost: Some(0.005),
        stop_reason: Some("end_turn".into()),
        context_limit: Some(200_000),
        model: None,
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["tokenUsage"]["inputTokens"], 100);
    assert_eq!(json["tokenUsage"]["cacheReadTokens"], 20);
    assert!(json["tokenUsage"].get("cacheCreationTokens").is_none());
    assert_eq!(json["cost"], 0.005);
    assert_eq!(json["contextLimit"], 200_000);
}

#[test]
fn tron_event_turn_failed() {
    let e = TronEvent::TurnFailed {
        base: BaseEvent::now("s1"),
        turn: 2,
        error: "rate limit".into(),
        code: Some("PRATE".into()),
        category: Some("rate_limit".into()),
        recoverable: true,
        partial_content: None,
    };
    assert_eq!(e.event_type(), "agent.turn_failed");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "agent.turn_failed");
    assert!(json["recoverable"].as_bool().unwrap());
}

#[test]
fn tron_event_capability_invocation_started() {
    let e = TronEvent::CapabilityInvocationStarted {
        base: BaseEvent::now("s1"),
        invocation_id: "tc-1".into(),
        model_primitive_name: "execute".into(),
        arguments: None,
        capability_identity: CapabilityEventIdentity {
            model_primitive_name: Some("execute".into()),
            contract_id: Some("capability::execute".into()),
            implementation_id: Some("primitive.execute".into()),
            function_id: Some("capability::execute".into()),
            plugin_id: None,
            worker_id: Some("capability".into()),
            schema_digest: Some("sha256:test".into()),
            catalog_revision: Some(7),
            trust_tier: Some("host_primitive".into()),
            risk_level: Some("high".into()),
            effect_class: Some("external_side_effect".into()),
            trace_id: Some("trace-test".into()),
            root_invocation_id: Some("root-test".into()),
            binding_decision_id: None,
            theme_color: Some("#10B981".into()),
            presentation_hints: Some(serde_json::json!({
                "displayName": "Execute",
                "chipTitle": "Execute",
                "icon": "terminal",
                "themeColor": "#10B981"
            })),
        },
    };
    assert!(e.is_capability_invocation());
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["modelPrimitiveName"], "execute");
    assert_eq!(json["contractId"], "capability::execute");
    assert_eq!(json["implementationId"], "primitive.execute");
    assert_eq!(json["schemaDigest"], "sha256:test");
    assert_eq!(json["catalogRevision"], 7);
    assert_eq!(json["themeColor"], "#10B981");
    assert_eq!(json["presentationHints"]["displayName"], "Execute");
    assert_eq!(json["presentationHints"]["icon"], "terminal");
}

#[test]
fn tron_event_binding_resolution_is_capability_invocation_event() {
    let e = TronEvent::CapabilityResolution {
        base: BaseEvent::now("s1"),
        invocation_id: "tc-1".into(),
        model_primitive_name: "execute".into(),
        requested_contract_id: Some("capability::execute".into()),
        requested_implementation_id: None,
        requested_function_id: None,
        capability_identity: CapabilityEventIdentity::with_model_primitive("execute"),
    };
    assert!(e.is_capability_invocation());
    assert_eq!(e.event_type(), "capability.resolution");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "capability.resolution");
    assert_eq!(json["invocationId"], "tc-1");
    assert_eq!(json["requestedContractId"], "capability::execute");
}

#[test]
fn tron_event_compaction_complete() {
    let e = TronEvent::CompactionComplete {
        base: BaseEvent::now("s1"),
        success: true,
        tokens_before: 100_000,
        tokens_after: 30_000,
        compression_ratio: 0.3,
        reason: Some(CompactionReason::ThresholdExceeded),
        summary: Some("Summarized 50 messages".into()),
        estimated_context_tokens: Some(45_000),
        preserved_turns: Some(3),
        summarized_turns: Some(5),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["tokensBefore"], 100_000);
    assert_eq!(json["tokensAfter"], 30_000);
    assert_eq!(json["compressionRatio"], 0.3);
    assert_eq!(json["reason"], "threshold_exceeded");
}

#[test]
fn tron_event_api_retry() {
    let e = TronEvent::ApiRetry {
        base: BaseEvent::now("s1"),
        attempt: 2,
        max_retries: 5,
        delay_ms: 4000,
        error_category: "rate_limit".into(),
        error_message: "429 Too Many Requests".into(),
    };
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["type"], "api_retry");
    assert_eq!(json["attempt"], 2);
}

#[test]
fn is_stream_event_type_positive() {
    assert!(is_stream_event_type("start"));
    assert!(is_stream_event_type("text_delta"));
    assert!(is_stream_event_type("done"));
    assert!(is_stream_event_type("safety_block"));
}

#[test]
fn is_stream_event_type_negative() {
    assert!(!is_stream_event_type("agent_start"));
    assert!(!is_stream_event_type("turn_end"));
    assert!(!is_stream_event_type("unknown"));
}

#[test]
fn base_event_now_has_timestamp() {
    let base = BaseEvent::now("s1");
    assert_eq!(base.session_id, "s1");
    assert!(!base.timestamp.is_empty());
}
