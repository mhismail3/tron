use super::*;

fn prompt_read_context() -> CausalContext {
    causal()
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_scope("prompt_library.read")
}

fn prompt_write_context(key: &str) -> CausalContext {
    mutating_causal(key).with_scope("prompt_library.write")
}

fn prompt_internal_write_context(key: &str) -> CausalContext {
    prompt_write_context(key).with_scope(crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE)
}

async fn prompt_artifacts(handle: &EngineHostHandle, prefix: &str) -> Vec<Value> {
    let listed = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"kind": "artifact", "limit": 10_000}),
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
                .is_some_and(|id| id.starts_with(prefix))
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

fn assert_retired_prompt_tables_absent(ctx: &crate::shared::server::context::ServerRuntimeContext) {
    let conn = ctx.event_store.pool().get().unwrap();
    let retired_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name IN ('prompt_history', 'prompt_snippets')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        retired_count, 0,
        "fresh modular-engine-v4 databases must not create retired prompt-library tables"
    );
}

#[tokio::test]
async fn prompt_snippets_are_resource_backed_without_retired_tables() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    assert_retired_prompt_tables_absent(&ctx);

    let created = handle
        .invoke(host_invocation(
            "prompt_library::snippet_create",
            json!({"name": "Resource snippet", "text": "Use substrate resources"}),
            prompt_write_context("prompt-snippet-create"),
        ))
        .await;
    assert_eq!(created.error, None);
    let created_value = created.value.as_ref().unwrap();
    let snippet = &created_value["snippet"];
    assert_eq!(snippet["name"], "Resource snippet");
    assert!(
        created_value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "artifact")
    );

    let listed = handle
        .invoke(host_invocation(
            "prompt_library::snippet_list",
            json!({}),
            prompt_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    let items = listed.value.as_ref().unwrap()["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], snippet["id"]);

    let updated = handle
        .invoke(host_invocation(
            "prompt_library::snippet_update",
            json!({"id": snippet["id"], "text": "Updated resource text"}),
            prompt_write_context("prompt-snippet-update"),
        ))
        .await;
    assert_eq!(updated.error, None);
    assert_eq!(
        updated.value.as_ref().unwrap()["snippet"]["text"],
        "Updated resource text"
    );
    assert!(
        updated.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["role"] == "updated")
    );

    let deleted = handle
        .invoke(host_invocation(
            "prompt_library::snippet_delete",
            json!({"id": snippet["id"]}),
            prompt_write_context("prompt-snippet-delete"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["deleted"], true);
    let resource_id = created_value["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap();
    let inspection = inspect_resource(&handle, resource_id).await;
    assert_eq!(
        inspection["resource"]["scope"], "system",
        "prompt snippets are reusable library state, not chat-session state"
    );
    assert_eq!(inspection["resource"]["lifecycle"], "discarded");
}

#[tokio::test]
async fn prompt_history_is_resource_backed_deduped_without_retired_tables() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    assert_retired_prompt_tables_absent(&ctx);

    let first = handle
        .invoke(host_invocation(
            "prompt_library::history_record",
            json!({"prompt": "  Remember this prompt  "}),
            prompt_internal_write_context("prompt-history-record-1"),
        ))
        .await;
    assert_eq!(first.error, None);
    assert_eq!(first.value.as_ref().unwrap()["recorded"], true);
    assert!(
        first.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "artifact")
    );
    let history_resource_id = first.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap();
    let history_inspection = inspect_resource(&handle, history_resource_id).await;
    assert_eq!(
        history_inspection["resource"]["scope"], "system",
        "prompt history is reusable library state, not chat-session state"
    );

    let second = handle
        .invoke(host_invocation(
            "prompt_library::history_record",
            json!({"prompt": "Remember this prompt"}),
            prompt_internal_write_context("prompt-history-record-2"),
        ))
        .await;
    assert_eq!(second.error, None);

    let listed = handle
        .invoke(host_invocation(
            "prompt_library::history_list",
            json!({"limit": 20}),
            prompt_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    let items = listed.value.as_ref().unwrap()["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "Remember this prompt");
    assert_eq!(items[0]["useCount"], 2);
    assert_eq!(
        prompt_artifacts(&handle, "artifact:prompt-history:")
            .await
            .len(),
        1
    );
}

#[tokio::test]
async fn prompt_history_skip_and_validation_fail_without_accepted_refs() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let skipped = handle
        .invoke(host_invocation(
            "prompt_library::history_record",
            json!({"prompt": "skip me", "source": "cron:daily"}),
            prompt_internal_write_context("prompt-history-skip-cron"),
        ))
        .await;
    assert_eq!(skipped.error, None);
    assert_eq!(skipped.value.as_ref().unwrap()["recorded"], false);
    assert!(
        skipped.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let failed = handle
        .invoke(host_invocation(
            "prompt_library::snippet_create",
            json!({"name": "Secret", "text": "secret=raw-value"}),
            prompt_write_context("prompt-snippet-secret"),
        ))
        .await;
    assert!(failed.error.is_some());
    let records = handle.lock().await.catalog().invocations().to_vec();
    let record = records
        .iter()
        .find(|record| record.invocation_id == failed.invocation_id)
        .expect("failed prompt invocation should remain inspectable");
    assert!(!record.succeeded);
    assert!(record.produced_resource_refs.is_empty());
    assert!(
        prompt_artifacts(&handle, "artifact:prompt-snippet:")
            .await
            .is_empty()
    );
}

#[tokio::test]
async fn prompt_library_idempotency_and_history_delete_clear_do_not_duplicate_resources() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let first = handle
        .invoke(host_invocation(
            "prompt_library::snippet_create",
            json!({"name": "Reusable", "text": "Do the thing"}),
            prompt_write_context("prompt-snippet-idempotent"),
        ))
        .await;
    assert_eq!(first.error, None);
    let second = handle
        .invoke(host_invocation(
            "prompt_library::snippet_create",
            json!({"name": "Reusable", "text": "Do the thing"}),
            prompt_write_context("prompt-snippet-idempotent"),
        ))
        .await;
    assert_eq!(second.error, None);
    assert_eq!(
        first.value.as_ref().unwrap()["resourceRefs"],
        second.value.as_ref().unwrap()["resourceRefs"]
    );
    assert_eq!(
        prompt_artifacts(&handle, "artifact:prompt-snippet:")
            .await
            .len(),
        1
    );

    for (key, prompt) in [
        ("prompt-history-delete-a", "delete this prompt"),
        ("prompt-history-delete-b", "clear this prompt"),
    ] {
        let recorded = handle
            .invoke(host_invocation(
                "prompt_library::history_record",
                json!({"prompt": prompt}),
                prompt_internal_write_context(key),
            ))
            .await;
        assert_eq!(recorded.error, None);
    }
    let listed = handle
        .invoke(host_invocation(
            "prompt_library::history_list",
            json!({"limit": 20}),
            prompt_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    let first_history_id = listed.value.as_ref().unwrap()["items"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let deleted = handle
        .invoke(host_invocation(
            "prompt_library::history_delete",
            json!({"id": first_history_id}),
            prompt_write_context("prompt-history-delete"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["deleted"], true);
    assert!(
        deleted.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["role"] == "discarded")
    );

    let cleared = handle
        .invoke(host_invocation(
            "prompt_library::history_clear",
            json!({}),
            prompt_write_context("prompt-history-clear"),
        ))
        .await;
    assert_eq!(cleared.error, None);
    assert_eq!(cleared.value.as_ref().unwrap()["deletedCount"], 1);
    let listed_after_clear = handle
        .invoke(host_invocation(
            "prompt_library::history_list",
            json!({"limit": 20}),
            prompt_read_context(),
        ))
        .await;
    assert_eq!(listed_after_clear.error, None);
    assert!(
        listed_after_clear.value.as_ref().unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}
