use serde_json::json;

use super::support::{APNS_TOKEN, Fixture, assert_no_token_fragments, dt};

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
    assert_eq!(
        delivery["push"]["tokenFingerprint"]["redacted"],
        json!(true)
    );
    assert!(
        delivery["push"]["tokenFingerprint"]
            .get("preview")
            .is_none()
    );
    assert_no_token_fragments("notification send delivery response", delivery, APNS_TOKEN);
    assert_no_token_fragments(
        "notification send provider response",
        &transport_sent,
        APNS_TOKEN,
    );

    let inspected_transport = transport
        .inspect(
            "push-transport-inspect",
            transport_sent["notificationResourceId"].as_str().unwrap(),
        )
        .await;
    assert_no_token_fragments(
        "notification inspect delivery evidence",
        &inspected_transport,
        APNS_TOKEN,
    );
}

#[tokio::test]
async fn notification_timestamps_use_injected_operation_time() {
    let fixture = Fixture::new("timestamps").await;
    let sent_at = dt("2026-06-25T09:00:00Z");
    let read_at = dt("2026-06-25T09:05:00Z");
    let second_sent_at = dt("2026-06-25T09:10:00Z");
    let all_read_at = dt("2026-06-25T09:15:00Z");

    let first = fixture
        .send_at(
            "timestamps-send",
            json!({"title": "Timed", "body": "Timed body", "family": "approval"}),
            sent_at,
        )
        .await;
    let first_resource_id = first["notificationResourceId"].as_str().unwrap();
    let first_version_id = first["notificationVersionId"].as_str().unwrap();
    assert_eq!(
        first["delivery"]["records"][0]["createdAt"],
        json!(sent_at.to_rfc3339())
    );

    let inspected = fixture
        .inspect("timestamps-inspect", first_resource_id)
        .await;
    assert_eq!(
        inspected["notification"]["payload"]["createdAt"],
        json!(sent_at.to_rfc3339())
    );
    assert_eq!(
        inspected["notification"]["payload"]["updatedAt"],
        json!(sent_at.to_rfc3339())
    );

    fixture
        .mark_read_at(
            "timestamps-read",
            first_resource_id,
            first_version_id,
            read_at,
        )
        .await;
    let inspected = fixture
        .inspect("timestamps-inspect-read", first_resource_id)
        .await;
    assert_eq!(
        inspected["notification"]["payload"]["updatedAt"],
        json!(read_at.to_rfc3339())
    );
    assert_eq!(
        inspected["notification"]["payload"]["readState"]["readAt"],
        json!(read_at.to_rfc3339())
    );

    let second = fixture
        .send_at(
            "timestamps-send-second",
            json!({"title": "Timed second", "body": "Timed second body"}),
            second_sent_at,
        )
        .await;
    let second_resource_id = second["notificationResourceId"].as_str().unwrap();
    fixture
        .mark_all_read_at(
            "timestamps-all-read",
            json!({"reason": "deterministic test"}),
            all_read_at,
        )
        .await;
    let inspected = fixture
        .inspect("timestamps-inspect-all-read", second_resource_id)
        .await;
    assert_eq!(
        inspected["notification"]["payload"]["createdAt"],
        json!(second_sent_at.to_rfc3339())
    );
    assert_eq!(
        inspected["notification"]["payload"]["updatedAt"],
        json!(all_read_at.to_rfc3339())
    );
    assert_eq!(
        inspected["notification"]["payload"]["readState"]["readAt"],
        json!(all_read_at.to_rfc3339())
    );
}
