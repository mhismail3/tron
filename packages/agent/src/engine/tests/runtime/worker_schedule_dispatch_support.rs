use std::path::{Path, PathBuf};

use chrono::{DateTime, TimeZone};
use sha2::{Digest, Sha256};

use super::*;
use crate::engine::durability::resources::ListResources;

pub(super) async fn expected_function_for_fixture(
    handle: &EngineHostHandle,
    refs: &WorkerActivationGovernanceFixture,
) -> FunctionDefinition {
    let payload = resource_payload(handle, &refs.candidate_resource_id).await;
    serde_json::from_value(payload["definition"].clone()).unwrap()
}

pub(super) async fn predicted_worker_id(
    handle: &EngineHostHandle,
    refs: &WorkerActivationGovernanceFixture,
    issue_idempotency_key: &str,
) -> String {
    let expected_function = expected_function_for_fixture(handle, refs).await;
    let governance_fingerprint = hex::encode(Sha256::digest(
        serde_json::to_vec(&json!({
            "version": 1,
            "functionId": refs.function_id,
            "targetVisibility": refs.target_visibility.as_str(),
            "workspaceId": refs.workspace_id,
            "candidateResourceId": refs.candidate_resource_id,
            "decisionResourceId": refs.decision_resource_id,
            "evidenceResourceIds": refs.evidence_resource_ids,
            "expectedFunctionDefinition": expected_function,
        }))
        .unwrap(),
    ));
    let seed = format!(
        "{}:{}:{}:{}:{}:{}",
        refs.function_id,
        refs.candidate_resource_id,
        refs.decision_resource_id,
        refs.target_visibility.as_str(),
        issue_idempotency_key,
        governance_fingerprint
    );
    format!("worker-activation:{}", short_test_hash(&seed))
}

async fn resource_payload(handle: &EngineHostHandle, resource_id: &str) -> Value {
    let inspection = handle
        .inspect_resource(resource_id)
        .await
        .unwrap()
        .expect("resource should exist");
    let current = inspection.resource.current_version_id.as_ref().unwrap();
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .unwrap()
        .payload
        .clone()
}

pub(super) async fn tick_payloads_for_schedule(
    handle: &EngineHostHandle,
    schedule_id: &str,
) -> Vec<Value> {
    let resources = handle
        .list_resources(ListResources {
            kind: Some("worker_schedule_tick".to_owned()),
            limit: 500,
            ..ListResources::default()
        })
        .await
        .unwrap();
    let mut payloads = Vec::new();
    for resource in resources {
        let payload = resource_payload(handle, &resource.resource_id).await;
        if payload["scheduleId"] == schedule_id {
            payloads.push(payload);
        }
    }
    payloads
}

pub(super) async fn queue_count(handle: &EngineHostHandle) -> usize {
    handle
        .replay_snapshot("session-a")
        .await
        .unwrap()
        .queue_items
        .len()
}

pub(super) async fn activation_count(handle: &EngineHostHandle) -> usize {
    handle
        .list_resources(ListResources {
            kind: Some("worker_activation".to_owned()),
            limit: 500,
            ..ListResources::default()
        })
        .await
        .unwrap()
        .len()
}

pub(super) fn schedule_payload(
    schedule_id: &str,
    trigger_id: &str,
    autostart_id: &str,
    anchor: DateTime<Utc>,
) -> Value {
    json!({
        "status": "reviewed",
        "scheduleId": schedule_id,
        "triggerId": trigger_id,
        "autostartPlanResourceId": autostart_id,
        "anchorAtUtc": anchor.to_rfc3339(),
        "intervalMs": 60_000,
        "missedTickPolicy": "skip_missed_ticks_v1",
        "overlapPolicy": "single_active_tick_v1",
        "duplicatePolicy": "tick_idempotency_replay_v1"
    })
}

pub(super) trait JsonEdit {
    fn with(self, field: &str, value: Value) -> Value;
    fn without(self, field: &str) -> Value;
}

impl JsonEdit for Value {
    fn with(mut self, field: &str, value: Value) -> Value {
        self[field] = value;
        self
    }

    fn without(mut self, field: &str) -> Value {
        self.as_object_mut().unwrap().remove(field);
        self
    }
}

pub(super) fn assert_safe_tick_payload(payload: &Value) {
    let text = payload.to_string();
    for forbidden in [
        "activationBundle",
        "workerHello",
        "stdinPayload",
        "processEnv",
        "api_key",
        "bearer",
        "password",
        "saawsd:target:",
    ] {
        assert!(
            !text.contains(forbidden),
            "tick audit persisted forbidden material {forbidden}: {text}"
        );
    }
}

pub(super) fn base_time() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 6, 10, 12, 0, 0).unwrap()
}

pub(super) fn schedule_target_key(schedule_id: &str, nominal_tick_at_utc: DateTime<Utc>) -> String {
    format!(
        "saawsd:target:{schedule_id}:{}",
        nominal_tick_at_utc.to_rfc3339()
    )
}

pub(super) fn derived_trigger_issue_key(
    autostart_plan_resource_id: &str,
    trigger_id: &str,
    target_idempotency_key: &str,
) -> String {
    let attempt_id = format!(
        "worker_trigger_launch_attempt:{}",
        short_test_hash(&format!(
            "{autostart_plan_resource_id}:{trigger_id}:{target_idempotency_key}"
        ))
    );
    format!("saawtl:issue:{attempt_id}")
}

pub(super) fn temp_executable(suffix: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("tron-saawsd-{suffix}-{}", uuid::Uuid::now_v7()));
    std::fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
    path
}

pub(super) fn file_digest(path: &Path) -> String {
    let bytes = std::fs::read(path).unwrap();
    hex::encode(Sha256::digest(bytes))
}

fn short_test_hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
        .chars()
        .take(16)
        .collect()
}
