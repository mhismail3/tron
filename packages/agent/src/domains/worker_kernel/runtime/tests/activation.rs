use super::*;

#[tokio::test]
async fn enqueue_and_await_compose_long_work_without_blocking_admission() {
    let (runtime, _home) = test_runtime(None);
    let bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "sleep 0.2; cat".to_owned(),
    ]);
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let admitted = runtime
        .enqueue_and_dispatch(request(
            &outcome.worker.worker_id,
            json!({"mode":"parallel"}),
            "enqueue-await",
        ))
        .unwrap();
    assert_eq!(admitted.status, "queued");
    let (current, timed_out) = runtime
        .await_invocation(&admitted.invocation_id, Duration::ZERO)
        .await
        .unwrap();
    assert!(matches!(current.status.as_str(), "queued" | "running"));
    assert!(timed_out);

    let (completed, timed_out) = runtime
        .await_invocation(&admitted.invocation_id, Duration::from_secs(2))
        .await
        .unwrap();
    assert!(!timed_out);
    assert_eq!(completed.status, "completed");
    assert_eq!(completed.output, Some(json!({"mode":"parallel"})));
}

#[tokio::test]
async fn last30days_replay_activates_one_typed_worker_and_survives_restart() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../tests/fixtures/last30days_worker_gap.json"
    ))
    .unwrap();
    let source_url = fixture["sourceUrl"].as_str().unwrap();
    let home = tempfile::tempdir().unwrap();
    let runtime = test_runtime_at(home.path(), None);
    let mut bundle = last30days_bundle(source_url);
    for trigger in &mut bundle.triggers {
        if let WorkerTrigger::Schedule { every_seconds, .. } = trigger {
            *every_seconds = 1;
        }
    }

    let outcome = runtime.upsert(bundle, None).await.unwrap();
    assert!(outcome.created);
    assert_eq!(outcome.worker.worker_id, "last30days-research");
    assert_eq!(outcome.worker.tool_name, "worker_last30days_research");
    assert_eq!(outcome.webhooks.len(), 1);
    let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
    let trigger_kinds = inspection["triggers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|trigger| trigger["kind"].as_str().unwrap())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        trigger_kinds,
        BTreeSet::from(["manual", "schedule", "engine_event", "webhook"])
    );

    let direct = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::dynamic_last30days-research").unwrap(),
            json!({"topic":"worker adaptation","asOf":"2026-07-19"}),
            CausalContext::new(
                ActorId::new("agent:last30days-replay").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-last30days-direct").unwrap(),
            )
            .with_session_id("session-last30days-replay")
            .with_idempotency_key("last30days-direct"),
        ))
        .await;
    assert!(
        direct.error.is_none(),
        "direct worker error: {:?}",
        direct.error
    );
    let value = direct.value.unwrap();
    assert_eq!(value["windowDays"], 30);
    assert_eq!(value["credentialMode"], "optional_credentials_absent");
    assert_eq!(value["sources"].as_array().unwrap().len(), 3);
    assert!(
        value["summary"]
            .as_str()
            .unwrap()
            .contains("worker adaptation")
    );

    let webhook_credential = &outcome.webhooks[0];
    let webhook_input = runtime
        .store()
        .verify_webhook(
            &outcome.worker.worker_id,
            &webhook_credential.trigger_id,
            &webhook_credential.token,
        )
        .unwrap();
    let webhook = runtime
        .invoke(InvokeRequest {
            worker_id: outcome.worker.worker_id.clone(),
            input: webhook_input,
            idempotency_key: "webhook:local-research:last30days-replay".to_owned(),
            trace_id: "trace-last30days-webhook".to_owned(),
            causal_depth: 0,
            trigger_kind: "webhook".to_owned(),
            origin_session_id: None,
        })
        .await
        .unwrap();
    assert_eq!(webhook.status, "completed");

    runtime
        .publish_event(
            "research.requested",
            json!({"windowDays":30,"requestId":"same-worker-proof"}),
            Some(TraceId::new("trace-last30days-event").unwrap()),
        )
        .await;
    let mut event_runs = JoinSet::new();
    runtime.dispatch_events(&mut event_runs).await;
    while event_runs.join_next().await.is_some() {}

    tokio::time::sleep(Duration::from_millis(1_100)).await;
    let mut schedule_runs = JoinSet::new();
    runtime.dispatch_schedules(&mut schedule_runs).await;
    while schedule_runs.join_next().await.is_some() {}
    let trigger_kinds = runtime
        .store()
        .runs_filtered(Some(&outcome.worker.worker_id), None, 10)
        .unwrap()
        .into_iter()
        .map(|run| run.trigger_kind)
        .collect::<BTreeSet<_>>();
    assert_eq!(
        trigger_kinds,
        BTreeSet::from([
            "engine_event".to_owned(),
            "manual".to_owned(),
            "schedule".to_owned(),
            "webhook".to_owned(),
        ])
    );

    let version_dir = home
        .path()
        .join("workspace/workers/last30days-research/versions")
        .join(&outcome.version);
    assert!(version_dir.join("manifest.json").is_file());
    assert!(
        home.path()
            .join("workspace/workers/last30days-research/worker.json")
            .is_file()
    );

    let restarted = test_runtime_at(home.path(), None);
    restarted.register_active_tools().await.unwrap();
    let after_restart = restarted
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::dynamic_last30days-research").unwrap(),
            json!({"topic":"persistent workers","asOf":"2026-07-19"}),
            CausalContext::new(
                ActorId::new("agent:last30days-restart").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-last30days-restart").unwrap(),
            )
            .with_session_id("session-last30days-restart")
            .with_idempotency_key("last30days-restart"),
        ))
        .await;
    assert!(
        after_restart.error.is_none(),
        "restarted worker error: {:?}",
        after_restart.error
    );
    assert_eq!(after_restart.value.unwrap()["topic"], "persistent workers");
    assert_eq!(
        restarted
            .store()
            .runs_filtered(Some("last30days-research"), None, 10)
            .unwrap()
            .len(),
        5
    );
}

#[tokio::test]
#[ignore = "opt-in live network: set TRON_WORKER_LIVE_NETWORK=1"]
async fn last30days_upstream_live_network_dependency_is_locked_and_activates() {
    assert_eq!(
        std::env::var("TRON_WORKER_LIVE_NETWORK").ok().as_deref(),
        Some("1"),
        "set TRON_WORKER_LIVE_NETWORK=1 to run the upstream proof"
    );
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../tests/fixtures/last30days_worker_gap.json"
    ))
    .unwrap();
    let source_url = fixture["sourceUrl"].as_str().unwrap();
    let revision_output = std::process::Command::new("git")
        .args(["ls-remote", source_url, "HEAD"])
        .output()
        .unwrap();
    assert!(revision_output.status.success());
    let revision = String::from_utf8(revision_output.stdout)
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .to_owned();
    let mut bundle = last30days_bundle(source_url);
    bundle
        .description
        .push_str(" using a locked upstream checkout");
    bundle.dependencies.push(WorkerDependency {
        name: "upstream".to_owned(),
        source: format!("git+{source_url}"),
        version: revision.clone(),
        checksum: None,
        install: None,
    });
    bundle.smoke_tests.push(WorkerCommand {
        command: vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "test -d ../dependencies/upstream".to_owned(),
        ],
        timeout_seconds: 10,
    });
    bundle.provenance[0].revision = Some(revision);

    let (runtime, _home) = test_runtime(None);
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let active = runtime
        .store()
        .load_active(&outcome.worker.worker_id)
        .unwrap();
    let locked = active.bundle.dependencies[0]
        .checksum
        .as_deref()
        .expect("upsert seals fetched dependency checksum");
    assert_eq!(
        locked,
        format!(
            "sha256:{}",
            digest_tree(&active.version_dir.join("dependencies/upstream")).unwrap()
        )
    );
    let result = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"topic":"recent research","asOf":"2026-07-19"}),
            "upstream-live-network",
        ))
        .await
        .unwrap();
    assert_eq!(result.status, "completed");
    assert_eq!(result.output.unwrap()["upstreamAvailable"], true);
}

#[tokio::test]
async fn upsert_fetches_and_seals_an_omitted_dependency_checksum() {
    let (runtime, home) = test_runtime(None);
    let source = home.path().join("dependency-source");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(source.join("source.txt"), "locked content").unwrap();
    let expected = format!("sha256:{}", digest_tree(&source).unwrap());
    let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bundle.dependencies.push(WorkerDependency {
        name: "upstream".to_owned(),
        source: format!("file://{}", source.display()),
        version: "fixture-1".to_owned(),
        checksum: None,
        install: None,
    });
    bundle.smoke_tests.push(WorkerCommand {
        command: vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "test -f ../dependencies/upstream/source.txt".to_owned(),
        ],
        timeout_seconds: 5,
    });

    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let active = runtime
        .store()
        .load_active(&outcome.worker.worker_id)
        .unwrap();
    assert_eq!(
        active.bundle.dependencies[0].checksum.as_deref(),
        Some(expected.as_str())
    );
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(active.version_dir.join("manifest.json")).unwrap())
            .unwrap();
    let lock: Value = serde_json::from_slice(
        &std::fs::read(active.version_dir.join("dependencies.lock.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["dependencies"][0]["checksum"], expected);
    assert_eq!(lock[0]["checksum"], expected);
}

#[cfg(unix)]
#[tokio::test]
async fn dependency_hash_and_runtime_copy_preserve_symlink_targets() {
    let (runtime, home) = test_runtime(None);
    let source = home.path().join("symlink-dependency-source");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(source.join("target.txt"), "linked content").unwrap();
    std::os::unix::fs::symlink("target.txt", source.join("current.txt")).unwrap();
    let expected = format!("sha256:{}", digest_tree(&source).unwrap());
    let mut bundle = command_bundle(vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "test \"$(cat ../dependencies/upstream/current.txt)\" = 'linked content'; printf '{\"linked\":true}'".to_owned(),
        ]);
    bundle.dependencies.push(WorkerDependency {
        name: "upstream".to_owned(),
        source: format!("file://{}", source.display()),
        version: "fixture-1".to_owned(),
        checksum: None,
        install: None,
    });
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let active = runtime
        .store()
        .load_active(&outcome.worker.worker_id)
        .unwrap();

    assert_eq!(
        active.bundle.dependencies[0].checksum.as_deref(),
        Some(expected.as_str())
    );
    assert!(
        std::fs::symlink_metadata(active.version_dir.join("dependencies/upstream/current.txt"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
    let record = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "symlink-runtime-copy",
        ))
        .await
        .unwrap();
    assert_eq!(record.output, Some(json!({"linked":true})));
}

#[tokio::test]
async fn command_runner_upserts_invokes_and_replays_idempotently() {
    let (runtime, home) = test_runtime(None);
    let command = vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,os,sys; value=json.load(sys.stdin); value['idempotencyKey']=os.environ['TRON_WORKER_IDEMPOTENCY_KEY']; value['traceId']=os.environ['TRON_WORKER_TRACE_ID']; print(json.dumps(value))".to_owned(),
        ];
    let outcome = runtime.upsert(command_bundle(command), None).await.unwrap();
    let inspection_actor = crate::engine::ActorContext::new(
        ActorId::new("system:worker-tool-evidence-test").unwrap(),
        ActorKind::System,
    );
    let function_id = FunctionId::new(format!(
        "worker_kernel::dynamic_{}",
        outcome.worker.worker_id
    ))
    .unwrap();
    let initial_definition = runtime
        .host
        .inspect_function(&function_id, &inspection_actor)
        .await
        .unwrap();
    let first = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"topic":"workers"}),
            "same-key",
        ))
        .await
        .unwrap();
    let replay = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"topic":"different"}),
            "same-key",
        ))
        .await
        .unwrap();

    assert_eq!(first.status, "completed");
    assert_eq!(first.attempt_count, 1);
    assert_eq!(
        first.output,
        Some(json!({
            "topic":"workers",
            "idempotencyKey":"same-key",
            "traceId":"trace-same-key",
        }))
    );
    assert_eq!(replay.invocation_id, first.invocation_id);
    assert_eq!(
        runtime.store().runs_filtered(None, None, 10).unwrap().len(),
        1
    );
    assert_eq!(
        runtime
            .store()
            .attempts(&first.invocation_id)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        runtime.store().trace("trace-same-key").unwrap().unwrap()["suppressedCount"],
        1
    );
    assert!(
        home.path()
            .join("workspace/workers")
            .join(&outcome.worker.worker_id)
            .join("versions")
            .join(&outcome.version)
            .join("verification.json")
            .is_file()
    );

    let direct = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new(format!(
                "worker_kernel::dynamic_{}",
                outcome.worker.worker_id
            ))
            .unwrap(),
            json!({"topic":"direct typed tool"}),
            CausalContext::new(
                ActorId::new("agent:worker-direct-test").unwrap(),
                ActorKind::Agent,
                TraceId::new("worker-direct-trace").unwrap(),
            )
            .with_session_id("worker-direct-session")
            .with_idempotency_key("worker-direct-call"),
        ))
        .await;
    assert!(
        direct.error.is_none(),
        "direct worker error: {:?}",
        direct.error
    );
    assert_eq!(
        direct.value,
        Some(json!({
            "topic":"direct typed tool",
            "idempotencyKey":"worker-direct-call",
            "traceId":"worker-direct-trace",
        }))
    );
    let definition = runtime
        .host
        .inspect_function(&function_id, &inspection_actor)
        .await
        .unwrap();
    assert_eq!(definition.revision, initial_definition.revision);
    assert!(!definition.description.contains("completedRuns="));
    assert!(definition.description.contains("test:deterministic@1"));
    let surface = runtime
        .engine_surface_snapshot(
            Some("worker-direct-session"),
            Some("workers direct typed tool"),
        )
        .await
        .unwrap();
    let available = surface["surface"]["availableWorkers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|worker| worker["workerId"] == outcome.worker.worker_id)
        .unwrap();
    assert_eq!(available["completedRuns"], 2);
}

#[tokio::test]
async fn direct_tool_uses_narrow_schema_while_internal_invocation_keeps_full_schema() {
    let (runtime, _home) = test_runtime(None);
    let command = vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import json,sys; print(json.dumps(json.load(sys.stdin)))".to_owned(),
    ];
    let mut bundle = command_bundle(command);
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action"],
        "properties":{"action":{"enum":["public","internal"]}}
    });
    bundle.tool_input_schema = Some(json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action"],
        "properties":{"action":{"const":"public"}}
    }));
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let function_id = FunctionId::new(format!(
        "worker_kernel::dynamic_{}",
        outcome.worker.worker_id
    ))
    .unwrap();
    let inspection_actor = crate::engine::ActorContext::new(
        ActorId::new("system:narrow-tool-schema-test").unwrap(),
        ActorKind::System,
    );
    let definition = runtime
        .host
        .inspect_function(&function_id, &inspection_actor)
        .await
        .unwrap();
    assert_eq!(
        definition.request_schema.unwrap()["properties"]["action"]["const"],
        "public"
    );

    let direct_internal = runtime
        .host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"action":"internal"}),
            CausalContext::new(
                ActorId::new("agent:narrow-tool-schema-test").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-narrow-direct").unwrap(),
            )
            .with_session_id("session-narrow-direct")
            .with_idempotency_key("narrow-direct"),
        ))
        .await;
    assert!(direct_internal.error.is_some());

    let internal = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"action":"internal"}),
            "narrow-internal",
        ))
        .await
        .unwrap();
    assert_eq!(internal.status, "completed");
    assert_eq!(internal.output, Some(json!({"action":"internal"})));
    assert!(
        runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled
    );
}

#[tokio::test]
async fn command_runner_writes_only_to_its_disposable_runtime_copy() {
    let (runtime, home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "printf runtime > runtime-only.txt; printf '{\"isolated\":true}'".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();

    let record = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "runtime-copy",
        ))
        .await
        .unwrap();

    assert_eq!(record.output, Some(json!({"isolated":true})));
    assert!(
        !home
            .path()
            .join("workspace/workers")
            .join(&outcome.worker.worker_id)
            .join("versions")
            .join(&outcome.version)
            .join("files/runtime-only.txt")
            .exists(),
        "worker execution mutated its immutable canonical version"
    );
    assert!(
        !home
            .path()
            .join("internal/run/worker-invocations")
            .join(&record.invocation_id)
            .exists(),
        "terminal command runtime copy was not removed"
    );
}

#[tokio::test]
async fn update_routes_new_work_immediately_while_old_version_drains() {
    let (runtime, home) = test_runtime(None);
    let started = home.path().join("old-started");
    let release = home.path().join("release-old");
    let old_command = format!(
        "touch '{}'; while [ ! -f '{}' ]; do sleep 0.02; done; printf '{{\"version\":\"old\"}}'",
        started.display(),
        release.display()
    );
    let first = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), old_command]),
            None,
        )
        .await
        .unwrap();
    let worker_id = first.worker.worker_id.clone();
    let old_version = first.version.clone();
    let old_runtime = Arc::clone(&runtime);
    let old_worker = worker_id.clone();
    let old_run = tokio::spawn(async move {
        old_runtime
            .invoke(request(&old_worker, json!({}), "draining-old"))
            .await
            .unwrap()
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while !started.is_file() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();

    let mut updated = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "printf '{\"version\":\"new\"}'".to_owned(),
    ]);
    updated
        .description
        .push_str(" updated while prior work drains");
    let second = runtime.upsert(updated, Some(&worker_id)).await.unwrap();
    assert_ne!(second.version, old_version);
    let new_run = runtime
        .invoke(request(&worker_id, json!({}), "routed-new"))
        .await
        .unwrap();
    assert_eq!(new_run.worker_version, second.version);
    assert_eq!(new_run.output, Some(json!({"version":"new"})));

    std::fs::write(&release, "release").unwrap();
    let drained = old_run.await.unwrap();
    assert_eq!(drained.worker_version, old_version);
    assert_eq!(drained.output, Some(json!({"version":"old"})));
    assert_eq!(
        runtime
            .store()
            .load_active(&worker_id)
            .unwrap()
            .summary
            .active_version,
        second.version
    );
}
