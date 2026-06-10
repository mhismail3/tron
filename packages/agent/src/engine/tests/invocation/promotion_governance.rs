use super::promotion_governance_support::*;
use super::*;

#[tokio::test]
async fn engine_promote_requires_governance_authority_and_session_ownership() {
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
    let refs = create_promotion_governance(
        &mut host,
        "workspace",
        "alpha::session",
        "workspace",
        Some("workspace-a"),
        "capability_definition",
    )
    .await;

    let no_promote_grant = host
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "no-promote-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["engine::discover"],
                "allowedNamespaces": ["engine"],
                "allowedAuthorityScopes": ["engine.discover"],
                "allowedResourceKinds": ["*"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "critical"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("promote-grant-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-no-promote"),
        ))
        .await;
    assert_eq!(no_promote_grant.error, None);

    let no_scope = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::session",
                "workspace",
                Some("workspace-a"),
                "promote-no-scope",
                &refs,
            ),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("no-promote-grant"),
                trace("promote-no-grant"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_scope("engine.promote")
            .with_idempotency_key("promote-no-scope"),
        ))
        .await;
    assert!(matches!(
        no_scope.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow function")
                || message.contains("does not allow required authority")
    ));

    let cross_session = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::session",
                "workspace",
                Some("workspace-a"),
                "promote-cross",
                &refs,
            ),
            causal()
                .with_session_id("session-b")
                .with_workspace_id("workspace-a")
                .with_idempotency_key("promote-cross")
                .with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        cross_session.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("session")
    ));

    let cross_workspace = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::session",
                "workspace",
                Some("workspace-a"),
                "promote-cross-workspace",
                &refs,
            ),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-b")
                .with_idempotency_key("promote-cross-workspace")
                .with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        cross_workspace.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("workspace authority")
    ));

    let missing_governance = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "idempotencyKey": "promote-missing-governance"
            }),
            mutating_causal("promote-missing-governance").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        missing_governance.error,
        Some(EngineError::SchemaViolation { .. })
    ));

    let promoted = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::session",
                "workspace",
                Some("workspace-a"),
                "promote-ok",
                &refs,
            ),
            mutating_causal("promote-ok").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(promoted.error, None);
    assert_eq!(promoted.value.as_ref().unwrap()["revision"], 2);
    assert_eq!(
        promoted.value.as_ref().unwrap()["decisionResourceId"],
        "sapg-workspace-decision"
    );
    assert_eq!(
        promoted.value.as_ref().unwrap()["evidenceResourceIds"],
        json!(["sapg-workspace-evidence"])
    );
    assert_eq!(
        promoted.value.as_ref().unwrap()["candidateResourceIds"],
        json!(["sapg-workspace-candidate"])
    );
    let function = host.catalog().function(&fid("alpha::session")).unwrap();
    assert_eq!(function.visibility, VisibilityScope::Workspace);
    assert_eq!(function.provenance.session_id, None);
    assert_eq!(
        function.provenance.workspace_id.as_deref(),
        Some("workspace-a")
    );
    assert_eq!(
        function.metadata["promotionGovernance"]["decisionResourceId"],
        "sapg-workspace-decision"
    );
    assert_eq!(
        function.metadata["promotionGovernance"]["candidateResourceIds"],
        json!(["sapg-workspace-candidate"])
    );

    let replay = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::session",
                "workspace",
                Some("workspace-a"),
                "promote-ok",
                &refs,
            ),
            mutating_causal("promote-ok").with_scope("engine.promote.workspace"),
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
async fn engine_promote_system_requires_admin_authority_and_verified_chain() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::system_candidate"),
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
    let refs = create_promotion_governance(
        &mut host,
        "system",
        "alpha::system_candidate",
        "system",
        None,
        "materialized_file",
    )
    .await;

    let non_admin = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::system_candidate",
                "system",
                None,
                "promote-system-non-admin",
                &refs,
            ),
            mutating_causal("promote-system-non-admin").with_scope("engine.promote.system"),
        ))
        .await;
    assert!(matches!(
        non_admin.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("admin authority")
    ));

    let admin = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::system_candidate",
                "system",
                None,
                "promote-system-admin",
                &refs,
            ),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("grant"),
                trace("promote-system-admin"),
            )
            .with_session_id("session-a")
            .with_idempotency_key("promote-system-admin")
            .with_scope("engine.promote.system"),
        ))
        .await;
    assert_eq!(admin.error, None);
    let function = host
        .catalog()
        .function(&fid("alpha::system_candidate"))
        .unwrap();
    assert_eq!(function.visibility, VisibilityScope::System);
    assert_eq!(function.provenance.session_id, None);
    assert_eq!(function.provenance.workspace_id, None);
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
    let refs = create_promotion_governance(
        &mut host,
        "conflict",
        "alpha::one",
        "workspace",
        Some("workspace-a"),
        "artifact",
    )
    .await;

    let first = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::one",
                "workspace",
                Some("workspace-a"),
                "promote-shared-key",
                &refs,
            ),
            mutating_causal("promote-shared-key").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(first.error, None);

    let conflict = host
        .invoke(host_invocation(
            "engine::promote",
            governed_promote_payload(
                "alpha::two",
                "workspace",
                Some("workspace-a"),
                "promote-shared-key",
                &refs,
            ),
            mutating_causal("promote-shared-key").with_scope("engine.promote.workspace"),
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
