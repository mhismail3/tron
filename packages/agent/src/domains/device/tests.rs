use serde_json::{Value, json};

use super::contract::{
    DEVICE_LIFECYCLE_TOPIC, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE,
};
use super::service::{
    inspect_device_value, list_devices_value, register_device_value, unregister_device_value,
};
use super::{DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, Deps};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, StreamActorScope, StreamCursor, TraceId, VisibilityScope,
};
use crate::shared::server::test_support::make_test_context;

const APNS_TOKEN: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0fedcba9876543210";

#[tokio::test]
async fn register_records_hash_only_token_and_redacted_projection() {
    let fixture = Fixture::new("register").await;
    let registered = fixture.register("register-key", register_payload()).await;
    let resource_id = registered["deviceRegistrationResourceId"].as_str().unwrap();
    assert_eq!(registered["status"], json!("active"));
    assert_eq!(registered["apnsEnvironment"], json!("development"));
    assert_eq!(registered["apnsTokenRedacted"], json!(true));
    assert_eq!(registered["liveApnsEnabled"], json!(false));
    assert_no_token_fragments("register response", &registered, APNS_TOKEN);

    let inspection = fixture
        .deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("device registration");
    assert_eq!(inspection.resource.kind, DEVICE_REGISTRATION_KIND);
    assert_eq!(inspection.resource.schema_id, DEVICE_REGISTRATION_SCHEMA_ID);
    let payload = current_payload(&inspection);
    assert_eq!(payload["apns"]["environment"], json!("development"));
    assert_eq!(payload["apns"]["liveApnsEnabled"], json!(false));
    assert_ne!(payload["apns"]["tokenHash"], json!(APNS_TOKEN));
    assert!(payload["apns"].get("tokenPreview").is_none());
    assert_no_token_fragments("stored device resource", &inspection, APNS_TOKEN);
    let token_hash = payload["apns"]["tokenHash"].as_str().unwrap().to_owned();

    let listed = fixture
        .list("token-redaction-list", json!({"limit": 10}))
        .await;
    assert_no_token_fragments("device list projection", &listed, APNS_TOKEN);
    let list_fingerprint = &listed["devices"][0]["apns"]["tokenFingerprint"];
    assert_eq!(list_fingerprint["redacted"], json!(true));
    assert_eq!(list_fingerprint["rawPreviewReturned"], json!(false));
    assert!(list_fingerprint.get("preview").is_none());
    assert_no_token_fragments(
        "device list token fingerprint",
        list_fingerprint,
        APNS_TOKEN,
    );

    let inspected = fixture.inspect("inspect-key", resource_id).await;
    let projection = serde_json::to_string(&inspected).unwrap();
    assert_eq!(inspected["apnsTokenReturned"], json!(false));
    assert!(projection.contains("tokenFingerprint"));
    assert!(!projection.contains(APNS_TOKEN));
    assert!(!projection.contains(&token_hash));
    assert_no_token_fragments("device inspect projection", &inspected, APNS_TOKEN);
    let inspect_fingerprint = &inspected["device"]["payload"]["apns"]["tokenFingerprint"];
    assert_eq!(inspect_fingerprint["redacted"], json!(true));
    assert_eq!(inspect_fingerprint["rawPreviewReturned"], json!(false));
    assert!(inspect_fingerprint.get("preview").is_none());
    assert_no_token_fragments(
        "device inspect token fingerprint",
        inspect_fingerprint,
        APNS_TOKEN,
    );
    assert_eq!(
        inspected["device"]["projection"]["fullTokenHashReturned"],
        json!(false)
    );

    let lifecycle_events = fixture.device_lifecycle_events().await;
    assert_no_token_fragments(
        "device lifecycle stream events",
        &lifecycle_events,
        APNS_TOKEN,
    );
}

#[tokio::test]
async fn register_requires_explicit_environment_and_push_opt_in() {
    let fixture = Fixture::new("environment").await;
    let missing_environment = fixture
        .register_error(
            "missing-environment",
            json!({"deviceId": "ios-device", "apnsToken": APNS_TOKEN}),
        )
        .await;
    assert!(
        missing_environment.contains("apnsEnvironment"),
        "{missing_environment}"
    );

    let invalid_environment = fixture
        .register_error(
            "invalid-environment",
            json!({
                "deviceId": "ios-device",
                "apnsEnvironment": "sandbox",
                "apnsToken": APNS_TOKEN
            }),
        )
        .await;
    assert!(
        invalid_environment.contains("development or production"),
        "{invalid_environment}"
    );

    let push_without_opt_in = fixture
        .register_error(
            "push-without-opt-in",
            json!({
                "deviceId": "ios-device",
                "apnsEnvironment": "development",
                "apnsToken": APNS_TOKEN,
                "pushEnabled": true
            }),
        )
        .await;
    assert!(
        push_without_opt_in.contains("pushOptIn"),
        "{push_without_opt_in}"
    );
}

#[tokio::test]
async fn unregister_preserves_durable_state_and_default_list_hides_it() {
    let fixture = Fixture::new("unregister").await;
    let registered = fixture
        .register("unregister-register", register_payload())
        .await;
    let resource_id = registered["deviceRegistrationResourceId"].as_str().unwrap();
    let unregistered = fixture
        .unregister("unregister-key", resource_id, "user signed out")
        .await;
    assert_eq!(unregistered["status"], json!("unregistered"));
    assert_eq!(unregistered["apnsTokenRedacted"], json!(true));

    let active_only = fixture.list("list-active", json!({"limit": 10})).await;
    assert_eq!(active_only["devices"].as_array().unwrap().len(), 0);

    let all = fixture
        .list(
            "list-all",
            json!({"limit": 10, "includeUnregistered": true}),
        )
        .await;
    assert_eq!(all["devices"].as_array().unwrap().len(), 1);
    assert_eq!(all["devices"][0]["state"], json!("unregistered"));
}

#[tokio::test]
async fn device_registration_rejects_broad_or_untrusted_authority() {
    let fixture = Fixture::new("authority").await;
    let agent_error = fixture
        .register_error_with_actor("agent-denied", ActorKind::Agent, register_payload())
        .await;
    assert!(agent_error.contains("system/admin"), "{agent_error}");

    let wildcard_grant = fixture
        .derive_grant(
            "wildcard",
            &[WRITE_SCOPE, RESOURCE_WRITE_SCOPE],
            &["*"],
            &["kind:device_registration"],
            "none",
        )
        .await;
    let wildcard_invocation = fixture.write_invocation_with_grant(
        "wildcard-denied",
        register_payload(),
        ActorKind::System,
        wildcard_grant,
        &[WRITE_SCOPE, RESOURCE_WRITE_SCOPE],
        &fixture.session_id,
    );
    let wildcard = register_device_value(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
    )
    .await
    .expect_err("wildcard denied")
    .to_string();
    assert!(wildcard.contains("wildcard"), "{wildcard}");
}

#[tokio::test]
async fn device_reads_are_scoped_to_current_session() {
    let fixture = Fixture::new("scope-a").await;
    let registered = fixture.register("scope-register", register_payload()).await;
    let resource_id = registered["deviceRegistrationResourceId"].as_str().unwrap();
    let other = fixture.clone_for_session("scope-b-session").await;

    let error = other.inspect_error("scope-denied", resource_id).await;
    assert!(error.contains("outside the current scope"), "{error}");
}

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
            &[WRITE_SCOPE, RESOURCE_WRITE_SCOPE],
            &[DEVICE_REGISTRATION_KIND],
            &["kind:device_registration"],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[DEVICE_REGISTRATION_KIND],
            &["kind:device_registration"],
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
        let read_grant_id = self
            .derive_grant(
                &format!("{session_id}-read"),
                &[READ_SCOPE, RESOURCE_READ_SCOPE],
                &[DEVICE_REGISTRATION_KIND],
                &["kind:device_registration"],
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

    async fn register(&self, key: &str, payload: Value) -> Value {
        let invocation = self.write_invocation(key, payload, ActorKind::System);
        register_device_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("register device")
    }

    async fn register_error(&self, key: &str, payload: Value) -> String {
        self.register_error_with_actor(key, ActorKind::System, payload)
            .await
    }

    async fn register_error_with_actor(
        &self,
        key: &str,
        actor_kind: ActorKind,
        payload: Value,
    ) -> String {
        let invocation = self.write_invocation(key, payload, actor_kind);
        register_device_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("register should fail")
            .to_string()
    }

    async fn unregister(&self, key: &str, resource_id: &str, reason: &str) -> Value {
        let invocation = self.write_invocation(
            key,
            json!({"deviceRegistrationResourceId": resource_id, "reason": reason}),
            ActorKind::System,
        );
        unregister_device_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("unregister")
    }

    async fn list(&self, key: &str, payload: Value) -> Value {
        let invocation = self.read_invocation(key, payload);
        list_devices_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list devices")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation =
            self.read_invocation(key, json!({"deviceRegistrationResourceId": resource_id}));
        inspect_device_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect device")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation =
            self.read_invocation(key, json!({"deviceRegistrationResourceId": resource_id}));
        inspect_device_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    async fn device_lifecycle_events(&self) -> Value {
        let subscription_id = format!("device-lifecycle-{}", self.session_id);
        self.deps
            .engine_host
            .subscribe_stream(
                subscription_id.clone(),
                DEVICE_LIFECYCLE_TOPIC.to_owned(),
                StreamCursor(0),
                VisibilityScope::System,
                None,
                None,
            )
            .await
            .expect("subscribe device lifecycle stream");
        let page = self
            .deps
            .engine_host
            .poll_stream(&subscription_id, None, 20, &StreamActorScope::admin())
            .await
            .expect("poll device lifecycle stream");
        json!(page.events)
    }

    fn write_invocation(&self, key: &str, payload: Value, actor_kind: ActorKind) -> Invocation {
        self.write_invocation_with_grant(
            key,
            payload,
            actor_kind,
            self.write_grant_id.clone(),
            &[WRITE_SCOPE, RESOURCE_WRITE_SCOPE],
            &self.session_id,
        )
    }

    fn write_invocation_with_grant(
        &self,
        key: &str,
        payload: Value,
        actor_kind: ActorKind,
        grant_id: AuthorityGrantId,
        scopes: &[&str],
        session_id: &str,
    ) -> Invocation {
        invocation(key, payload, grant_id, actor_kind, scopes, Some(session_id))
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.read_grant_id.clone(),
            ActorKind::Agent,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
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
            grant_id: Some(AuthorityGrantId::new(format!("device-{suffix}")).unwrap()),
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
            budget: json!({"class": "device_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "device_test"}),
            trace_id: TraceId::new(format!("trace-device-{suffix}")).unwrap(),
        })
        .await
        .expect("derive grant");
    grant.grant_id
}

fn invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    actor_kind: ActorKind,
    scopes: &[&str],
    session_id: Option<&str>,
) -> Invocation {
    let actor_id = match actor_kind {
        ActorKind::Agent => ActorId::new(format!("agent:{}", session_id.unwrap())).unwrap(),
        ActorKind::System => ActorId::new("system:device-test").unwrap(),
        ActorKind::Admin => ActorId::new("admin:device-test").unwrap(),
        _ => ActorId::new("client:device-test").unwrap(),
    };
    let mut context = CausalContext::new(
        actor_id,
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-device")
    .with_idempotency_key(key.to_owned());
    if let Some(session_id) = session_id {
        context = context.with_session_id(session_id.to_owned());
    }
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

fn register_payload() -> Value {
    json!({
        "deviceId": "ios-device",
        "platform": "ios",
        "apnsEnvironment": "development",
        "apnsToken": APNS_TOKEN
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

fn assert_no_token_fragments<T: serde::Serialize>(label: &str, value: &T, token: &str) {
    let serialized =
        serde_json::to_string(value).unwrap_or_else(|error| panic!("serialize {label}: {error}"));
    for (fragment_label, fragment) in raw_token_fragments(token) {
        assert!(
            !serialized.contains(&fragment),
            "{label} leaked raw APNs token {fragment_label} fragment `{fragment}`: {serialized}"
        );
    }
}

fn raw_token_fragments(token: &str) -> Vec<(&'static str, String)> {
    let middle = token.chars().skip(16).take(16).collect::<String>();
    vec![
        ("full", token.to_owned()),
        ("prefix", token.chars().take(8).collect()),
        (
            "suffix",
            token
                .chars()
                .rev()
                .take(8)
                .collect::<String>()
                .chars()
                .rev()
                .collect(),
        ),
        ("substring", middle),
        (
            "legacy_preview",
            format!(
                "{}...{}",
                token.chars().take(6).collect::<String>(),
                token
                    .chars()
                    .rev()
                    .take(4)
                    .collect::<String>()
                    .chars()
                    .rev()
                    .collect::<String>()
            ),
        ),
    ]
}
