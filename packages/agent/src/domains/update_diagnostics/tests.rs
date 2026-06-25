use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_update_diagnostics_value, list_update_diagnostics_value,
    record_update_diagnostic_value_at,
};
use super::{Deps, UPDATE_DIAGNOSTIC_RECORD_KIND, UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, ListResources, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-25T12:00:00Z";
const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.update_diagnostics.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.update_diagnostics.idempotency.v1\0";
const IDEMPOTENCY_LEAK_PREFIX: &str = "UPDATE_DIAGNOSTIC_IDEMPOTENCY_LEAK_PREFIX";
const IDEMPOTENCY_LEAK_SUFFIX: &str = "UPDATE_DIAGNOSTIC_IDEMPOTENCY_LEAK_SUFFIX";

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
            &[UPDATE_DIAGNOSTIC_RECORD_KIND],
            &["kind:update_diagnostic_record"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[UPDATE_DIAGNOSTIC_RECORD_KIND],
            &["kind:update_diagnostic_record"],
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
            &[UPDATE_DIAGNOSTIC_RECORD_KIND],
            &["kind:update_diagnostic_record"],
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
        record_update_diagnostic_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            operation_at,
        )
        .await
        .expect("record update diagnostic")
    }

    async fn record_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        record_update_diagnostic_value_at(
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
        list_update_diagnostics_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list update diagnostics")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation =
            self.read_invocation(key, json!({"updateDiagnosticResourceId": resource_id}));
        inspect_update_diagnostics_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect update diagnostic")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation =
            self.read_invocation(key, json!({"updateDiagnosticResourceId": resource_id}));
        inspect_update_diagnostics_value(&self.deps, &invocation, &invocation.payload)
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
            .expect("inspect update diagnostic resource")
            .expect("update diagnostic resource");
        let current = inspection.resource.current_version_id.as_deref();
        inspection
            .versions
            .iter()
            .find(|version| Some(version.version_id.as_str()) == current)
            .expect("current update diagnostic payload")
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
            &[UPDATE_DIAGNOSTIC_RECORD_KIND],
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
async fn record_list_inspect_update_diagnostic_resource_schema_and_lifecycle() {
    let fixture = Fixture::new("update-diagnostics-lifecycle").await;
    let recorded_at = dt("2026-06-25T09:00:00Z");
    let recorded = fixture
        .record_at("record-update", update_payload(), recorded_at)
        .await;
    assert_eq!(recorded["status"], json!("active"));
    assert_eq!(recorded["idempotentReplay"], json!(false));
    let resource_id = recorded["updateDiagnosticResourceId"].as_str().unwrap();

    let stored = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("update diagnostic resource");
    assert_eq!(stored.resource.kind, UPDATE_DIAGNOSTIC_RECORD_KIND);
    assert_eq!(
        stored.resource.schema_id,
        UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID
    );
    assert_eq!(stored.resource.lifecycle, "active");
    assert_eq!(
        stored.versions[0].payload["metadata"]["signedReleaseMetadataOnly"],
        json!(true)
    );
    assert_eq!(
        stored.versions[0].payload["metadata"]["liveNetworkCheckPerformed"],
        json!(false)
    );
    assert_eq!(
        stored.versions[0].payload["metadata"]["packageBytesStored"],
        json!(false)
    );

    let listed = fixture
        .list("list-update", json!({"releaseChannel": "stable"}))
        .await;
    assert_eq!(listed["records"].as_array().unwrap().len(), 1);
    assert_eq!(
        listed["records"][0]["release"]["version"],
        json!("2026.6.25")
    );

    let inspected = fixture.inspect("inspect-update", resource_id).await;
    assert_eq!(
        inspected["record"]["payload"]["createdAt"],
        json!(recorded_at.to_rfc3339())
    );
    assert_eq!(
        inspected["record"]["payload"]["release"]["signatureStatus"],
        json!("verified")
    );
    assert_eq!(
        inspected["record"]["projection"]["rawProductionEndpointReturned"],
        json!(false)
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
            .any(|event| event.topic == "update_diagnostics.lifecycle"
                && event.payload["event"] == json!("update_diagnostics.recorded")
                && event.payload["updateBoundary"]["liveNetworkCheckPerformed"] == json!(false))
    );
}

#[tokio::test]
async fn update_diagnostic_validation_rejects_raw_updater_material_and_secrets() {
    let fixture = Fixture::new("update-diagnostics-validation").await;
    let package_bytes = fixture
        .record_error(
            "raw-package",
            with_field(update_payload(), "packageBytes", json!("base64-package")),
        )
        .await;
    assert!(
        package_bytes.contains("bounded signed-release metadata"),
        "{package_bytes}"
    );

    let endpoint = fixture
        .record_error(
            "raw-endpoint",
            with_field(
                update_payload(),
                "productionEndpoint",
                json!("https://updates.invalid/private"),
            ),
        )
        .await;
    assert!(
        endpoint.contains("bounded signed-release metadata"),
        "{endpoint}"
    );

    let command = fixture
        .record_error(
            "deploy-command",
            with_field(update_payload(), "deployCommand", json!("tron deploy")),
        )
        .await;
    assert!(
        command.contains("bounded signed-release metadata"),
        "{command}"
    );

    let secret_like_context = fixture
        .record_error("authorization:update-diagnostics-secret", update_payload())
        .await;
    assert!(
        secret_like_context.contains("credential-like material"),
        "{secret_like_context}"
    );

    let bad_ref = fixture
        .record_error(
            "bad-ref",
            with_field(
                update_payload(),
                "signatureRefs",
                json!([{"kind": "signature", "id": "../unsafe-path"}]),
            ),
        )
        .await;
    assert!(bad_ref.contains("bounded non-wildcard token"), "{bad_ref}");
}

#[tokio::test]
async fn update_diagnostic_redacted_projections_do_not_leak_raw_payload_or_authority() {
    let fixture = Fixture::new("update-diagnostics-redaction").await;
    let created = fixture.record("redacted-record", update_payload()).await;
    let resource_id = created["updateDiagnosticResourceId"].as_str().unwrap();
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
        &[
            "https://updates.invalid/private",
            "base64-package",
            "installCommand",
            "restartCommand",
            "deployCommand",
            "grantId",
        ],
    );
}

#[tokio::test]
async fn update_diagnostic_projections_truncate_multibyte_utf8_without_panicking() {
    let fixture = Fixture::new("update-diagnostics-utf8-truncation").await;
    let expected_summary = "a".repeat(511);
    let created = fixture
        .record(
            "utf8-truncation-record",
            update_payload_with_summary(format!("{expected_summary}\u{00e9}tail")),
        )
        .await;
    let resource_id = created["updateDiagnosticResourceId"].as_str().unwrap();

    let listed = fixture.list("utf8-truncation-list", json!({})).await;
    let listed_summary = listed["records"][0]["metadata"]["diagnosticSummary"]
        .as_str()
        .unwrap();
    assert_eq!(listed_summary, expected_summary);
    assert!(listed_summary.len() <= 512);

    let inspected = fixture
        .inspect("utf8-truncation-inspect", resource_id)
        .await;
    let inspected_summary = inspected["record"]["payload"]["metadata"]["diagnosticSummary"]
        .as_str()
        .unwrap();
    assert_eq!(inspected_summary, expected_summary);
    assert!(inspected_summary.len() <= 512);
}

#[tokio::test]
async fn update_diagnostic_idempotency_evidence_is_fingerprinted_without_raw_key_leaks() {
    let fixture = Fixture::new("update-diagnostics-idempotency").await;
    let key = id_token_like_idempotency_key("RECORD");
    let mut invocation = fixture.write_invocation(&key, update_payload());
    invocation.id =
        InvocationId::new("invocation-update-diagnostic-record").expect("invocation id");
    invocation.causal_context.trace_id =
        TraceId::new("trace-update-diagnostic-record").expect("trace id");

    let created = record_update_diagnostic_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record update diagnostic with id-token-like key");
    let resource_id = created["updateDiagnosticResourceId"].as_str().unwrap();
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
async fn update_diagnostic_authority_scope_and_replay_are_fail_closed() {
    let fixture = Fixture::new("update-diagnostics-authority").await;
    let read_only = fixture.read_invocation("read-only-record", update_payload());
    let read_only_error = record_update_diagnostic_value_at(
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
        update_payload(),
        wildcard_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let wildcard_error = record_update_diagnostic_value_at(
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
            &["kind:update_diagnostic_record"],
            "declared",
        )
        .await;
    let network = fixture.invocation_with_grant(
        "network-record",
        update_payload(),
        network_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let network_error = record_update_diagnostic_value_at(
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

    let first = fixture.record("same-key", update_payload()).await;
    let replay = fixture.record("same-key", update_payload()).await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    assert_eq!(
        first["updateDiagnosticResourceId"],
        replay["updateDiagnosticResourceId"]
    );

    let resource_id = first["updateDiagnosticResourceId"].as_str().unwrap();
    let other = fixture
        .clone_for_session("update-diagnostics-other-session")
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
            kind: Some(UPDATE_DIAGNOSTIC_RECORD_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources");
    assert_eq!(resources.len(), 1, "replay must not duplicate resources");
}

fn update_payload() -> Value {
    json!({
        "diagnosticId": "update-diagnostic-1",
        "checkKind": "metadata_snapshot",
        "releaseChannel": "stable",
        "releaseVersion": "2026.6.25",
        "releaseBuild": "agent.20260625",
        "diagnosticStatus": "update_available",
        "signatureStatus": "verified",
        "diagnosticLabel": "Signed release metadata",
        "diagnosticSummary": "Bounded update diagnostic metadata without package bytes or live checks.",
        "provenanceSummary": "Signed release provenance metadata only.",
        "sourceRefs": [{"kind": "release_manifest", "id": "manifest-20260625"}],
        "evidenceRefs": [{"kind": "trace", "id": "trace-update-source"}],
        "provenanceRefs": [{"kind": "provenance", "id": "slsa-attestation-20260625"}],
        "signatureRefs": [{"kind": "signature", "id": "sigstore-bundle-20260625"}],
        "maxAgeDays": 45
    })
}

fn update_payload_with_summary(diagnostic_summary: String) -> Value {
    let mut payload = update_payload();
    payload["diagnosticSummary"] = json!(diagnostic_summary);
    payload
}

fn with_field(mut payload: Value, field: &str, value: Value) -> Value {
    payload[field] = value;
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
            grant_id: Some(AuthorityGrantId::new(format!("update-diagnostics-{suffix}")).unwrap()),
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
            budget: json!({"class": "update_diagnostics_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "update_diagnostics_test"}),
            trace_id: TraceId::new(format!("trace-update-diagnostics-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-update-diagnostics")
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
