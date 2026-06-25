use serde_json::{Value, json};

use super::contract::{
    DEVICE_READ_SCOPE, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE,
};
use super::service::{
    inspect_notification_value, list_notifications_value, mark_all_notifications_read_value,
    mark_notification_read_value, send_notification_value,
};
use super::{Deps, NOTIFICATION_DELIVERY_KIND, NOTIFICATION_KIND};
use crate::domains::device;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

const APNS_TOKEN: &str = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

#[tokio::test]
async fn send_list_and_read_update_badge_state_and_replay_refs() {
    let fixture = Fixture::new("badge").await;
    let first = fixture
        .send(
            "send-one",
            json!({
                "title": "First",
                "body": "First body",
                "family": "approval",
                "sourceRefs": [{"kind": "trace", "id": "source-one"}]
            }),
        )
        .await;
    assert_eq!(first["status"], json!("unread"));
    assert_eq!(first["badgeCount"], json!(1));
    assert_eq!(
        first["delivery"]["records"][0]["state"],
        json!("inbox_only")
    );
    assert_eq!(
        first["delivery"]["records"][0]["push"]["liveApnsAttempted"],
        json!(false)
    );
    let first_resource_id = first["notificationResourceId"].as_str().unwrap();
    let first_version_id = first["notificationVersionId"].as_str().unwrap();

    let second = fixture
        .send(
            "send-two",
            json!({"title": "Second", "body": "Second body", "family": "web"}),
        )
        .await;
    assert_eq!(second["badgeCount"], json!(2));

    let listed = fixture.list("list-unread", json!({"limit": 10})).await;
    assert_eq!(listed["badgeCount"], json!(2));
    assert_eq!(listed["notifications"].as_array().unwrap().len(), 2);

    let inspected = fixture.inspect("inspect-first", first_resource_id).await;
    assert_eq!(
        inspected["notification"]["payload"]["retention"]["maxAgeDays"],
        json!(90)
    );
    assert_eq!(
        inspected["notification"]["payload"]["retention"]["maxInboxRecords"],
        json!(500)
    );
    assert_eq!(
        inspected["notification"]["payload"]["traceRefs"]["total"],
        json!(1)
    );
    assert_eq!(
        inspected["notification"]["payload"]["replayRefs"]["total"],
        json!(1)
    );
    assert_eq!(
        inspected["notification"]["deliveries"][0]["state"],
        json!("inbox_only")
    );

    let read = fixture
        .mark_read("read-first", first_resource_id, first_version_id)
        .await;
    assert_eq!(read["status"], json!("read"));
    assert_eq!(read["badgeCount"], json!(1));

    let after_read = fixture.list("list-after-read", json!({"limit": 10})).await;
    assert_eq!(after_read["notifications"].as_array().unwrap().len(), 1);
    assert_eq!(after_read["badgeCount"], json!(1));

    let all_read = fixture
        .mark_all_read("read-all", json!({"reason": "clear inbox"}))
        .await;
    assert_eq!(all_read["updatedCount"], json!(1));
    assert_eq!(all_read["badgeCount"], json!(0));

    let include_read = fixture
        .list(
            "list-include-read",
            json!({"limit": 10, "includeRead": true}),
        )
        .await;
    assert_eq!(include_read["notifications"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn push_requested_records_failure_evidence_without_live_apns() {
    let no_device = Fixture::new("push-no-device").await;
    let no_device_sent = no_device
        .send_with_push_grant(
            "push-no-device",
            json!({
                "title": "Push no device",
                "body": "No active device",
                "family": "approval",
                "pushRequested": true
            }),
        )
        .await;
    assert_eq!(
        no_device_sent["delivery"]["records"][0]["state"],
        json!("skipped_no_device")
    );

    let disabled = Fixture::new("push-disabled").await;
    disabled
        .register_device(
            "push-disabled-device",
            json!({
                "deviceId": "ios-disabled",
                "platform": "ios",
                "apnsEnvironment": "production",
                "apnsToken": APNS_TOKEN
            }),
        )
        .await;
    let disabled_sent = disabled
        .send_with_push_grant(
            "push-disabled-send",
            json!({
                "title": "Push disabled",
                "body": "Device policy disabled",
                "family": "approval",
                "pushRequested": true
            }),
        )
        .await;
    assert_eq!(
        disabled_sent["delivery"]["records"][0]["state"],
        json!("skipped_policy_disabled")
    );

    let transport = Fixture::new("push-transport").await;
    transport
        .register_device(
            "push-transport-device",
            json!({
                "deviceId": "ios-transport",
                "platform": "ios",
                "apnsEnvironment": "production",
                "apnsToken": APNS_TOKEN,
                "pushOptIn": true,
                "pushEnabled": true,
                "eventFamilies": ["approval"]
            }),
        )
        .await;
    let transport_sent = transport
        .send_with_push_grant(
            "push-transport-send",
            json!({
                "title": "Push transport",
                "body": "Transport disabled",
                "family": "approval",
                "pushRequested": true
            }),
        )
        .await;
    let delivery = &transport_sent["delivery"]["records"][0];
    assert_eq!(delivery["state"], json!("skipped_transport_disabled"));
    assert_eq!(delivery["apnsEnvironment"], json!("production"));
    assert_eq!(delivery["push"]["liveApnsEnabled"], json!(false));
    assert_eq!(delivery["push"]["liveApnsAttempted"], json!(false));
    let projected = serde_json::to_string(delivery).unwrap();
    assert!(!projected.contains(APNS_TOKEN));
}

#[tokio::test]
async fn notification_authority_requires_exact_scopes_and_selectors() {
    let fixture = Fixture::new("authority").await;
    let read_only_invocation = fixture.invocation_with_grant(
        "read-only-send",
        json!({"title": "Denied", "body": "Denied"}),
        fixture.read_grant_id.clone(),
        ActorKind::Agent,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
    );
    let read_only = send_notification_value(
        &fixture.deps,
        &read_only_invocation,
        &read_only_invocation.payload,
    )
    .await
    .expect_err("read-only denied")
    .to_string();
    assert!(read_only.contains(WRITE_SCOPE), "{read_only}");

    let wildcard_grant = fixture
        .derive_grant(
            "wildcard",
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
            &["kind:*"],
            "none",
        )
        .await;
    let wildcard_invocation = fixture.invocation_with_grant(
        "wildcard-send",
        json!({"title": "Denied", "body": "Denied"}),
        wildcard_grant,
        ActorKind::Agent,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
    );
    let wildcard = send_notification_value(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
    )
    .await
    .expect_err("wildcard denied")
    .to_string();
    assert!(wildcard.contains("broad resource selector"), "{wildcard}");

    let push_without_device_read = fixture
        .send_error(
            "push-no-device-read",
            json!({
                "title": "Denied",
                "body": "Denied",
                "pushRequested": true
            }),
        )
        .await;
    assert!(
        push_without_device_read.contains(DEVICE_READ_SCOPE),
        "{push_without_device_read}"
    );
}

#[tokio::test]
async fn notification_reads_are_scoped_to_current_session() {
    let fixture = Fixture::new("scope-a").await;
    let sent = fixture
        .send(
            "scope-send",
            json!({"title": "Scoped", "body": "Scoped body"}),
        )
        .await;
    let resource_id = sent["notificationResourceId"].as_str().unwrap();
    let other = fixture.clone_for_session("scope-b-session").await;

    let error = other.inspect_error("scope-denied", resource_id).await;
    assert!(error.contains("outside the current scope"), "{error}");
}

struct Fixture {
    deps: Deps,
    device_deps: device::Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    push_write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
    device_write_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
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

    async fn clone_for_session(&self, session_id: &str) -> Self {
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

    async fn send(&self, key: &str, payload: Value) -> Value {
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
        send_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("send notification")
    }

    async fn send_with_push_grant(&self, key: &str, payload: Value) -> Value {
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
        send_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("send notification")
    }

    async fn send_error(&self, key: &str, payload: Value) -> String {
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
        send_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("send should fail")
            .to_string()
    }

    async fn list(&self, key: &str, payload: Value) -> Value {
        let invocation = self.read_invocation(key, payload);
        list_notifications_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("list notifications")
    }

    async fn inspect(&self, key: &str, resource_id: &str) -> Value {
        let invocation = self.read_invocation(key, json!({"notificationResourceId": resource_id}));
        inspect_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("inspect notification")
    }

    async fn inspect_error(&self, key: &str, resource_id: &str) -> String {
        let invocation = self.read_invocation(key, json!({"notificationResourceId": resource_id}));
        inspect_notification_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect_err("inspect should fail")
            .to_string()
    }

    async fn mark_read(&self, key: &str, resource_id: &str, version_id: &str) -> Value {
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
        mark_notification_read_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("mark read")
    }

    async fn mark_all_read(&self, key: &str, payload: Value) -> Value {
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
        mark_all_notifications_read_value(&self.deps, &invocation, &invocation.payload)
            .await
            .expect("mark all read")
    }

    async fn register_device(&self, key: &str, payload: Value) -> Value {
        let invocation = self.device_invocation(key, payload);
        device::service::register_device_value(&self.device_deps, &invocation, &invocation.payload)
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

    fn invocation_with_grant(
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
