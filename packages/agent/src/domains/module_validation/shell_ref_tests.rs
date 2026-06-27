use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_module_validation_report_value, record_module_validation_report_value_at,
};
use super::{Deps, MODULE_VALIDATION_REPORT_KIND};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, ListResources, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-26T12:00:00Z";

struct Fixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[MODULE_VALIDATION_REPORT_KIND],
            &["kind:module_validation_report"],
        )
        .await;
        Self {
            deps,
            session_id,
            write_grant_id,
        }
    }

    async fn record(&self, key: &str, payload: Value) -> Value {
        let invocation = self.write_invocation(key, payload);
        record_module_validation_report_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record module validation report")
    }

    async fn record_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        record_module_validation_report_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("record should fail")
        .to_string()
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let exact_grant = self.exact_read_grant(key, resource_id).await;
        let invocation = invocation(
            key,
            json!({"moduleValidationReportResourceId": resource_id}),
            exact_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &self.session_id,
        );
        inspect_module_validation_report_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect module validation report")
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[MODULE_VALIDATION_REPORT_KIND],
            &["kind:module_validation_report", exact_selector.as_str()],
        )
        .await
    }

    async fn raw_current_payload(&self, resource_id: &str) -> Value {
        let inspection = self
            .deps
            .engine_host
            .inspect_resource(resource_id)
            .await
            .expect("inspect module validation report resource")
            .expect("module validation report resource");
        let current = inspection.resource.current_version_id.as_deref();
        inspection
            .versions
            .iter()
            .find(|version| Some(version.version_id.as_str()) == current)
            .expect("current module validation payload")
            .payload
            .clone()
    }

    fn write_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.write_grant_id.clone(),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        )
    }
}

#[tokio::test]
async fn validation_command_and_result_refs_reject_raw_shell_preview_or_summary() {
    let fixture = Fixture::new("module-validation-shell-ref-denial").await;

    for (label, field, value) in [
        (
            "command-preview-cargo",
            "commandRefs",
            json!([{
                "kind": "command_identity",
                "id": "cmd:cargo-test-module-validation",
                "role": "command_identity",
                "fingerprint": "sha256:command_identity",
                "preview": "cargo test --manifest-path packages/agent/Cargo.toml module_validation"
            }]),
        ),
        (
            "command-summary-xcodebuild",
            "commandRefs",
            json!([{
                "kind": "command_identity",
                "id": "cmd:xcodebuild-module-validation",
                "role": "command_identity",
                "fingerprint": "sha256:xcodebuild_identity",
                "summary": "xcodebuild test -scheme Tron -destination simulator"
            }]),
        ),
        (
            "result-preview-scripts-tron",
            "resultRefs",
            json!([{
                "kind": "command_result",
                "id": "result:static-gates",
                "role": "result_ref",
                "status": "passed",
                "fingerprint": "sha256:static_gates",
                "preview": "scripts/tron ci fmt check clippy test"
            }]),
        ),
        (
            "result-summary-git-status",
            "resultRefs",
            json!([{
                "kind": "command_result",
                "id": "result:git-status",
                "role": "result_ref",
                "status": "passed",
                "fingerprint": "sha256:git_status",
                "summary": "git status --short"
            }]),
        ),
    ] {
        let mut payload = validation_payload();
        payload[field] = value;
        let denied = fixture.record_error(label, payload).await;
        assert!(
            denied.contains("shell-command-like"),
            "{label} should reject raw shell text: {denied}"
        );
    }

    let resources = fixture
        .deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MODULE_VALIDATION_REPORT_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources after shell ref denial");
    assert!(
        resources.is_empty(),
        "raw shell command refs must be rejected before storage"
    );
}

#[tokio::test]
async fn validation_command_and_result_refs_allow_safe_evidence_summaries() {
    let fixture = Fixture::new("module-validation-safe-ref-summaries").await;
    let mut payload = validation_payload();
    payload["commandRefs"] = json!([{
        "kind": "command_identity",
        "id": "cmd:module-validation-focused-suite",
        "role": "command_identity",
        "fingerprint": "sha256:module_validation_focused_suite",
        "preview": "Focused module validation suite identity.",
        "summary": "Cargo validation identity described without executable syntax."
    }]);
    payload["resultRefs"] = json!([{
        "kind": "command_result",
        "id": "result:module-validation-focused-suite",
        "role": "result_ref",
        "status": "passed",
        "fingerprint": "sha256:module_validation_focused_result",
        "preview": "Focused module validation suite completed.",
        "summary": "Safe bounded result summary with no shell text."
    }]);

    let recorded = fixture.record("safe-ref-summary-create", payload).await;
    let resource_id = recorded["moduleValidationReportResourceId"]
        .as_str()
        .unwrap();
    let stored = fixture.raw_current_payload(resource_id).await;
    assert_eq!(
        stored["evidence"]["commands"][0]["summary"],
        json!("Cargo validation identity described without executable syntax.")
    );
    assert_eq!(
        stored["evidence"]["results"][0]["summary"],
        json!("Safe bounded result summary with no shell text.")
    );

    let inspected = fixture
        .inspect("module-validation-safe-ref-summaries-inspect", resource_id)
        .await;
    assert_eq!(
        inspected["validationReport"]["validationReport"]["evidence"]["commands"]["items"][0]["summary"],
        json!("Cargo validation identity described without executable syntax.")
    );
    assert_eq!(
        inspected["validationReport"]["validationReport"]["evidence"]["results"]["items"][0]["summary"],
        json!("Safe bounded result summary with no shell text.")
    );
    assert_no_leaks(
        "safe ref summary inspect response",
        &inspected,
        &[
            "cargo test",
            "xcodebuild test",
            "scripts/tron",
            "git status",
        ],
    );
}

fn validation_payload() -> Value {
    json!({
        "reportId": "slice-23c-validation-report",
        "title": "Module Validation Harness",
        "summary": "Bounded validation evidence for module contract test harness review.",
        "moduleRefs": [{"kind": "module_manifest", "resourceId": "module_manifest:module_registry", "role": "module"}],
        "proposalRefs": [{"kind": "module_proposal", "resourceId": "module_proposal:proposal_23c", "role": "proposal"}],
        "manifestProjectionParity": [{"name": "manifest_projection", "status": "passed", "summary": "Manifest declarations matched provider projection.", "fingerprint": "sha256:manifest_parity"}],
        "resourceProjectionParity": [{"name": "resource_projection", "status": "passed", "summary": "Resource schema and kind matched stored report.", "fingerprint": "sha256:resource_parity"}],
        "providerProjectionParity": [{"name": "provider_projection", "status": "passed", "summary": "Provider metadata stayed bounded and redacted.", "fingerprint": "sha256:provider_parity"}],
        "docEvidence": [{"kind": "prompt_artifact", "resourceId": "prompt_artifact:docs", "role": "docs", "fingerprint": "sha256:docs"}],
        "testEvidence": [{"kind": "prompt_artifact", "resourceId": "prompt_artifact:tests", "role": "tests", "fingerprint": "sha256:tests"}],
        "validationStatus": "pending_review",
        "validationChecks": [{"name": "docs_tests_present", "status": "passed", "summary": "Docs and tests evidence refs are present.", "fingerprint": "sha256:docs_tests"}]
    })
}

async fn derive_grant(
    deps: &Deps,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
) -> AuthorityGrantId {
    let grant = deps
        .engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("module-validation-{suffix}")).unwrap()),
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
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "module_validation_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "module_validation_test"}),
            trace_id: TraceId::new(format!("trace-module-validation-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-module-validation")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(key.to_owned());
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

fn default_operation_at() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(DEFAULT_OPERATION_AT)
        .expect("test timestamp")
        .with_timezone(&Utc)
}

fn assert_no_leaks(label: &str, value: &Value, needles: &[&str]) {
    let serialized = serde_json::to_string(value).expect("serialize value");
    for needle in needles {
        assert!(
            !serialized.contains(needle),
            "{label} leaked forbidden string {needle}: {serialized}"
        );
    }
}
