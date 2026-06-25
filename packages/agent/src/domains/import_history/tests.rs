use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_import_history_value, list_import_history_value, record_import_history_value_at,
};
use super::{Deps, IMPORT_HISTORY_RECORD_KIND, IMPORT_HISTORY_RECORD_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, ListResources, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-25T12:00:00Z";
const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.import_history.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.import_history.idempotency.v1\0";
const IDEMPOTENCY_LEAK_PREFIX: &str = "IMPORT_HISTORY_IDEMPOTENCY_LEAK_PREFIX";
const IDEMPOTENCY_LEAK_SUFFIX: &str = "IMPORT_HISTORY_IDEMPOTENCY_LEAK_SUFFIX";

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
            &[IMPORT_HISTORY_RECORD_KIND],
            &["kind:import_history_record"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[IMPORT_HISTORY_RECORD_KIND],
            &["kind:import_history_record"],
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
            &[IMPORT_HISTORY_RECORD_KIND],
            &["kind:import_history_record"],
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
        record_import_history_value_at(&self.deps, &invocation, &invocation.payload, operation_at)
            .await
            .expect("record import history")
    }

    async fn record_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        record_import_history_value_at(
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
        list_import_history_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list import history")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"importHistoryResourceId": resource_id}));
        inspect_import_history_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect import history")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"importHistoryResourceId": resource_id}));
        inspect_import_history_value(&self.deps, &invocation, &invocation.payload)
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
            .expect("inspect import history resource")
            .expect("import history resource");
        let current = inspection.resource.current_version_id.as_deref();
        inspection
            .versions
            .iter()
            .find(|version| Some(version.version_id.as_str()) == current)
            .expect("current import history payload")
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
            &[IMPORT_HISTORY_RECORD_KIND],
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
async fn record_list_inspect_import_history_resource_schema_and_lifecycle() {
    let fixture = Fixture::new("import-history-lifecycle").await;
    let recorded_at = dt("2026-06-25T09:00:00Z");
    let recorded = fixture
        .record_at(
            "record-graph",
            graph_payload_for(&fixture.session_id),
            recorded_at,
        )
        .await;
    assert_eq!(recorded["status"], json!("active"));
    assert_eq!(recorded["idempotentReplay"], json!(false));
    let resource_id = recorded["importHistoryResourceId"].as_str().unwrap();

    let stored = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("import history resource");
    assert_eq!(stored.resource.kind, IMPORT_HISTORY_RECORD_KIND);
    assert_eq!(stored.resource.schema_id, IMPORT_HISTORY_RECORD_SCHEMA_ID);
    assert_eq!(stored.resource.lifecycle, "active");
    assert_eq!(
        stored.versions[0].payload["metadata"]["genericGraphOnly"],
        json!(true)
    );
    assert_eq!(
        stored.versions[0].payload["metadata"]["rawImportPayloadStored"],
        json!(false)
    );

    let listed = fixture
        .list(
            "list-graph",
            json!({"subjectKind": "session", "subjectId": &fixture.session_id}),
        )
        .await;
    assert_eq!(listed["records"].as_array().unwrap().len(), 1);
    assert_eq!(
        listed["records"][0]["lineage"]["parents"]["total"],
        json!(1)
    );
    assert_eq!(
        listed["records"][0]["lineage"]["children"]["total"],
        json!(2)
    );

    let inspected = fixture.inspect("inspect-graph", resource_id).await;
    assert_eq!(
        inspected["record"]["payload"]["createdAt"],
        json!(recorded_at.to_rfc3339())
    );
    assert_eq!(
        inspected["record"]["payload"]["metadata"]["renderHint"],
        json!("generic_graph")
    );
    assert_eq!(
        inspected["record"]["projection"]["genericGraphOnly"],
        json!(true)
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
            .any(|event| event.topic == "import_history.lifecycle"
                && event.payload["event"] == json!("import_history.recorded"))
    );
}

#[tokio::test]
async fn import_history_validation_rejects_raw_payloads_secret_like_and_tree_hints() {
    let fixture = Fixture::new("import-history-validation").await;
    let raw = fixture
        .record_error(
            "raw-import",
            json!({
                "subjectKind": "session",
                "subjectId": &fixture.session_id,
                "repositoryTree": {"nodes": []}
            }),
        )
        .await;
    assert!(raw.contains("bounded lineage refs only"), "{raw}");

    let render_hint = fixture
        .record_error(
            "tree-render",
            json!({
                "subjectKind": "session",
                "subjectId": &fixture.session_id,
                "renderHint": "native_tree"
            }),
        )
        .await;
    assert!(render_hint.contains("generic_graph"), "{render_hint}");

    let secret_like_context = fixture
        .record_error(
            "authorization:import-history-secret",
            graph_payload_for(&fixture.session_id),
        )
        .await;
    assert!(
        secret_like_context.contains("credential-like material"),
        "{secret_like_context}"
    );

    let bad_ref = fixture
        .record_error(
            "bad-ref",
            json!({
                "subjectKind": "session",
                "subjectId": &fixture.session_id,
                "parentRefs": [{"kind": "session", "id": "../unsafe-path"}]
            }),
        )
        .await;
    assert!(bad_ref.contains("bounded non-wildcard token"), "{bad_ref}");
}

#[tokio::test]
async fn import_history_redacted_projections_do_not_leak_raw_payload_or_authority() {
    let fixture = Fixture::new("import-history-redaction").await;
    let created = fixture
        .record("redacted-record", graph_payload_for(&fixture.session_id))
        .await;
    let resource_id = created["importHistoryResourceId"].as_str().unwrap();
    let inspected = fixture.inspect("redacted-inspect", resource_id).await;

    assert!(
        inspected["record"]["payload"].get("idempotency").is_none(),
        "inspect projection must not return raw payload idempotency evidence"
    );
    assert_eq!(
        inspected["record"]["payload"]["authority"]["grantRedacted"],
        json!(true)
    );
    assert_no_leaks(
        "inspect response",
        &inspected,
        &["repositoryTree", "rawImportPayload", "grantId"],
    );
}

#[tokio::test]
async fn import_history_projections_truncate_multibyte_utf8_without_panicking() {
    let fixture = Fixture::new("import-history-utf8-truncation").await;
    let expected_summary = "a".repeat(511);
    let created = fixture
        .record(
            "utf8-truncation-record",
            graph_payload_with_summary(
                &fixture.session_id,
                format!("{expected_summary}\u{00e9}tail"),
            ),
        )
        .await;
    let resource_id = created["importHistoryResourceId"].as_str().unwrap();

    let listed = fixture
        .list(
            "utf8-truncation-list",
            json!({"subjectKind": "session", "subjectId": &fixture.session_id}),
        )
        .await;
    let listed_summary = listed["records"][0]["metadata"]["lineageSummary"]
        .as_str()
        .unwrap();
    assert_eq!(listed_summary, expected_summary);
    assert!(listed_summary.len() <= 512);

    let inspected = fixture
        .inspect("utf8-truncation-inspect", resource_id)
        .await;
    let inspected_summary = inspected["record"]["payload"]["metadata"]["lineageSummary"]
        .as_str()
        .unwrap();
    assert_eq!(inspected_summary, expected_summary);
    assert!(inspected_summary.len() <= 512);
}

#[tokio::test]
async fn import_history_idempotency_evidence_is_fingerprinted_without_raw_key_leaks() {
    let fixture = Fixture::new("import-history-idempotency").await;
    let key = id_token_like_idempotency_key("RECORD");
    let mut invocation = fixture.write_invocation(&key, graph_payload_for(&fixture.session_id));
    invocation.id = InvocationId::new("invocation-import-history-record").expect("invocation id");
    invocation.causal_context.trace_id =
        TraceId::new("trace-import-history-record").expect("trace id");

    let created = record_import_history_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record import history with id-token-like key");
    let resource_id = created["importHistoryResourceId"].as_str().unwrap();
    let payload = fixture.raw_current_payload(resource_id).await;
    assert_fingerprinted_idempotency(&payload["idempotency"], &key);

    let listed = fixture.list("idempotency-list", json!({})).await;
    let inspected = fixture.inspect("idempotency-inspect", resource_id).await;
    let stream_payloads = Value::Array(
        fixture
            .deps
            .engine_host
            .replay_snapshot(&fixture.session_id)
            .await
            .expect("snapshot")
            .streams
            .into_iter()
            .map(|event| event.payload)
            .collect(),
    );

    for (label, value) in [
        ("create response", &created),
        ("raw resource payload", &payload),
        ("list response", &listed),
        ("inspect response", &inspected),
        ("lifecycle stream payloads", &stream_payloads),
    ] {
        assert_no_idempotency_key_fragments(label, value, &[&key]);
    }
}

#[tokio::test]
async fn import_history_authority_scope_and_replay_are_fail_closed() {
    let fixture = Fixture::new("import-history-authority").await;
    let read_only =
        fixture.read_invocation("read-only-record", graph_payload_for(&fixture.session_id));
    let read_only_error = record_import_history_value_at(
        &fixture.deps,
        &read_only,
        &read_only.payload,
        default_operation_at(),
    )
    .await
    .expect_err("read-only denied")
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
            &["kind:*"],
            "none",
        )
        .await;
    let wildcard = fixture.invocation_with_grant(
        "wildcard-record",
        graph_payload_for(&fixture.session_id),
        wildcard_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let wildcard_error = record_import_history_value_at(
        &fixture.deps,
        &wildcard,
        &wildcard.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wildcard denied")
    .to_string();
    assert!(
        wildcard_error.contains("broad resource selector"),
        "{wildcard_error}"
    );

    let network_grant = fixture
        .derive_grant(
            "network",
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &["kind:import_history_record"],
            "declared",
        )
        .await;
    let network = fixture.invocation_with_grant(
        "network-record",
        graph_payload_for(&fixture.session_id),
        network_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let network_error = record_import_history_value_at(
        &fixture.deps,
        &network,
        &network.payload,
        default_operation_at(),
    )
    .await
    .expect_err("network denied")
    .to_string();
    assert!(
        network_error.contains("networkPolicy none"),
        "{network_error}"
    );

    let first = fixture
        .record("same-key", graph_payload_for(&fixture.session_id))
        .await;
    let replay = fixture
        .record("same-key", graph_payload_for(&fixture.session_id))
        .await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    assert_eq!(
        first["importHistoryResourceId"],
        replay["importHistoryResourceId"]
    );

    let resource_id = first["importHistoryResourceId"].as_str().unwrap();
    let other = fixture
        .clone_for_session("import-history-other-session")
        .await;
    let scope_error = other.inspect_error("scope-denied", resource_id).await;
    assert!(
        scope_error.contains("outside the current scope"),
        "{scope_error}"
    );

    let resources = fixture
        .deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(IMPORT_HISTORY_RECORD_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources");
    assert_eq!(resources.len(), 1, "replay must not duplicate resources");
}

fn graph_payload_for(session_id: &str) -> Value {
    json!({
        "recordId": "session-graph-1",
        "graphKind": "session_resource",
        "subjectKind": "session",
        "subjectId": session_id,
        "lineageLabel": "Imported branch lineage",
        "lineageSummary": "Generic graph lineage for imported session resources.",
        "renderHint": "generic_graph",
        "importSourceKind": "git_branch_start",
        "parentRefs": [{"kind": "session", "id": "parent-session", "role": "fork_parent"}],
        "childRefs": [
            {"kind": "resource", "id": "media_artifact:child-1", "role": "imported_resource"},
            {"kind": "resource", "id": "memory_record:child-2", "role": "imported_resource"}
        ],
        "sourceRefs": [{"kind": "git_branch_start", "id": "git_branch_start:source"}],
        "evidenceRefs": [{"kind": "trace", "id": "trace-import-source"}],
        "maxAgeDays": 45
    })
}

fn graph_payload_with_summary(session_id: &str, lineage_summary: String) -> Value {
    let mut payload = graph_payload_for(session_id);
    payload["lineageSummary"] = json!(lineage_summary);
    payload
}

fn id_token_like_idempotency_key(label: &str) -> String {
    format!(
        "eyJhbGciOiJSUzI1NiJ9.{IDEMPOTENCY_LEAK_PREFIX}_{label}_BODY.{IDEMPOTENCY_LEAK_SUFFIX}_{label}_TAIL"
    )
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
            grant_id: Some(AuthorityGrantId::new(format!("import-history-{suffix}")).unwrap()),
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
            budget: json!({"class": "import_history_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "import_history_test"}),
            trace_id: TraceId::new(format!("trace-import-history-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-import-history")
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
        value["fingerprint"],
        json!(expected_idempotency_fingerprint(key))
    );
    assert_eq!(
        value["fingerprintAlgorithm"],
        json!(IDEMPOTENCY_FINGERPRINT_ALGORITHM)
    );
    assert_eq!(value["keyRedacted"], json!(true));
    assert_eq!(value["rawKeyStored"], json!(false));
    assert!(value.get("key").is_none());
}

fn expected_idempotency_fingerprint(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(IDEMPOTENCY_FINGERPRINT_DOMAIN);
    hasher.update(key.as_bytes());
    hex::encode(hasher.finalize())
}

fn assert_no_idempotency_key_fragments<T: serde::Serialize>(label: &str, value: &T, keys: &[&str]) {
    let serialized =
        serde_json::to_string(value).unwrap_or_else(|error| panic!("serialize {label}: {error}"));
    for key in keys {
        assert!(
            !serialized.contains(key),
            "{label} leaked full idempotency key: {serialized}"
        );
    }
    for forbidden in [
        "eyJhbGciOiJSUzI1NiJ9",
        IDEMPOTENCY_LEAK_PREFIX,
        IDEMPOTENCY_LEAK_SUFFIX,
        "authorization:",
        "\"token\"",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "{label} leaked forbidden fragment `{forbidden}`: {serialized}"
        );
    }
}

fn assert_no_leaks<T: serde::Serialize>(label: &str, value: &T, forbidden: &[&str]) {
    let serialized =
        serde_json::to_string(value).unwrap_or_else(|error| panic!("serialize {label}: {error}"));
    for fragment in forbidden {
        assert!(
            !serialized.contains(fragment),
            "{label} leaked forbidden fragment `{fragment}`: {serialized}"
        );
    }
}
