use std::sync::Mutex;
use std::time::Duration as StdDuration;

use chrono::DateTime;

use super::worker_schedule_dispatch_support::*;
use super::*;
use crate::engine::durability::queue::QueueItemStatus;
use crate::engine::runtime::worker_orchestration::{
    WorkerProcessHandle, WorkerProcessStartRequest, WorkerProcessStartResult,
    WorkerProcessStopResult, WorkerProcessSupervisor,
};
use crate::engine::runtime::worker_schedule::EngineWorkerScheduleRuntime;

#[tokio::test]
async fn worker_schedule_dispatch_enqueues_and_drains_trigger_launch_once() {
    let fixture = ScheduleFixture::new("due", base_time(), ScheduleOptions::default()).await;
    let runtime = EngineWorkerScheduleRuntime::new(fixture.handle.clone());

    let tick = runtime
        .dispatch_due_for_schedule(&fixture.schedule_id, fixture.anchor)
        .await
        .unwrap()
        .expect("due schedule should produce a tick");
    assert_eq!(tick["status"], "enqueued");
    assert_eq!(tick["scheduleId"], fixture.schedule_id);
    assert_eq!(tick["dispatch"]["deliveryMode"], "enqueue");
    assert_eq!(tick["idempotency"]["targetKeyFormat"], "worker_schedule_v1");
    assert_safe_tick_payload(&tick);

    let receipt = tick["dispatch"]["queueReceiptId"].as_str().unwrap();
    let item = fixture
        .handle
        .get_queue_item(receipt)
        .await
        .unwrap()
        .expect("schedule tick should enqueue a trigger target");
    assert_eq!(item.status, QueueItemStatus::Ready);
    assert_eq!(item.function_id.as_str(), "worker::launch_from_trigger");
    assert_eq!(
        item.trigger_id.as_ref().unwrap().as_str(),
        fixture.trigger_id
    );
    assert_eq!(
        item.idempotency_key.as_deref(),
        Some(fixture.target_key.as_str())
    );

    let drained = EngineQueueDrainer::drain_receipt(&fixture.handle, receipt, "worker-a")
        .await
        .unwrap()
        .expect("queued scheduled trigger should drain");
    assert_eq!(drained.error, None, "launch drain failed: {drained:?}");
    assert_eq!(fixture.fake.starts.load(Ordering::SeqCst), 1);
    assert_eq!(drained.value.as_ref().unwrap()["status"], "ready_pending");
    assert_eq!(activation_count(&fixture.handle).await, 1);
}

#[tokio::test]
async fn worker_schedule_dispatch_replays_same_tick_after_restart_without_duplicate_launch() {
    let fixture = ScheduleFixture::new("replay", base_time(), ScheduleOptions::default()).await;
    let runtime = EngineWorkerScheduleRuntime::new(fixture.handle.clone());
    let first = runtime
        .dispatch_due_for_schedule(&fixture.schedule_id, fixture.anchor)
        .await
        .unwrap()
        .expect("first tick should enqueue");
    let receipt = first["dispatch"]["queueReceiptId"]
        .as_str()
        .unwrap()
        .to_owned();
    EngineQueueDrainer::drain_receipt(&fixture.handle, &receipt, "worker-a")
        .await
        .unwrap()
        .expect("first queue item should drain");
    assert_eq!(fixture.fake.starts.load(Ordering::SeqCst), 1);
    let queue_before = queue_count(&fixture.handle).await;
    let activations_before = activation_count(&fixture.handle).await;

    let restarted_runtime = EngineWorkerScheduleRuntime::new(fixture.handle.clone());
    let replay = restarted_runtime
        .dispatch_due_for_schedule(&fixture.schedule_id, fixture.anchor)
        .await
        .unwrap()
        .expect("same nominal tick should replay");
    assert_eq!(replay["status"], "enqueued");
    assert_eq!(replay["dispatch"]["queueReceiptId"], receipt);
    assert_eq!(queue_count(&fixture.handle).await, queue_before);
    assert_eq!(activation_count(&fixture.handle).await, activations_before);
    assert!(
        EngineQueueDrainer::drain_once(&fixture.handle, "default", "worker-a")
            .await
            .unwrap()
            .is_none(),
        "replayed tick must not create another queue item"
    );
    assert_eq!(fixture.fake.starts.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn worker_schedule_dispatch_skips_missed_ticks_without_backfill_storm() {
    let anchor = base_time();
    let fixture = ScheduleFixture::new("missed", anchor, ScheduleOptions::default()).await;
    let runtime = EngineWorkerScheduleRuntime::new(fixture.handle.clone());
    let now = anchor + ChronoDuration::minutes(5);

    let latest = runtime
        .dispatch_due_for_schedule(&fixture.schedule_id, now)
        .await
        .unwrap()
        .expect("latest due tick should enqueue");
    assert_eq!(latest["status"], "enqueued");
    assert_eq!(latest["nominalTickAtUtc"], now.to_rfc3339());

    let ticks = tick_payloads_for_schedule(&fixture.handle, &fixture.schedule_id).await;
    let skipped: Vec<_> = ticks
        .iter()
        .filter(|payload| payload["status"] == "skipped_missed")
        .collect();
    let enqueued: Vec<_> = ticks
        .iter()
        .filter(|payload| payload["status"] == "enqueued")
        .collect();
    assert_eq!(skipped.len(), 1, "missed policy records one audit tick");
    assert_eq!(
        enqueued.len(),
        1,
        "missed policy dispatches only latest tick"
    );
    assert_eq!(
        skipped[0]["missed"]["latestDispatchedNominalTickAtUtc"],
        now.to_rfc3339()
    );
    assert_eq!(queue_count(&fixture.handle).await, 1);
}

#[tokio::test]
async fn worker_schedule_dispatch_records_overlap_without_second_enqueue() {
    let anchor = base_time();
    let fixture = ScheduleFixture::new("overlap", anchor, ScheduleOptions::default()).await;
    let runtime = EngineWorkerScheduleRuntime::new(fixture.handle.clone());
    runtime
        .dispatch_due_for_schedule(&fixture.schedule_id, anchor)
        .await
        .unwrap()
        .expect("first tick should enqueue");
    assert_eq!(queue_count(&fixture.handle).await, 1);

    let next = runtime
        .dispatch_due_for_schedule(&fixture.schedule_id, anchor + ChronoDuration::minutes(1))
        .await
        .unwrap()
        .expect("overlapping tick should be recorded");
    assert_eq!(next["status"], "skipped_overlap");
    assert_eq!(next["overlap"]["evidence"]["source"], "queue");
    assert_eq!(queue_count(&fixture.handle).await, 1);
    assert_eq!(fixture.fake.starts.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn worker_schedule_dispatch_rejects_invalid_plans_before_enqueue() {
    let anchor = base_time();
    let valid = ScheduleFixture::new("negative", anchor, ScheduleOptions::default()).await;

    assert_create_fails(
        &valid.handle,
        "missing_schedule_id",
        schedule_payload(
            &valid.schedule_id,
            &valid.trigger_id,
            &valid.autostart_id,
            anchor,
        )
        .without("scheduleId"),
    )
    .await;

    let bad_time_id = create_schedule_plan(
        &valid.handle,
        "bad_time",
        schedule_payload("bad_time", &valid.trigger_id, &valid.autostart_id, anchor)
            .with("anchorAtUtc", json!("not-a-utc-time")),
        "reviewed",
    )
    .await;
    assert_dispatch_fails(&valid.handle, &bad_time_id, anchor, "invalid anchorAtUtc").await;

    let short_interval_id = create_schedule_plan(
        &valid.handle,
        "short_interval",
        schedule_payload(
            "short_interval",
            &valid.trigger_id,
            &valid.autostart_id,
            anchor,
        )
        .with("intervalMs", json!(59_999)),
        "reviewed",
    )
    .await;
    assert_dispatch_fails(
        &valid.handle,
        &short_interval_id,
        anchor,
        "intervalMs must be between",
    )
    .await;
    let long_interval_id = create_schedule_plan(
        &valid.handle,
        "long_interval",
        schedule_payload(
            "long_interval",
            &valid.trigger_id,
            &valid.autostart_id,
            anchor,
        )
        .with("intervalMs", json!(86_400_001)),
        "reviewed",
    )
    .await;
    assert_dispatch_fails(
        &valid.handle,
        &long_interval_id,
        anchor,
        "intervalMs must be between",
    )
    .await;
    assert_create_fails(
        &valid.handle,
        "bad_policy",
        schedule_payload("bad_policy", &valid.trigger_id, &valid.autostart_id, anchor)
            .with("duplicatePolicy", json!("caller_template_v0")),
    )
    .await;

    let draft_id = create_schedule_plan(
        &valid.handle,
        "draft",
        schedule_payload("draft", &valid.trigger_id, &valid.autostart_id, anchor),
        "draft",
    )
    .await;
    assert_dispatch_fails(&valid.handle, &draft_id, anchor, "must be reviewed").await;

    let secret_id = create_schedule_plan(
        &valid.handle,
        "credcase",
        schedule_payload("credcase", &valid.trigger_id, &valid.autostart_id, anchor)
            .with("metadata", json!({"authorization": "bearer-token"})),
        "reviewed",
    )
    .await;
    assert_dispatch_fails(&valid.handle, &secret_id, anchor, "secret-bearing").await;

    let wrong_target =
        ScheduleFixture::new("wrong_target", anchor, ScheduleOptions::wrong_target()).await;
    assert_dispatch_fails(
        &wrong_target.handle,
        &wrong_target.schedule_id,
        anchor,
        "must target worker::launch_from_trigger",
    )
    .await;

    let sync_trigger =
        ScheduleFixture::new("sync_trigger", anchor, ScheduleOptions::sync_trigger()).await;
    assert_dispatch_fails(
        &sync_trigger.handle,
        &sync_trigger.schedule_id,
        anchor,
        "enqueue delivery",
    )
    .await;

    let missing_grant =
        ScheduleFixture::new("missing_grant", anchor, ScheduleOptions::missing_grant()).await;
    assert_dispatch_fails(
        &missing_grant.handle,
        &missing_grant.schedule_id,
        anchor,
        "authority grant",
    )
    .await;

    let non_stdin =
        ScheduleFixture::new("non_stdin", anchor, ScheduleOptions::non_stdin_launch()).await;
    assert_dispatch_fails(
        &non_stdin.handle,
        &non_stdin.schedule_id,
        anchor,
        "stdin_activation_bundle_v1",
    )
    .await;

    let secret_launch =
        ScheduleFixture::new("launch_cred", anchor, ScheduleOptions::secret_launch_argv()).await;
    assert_dispatch_fails(
        &secret_launch.handle,
        &secret_launch.schedule_id,
        anchor,
        "secret-bearing",
    )
    .await;
}

#[derive(Default)]
struct FakeSupervisor {
    starts: AtomicUsize,
    requests: Mutex<Vec<RecordedStartRequest>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecordedStartRequest {
    had_secret_stdin: bool,
}

#[async_trait]
impl WorkerProcessSupervisor for FakeSupervisor {
    async fn start(&self, request: WorkerProcessStartRequest) -> Result<WorkerProcessStartResult> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        let process_id = request.process_resource_id.clone();
        self.requests.lock().unwrap().push(RecordedStartRequest {
            had_secret_stdin: request.secret_stdin.is_some(),
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

struct ScheduleFixture {
    handle: EngineHostHandle,
    fake: Arc<FakeSupervisor>,
    schedule_id: String,
    trigger_id: String,
    autostart_id: String,
    anchor: DateTime<Utc>,
    target_key: String,
}

impl ScheduleFixture {
    async fn new(suffix: &str, anchor: DateTime<Utc>, options: ScheduleOptions) -> Self {
        let handle = EngineHostHandle::new_in_memory().unwrap();
        let fake = Arc::new(FakeSupervisor::default());
        handle
            .worker_process_supervisor_registry_for_setup()
            .unwrap()
            .set_supervisor(fake.clone());

        let function_id = format!("saawsd_{}::echo", suffix.replace('-', "_"));
        let trigger_id = register_schedule_trigger(&handle, suffix, &options).await;
        let refs = create_worker_activation_governance(
            &handle,
            WorkerActivationGovernanceConfig::session(suffix, &function_id),
        )
        .await;
        let schedule_id = format!("saawsd-{suffix}-schedule");
        let autostart_id = format!("saawsd-{suffix}-autostart-plan");
        let target_key = schedule_target_key(&schedule_id, anchor);
        let issue_key = derived_trigger_issue_key(&autostart_id, &trigger_id, &target_key);
        let expected_worker_id = predicted_worker_id(&handle, &refs, &issue_key).await;
        let expected_function = expected_function_for_fixture(&handle, &refs).await;
        let launch_plan_id = create_launch_plan(
            &handle,
            suffix,
            &expected_function,
            LaunchPlanOptions {
                worker_id: Some(expected_worker_id),
                activation_delivery_mode: Some(options.activation_delivery_mode),
                argv: options.argv,
                argv_allowlist: options.argv_allowlist,
            },
        )
        .await;
        create_autostart_plan(&handle, suffix, &trigger_id, &launch_plan_id, &refs).await;
        create_schedule_plan(
            &handle,
            &schedule_id,
            schedule_payload(&schedule_id, &trigger_id, &autostart_id, anchor),
            "reviewed",
        )
        .await;
        Self {
            handle,
            fake,
            schedule_id,
            trigger_id,
            autostart_id,
            anchor,
            target_key,
        }
    }
}

struct ScheduleOptions {
    target_function: String,
    delivery_mode: DeliveryMode,
    authority_grant: String,
    activation_delivery_mode: String,
    argv: Vec<String>,
    argv_allowlist: Vec<String>,
}

impl Default for ScheduleOptions {
    fn default() -> Self {
        Self {
            target_function: "worker::launch_from_trigger".to_owned(),
            delivery_mode: DeliveryMode::Enqueue,
            authority_grant: "grant".to_owned(),
            activation_delivery_mode: "stdin_activation_bundle_v1".to_owned(),
            argv: vec!["--serve".to_owned()],
            argv_allowlist: vec!["--serve".to_owned()],
        }
    }
}

impl ScheduleOptions {
    fn wrong_target() -> Self {
        Self {
            target_function: "saawsd_wrong::queued".to_owned(),
            ..Self::default()
        }
    }

    fn sync_trigger() -> Self {
        Self {
            delivery_mode: DeliveryMode::Sync,
            ..Self::default()
        }
    }

    fn missing_grant() -> Self {
        Self {
            authority_grant: "saawsd-missing-grant".to_owned(),
            ..Self::default()
        }
    }

    fn non_stdin_launch() -> Self {
        Self {
            activation_delivery_mode: "preissued_bundle".to_owned(),
            ..Self::default()
        }
    }

    fn secret_launch_argv() -> Self {
        Self {
            argv: vec!["--token".to_owned()],
            argv_allowlist: vec!["--token".to_owned()],
            ..Self::default()
        }
    }
}

async fn register_schedule_trigger(
    handle: &EngineHostHandle,
    suffix: &str,
    options: &ScheduleOptions,
) -> String {
    if options.target_function == "saawsd_wrong::queued" {
        handle
            .register_worker_for_setup(worker("saawsd-wrong-worker", "saawsd_wrong"), false)
            .unwrap();
        handle
            .register_function_for_setup(
                read_function("saawsd_wrong::queued", "saawsd-wrong-worker")
                    .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                    .with_required_authority(AuthorityRequirement::scope("worker.launch")),
                Some(handler()),
                false,
            )
            .unwrap();
    }
    let trigger_type_id = TriggerTypeId::new(format!("saawsd-trigger-type-{suffix}")).unwrap();
    let mut trigger_type = TriggerTypeDefinition::new(
        trigger_type_id.clone(),
        wid("trigger"),
        "test worker schedule dispatch",
    );
    trigger_type.allowed_delivery_modes = vec![DeliveryMode::Sync, DeliveryMode::Enqueue];
    handle
        .register_trigger_type(trigger_type, true)
        .await
        .unwrap();
    let trigger_id = TriggerId::new(format!("saawsd-trigger-{suffix}")).unwrap();
    handle
        .register_trigger(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("trigger"),
                trigger_type_id,
                fid(&options.target_function),
                grant(&options.authority_grant),
            )
            .with_delivery_mode(options.delivery_mode.clone()),
            true,
        )
        .await
        .unwrap();
    trigger_id.to_string()
}

struct LaunchPlanOptions {
    worker_id: Option<String>,
    activation_delivery_mode: Option<String>,
    argv: Vec<String>,
    argv_allowlist: Vec<String>,
}

async fn create_launch_plan(
    handle: &EngineHostHandle,
    suffix: &str,
    expected_function: &FunctionDefinition,
    options: LaunchPlanOptions,
) -> String {
    let executable = temp_executable(suffix);
    let digest = file_digest(&executable);
    let plan_id = format!("saawsd-{suffix}-launch-plan");
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
                    "expectedWorkerId": options
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
                    "argv": options.argv,
                    "argvAllowlist": options.argv_allowlist,
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
                    "activationDeliveryMode": options
                        .activation_delivery_mode
                        .unwrap_or_else(|| "stdin_activation_bundle_v1".to_owned()),
                    "governance": {
                        "reviewed": true,
                        "decisionResourceId": format!("saawsd-{suffix}-decision"),
                        "evidenceResourceIds": [format!("saawsd-{suffix}-evidence")]
                    }
                }
            }),
            mutating_causal(&format!("saawsd-{suffix}-launch-plan")).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None, "launch plan create failed: {result:?}");
    plan_id
}

async fn create_autostart_plan(
    handle: &EngineHostHandle,
    suffix: &str,
    trigger_id: &str,
    launch_plan_id: &str,
    refs: &WorkerActivationGovernanceFixture,
) {
    let autostart_id = format!("saawsd-{suffix}-autostart-plan");
    let result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": autostart_id,
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
                    "activationReason": "reviewed schedule worker launch",
                    "policy": {
                        "deliveryMode": "stdin_activation_bundle_v1",
                        "restartPolicy": "none",
                        "duplicatePolicy": "idempotency_key_replay_v1"
                    }
                }
            }),
            mutating_causal(&format!("saawsd-{suffix}-autostart")).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None, "autostart create failed: {result:?}");
}

async fn create_schedule_plan(
    handle: &EngineHostHandle,
    resource_id: &str,
    payload: Value,
    lifecycle: &str,
) -> String {
    let result = create_schedule_plan_result(handle, resource_id, payload, lifecycle).await;
    assert_eq!(result.error, None, "schedule create failed: {result:?}");
    resource_id.to_owned()
}

async fn create_schedule_plan_result(
    handle: &EngineHostHandle,
    resource_id: &str,
    payload: Value,
    lifecycle: &str,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": resource_id,
                "kind": "worker_schedule_plan",
                "scope": "session",
                "sessionId": "session-a",
                "lifecycle": lifecycle,
                "payload": payload
            }),
            mutating_causal(&format!("saawsd-{resource_id}-schedule")).with_scope("resource.write"),
        ))
        .await
}

async fn assert_create_fails(handle: &EngineHostHandle, resource_id: &str, payload: Value) {
    let before = queue_count(handle).await;
    let result = create_schedule_plan_result(handle, resource_id, payload, "reviewed").await;
    assert!(
        result.error.is_some(),
        "resource create should fail: {result:?}"
    );
    assert_eq!(queue_count(handle).await, before);
}

async fn assert_dispatch_fails(
    handle: &EngineHostHandle,
    schedule_id: &str,
    now: DateTime<Utc>,
    expected: &str,
) {
    let before = queue_count(handle).await;
    let result = EngineWorkerScheduleRuntime::new(handle.clone())
        .dispatch_due_for_schedule(schedule_id, now)
        .await;
    let error = result.expect_err("invalid schedule should fail closed");
    assert!(
        error.to_string().contains(expected),
        "expected {expected:?}, got {error}"
    );
    assert_eq!(queue_count(handle).await, before);
}
