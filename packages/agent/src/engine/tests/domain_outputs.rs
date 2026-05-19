use super::*;
use base64::Engine;

fn voice_write_context(key: &str) -> CausalContext {
    mutating_causal(key).with_scope("voice_notes.write")
}

fn voice_read_context() -> CausalContext {
    causal()
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_scope("voice_notes.read")
}

async fn voice_note_resources(handle: &EngineHostHandle, kind: &str) -> Vec<Value> {
    let listed = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"kind": kind, "limit": 100}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(listed.error, None);
    listed.value.unwrap()["resources"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|resource| {
            resource["resourceId"]
                .as_str()
                .is_some_and(|id| id.contains("voice-note"))
        })
        .cloned()
        .collect()
}

async fn inspect_resource(handle: &EngineHostHandle, resource_id: &str) -> Value {
    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    inspected.value.unwrap()["inspection"].clone()
}

#[tokio::test]
async fn voice_notes_save_list_and_delete_are_resource_backed() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let audio = base64::engine::general_purpose::STANDARD.encode(b"hello voice note");

    let saved = handle
        .invoke(host_invocation(
            "voice_notes::save",
            json!({"audioBase64": audio, "mimeType": "audio/wav"}),
            voice_write_context("voice-notes-resource-save"),
        ))
        .await;
    assert_eq!(saved.error, None);
    let value = saved.value.as_ref().unwrap();
    assert_eq!(value["success"], true);
    let refs = value["resourceRefs"].as_array().unwrap();
    assert!(
        refs.iter()
            .any(|reference| reference["kind"] == "materialized_file")
    );
    assert!(refs.iter().any(|reference| reference["kind"] == "artifact"));

    let filename = value["filename"].as_str().unwrap();
    std::fs::write(
        crate::shared::paths::voice_notes_dir().join("unregistered.md"),
        "this file must not become list truth",
    )
    .unwrap();

    let listed = handle
        .invoke(host_invocation(
            "voice_notes::list",
            json!({"limit": 20, "offset": 0}),
            voice_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    let list_value = listed.value.as_ref().unwrap();
    assert_eq!(list_value["totalCount"], 1);
    assert_eq!(list_value["notes"][0]["filename"], filename);
    assert_eq!(
        list_value["notes"][0]["transcript"],
        "(transcription not available)"
    );

    let deleted = handle
        .invoke(host_invocation(
            "voice_notes::delete",
            json!({"filename": filename}),
            voice_write_context("voice-notes-resource-delete"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["success"], true);
    assert!(
        deleted.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "artifact")
    );

    let listed_after_delete = handle
        .invoke(host_invocation(
            "voice_notes::list",
            json!({"limit": 20, "offset": 0}),
            voice_read_context(),
        ))
        .await;
    assert_eq!(listed_after_delete.error, None);
    assert_eq!(listed_after_delete.value.as_ref().unwrap()["totalCount"], 0);

    let artifact_ref = refs
        .iter()
        .find(|reference| reference["kind"] == "artifact")
        .unwrap();
    let artifact = inspect_resource(&handle, artifact_ref["resourceId"].as_str().unwrap()).await;
    assert_eq!(artifact["resource"]["lifecycle"], "discarded");
}

#[tokio::test]
async fn voice_notes_save_idempotency_does_not_duplicate_resources() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let audio = base64::engine::general_purpose::STANDARD.encode(b"same voice note");
    let payload = json!({"audioBase64": audio, "mimeType": "audio/wav"});

    let first = handle
        .invoke(host_invocation(
            "voice_notes::save",
            payload.clone(),
            voice_write_context("voice-notes-idempotent-save"),
        ))
        .await;
    assert_eq!(first.error, None);
    let second = handle
        .invoke(host_invocation(
            "voice_notes::save",
            payload,
            voice_write_context("voice-notes-idempotent-save"),
        ))
        .await;
    assert_eq!(second.error, None);
    assert_eq!(
        first.value.as_ref().unwrap()["resourceRefs"],
        second.value.as_ref().unwrap()["resourceRefs"]
    );
    assert_eq!(voice_note_resources(&handle, "artifact").await.len(), 1);
    assert_eq!(
        voice_note_resources(&handle, "materialized_file")
            .await
            .len(),
        1
    );
}

#[tokio::test]
async fn voice_notes_invalid_audio_fails_without_accepted_resource_refs() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let failed = handle
        .invoke(host_invocation(
            "voice_notes::save",
            json!({"audioBase64": "not valid base64"}),
            voice_write_context("voice-notes-invalid-audio"),
        ))
        .await;
    assert!(matches!(
        failed.error,
        Some(EngineError::DomainFailure { message, .. }) if message.contains("Invalid base64")
    ));
    let records = handle.lock().await.catalog().invocations().to_vec();
    let record = records
        .iter()
        .find(|record| record.invocation_id == failed.invocation_id)
        .expect("failed voice note invocation should remain inspectable");
    assert!(!record.succeeded);
    assert!(record.produced_resource_refs.is_empty());
    assert!(voice_note_resources(&handle, "artifact").await.is_empty());
    assert!(
        voice_note_resources(&handle, "materialized_file")
            .await
            .is_empty()
    );
}
