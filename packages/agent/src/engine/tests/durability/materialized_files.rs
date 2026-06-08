use super::*;
#[tokio::test]
async fn materialized_file_update_writes_file_and_returns_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("nested").join("result.txt");

    let result = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "resource-owned bytes"
            }),
            mutating_causal("materialized-file-update").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "resource-owned bytes"
    );
    let value = result.value.as_ref().unwrap();
    assert_eq!(value["version"]["state"], "available");
    assert_eq!(value["resourceRefs"][0]["kind"], "materialized_file");
    assert_eq!(value["resourceRefs"][0]["role"], "updated");
}

#[tokio::test]
async fn materialized_file_update_resolves_relative_paths_with_runtime_working_directory() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let relative = format!("tron-runtime-cwd-test-{}/result.txt", uuid::Uuid::now_v7());
    let causal = mutating_causal("materialized-file-runtime-cwd")
        .with_scope("resource.write")
        .with_runtime_metadata(
            crate::engine::invocation::model::RUNTIME_METADATA_WORKING_DIRECTORY,
            tmp.path().to_string_lossy(),
        );

    let result = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": relative,
                "content": "runtime-owned bytes"
            }),
            causal,
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        std::fs::read_to_string(tmp.path().join(&relative)).unwrap(),
        "runtime-owned bytes"
    );
    assert!(
        !std::path::Path::new(&relative).exists(),
        "relative materialized paths must not use the server cwd when runtime working directory is present"
    );
}

#[tokio::test]
async fn materialized_file_update_rejects_relative_runtime_path_escape() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let causal = mutating_causal("materialized-file-runtime-cwd-escape")
        .with_scope("resource.write")
        .with_runtime_metadata(
            crate::engine::invocation::model::RUNTIME_METADATA_WORKING_DIRECTORY,
            tmp.path().to_string_lossy(),
        );

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": "../escape.txt",
                "content": "should not be written"
            }),
            causal,
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("must stay inside")
    ));
    assert!(!tmp.path().parent().unwrap().join("escape.txt").exists());
}

#[tokio::test]
async fn materialized_file_version_conflict_does_not_touch_target_file() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("result.txt");

    let first = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "first version"
            }),
            mutating_causal("materialized-file-conflict-first").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(first.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "should not be written",
                "expectedCurrentVersionId": "wrong-version"
            }),
            mutating_causal("materialized-file-conflict-second").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "first version");
}

#[tokio::test]
async fn materialized_file_invalid_scope_does_not_touch_target_file() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("result.txt");

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "should not be written",
                "scope": "workspace",
                "workspaceId": ""
            }),
            mutating_causal("materialized-file-invalid-scope").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("workspaceId must not be empty")
    ));
    assert!(
        !target.exists(),
        "invalid resource scope must fail before target bytes are written"
    );
}

#[tokio::test]
async fn materialized_file_hash_verify_marks_missing_bytes_as_damaged_truth() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("missing.txt");

    let created = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": "materialized_file:missing-bytes-test",
                "kind": "materialized_file",
                "scope": "session",
                "lifecycle": "materialized",
                "payload": {
                    "canonicalPath": missing.to_string_lossy(),
                    "relativePath": "missing.txt",
                    "entryType": "file",
                    "content": "expected bytes",
                    "contentHash": "expected-hash",
                    "sizeBytes": 14,
                    "mimeType": "text/plain",
                    "metadata": {"fixture": "missing-bytes"}
                },
                "locations": [{
                    "kind": "file",
                    "uri": missing.to_string_lossy(),
                    "mimeType": "text/plain",
                    "sizeBytes": 14
                }]
            }),
            mutating_causal("materialized-file-missing-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let original_current = created.value.as_ref().unwrap()["resource"]["currentVersionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let verified = handle
        .invoke(host_invocation(
            "materialized_file::hash_verify",
            json!({"resourceId": "materialized_file:missing-bytes-test"}),
            mutating_causal("materialized-file-missing-verify").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(verified.error, None);
    let value = verified.value.as_ref().unwrap();
    assert_eq!(value["version"]["state"], "damaged");
    assert_eq!(value["resourceRefs"][0]["role"], "damaged");
    assert!(value["version"]["payload"]["actualContentHash"].is_null());
    assert!(
        value["version"]["payload"]["damageReason"]
            .as_str()
            .unwrap()
            .contains("missing or unreadable")
    );

    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": "materialized_file:missing-bytes-test"}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let inspection = &inspected.value.as_ref().unwrap()["inspection"];
    assert_eq!(inspection["resource"]["lifecycle"], "damaged");
    assert_eq!(inspection["resource"]["currentVersionId"], original_current);
    assert_eq!(inspection["versions"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn materialized_file_read_rejects_discarded_resource_but_inspect_remains_available() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("discarded.txt");
    let resource_id = "materialized_file:discarded-read-test";

    let created = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "resourceId": resource_id,
                "path": target.to_string_lossy(),
                "content": "discard me",
                "scope": "session"
            }),
            mutating_causal("materialized-file-discarded-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let current = created.value.as_ref().unwrap()["version"]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let discarded = handle
        .invoke(host_invocation(
            "materialized_file::discard",
            json!({
                "resourceId": resource_id,
                "expectedCurrentVersionId": current
            }),
            mutating_causal("materialized-file-discarded-discard").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(discarded.error, None);

    let inspected = handle
        .invoke(host_invocation(
            "materialized_file::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    assert_eq!(
        inspected.value.as_ref().unwrap()["inspection"]["resource"]["lifecycle"],
        "discarded"
    );

    let read = handle
        .invoke(host_invocation(
            "materialized_file::read",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert!(matches!(
        read.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("discarded")
    ));
}
