use serde_json::{Value, json};

use super::service::{
    create_conformance_report_value, create_proposal_value, inspect_tool_source_value,
    list_tool_sources_value,
};
use super::{Deps, PROPOSE_FUNCTION, READ_SCOPE, REPORT_FUNCTION};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
    TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID, TOOL_SOURCE_PROPOSAL_KIND,
    TOOL_SOURCE_PROPOSAL_SCHEMA_ID, TraceId, builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

mod inspect;
mod validation_tests;

#[tokio::test]
async fn internal_proposal_creation_records_bounded_inert_resource() {
    let fixture = Fixture::new("proposal-create").await;
    let result = fixture
        .create_proposal("proposal-create", proposal_payload())
        .await;
    let resource_id = result["toolSourceProposalResourceId"]
        .as_str()
        .expect("proposal id");

    assert_eq!(result["activation"]["performed"], json!(false));
    let inspection = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("proposal");
    assert_eq!(inspection.resource.kind, TOOL_SOURCE_PROPOSAL_KIND);
    assert_eq!(
        inspection.resource.schema_id,
        TOOL_SOURCE_PROPOSAL_SCHEMA_ID
    );
    assert_eq!(inspection.resource.scope.kind(), "session");
    let payload = current_payload(&inspection);
    assert_eq!(payload["sourceKind"], json!("mcp_server"));
    assert_eq!(payload["sandboxPolicy"]["networkPolicy"], json!("none"));
    assert_eq!(payload["declaredTools"][0]["name"], json!("lookup"));
    assert_eq!(payload["activation"], Value::Null);
}

#[tokio::test]
async fn proposal_creation_requires_internal_non_wildcard_authority() {
    let fixture = Fixture::new("proposal-authority").await;
    let agent_error = fixture
        .create_proposal_error_with_actor(
            "proposal-agent-denied",
            ActorKind::Agent,
            proposal_payload(),
        )
        .await;
    assert!(agent_error.contains("trusted internal"), "{agent_error}");

    let bootstrap_invocation = invocation(
        PROPOSE_FUNCTION,
        "bootstrap-denied",
        proposal_payload(),
        AuthorityGrantId::new("engine-system").unwrap(),
        ActorKind::System,
        &["tool_sources.propose", "resource.write"],
        Some("proposal-authority-session"),
    );
    let bootstrap = create_proposal_value(
        &fixture.deps,
        &bootstrap_invocation,
        &bootstrap_invocation.payload,
    )
    .await
    .expect_err("bootstrap grant denied")
    .to_string();
    assert!(bootstrap.contains("non-bootstrap"), "{bootstrap}");

    let wildcard_grant = fixture
        .derive_grant(
            "wildcard",
            &["tool_sources.propose", "resource.write"],
            &["*"],
            &["kind:tool_source_proposal"],
            "none",
        )
        .await;
    let wildcard_invocation = invocation(
        PROPOSE_FUNCTION,
        "wildcard-denied",
        proposal_payload(),
        wildcard_grant,
        ActorKind::System,
        &["tool_sources.propose", "resource.write"],
        Some(&fixture.session_id),
    );
    let wildcard = create_proposal_value(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
    )
    .await
    .expect_err("wildcard grant denied")
    .to_string();
    assert!(wildcard.contains("wildcard"), "{wildcard}");
}

#[tokio::test]
async fn proposal_creation_is_idempotent_per_scope_and_key() {
    let fixture = Fixture::new("proposal-idempotent").await;
    let first = fixture
        .create_proposal("same-key", proposal_payload())
        .await;
    let second = fixture
        .create_proposal("same-key", proposal_payload())
        .await;
    assert_eq!(
        first["toolSourceProposalResourceId"],
        second["toolSourceProposalResourceId"]
    );
    assert_eq!(second["idempotentReplay"], json!(true));

    let listed = fixture.list("proposal-list").await;
    assert_eq!(listed["proposals"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn read_operations_are_session_scoped_and_sandbox_visible() {
    let first = Fixture::new("scope-one").await;
    let second = first.clone_for_session("scope-two-session").await;
    let created = first.create_proposal("scope-key", proposal_payload()).await;
    let resource_id = created["toolSourceProposalResourceId"].as_str().unwrap();

    let inspected = first.inspect("scope-inspect", resource_id).await;
    assert_eq!(
        inspected["resource"]["payload"]["sandboxPolicy"]["networkPolicy"],
        "none"
    );
    assert_eq!(inspected["activation"]["catalogRegistration"], json!(false));

    let cross_scope = second.inspect_error("scope-denied", resource_id).await;
    assert!(
        cross_scope.contains("outside the current scope"),
        "{cross_scope}"
    );
}

#[tokio::test]
async fn proposal_validation_rejects_secrets_unsafe_paths_unbounded_schema_and_execution_fields() {
    let fixture = Fixture::new("proposal-validation").await;
    let mut secret = proposal_payload();
    secret["sourceIdentity"]["token"] = json!("Bearer not-allowed");
    assert!(
        fixture
            .create_proposal_error("secret", secret)
            .await
            .contains("secret")
    );

    let mut unsafe_path = proposal_payload();
    unsafe_path["expectedLinkage"] = json!({"manifestPath": "../escape"});
    assert!(
        fixture
            .create_proposal_error("unsafe-path", unsafe_path)
            .await
            .contains("unsafe path")
    );

    let mut command = proposal_payload();
    command["declaredTools"][0]["command"] = json!("node server.js");
    assert!(
        fixture
            .create_proposal_error("command", command)
            .await
            .contains("execution field")
    );

    let mut schema = proposal_payload();
    schema["declaredSchemas"] = json!([{"schema": "x".repeat(33_000)}]);
    assert!(
        fixture
            .create_proposal_error("large-schema", schema)
            .await
            .contains("exceeds")
    );

    let mut wildcard = proposal_payload();
    wildcard["sandboxPolicy"]["authorityScopes"] = json!(["*"]);
    assert!(
        fixture
            .create_proposal_error("sandbox-wildcard", wildcard)
            .await
            .contains("wildcard authority")
    );
}

#[tokio::test]
async fn proposal_validation_rejects_string_valued_activation_intent() {
    let fixture = Fixture::new("proposal-string-intent").await;
    let mut cases = Vec::new();
    let mut payload = proposal_payload();
    payload["sourceIdentity"]["note"] = json!("register this MCP server");
    cases.push(("string-register", payload));
    let mut payload = proposal_payload();
    payload["sandboxPolicy"]["reviewNote"] = json!("install package after review");
    cases.push(("string-install", payload));
    let mut payload = proposal_payload();
    payload["declaredTools"][0]["description"] = json!("execute this tool");
    cases.push(("string-execute", payload));
    let mut payload = proposal_payload();
    payload["expectedLinkage"]["plan"] = json!("launch worker package");
    cases.push(("string-launch", payload));
    for (key, payload) in cases {
        let error = fixture.create_proposal_error(key, payload).await;
        assert!(error.contains("activation intent string"), "{error}");
    }
}

#[tokio::test]
async fn conformance_report_links_to_proposal_without_activation() {
    let fixture = Fixture::new("proposal-report").await;
    let proposal = fixture
        .create_proposal("report-proposal", proposal_payload())
        .await;
    let proposal_id = proposal["toolSourceProposalResourceId"].as_str().unwrap();
    let report = fixture
        .create_report(
            "report-key",
            json!({
                "toolSourceProposalResourceId": proposal_id,
                "status": "passed",
                "checks": [{"name": "schema_bounded", "status": "passed"}],
                "summary": {"preflight": "metadata_only"}
            }),
        )
        .await;
    let report_id = report["toolSourceConformanceReportResourceId"]
        .as_str()
        .expect("report id");
    assert_eq!(report["activation"]["execution"], json!(false));

    let inspection = fixture
        .deps
        .engine_host
        .inspect_resource(report_id)
        .await
        .expect("inspect")
        .expect("report");
    assert_eq!(
        inspection.resource.kind,
        TOOL_SOURCE_CONFORMANCE_REPORT_KIND
    );
    assert_eq!(
        inspection.resource.schema_id,
        TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID
    );
    let payload = current_payload(&inspection);
    assert_eq!(payload["toolSourceProposalResourceId"], json!(proposal_id));
    assert_eq!(payload["status"], json!("passed"));

    let inspected = fixture.inspect("report-inspect", report_id).await;
    assert_eq!(
        inspected["resource"]["kind"],
        json!(TOOL_SOURCE_CONFORMANCE_REPORT_KIND)
    );
}

#[tokio::test]
async fn conformance_report_creation_requires_report_resource_kind_authority() {
    let fixture = Fixture::new("report-kind-authority").await;
    let proposal = fixture
        .create_proposal("report-kind-proposal", proposal_payload())
        .await;
    let proposal_id = proposal["toolSourceProposalResourceId"].as_str().unwrap();
    let proposal_only_grant = fixture
        .derive_grant(
            "proposal-only-write",
            &["tool_sources.propose", "resource.write"],
            &["tool_source_proposal"],
            &["kind:tool_source_proposal"],
            "none",
        )
        .await;
    let invocation = invocation(
        REPORT_FUNCTION,
        "proposal-only-report-denied",
        json!({
            "toolSourceProposalResourceId": proposal_id,
            "status": "passed"
        }),
        proposal_only_grant,
        ActorKind::System,
        &["tool_sources.propose", "resource.write"],
        Some(&fixture.session_id),
    );

    let error = create_conformance_report_value(&fixture.deps, &invocation, &invocation.payload)
        .await
        .expect_err("proposal-only grant cannot create report")
        .to_string();
    assert!(error.contains("tool_source_conformance_report"), "{error}");
}

#[tokio::test]
async fn proposal_only_read_grant_cannot_inspect_conformance_reports() {
    let fixture = Fixture::new("report-read-kind-authority").await;
    let proposal = fixture
        .create_proposal("read-kind-proposal", proposal_payload())
        .await;
    let proposal_id = proposal["toolSourceProposalResourceId"].as_str().unwrap();
    let report = fixture
        .create_report(
            "read-kind-report",
            json!({
                "toolSourceProposalResourceId": proposal_id,
                "status": "passed"
            }),
        )
        .await;
    let report_id = report["toolSourceConformanceReportResourceId"]
        .as_str()
        .unwrap();
    let proposal_only_read_grant = fixture
        .derive_grant(
            "proposal-only-read",
            &["tool_sources.read", "resource.read"],
            &["tool_source_proposal"],
            &["kind:tool_source_proposal"],
            "none",
        )
        .await;
    let list_invocation = invocation(
        "capability::execute",
        "proposal-only-list",
        json!({"limit": 10}),
        proposal_only_read_grant.clone(),
        ActorKind::Agent,
        &[READ_SCOPE, "resource.read"],
        Some(&fixture.session_id),
    );
    let listed = list_tool_sources_value(&fixture.deps, &list_invocation, &list_invocation.payload)
        .await
        .expect("proposal-only grant can list proposals");
    assert_eq!(listed["proposals"].as_array().unwrap().len(), 1);

    let proposal_inspect_invocation = invocation(
        "capability::execute",
        "proposal-only-inspect-proposal",
        json!({"toolSourceResourceId": proposal_id}),
        proposal_only_read_grant.clone(),
        ActorKind::Agent,
        &[READ_SCOPE, "resource.read"],
        Some(&fixture.session_id),
    );
    inspect_tool_source_value(
        &fixture.deps,
        &proposal_inspect_invocation,
        &proposal_inspect_invocation.payload,
    )
    .await
    .expect("proposal-only grant can inspect proposals");

    let report_inspect_invocation = invocation(
        "capability::execute",
        "proposal-only-inspect-report",
        json!({"toolSourceResourceId": report_id}),
        proposal_only_read_grant,
        ActorKind::Agent,
        &[READ_SCOPE, "resource.read"],
        Some(&fixture.session_id),
    );
    let error = inspect_tool_source_value(
        &fixture.deps,
        &report_inspect_invocation,
        &report_inspect_invocation.payload,
    )
    .await
    .expect_err("proposal-only grant cannot inspect reports")
    .to_string();
    assert!(error.contains("tool_source_conformance_report"), "{error}");
}

#[tokio::test]
async fn proposals_do_not_register_or_execute_declared_tools() {
    let fixture = Fixture::new("proposal-non-goal").await;
    let before = fixture.deps.engine_host.catalog_revision().await.0;
    let _ = fixture
        .create_proposal("non-goal", proposal_payload())
        .await;
    let after = fixture.deps.engine_host.catalog_revision().await.0;
    assert_eq!(
        before, after,
        "proposal creation must not register catalog tools"
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
    deps: Deps,
    session_id: String,
    grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                "tool_sources.propose",
                "tool_sources.read",
                "resource.write",
                "resource.read",
            ],
            &["tool_source_proposal", "tool_source_conformance_report"],
            &[
                "kind:tool_source_proposal",
                "kind:tool_source_conformance_report",
            ],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &["tool_sources.read", "resource.read"],
            &["tool_source_proposal", "tool_source_conformance_report"],
            &[
                "kind:tool_source_proposal",
                "kind:tool_source_conformance_report",
            ],
            "none",
        )
        .await;
        Self {
            deps,
            session_id,
            grant_id,
            read_grant_id,
        }
    }

    async fn clone_for_session(&self, session_id: &str) -> Self {
        let grant_id = self
            .derive_grant(
                &format!("{session_id}-write"),
                &[
                    "tool_sources.propose",
                    "tool_sources.read",
                    "resource.write",
                    "resource.read",
                ],
                &["tool_source_proposal", "tool_source_conformance_report"],
                &[
                    "kind:tool_source_proposal",
                    "kind:tool_source_conformance_report",
                ],
                "none",
            )
            .await;
        let read_grant_id = self
            .derive_grant(
                &format!("{session_id}-read"),
                &["tool_sources.read", "resource.read"],
                &["tool_source_proposal", "tool_source_conformance_report"],
                &[
                    "kind:tool_source_proposal",
                    "kind:tool_source_conformance_report",
                ],
                "none",
            )
            .await;
        Self {
            deps: self.deps.clone(),
            session_id: session_id.to_owned(),
            grant_id,
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
            &self.deps,
            suffix,
            scopes,
            resource_kinds,
            selectors,
            network_policy,
        )
        .await
    }

    async fn create_proposal(&self, key: &str, payload: Value) -> Value {
        let invocation = self.write_invocation(PROPOSE_FUNCTION, key, payload, ActorKind::System);
        create_proposal_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("create proposal")
    }

    async fn create_proposal_error(&self, key: &str, payload: Value) -> String {
        self.create_proposal_error_with_actor(key, ActorKind::System, payload)
            .await
    }

    async fn create_proposal_error_with_actor(
        &self,
        key: &str,
        actor_kind: ActorKind,
        payload: Value,
    ) -> String {
        let invocation = self.write_invocation(PROPOSE_FUNCTION, key, payload, actor_kind);
        create_proposal_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("proposal should fail")
            .to_string()
    }

    async fn create_report(&self, key: &str, payload: Value) -> Value {
        let invocation = self.write_invocation(REPORT_FUNCTION, key, payload, ActorKind::System);
        create_conformance_report_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("create report")
    }

    async fn list(&self, key: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"limit": 10}));
        list_tool_sources_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list proposals")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(
            key,
            json!({"toolSourceResourceId": resource_id, "maxSchemaBytes": 100}),
        );
        inspect_tool_source_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect proposal")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"toolSourceResourceId": resource_id}));
        inspect_tool_source_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    fn write_invocation(
        &self,
        function_id: &str,
        key: &str,
        payload: Value,
        actor_kind: ActorKind,
    ) -> Invocation {
        invocation(
            function_id,
            key,
            payload,
            self.grant_id.clone(),
            actor_kind,
            &["tool_sources.propose", "resource.write"],
            Some(&self.session_id),
        )
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            "capability::execute",
            key,
            payload,
            self.read_grant_id.clone(),
            ActorKind::Agent,
            &[READ_SCOPE, "resource.read"],
            Some(&self.session_id),
        )
    }
}

async fn derive_grant(
    deps: &Deps,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    let grant = deps
        .engine_host
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
    function_id: &str,
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    actor_kind: ActorKind,
    scopes: &[&str],
    session_id: Option<&str>,
) -> Invocation {
    let actor_id = match actor_kind {
        ActorKind::Agent => ActorId::new(format!("agent:{}", session_id.unwrap())).unwrap(),
        ActorKind::System => ActorId::new("system:tool-sources-test").unwrap(),
        ActorKind::Admin => ActorId::new("admin:tool-sources-test").unwrap(),
        _ => ActorId::new("client:tool-sources-test").unwrap(),
    };
    let mut context = CausalContext::new(
        actor_id,
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-tool-sources")
    .with_idempotency_key(key.to_owned());
    if let Some(session_id) = session_id {
        context = context.with_session_id(session_id.to_owned());
    }
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new(function_id).unwrap(),
        delivery_mode: crate::engine::DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn proposal_payload() -> Value {
    json!({
        "sourceKind": "mcp_server",
        "sourceIdentity": {
            "id": "demo.lookup",
            "label": "Demo Lookup",
            "uri": "mcp://demo.lookup"
        },
        "provenance": {
            "submittedBy": "system-test",
            "source": "fixture",
            "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        "sandboxPolicy": {
            "networkPolicy": "none",
            "authorityScopes": ["tool_sources.read"],
            "resourceKinds": ["tool_source_proposal"],
            "resourceSelectors": ["kind:tool_source_proposal"]
        },
        "declaredTools": [{
            "name": "lookup",
            "description": "Lookup metadata only.",
            "inputSchemaRef": "schema:lookup.input"
        }],
        "declaredSchemas": [{
            "id": "schema:lookup.input",
            "schema": {"type": "object", "additionalProperties": false, "properties": {"query": {"type": "string"}}}
        }],
        "expectedLinkage": {
            "workerPackageResourceId": "worker_package:demo.lookup:1.0.0"
        },
        "evidenceRefs": [{"kind": "fixture", "id": "evidence-1"}],
        "summary": "Demo lookup proposal"
    })
}

fn current_payload(inspection: &crate::engine::EngineResourceInspection) -> Value {
    let current = inspection
        .resource
        .current_version_id
        .as_ref()
        .expect("current version");
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .expect("current payload")
        .payload
        .clone()
}
