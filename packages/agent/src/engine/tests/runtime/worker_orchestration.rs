use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration as StdDuration;

use sha2::{Digest, Sha256};

use super::external_worker_helpers::EchoExternalInvoker;
use super::*;
use crate::engine::runtime::worker_orchestration::{
    WorkerProcessHandle, WorkerProcessStartRequest, WorkerProcessStartResult,
    WorkerProcessStopResult, WorkerProcessSupervisor,
};

#[tokio::test]
async fn worker_orchestration_launch_replay_ready_invoke_and_stop_are_governed() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let fake = Arc::new(FakeSupervisor::default());
    handle
        .worker_process_supervisor_registry_for_setup()
        .unwrap()
        .set_supervisor(fake.clone());

    let (activation_id, hello, expected_function) =
        issued_activation_bundle(&handle, "orch-valid", "orchestrated_valid::echo").await;
    let plan_id = create_launch_plan(
        &handle,
        "orch-valid",
        &activation_id,
        &expected_function,
        LaunchPlanOverrides::default(),
    )
    .await;
    let launch_key = "saawo-valid-launch";
    let launched = launch_activation(&handle, &activation_id, &plan_id, launch_key).await;
    assert_eq!(launched.error, None, "launch failed: {launched:?}");
    let value = launched.value.as_ref().unwrap();
    let process_id = value["workerProcessResourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    assert_eq!(
        fake.requests.lock().unwrap()[0]
            .env
            .get("TRON_WORKER_ACTIVATION_RESOURCE_ID"),
        Some(&activation_id)
    );
    assert_eq!(
        process_status(&handle, &process_id).await,
        "starting",
        "launch must not mark the process ready"
    );
    let starting_payload = process_payload(&handle, &process_id).await;
    assert!(
        !starting_payload
            .to_string()
            .contains("activation-token-secret"),
        "worker_process must not persist secret-bearing supervisor output"
    );
    assert_eq!(
        starting_payload["logs"]["stdoutSnippet"],
        json!("[redacted]\nworker booted")
    );

    let replay = launch_activation(&handle, &activation_id, &plan_id, launch_key).await;
    assert_eq!(replay.error, None);
    assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    assert_eq!(
        replay.value.as_ref().unwrap()["workerProcessResourceId"],
        json!(process_id)
    );

    let function_id = expected_function.id.clone();
    assert!(matches!(
        handle.inspect_function(&function_id, None).await,
        Err(EngineError::NotFound { .. })
    ));

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    runtime.hello(hello).await.unwrap();
    assert_eq!(process_status(&handle, &process_id).await, "hello_seen");
    assert!(matches!(
        handle.inspect_function(&function_id, None).await,
        Err(EngineError::NotFound { .. })
    ));

    runtime
        .attach_invoker(
            expected_function.owner_worker.clone(),
            Arc::new(EchoExternalInvoker),
        )
        .unwrap();
    runtime
        .register_function(RegisterFunction {
            definition: expected_function.clone(),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    assert_eq!(process_status(&handle, &process_id).await, "ready");

    let invoked = handle
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"message": "ready"}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(invoked.error, None);
    assert_eq!(
        invoked.value.as_ref().unwrap()["payload"]["message"],
        "ready"
    );

    let stopped = stop_process(&handle, &process_id, "saawo-valid-stop").await;
    assert_eq!(stopped.error, None);
    assert_eq!(fake.stops.load(Ordering::SeqCst), 1);
    assert_eq!(process_status(&handle, &process_id).await, "stopped");
    assert!(matches!(
        handle.inspect_function(&function_id, None).await,
        Err(EngineError::NotFound { .. })
    ));
    let stopped_payload = process_payload(&handle, &process_id).await;
    assert!(
        !stopped_payload
            .to_string()
            .contains("bearer activation-token-secret"),
        "stop output must be redacted before persistence"
    );
}

#[tokio::test]
async fn worker_orchestration_stdin_activation_bundle_consumes_vault_once() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let fake = Arc::new(FakeSupervisor::default());
    handle
        .worker_process_supervisor_registry_for_setup()
        .unwrap()
        .set_supervisor(fake.clone());

    let (activation_id, _hello, expected_function) =
        issued_activation_bundle(&handle, "orch-stdin", "orchestrated_stdin::echo").await;
    let vault_before = handle
        .worker_activation_bundle_metadata_for_test(&activation_id)
        .await
        .unwrap()
        .expect("activation bundle should be in the in-memory vault");
    let plan_id = create_launch_plan(
        &handle,
        "orch-stdin",
        &activation_id,
        &expected_function,
        LaunchPlanOverrides {
            activation_delivery_mode: Some("stdin_activation_bundle_v1".to_owned()),
            ..LaunchPlanOverrides::default()
        },
    )
    .await;
    let launched = launch_activation(&handle, &activation_id, &plan_id, "saawo-stdin-launch").await;
    assert_eq!(launched.error, None, "stdin launch failed: {launched:?}");
    assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    let request = fake.requests.lock().unwrap()[0].clone();
    assert!(request.had_secret_stdin);
    assert_eq!(
        request.secret_stdin_byte_count,
        vault_before.bundle_byte_count
    );
    assert_eq!(
        request.secret_stdin_fingerprint.as_deref(),
        Some(vault_before.bundle_fingerprint.as_str())
    );
    assert!(
        handle
            .worker_activation_bundle_metadata_for_test(&activation_id)
            .await
            .unwrap()
            .is_none(),
        "stdin launch must consume the vault entry exactly once"
    );
    let process_id = launched.value.unwrap()["workerProcessResourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let payload = process_payload(&handle, &process_id).await;
    assert_eq!(
        payload["activationHandoff"]["delivery"],
        "stdin_activation_bundle_v1"
    );
    assert_eq!(payload["activationHandoff"]["secretStdin"]["present"], true);
    assert_eq!(
        payload["activationHandoff"]["secretStdin"]["redacted"],
        true
    );
    assert_eq!(
        payload["activationHandoff"]["secretStdin"]["fingerprint"],
        vault_before.bundle_fingerprint
    );
    assert_eq!(
        payload["activationHandoff"]["secretStdin"]["byteCount"],
        vault_before.bundle_byte_count
    );
    assert!(
        !payload.to_string().contains("workerHello"),
        "worker_process payload must not persist activation bundle JSON"
    );

    let replay = launch_activation(&handle, &activation_id, &plan_id, "saawo-stdin-launch").await;
    assert_eq!(replay.error, None);
    assert_eq!(fake.starts.load(Ordering::SeqCst), 1);
    assert_eq!(
        replay.value.as_ref().unwrap()["workerProcessResourceId"],
        json!(process_id)
    );
}

#[tokio::test]
async fn worker_orchestration_rejects_mismatched_or_secret_launch_plans_before_start() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let fake = Arc::new(FakeSupervisor::default());
    handle
        .worker_process_supervisor_registry_for_setup()
        .unwrap()
        .set_supervisor(fake.clone());

    let (activation_id, _hello, expected_function) =
        issued_activation_bundle(&handle, "orch-reject", "orchestrated_reject::echo").await;
    for (suffix, overrides, expected_error) in [
        (
            "wrong-worker",
            LaunchPlanOverrides {
                worker_id: Some("other-worker".to_owned()),
                ..LaunchPlanOverrides::default()
            },
            "workerId",
        ),
        (
            "secret-env",
            LaunchPlanOverrides {
                env: Some(BTreeMap::from([(
                    "API_TOKEN".to_owned(),
                    "activation-token-secret".to_owned(),
                )])),
                env_allowlist: Some(vec!["API_TOKEN".to_owned()]),
                ..LaunchPlanOverrides::default()
            },
            "secret-bearing",
        ),
    ] {
        let plan_id = create_launch_plan(
            &handle,
            suffix,
            &activation_id,
            &expected_function,
            overrides,
        )
        .await;
        let result = launch_activation(
            &handle,
            &activation_id,
            &plan_id,
            &format!("saawo-{suffix}-launch"),
        )
        .await;
        let error = result.error.expect("launch should fail closed");
        assert!(
            error.to_string().contains(expected_error),
            "expected {expected_error:?}, got {error:?}"
        );
    }
    assert_eq!(
        fake.starts.load(Ordering::SeqCst),
        0,
        "invalid launch plans must fail before supervisor start"
    );

    let rejected_plan = create_launch_plan_result(
        &handle,
        "unsupported-delivery",
        &activation_id,
        &expected_function,
        LaunchPlanOverrides {
            activation_delivery_mode: Some("env_token".to_owned()),
            ..LaunchPlanOverrides::default()
        },
    )
    .await;
    let error = rejected_plan
        .error
        .expect("unsupported activation delivery mode should fail schema validation");
    assert!(error.to_string().contains("activationDeliveryMode"));
}

#[tokio::test]
async fn worker_orchestration_wrong_registration_marks_process_failed() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let fake = Arc::new(FakeSupervisor::default());
    handle
        .worker_process_supervisor_registry_for_setup()
        .unwrap()
        .set_supervisor(fake);

    let (activation_id, hello, expected_function) =
        issued_activation_bundle(&handle, "orch-wrong-register", "orchestrated_wrong::echo").await;
    let plan_id = create_launch_plan(
        &handle,
        "orch-wrong-register",
        &activation_id,
        &expected_function,
        LaunchPlanOverrides::default(),
    )
    .await;
    let launched = launch_activation(
        &handle,
        &activation_id,
        &plan_id,
        "saawo-wrong-register-launch",
    )
    .await;
    assert_eq!(launched.error, None);
    let process_id = launched.value.unwrap()["workerProcessResourceId"]
        .as_str()
        .unwrap()
        .to_owned();

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    runtime.hello(hello).await.unwrap();
    let mut wrong = expected_function.clone();
    wrong.id = fid("orchestrated_wrong::other");
    let error = runtime
        .register_function(RegisterFunction {
            definition: wrong,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(error.to_string().contains("function id"));
    assert_eq!(process_status(&handle, &process_id).await, "failed");
    assert!(matches!(
        handle.inspect_function(&expected_function.id, None).await,
        Err(EngineError::NotFound { .. })
    ));
}

#[derive(Default)]
struct FakeSupervisor {
    starts: AtomicUsize,
    stops: AtomicUsize,
    requests: Mutex<Vec<RecordedStartRequest>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecordedStartRequest {
    env: BTreeMap<String, String>,
    argv: Vec<String>,
    had_secret_stdin: bool,
    secret_stdin_byte_count: usize,
    secret_stdin_fingerprint: Option<String>,
}

#[async_trait]
impl WorkerProcessSupervisor for FakeSupervisor {
    async fn start(&self, request: WorkerProcessStartRequest) -> Result<WorkerProcessStartResult> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        let process_id = request.process_resource_id.clone();
        self.requests.lock().unwrap().push(RecordedStartRequest {
            env: request.env.clone(),
            argv: request.argv.clone(),
            had_secret_stdin: request.secret_stdin.is_some(),
            secret_stdin_byte_count: request
                .secret_stdin
                .as_ref()
                .map(|stdin| stdin.byte_count)
                .unwrap_or_default(),
            secret_stdin_fingerprint: request
                .secret_stdin
                .as_ref()
                .map(|stdin| stdin.fingerprint.clone()),
        });
        Ok(WorkerProcessStartResult {
            handle: WorkerProcessHandle {
                supervisor_process_id: process_id.clone(),
                pid: Some(4242),
                pid_fingerprint: format!("fake-{process_id}"),
            },
            stdout_snippet: "token=activation-token-secret\nworker booted".to_owned(),
            stderr_snippet: String::new(),
            output_truncated: false,
        })
    }

    async fn stop(
        &self,
        _handle: WorkerProcessHandle,
        _stop_timeout: StdDuration,
    ) -> Result<WorkerProcessStopResult> {
        self.stops.fetch_add(1, Ordering::SeqCst);
        Ok(WorkerProcessStopResult {
            status: "stopped".to_owned(),
            exit_code: Some(0),
            stdout_snippet: "bearer activation-token-secret".to_owned(),
            stderr_snippet: "clean stop".to_owned(),
            output_truncated: false,
        })
    }
}

#[derive(Default)]
struct LaunchPlanOverrides {
    worker_id: Option<String>,
    activation_delivery_mode: Option<String>,
    env: Option<BTreeMap<String, String>>,
    env_allowlist: Option<Vec<String>>,
}

async fn issued_activation_bundle(
    handle: &EngineHostHandle,
    suffix: &str,
    function_id: &str,
) -> (String, WorkerHello, FunctionDefinition) {
    let refs = create_worker_activation_governance(
        handle,
        WorkerActivationGovernanceConfig::session(suffix, function_id),
    )
    .await;
    let issued = issue_worker_activation(handle, &refs, &format!("saawa-{suffix}-issue")).await;
    assert_eq!(issued.error, None, "activation issue failed: {issued:?}");
    let value = issued.value.as_ref().unwrap();
    let activation_id = value["activationResourceId"].as_str().unwrap().to_owned();
    let hello = serde_json::from_value(value["activationBundle"]["workerHello"].clone()).unwrap();
    let expected_function =
        serde_json::from_value(value["activationBundle"]["expectedFunctionDefinition"].clone())
            .unwrap();
    (activation_id, hello, expected_function)
}

async fn create_launch_plan(
    handle: &EngineHostHandle,
    suffix: &str,
    activation_id: &str,
    expected_function: &FunctionDefinition,
    overrides: LaunchPlanOverrides,
) -> String {
    let result =
        create_launch_plan_result(handle, suffix, activation_id, expected_function, overrides)
            .await;
    assert_eq!(
        result.error, None,
        "launch plan create failed for {activation_id}: {result:?}"
    );
    format!("saawo-{suffix}-launch-plan")
}

async fn create_launch_plan_result(
    handle: &EngineHostHandle,
    suffix: &str,
    _activation_id: &str,
    expected_function: &FunctionDefinition,
    overrides: LaunchPlanOverrides,
) -> InvocationResult {
    let executable = temp_executable(suffix);
    let digest = file_digest(&executable);
    let plan_id = format!("saawo-{suffix}-launch-plan");
    let env = overrides.env.unwrap_or_default();
    let env_allowlist = overrides.env_allowlist.unwrap_or_else(|| {
        vec![
            "TRON_WORKER_ACTIVATION_RESOURCE_ID".to_owned(),
            "TRON_WORKER_PORT".to_owned(),
        ]
    });
    handle
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
                    "env": env,
                    "envAllowlist": env_allowlist,
                    "cwd": null,
                    "cwdPolicy": "none",
                    "startupTimeoutMs": 10000,
                    "stopTimeoutMs": 5000,
                    "maxLogCaptureBytes": 4096,
                    "activationDeliveryMode": overrides
                        .activation_delivery_mode
                        .unwrap_or_else(|| "preissued_bundle".to_owned()),
                    "governance": {
                        "reviewed": true,
                        "decisionResourceId": format!("saawo-{suffix}-decision"),
                        "evidenceResourceIds": [format!("saawo-{suffix}-evidence")]
                    }
                }
            }),
            mutating_causal(&format!("saawo-{suffix}-plan")).with_scope("resource.write"),
        ))
        .await
}

async fn launch_activation(
    handle: &EngineHostHandle,
    activation_id: &str,
    plan_id: &str,
    idempotency_key: &str,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "worker::launch_activation",
            json!({
                "activationResourceId": activation_id,
                "launchPlanResourceId": plan_id,
                "launchReason": "test launch",
                "idempotencyKey": idempotency_key,
            }),
            admin_launch_causal(idempotency_key),
        ))
        .await
}

async fn stop_process(
    handle: &EngineHostHandle,
    process_id: &str,
    idempotency_key: &str,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "worker::stop_process",
            json!({
                "workerProcessResourceId": process_id,
                "reason": "test stop",
                "idempotencyKey": idempotency_key,
            }),
            admin_launch_causal(idempotency_key),
        ))
        .await
}

fn admin_launch_causal(idempotency_key: &str) -> CausalContext {
    CausalContext::new(
        actor("admin"),
        ActorKind::Admin,
        grant("grant"),
        trace(&format!("worker-orchestration-{idempotency_key}")),
    )
    .with_scope("worker.launch")
    .with_session_id("session-a")
    .with_workspace_id("workspace-a")
    .with_idempotency_key(idempotency_key)
}

async fn process_status(handle: &EngineHostHandle, process_id: &str) -> String {
    process_payload(handle, process_id).await["status"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn process_payload(handle: &EngineHostHandle, process_id: &str) -> Value {
    let inspection = handle
        .inspect_resource(process_id)
        .await
        .unwrap()
        .expect("worker_process resource should exist");
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
    let path = std::env::temp_dir().join(format!("tron-saawo-{suffix}-{}", uuid::Uuid::now_v7()));
    std::fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
    path
}

fn file_digest(path: &Path) -> String {
    let bytes = std::fs::read(path).unwrap();
    hex::encode(Sha256::digest(bytes))
}
