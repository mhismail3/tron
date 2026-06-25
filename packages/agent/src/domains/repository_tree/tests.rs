use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_repository_tree_value, list_repository_tree_value,
    record_repository_tree_snapshot_value_at,
};
use super::{Deps, REPOSITORY_TREE_SNAPSHOT_KIND, REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, ListResources, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-25T12:00:00Z";
const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.repository_tree.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.repository_tree.idempotency.v1\0";
const IDEMPOTENCY_LEAK_PREFIX: &str = "REPOSITORY_TREE_IDEMPOTENCY_LEAK_PREFIX";
const IDEMPOTENCY_LEAK_SUFFIX: &str = "REPOSITORY_TREE_IDEMPOTENCY_LEAK_SUFFIX";

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
            &[REPOSITORY_TREE_SNAPSHOT_KIND],
            &["kind:repository_tree_snapshot"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[REPOSITORY_TREE_SNAPSHOT_KIND],
            &["kind:repository_tree_snapshot"],
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
            &[REPOSITORY_TREE_SNAPSHOT_KIND],
            &["kind:repository_tree_snapshot"],
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
        record_repository_tree_snapshot_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            operation_at,
        )
        .await
        .expect("record repository tree snapshot")
    }

    async fn record_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        record_repository_tree_snapshot_value_at(
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
        list_repository_tree_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list repository tree snapshots")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation =
            self.read_invocation(key, json!({"repositoryTreeResourceId": resource_id}));
        inspect_repository_tree_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect repository tree snapshot")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation =
            self.read_invocation(key, json!({"repositoryTreeResourceId": resource_id}));
        inspect_repository_tree_value(&self.deps, &invocation, &invocation.payload)
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
            .expect("inspect repository tree resource")
            .expect("repository tree resource");
        let current = inspection.resource.current_version_id.as_deref();
        inspection
            .versions
            .iter()
            .find(|version| Some(version.version_id.as_str()) == current)
            .expect("current repository tree payload")
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
            &[REPOSITORY_TREE_SNAPSHOT_KIND],
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
async fn record_list_inspect_repository_tree_schema_lifecycle_and_projection() {
    let fixture = Fixture::new("repository-tree-lifecycle").await;
    let recorded_at = dt("2026-06-25T09:00:00Z");
    let recorded = fixture
        .record_at("snapshot-tree", tree_payload(), recorded_at)
        .await;
    assert_eq!(recorded["status"], json!("active"));
    assert_eq!(recorded["idempotentReplay"], json!(false));
    let resource_id = recorded["repositoryTreeResourceId"].as_str().unwrap();

    let stored = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("repository tree resource");
    assert_eq!(stored.resource.kind, REPOSITORY_TREE_SNAPSHOT_KIND);
    assert_eq!(
        stored.resource.schema_id,
        REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID
    );
    assert_eq!(stored.resource.lifecycle, "active");
    assert_eq!(
        stored.versions[0].payload["metadata"]["contentFreeSnapshot"],
        json!(true)
    );
    assert_eq!(
        stored.versions[0].payload["metadata"]["rawRepositoryContentsStored"],
        json!(false)
    );
    assert_eq!(
        stored.versions[0].payload["pathEntries"][0]["path"],
        json!("src/lib.rs")
    );

    let listed = fixture.list("list-tree", json!({})).await;
    assert_eq!(listed["records"].as_array().unwrap().len(), 1);
    assert_eq!(listed["records"][0]["counts"]["totalEntries"], json!(3));
    assert_eq!(listed["records"][0]["pathPreview"]["total"], json!(2));

    let inspected = fixture.inspect("inspect-tree", resource_id).await;
    assert_eq!(
        inspected["record"]["payload"]["createdAt"],
        json!(recorded_at.to_rfc3339())
    );
    assert_eq!(
        inspected["record"]["projection"]["contentFreeSnapshot"],
        json!(true)
    );
    assert_no_leaks(
        "inspect response",
        &inspected,
        &["file contents", "/Users/", "grantId"],
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
            .any(|event| event.topic == "repository_tree.lifecycle"
                && event.payload["event"] == json!("repository_tree.recorded")
                && event.payload["repositoryTreeBoundary"]["contentFreeSnapshot"] == json!(true))
    );
}

#[tokio::test]
async fn repository_tree_validation_rejects_raw_contents_unsafe_paths_and_secret_like_tokens() {
    let fixture = Fixture::new("repository-tree-validation").await;
    let raw = fixture
        .record_error(
            "raw-tree",
            with_extra(tree_payload(), "repositoryContents", json!("file contents")),
        )
        .await;
    assert!(raw.contains("bounded metadata only"), "{raw}");

    let absolute = fixture
        .record_error(
            "absolute-path",
            with_path(tree_payload(), "/tmp/private/file.rs"),
        )
        .await;
    assert!(absolute.contains("normalized relative path"), "{absolute}");

    let parent = fixture
        .record_error("parent-path", with_path(tree_payload(), "src/../secret.rs"))
        .await;
    assert!(parent.contains("parent path segments"), "{parent}");

    let secret_like = fixture
        .record_error("authorization:repository-tree-secret", tree_payload())
        .await;
    assert!(
        secret_like.contains("credential-like material"),
        "{secret_like}"
    );
}

#[tokio::test]
async fn repository_tree_idempotency_evidence_is_fingerprinted_without_raw_key_leaks() {
    let fixture = Fixture::new("repository-tree-idempotency").await;
    let key = id_token_like_idempotency_key("SNAPSHOT");
    let mut invocation = fixture.write_invocation(&key, tree_payload());
    invocation.id =
        InvocationId::new("invocation-repository-tree-snapshot").expect("invocation id");
    invocation.causal_context.trace_id =
        TraceId::new("trace-repository-tree-snapshot").expect("trace id");

    let created = record_repository_tree_snapshot_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record repository tree with id-token-like key");
    let resource_id = created["repositoryTreeResourceId"].as_str().unwrap();
    let payload = fixture.raw_current_payload(resource_id).await;
    assert_fingerprinted_idempotency(&payload["idempotency"], &key);

    let listed = fixture.list("idempotency-list", json!({})).await;
    let inspected = fixture.inspect("idempotency-inspect", resource_id).await;
    for (label, value) in [
        ("create response", &created),
        ("raw resource payload", &payload),
        ("list response", &listed),
        ("inspect response", &inspected),
    ] {
        assert_no_idempotency_key_fragments(label, value, &[&key]);
    }
}

#[tokio::test]
async fn repository_tree_authority_scope_replay_and_selector_checks_are_fail_closed() {
    let fixture = Fixture::new("repository-tree-authority").await;
    let read_only = fixture.read_invocation("read-only-record", tree_payload());
    let read_only_error = record_repository_tree_snapshot_value_at(
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
        tree_payload(),
        wildcard_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let wildcard_error = record_repository_tree_snapshot_value_at(
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

    let first = fixture.record("same-key", tree_payload()).await;
    let replay = fixture.record("same-key", tree_payload()).await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    assert_eq!(
        first["repositoryTreeResourceId"],
        replay["repositoryTreeResourceId"]
    );

    let resource_id = first["repositoryTreeResourceId"].as_str().unwrap();
    let other = fixture
        .clone_for_session("repository-tree-other-session")
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
            kind: Some(REPOSITORY_TREE_SNAPSHOT_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources");
    assert_eq!(resources.len(), 1, "replay must not duplicate resources");
}

fn tree_payload() -> Value {
    json!({
        "snapshotId": "repo-tree-snapshot-1",
        "repositoryRef": {"kind": "repository", "id": "repo:primary", "role": "repository"},
        "rootRef": {"kind": "workspace", "id": "workspace:primary", "role": "root"},
        "headRef": {"kind": "commit", "id": "commit:abc123"},
        "treeObjectRef": "tree:abc123",
        "totalEntries": 3,
        "fileCount": 2,
        "directoryCount": 1,
        "maxDepth": 2,
        "pathEntries": [
            {"path": "src/lib.rs", "kind": "file", "mode": "100644", "objectRef": "blob:one", "contentHash": "sha256:one", "sizeBytes": 120},
            {"path": "src/domains", "kind": "directory", "mode": "040000", "objectRef": "tree:two"}
        ],
        "snapshotLabel": "Backend tree snapshot",
        "snapshotSummary": "Content-free repository tree metadata snapshot.",
        "sourceRefs": [{"kind": "git_status", "id": "git_status:source"}],
        "evidenceRefs": [{"kind": "trace", "id": "trace-source"}],
        "maxAgeDays": 45
    })
}

fn with_path(mut payload: Value, path: &str) -> Value {
    payload["pathEntries"][0]["path"] = json!(path);
    payload
}

fn with_extra(mut payload: Value, field: &str, value: Value) -> Value {
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
            grant_id: Some(AuthorityGrantId::new(format!("repository-tree-{suffix}")).unwrap()),
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
            budget: json!({"class": "repository_tree_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "repository_tree_test"}),
            trace_id: TraceId::new(format!("trace-repository-tree-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-repository-tree")
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
        "{label} leaked prefix"
    );
    assert!(
        !serialized.contains(IDEMPOTENCY_LEAK_SUFFIX),
        "{label} leaked suffix"
    );
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
