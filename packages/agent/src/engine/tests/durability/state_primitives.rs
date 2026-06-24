use super::*;

#[tokio::test]
async fn state_primitive_revisions_cas_list_and_delete_are_idempotent() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let context = |key: &str| {
        mutating_causal(key)
            .with_scope("state.write")
            .with_session_id("session-a")
    };
    let set = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "value": {"text": "one"}
            }),
            context("state-set-1"),
        ))
        .await;
    assert_eq!(set.error, None);
    assert_eq!(set.value.as_ref().unwrap()["entry"]["revision"], 1);

    let replay = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "value": {"text": "one"}
            }),
            context("state-set-1"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(set.invocation_id.clone()));

    let cas = handle
        .invoke(host_invocation(
            "state::compare_and_set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "expectedRevision": 1,
                "value": {"text": "two"}
            }),
            context("state-cas-1"),
        ))
        .await;
    assert_eq!(cas.error, None);
    assert_eq!(cas.value.as_ref().unwrap()["entry"]["revision"], 2);

    let stale = handle
        .invoke(host_invocation(
            "state::compare_and_set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "expectedRevision": 1,
                "value": {"text": "three"}
            }),
            context("state-cas-stale"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("revision conflict")
    ));

    let listed = handle
        .invoke(host_invocation(
            "state::list",
            json!({"scope": "session", "namespace": "agent", "keyPrefix": "dr"}),
            causal()
                .with_scope("state.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert_eq!(
        listed.value.as_ref().unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let deleted = handle
        .invoke(host_invocation(
            "state::delete",
            json!({"scope": "session", "namespace": "agent", "key": "draft"}),
            context("state-delete-1"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["deleted"], true);
}
