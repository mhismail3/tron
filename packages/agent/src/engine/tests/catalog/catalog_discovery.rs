use super::*;

#[test]
fn empty_catalog_starts_at_revision_zero() {
    let catalog = LiveCatalog::new();
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.ledger_catalog_changes().unwrap().is_empty());
}

#[test]
fn function_registration_is_self_sufficient() {
    let mut catalog = LiveCatalog::new();
    let revision = catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    assert_eq!(revision, FunctionRevision(1));
}

#[test]
fn function_registration_allows_same_owner_update_and_rejects_cross_owner() {
    let mut catalog = LiveCatalog::new();
    let rev = catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    assert_eq!(rev.0, 1);
    let rev = catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    assert_eq!(rev.0, 2);

    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w2"), handler()),
        Err(EngineError::OwnerMismatch {
            kind: "function",
            ..
        })
    ));
}

#[test]
fn mutating_function_requires_idempotency() {
    let mut catalog = LiveCatalog::new();
    let missing_contract = FunctionDefinition::new(
        fid("alpha::write"),
        wid("w1"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    );
    assert!(matches!(
        catalog.register_function(missing_contract, handler()),
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
        catalog.register_function(internal_missing_contract, handler()),
        Err(EngineError::PolicyViolation(message)) if message.contains("requires idempotency")
    ));

    catalog
        .register_function(write_function("alpha::write", "w1"), handler())
        .unwrap();
}

#[test]
fn catalog_changes_increment_by_one_and_record_subjects() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    let changes = catalog.ledger_catalog_changes().unwrap();
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].before.0, 0);
    assert_eq!(changes[0].after.0, 1);
    assert_eq!(changes[0].kind, CatalogChangeKind::FunctionRegistered);
    assert_eq!(changes[0].subject_id, "alpha::read");
    assert_eq!(changes[0].subject_kind, CatalogSubjectKind::Function);
    assert_eq!(changes[0].class, CatalogChangeClass::Availability);
    assert_eq!(changes[0].visibility, VisibilityScope::Agent);
}

#[test]
fn visible_functions_are_sorted_and_hide_internal_functions_from_agents() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::zeta", "w1"), handler())
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::beta", "w1")
                .with_risk(RiskLevel::Medium)
                .with_health(FunctionHealth::Degraded),
            handler(),
        )
        .unwrap();
    let internal = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal",
        VisibilityScope::Internal,
        EffectClass::PureRead,
    );
    catalog.register_function(internal, handler()).unwrap();

    let agent = ActorContext::new(actor("agent"), ActorKind::Agent);
    let all = catalog.visible_functions(&agent);
    assert_eq!(
        all.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::beta", "alpha::zeta"]
    );
}

#[test]
fn discovery_enforces_scoped_visibility_and_internal_requires_admin() {
    let mut catalog = LiveCatalog::new();
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
        .register_function(session_function, handler())
        .unwrap();
    catalog
        .register_function(workspace_function, handler())
        .unwrap();
    catalog
        .register_function(internal_function, handler())
        .unwrap();

    let scoped_actor = ActorContext::new(actor("agent"), ActorKind::Agent)
        .with_session_id("session-a")
        .with_workspace_id("workspace-a");
    let scoped = catalog.visible_functions(&scoped_actor);
    assert_eq!(
        scoped.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::session", "alpha::workspace"]
    );

    let other_session = ActorContext::new(actor("agent"), ActorKind::Agent)
        .with_session_id("session-b")
        .with_workspace_id("workspace-a");
    let workspace_only = catalog.visible_functions(&other_session);
    assert_eq!(
        workspace_only
            .iter()
            .map(|f| f.id.as_str())
            .collect::<Vec<_>>(),
        vec!["alpha::workspace"]
    );

    let admin = ActorContext::new(actor("admin"), ActorKind::Admin);
    let admin_view = catalog.visible_functions(&admin);
    assert_eq!(
        admin_view.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::internal", "alpha::session", "alpha::workspace"]
    );
}

#[test]
fn inspect_is_visibility_checked() {
    let mut catalog = LiveCatalog::new();
    let function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    catalog.register_function(function, handler()).unwrap();

    let matching_session =
        ActorContext::new(actor("agent"), ActorKind::Agent).with_session_id("session-a");
    let other_session =
        ActorContext::new(actor("agent"), ActorKind::Agent).with_session_id("session-b");
    assert!(
        catalog
            .inspect_function(&fid("alpha::session"), &matching_session)
            .is_ok()
    );
    assert!(matches!(
        catalog.inspect_function(&fid("alpha::session"), &other_session),
        Err(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));
}

#[test]
fn unregister_function_removes_the_function_and_advances_revision() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    let before = catalog.revision();

    catalog
        .unregister_function(&fid("alpha::read"), &wid("w1"))
        .unwrap();

    assert!(catalog.function(&fid("alpha::read")).is_none());
    assert_eq!(catalog.revision().0, before.0 + 1);
    let changes = catalog.ledger_catalog_changes().unwrap();
    assert_eq!(
        changes.last().unwrap().kind,
        CatalogChangeKind::FunctionUnregistered
    );
}

#[test]
fn engine_namespace_is_reserved_for_the_engine_owner() {
    let mut host = EngineHost::new().unwrap();
    let denied_function = host
        .catalog_mut()
        .register_function(read_function("engine::spoof", "w1"), handler());
    assert!(matches!(
        denied_function,
        Err(EngineError::PolicyViolation(message))
            if message.contains("reserved engine namespace")
    ));
}

#[test]
fn catalog_change_ledger_failure_does_not_mutate_registered_catalog_entries() {
    let mut catalog = LiveCatalog::with_ledger_store(Box::new(CatalogChangeFailingLedger));

    let result = catalog.register_function(read_function("alpha::read", "w1"), handler());
    assert!(matches!(
        result,
        Err(EngineError::LedgerFailure {
            operation: "append_catalog_change",
            ..
        })
    ));
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.function(&fid("alpha::read")).is_none());
    assert!(catalog.ledger_catalog_changes().unwrap().is_empty());
}
