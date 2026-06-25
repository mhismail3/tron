use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    archive_media_value_at, create_media_value_at, inspect_media_value, list_media_value,
};
use super::{Deps, MEDIA_ARTIFACT_KIND, MEDIA_ARTIFACT_SCHEMA_ID};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, ListResources, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-25T12:00:00Z";
const RAW_AUDIO_SENTINEL: &str = "RAW_AUDIO_BASE64_SENTINEL_SHOULD_NOT_LEAK";

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
            &[MEDIA_ARTIFACT_KIND],
            &["kind:media_artifact"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[MEDIA_ARTIFACT_KIND],
            &["kind:media_artifact"],
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
            &[MEDIA_ARTIFACT_KIND],
            &["kind:media_artifact"],
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

    async fn create(&self, key: &str, payload: Value) -> Value {
        self.create_at(key, payload, default_operation_at()).await
    }

    async fn create_at(&self, key: &str, payload: Value, operation_at: DateTime<Utc>) -> Value {
        let invocation = self.write_invocation(key, payload);
        create_media_value_at(&self.deps, &invocation, &invocation.payload, operation_at)
            .await
            .expect("create media")
    }

    async fn create_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.write_invocation(key, payload);
        create_media_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("create should fail")
        .to_string()
    }

    async fn list(&self, key: &str, payload: Value) -> Value {
        let invocation = self.read_invocation(key, payload);
        list_media_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list media")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"mediaResourceId": resource_id}));
        inspect_media_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect media")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"mediaResourceId": resource_id}));
        inspect_media_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    async fn archive_at(
        &self,
        key: &str,
        resource_id: &str,
        version_id: &str,
        operation_at: DateTime<Utc>,
    ) -> Value {
        let invocation = self.write_invocation(
            key,
            json!({
                "mediaResourceId": resource_id,
                "expectedMediaVersionId": version_id,
                "reason": "retention cleanup"
            }),
        );
        archive_media_value_at(&self.deps, &invocation, &invocation.payload, operation_at)
            .await
            .expect("archive media")
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
            &[MEDIA_ARTIFACT_KIND],
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
async fn create_list_inspect_archive_media_resource_schema_and_lifecycle() {
    let fixture = Fixture::new("media-lifecycle").await;
    let created_at = dt("2026-06-25T09:00:00Z");
    let archived_at = dt("2026-06-25T10:00:00Z");
    let created = fixture
        .create_at("create-voice", voice_note_payload(), created_at)
        .await;
    assert_eq!(created["status"], json!("active"));
    assert_eq!(created["idempotentReplay"], json!(false));
    let resource_id = created["mediaResourceId"].as_str().unwrap();
    let version_id = created["mediaVersionId"].as_str().unwrap();

    let stored = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("media resource");
    assert_eq!(stored.resource.kind, MEDIA_ARTIFACT_KIND);
    assert_eq!(stored.resource.schema_id, MEDIA_ARTIFACT_SCHEMA_ID);
    assert_eq!(stored.resource.lifecycle, "active");
    assert_eq!(stored.versions[0].locations[0].kind, "blob");
    assert_eq!(
        stored.versions[0].payload["storage"]["blobRef"],
        json!("blob:voice-1")
    );
    assert_eq!(
        stored.versions[0].payload["storage"]["rawBytesStoredInResource"],
        json!(false)
    );
    assert_eq!(
        stored.versions[0].payload["retention"]["maxAgeDays"],
        json!(30)
    );

    let listed = fixture
        .list("list-voice", json!({"mediaKind": "voice_note"}))
        .await;
    assert_eq!(listed["media"].as_array().unwrap().len(), 1);
    assert_eq!(
        listed["media"][0]["storage"]["providerVisibleRawAudio"],
        json!(false)
    );

    let inspected = fixture.inspect("inspect-voice", resource_id).await;
    assert_eq!(
        inspected["media"]["payload"]["createdAt"],
        json!(created_at.to_rfc3339())
    );
    assert_eq!(
        inspected["media"]["payload"]["traceRefs"]["total"],
        json!(1)
    );
    assert_eq!(
        inspected["media"]["payload"]["replayRefs"]["total"],
        json!(1)
    );
    assert_eq!(
        inspected["media"]["projection"]["rawAudioReturned"],
        json!(false)
    );

    let archived = fixture
        .archive_at("archive-voice", resource_id, version_id, archived_at)
        .await;
    assert_eq!(archived["status"], json!("archived"));
    let archived_inspection = fixture.inspect("inspect-archived", resource_id).await;
    assert_eq!(
        archived_inspection["media"]["payload"]["updatedAt"],
        json!(archived_at.to_rfc3339())
    );
    assert_eq!(
        archived_inspection["media"]["payload"]["archivedAt"],
        json!(archived_at.to_rfc3339())
    );

    let active_list = fixture.list("list-active", json!({})).await;
    assert_eq!(active_list["media"].as_array().unwrap().len(), 0);
    let archived_list = fixture
        .list("list-archived", json!({"includeArchived": true}))
        .await;
    assert_eq!(archived_list["media"].as_array().unwrap().len(), 1);

    let streams = fixture
        .deps
        .engine_host
        .replay_snapshot(&fixture.session_id)
        .await
        .expect("snapshot")
        .streams;
    assert!(streams.iter().any(|event| event.topic == "media.lifecycle"
        && event.payload["event"] == json!("media.created")));
    assert!(streams.iter().any(|event| event.topic == "media.lifecycle"
        && event.payload["event"] == json!("media.archived")));
}

#[tokio::test]
async fn media_validation_rejects_raw_audio_disallowed_mime_and_oversize() {
    let fixture = Fixture::new("media-validation").await;
    let raw = fixture
        .create_error(
            "raw-audio",
            json!({
                "mediaKind": "voice_note",
                "mimeType": "audio/wav",
                "sizeBytes": 12,
                "blobRef": "blob:raw",
                "audioBase64": RAW_AUDIO_SENTINEL
            }),
        )
        .await;
    assert!(raw.contains("blob refs only"), "{raw}");

    let mime = fixture
        .create_error(
            "bad-mime",
            json!({
                "mediaKind": "voice_note",
                "mimeType": "video/mp4",
                "sizeBytes": 12,
                "blobRef": "blob:bad-mime"
            }),
        )
        .await;
    assert!(mime.contains("not allowed"), "{mime}");

    let oversize = fixture
        .create_error(
            "oversize",
            json!({
                "mediaKind": "voice_note",
                "mimeType": "audio/wav",
                "sizeBytes": 157286401_u64,
                "blobRef": "blob:oversize"
            }),
        )
        .await;
    assert!(oversize.contains("exceeds limit"), "{oversize}");
}

#[tokio::test]
async fn media_redacted_projections_do_not_leak_raw_audio_or_full_payload() {
    let fixture = Fixture::new("media-redaction").await;
    let created = fixture
        .create(
            "redacted-create",
            json!({
                "mediaKind": "voice_note",
                "mimeType": "audio/wav",
                "sizeBytes": 4096,
                "blobRef": "blob:redacted",
                "mediaId": "redacted-voice",
                "title": "Redacted Voice",
                "transcriptionState": "local_completed",
                "transcriptionText": "hello from local composer transcription",
                "sourceRefs": [{"kind": "test", "id": "source-redacted"}]
            }),
        )
        .await;
    let resource_id = created["mediaResourceId"].as_str().unwrap();
    let inspected = fixture.inspect("redacted-inspect", resource_id).await;
    assert_eq!(
        inspected["media"]["payload"]["transcription"]["hasText"],
        json!(true)
    );
    assert_eq!(
        inspected["media"]["payload"]["transcription"]["rawAudioProviderBoundary"],
        json!("not_sent")
    );
    assert_no_raw_audio_fragments("create response", &created);
    assert_no_raw_audio_fragments("inspect response", &inspected);
    assert!(
        inspected["media"]["payload"].get("idempotency").is_none(),
        "inspect projection must not return raw payload"
    );
}

#[tokio::test]
async fn media_authority_requires_exact_scopes_selectors_and_none_network() {
    let fixture = Fixture::new("media-authority").await;
    let read_only = fixture.read_invocation("read-only-create", voice_note_payload());
    let read_only_error = create_media_value_at(
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
        "wildcard-create",
        voice_note_payload(),
        wildcard_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let wildcard_error = create_media_value_at(
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
            &["kind:media_artifact"],
            "declared",
        )
        .await;
    let network = fixture.invocation_with_grant(
        "network-create",
        voice_note_payload(),
        network_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let network_error = create_media_value_at(
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
}

#[tokio::test]
async fn media_scope_isolation_and_idempotent_replay_are_enforced() {
    let fixture = Fixture::new("media-scope-a").await;
    let first = fixture.create("same-key", voice_note_payload()).await;
    let replay = fixture.create("same-key", voice_note_payload()).await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    assert_eq!(first["mediaResourceId"], replay["mediaResourceId"]);
    assert_eq!(first["mediaVersionId"], replay["mediaVersionId"]);

    let resource_id = first["mediaResourceId"].as_str().unwrap();
    let other = fixture.clone_for_session("media-scope-b-session").await;
    let error = other.inspect_error("scope-denied", resource_id).await;
    assert!(error.contains("outside the current scope"), "{error}");

    let resources = fixture
        .deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MEDIA_ARTIFACT_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources");
    assert_eq!(
        resources.len(),
        1,
        "idempotent replay must not duplicate resources"
    );
}

fn voice_note_payload() -> Value {
    json!({
        "mediaKind": "voice_note",
        "mimeType": "audio/wav",
        "sizeBytes": 4096,
        "blobRef": "blob:voice-1",
        "mediaId": "voice-note-1",
        "title": "Voice Note",
        "summary": "A bounded media artifact",
        "durationMs": 1200,
        "maxAgeDays": 30,
        "transcriptionState": "local_completed",
        "transcriptionText": "hello from local composer transcription",
        "transcriptionLanguage": "en",
        "transcriptionModel": "parakeet-tdt-0.6b-v3",
        "sourceRefs": [{"kind": "session", "id": "source-session"}],
        "evidenceRefs": [{"kind": "trace", "id": "trace-source"}]
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
            grant_id: Some(AuthorityGrantId::new(format!("media-{suffix}")).unwrap()),
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
            budget: json!({"class": "media_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "media_test"}),
            trace_id: TraceId::new(format!("trace-media-{suffix}")).unwrap(),
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
    .with_workspace_id("workspace-media")
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

fn assert_no_raw_audio_fragments<T: serde::Serialize>(label: &str, value: &T) {
    let serialized =
        serde_json::to_string(value).unwrap_or_else(|error| panic!("serialize {label}: {error}"));
    for forbidden in [
        RAW_AUDIO_SENTINEL,
        "audioBase64",
        "mediaBase64",
        "rawBytesStoredInResource\":true",
        "providerVisibleRawAudio\":true",
        "rawAudioReturned\":true",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "{label} leaked forbidden media material `{forbidden}`: {serialized}"
        );
    }
}
