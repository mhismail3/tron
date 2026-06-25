use super::*;

#[tokio::test]
async fn worker_package_list_and_inspect_return_bounded_redacted_lifecycle_evidence() {
    let (temp, deps, package) = test_deps().await;
    let session_id = "worker-inspect-session";
    let workspace_id = "workspace-worker-inspect";
    let read_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "redacted",
        &["worker.lifecycle.read", "resource.read"],
        &[PACKAGE_KIND],
        &["kind:worker_package"],
        "none",
    )
    .await;
    let resource_id = "worker_package:local.echo:1.0.0";
    create_worker_package_resource(
        &deps.engine_host,
        resource_id,
        EngineResourceScope::Session(session_id.to_owned()),
        package_payload_for_inspection(&package),
        "installed",
    )
    .await;

    let list_invocation = worker_package_read_invocation(
        "list-redacted",
        json!({"operation": "worker_package_list", "lifecycle": "installed", "limit": 10}),
        read_grant.clone(),
        session_id,
        workspace_id,
    );
    let listed = list_worker_packages_value(
        &deps.engine_host,
        &list_invocation,
        &list_invocation.payload,
    )
    .await
    .expect("list worker packages");
    assert_eq!(listed["records"].as_array().unwrap().len(), 1);
    assert_eq!(listed["records"][0]["resourceId"], resource_id);

    let inspect_invocation = worker_package_read_invocation(
        "inspect-redacted",
        json!({
            "operation": "worker_package_inspect",
            "workerPackageResourceId": resource_id,
            "maxLifecycleItems": 1
        }),
        read_grant,
        session_id,
        workspace_id,
    );
    let inspected = inspect_worker_package_value(
        &deps.engine_host,
        &inspect_invocation,
        &inspect_invocation.payload,
    )
    .await
    .expect("inspect worker package");
    assert_eq!(
        inspected["resource"]["expectedFunctions"]["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        inspected["resource"]["expectedFunctions"]["truncated"],
        json!(true)
    );
    let serialized = serde_json::to_string(&inspected).expect("serialize projection");
    for forbidden in [
        "workerToken",
        "TRON_WORKER_TOKEN_JSON",
        "secret-env-value",
        package.display().to_string().as_str(),
        "/private/worker/root",
        "token-grant-secret",
        "127.0.0.1:17345",
        "failed with token-grant-secret at /private/worker/root",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "projection leaked forbidden material {forbidden}: {serialized}"
        );
    }
    drop(temp);
}

#[tokio::test]
async fn worker_package_list_honors_kind_lifecycle_and_scope_filters() {
    let (_temp, deps, package) = test_deps().await;
    let session_id = "worker-list-session";
    let workspace_id = "workspace-worker-list";
    let read_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "filters",
        &["worker.lifecycle.read", "resource.read"],
        &[PACKAGE_KIND],
        &["kind:worker_package"],
        "none",
    )
    .await;
    create_worker_package_resource(
        &deps.engine_host,
        "worker_package:local.echo:1.0.0",
        EngineResourceScope::Session(session_id.to_owned()),
        package_payload_for_inspection(&package),
        "installed",
    )
    .await;
    create_worker_package_resource(
        &deps.engine_host,
        "worker_package:local.echo:2.0.0",
        EngineResourceScope::Session(session_id.to_owned()),
        json!({
            "schemaVersion": PACKAGE_SCHEMA_VERSION,
            "packageId": "local.echo",
            "packageVersion": "2.0.0",
            "packageDigest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "provenance": {},
            "source": {"kind": SOURCE_KIND_LOCAL_FILESYSTEM},
            "workerId": "local_echo",
            "namespaceClaims": [],
            "launchCommand": [],
            "workingDirectory": ".",
            "envAllowlist": [],
            "expectedFunctions": [],
            "expectedTriggers": [],
            "requestedGrants": {},
            "conformancePolicy": {},
            "rollbackPolicy": {},
            "status": "retired"
        }),
        "retired",
    )
    .await;
    create_worker_package_resource(
        &deps.engine_host,
        "worker_package:other.session:1.0.0",
        EngineResourceScope::Session("other-worker-list-session".to_owned()),
        package_payload_for_inspection(&package),
        "installed",
    )
    .await;

    let invocation = worker_package_read_invocation(
        "list-filtered",
        json!({
            "operation": "worker_package_list",
            "workerPackageKind": "worker_package",
            "lifecycle": "installed"
        }),
        read_grant,
        session_id,
        workspace_id,
    );
    let listed = list_worker_packages_value(&deps.engine_host, &invocation, &invocation.payload)
        .await
        .expect("filtered list");
    let records = listed["records"].as_array().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["resourceId"], "worker_package:local.echo:1.0.0");
}

#[tokio::test]
async fn worker_package_inspect_denies_wrong_session_missing_grants_and_wildcards() {
    let (_temp, deps, package) = test_deps().await;
    create_worker_package_resource(
        &deps.engine_host,
        "worker_package:local.echo:1.0.0",
        EngineResourceScope::Session("expected-worker-session".to_owned()),
        package_payload_for_inspection(&package),
        "installed",
    )
    .await;
    let payload = json!({
        "operation": "worker_package_inspect",
        "workerPackageResourceId": "worker_package:local.echo:1.0.0"
    });
    let missing_scope_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "missing-scope",
        &["resource.read"],
        &[PACKAGE_KIND],
        &["kind:worker_package"],
        "none",
    )
    .await;
    let missing_scope_invocation = worker_package_read_invocation(
        "missing-scope",
        payload.clone(),
        missing_scope_grant,
        "expected-worker-session",
        "workspace-worker-auth",
    );
    let missing_scope = inspect_worker_package_value(
        &deps.engine_host,
        &missing_scope_invocation,
        &missing_scope_invocation.payload,
    )
    .await
    .expect_err("missing read grant denied")
    .to_string();
    assert!(
        missing_scope.contains("worker.lifecycle.read"),
        "{missing_scope}"
    );

    let wildcard_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "wildcard",
        &["worker.lifecycle.read", "resource.read"],
        &["*"],
        &["kind:worker_package"],
        "none",
    )
    .await;
    let wildcard_invocation = worker_package_read_invocation(
        "wildcard",
        payload.clone(),
        wildcard_grant,
        "expected-worker-session",
        "workspace-worker-auth",
    );
    let wildcard = inspect_worker_package_value(
        &deps.engine_host,
        &wildcard_invocation,
        &wildcard_invocation.payload,
    )
    .await
    .expect_err("wildcard grant denied")
    .to_string();
    assert!(wildcard.contains("wildcard"), "{wildcard}");

    let read_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "wrong-session",
        &["worker.lifecycle.read", "resource.read"],
        &[PACKAGE_KIND],
        &["kind:worker_package"],
        "none",
    )
    .await;
    let wrong_session_invocation = worker_package_read_invocation(
        "wrong-session",
        payload,
        read_grant,
        "other-worker-session",
        "workspace-worker-auth",
    );
    let wrong_session = inspect_worker_package_value(
        &deps.engine_host,
        &wrong_session_invocation,
        &wrong_session_invocation.payload,
    )
    .await
    .expect_err("wrong session denied")
    .to_string();
    assert!(
        wrong_session.contains("outside the current session/workspace"),
        "{wrong_session}"
    );
}

#[tokio::test]
async fn worker_package_inspect_revalidates_stored_kind_and_schema() {
    let (_temp, deps, package) = test_deps().await;
    let read_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "kind-schema",
        &["worker.lifecycle.read", "resource.read"],
        &[PACKAGE_KIND],
        &["kind:worker_package"],
        "none",
    )
    .await;
    deps.engine_host
        .create_resource(CreateResource {
            resource_id: Some("worker_package:wrong-kind:1.0.0".to_owned()),
            kind: super::INSTALLATION_KIND.to_owned(),
            schema_id: None,
            scope: EngineResourceScope::Session("kind-schema-session".to_owned()),
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
            owner_actor_id: ActorId::new("agent:kind-schema-session").unwrap(),
            lifecycle: Some("installed".to_owned()),
            policy: json!({"owner": WORKER}),
            initial_payload: Some(json!({
                "packageId": "wrong-kind",
                "packageVersion": "1.0.0",
                "packageDigest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                "workerId": "local_echo",
                "status": "installed"
            })),
            locations: Vec::new(),
            trace_id: TraceId::new("trace-wrong-kind-resource").unwrap(),
            invocation_id: None,
        })
        .await
        .expect("wrong kind resource");
    let wrong_kind_invocation = worker_package_read_invocation(
        "wrong-kind",
        json!({
            "operation": "worker_package_inspect",
            "workerPackageResourceId": "worker_package:wrong-kind:1.0.0"
        }),
        read_grant.clone(),
        "kind-schema-session",
        "workspace-kind-schema",
    );
    let wrong_kind = inspect_worker_package_value(
        &deps.engine_host,
        &wrong_kind_invocation,
        &wrong_kind_invocation.payload,
    )
    .await
    .expect_err("stored kind must be revalidated")
    .to_string();
    assert!(
        wrong_kind.contains("expected worker_package"),
        "{wrong_kind}"
    );

    deps.engine_host
        .register_resource_type(RegisterResourceType {
            kind: PACKAGE_KIND.to_owned(),
            schema_id: "tron.resource.worker_package.test_mismatch.v1".to_owned(),
            schema: json!({
                "type": "object",
                "required": ["packageId", "packageVersion", "status"],
                "additionalProperties": true
            }),
            lifecycle_states: vec!["installed".to_owned()],
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: Vec::new(),
            default_retention: json!({"class": "test"}),
            redaction_rules: json!({}),
            materialization_rules: json!({}),
            required_capabilities: json!({}),
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
        })
        .await
        .expect("override test type");
    create_worker_package_resource(
        &deps.engine_host,
        "worker_package:schema-mismatch:1.0.0",
        EngineResourceScope::Session("kind-schema-session".to_owned()),
        package_payload_for_inspection(&package),
        "installed",
    )
    .await;
    let schema_mismatch_invocation = worker_package_read_invocation(
        "schema-mismatch",
        json!({
            "operation": "worker_package_inspect",
            "workerPackageResourceId": "worker_package:schema-mismatch:1.0.0"
        }),
        read_grant,
        "kind-schema-session",
        "workspace-kind-schema",
    );
    let schema_mismatch = inspect_worker_package_value(
        &deps.engine_host,
        &schema_mismatch_invocation,
        &schema_mismatch_invocation.payload,
    )
    .await
    .expect_err("stored schema must be revalidated")
    .to_string();
    assert!(
        schema_mismatch.contains("tron.resource.worker_package.v1"),
        "{schema_mismatch}"
    );
}

async fn derived_worker_package_read_grant(
    handle: &crate::engine::EngineHostHandle,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    let grant = handle
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("worker-package-read-{suffix}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
            subject_actor_id: None,
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
            allowed_resource_kinds: resource_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect(),
            resource_selectors: selectors
                .iter()
                .map(|selector| (*selector).to_owned())
                .collect(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: network_policy.to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "worker_package_read_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "worker_lifecycle_inspection_test"}),
            trace_id: TraceId::new(format!("trace-worker-package-read-{suffix}")).unwrap(),
        })
        .await
        .expect("derive worker package read grant");
    grant.grant_id
}

fn worker_package_read_invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    session_id: &str,
    workspace_id: &str,
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-worker-package-{key}")).unwrap(),
    )
    .with_session_id(session_id.to_owned())
    .with_workspace_id(workspace_id.to_owned());
    for scope in ["worker.lifecycle.read", "resource.read"] {
        context = context.with_scope(scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-worker-package-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

async fn create_worker_package_resource(
    handle: &crate::engine::EngineHostHandle,
    resource_id: &str,
    scope: EngineResourceScope,
    payload: Value,
    lifecycle: &str,
) {
    handle
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: PACKAGE_KIND.to_owned(),
            schema_id: None,
            scope,
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
            owner_actor_id: ActorId::new("agent:worker-package-test").unwrap(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: json!({"owner": WORKER}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: TraceId::new(format!("trace-{resource_id}").replace(':', "-")).unwrap(),
            invocation_id: None,
        })
        .await
        .expect("create worker package resource");
}

fn package_payload_for_inspection(package: &Path) -> Value {
    json!({
        "schemaVersion": PACKAGE_SCHEMA_VERSION,
        "packageId": "local.echo",
        "packageVersion": "1.0.0",
        "packageDigest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "provenance": {
            "source": "inspection-test",
            "sourcePath": package.display().to_string(),
            "nested": {"credential": "token-grant-secret"}
        },
        "source": {
            "kind": SOURCE_KIND_LOCAL_FILESYSTEM,
            "path": package.display().to_string(),
            "privatePath": "/private/worker/root"
        },
        "workerId": "local_echo",
        "namespaceClaims": ["local_echo", "local_echo.extra"],
        "launchCommand": [package.join("worker.sh").display().to_string(), "--serve"],
        "workingDirectory": package.display().to_string(),
        "envAllowlist": ["TRON_WORKER_TOKEN_JSON", "SECRET_ENV"],
        "expectedFunctions": ["local_echo::run", "local_echo::extra"],
        "expectedTriggers": ["local_echo.trigger"],
        "requestedGrants": {
            "authorityScopes": ["local_echo.run"],
            "resourceKinds": ["artifact"],
            "fileRoots": [package.display().to_string()],
            "networkPolicy": "loopback",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 1}
        },
        "conformancePolicy": {"timeoutMs": 50},
        "rollbackPolicy": {"onFailure": "stop_worker"},
        "manifest": {"raw": "redacted by projection"},
        "sourceRoot": package.display().to_string(),
        "status": "installed",
        "failure": {
            "message": "failed with token-grant-secret at /private/worker/root",
            "details": {"env": {"SECRET_ENV": "secret-env-value"}}
        },
        "workerToken": {"secret": "token-grant-secret"},
        "env": {"SECRET_ENV": "secret-env-value"},
        "endpoint": "ws://127.0.0.1:17345/engine/workers",
        "tokenGrantId": "token-grant-secret"
    })
}
