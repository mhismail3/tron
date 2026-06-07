use super::*;

#[test]
fn empty_catalog_starts_at_revision_zero() {
    let catalog = LiveCatalog::new();
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.workers().is_empty());
    assert!(catalog.changes().is_empty());
}

#[test]
fn worker_registration_updates_revision_and_owner_conflicts_are_rejected() {
    let mut catalog = LiveCatalog::new();
    let rev = catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    assert_eq!(rev.0, 1);
    assert_eq!(catalog.revision().0, 1);
    assert_eq!(catalog.worker_is_volatile(&wid("w1")), Some(true));

    let rev = catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    assert_eq!(rev.0, 2);
    assert_eq!(catalog.revision().0, 2);

    let conflicting = WorkerDefinition::new(
        wid("w1"),
        WorkerKind::InProcess,
        actor("other"),
        grant("grant"),
    )
    .with_namespace_claim("alpha");
    assert!(matches!(
        catalog.register_worker(conflicting, true),
        Err(EngineError::OwnerMismatch { kind: "worker", .. })
    ));
}

#[test]
fn function_registration_requires_owner_and_namespace_claim() {
    let mut catalog = LiveCatalog::new();
    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w1"), Some(handler()), true),
        Err(EngineError::NotFound { kind: "worker", .. })
    ));

    catalog.register_worker(worker("w1", "beta"), true).unwrap();
    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w1"), Some(handler()), true),
        Err(EngineError::NamespaceDenied { .. })
    ));
}

#[test]
fn function_registration_allows_same_owner_update_and_rejects_cross_owner() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_worker(worker("w2", "alpha"), true)
        .unwrap();

    let rev = catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    assert_eq!(rev.0, 1);
    let rev = catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    assert_eq!(rev.0, 2);

    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w2"), Some(handler()), true),
        Err(EngineError::OwnerMismatch {
            kind: "function",
            ..
        })
    ));
}

#[test]
fn mutating_function_requires_idempotency() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let missing_contract = FunctionDefinition::new(
        fid("alpha::write"),
        wid("w1"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    );
    assert!(matches!(
        catalog.register_function(missing_contract, Some(handler()), true),
        Err(EngineError::PolicyViolation(message)) if message.contains("requires idempotency")
    ));

    let internal_missing_contract = FunctionDefinition::new(
        fid("alpha::internal_write"),
        wid("w1"),
        "internal write",
        VisibilityScope::Internal,
        EffectClass::IdempotentWrite,
    );
    assert!(matches!(
        catalog.register_function(internal_missing_contract, Some(handler()), true),
        Err(EngineError::PolicyViolation(message)) if message.contains("requires idempotency")
    ));

    catalog
        .register_function(write_function("alpha::write", "w1"), Some(handler()), true)
        .unwrap();
}

#[test]
fn high_risk_agent_visible_function_requires_compensation_metadata() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let irreversible = FunctionDefinition::new(
        fid("alpha::delete_forever"),
        wid("w1"),
        "irreversible",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_idempotency(IdempotencyContract::caller_session());
    assert!(matches!(
        catalog.register_function(irreversible, Some(handler()), true),
        Err(EngineError::PolicyViolation(message)) if message.contains("compensation")
    ));

    let compensated = FunctionDefinition::new(
        fid("alpha::delete_forever"),
        wid("w1"),
        "irreversible",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_idempotency(IdempotencyContract::caller_session())
    .with_required_authority(AuthorityRequirement::scope("delete"))
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "test irreversible operation requires manual recovery notes",
    ));
    catalog
        .register_function(compensated, Some(handler()), true)
        .unwrap();
}

#[test]
fn catalog_changes_increment_by_one_and_record_subjects() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    let changes = catalog.changes();
    assert_eq!(changes.len(), 2);
    assert_eq!(changes[0].before.0, 0);
    assert_eq!(changes[0].after.0, 1);
    assert_eq!(changes[1].before.0, 1);
    assert_eq!(changes[1].after.0, 2);
    assert_eq!(changes[1].kind, CatalogChangeKind::FunctionRegistered);
    assert_eq!(changes[1].subject_id, "alpha::read");
    assert_eq!(changes[1].subject_kind, CatalogSubjectKind::Function);
    assert_eq!(changes[1].class, CatalogChangeClass::Availability);
    assert_eq!(changes[1].visibility, VisibilityScope::Agent);
}

#[test]
fn discovery_is_sorted_and_filters_visibility_namespace_effect_risk_health_and_text() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::zeta", "w1").with_tags(vec!["lookup".to_owned()]),
            Some(handler()),
            true,
        )
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::beta", "w1")
                .with_risk(RiskLevel::Medium)
                .with_health(FunctionHealth::Degraded),
            Some(handler()),
            true,
        )
        .unwrap();
    let internal = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal",
        VisibilityScope::Internal,
        EffectClass::PureRead,
    );
    catalog
        .register_function(internal, Some(handler()), true)
        .unwrap();

    let agent = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"));
    let all = catalog.discover_functions(&FunctionQuery {
        actor: Some(agent.clone()),
        ..FunctionQuery::default()
    });
    assert_eq!(
        all.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::beta", "alpha::zeta"]
    );

    let filtered = catalog.discover_functions(&FunctionQuery {
        namespace_prefix: Some("alpha::z".to_owned()),
        text: Some("lookup".to_owned()),
        effect_class: Some(EffectClass::PureRead),
        max_risk: Some(RiskLevel::Low),
        health: Some(FunctionHealth::Healthy),
        include_internal: false,
        actor: Some(agent),
        visibility: None,
    });
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id.as_str(), "alpha::zeta");
}

#[test]
fn discovery_text_query_matches_tokens_across_canonical_id() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("worker", "worker"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("worker::list", "worker"),
            Some(handler()),
            true,
        )
        .unwrap();

    let agent = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"));
    let filtered = catalog.discover_functions(&FunctionQuery {
        text: Some("worker list".to_owned()),
        actor: Some(agent),
        ..FunctionQuery::default()
    });

    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id.as_str(), "worker::list");
}

#[test]
fn discovery_enforces_scoped_visibility_and_internal_requires_admin() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let session_function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    let workspace_function = FunctionDefinition::new(
        fid("alpha::workspace"),
        wid("w1"),
        "workspace function",
        VisibilityScope::Workspace,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_workspace_id("workspace-a"));
    let internal_function = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal function",
        VisibilityScope::Internal,
        EffectClass::PureRead,
    );
    catalog
        .register_function(session_function, Some(handler()), true)
        .unwrap();
    catalog
        .register_function(workspace_function, Some(handler()), true)
        .unwrap();
    catalog
        .register_function(internal_function, Some(handler()), true)
        .unwrap();

    let scoped_actor = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-a")
        .with_workspace_id("workspace-a");
    let scoped = catalog.discover_functions(&FunctionQuery {
        actor: Some(scoped_actor),
        include_internal: true,
        ..FunctionQuery::default()
    });
    assert_eq!(
        scoped.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::session", "alpha::workspace"]
    );

    let other_session = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-b")
        .with_workspace_id("workspace-a");
    let workspace_only = catalog.discover_functions(&FunctionQuery {
        actor: Some(other_session),
        ..FunctionQuery::default()
    });
    assert_eq!(
        workspace_only
            .iter()
            .map(|f| f.id.as_str())
            .collect::<Vec<_>>(),
        vec!["alpha::workspace"]
    );

    let admin = ActorContext::new(actor("admin"), ActorKind::Admin, grant("grant"));
    let admin_view = catalog.discover_functions(&FunctionQuery {
        actor: Some(admin),
        include_internal: true,
        ..FunctionQuery::default()
    });
    assert_eq!(
        admin_view.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::internal", "alpha::session", "alpha::workspace"]
    );
}

#[test]
fn worker_unregister_cleans_owned_volatile_registrations_only() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog.register_worker(worker("w2", "beta"), true).unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    catalog
        .register_function(read_function("beta::read", "w2"), Some(handler()), true)
        .unwrap();

    catalog.unregister_worker(&wid("w1"), "owner").unwrap();
    assert!(catalog.function(&fid("alpha::read")).is_none());
    assert!(catalog.function(&fid("beta::read")).is_some());
}

#[test]
fn inspect_and_promotion_are_visibility_and_owner_checked() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    catalog
        .register_function(function, Some(handler()), true)
        .unwrap();

    let matching_session = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-a");
    let other_session = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-b");
    assert!(
        catalog
            .inspect_function(&fid("alpha::session"), Some(&matching_session))
            .is_ok()
    );
    assert!(matches!(
        catalog.inspect_function(&fid("alpha::session"), Some(&other_session)),
        Err(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    assert!(matches!(
        catalog.promote_function_visibility(
            &fid("alpha::session"),
            &wid("other"),
            VisibilityScope::Workspace,
            Some("workspace-a".to_owned())
        ),
        Err(EngineError::OwnerMismatch { .. })
    ));
    assert!(matches!(
        catalog.promote_function_visibility(
            &fid("alpha::session"),
            &wid("w1"),
            VisibilityScope::Session,
            None
        ),
        Err(EngineError::InvalidVisibilityPromotion { .. })
    ));
    let revision = catalog
        .promote_function_visibility(
            &fid("alpha::session"),
            &wid("w1"),
            VisibilityScope::Workspace,
            Some("workspace-a".to_owned()),
        )
        .unwrap();
    assert_eq!(revision, FunctionRevision(2));
    let promoted = catalog.function(&fid("alpha::session")).unwrap();
    assert_eq!(promoted.visibility, VisibilityScope::Workspace);
    assert_eq!(
        promoted.provenance.workspace_id.as_deref(),
        Some("workspace-a")
    );
    assert!(promoted.provenance.session_id.is_none());
    assert_eq!(
        catalog.changes().last().unwrap().kind,
        CatalogChangeKind::VisibilityChanged
    );

    let workspace_actor = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_workspace_id("workspace-a");
    assert!(
        catalog
            .inspect_function(&fid("alpha::session"), Some(&workspace_actor))
            .is_ok()
    );
    assert!(catalog.inspect_worker(&wid("w1")).is_ok());
}

#[test]
fn unregister_function_removes_targeting_triggers_and_revisions_remain_monotonic() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    catalog
        .register_trigger_type(
            TriggerTypeDefinition::new(TriggerTypeId::new("cron").unwrap(), wid("w1"), "cron"),
            true,
        )
        .unwrap();
    catalog
        .register_trigger(
            TriggerDefinition::new(
                TriggerId::new("t1").unwrap(),
                wid("w1"),
                TriggerTypeId::new("cron").unwrap(),
                fid("alpha::read"),
                grant("grant"),
            ),
            true,
        )
        .unwrap();
    let before = catalog.revision();

    catalog
        .unregister_function(&fid("alpha::read"), &wid("w1"))
        .unwrap();

    assert!(catalog.function(&fid("alpha::read")).is_none());
    assert!(
        catalog
            .inspect_trigger(&TriggerId::new("t1").unwrap())
            .is_err()
    );
    assert_eq!(catalog.revision().0, before.0 + 2);
    assert_eq!(
        catalog.changes()[catalog.changes().len() - 2].kind,
        CatalogChangeKind::TriggerUnregistered
    );
    assert_eq!(
        catalog.changes().last().unwrap().kind,
        CatalogChangeKind::FunctionUnregistered
    );
}

#[test]
fn engine_host_bootstrap_repairs_stale_system_meta_contracts() {
    let mut catalog = LiveCatalog::new();
    let engine_worker = WorkerDefinition::new(
        wid("engine"),
        WorkerKind::System,
        actor("system"),
        grant("engine-system"),
    )
    .with_namespace_claim("engine");
    catalog.register_worker(engine_worker, false).unwrap();
    catalog
        .register_function(
            FunctionDefinition::new(
                fid("engine::discover"),
                wid("engine"),
                "stale discover",
                VisibilityScope::Internal,
                EffectClass::IdempotentWrite,
            )
            .with_idempotency(IdempotencyContract::caller_session()),
            None,
            false,
        )
        .unwrap();

    let host = EngineHost::from_catalog(catalog).unwrap();
    let discover = host.catalog().function(&fid("engine::discover")).unwrap();
    assert_eq!(discover.description, "discover live engine capabilities");
    assert_eq!(discover.visibility, VisibilityScope::System);
    assert_eq!(discover.effect_class, EffectClass::PureRead);
    assert_eq!(discover.idempotency, None);
    assert_eq!(discover.revision, FunctionRevision(2));
}

#[test]
fn engine_namespace_is_reserved_for_the_system_engine_worker() {
    let mut catalog = LiveCatalog::new();
    let denied = catalog.register_worker(worker("w1", "engine"), true);
    assert!(matches!(
        denied,
        Err(EngineError::PolicyViolation(message))
            if message.contains("reserved engine namespace")
    ));

    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let denied_function = host.catalog_mut().register_function(
        read_function("engine::spoof", "w1"),
        Some(handler()),
        true,
    );
    assert!(matches!(
        denied_function,
        Err(EngineError::PolicyViolation(message))
            if message.contains("reserved engine namespace")
    ));
}

#[test]
fn catalog_change_ledger_failure_does_not_mutate_registered_catalog_entries() {
    let mut catalog = LiveCatalog::with_ledger_store(Box::new(CatalogChangeFailingLedger));

    let result = catalog.register_worker(worker("w1", "alpha"), true);
    assert!(matches!(
        result,
        Err(EngineError::LedgerFailure {
            operation: "append_catalog_change",
            ..
        })
    ));
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.worker(&wid("w1")).is_none());
    assert!(catalog.changes().is_empty());
}
