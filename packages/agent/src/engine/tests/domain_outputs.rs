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

fn model_execute_context(key: &str) -> CausalContext {
    mutating_causal(key)
        .with_scope("capability.execute")
        .with_scope("primitive.allow:*")
        .with_scope("contract.allow:*")
        .with_scope("implementation.allow:*")
        .with_scope("plugin.allow:*")
}

fn filesystem_write_context(session_id: &str, key: &str, working_directory: &str) -> CausalContext {
    causal()
        .with_session_id(session_id)
        .with_workspace_id("workspace-a")
        .with_idempotency_key(key)
        .with_scope("filesystem.write")
        .with_runtime_metadata(
            crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
            working_directory,
        )
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
async fn filesystem_write_file_idempotency_is_session_scoped_for_isolated_worktrees() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let session_a_root = tempfile::tempdir().unwrap();
    let session_b_root = tempfile::tempdir().unwrap();
    let session_a_path = std::fs::canonicalize(session_a_root.path()).unwrap();
    let session_b_path = std::fs::canonicalize(session_b_root.path()).unwrap();
    let relative_path = "packages/agent/docs/rwontwoidempotencyscratch.md";
    for root in [&session_a_path, &session_b_path] {
        std::fs::create_dir_all(root.join("packages/agent/docs")).unwrap();
    }
    let payload = json!({
        "path": relative_path,
        "content": "replay check through execute only."
    });
    let key = "rwontwoalpha";

    let first = handle
        .invoke(host_invocation(
            "filesystem::write_file",
            payload.clone(),
            filesystem_write_context(
                "session-rwo-a",
                key,
                session_a_path.to_string_lossy().as_ref(),
            ),
        ))
        .await;
    assert_eq!(first.error, None);

    let second = handle
        .invoke(host_invocation(
            "filesystem::write_file",
            payload.clone(),
            filesystem_write_context(
                "session-rwo-b",
                key,
                session_b_path.to_string_lossy().as_ref(),
            ),
        ))
        .await;
    assert_eq!(second.error, None);
    assert_eq!(
        second.replayed_from, None,
        "same caller key in a different isolated session must not replay another session path"
    );

    let first_path = first.value.as_ref().unwrap()["path"].as_str().unwrap();
    let second_path = second.value.as_ref().unwrap()["path"].as_str().unwrap();
    assert!(first_path.starts_with(session_a_path.to_string_lossy().as_ref()));
    assert!(second_path.starts_with(session_b_path.to_string_lossy().as_ref()));
    assert_ne!(first_path, second_path);
    assert_eq!(
        std::fs::read_to_string(session_b_path.join(relative_path)).unwrap(),
        "replay check through execute only."
    );

    let replay = handle
        .invoke(host_invocation(
            "filesystem::write_file",
            payload,
            filesystem_write_context(
                "session-rwo-b",
                key,
                session_b_path.to_string_lossy().as_ref(),
            ),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(second.invocation_id.clone()));
    assert_eq!(
        replay.value.as_ref().unwrap()["path"].as_str(),
        Some(second_path)
    );

    let records = handle.invocation_records().await;
    let writes = records
        .iter()
        .filter(|record| {
            record.function_id.as_str() == "filesystem::write_file"
                && record.idempotency_key.as_deref() == Some(key)
        })
        .collect::<Vec<_>>();
    assert_eq!(writes.len(), 3);
    assert_eq!(
        writes[0].idempotency_scope,
        Some(IdempotencyScope::new("session", "session-rwo-a"))
    );
    assert_eq!(
        writes[1].idempotency_scope,
        Some(IdempotencyScope::new("session", "session-rwo-b"))
    );
    assert_eq!(
        writes[2].idempotency_scope,
        Some(IdempotencyScope::new("session", "session-rwo-b"))
    );
    assert_eq!(
        writes[2].replayed_from,
        Some(writes[1].invocation_id.clone())
    );
}

#[tokio::test]
async fn filesystem_apply_patch_is_resource_backed_with_patch_evidence() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("README.md");
    std::fs::write(&target, "Testing out a README here.\n").unwrap();

    let applied = handle
        .invoke(host_invocation(
            "filesystem::apply_patch",
            json!({
                "path": target.to_string_lossy(),
                "oldString": "Testing out a README here.\n",
                "newString": "Testing out a README here.\nExecute apply_patch smoke\n"
            }),
            mutating_causal("filesystem-apply-patch-resource-backed")
                .with_scope("filesystem.write"),
        ))
        .await;
    assert_eq!(applied.error, None);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "Testing out a README here.\nExecute apply_patch smoke\n"
    );
    let value = applied.value.as_ref().unwrap();
    let refs = value["resourceRefs"].as_array().unwrap();
    assert!(refs.iter().any(|reference| {
        reference["kind"] == "materialized_file" && reference["role"] == "updated_file"
    }));
    let patch_ref = refs
        .iter()
        .find(|reference| {
            reference["kind"] == "patch_proposal" && reference["role"] == "applied_patch"
        })
        .expect("apply_patch should return patch proposal evidence");

    let patch = inspect_resource(&handle, patch_ref["resourceId"].as_str().unwrap()).await;
    assert_eq!(patch["resource"]["kind"], "patch_proposal");
    assert_eq!(patch["resource"]["lifecycle"], "proposed");
    let payload = &patch["versions"][0]["payload"];
    assert_eq!(
        payload["targetPath"].as_str(),
        Some(target.to_string_lossy().as_ref())
    );
    assert_eq!(payload["status"], "proposed");
    assert!(
        payload.get("baseContentHash").is_none(),
        "filesystem apply_patch must not persist null optional patch fields"
    );
}

#[tokio::test]
async fn filesystem_apply_patch_empty_old_string_appends_and_replays() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("README.md");
    std::fs::write(&target, "Testing out a README here.\n").unwrap();
    let payload = json!({
        "path": target.to_string_lossy(),
        "oldString": "",
        "newString": "Execute append smoke\n"
    });

    let first = handle
        .invoke(host_invocation(
            "filesystem::apply_patch",
            payload.clone(),
            mutating_causal("filesystem-apply-patch-empty-append").with_scope("filesystem.write"),
        ))
        .await;
    assert_eq!(first.error, None);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "Testing out a README here.\nExecute append smoke\n"
    );
    let value = first.value.as_ref().unwrap();
    assert_eq!(value["replacements"], 1);
    assert!(
        value["diff"]
            .as_str()
            .unwrap()
            .contains("+Execute append smoke")
    );
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "patch_proposal"
                && reference["role"] == "applied_patch")
    );

    let replay = handle
        .invoke(host_invocation(
            "filesystem::apply_patch",
            payload,
            mutating_causal("filesystem-apply-patch-empty-append").with_scope("filesystem.write"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert!(
        replay.replayed_from.is_some(),
        "duplicate append patch key should replay instead of appending again"
    );
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "Testing out a README here.\nExecute append smoke\n"
    );
}

#[tokio::test]
async fn capability_execute_apply_patch_append_shape_runs_without_failed_probe() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("README.md");
    std::fs::write(&target, "Testing out a README here.\n").unwrap();

    let first = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "intent": "Append an exact smoke-test line to README.md.",
                "target": "filesystem::apply_patch",
                "arguments": {
                    "path": target.to_string_lossy(),
                    "newString": "Execute orchestrated append smoke\n"
                },
                "idempotencyKey": "execute-apply-patch-child-append",
                "reason": "Append a deterministic test line"
            }),
            model_execute_context("execute-apply-patch-wrapper-1"),
        ))
        .await;
    assert_eq!(first.error, None);
    let value = first.value.as_ref().unwrap();
    assert_eq!(value["isError"], Value::Null);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "Testing out a README here.\nExecute orchestrated append smoke\n"
    );
    let details = &value["details"];
    assert!(
        details["correctionsApplied"]
            .as_array()
            .unwrap()
            .iter()
            .any(|correction| correction["kind"] == "filesystem_apply_patch_append_shape")
    );
    assert!(
        details["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "patch_proposal")
    );

    let replay = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "intent": "Append an exact smoke-test line to README.md.",
                "target": "filesystem::apply_patch",
                "arguments": {
                    "path": target.to_string_lossy(),
                    "newString": "Execute orchestrated append smoke\n"
                },
                "idempotencyKey": "execute-apply-patch-child-append",
                "reason": "Append a deterministic test line"
            }),
            model_execute_context("execute-apply-patch-wrapper-2"),
        ))
        .await;
    assert_eq!(replay.error, None);
    let replay_value = replay.value.as_ref().unwrap();
    assert_eq!(replay_value["isError"], Value::Null);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "Testing out a README here.\nExecute orchestrated append smoke\n"
    );
    let records = handle.invocation_records().await;
    let apply_patch_records = records
        .iter()
        .filter(|record| {
            record.function_id.as_str() == "filesystem::apply_patch"
                && record.idempotency_key.as_deref() == Some("execute-apply-patch-child-append")
        })
        .collect::<Vec<_>>();
    assert_eq!(
        apply_patch_records.len(),
        2,
        "two execute attempts should produce one child execution and one child replay"
    );
    assert!(
        apply_patch_records
            .iter()
            .any(|record| record.replayed_from.is_some())
    );
}

#[tokio::test]
async fn capability_execute_reports_failed_child_invocation_lineage() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let missing_path = crate::shared::server::test_support::unique_test_path(
        "execute-missing-child-lineage",
        "txt",
    );

    let failed = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "intent": "Read a file that does not exist and report the exact engine failure.",
                "target": "filesystem::read_file",
                "arguments": {"path": missing_path.to_string_lossy()},
                "reason": "Validate failed child invocation lineage"
            }),
            model_execute_context("execute-failed-child-lineage"),
        ))
        .await;
    assert_eq!(failed.error, None);
    let value = failed.value.as_ref().unwrap();
    assert_eq!(value["isError"], true);
    let details = &value["details"];
    assert_eq!(details["status"], "run_failed");
    let child_invocation_ids = details["childInvocationIds"].as_array().unwrap();
    assert_eq!(
        child_invocation_ids.len(),
        1,
        "failed child execution must remain visible to execute callers"
    );
    assert_eq!(
        details["orchestration"]["childInvocationIds"],
        details["childInvocationIds"]
    );

    let records = handle.lock().await.catalog().invocations().to_vec();
    let child_id = child_invocation_ids[0].as_str().unwrap();
    let child_record = records
        .iter()
        .find(|record| record.invocation_id.as_str() == child_id)
        .expect("failed child invocation should be persisted");
    assert_eq!(child_record.function_id.as_str(), "filesystem::read_file");
    assert_eq!(
        child_record.parent_invocation_id,
        Some(failed.invocation_id.clone())
    );
    assert!(!child_record.succeeded);
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
    let materialized_only_path =
        crate::shared::server::test_support::unique_test_path("unregistered-voice-note", "md");
    let materialized_only = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "resourceId": "materialized_file:voice-note:unregistered.md",
                "path": materialized_only_path.to_string_lossy(),
                "content": "this materialized file must not become list truth",
                "scope": "workspace",
                "policy": {"retention": "voice_note"}
            }),
            mutating_causal("voice-notes-materialized-only").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(materialized_only.error, None);

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
