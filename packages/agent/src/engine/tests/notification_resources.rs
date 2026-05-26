use super::*;

fn notification_read_context() -> CausalContext {
    causal()
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_scope("notifications.read")
}

fn notification_write_context(key: &str) -> CausalContext {
    mutating_causal(key).with_scope("notifications.write")
}

fn notification_ui_context(key: &str) -> CausalContext {
    mutating_causal(key)
        .with_scope("ui.write")
        .with_scope("notifications.read")
        .with_scope("notifications.write")
}

async fn list_notifications(handle: &EngineHostHandle) -> Value {
    let listed = handle
        .invoke(host_invocation(
            "notifications::list",
            json!({"limit": 50}),
            notification_read_context(),
        ))
        .await;
    assert_eq!(listed.error, None);
    listed.value.unwrap()
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

async fn resources_with_kind(handle: &EngineHostHandle, kind: &str) -> Vec<Value> {
    let listed = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"kind": kind, "limit": 10_000}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(listed.error, None);
    listed.value.unwrap()["resources"]
        .as_array()
        .cloned()
        .unwrap()
}

fn assert_retired_notification_read_state_absent(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
) {
    let conn = ctx.event_store.pool().get().unwrap();
    let retired_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'notification_read_state'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        retired_count, 0,
        "fresh current databases must not create notification_read_state"
    );
}

#[tokio::test]
async fn notifications_send_list_and_read_are_resource_backed() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    assert_retired_notification_read_state_absent(&ctx);

    let sent = handle
        .invoke(host_invocation(
            "notifications::send",
            json!({
                "title": "Resource backed",
                "body": "Notification durable truth is a resource.",
                "priority": "normal",
                "data": {"kind": "test"}
            }),
            notification_write_context("notification-resource-send"),
        ))
        .await;
    assert_eq!(sent.error, None);
    let sent_value = sent.value.as_ref().unwrap();
    assert_eq!(sent_value["title"], "Resource backed");
    assert!(
        sent_value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "notification")
    );
    assert!(
        sent_value["evidenceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence"),
        "stub push delivery should still leave delivery evidence"
    );

    let listed = list_notifications(&handle).await;
    let items = listed["notifications"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["title"], "Resource backed");
    assert_eq!(items[0]["isRead"], false);
    assert!(
        items[0]["eventId"]
            .as_str()
            .unwrap()
            .starts_with("notification:")
    );
    assert_eq!(
        items[0]["notificationResourceId"], items[0]["eventId"],
        "eventId is now the stable notification resource id"
    );
    assert_eq!(listed["unreadCount"], 1);

    let read = handle
        .invoke(host_invocation(
            "notifications::mark_read",
            json!({"eventId": items[0]["eventId"]}),
            notification_write_context("notification-mark-read"),
        ))
        .await;
    assert_eq!(read.error, None);
    let read_value = read.value.as_ref().unwrap();
    assert_eq!(read_value["success"], true);
    assert!(
        read_value["decisionRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "decision")
    );

    let after_read = list_notifications(&handle).await;
    assert_eq!(after_read["notifications"][0]["isRead"], true);
    assert_eq!(after_read["unreadCount"], 0);
}

#[tokio::test]
async fn notification_list_ignores_unregistered_event_only_rows() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    assert_retired_notification_read_state_absent(&ctx);

    {
        let conn = ctx.event_store.pool().get().unwrap();
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('workspace-a', '/tmp/workspace-a', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('session-a', 'workspace-a', 'gpt-test', '/tmp/workspace-a', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_unregistered_notification', 'session-a', 1, 'capability.invocation.completed',
                     '2026-01-01T00:00:00Z',
                     '{\"contractId\":\"notifications::send\",\"details\":{\"output\":{\"title\":\"Unregistered\",\"body\":\"Ignore me\"}}}',
                     'workspace-a')",
            [],
        )
        .unwrap();
    }

    let listed = list_notifications(&handle).await;
    assert_eq!(
        listed["notifications"].as_array().unwrap().len(),
        0,
        "event-only notification rows are historical invocation records, not inbox truth"
    );
}

#[tokio::test]
async fn notification_mark_all_read_creates_one_scoped_decision() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    for idx in 0..2 {
        let sent = handle
            .invoke(host_invocation(
                "notifications::send",
                json!({
                    "title": format!("Notice {idx}"),
                    "body": "Needs a read decision.",
                    "priority": "normal"
                }),
                notification_write_context(&format!("notification-send-{idx}")),
            ))
            .await;
        assert_eq!(sent.error, None);
    }

    let marked = handle
        .invoke(host_invocation(
            "notifications::mark_all_read",
            json!({"sessionId": "session-a"}),
            notification_write_context("notification-mark-all"),
        ))
        .await;
    assert_eq!(marked.error, None);
    assert_eq!(marked.value.as_ref().unwrap()["marked"], 2);
    assert_eq!(
        marked.value.as_ref().unwrap()["decisionRefs"]
            .as_array()
            .unwrap()
            .len(),
        1,
        "mark_all_read should store one bounded scoped decision"
    );

    let replay = handle
        .invoke(host_invocation(
            "notifications::mark_all_read",
            json!({"sessionId": "session-a"}),
            notification_write_context("notification-mark-all"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.value, marked.value);
    assert_eq!(resources_with_kind(&handle, "decision").await.len(), 1);
    assert_eq!(list_notifications(&handle).await["unreadCount"], 0);
}

#[tokio::test]
async fn notification_read_state_requires_decision_linkage() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let sent = handle
        .invoke(host_invocation(
            "notifications::send",
            json!({
                "title": "Linked read state",
                "body": "Read projection must require resource linkage.",
                "priority": "normal"
            }),
            notification_write_context("notification-linkage-send"),
        ))
        .await;
    assert_eq!(sent.error, None);
    let listed = list_notifications(&handle).await;
    let notification_id = listed["notifications"][0]["eventId"]
        .as_str()
        .unwrap()
        .to_owned();

    let unlinked_decision = handle
        .invoke(host_invocation(
            "decision::create",
            json!({
                "resourceId": "decision:notification-read:unlinked",
                "scope": "system",
                "lifecycle": "final",
                "payload": {
                    "status": "final",
                    "summary": "Unlinked notification read decision",
                    "metadata": {
                        "decisionType": "notification_read",
                        "notificationResourceId": notification_id,
                        "readAt": "2026-01-01T00:00:00Z"
                    }
                }
            }),
            mutating_causal("notification-unlinked-read-decision").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(unlinked_decision.error, None);

    let after_unlinked_decision = list_notifications(&handle).await;
    assert_eq!(after_unlinked_decision["notifications"][0]["isRead"], false);
    assert_eq!(after_unlinked_decision["unreadCount"], 1);
}

#[tokio::test]
async fn notification_generated_inbox_surface_uses_stored_canonical_actions() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let sent = handle
        .invoke(host_invocation(
            "notifications::send",
            json!({
                "title": "Generated inbox",
                "body": "This row should render from notification resource truth.",
                "priority": "high"
            }),
            notification_write_context("notification-generated-inbox-send"),
        ))
        .await;
    assert_eq!(sent.error, None);

    let surface = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            json!({
                "targetType": "resource_collection",
                "targetId": "notification",
                "purpose": "Review notifications",
                "layoutProfile": "notifications.inbox.v1",
                "maxPreviewBytes": 512,
                "expiresAt": "2100-01-01T00:00:00Z"
            }),
            notification_ui_context("notification-generated-inbox-surface"),
        ))
        .await;
    assert_eq!(surface.error, None);
    let value = surface.value.as_ref().unwrap();
    let authored = &value["surface"];
    assert_eq!(authored["authoring"]["targetType"], "resource_collection");
    assert_eq!(
        authored["authoring"]["layoutProfile"],
        "notifications.inbox.v1"
    );
    assert!(authored["layout"].to_string().contains("Generated inbox"));

    let actions = authored["actions"].as_array().unwrap();
    assert!(actions.iter().any(|action| {
        action["targetFunctionId"] == "notifications::mark_read"
            && action["payloadTemplate"]["eventId"].is_string()
            && action["idempotencyKeyTemplate"] == "${submission.idempotencyKey}"
    }));
    assert!(actions.iter().any(|action| {
        action["targetFunctionId"] == "notifications::mark_all_read"
            && action["idempotencyKeyTemplate"] == "${submission.idempotencyKey}"
    }));
    assert!(
        actions
            .iter()
            .all(|action| action.get("payloadTemplate").is_some()),
        "generated notification actions must be server-authored stored templates"
    );
}

#[tokio::test]
async fn notification_resources_are_inspectable_after_stub_delivery_failure() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let sent = handle
        .invoke(host_invocation(
            "notifications::send",
            json!({
                "title": "Stub delivery",
                "body": "No APNs service is configured in tests.",
                "priority": "normal"
            }),
            notification_write_context("notification-stub-delivery"),
        ))
        .await;
    assert_eq!(sent.error, None);
    let value = sent.value.as_ref().unwrap();
    assert_eq!(value["success"], false);
    let notification_ref = value["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "notification")
        .expect("notification ref");
    let inspection =
        inspect_resource(&handle, notification_ref["resourceId"].as_str().unwrap()).await;
    let current = inspection["resource"]["currentVersionId"].as_str().unwrap();
    let payload = inspection["versions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|version| version["versionId"] == current)
        .unwrap()["payload"]
        .clone();
    assert_eq!(payload["delivery"]["success"], false);
    assert_eq!(inspection["resource"]["lifecycle"], "delivery_failed");
    assert!(
        value["evidenceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
}
