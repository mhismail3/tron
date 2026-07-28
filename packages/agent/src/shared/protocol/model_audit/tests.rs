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
