use super::*;

#[test]
fn empty_catalog_starts_at_revision_zero() {
    let catalog = LiveCatalog::new();
    assert_eq!(catalog.revision(), CatalogRevision(0));
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
        FunctionVisibility::Public,
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
        FunctionVisibility::Internal,
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
fn catalog_revision_increments_for_registration() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    assert_eq!(catalog.revision(), CatalogRevision(1));
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
        FunctionVisibility::Internal,
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
fn system_discovery_includes_internal_functions() {
    let mut catalog = LiveCatalog::new();
    let public_function = FunctionDefinition::new(
        fid("alpha::public"),
        wid("w1"),
        "public function",
        FunctionVisibility::Public,
        EffectClass::PureRead,
    );
    let internal_function = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal function",
        FunctionVisibility::Internal,
        EffectClass::PureRead,
    );
    catalog
        .register_function(public_function, handler())
        .unwrap();
    catalog
        .register_function(internal_function, handler())
        .unwrap();

    let system = ActorContext::new(actor("system"), ActorKind::System);
    let visible = catalog.visible_functions(&system);
    assert_eq!(
        visible.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::internal", "alpha::public"]
    );
}

#[test]
fn inspect_is_visibility_checked() {
    let mut catalog = LiveCatalog::new();
    let function = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal function",
        FunctionVisibility::Internal,
        EffectClass::PureRead,
    );
    catalog.register_function(function, handler()).unwrap();

    let system = ActorContext::new(actor("system"), ActorKind::System);
    let agent = ActorContext::new(actor("agent"), ActorKind::Agent);
    assert!(
        catalog
            .inspect_function(&fid("alpha::internal"), &system)
            .is_ok()
    );
    assert!(matches!(
        catalog.inspect_function(&fid("alpha::internal"), &agent),
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
fn catalog_revision_failure_does_not_mutate_registered_catalog_entries() {
    let mut catalog = LiveCatalog::with_ledger_store(Box::new(CatalogRevisionFailingLedger));

    let result = catalog.register_function(read_function("alpha::read", "w1"), handler());
    assert!(matches!(
        result,
        Err(EngineError::LedgerFailure {
            operation: "advance_catalog_revision",
            ..
        })
    ));
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.function(&fid("alpha::read")).is_none());
}
