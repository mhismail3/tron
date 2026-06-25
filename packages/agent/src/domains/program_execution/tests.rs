use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_program_execution_value, list_program_execution_value,
    record_program_execution_record_value_at,
};
use super::{Deps, PROGRAM_EXECUTION_KIND, PROGRAM_EXECUTION_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-25T12:00:00Z";
const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.program_execution.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.program_execution.idempotency.v1\0";
const IDEMPOTENCY_LEAK_PREFIX: &str = "PROGRAM_EXECUTION_IDEMPOTENCY_LEAK_PREFIX";
const IDEMPOTENCY_LEAK_SUFFIX: &str = "PROGRAM_EXECUTION_IDEMPOTENCY_LEAK_SUFFIX";

struct Fixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
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
            &[PROGRAM_EXECUTION_KIND],
            &["kind:program_execution_record"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[PROGRAM_EXECUTION_KIND],
            &["kind:program_execution_record"],
            "none",
        )
        .await;
        Self {
            deps,
            session_id,
            write_grant_id,
            read_grant_id,
        }
    }

    async fn clone_for_session(&self, session_id: &str) -> Self {
        let read_grant_id = derive_grant(
            &self.deps,
            &format!("{session_id}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[PROGRAM_EXECUTION_KIND],
            &["kind:program_execution_record"],
            "none",
        )
        .await;
        Self {
            deps: self.deps.clone(),
            session_id: session_id.to_owned(),
            write_grant_id: self.write_grant_id.clone(),
            read_grant_id,
        }
    }

    async fn record(&self, key: &str, payload: Value) -> Value {
        self.record_at(key, payload, default_operation_at()).await
    }

    async fn record_at(&self, key: &str, payload: Value, operation_at: DateTime<Utc>) -> Value {
        let invocation = self.write_invocation(key, payload);
        record_program_execution_record_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            operation_at,
        )
        .await
        .expect("record program execution")
    }

    async fn record_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        record_program_execution_record_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("record should fail")
        .to_string()
    }

    async fn list(&self, key: &str, payload: Value) -> Value {
        let invocation = self.read_invocation(key, payload);
        list_program_execution_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list program executions")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation =
            self.read_invocation(key, json!({"programExecutionResourceId": resource_id}));
        inspect_program_execution_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect program execution")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation =
            self.read_invocation(key, json!({"programExecutionResourceId": resource_id}));
        inspect_program_execution_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    async fn raw_current_payload(&self, resource_id: &str) -> Value {
        let inspection = self
            .deps
            .engine_host
            .inspect_resource(resource_id)
            .await
            .expect("inspect program execution resource")
            .expect("program execution resource");
        let current = inspection.resource.current_version_id.as_deref();
        inspection
            .versions
            .iter()
            .find(|version| Some(version.version_id.as_str()) == current)
            .expect("current program execution payload")
            .payload
            .clone()
    }

    async fn derive_grant(
        &self,
        suffix: &str,
        scopes: &[&str],
        selectors: &[&str],
        network_policy: &str,
    ) -> AuthorityGrantId {
        derive_grant(
            &self.deps,
            suffix,
            scopes,
            &[PROGRAM_EXECUTION_KIND],
            selectors,
            network_policy,
        )
        .await
    }

    fn write_invocation(&self, key: &str, payload: Value) -> Invocation {
        self.invocation_with_grant(
            key,
            payload,
            self.write_grant_id.clone(),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
        )
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        self.invocation_with_grant(
            key,
            payload,
            self.read_grant_id.clone(),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
        )
    }

    fn invocation_with_grant(
        &self,
        key: &str,
        payload: Value,
        grant_id: AuthorityGrantId,
        scopes: &[&str],
    ) -> Invocation {
        invocation(key, payload, grant_id, scopes, &self.session_id)
    }
}

#[tokio::test]
async fn record_list_inspect_program_execution_schema_lifecycle_and_projection() {
    let fixture = Fixture::new("program-lifecycle").await;
    let recorded_at = dt("2026-06-25T09:00:00Z");
    let recorded = fixture
        .record_at("program-record", program_payload(), recorded_at)
        .await;
    assert_eq!(recorded["status"], json!("active"));
    assert_eq!(recorded["idempotentReplay"], json!(false));
    let resource_id = recorded["programExecutionResourceId"].as_str().unwrap();

    let stored = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("resource exists");
    assert_eq!(stored.resource.kind, PROGRAM_EXECUTION_KIND);
    assert_eq!(stored.resource.schema_id, PROGRAM_EXECUTION_SCHEMA_ID);
    assert_eq!(stored.resource.scope.kind(), "session");
    assert_eq!(stored.resource.scope.value(), fixture.session_id);
    let payload = fixture.raw_current_payload(resource_id).await;
    assert_eq!(payload["createdAt"], json!("2026-06-25T09:00:00+00:00"));
    assert_eq!(payload["runtimeId"], json!("runtime.metadata.v1"));
    assert_eq!(payload["languageId"], json!("python.metadata"));
    assert_eq!(
        payload["metadata"]["runtimeExecutionPerformed"],
        json!(false)
    );
    assert_eq!(payload["metadata"]["processLaunched"], json!(false));
    assert_eq!(payload["metadata"]["rawCodeStored"], json!(false));
    assert_fingerprinted_idempotency(&payload["idempotency"], "program-record");

    let listed = fixture
        .list("program-list", json!({"runtimeId": "runtime.metadata.v1"}))
        .await;
    assert_eq!(listed["records"].as_array().unwrap().len(), 1);
    assert_eq!(
        listed["records"][0]["programExecutionResourceId"],
        json!(resource_id)
    );
    assert_eq!(
        listed["records"][0]["metadata"]["runtimeExecutionPerformed"],
        json!(false)
    );

    let inspected = fixture.inspect("program-inspect", resource_id).await;
    assert_eq!(
        inspected["record"]["payload"]["programFingerprint"],
        json!("sha256:program-envelope")
    );
    assert_eq!(
        inspected["record"]["projection"]["rawCodeReturned"],
        json!(false)
    );
    assert_eq!(
        inspected["record"]["projection"]["rawIoReturned"],
        json!(false)
    );
    assert!(
        !serde_json::to_string(&inspected)
            .unwrap()
            .contains("print(")
    );

    let streams = fixture
        .deps
        .engine_host
        .replay_snapshot(&fixture.session_id)
        .await
        .expect("snapshot")
        .streams;
    assert!(
        streams
            .iter()
            .any(|event| event.topic == "program_execution.lifecycle"
                && event.payload["event"] == json!("program_execution.recorded"))
    );
}

#[tokio::test]
async fn program_execution_validation_rejects_raw_execution_payloads_and_secrets() {
    let fixture = Fixture::new("program-validation").await;
    for (field, value) in [
        ("code", json!("print('no')")),
        ("command", json!("python script.py")),
        ("stdin", json!("raw input")),
        ("stdout", json!("raw output")),
        ("absolutePath", json!("/tmp/run.py")),
        ("packageInstall", json!("pip install thing")),
        ("programSummary", json!("run bash -c whoami")),
        ("programFingerprint", json!("token:secret")),
    ] {
        let mut payload = program_payload();
        payload[field] = value;
        let error = fixture
            .record_error(&format!("reject-{field}"), payload)
            .await;
        assert!(
            error.contains("not accepted")
                || error.contains("credential-like")
                || error.contains("executable command text"),
            "{field}: {error}"
        );
    }
}

#[tokio::test]
async fn program_execution_idempotency_evidence_is_fingerprinted_without_raw_key_leaks() {
    let fixture = Fixture::new("program-idempotency").await;
    let key = "metadata-retry-token-without-fixture-id";
    let mut invocation = fixture.write_invocation("idempotency-record", program_payload());
    invocation.causal_context.idempotency_key = Some(key.to_owned());
    let created = record_program_execution_record_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("create");
    let replayed = record_program_execution_record_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("replay");
    assert_eq!(replayed["idempotentReplay"], json!(true));
    assert_eq!(
        created["programExecutionResourceId"],
        replayed["programExecutionResourceId"]
    );
    let resource_id = created["programExecutionResourceId"].as_str().unwrap();
    let payload = fixture.raw_current_payload(resource_id).await;
    assert_fingerprinted_idempotency(&payload["idempotency"], &key);
    assert_no_idempotency_key_fragments("stored payload", &payload, &[&key]);
    assert_no_idempotency_key_fragments("projection", &created, &[&key]);
    assert_no_idempotency_key_fragments("replay", &replayed, &[&key]);
}

#[tokio::test]
async fn program_execution_authority_scope_replay_and_selector_checks_are_fail_closed() {
    let fixture = Fixture::new("program-authority").await;
    let read_only_grant = fixture
        .derive_grant(
            "read-only",
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &["kind:program_execution_record"],
            "none",
        )
        .await;
    let read_only_invocation = fixture.invocation_with_grant(
        "read-only",
        program_payload(),
        read_only_grant,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
    );
    let read_only_error = record_program_execution_record_value_at(
        &fixture.deps,
        &read_only_invocation,
        &read_only_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("read-only grant cannot write")
    .to_string();
    assert!(read_only_error.contains(WRITE_SCOPE), "{read_only_error}");

    let wildcard_grant = fixture
        .derive_grant(
            "wildcard",
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &["*"],
            "none",
        )
        .await;
    let wildcard_invocation = fixture.invocation_with_grant(
        "wildcard",
        program_payload(),
        wildcard_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let wildcard_error = record_program_execution_record_value_at(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wildcard selectors fail")
    .to_string();
    assert!(wildcard_error.contains("broad resource selector"));

    let created = fixture.record("scoped", program_payload()).await;
    let resource_id = created["programExecutionResourceId"].as_str().unwrap();
    let other_session = fixture.clone_for_session("other-program-session").await;
    let scope_error = other_session
        .inspect_error("scope-denied", resource_id)
        .await;
    assert!(scope_error.contains("outside the current scope"));
}

fn program_payload() -> Value {
    json!({
        "operation": "program_execution_record",
        "programId": "program-metadata-1",
        "runtimeId": "runtime.metadata.v1",
        "languageId": "python.metadata",
        "programFingerprint": "sha256:program-envelope",
        "sourceRef": {"kind": "artifact", "resourceId": "artifact:program-source", "role": "source"},
        "inputRef": {"kind": "artifact", "resourceId": "artifact:program-input", "role": "input"},
        "outputRef": {"kind": "artifact", "resourceId": "artifact:program-output", "role": "output"},
        "inputFingerprint": "sha256:input-envelope",
        "outputFingerprint": "sha256:output-envelope",
        "maxWallClockMs": 1000,
        "maxMemoryMb": 128,
        "maxOutputBytes": 4096,
        "programLabel": "metadata-only program envelope",
        "programSummary": "Content-free program execution metadata record.",
        "sourceRefs": [{"kind": "artifact", "resourceId": "artifact:source-ref", "role": "source"}],
        "evidenceRefs": [{"kind": "evidence", "resourceId": "evidence:program", "role": "evidence"}],
        "idempotencyKey": "program-record"
    })
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
            grant_id: Some(AuthorityGrantId::new(format!("program-execution-{suffix}")).unwrap()),
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
            budget: json!({"class": "program_execution_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "program_execution_test"}),
            trace_id: TraceId::new(format!("trace-program-execution-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-program-execution")
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
    dt(DEFAULT_OPERATION_AT)
}

fn dt(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("test timestamp")
        .with_timezone(&Utc)
}

fn assert_fingerprinted_idempotency(value: &Value, key: &str) {
    assert_eq!(
        value["fingerprintAlgorithm"],
        json!(IDEMPOTENCY_FINGERPRINT_ALGORITHM)
    );
    assert_eq!(value["fingerprint"], json!(idempotency_fingerprint(key)));
    assert_eq!(value["keyRedacted"], json!(true));
    assert_eq!(value["rawKeyStored"], json!(false));
    assert_ne!(value["fingerprint"], json!(key));
}

fn idempotency_fingerprint(idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(IDEMPOTENCY_FINGERPRINT_DOMAIN);
    hasher.update(idempotency_key.as_bytes());
    hex::encode(hasher.finalize())
}

fn assert_no_idempotency_key_fragments(label: &str, value: &Value, keys: &[&str]) {
    let serialized = serde_json::to_string(value).expect("serialize value");
    for key in keys {
        assert!(!serialized.contains(key), "{label} leaked raw key {key}");
        for fragment in key.split('.') {
            if fragment.len() > 12 {
                assert!(
                    !serialized.contains(fragment),
                    "{label} leaked raw key fragment {fragment}"
                );
            }
        }
    }
    assert!(
        !serialized.contains(IDEMPOTENCY_LEAK_PREFIX),
        "{label} leaked idempotency prefix"
    );
    assert!(
        !serialized.contains(IDEMPOTENCY_LEAK_SUFFIX),
        "{label} leaked idempotency suffix"
    );
}
