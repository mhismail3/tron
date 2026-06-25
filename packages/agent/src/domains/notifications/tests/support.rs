use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::super::contract::{
    DEVICE_READ_SCOPE, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE,
};
use super::super::service::{
    inspect_notification_value, list_notifications_value, mark_all_notifications_read_value_at,
    mark_notification_read_value_at, send_notification_value_at,
};
use super::super::{Deps, NOTIFICATION_DELIVERY_KIND, NOTIFICATION_KIND};
use crate::domains::device;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

pub(super) const APNS_TOKEN: &str =
    "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
const DEFAULT_OPERATION_AT: &str = "2026-06-25T12:00:00Z";

pub(super) struct Fixture {
    pub(super) deps: Deps,
    pub(super) device_deps: device::Deps,
    pub(super) session_id: String,
    pub(super) write_grant_id: AuthorityGrantId,
    pub(super) push_write_grant_id: AuthorityGrantId,
    pub(super) read_grant_id: AuthorityGrantId,
    pub(super) device_write_grant_id: AuthorityGrantId,
}

impl Fixture {
    pub(super) async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let device_deps = device::Deps {
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
            &[NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
            &["kind:notification", "kind:notification_delivery"],
            "none",
        )
        .await;
        let push_write_grant_id = derive_grant(
            &deps,
            &format!("{label}-push-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
                DEVICE_READ_SCOPE,
            ],
            &[
                NOTIFICATION_KIND,
                NOTIFICATION_DELIVERY_KIND,
                device::DEVICE_REGISTRATION_KIND,
            ],
            &[
                "kind:notification",
                "kind:notification_delivery",
                "kind:device_registration",
            ],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
            &["kind:notification", "kind:notification_delivery"],
            "none",
        )
        .await;
        let device_write_grant_id = derive_grant(
            &deps,
            &format!("{label}-device-write"),
            &[
                device::contract::WRITE_SCOPE,
                device::contract::RESOURCE_WRITE_SCOPE,
            ],
            &[device::DEVICE_REGISTRATION_KIND],
            &["kind:device_registration"],
            "none",
        )
        .await;
        Self {
            deps,
            device_deps,
            session_id,
            write_grant_id,
            push_write_grant_id,
            read_grant_id,
            device_write_grant_id,
        }
    }

    pub(super) async fn clone_for_session(&self, session_id: &str) -> Self {
        let read_grant_id = self
            .derive_grant(
                &format!("{session_id}-read"),
                &[READ_SCOPE, RESOURCE_READ_SCOPE],
                &[NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
                &["kind:notification", "kind:notification_delivery"],
                "none",
            )
            .await;
        Self {
            deps: self.deps.clone(),
            device_deps: self.device_deps.clone(),
            session_id: session_id.to_owned(),
            write_grant_id: self.write_grant_id.clone(),
            push_write_grant_id: self.push_write_grant_id.clone(),
            read_grant_id,
            device_write_grant_id: self.device_write_grant_id.clone(),
        }
    }

    pub(super) async fn derive_grant(
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

    pub(super) async fn send(&self, key: &str, payload: Value) -> Value {
        self.send_at(key, payload, default_operation_at()).await
    }

    pub(super) async fn send_at(
        &self,
        key: &str,
        payload: Value,
        operation_at: DateTime<Utc>,
    ) -> Value {
        let invocation = self.invocation_with_grant(
            key,
            payload,
            self.write_grant_id.clone(),
            ActorKind::Agent,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
        );
        send_notification_value_at(&self.deps, &invocation, &invocation.payload, operation_at)
            .await
            .expect("send notification")
    }

    pub(super) async fn send_with_push_grant(&self, key: &str, payload: Value) -> Value {
        let invocation = self.invocation_with_grant(
            key,
            payload,
            self.push_write_grant_id.clone(),
            ActorKind::Agent,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
                DEVICE_READ_SCOPE,
            ],
        );
        send_notification_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("send notification")
    }

    pub(super) async fn send_error(&self, key: &str, payload: Value) -> String {
        let invocation = self.invocation_with_grant(
            key,
            payload,
            self.write_grant_id.clone(),
            ActorKind::Agent,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
        );
        send_notification_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("send should fail")
        .to_string()
    }

    pub(super) async fn list(&self, key: &str, payload: Value) -> Value {
        let invocation = self.read_invocation(key, payload);
        list_notifications_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list notifications")
    }

    pub(super) async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"notificationResourceId": resource_id}));
        inspect_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect notification")
    }

    pub(super) async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"notificationResourceId": resource_id}));
        inspect_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    pub(super) async fn mark_read(&self, key: &str, resource_id: &str, version_id: &str) -> Value {
        self.mark_read_at(key, resource_id, version_id, default_operation_at())
            .await
    }

    pub(super) async fn mark_read_at(
        &self,
        key: &str,
        resource_id: &str,
        version_id: &str,
        operation_at: DateTime<Utc>,
    ) -> Value {
        let invocation = self.invocation_with_grant(
            key,
            json!({
                "notificationResourceId": resource_id,
                "expectedNotificationVersionId": version_id,
                "reason": "user read"
            }),
            self.write_grant_id.clone(),
            ActorKind::Agent,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
        );
        mark_notification_read_value_at(&self.deps, &invocation, &invocation.payload, operation_at)
            .await
            .expect("mark read")
    }

    pub(super) async fn mark_all_read(&self, key: &str, payload: Value) -> Value {
        self.mark_all_read_at(key, payload, default_operation_at())
            .await
    }

    pub(super) async fn mark_all_read_at(
        &self,
        key: &str,
        payload: Value,
        operation_at: DateTime<Utc>,
    ) -> Value {
        let invocation = self.invocation_with_grant(
            key,
            payload,
            self.write_grant_id.clone(),
            ActorKind::Agent,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
        );
        mark_all_notifications_read_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            operation_at,
        )
        .await
        .expect("mark all read")
    }

    pub(super) async fn register_device(&self, key: &str, payload: Value) -> Value {
        let invocation = self.device_invocation(key, payload);
        device::service::register_device_value_at(
            &self.device_deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("register device")
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        self.invocation_with_grant(
            key,
            payload,
            self.read_grant_id.clone(),
            ActorKind::Agent,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
        )
    }

    pub(super) fn invocation_with_grant(
        &self,
        key: &str,
        payload: Value,
        grant_id: AuthorityGrantId,
        actor_kind: ActorKind,
        scopes: &[&str],
    ) -> Invocation {
        invocation(key, payload, grant_id, actor_kind, scopes, &self.session_id)
    }

    fn device_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.device_write_grant_id.clone(),
            ActorKind::System,
            &[
                device::contract::WRITE_SCOPE,
                device::contract::RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
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
            grant_id: Some(AuthorityGrantId::new(format!("notifications-{suffix}")).unwrap()),
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
            budget: json!({"class": "notifications_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "notifications_test"}),
            trace_id: TraceId::new(format!("trace-notifications-{suffix}")).unwrap(),
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
    session_id: &str,
) -> Invocation {
    let actor_id = match actor_kind {
        ActorKind::Agent => ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::System => ActorId::new("system:notifications-test").unwrap(),
        ActorKind::Admin => ActorId::new("admin:notifications-test").unwrap(),
        _ => ActorId::new("client:notifications-test").unwrap(),
    };
    let mut context = CausalContext::new(
        actor_id,
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-notifications")
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

pub(super) fn default_operation_at() -> DateTime<Utc> {
    dt(DEFAULT_OPERATION_AT)
}

pub(super) fn dt(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("test timestamp")
        .with_timezone(&Utc)
}

pub(super) fn assert_no_token_fragments<T: serde::Serialize>(label: &str, value: &T, token: &str) {
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
