use super::*;

pub(crate) async fn derived_worker_package_read_grant(
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

pub(crate) fn worker_package_read_invocation(
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

pub(crate) async fn create_worker_package_resource(
    handle: &crate::engine::EngineHostHandle,
    resource_id: &str,
    scope: EngineResourceScope,
    payload: Value,
    lifecycle: &str,
) {
    create_worker_lifecycle_resource(handle, PACKAGE_KIND, resource_id, scope, payload, lifecycle)
        .await;
}

pub(crate) async fn create_worker_lifecycle_resource(
    handle: &crate::engine::EngineHostHandle,
    kind: &str,
    resource_id: &str,
    scope: EngineResourceScope,
    payload: Value,
    lifecycle: &str,
) {
    handle
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: kind.to_owned(),
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
        .expect("create worker lifecycle resource");
}

pub(crate) fn proposal_payload(summary: &str, status: &str) -> Value {
    json!({
        "packageId": "local.echo",
        "packageVersion": "1.0.0",
        "summary": summary,
        "status": status,
        "manifest": {"schemaVersion": PACKAGE_SCHEMA_VERSION},
        "proposedBy": "agent:worker-archived-session"
    })
}

pub(crate) fn conformance_payload(status: &str) -> Value {
    json!({
        "packageId": "local.echo",
        "packageVersion": "1.0.0",
        "workerId": "local_echo",
        "status": status,
        "checks": [{"name": "manifest", "status": status}],
        "launchAttemptResourceId": "worker_launch_attempt:local.echo:1.0.0",
        "catalogRevision": 1
    })
}

pub(crate) fn package_payload_for_inspection(package: &Path) -> Value {
    json!({
        "schemaVersion": PACKAGE_SCHEMA_VERSION,
        "packageId": "local.echo",
        "packageVersion": "1.0.0",
        "packageDigest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "provenance": {
            "source": "inspection-test",
            "sourcePath": package.display().to_string(),
            "authorityGrantId": "grant-prod-lifecycle-123",
            "authority_grant_id": "grant-prod-lifecycle-snake-123",
            "nested": {
                "credential": "token-grant-secret",
                "grantId": "grant-prod-lifecycle-camel-123",
                "grant_id": "grant-prod-lifecycle-nested-snake-123",
                "grantIdentifier": "worker-package-read-sensitive",
                "lifecycleStatus": "grant request pending"
            }
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
            "message": "failed with grant-prod-failure-123 at /private/worker/root",
            "details": {
                "env": {"SECRET_ENV": "secret-env-value"},
                "grantId": "grant-prod-failure-camel-123"
            }
        },
        "traceRefs": [
            {
                "traceId": "trace-safe-worker-lifecycle",
                "grant_id": "grant-prod-trace-snake-123"
            }
        ],
        "replayRefs": {
            "authority_grant_id": "grant-prod-replay-snake-123",
            "note": "replay reference retained"
        },
        "workerToken": {"secret": "token-grant-secret"},
        "env": {"SECRET_ENV": "secret-env-value"},
        "endpoint": "ws://127.0.0.1:17345/engine/workers",
        "tokenGrantId": "token-grant-secret"
    })
}
