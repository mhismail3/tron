use serde_json::json;

use super::super::contract::{
    DEVICE_READ_SCOPE, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE,
};
use super::super::service::send_notification_value_at;
use super::super::{NOTIFICATION_DELIVERY_KIND, NOTIFICATION_KIND};
use super::support::{Fixture, default_operation_at};
use crate::engine::ActorKind;

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
    let read_only = send_notification_value_at(
        &fixture.deps,
        &read_only_invocation,
        &read_only_invocation.payload,
        default_operation_at(),
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
    let wildcard = send_notification_value_at(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
        default_operation_at(),
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
