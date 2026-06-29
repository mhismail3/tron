use super::inspection_test_support::*;
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
    assert_eq!(
        inspected["resource"]["provenance"]["authorityGrantId"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["provenance"]["authority_grant_id"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["provenance"]["nested"]["grantId"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["provenance"]["nested"]["grant_id"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["provenance"]["nested"]["grantIdentifier"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["state"]["failure"]["details"]["grantId"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["traceRefs"]["items"][0]["grant_id"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["replayRefs"]["authority_grant_id"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["provenance"]["nested"]["lifecycleStatus"]["text"],
        json!("grant request pending")
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
        "grant-prod-lifecycle-123",
        "grant-prod-lifecycle-snake-123",
        "grant-prod-lifecycle-camel-123",
        "grant-prod-lifecycle-nested-snake-123",
        "worker-package-read-sensitive",
        "grant-prod-failure-123",
        "grant-prod-failure-camel-123",
        "grant-prod-trace-snake-123",
        "grant-prod-replay-snake-123",
        "failed with grant-prod-failure-123 at /private/worker/root",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "projection leaked forbidden material {forbidden}: {serialized}"
        );
    }
    assert!(serialized.contains("grant request pending"), "{serialized}");
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

    let selector_wildcard_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "selector-wildcard",
        &["worker.lifecycle.read", "resource.read"],
        &[PACKAGE_KIND],
        &["*", "kind:worker_package"],
        "none",
    )
    .await;
    let selector_wildcard_invocation = worker_package_read_invocation(
        "selector-wildcard",
        payload.clone(),
        selector_wildcard_grant,
        "expected-worker-session",
        "workspace-worker-auth",
    );
    let selector_wildcard = inspect_worker_package_value(
        &deps.engine_host,
        &selector_wildcard_invocation,
        &selector_wildcard_invocation.payload,
    )
    .await
    .expect_err("selector wildcard grant denied")
    .to_string();
    assert!(
        selector_wildcard.contains("wildcard"),
        "{selector_wildcard}"
    );

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
async fn worker_package_list_excludes_and_inspect_denies_archived_resources() {
    let (_temp, deps, _package) = test_deps().await;
    let session_id = "worker-archived-session";
    let workspace_id = "workspace-worker-archived";
    let read_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "archived",
        &["worker.lifecycle.read", "resource.read"],
        &[PROPOSAL_KIND, CONFORMANCE_KIND],
        &[
            "kind:worker_package_proposal",
            "kind:worker_package_conformance_report",
        ],
        "none",
    )
    .await;

    create_worker_lifecycle_resource(
        &deps.engine_host,
        PROPOSAL_KIND,
        "worker_package_proposal:local.echo:1.0.0:active",
        EngineResourceScope::Session(session_id.to_owned()),
        proposal_payload("active proposal", "proposed"),
        "proposed",
    )
    .await;
    create_worker_lifecycle_resource(
        &deps.engine_host,
        PROPOSAL_KIND,
        "worker_package_proposal:local.echo:1.0.0:archived",
        EngineResourceScope::Session(session_id.to_owned()),
        proposal_payload("archived proposal", "archived"),
        "archived",
    )
    .await;
    create_worker_lifecycle_resource(
        &deps.engine_host,
        CONFORMANCE_KIND,
        "worker_package_conformance_report:local.echo:1.0.0:active",
        EngineResourceScope::Session(session_id.to_owned()),
        conformance_payload("passed"),
        "passed",
    )
    .await;
    create_worker_lifecycle_resource(
        &deps.engine_host,
        CONFORMANCE_KIND,
        "worker_package_conformance_report:local.echo:1.0.0:archived",
        EngineResourceScope::Session(session_id.to_owned()),
        conformance_payload("archived"),
        "archived",
    )
    .await;

    let proposal_list_invocation = worker_package_read_invocation(
        "archived-proposal-list",
        json!({
            "operation": "worker_package_list",
            "workerPackageKind": "worker_package_proposal"
        }),
        read_grant.clone(),
        session_id,
        workspace_id,
    );
    let listed_proposals = list_worker_packages_value(
        &deps.engine_host,
        &proposal_list_invocation,
        &proposal_list_invocation.payload,
    )
    .await
    .expect("list proposals");
    let proposal_records = listed_proposals["records"].as_array().unwrap();
    assert_eq!(proposal_records.len(), 1);
    assert_eq!(
        proposal_records[0]["resourceId"],
        "worker_package_proposal:local.echo:1.0.0:active"
    );

    let conformance_list_invocation = worker_package_read_invocation(
        "archived-conformance-list",
        json!({
            "operation": "worker_package_list",
            "workerPackageKind": "worker_package_conformance_report"
        }),
        read_grant.clone(),
        session_id,
        workspace_id,
    );
    let listed_conformance = list_worker_packages_value(
        &deps.engine_host,
        &conformance_list_invocation,
        &conformance_list_invocation.payload,
    )
    .await
    .expect("list conformance reports");
    let conformance_records = listed_conformance["records"].as_array().unwrap();
    assert_eq!(conformance_records.len(), 1);
    assert_eq!(
        conformance_records[0]["resourceId"],
        "worker_package_conformance_report:local.echo:1.0.0:active"
    );

    let archived_lifecycle_invocation = worker_package_read_invocation(
        "archived-lifecycle-list",
        json!({
            "operation": "worker_package_list",
            "workerPackageKind": "worker_package_proposal",
            "lifecycle": "archived"
        }),
        read_grant.clone(),
        session_id,
        workspace_id,
    );
    let archived_lifecycle = list_worker_packages_value(
        &deps.engine_host,
        &archived_lifecycle_invocation,
        &archived_lifecycle_invocation.payload,
    )
    .await
    .expect_err("archived lifecycle filter denied")
    .to_string();
    assert!(
        archived_lifecycle.contains("archived"),
        "{archived_lifecycle}"
    );

    for resource_id in [
        "worker_package_proposal:local.echo:1.0.0:archived",
        "worker_package_conformance_report:local.echo:1.0.0:archived",
    ] {
        let invocation = worker_package_read_invocation(
            &format!("archived-inspect-{resource_id}").replace(':', "-"),
            json!({
                "operation": "worker_package_inspect",
                "workerPackageResourceId": resource_id
            }),
            read_grant.clone(),
            session_id,
            workspace_id,
        );
        let denied =
            inspect_worker_package_value(&deps.engine_host, &invocation, &invocation.payload)
                .await
                .expect_err("archived inspect denied")
                .to_string();
        assert!(denied.contains("archived"), "{denied}");
    }
}

#[tokio::test]
async fn worker_package_inspect_redacts_installation_authority_grant_id() {
    let (_temp, deps, _package) = test_deps().await;
    let session_id = "worker-installation-redaction-session";
    let workspace_id = "workspace-worker-installation-redaction";
    let read_grant = derived_worker_package_read_grant(
        &deps.engine_host,
        "installation-redaction",
        &["worker.lifecycle.read", "resource.read"],
        &[INSTALLATION_KIND],
        &["kind:worker_package_installation"],
        "none",
    )
    .await;
    create_worker_lifecycle_resource(
        &deps.engine_host,
        INSTALLATION_KIND,
        "worker_package_installation:local.echo:1.0.0",
        EngineResourceScope::Session(session_id.to_owned()),
        json!({
            "packageId": "local.echo",
            "packageVersion": "1.0.0",
            "packageDigest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "workerId": "local_echo",
            "packageResourceId": "worker_package:local.echo:1.0.0",
            "status": "installed",
            "authorityGrantId": "grant-secret-installation-lifecycle",
            "rollbackRef": {"resourceId": "worker_package:local.echo:0.9.0"}
        }),
        "installed",
    )
    .await;

    let invocation = worker_package_read_invocation(
        "installation-redaction",
        json!({
            "operation": "worker_package_inspect",
            "workerPackageResourceId": "worker_package_installation:local.echo:1.0.0"
        }),
        read_grant,
        session_id,
        workspace_id,
    );
    let inspected =
        inspect_worker_package_value(&deps.engine_host, &invocation, &invocation.payload)
            .await
            .expect("inspect installation");
    assert_eq!(
        inspected["resource"]["installation"]["lifecycleGrantRedacted"],
        json!(true)
    );
    let serialized = serde_json::to_string(&inspected).expect("serialize projection");
    assert!(
        !serialized.contains("grant-secret-installation-lifecycle"),
        "{serialized}"
    );
    assert!(!serialized.contains("authorityGrantId"), "{serialized}");
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
