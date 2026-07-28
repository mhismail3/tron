//! Provider-audit manifest, projection, redaction, and digest tests.

use super::*;
use serde_json::json;

#[test]
fn provider_audit_payload_redacts_nested_secrets() {
    let payload = ProviderAuditPayload::exact_provider_envelope(json!({
        "headers": {
            "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
        },
        "body": [
            {"apiKey": "sk-proj-abcdefghijklmnopqrstuvwxyz"},
            "access_token=access-token-1234567890"
        ]
    }));

    let redacted = payload.redacted_and_bounded().unwrap();
    let body = redacted.body.to_string();

    assert!(!body.contains("abcdefghijklmnopqrstuvwxyz0123456789"));
    assert!(!body.contains("sk-proj-abcdefghijklmnopqrstuvwxyz"));
    assert!(!body.contains("access-token-1234567890"));
    assert!(body.contains("Bearer ****"));
    assert!(body.contains("sk-proj-****"));
    assert!(body.contains("access_token=****"));
}

#[test]
fn provider_audit_payload_omits_raw_reasoning_and_redacts_paths() {
    let payload = ProviderAuditPayload::provider_independent_snapshot(json!({
        "messages": [{
            "type": "thinking",
            "thinking": "raw hidden reasoning from provider",
            "debugPath": "/tmp/tron-provider/raw-reasoning.log"
        }],
        "providerDebug": {
            "reasoning_content": {
                "text": "provider native chain of thought"
            },
            "chainOfThought": ["first hidden step", "second hidden step"],
            "unsafe": "../escape/provider.json"
        },
        "headers": {
            "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
        }
    }));

    let redacted = payload.redacted_and_bounded().unwrap();
    let body = redacted.body.to_string();

    for forbidden in [
        "raw hidden reasoning",
        "provider native chain",
        "first hidden step",
        "/tmp/tron-provider",
        "../escape",
        "abcdefghijklmnopqrstuvwxyz0123456789",
    ] {
        assert!(
            !body.contains(forbidden),
            "provider audit leaked {forbidden}: {body}"
        );
    }
    assert!(body.contains("[omitted:provider-reasoning-payload]"));
    assert!(body.contains("[redacted-path]"));
    assert!(body.contains("Bearer ****"));
}

#[test]
fn provider_audit_payload_projects_bulk_inline_media() {
    let image_data = "a".repeat(MAX_PROVIDER_AUDIT_PAYLOAD_BYTES + 1);
    let payload = ProviderAuditPayload::exact_provider_envelope(json!({
        "input": [{
            "role": "user",
            "content": [{
                "type": "input_image",
                "image_url": format!("data:image/jpeg;base64,{image_data}")
            }]
        }]
    }));

    let bounded = payload.redacted_and_bounded().unwrap();
    let projection = &bounded.body["input"][0]["content"][0]["image_url"];

    assert_eq!(
        bounded.kind,
        ProviderAuditPayloadKind::ProviderEnvelopeProjection
    );
    assert_eq!(projection["$tronAuditProjection"], "bulk_string.v1");
    assert_eq!(projection["encoding"], "base64");
    assert_eq!(projection["mimeType"], "image/jpeg");
    assert_eq!(
        projection["payloadBytes"],
        serde_json::json!(image_data.len())
    );
    assert!(
        projection["sha256"]
            .as_str()
            .is_some_and(|value| value.starts_with("sha256:"))
    );
    assert!(serde_json::to_vec(&bounded).unwrap().len() < MAX_PROVIDER_AUDIT_PAYLOAD_BYTES);
    assert!(!bounded.body.to_string().contains(&image_data));
}

#[test]
fn provider_audit_payload_keeps_fitting_long_text_exact() {
    let payload = ProviderAuditPayload::exact_provider_envelope(json!({
        "input": "x".repeat(MAX_PROVIDER_AUDIT_INLINE_STRING_BYTES + 1)
    }));

    let bounded = payload.redacted_and_bounded().unwrap();

    assert_eq!(
        bounded.kind,
        ProviderAuditPayloadKind::ExactProviderEnvelope
    );
    assert_eq!(
        bounded.body["input"].as_str().map(str::len),
        Some(MAX_PROVIDER_AUDIT_INLINE_STRING_BYTES + 1)
    );
}

#[test]
fn provider_audit_payload_summarizes_oversized_structure_after_bulk_projection() {
    let values = (0..70_000)
        .map(|index| format!("small-audit-value-{index:05}"))
        .collect::<Vec<_>>();
    let payload = ProviderAuditPayload::provider_independent_snapshot(json!({
        "values": values
    }));

    let bounded = payload.redacted_and_bounded().unwrap();

    assert_eq!(
        bounded.kind,
        ProviderAuditPayloadKind::ProviderIndependentProjection
    );
    assert_eq!(bounded.body["$tronAuditProjection"], "request_envelope.v1");
    assert!(bounded.body["encodedBytes"].as_u64().is_some_and(|size| {
        usize::try_from(size).is_ok_and(|size| size > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES)
    }));
    assert!(serde_json::to_vec(&bounded).unwrap().len() < MAX_PROVIDER_AUDIT_PAYLOAD_BYTES);
}

#[test]
fn context_manifest_matches_context_and_retains_message_provenance() {
    let context = Context {
        system_prompt: Some("base\n\nremember this".to_owned()),
        messages: vec![Message::user("hello")].into(),
        tools: Some(Vec::new()),
        request_context: Vec::new(),
        cache_layout: Default::default(),
        working_directory: Some("/workspace/project".to_owned()),
        server_origin: Some("localhost:9847".to_owned()),
    };
    let contributions = vec![
        SystemContextContribution::new(
            "base_instructions",
            "Agent instructions",
            "base",
            json!({"owner":"runtime"}),
        ),
        SystemContextContribution::new(
            "continuity_context",
            "Continuity context",
            "remember this",
            json!({"workerId":"continuity-curator"}),
        ),
    ];
    let source = MessageAuditSource::events(vec!["event-user-1".to_owned()]);

    let manifest = ContextManifest::build(
        &context,
        contributions,
        json!({"fixedToolCount":0}),
        Vec::new(),
        &[source],
    )
    .expect("matching manifest");

    assert_eq!(manifest.messages[0].source_event_ids, ["event-user-1"]);
    assert_eq!(manifest.messages[0].source_kind, "durable_event");
    assert!(manifest.context_sha256.starts_with("sha256:"));
    assert_eq!(manifest.system_contributions.len(), 2);
}

#[test]
fn request_context_changes_only_request_specific_cache_evidence() {
    let build = |content: &str| {
        let context = Context {
            system_prompt: Some("stable instructions".to_owned()),
            messages: vec![Message::user("durable history")].into(),
            request_context: vec![crate::shared::protocol::messages::RequestContextBlock {
                kind: crate::shared::protocol::messages::RequestContextKind::Continuity,
                content: content.to_owned(),
            }],
            ..Context::default()
        };
        ContextManifest::build(
            &context,
            vec![SystemContextContribution::new(
                "base_instructions",
                "Agent instructions",
                "stable instructions",
                Value::Null,
            )],
            Value::Null,
            vec![AutomaticContextEvaluation {
                kind: "continuity".to_owned(),
                outcome: "injected".to_owned(),
                mechanism: "continuity_hook".to_owned(),
                delivery_channel: Some("reference".to_owned()),
                narrative: Some(content.to_owned()),
                worker_id: Some("continuity-curator".to_owned()),
                worker_version: Some("v1".to_owned()),
                invocation_id: Some("invocation".to_owned()),
                sources: Vec::new(),
                detail: None,
            }],
            &[MessageAuditSource::events(vec!["event-user".to_owned()])],
        )
        .unwrap()
    };

    let first = build("first memory");
    let second = build("second memory");
    let first_cache = first.cache_layout.as_ref().unwrap();
    let second_cache = second.cache_layout.as_ref().unwrap();

    assert_eq!(
        first_cache.stable_instruction_sha256,
        second_cache.stable_instruction_sha256
    );
    assert_eq!(
        first_cache.fixed_tool_prefix_sha256,
        second_cache.fixed_tool_prefix_sha256
    );
    assert_ne!(
        first_cache.request_context_sha256,
        second_cache.request_context_sha256
    );
    assert_eq!(first.messages.len(), 2);
    assert_eq!(first.messages[1].source_kind, "generated");
    assert!(
        first.messages[1]
            .preview
            .as_deref()
            .is_some_and(|preview| preview.contains("TRON REFERENCE CONTEXT"))
    );
}

#[test]
fn empty_request_context_adds_zero_provider_input_bytes() {
    let context = Context {
        system_prompt: Some("stable instructions".to_owned()),
        messages: vec![Message::user("durable history")].into(),
        ..Context::default()
    };
    let manifest = ContextManifest::build(
        &context,
        vec![SystemContextContribution::new(
            "base_instructions",
            "Agent instructions",
            "stable instructions",
            Value::Null,
        )],
        Value::Null,
        Vec::new(),
        &[MessageAuditSource::events(vec!["event-user".to_owned()])],
    )
    .unwrap();

    assert_eq!(manifest.messages.len(), 1);
    assert_eq!(
        manifest
            .cache_layout
            .as_ref()
            .unwrap()
            .request_context_bytes,
        0
    );
    assert!(
        manifest
            .cache_layout
            .as_ref()
            .unwrap()
            .request_context_sha256
            .is_none()
    );
}

#[test]
fn dynamic_worker_changes_do_not_invalidate_fixed_tool_prefix() {
    let tool = |name: &str, description: &str| crate::shared::protocol::model_tools::ModelTool {
        name: name.to_owned(),
        description: description.to_owned(),
        parameters: crate::shared::protocol::model_tools::ToolParameterSchema {
            schema_type: "object".to_owned(),
            properties: None,
            required: None,
            description: None,
            extra: serde_json::Map::new(),
        },
    };
    let build = |dynamic_description: &str| {
        let context = Context {
            system_prompt: Some("stable".to_owned()),
            tools: Some(vec![
                tool("fixed_read", "Stable primitive"),
                tool("worker_memory", dynamic_description),
            ]),
            cache_layout: crate::shared::protocol::messages::ContextCacheLayout {
                fixed_tool_prefix_len: 1,
            },
            ..Context::default()
        };
        ContextManifest::build(
            &context,
            vec![SystemContextContribution::new(
                "base_instructions",
                "Agent instructions",
                "stable",
                Value::Null,
            )],
            Value::Null,
            Vec::new(),
            &[],
        )
        .unwrap()
    };

    let first = build("First selected worker schema");
    let second = build("Updated selected worker schema");
    let first = first.cache_layout.unwrap();
    let second = second.cache_layout.unwrap();
    assert_eq!(
        first.fixed_tool_prefix_sha256,
        second.fixed_tool_prefix_sha256
    );
    assert_ne!(first.dynamic_tools_sha256, second.dynamic_tools_sha256);
}

#[test]
fn context_manifest_rejects_unrecorded_system_mutation() {
    let context = Context {
        system_prompt: Some("base\n\nunrecorded".to_owned()),
        ..Context::default()
    };

    let error = ContextManifest::build(
        &context,
        vec![SystemContextContribution::new(
            "base_instructions",
            "Agent instructions",
            "base",
            Value::Null,
        )],
        Value::Null,
        Vec::new(),
        &[],
    )
    .expect_err("unrecorded system text must fail closed");

    assert!(error.contains("does not match"));
}
