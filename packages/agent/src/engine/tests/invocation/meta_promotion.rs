use super::*;

#[tokio::test]
async fn engine_promote_requires_session_ownership_and_idempotency() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();

    let cross_session = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a"
            }),
            causal()
                .with_session_id("session-b")
                .with_workspace_id("workspace-a")
                .with_idempotency_key("promote-cross"),
        ))
        .await;
    assert!(matches!(
        cross_session.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("session")
    ));

    let promoted = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a"
            }),
            mutating_causal("promote-ok"),
        ))
        .await;
    assert_eq!(promoted.error, None);
    assert_eq!(promoted.value.as_ref().unwrap()["revision"], 2);
    let function = host.catalog().function(&fid("alpha::session")).unwrap();
    assert_eq!(function.visibility, VisibilityScope::Workspace);
    assert_eq!(function.provenance.session_id, None);
    assert_eq!(
        function.provenance.workspace_id.as_deref(),
        Some("workspace-a")
    );

    let replay = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a"
            }),
            mutating_causal("promote-ok"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(promoted.invocation_id));
    assert_eq!(replay.value.as_ref().unwrap()["revision"], 2);
    assert_eq!(
        host.catalog()
            .function(&fid("alpha::session"))
            .unwrap()
            .revision,
        FunctionRevision(2)
    );
}

#[tokio::test]
async fn engine_promote_conflicting_duplicate_key_does_not_mutate_new_target() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    for id in ["alpha::one", "alpha::two"] {
        host.catalog_mut()
            .register_function(
                FunctionDefinition::new(
                    fid(id),
                    wid("w1"),
                    "session function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(
                    Provenance::new(actor("agent"), "test").with_session_id("session-a"),
                ),
                Some(handler()),
                true,
            )
            .unwrap();
    }

    let first = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::one",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a"
            }),
            mutating_causal("promote-shared-key"),
        ))
        .await;
    assert_eq!(first.error, None);

    let conflict = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::two",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a"
            }),
            mutating_causal("promote-shared-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    assert_eq!(
        host.catalog()
            .function(&fid("alpha::two"))
            .unwrap()
            .visibility,
        VisibilityScope::Session
    );
}
