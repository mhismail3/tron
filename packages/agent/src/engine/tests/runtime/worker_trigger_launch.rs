use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration as StdDuration;

use sha2::{Digest, Sha256};

use super::*;
use crate::engine::runtime::worker_orchestration::{
    WorkerProcessHandle, WorkerProcessStartRequest, WorkerProcessStartResult,
    WorkerProcessStopResult, WorkerProcessSupervisor,
};

#[tokio::test]
async fn worker_trigger_launch_dispatch_issues_stdin_launch_once_and_replays_attempt() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let fake = Arc::new(FakeSupervisor::default());
    handle
        .worker_process_supervisor_registry_for_setup()
        .unwrap()
        .set_supervisor(fake.clone());

    let suffix = "trigger-valid";
    let function_id = "trigger_valid::echo";
    let trigger_id = register_worker_launch_trigger(&handle, suffix).await;
    let refs = create_worker_activation_governance(
        &handle,
        WorkerActivationGovernanceConfig::session(suffix, function_id),
    )
    .await;
    let autostart_id = format!("saawtl-{suffix}-autostart-plan");
    let target_key = "saawtl-trigger-valid-target";
    let issue_key = derived_trigger_issue_key(&autostart_id, &trigger_id, target_key);
    let expected_worker_id = predicted_worker_id(&handle, &refs, &issue_key).await;
    let expected_function = expected_function_for_fixture(&handle, &refs).await;
    let launch_plan_id = create_launch_plan(
        &handle,
        suffix,
        &expected_function,
        LaunchPlanOverrides {
            worker_id: Some(expected_worker_id),
            activation_delivery_mode: Some("stdin_activation_bundle_v1".to_owned()),
        },
    )
    .await;
    create_autostart_plan(&handle, suffix, &trigger_id, &launch_plan_id, &refs).await;

    let launched =
        dispatch_trigger_launch(&handle, &trigger_id, &autostart_id, target_key, "one").await;
    assert_eq!(launched.error, None, "trigger launch failed: {launched:?}");
    assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    let value = launched.value.as_ref().unwrap()["result"].clone();
    assert_eq!(value["status"], "ready_pending");
    assert_eq!(value["processState"], "starting");
    let process_id = value["workerProcessResourceId"].as_str().unwrap();
    let attempt_id = value["triggerLaunchAttemptResourceId"].as_str().unwrap();
    let request = fake.requests.lock().unwrap()[0].clone();
    assert!(request.had_secret_stdin);
    assert_eq!(
        request.startup_timeout_ms, 10000,
        "trigger launch must use the reviewed launch plan timeout"
    );

    let attempt_payload = resource_payload(&handle, attempt_id).await;
    assert_eq!(attempt_payload["status"], "ready_pending");
    assert!(
        !attempt_payload.to_string().contains("workerHello"),
        "attempt audit must not persist activation bundle JSON"
    );
    let process = resource_payload(&handle, process_id).await;
    assert_eq!(
        process["activationHandoff"]["delivery"],
        "stdin_activation_bundle_v1"
    );
    assert_eq!(process["readiness"]["functionRegistered"], false);

    let replay =
        dispatch_trigger_launch(&handle, &trigger_id, &autostart_id, target_key, "two").await;
    assert_eq!(replay.error, None);
    assert_eq!(
        fake.starts.load(Ordering::SeqCst),
        1,
        "same target idempotency key must not start another process"
    );
    assert_eq!(
        replay.value.as_ref().unwrap()["result"]["workerProcessResourceId"],
        json!(process_id)
    );
}

#[tokio::test]
async fn worker_trigger_launch_rejects_direct_calls_and_unreviewed_context() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let result = handle
        .invoke(host_invocation(
            "worker::launch_from_trigger",
            json!({"autostartPlanResourceId": "missing-plan"}),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("grant"),
                trace("worker-trigger-launch-direct"),
            )
            .with_scope("worker.activate")
            .with_scope("worker.launch")
            .with_idempotency_key("direct-key"),
        ))
        .await;
    let error = result.error.expect("direct call should fail");
    assert!(
        error.to_string().contains("trigger causal context"),
        "got {error}"
    );
}

#[tokio::test]
async fn worker_trigger_launch_rejects_wrong_policy_before_issue_or_start() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let fake = Arc::new(FakeSupervisor::default());
    handle
        .worker_process_supervisor_registry_for_setup()
        .unwrap()
        .set_supervisor(fake.clone());

    let suffix = "trigger-policy";
    let function_id = "trigger_policy::echo";
    let trigger_id = register_worker_launch_trigger(&handle, suffix).await;
    let refs = create_worker_activation_governance(
        &handle,
        WorkerActivationGovernanceConfig::session(suffix, function_id),
    )
    .await;
    let autostart_id = format!("saawtl-{suffix}-autostart-plan");
    let target_key = "saawtl-trigger-policy-target";
    let issue_key = derived_trigger_issue_key(&autostart_id, &trigger_id, target_key);
    let expected_worker_id = predicted_worker_id(&handle, &refs, &issue_key).await;
    let expected_function = expected_function_for_fixture(&handle, &refs).await;
    let launch_plan_id = create_launch_plan(
        &handle,
        suffix,
        &expected_function,
        LaunchPlanOverrides {
            worker_id: Some(expected_worker_id),
            activation_delivery_mode: Some("preissued_bundle".to_owned()),
        },
    )
    .await;
    create_autostart_plan(&handle, suffix, &trigger_id, &launch_plan_id, &refs).await;

    let result =
        dispatch_trigger_launch(&handle, &trigger_id, &autostart_id, target_key, "policy").await;
    let error = result.error.expect("non-stdin plan should fail");
    assert!(error.to_string().contains("stdin_activation_bundle_v1"));
    assert_eq!(fake.starts.load(Ordering::SeqCst), 0);
    assert!(
        handle
            .inspect_resource(&format!(
                "worker_trigger_launch_attempt:{}",
                short_test_hash(&format!("{autostart_id}:{trigger_id}:{target_key}"))
            ))
            .await
            .unwrap()
            .is_none(),
        "preflight rejection should not create an attempt"
    );
}

#[derive(Default)]
struct FakeSupervisor {
    starts: AtomicUsize,
    requests: Mutex<Vec<RecordedStartRequest>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecordedStartRequest {
    had_secret_stdin: bool,
    startup_timeout_ms: u128,
}

#[async_trait]
impl WorkerProcessSupervisor for FakeSupervisor {
    async fn start(&self, request: WorkerProcessStartRequest) -> Result<WorkerProcessStartResult> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        let process_id = request.process_resource_id.clone();
        self.requests.lock().unwrap().push(RecordedStartRequest {
            had_secret_stdin: request.secret_stdin.is_some(),
            startup_timeout_ms: request.startup_timeout.as_millis(),
        });
        Ok(WorkerProcessStartResult {
            handle: WorkerProcessHandle {
                supervisor_process_id: process_id.clone(),
                pid: Some(4242),
                pid_fingerprint: format!("fake-{process_id}"),
            },
            stdout_snippet: String::new(),
            stderr_snippet: String::new(),
            output_truncated: false,
        })
    }

    async fn stop(
        &self,
        _handle: WorkerProcessHandle,
        _stop_timeout: StdDuration,
    ) -> Result<WorkerProcessStopResult> {
        Ok(WorkerProcessStopResult {
            status: "stopped".to_owned(),
            exit_code: Some(0),
            stdout_snippet: String::new(),
            stderr_snippet: String::new(),
            output_truncated: false,
        })
    }
}

#[derive(Default)]
struct LaunchPlanOverrides {
    worker_id: Option<String>,
    activation_delivery_mode: Option<String>,
}

async fn register_worker_launch_trigger(handle: &EngineHostHandle, suffix: &str) -> String {
    let trigger_type_id = TriggerTypeId::new(format!("saawtl-trigger-type-{suffix}")).unwrap();
    handle
        .register_trigger_type(
            TriggerTypeDefinition::new(
                trigger_type_id.clone(),
                wid("trigger"),
                "test worker trigger launch",
            ),
            true,
        )
        .await
        .unwrap();
    let trigger_id = TriggerId::new(format!("saawtl-trigger-{suffix}")).unwrap();
    handle
        .register_trigger(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("trigger"),
                trigger_type_id,
                fid("worker::launch_from_trigger"),
                grant("grant"),
            ),
            true,
        )
        .await
        .unwrap();
    trigger_id.to_string()
}

async fn create_launch_plan(
    handle: &EngineHostHandle,
    suffix: &str,
    expected_function: &FunctionDefinition,
    overrides: LaunchPlanOverrides,
) -> String {
    let executable = temp_executable(suffix);
    let digest = file_digest(&executable);
    let plan_id = format!("saawo-{suffix}-launch-plan");
    let result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": plan_id,
                "kind": "worker_launch_plan",
                "scope": "session",
                "sessionId": "session-a",
                "lifecycle": "reviewed",
                "payload": {
                    "status": "reviewed",
                    "expectedWorkerId": overrides
                        .worker_id
                        .unwrap_or_else(|| expected_function.owner_worker.as_str().to_owned()),
                    "expectedFunctionId": expected_function.id.as_str(),
                    "targetVisibility": "session",
                    "scope": {
                        "sessionId": "session-a",
                        "workspaceId": null
                    },
                    "namespace": expected_function.id.namespace(),
                    "executable": {
                        "path": executable.to_string_lossy(),
                        "sha256": digest,
                        "pathPolicy": "absolute_file"
                    },
                    "argv": ["--serve"],
                    "argvAllowlist": ["--serve"],
                    "env": {},
                    "envAllowlist": [
                        "TRON_WORKER_ACTIVATION_RESOURCE_ID",
                        "TRON_WORKER_PORT"
                    ],
                    "cwd": null,
                    "cwdPolicy": "none",
                    "startupTimeoutMs": 10000,
                    "stopTimeoutMs": 5000,
                    "maxLogCaptureBytes": 4096,
                    "activationDeliveryMode": overrides
                        .activation_delivery_mode
                        .unwrap_or_else(|| "stdin_activation_bundle_v1".to_owned()),
                    "governance": {
                        "reviewed": true,
                        "decisionResourceId": format!("saawo-{suffix}-decision"),
                        "evidenceResourceIds": [format!("saawo-{suffix}-evidence")]
                    }
                }
            }),
            mutating_causal(&format!("saawo-{suffix}-plan")).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None, "launch plan create failed: {result:?}");
    format!("saawo-{suffix}-launch-plan")
}

async fn create_autostart_plan(
    handle: &EngineHostHandle,
    suffix: &str,
    trigger_id: &str,
    launch_plan_id: &str,
    refs: &WorkerActivationGovernanceFixture,
) {
    let result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": format!("saawtl-{suffix}-autostart-plan"),
                "kind": "worker_autostart_plan",
                "scope": "session",
                "sessionId": "session-a",
                "lifecycle": "reviewed",
                "payload": {
                    "status": "reviewed",
                    "triggerId": trigger_id,
                    "launchPlanResourceId": launch_plan_id,
                    "functionId": refs.function_id,
                    "candidateResourceId": refs.candidate_resource_id,
                    "decisionResourceId": refs.decision_resource_id,
                    "evidenceResourceIds": refs.evidence_resource_ids,
                    "targetVisibility": refs.target_visibility.as_str(),
                    "activationReason": "reviewed trigger worker launch",
                    "policy": {
                        "deliveryMode": "stdin_activation_bundle_v1",
                        "restartPolicy": "none",
                        "duplicatePolicy": "idempotency_key_replay_v1"
                    }
                }
            }),
            mutating_causal(&format!("saawtl-{suffix}-autostart")).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None, "autostart create failed: {result:?}");
}

async fn dispatch_trigger_launch(
    handle: &EngineHostHandle,
    trigger_id: &str,
    autostart_id: &str,
    target_idempotency_key: &str,
    dispatch_suffix: &str,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "trigger::dispatch",
            json!({
                "triggerId": trigger_id,
                "payload": {
                    "autostartPlanResourceId": autostart_id,
                    "launchReason": "test trigger launch"
                },
                "deliveryMode": "sync",
                "targetIdempotencyKey": target_idempotency_key,
            }),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("grant"),
                trace(&format!("worker-trigger-launch-{dispatch_suffix}")),
            )
            .with_scope("worker.activate")
            .with_scope("worker.launch")
            .with_idempotency_key(format!(
                "dispatch-{target_idempotency_key}-{dispatch_suffix}"
            ))
            .with_session_id("session-a")
            .with_workspace_id("workspace-a"),
        ))
        .await
}

async fn expected_function_for_fixture(
    handle: &EngineHostHandle,
    refs: &WorkerActivationGovernanceFixture,
) -> FunctionDefinition {
    let payload = resource_payload(handle, &refs.candidate_resource_id).await;
    serde_json::from_value(payload["definition"].clone()).unwrap()
}

async fn predicted_worker_id(
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

fn derived_trigger_issue_key(
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

fn temp_executable(suffix: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("tron-saawtl-{suffix}-{}", uuid::Uuid::now_v7()));
    std::fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
    path
}

fn file_digest(path: &Path) -> String {
    let bytes = std::fs::read(path).unwrap();
    hex::encode(Sha256::digest(bytes))
}

fn short_test_hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
        .chars()
        .take(16)
        .collect()
}
