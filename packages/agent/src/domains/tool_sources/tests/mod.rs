use serde_json::{Value, json};

use super::service::{inspect_tool_source_value, list_tool_sources_value};
use super::{READ_SCOPE, SCHEMA_VERSION};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeriveGrant,
    EngineHostHandle, EngineResourceScope, FunctionId, Invocation, InvocationId, RiskLevel,
    TOOL_SOURCE_CONFORMANCE_REPORT_KIND, TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID,
    TOOL_SOURCE_PROPOSAL_KIND, TOOL_SOURCE_PROPOSAL_SCHEMA_ID, TraceId, WorkerId,
    builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

mod inspect;

#[tokio::test]
async fn read_operations_are_session_scoped_and_bounded() {
    let first = Fixture::new("scope-one").await;
    let second = first.clone_for_session("scope-two-session").await;
    let resource_id = first.seed_proposal("scope-proposal").await;

    let listed = first.list("scope-list").await;
    assert_eq!(listed["proposals"].as_array().unwrap().len(), 1);
    assert_eq!(listed["proposals"][0]["sourceKind"], json!("mcp_server"));
    assert_eq!(listed["proposals"][0]["declaredToolCount"], json!(1));
    assert_eq!(listed["proposals"][0]["declaredSchemaCount"], json!(1));

    let inspected = first.inspect("scope-inspect", &resource_id).await;
    assert_eq!(
        inspected["resource"]["payload"]["sandboxPolicy"]["networkPolicy"],
        "none"
    );
    assert_eq!(
        inspected["resource"]["payload"]["declaredSchemas"]["maxBytes"],
        json!(100)
    );
    assert_eq!(
        inspected["resource"]["payload"]["declaredSchemas"]["truncated"],
        json!(true)
    );
    assert_eq!(inspected["activation"]["catalogRegistration"], json!(false));

    let cross_scope = second.inspect_error("scope-denied", &resource_id).await;
    assert!(
        cross_scope.contains("outside the current scope"),
        "{cross_scope}"
    );
}

#[tokio::test]
async fn conformance_report_inspection_preserves_proposal_reference_without_activation() {
    let fixture = Fixture::new("report-inspect").await;
    let proposal_id = fixture.seed_proposal("report-proposal").await;
    let report_id = fixture.seed_report("report", &proposal_id, "passed").await;

    let inspected = fixture.inspect("report-inspect", &report_id).await;
    assert_eq!(
        inspected["resource"]["kind"],
        json!(TOOL_SOURCE_CONFORMANCE_REPORT_KIND)
    );
    assert_eq!(
        inspected["resource"]["payload"]["toolSourceProposalResourceId"],
        json!(proposal_id)
    );
    assert_eq!(inspected["resource"]["payload"]["status"], json!("passed"));
    assert_eq!(inspected["activation"]["performed"], json!(false));
    assert_eq!(inspected["activation"]["execution"], json!(false));
}

#[tokio::test]
async fn read_operations_require_explicit_scope_kind_and_selector() {
    let fixture = Fixture::new("read-authority").await;

    let missing_scope_grant = fixture
        .derive_grant(
            "missing-scope",
            &["resource.read"],
            &[TOOL_SOURCE_PROPOSAL_KIND],
            &["kind:tool_source_proposal"],
            "none",
        )
        .await;
    let missing_scope = invocation(
        "missing-scope",
        json!({"limit": 10}),
        missing_scope_grant,
        &["resource.read"],
        &fixture.session_id,
    );
    let error = list_tool_sources_value(&fixture.host, &missing_scope, &missing_scope.payload)
        .await
        .expect_err("tool_sources.read scope is required")
        .to_string();
    assert!(error.contains(READ_SCOPE), "{error}");

    let missing_selector_grant = fixture
        .derive_grant(
            "missing-selector",
            &[READ_SCOPE, "resource.read"],
            &[TOOL_SOURCE_PROPOSAL_KIND],
            &["resource:tool_source_proposal:other"],
            "none",
        )
        .await;
    let missing_selector = invocation(
        "missing-selector",
        json!({"limit": 10}),
        missing_selector_grant,
        &[READ_SCOPE, "resource.read"],
        &fixture.session_id,
    );
    let error =
        list_tool_sources_value(&fixture.host, &missing_selector, &missing_selector.payload)
            .await
            .expect_err("kind selector is required")
            .to_string();
    assert!(error.contains("kind:tool_source_proposal"), "{error}");
}

#[tokio::test]
async fn proposal_only_read_grant_cannot_inspect_conformance_reports() {
    let fixture = Fixture::new("report-read-kind-authority").await;
    let proposal_id = fixture.seed_proposal("read-kind-proposal").await;
    let report_id = fixture
        .seed_report("read-kind-report", &proposal_id, "passed")
        .await;
    let proposal_only_read_grant = fixture
        .derive_grant(
            "proposal-only-read",
            &[READ_SCOPE, "resource.read"],
            &[TOOL_SOURCE_PROPOSAL_KIND],
            &["kind:tool_source_proposal"],
            "none",
        )
        .await;
    let list_invocation = invocation(
        "proposal-only-list",
        json!({"limit": 10}),
        proposal_only_read_grant.clone(),
        &[READ_SCOPE, "resource.read"],
        &fixture.session_id,
    );
    let listed = list_tool_sources_value(&fixture.host, &list_invocation, &list_invocation.payload)
        .await
        .expect("proposal-only grant can list proposals");
    assert_eq!(listed["proposals"].as_array().unwrap().len(), 1);

    let proposal_inspect_invocation = invocation(
        "proposal-only-inspect-proposal",
        json!({"toolSourceResourceId": proposal_id}),
        proposal_only_read_grant.clone(),
        &[READ_SCOPE, "resource.read"],
        &fixture.session_id,
    );
    inspect_tool_source_value(
        &fixture.host,
        &proposal_inspect_invocation,
        &proposal_inspect_invocation.payload,
    )
    .await
    .expect("proposal-only grant can inspect proposals");

    let report_inspect_invocation = invocation(
        "proposal-only-inspect-report",
        json!({"toolSourceResourceId": report_id}),
        proposal_only_read_grant,
        &[READ_SCOPE, "resource.read"],
        &fixture.session_id,
    );
    let error = inspect_tool_source_value(
        &fixture.host,
        &report_inspect_invocation,
        &report_inspect_invocation.payload,
    )
    .await
    .expect_err("proposal-only grant cannot inspect reports")
    .to_string();
    assert!(
        error.contains(TOOL_SOURCE_CONFORMANCE_REPORT_KIND),
        "{error}"
    );
}

#[test]
fn resource_definitions_include_tool_source_required_fields() {
    let definitions = builtin_resource_type_definitions();
    let proposal = definitions
        .iter()
        .find(|definition| definition.kind == TOOL_SOURCE_PROPOSAL_KIND)
        .expect("proposal definition");
    assert_eq!(proposal.schema_id, TOOL_SOURCE_PROPOSAL_SCHEMA_ID);
    assert!(
        proposal
            .lifecycle_states
            .iter()
            .any(|state| state == "proposed")
    );
    assert!(
        proposal
            .required_capabilities
            .to_string()
            .contains("tool_sources.propose")
    );
    for field in [
        "sourceKind",
        "sourceIdentity",
        "provenance",
        "sandboxPolicy",
        "declaredTools",
        "declaredSchemas",
        "expectedLinkage",
    ] {
        assert!(
            proposal.schema["required"]
                .as_array()
                .unwrap()
                .contains(&json!(field)),
            "proposal schema must require {field}"
        );
    }

    let report = definitions
        .iter()
        .find(|definition| definition.kind == TOOL_SOURCE_CONFORMANCE_REPORT_KIND)
        .expect("report definition");
    assert_eq!(report.schema_id, TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID);
    assert!(
        report
            .lifecycle_states
            .iter()
            .any(|state| state == "passed")
    );
}

#[test]
fn static_non_goal_guards_keep_tool_sources_inert() {
    let service = include_str!("../service/mod.rs");
    for forbidden in [
        "std::process::Command",
        ".spawn(",
        "register_function",
        "register_worker",
        "mcp_start",
        "web_search",
        "browser_",
        "cookie",
        "login",
    ] {
        assert!(
            !service.contains(forbidden),
            "tool source service must not contain {forbidden}"
        );
    }
}

struct Fixture {
    host: EngineHostHandle,
    session_id: String,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let host = ctx.engine_host.clone();
        let session_id = format!("{label}-session");
        let read_grant_id = derive_grant(
            &host,
            &format!("{label}-read"),
            &[READ_SCOPE, "resource.read"],
            &[
                TOOL_SOURCE_PROPOSAL_KIND,
                TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
            ],
            &[
                "kind:tool_source_proposal",
                "kind:tool_source_conformance_report",
            ],
            "none",
        )
        .await;
        Self {
            host,
            session_id,
            read_grant_id,
        }
    }

    async fn clone_for_session(&self, session_id: &str) -> Self {
        let read_grant_id = self
            .derive_grant(
                &format!("{session_id}-read"),
                &[READ_SCOPE, "resource.read"],
                &[
                    TOOL_SOURCE_PROPOSAL_KIND,
                    TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
                ],
                &[
                    "kind:tool_source_proposal",
                    "kind:tool_source_conformance_report",
                ],
                "none",
            )
            .await;
        Self {
            host: self.host.clone(),
            session_id: session_id.to_owned(),
            read_grant_id,
        }
    }

    async fn derive_grant(
        &self,
        suffix: &str,
        scopes: &[&str],
        resource_kinds: &[&str],
        selectors: &[&str],
        network_policy: &str,
    ) -> AuthorityGrantId {
        derive_grant(
            &self.host,
            suffix,
            scopes,
            resource_kinds,
            selectors,
            network_policy,
        )
        .await
    }

    async fn seed_resource(
        &self,
        resource_id: &str,
        kind: &str,
        schema_id: &str,
        lifecycle: &str,
        payload: Value,
    ) -> String {
        self.host
            .create_resource(CreateResource {
                resource_id: Some(resource_id.to_owned()),
                kind: kind.to_owned(),
                schema_id: Some(schema_id.to_owned()),
                scope: EngineResourceScope::Session(self.session_id.clone()),
                owner_worker_id: WorkerId::new("resource").expect("worker id"),
                owner_actor_id: ActorId::new("system:tool-sources-test").expect("actor id"),
                lifecycle: Some(lifecycle.to_owned()),
                policy: json!({"test": "stored-resource-fixture"}),
                initial_payload: Some(payload),
                locations: Vec::new(),
                trace_id: TraceId::generate(),
                invocation_id: None,
            })
            .await
            .expect("seed stored tool source resource")
            .resource_id
    }

    async fn seed_proposal(&self, label: &str) -> String {
        let resource_id = format!("{TOOL_SOURCE_PROPOSAL_KIND}:{label}");
        self.seed_resource(
            &resource_id,
            TOOL_SOURCE_PROPOSAL_KIND,
            TOOL_SOURCE_PROPOSAL_SCHEMA_ID,
            "proposed",
            stored_proposal_payload(label),
        )
        .await
    }

    async fn seed_report(&self, label: &str, proposal_id: &str, status: &str) -> String {
        let resource_id = format!("{TOOL_SOURCE_CONFORMANCE_REPORT_KIND}:{label}");
        self.seed_resource(
            &resource_id,
            TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
            TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID,
            status,
            stored_report_payload(label, proposal_id, status),
        )
        .await
    }

    async fn list(&self, key: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"limit": 10}));
        list_tool_sources_value(&self.host, &invocation, &invocation.payload)
            .await
            .expect("list proposals")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(
            key,
            json!({"toolSourceResourceId": resource_id, "maxSchemaBytes": 100}),
        );
        inspect_tool_source_value(&self.host, &invocation, &invocation.payload)
            .await
            .expect("inspect tool source")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"toolSourceResourceId": resource_id}));
        inspect_tool_source_value(&self.host, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.read_grant_id.clone(),
            &[READ_SCOPE, "resource.read"],
            &self.session_id,
        )
    }
}

async fn derive_grant(
    engine_host: &EngineHostHandle,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    let grant = engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("tool-source-{suffix}")).unwrap()),
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
            budget: json!({"class": "tool_source_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "tool_sources_test"}),
            trace_id: TraceId::new(format!("trace-tool-source-{suffix}")).unwrap(),
        })
        .await
        .expect("derive grant");
    grant.grant_id
}

fn invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    scopes: &[&str],
    session_id: &str,
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-tool-sources")
    .with_idempotency_key(key.to_owned())
    .with_session_id(session_id.to_owned());
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        delivery_mode: crate::engine::DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn stored_proposal_payload(label: &str) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": "proposed",
        "sourceKind": "mcp_server",
        "sourceIdentity": {"id": format!("fixture.{label}"), "label": "Stored fixture"},
        "provenance": {"source": "test_resource_store"},
        "sandboxPolicy": {"networkPolicy": "none"},
        "declaredTools": [{"name": "lookup", "description": "Metadata lookup"}],
        "declaredSchemas": [{
            "id": "schema:lookup.input",
            "schema": {
                "type": "object",
                "description": "x".repeat(256),
                "properties": {"query": {"type": "string"}}
            }
        }],
        "expectedLinkage": {"workerPackageResourceId": "worker_package:fixture"},
        "summary": "Stored proposal fixture",
        "authority": {"activation": "forbidden"},
        "traceRefs": [],
        "replayRefs": [],
        "evidenceRefs": [],
        "idempotency": {"key": label},
        "revision": 1
    })
}

fn stored_report_payload(label: &str, proposal_id: &str, status: &str) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": status,
        "toolSourceProposalResourceId": proposal_id,
        "proposalVersionId": format!("version:{label}"),
        "status": status,
        "checks": [{"name": "schema_bounded", "status": status}],
        "summary": {"source": "test_resource_store"},
        "authority": {"activation": "forbidden"},
        "traceRefs": [],
        "replayRefs": [],
        "evidenceRefs": [],
        "idempotency": {"key": label},
        "revision": 1,
        "activation": {"performed": false, "catalogRegistration": false, "execution": false}
    })
}
