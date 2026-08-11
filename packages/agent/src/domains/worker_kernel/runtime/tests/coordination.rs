use std::collections::HashSet;

use super::*;
use crate::shared::protocol::events::TronEvent;

#[test]
fn interaction_prediction_uses_runner_class_and_exact_version_p95() {
    let command = WorkerRunner::Command {
        command: vec!["true".to_owned()],
    };
    assert_eq!(
        super::super::admission::interaction_plan_from_evidence(
            &WorkerRunner::Agent {
                instructions: "bounded work".to_owned(),
                model: None,
                reasoning_level: None,
            },
            Vec::new(),
            Duration::from_secs(10),
        ),
        super::super::admission::InteractionPlan::Background
    );
    assert_eq!(
        super::super::admission::interaction_plan_from_evidence(
            &command,
            vec![Duration::from_secs(1); 4],
            Duration::from_secs(10),
        ),
        super::super::admission::InteractionPlan::ForegroundGrace
    );
    let mut slow_tail = vec![Duration::from_secs(2); 18];
    slow_tail.extend([Duration::from_secs(11), Duration::from_secs(12)]);
    assert_eq!(
        super::super::admission::interaction_plan_from_evidence(
            &command,
            slow_tail,
            Duration::from_secs(10),
        ),
        super::super::admission::InteractionPlan::Background
    );
}

#[tokio::test]
async fn model_tool_worker_invocation_streams_correlated_live_progress() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    runtime
        .orchestrator
        .init_sequence_counter("session-live", 0);
    let mut events = runtime.orchestrator.subscribe();
    let worker_id = outcome.worker.worker_id.clone();
    let record = runtime
        .invoke_from_model_tool(
            request(&worker_id, json!({"value":"hello"}), "live-progress"),
            ModelToolProgressTarget {
                session_id: "session-live".to_owned(),
                invocation_id: "provider-call-live".to_owned(),
                tool_name: outcome.worker.tool_name,
                worker_name: outcome.worker.name,
                trace_id: "trace-live-progress".to_owned(),
                root_invocation_id: Some("root-live".to_owned()),
            },
            None,
            None,
            None,
        )
        .await
        .unwrap();

    assert_eq!(record.status, "completed");
    assert_eq!(record.interaction_mode, WorkerInteractionMode::Foreground);
    let mut progress: Vec<String> = Vec::new();
    let mut output: Vec<String> = Vec::new();
    while let Ok(event) = events.try_recv() {
        match event {
            TronEvent::ToolInvocationProgress {
                invocation_id,
                message,
                ..
            } if invocation_id == "provider-call-live" => {
                progress.push(message.unwrap_or_default());
            }
            TronEvent::ToolInvocationOutput {
                invocation_id,
                update,
                ..
            } if invocation_id == "provider-call-live" => output.push(update),
            _ => {}
        }
    }
    assert!(progress.iter().any(|message| message.contains("Queued")));
    assert!(progress.iter().any(|message| message.contains("Running")));
    assert!(
        progress
            .iter()
            .any(|message| message.contains("Validating"))
    );
    assert!(output.iter().any(|message| message.contains("started")));
    assert!(runtime.model_tool_progress.is_empty());
}

#[tokio::test]
async fn reconstructed_parent_awaits_the_same_running_child_invocation() {
    let (runtime, _home) = test_runtime(None);
    let mut parent_bundle =
        command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    parent_bundle.name = "Recovery Parent".to_owned();
    parent_bundle.worker_id = Some("recovery-parent".to_owned());
    parent_bundle.tool_name = Some("worker_recovery_parent".to_owned());
    let parent_worker = runtime.upsert(parent_bundle, None).await.unwrap();

    let mut child_bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "sleep 0.2; cat".to_owned(),
    ]);
    child_bundle.name = "Recovery Child".to_owned();
    child_bundle.worker_id = Some("recovery-child".to_owned());
    child_bundle.tool_name = Some("worker_recovery_child".to_owned());
    let child_worker = runtime.upsert(child_bundle, None).await.unwrap();

    let (parent, replayed) = runtime
        .store
        .begin_invocation_with_context(
            &parent_worker.worker.worker_id,
            &parent_worker.version,
            &json!({"value":"parent"}),
            "recovery-parent-run",
            "trace-recovery-child",
            0,
            "manual",
            Some("session-before-restart"),
            WorkerInteractionMode::Background,
            Some("provider-parent-before-restart"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(!replayed);

    let child_request = InvokeRequest {
        worker_id: child_worker.worker.worker_id.clone(),
        input: json!({"value":"one durable child"}),
        idempotency_key: "stable-nested-child".to_owned(),
        trace_id: parent.trace_id.clone(),
        causal_depth: 1,
        trigger_kind: "manual".to_owned(),
        origin_session_id: Some("session-before-restart".to_owned()),
        model: None,
        reasoning_level: None,
    };
    let first_runtime = Arc::clone(&runtime);
    let first_request = child_request.clone();
    let parent_id = parent.invocation_id.clone();
    let child_tool_name = child_worker.worker.tool_name.clone();
    let child_name = child_worker.worker.name.clone();
    let first = tokio::spawn(async move {
        first_runtime
            .invoke_from_model_tool(
                first_request,
                ModelToolProgressTarget {
                    session_id: "session-before-restart".to_owned(),
                    invocation_id: "provider-child-before-restart".to_owned(),
                    tool_name: child_tool_name,
                    worker_name: child_name,
                    trace_id: "trace-recovery-child".to_owned(),
                    root_invocation_id: Some("provider-parent-before-restart".to_owned()),
                },
                Some(&parent_id),
                None,
                Some(0),
            )
            .await
    });

    tokio::time::sleep(Duration::from_millis(50)).await;

    let recovered_request = InvokeRequest {
        input: json!({"value":"provider regenerated different valid arguments"}),
        idempotency_key: "different-recovered-provider-call".to_owned(),
        origin_session_id: Some("session-after-restart".to_owned()),
        ..child_request
    };
    let recovered = runtime
        .invoke_from_model_tool(
            recovered_request,
            ModelToolProgressTarget {
                session_id: "session-after-restart".to_owned(),
                invocation_id: "provider-child-after-restart".to_owned(),
                tool_name: child_worker.worker.tool_name,
                worker_name: child_worker.worker.name,
                trace_id: parent.trace_id,
                root_invocation_id: Some("provider-parent-after-restart".to_owned()),
            },
            Some(&parent.invocation_id),
            None,
            Some(0),
        )
        .await
        .unwrap();
    let original = first.await.unwrap().unwrap();

    assert_eq!(original.status, "completed");
    assert_eq!(recovered.status, "completed");
    assert_eq!(recovered.invocation_id, original.invocation_id);
    assert_eq!(recovered.attempt_count, 1);
    let recovered_projection = runtime
        .store()
        .provider_result_projections(
            &["provider-child-after-restart".to_owned()],
            &[],
            &HashSet::from(["provider-child-after-restart".to_owned()]),
            &HashSet::new(),
            Some("session-before-restart"),
            Some("trace-recovery-child"),
        )
        .unwrap();
    assert_eq!(recovered_projection.len(), 1);
    assert_eq!(
        recovered_projection[0]["invocationId"],
        original.invocation_id
    );
    assert_eq!(
        recovered_projection[0]["providerValue"],
        json!({"value":"one durable child"})
    );
}

#[tokio::test]
async fn slow_top_level_model_tool_returns_a_durable_background_handle() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "sleep 0.2; cat".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();
    runtime
        .orchestrator
        .init_sequence_counter("session-background", 0);
    let worker_id = outcome.worker.worker_id.clone();

    let result = runtime
        .invoke_from_model_tool_with_grace(
            request(&worker_id, json!({"value":"hello"}), "background-progress"),
            ModelToolProgressTarget {
                session_id: "session-background".to_owned(),
                invocation_id: "provider-call-background".to_owned(),
                tool_name: outcome.worker.tool_name,
                worker_name: outcome.worker.name,
                trace_id: "trace-background-progress".to_owned(),
                root_invocation_id: Some("root-background".to_owned()),
            },
            Duration::from_millis(10),
        )
        .await
        .unwrap();

    let ModelToolInvocationOutcome::Background(background) = result else {
        panic!("slow invocation should have left the foreground");
    };
    assert!(matches!(background.status.as_str(), "queued" | "running"));
    assert_eq!(
        background.interaction_mode,
        WorkerInteractionMode::Background
    );
    assert!(background.detached_at.is_some());
    assert!(
        runtime
            .model_tool_progress
            .contains_key(&background.invocation_id)
    );
    let explicitly_detached = runtime
        .detach_invocation(&background.invocation_id)
        .await
        .unwrap();
    assert_eq!(explicitly_detached.invocation_id, background.invocation_id);
    assert!(matches!(
        explicitly_detached.status.as_str(),
        "queued" | "running"
    ));

    let (completed, timed_out) = runtime
        .await_invocation(&background.invocation_id, Duration::from_secs(2))
        .await
        .unwrap();
    assert!(!timed_out);
    assert_eq!(completed.status, "completed");
    tokio::task::yield_now().await;
    assert!(runtime.model_tool_progress.is_empty());
}

#[tokio::test]
async fn worker_declared_child_ceiling_is_transactional_and_causally_linked() {
    let (runtime, _home) = test_runtime(None);
    let mut parent_bundle =
        command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    parent_bundle.name = "Bounded Parent".to_owned();
    parent_bundle.worker_id = Some("bounded-parent".to_owned());
    parent_bundle.tool_name = Some("worker_bounded_parent".to_owned());
    parent_bundle.execution_limits.max_child_invocations = Some(2);
    let parent_worker = runtime.upsert(parent_bundle, None).await.unwrap();

    let mut child_bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    child_bundle.name = "Bounded Child".to_owned();
    child_bundle.worker_id = Some("bounded-child".to_owned());
    child_bundle.tool_name = Some("worker_bounded_child".to_owned());
    let child_worker = runtime.upsert(child_bundle, None).await.unwrap();

    let (parent, replayed) = runtime
        .store
        .begin_invocation_with_context(
            &parent_worker.worker.worker_id,
            &parent_worker.version,
            &json!({"value":"parent"}),
            "bounded-parent-run",
            "trace-bounded-children",
            0,
            "manual",
            Some("session-bounded"),
            WorkerInteractionMode::Background,
            Some("provider-parent"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(!replayed);

    for ordinal in 0..2 {
        let record = runtime
            .invoke_from_model_tool(
                InvokeRequest {
                    worker_id: child_worker.worker.worker_id.clone(),
                    input: json!({"value":ordinal}),
                    idempotency_key: format!("bounded-child-{ordinal}"),
                    trace_id: parent.trace_id.clone(),
                    causal_depth: 1,
                    trigger_kind: "manual".to_owned(),
                    origin_session_id: Some("session-bounded".to_owned()),
                    model: None,
                    reasoning_level: None,
                },
                ModelToolProgressTarget {
                    session_id: "session-bounded".to_owned(),
                    invocation_id: format!("provider-child-{ordinal}"),
                    tool_name: child_worker.worker.tool_name.clone(),
                    worker_name: child_worker.worker.name.clone(),
                    trace_id: parent.trace_id.clone(),
                    root_invocation_id: Some("provider-parent".to_owned()),
                },
                Some(&parent.invocation_id),
                None,
                Some(ordinal),
            )
            .await
            .unwrap();
        assert_eq!(
            record.parent_worker_invocation_id.as_deref(),
            Some(parent.invocation_id.as_str())
        );
    }

    let error = runtime
        .invoke_from_model_tool(
            InvokeRequest {
                worker_id: child_worker.worker.worker_id,
                input: json!({"value":3}),
                idempotency_key: "bounded-child-3".to_owned(),
                trace_id: parent.trace_id.clone(),
                causal_depth: 1,
                trigger_kind: "manual".to_owned(),
                origin_session_id: Some("session-bounded".to_owned()),
                model: None,
                reasoning_level: None,
            },
            ModelToolProgressTarget {
                session_id: "session-bounded".to_owned(),
                invocation_id: "provider-child-3".to_owned(),
                tool_name: child_worker.worker.tool_name,
                worker_name: child_worker.worker.name,
                trace_id: parent.trace_id,
                root_invocation_id: Some("provider-parent".to_owned()),
            },
            Some(&parent.invocation_id),
            None,
            Some(2),
        )
        .await
        .unwrap_err();
    assert!(error.contains("child invocation ceiling (2)"), "{error}");
}

#[tokio::test]
async fn terminal_retry_reuses_immutable_contract_and_is_idempotently_linked() {
    let (runtime, _home) = test_runtime(None);
    let worker = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let original = runtime
        .invoke(request(
            &worker.worker.worker_id,
            json!({"value":"original"}),
            "retry-original",
        ))
        .await
        .unwrap();
    assert_eq!(original.status, "completed");

    let retry = runtime
        .retry_from_provider_tool(
            &original.invocation_id,
            "retry-once".to_owned(),
            "trace-retry-once".to_owned(),
            0,
            Some("session-retry".to_owned()),
            Some("provider-retry"),
            None,
            None,
            None,
        )
        .await
        .unwrap();
    assert_ne!(retry.invocation_id, original.invocation_id);
    assert_eq!(retry.worker_id, original.worker_id);
    assert_eq!(retry.worker_version, original.worker_version);
    assert_eq!(retry.input, original.input);
    assert_eq!(
        retry.retry_of_invocation_id.as_deref(),
        Some(original.invocation_id.as_str())
    );
    assert_eq!(
        retry.model_tool_invocation_id.as_deref(),
        Some("provider-retry")
    );

    let replay = runtime
        .retry_from_provider_tool(
            &original.invocation_id,
            "retry-once".to_owned(),
            "trace-retry-once".to_owned(),
            0,
            Some("session-retry".to_owned()),
            Some("provider-retry"),
            None,
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(replay.invocation_id, retry.invocation_id);
    assert_eq!(replay.attempt_count, retry.attempt_count);
}

#[tokio::test]
async fn cancelling_an_invocation_cancels_only_its_durable_causal_subtree() {
    let (runtime, _home) = test_runtime(None);
    let worker = runtime
        .upsert(
            command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "sleep 30; cat".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();
    let parent = runtime
        .enqueue(InvokeRequest {
            worker_id: worker.worker.worker_id.clone(),
            input: json!({"value":"parent"}),
            idempotency_key: "cancel-tree-parent".to_owned(),
            trace_id: "trace-cancel-tree".to_owned(),
            causal_depth: 0,
            trigger_kind: "manual".to_owned(),
            origin_session_id: Some("session-cancel-tree".to_owned()),
            model: None,
            reasoning_level: None,
        })
        .unwrap();
    let mut children = Vec::new();
    for ordinal in 0..2 {
        children.push(
            runtime
                .enqueue_from_provider_tool(
                    InvokeRequest {
                        worker_id: worker.worker.worker_id.clone(),
                        input: json!({"value":ordinal}),
                        idempotency_key: format!("cancel-tree-child-{ordinal}"),
                        trace_id: parent.trace_id.clone(),
                        causal_depth: 1,
                        trigger_kind: "manual".to_owned(),
                        origin_session_id: parent.origin_session_id.clone(),
                        model: None,
                        reasoning_level: None,
                    },
                    Some(&format!("provider-cancel-tree-{ordinal}")),
                    Some(&parent.invocation_id),
                    None,
                    Some(ordinal),
                )
                .unwrap(),
        );
    }
    let unrelated = runtime
        .enqueue_from_provider_tool(
            InvokeRequest {
                worker_id: worker.worker.worker_id,
                input: json!({"value":"unrelated"}),
                idempotency_key: "cancel-tree-unrelated".to_owned(),
                trace_id: "trace-cancel-tree-unrelated".to_owned(),
                causal_depth: 0,
                trigger_kind: "manual".to_owned(),
                origin_session_id: Some("session-cancel-tree".to_owned()),
                model: None,
                reasoning_level: None,
            },
            Some("provider-cancel-tree-unrelated"),
            None,
            None,
            None,
        )
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    let cancelled = runtime
        .cancel_invocation(&parent.invocation_id)
        .await
        .unwrap();
    assert_eq!(cancelled.status, "cancelled");
    for child in children {
        assert_eq!(
            runtime
                .store
                .invocation(&child.invocation_id)
                .unwrap()
                .unwrap()
                .status,
            "cancelled"
        );
    }
    let unrelated_state = runtime
        .store
        .invocation(&unrelated.invocation_id)
        .unwrap()
        .unwrap();
    assert!(
        matches!(unrelated_state.status.as_str(), "queued" | "running"),
        "{unrelated_state:?}"
    );
    runtime
        .cancel_invocation(&unrelated.invocation_id)
        .await
        .unwrap();
}

#[tokio::test]
async fn cancelled_model_tool_wait_drops_its_transient_progress_bridge() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "sleep 30; cat".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();
    let invocation = tokio::spawn({
        let runtime = Arc::clone(&runtime);
        async move {
            runtime
                .invoke_from_model_tool(
                    request(
                        &outcome.worker.worker_id,
                        json!({"value":"hello"}),
                        "cancel-live-progress",
                    ),
                    ModelToolProgressTarget {
                        session_id: "session-live".to_owned(),
                        invocation_id: "provider-call-cancelled".to_owned(),
                        tool_name: outcome.worker.tool_name,
                        worker_name: outcome.worker.name,
                        trace_id: "trace-live-progress".to_owned(),
                        root_invocation_id: None,
                    },
                    None,
                    None,
                    None,
                )
                .await
        }
    });

    tokio::time::timeout(Duration::from_secs(2), async {
        while runtime.model_tool_progress.is_empty() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    invocation.abort();
    let _ = invocation.await;

    assert!(runtime.model_tool_progress.is_empty());
    runtime.set_stop_all(true).await.unwrap();
}

#[tokio::test]
async fn agent_worker_child_steps_update_only_the_originating_tool_chip() {
    let (runtime, _home) = test_runtime(None);
    runtime
        .orchestrator
        .init_sequence_counter("session-agent", 0);
    let mut events = runtime.orchestrator.subscribe();
    runtime.model_tool_progress.insert(
        "worker-run-agent".to_owned(),
        ModelToolProgressTarget {
            session_id: "session-agent".to_owned(),
            invocation_id: "provider-call-agent".to_owned(),
            tool_name: "worker_general_delegate".to_owned(),
            worker_name: "General Delegate".to_owned(),
            trace_id: "trace-agent".to_owned(),
            root_invocation_id: None,
        },
    );

    runtime.observe_agent_model_tool_progress(
        "worker-run-agent",
        &TronEvent::ToolInvocationStarted {
            base: crate::shared::protocol::events::BaseEvent::now("child-session"),
            invocation_id: "child-tool-call".to_owned(),
            tool_name: "filesystem_read".to_owned(),
            arguments: None,
            tool_identity: Default::default(),
        },
    );

    let progress = events.recv().await.unwrap();
    let output = events.recv().await.unwrap();
    assert!(matches!(
        progress,
        TronEvent::ToolInvocationProgress {
            invocation_id,
            message: Some(message),
            ..
        } if invocation_id == "provider-call-agent" && message == "Using Filesystem read"
    ));
    assert!(matches!(
        output,
        TronEvent::ToolInvocationOutput {
            invocation_id,
            update,
            ..
        } if invocation_id == "provider-call-agent" && update == "Started Filesystem read"
    ));
}

#[tokio::test]
async fn causal_ceiling_rejects_before_persisting_an_invocation() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let mut too_deep = request(&outcome.worker.worker_id, json!({}), "too-deep");
    too_deep.causal_depth = MAX_CAUSAL_DEPTH + 1;

    let error = runtime.invoke(too_deep).await.unwrap_err();

    assert!(error.contains("causal depth"));
    assert!(
        runtime
            .store()
            .runs_filtered(None, None, 10)
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn over_depth_engine_event_is_durably_suppressed_and_cursor_advances() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bundle.worker_id = Some("depth-suppression".to_owned());
    bundle.name = "Depth Suppression".to_owned();
    bundle.description =
        "Engine-event fixture proving terminal causal suppression does not jam delivery".to_owned();
    bundle.tool_name = Some("worker_depth_suppression".to_owned());
    bundle.triggers = vec![WorkerTrigger::EngineEvent {
        id: "depth-event".to_owned(),
        topic: "worker.depth-fixture".to_owned(),
        filter: json!({"ready":true}),
        input: json!({"kind":"event"}),
    }];
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let trace_id = TraceId::new("depth-suppression-trace").unwrap();
    runtime
        .publish_event(
            "worker.depth-fixture",
            json!({"ready":true,"causalDepth":MAX_CAUSAL_DEPTH}),
            Some(trace_id.clone()),
        )
        .await;

    let mut runs = JoinSet::new();
    runtime.dispatch_events(&mut runs).await;

    assert!(runs.is_empty());
    assert!(
        runtime
            .store()
            .runs_filtered(None, None, 10)
            .unwrap()
            .is_empty()
    );
    let trace = runtime
        .store()
        .trace(trace_id.as_str())
        .unwrap()
        .expect("suppressed trace");
    assert_eq!(trace["suppressedCount"], 1);
    assert_eq!(trace["maxCausalDepth"], MAX_CAUSAL_DEPTH + 1);
    let cursor_after_suppression = runtime
        .store()
        .event_triggers()
        .unwrap()
        .into_iter()
        .find(|(worker_id, _, _)| worker_id == &outcome.worker.worker_id)
        .expect("event trigger")
        .2;
    assert!(cursor_after_suppression > 0);

    runtime.dispatch_events(&mut runs).await;
    let trace_after_repoll = runtime
        .store()
        .trace(trace_id.as_str())
        .unwrap()
        .expect("suppressed trace after repoll");
    assert_eq!(trace_after_repoll["suppressedCount"], 1);
    let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
    assert!(inspection["audit"].as_array().unwrap().iter().any(|entry| {
        entry["action"] == "delivery_suppressed"
            && entry["details"]["reason"] == "causal_depth_limit"
    }));
}
#[tokio::test]
async fn invalid_engine_event_projection_disables_worker_instead_of_jamming_cursor() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bundle.worker_id = Some("invalid-event-materialization".to_owned());
    bundle.name = "Invalid Event Materialization".to_owned();
    bundle.description =
        "Engine-event fixture whose projected input intentionally lacks a required field"
            .to_owned();
    bundle.tool_name = Some("worker_invalid_event_materialization".to_owned());
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["kind","requiredValue"],
        "properties":{"kind":{"type":"string"},"requiredValue":{"type":"integer"}}
    });
    bundle.triggers = vec![WorkerTrigger::EngineEvent {
        id: "invalid-event".to_owned(),
        topic: "worker.invalid-event-fixture".to_owned(),
        filter: json!({"ready":true}),
        input: json!({"kind":"event"}),
    }];
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    runtime
        .publish_event(
            "worker.invalid-event-fixture",
            json!({"ready":true}),
            Some(TraceId::new("invalid-event-materialization-trace").unwrap()),
        )
        .await;

    let mut runs = JoinSet::new();
    runtime.dispatch_events(&mut runs).await;

    assert!(runs.is_empty());
    assert!(
        runtime
            .store()
            .runs_filtered(None, None, 10)
            .unwrap()
            .is_empty()
    );
    let summary = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!summary.enabled);
    assert_eq!(summary.health, "failed");
    let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
    assert!(inspection["triggers"][0]["streamCursor"].as_i64().unwrap() > 0);
    assert_eq!(inspection["triggers"][0]["enabled"], false);
    assert_eq!(inspection["healthHistory"][0]["source"], "trigger_dispatch");
    let inbox = runtime
        .store()
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert!(inbox.iter().any(|item| {
        item["result"]["phase"] == "trigger_dispatch" && item["result"]["disabled"] == true
    }));
}

#[tokio::test]
async fn engine_and_worker_concurrency_overflow_stays_durably_queued() {
    let (runtime, home) = test_runtime(None);
    let release_path = home.path().join("concurrency-release");
    let command = format!(
        "while [ ! -f \"{}\" ]; do sleep 0.05; done; cat",
        release_path.display()
    );
    let mut worker_ids = Vec::new();
    for index in 0..5 {
        let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), command.clone()]);
        bundle.worker_id = Some(format!("concurrency-{index}"));
        bundle.name = format!("Concurrency Fixture {index}");
        bundle.description =
            format!("Deterministic concurrency lane {index} with a distinct explicit identity");
        bundle.tool_name = Some(format!("worker_concurrency_{index}"));
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        assert_eq!(outcome.worker.worker_id, format!("concurrency-{index}"));
        worker_ids.push(outcome.worker.worker_id);
    }

    let mut tasks = Vec::new();
    for index in 0..40 {
        let runtime = Arc::clone(&runtime);
        let worker_id = worker_ids[index % worker_ids.len()].clone();
        tasks.push(tokio::spawn(async move {
            runtime
                .invoke(request(
                    &worker_id,
                    json!({"index":index}),
                    &format!("concurrency-{index}"),
                ))
                .await
        }));
    }

    // The full suite creates substantial concurrent SQLite and process load.
    // Keep the fixtures blocked so admission can reach both ceilings without
    // making this assertion depend on a short wall-clock race.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    let mut observed_limits = false;
    while tokio::time::Instant::now() < deadline {
        let runs = runtime.store().runs_filtered(None, None, 100).unwrap();
        let running = runs.iter().filter(|run| run.status == "running").count();
        let queued = runs.iter().filter(|run| run.status == "queued").count();
        if runtime.engine_limit.available_permits() == 0
            && running <= MAX_ENGINE_CONCURRENCY
            && queued >= 8
        {
            observed_limits = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    std::fs::write(&release_path, b"release").unwrap();
    assert!(
        observed_limits,
        "engine overflow was not observed as queued"
    );
    assert_eq!(runtime.engine_limit.available_permits(), 0);
    for worker_id in &worker_ids {
        let running = runtime
            .store()
            .runs_filtered(Some(worker_id), None, 100)
            .unwrap()
            .iter()
            .filter(|run| run.status == "running")
            .count();
        assert!(running <= MAX_WORKER_CONCURRENCY);
    }

    for task in tasks {
        let record = task.await.unwrap().unwrap();
        assert_eq!(record.status, "completed");
    }
    assert_eq!(
        runtime
            .store()
            .runs_filtered(None, None, 100)
            .unwrap()
            .len(),
        40
    );
}

#[tokio::test]
async fn stop_all_blocks_new_dispatch_but_preserves_and_resumes_queued_work() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let queued = runtime
        .enqueue(request(
            &outcome.worker.worker_id,
            json!({"preserved":true}),
            "preserved-queue",
        ))
        .unwrap();
    assert_eq!(queued.status, "queued");

    runtime.set_stop_all(true).await.unwrap();
    assert!(
        runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"blocked":true}),
                "blocked-new",
            ))
            .await
            .unwrap_err()
            .contains("stopped")
    );
    assert_eq!(
        runtime
            .store()
            .invocation(&queued.invocation_id)
            .unwrap()
            .unwrap()
            .status,
        "queued"
    );

    runtime.set_stop_all(false).await.unwrap();
    let resumed = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"ignored":"idempotent replay uses durable input"}),
            "preserved-queue",
        ))
        .await
        .unwrap();
    assert_eq!(resumed.status, "completed");
    assert_eq!(resumed.output, Some(json!({"preserved":true})));
}

#[tokio::test]
async fn disabling_a_worker_stops_its_active_invocation() {
    let (runtime, home) = test_runtime(None);
    let child_started = home.path().join("disable-descendant-started");
    let child_survived = home.path().join("disable-descendant-survived");
    let mut bundle = command_bundle(vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import pathlib,subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import pathlib,sys,time; time.sleep(.4); pathlib.Path(sys.argv[1]).write_text(\"survived\")',sys.argv[2]]); pathlib.Path(sys.argv[1]).write_text('started'); time.sleep(30)".to_owned(),
            child_started.display().to_string(),
            child_survived.display().to_string(),
        ]);
    bundle.triggers = vec![WorkerTrigger::Manual {
        id: "manual".to_owned(),
    }];
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id;
    let invoking = {
        let runtime = Arc::clone(&runtime);
        let worker_id = worker_id.clone();
        tokio::spawn(async move {
            runtime
                .invoke(request(&worker_id, json!({}), "disable-running"))
                .await
        })
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline {
        if child_started.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(child_started.exists(), "worker descendant never started");

    runtime.set_enabled(&worker_id, false).await.unwrap();
    let result = invoking.await.unwrap().unwrap();
    assert_eq!(result.status, "cancelled");
    assert!(result.error.unwrap().contains("disabled"));
    assert!(
        !runtime
            .store()
            .summary(&worker_id)
            .unwrap()
            .unwrap()
            .enabled
    );
    let disabled = runtime.store().inspect(&worker_id).unwrap();
    assert_eq!(disabled["route"]["enabled"], false);
    assert_eq!(disabled["triggers"][0]["enabled"], false);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !child_survived.exists(),
        "worker descendant survived disable"
    );

    runtime.set_enabled(&worker_id, true).await.unwrap();
    let enabled = runtime.store().inspect(&worker_id).unwrap();
    assert_eq!(enabled["route"]["enabled"], true);
    assert_eq!(enabled["triggers"][0]["enabled"], true);
}

#[tokio::test]
async fn invocation_cancel_is_precise_for_queued_and_running_work() {
    let (runtime, home) = test_runtime(None);
    let started = home.path().join("cancel-started");
    let survived = home.path().join("cancel-survived");
    let mut bundle = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('started'); time.sleep(30); pathlib.Path(sys.argv[2]).write_text('survived')".to_owned(),
        started.display().to_string(),
        survived.display().to_string(),
    ]);
    bundle.worker_id = Some("precise-cancel".to_owned());
    bundle.name = "Precise Cancel".to_owned();
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let queued = runtime
        .enqueue(request(
            &outcome.worker.worker_id,
            json!({}),
            "queued-cancel",
        ))
        .unwrap();
    let cancelled_queued = runtime
        .cancel_invocation(&queued.invocation_id)
        .await
        .unwrap();
    assert_eq!(cancelled_queued.status, "cancelled");
    assert!(cancelled_queued.started_at.is_none());

    let running = {
        let runtime = Arc::clone(&runtime);
        let worker_id = outcome.worker.worker_id.clone();
        tokio::spawn(async move {
            runtime
                .invoke(request(&worker_id, json!({}), "running-cancel"))
                .await
        })
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline && !started.exists() {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(started.exists(), "running worker never started");
    let run_id = runtime
        .store()
        .runs_filtered(Some(&outcome.worker.worker_id), Some("running"), 10)
        .unwrap()
        .into_iter()
        .next()
        .expect("running invocation")
        .invocation_id;
    let cancelled_running = runtime.cancel_invocation(&run_id).await.unwrap();
    assert_eq!(cancelled_running.status, "cancelled");
    let joined = running.await.unwrap().unwrap();
    assert_eq!(joined.status, "cancelled");
    assert!(
        runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled
    );
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(
        !survived.exists(),
        "cancelled process continued after terminalization"
    );
    let inbox = runtime
        .store()
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(
        inbox
            .iter()
            .filter(|item| item["result"]["status"] == "cancelled")
            .count(),
        2
    );
}

#[tokio::test]
async fn stopping_one_worker_cancels_current_work_without_disabling_future_dispatch() {
    let (runtime, home) = test_runtime(None);
    let child_started = home.path().join("stop-descendant-started");
    let child_survived = home.path().join("stop-descendant-survived");
    let mut bundle = command_bundle(vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,pathlib,subprocess,sys,time; request=json.load(sys.stdin); block=request.get('block',False); subprocess.Popen([sys.executable,'-c','import pathlib,sys,time; time.sleep(.4); pathlib.Path(sys.argv[1]).write_text(\"survived\")',sys.argv[2]]) if block else None; pathlib.Path(sys.argv[1]).write_text('started') if block else None; time.sleep(30) if block else None; print(json.dumps(request))".to_owned(),
            child_started.display().to_string(),
            child_survived.display().to_string(),
        ]);
    bundle.triggers = vec![WorkerTrigger::Manual {
        id: "manual".to_owned(),
    }];
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id;
    let invoking = {
        let runtime = Arc::clone(&runtime);
        let worker_id = worker_id.clone();
        tokio::spawn(async move {
            runtime
                .invoke(request(&worker_id, json!({"block":true}), "stop-running"))
                .await
        })
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline {
        if child_started.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(child_started.exists(), "worker descendant never started");

    let stopped = runtime.stop_worker(&worker_id).await.unwrap();
    assert_eq!(stopped["enabled"], true);
    assert_eq!(stopped["retired"], false);
    let result = invoking.await.unwrap().unwrap();
    assert_eq!(result.status, "cancelled");
    assert!(result.error.unwrap().contains("stopped"));
    let inspection = runtime.store().inspect(&worker_id).unwrap();
    assert_eq!(inspection["worker"]["enabled"], true);
    assert_eq!(inspection["worker"]["health"], "healthy");
    assert_eq!(inspection["route"]["enabled"], true);
    assert_eq!(inspection["triggers"][0]["enabled"], true);
    assert!(
        inspection["audit"]
            .as_array()
            .is_some_and(|audit| { audit.iter().any(|entry| entry["action"] == "stopped") })
    );
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !child_survived.exists(),
        "worker descendant survived per-worker stop"
    );

    let resumed = runtime
        .invoke(request(
            &worker_id,
            json!({"block":false,"value":"after-stop"}),
            "after-stop",
        ))
        .await
        .unwrap();
    assert_eq!(resumed.status, "completed");
    assert_eq!(
        resumed.output,
        Some(json!({"block":false,"value":"after-stop"}))
    );
}

#[tokio::test]
async fn aborting_a_claimed_execution_future_interrupts_and_requeues_it_immediately() {
    let (runtime, home) = test_runtime(None);
    let marker = home.path().join("claimed-future-started");
    let bundle = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import json,pathlib,sys,time; marker=pathlib.Path(sys.argv[1]); first=not marker.exists(); marker.write_text('started'); time.sleep(30) if first else None; print(json.dumps({'ok':True}))".to_owned(),
        marker.display().to_string(),
    ]);
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id;
    let delivery = {
        let runtime = Arc::clone(&runtime);
        let worker_id = worker_id.clone();
        tokio::spawn(async move {
            runtime
                .invoke(request(&worker_id, json!({}), "abort-claimed-future"))
                .await
        })
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline && !marker.exists() {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(marker.exists(), "claimed worker process never started");
    let running = runtime
        .store()
        .runs_filtered(Some(&worker_id), Some("running"), 10)
        .unwrap();
    assert_eq!(running.len(), 1);
    let invocation_id = running[0].invocation_id.clone();

    delivery.abort();
    let _ = delivery.await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        let record = runtime.store().invocation(&invocation_id).unwrap().unwrap();
        if record.status == "queued" {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "drop finalizer did not requeue the claimed attempt"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let attempts = runtime.store().attempts(&invocation_id).unwrap();
    assert_eq!(attempts.len(), 1);
    assert_eq!(attempts[0]["status"], "interrupted");

    let completed = runtime
        .invoke(request(&worker_id, json!({}), "abort-claimed-future"))
        .await
        .unwrap();
    assert_eq!(completed.invocation_id, invocation_id);
    assert_eq!(completed.status, "completed");
    assert_eq!(completed.attempt_count, 2);
}

#[tokio::test]
async fn third_orphan_recovery_creates_one_durable_attention_item() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec![
                "python3".to_owned(),
                "-c".to_owned(),
                "import json; print(json.dumps({'ok':True}))".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();

    for index in 1..=3 {
        let (run, _) = runtime
            .store()
            .begin_invocation(
                &outcome.worker.worker_id,
                &outcome.version,
                &json!({"index":index}),
                &format!("orphan-attention-{index}"),
                &format!("trace-orphan-attention-{index}"),
                0,
                "manual",
                None,
            )
            .unwrap();
        assert!(runtime.store().claim_running(&run.invocation_id).unwrap());
        runtime.reconcile_orphaned_invocations(true).await;
    }

    let attention = runtime
        .store()
        .inbox_filtered_page(Some(&outcome.worker.worker_id), None, None, true, 20, 0)
        .unwrap();
    let orphan_attention = attention
        .iter()
        .filter(|item| item["result"]["phase"] == "orphan_recovery")
        .collect::<Vec<_>>();
    assert_eq!(orphan_attention.len(), 1);
    assert_eq!(orphan_attention[0]["result"]["recoveryCount"], 3);
}

#[tokio::test]
async fn shutdown_cancels_process_trees_and_restart_redelivers_the_interrupted_attempt() {
    let (runtime, home) = test_runtime(None);
    let child_started = home.path().join("shutdown-descendant-started");
    let child_survived = home.path().join("shutdown-descendant-survived");
    let bundle = command_bundle(vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,pathlib,subprocess,sys,time; started=pathlib.Path(sys.argv[1]); survived=pathlib.Path(sys.argv[2]); print(json.dumps({})) if started.exists() else (subprocess.Popen([sys.executable,'-c','import pathlib,sys,time; time.sleep(.4); pathlib.Path(sys.argv[1]).write_text(\"survived\")',str(survived)]),started.write_text('started'),time.sleep(30))".to_owned(),
            child_started.display().to_string(),
            child_survived.display().to_string(),
        ]);
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id;
    let invoking = {
        let runtime = Arc::clone(&runtime);
        let worker_id = worker_id.clone();
        tokio::spawn(async move {
            runtime
                .invoke(request(&worker_id, json!({}), "shutdown-running"))
                .await
        })
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline {
        if child_started.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(child_started.exists(), "worker descendant never started");

    runtime.shutdown().await;
    let interrupted = invoking.await.unwrap().unwrap();
    assert_eq!(interrupted.status, "queued");
    let interrupted = runtime
        .store()
        .runs_filtered(Some(&worker_id), None, 10)
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(interrupted.status, "queued");
    assert_eq!(interrupted.attempt_count, 1);
    let summary = runtime.store().summary(&worker_id).unwrap().unwrap();
    assert!(summary.enabled);
    assert_eq!(summary.health, "healthy");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !child_survived.exists(),
        "worker descendant survived runtime shutdown"
    );

    let restarted = test_runtime_at(home.path(), None);
    let recovered = restarted
        .invoke(request(&worker_id, json!({}), "shutdown-running"))
        .await
        .unwrap();
    assert_eq!(recovered.status, "completed");
    assert_eq!(recovered.attempt_count, 2);
    let attempts = restarted
        .store()
        .attempts(&recovered.invocation_id)
        .unwrap();
    assert_eq!(attempts[0]["status"], "interrupted");
    assert_eq!(attempts[1]["status"], "completed");
}

#[tokio::test]
async fn every_worker_console_lifecycle_mutation_emits_live_refresh_evidence() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let worker_id = outcome.worker.worker_id;
    let version = outcome.version;

    runtime.set_enabled(&worker_id, false).await.unwrap();
    runtime.set_enabled(&worker_id, true).await.unwrap();
    runtime.stop_worker(&worker_id).await.unwrap();
    runtime.rollback(&worker_id, &version).await.unwrap();
    runtime.retire(&worker_id).await.unwrap();
    runtime.purge(&worker_id).await.unwrap();
    runtime.set_stop_all(true).await.unwrap();
    runtime.set_stop_all(false).await.unwrap();

    let events = runtime
        .host
        .poll_stream_topic(
            "worker.lifecycle",
            StreamCursor(0),
            100,
            &StreamActorScope::all(),
        )
        .await
        .unwrap();
    let actions = events
        .events
        .iter()
        .filter_map(|event| event.payload["action"].as_str())
        .collect::<BTreeSet<_>>();
    for expected in [
        "activated",
        "disabled",
        "enabled",
        "stopped",
        "rolled_back",
        "retired",
        "purged",
        "stop_all",
        "resumed_all",
    ] {
        assert!(
            actions.contains(expected),
            "missing {expected}: {actions:?}"
        );
    }
    assert!(
        events.events.iter().all(|event| event.session_id.is_none()),
        "worker lifecycle invalidations remain global"
    );
}

#[tokio::test]
async fn worker_invocation_invalidations_carry_only_the_durable_origin_session() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let mut scoped_request = request(
        &outcome.worker.worker_id,
        json!({"scope":"session"}),
        "scoped-invalidation",
    );
    scoped_request.origin_session_id = Some("session-invalidation".to_owned());
    let scoped = runtime.invoke(scoped_request).await.unwrap();
    let unscoped = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"scope":"global"}),
            "unscoped-invalidation",
        ))
        .await
        .unwrap();

    let page = runtime
        .host()
        .poll_stream_topic(
            "worker.invocations",
            StreamCursor(0),
            100,
            &StreamActorScope::all(),
        )
        .await
        .unwrap();
    let scoped_events = page
        .events
        .iter()
        .filter(|event| event.payload["invocationId"] == scoped.invocation_id)
        .collect::<Vec<_>>();
    let unscoped_events = page
        .events
        .iter()
        .filter(|event| event.payload["invocationId"] == unscoped.invocation_id)
        .collect::<Vec<_>>();
    assert!(!scoped_events.is_empty());
    assert!(
        scoped_events
            .iter()
            .all(|event| event.session_id.as_deref() == Some("session-invalidation"))
    );
    assert!(!unscoped_events.is_empty());
    assert!(
        unscoped_events
            .iter()
            .all(|event| event.session_id.is_none())
    );
}

#[tokio::test]
async fn schedule_event_and_authenticated_webhook_share_the_durable_dispatch_path() {
    let (runtime, home) = test_runtime(None);
    let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bundle.worker_id = Some("automation-reminders".to_owned());
    bundle.name = "Automation Reminders".to_owned();
    bundle.tool_name = Some("worker_all_triggers".to_owned());
    bundle.triggers = vec![
        WorkerTrigger::Manual {
            id: "manual".to_owned(),
        },
        WorkerTrigger::Schedule {
            id: "scheduled".to_owned(),
            every_seconds: 1,
            input: json!({"kind":"schedule"}),
        },
        WorkerTrigger::EngineEvent {
            id: "engine-event".to_owned(),
            topic: "worker.fixture".to_owned(),
            filter: json!({"ready":true,"nested":{"state":"active"}}),
            input: json!({"kind":"event"}),
        },
        WorkerTrigger::Webhook {
            id: "local-webhook".to_owned(),
            input: json!({"kind":"webhook"}),
        },
    ];
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    assert_eq!(outcome.webhooks.len(), 1);
    let credential = &outcome.webhooks[0];
    assert!(
        runtime
            .store()
            .verify_webhook(
                &outcome.worker.worker_id,
                &credential.trigger_id,
                "wrong-token"
            )
            .is_err()
    );
    let mut webhook_input = runtime
        .store()
        .verify_webhook(
            &outcome.worker.worker_id,
            &credential.trigger_id,
            &credential.token,
        )
        .unwrap();
    webhook_input
        .as_object_mut()
        .unwrap()
        .insert("payload".to_owned(), json!(1));
    let webhook = runtime
        .invoke(InvokeRequest {
            worker_id: outcome.worker.worker_id.clone(),
            input: webhook_input,
            idempotency_key: "webhook:local-webhook:request-1".to_owned(),
            trace_id: "webhook-trace".to_owned(),
            causal_depth: 0,
            trigger_kind: "webhook".to_owned(),
            origin_session_id: None,
            model: None,
            reasoning_level: None,
        })
        .await
        .unwrap();
    assert_eq!(webhook.status, "completed");

    runtime
        .publish_event(
            "worker.fixture",
            json!({"ready":true,"nested":{"state":"active","extra":1}}),
            Some(TraceId::new("fixture-event-trace").unwrap()),
        )
        .await;
    let mut event_runs = JoinSet::new();
    runtime.dispatch_events(&mut event_runs).await;
    while event_runs.join_next().await.is_some() {}

    tokio::time::sleep(Duration::from_millis(1_100)).await;
    let mut schedule_runs = JoinSet::new();
    runtime.dispatch_schedules(&mut schedule_runs).await;
    while schedule_runs.join_next().await.is_some() {}

    let runs = runtime
        .store()
        .runs_filtered(Some(&outcome.worker.worker_id), None, 20)
        .unwrap();
    assert!(runs.iter().any(|run| run.trigger_kind == "webhook"));
    assert!(runs.iter().any(|run| run.trigger_kind == "engine_event"));
    assert!(runs.iter().any(|run| run.trigger_kind == "schedule"));
    assert!(runs.iter().all(|run| run.status == "completed"));
    let history = runtime
        .store()
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 20)
        .unwrap();
    assert!(history.iter().any(|item| {
        item["triggerKind"] == "schedule"
            && item["severity"] == "info"
            && item["requiresAttention"] == false
    }));
    assert!(
        runtime
            .store()
            .inbox_filtered_page(Some(&outcome.worker.worker_id), None, None, true, 20, 0,)
            .unwrap()
            .is_empty(),
        "completed reminder trigger outcomes stay in history without becoming Attention"
    );
    let durable_bytes =
        std::fs::read(home.path().join("internal/database/workers.sqlite")).unwrap();
    assert!(!String::from_utf8_lossy(&durable_bytes).contains(&credential.token));
    assert!(
        !walkdir::WalkDir::new(home.path().join("workspace/workers"))
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file())
            .any(|entry| {
                std::fs::read(entry.path())
                    .is_ok_and(|bytes| String::from_utf8_lossy(&bytes).contains(&credential.token))
            })
    );
}

#[tokio::test]
async fn dependency_or_smoke_failure_never_changes_active_version() {
    let (runtime, home) = test_runtime(None);
    let first = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let active = first.version;

    let dependency = home.path().join("dependency");
    std::fs::create_dir_all(&dependency).unwrap();
    std::fs::write(dependency.join("source.txt"), "locked").unwrap();
    let mut bad_dependency =
        command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bad_dependency.description.push_str(" updated");
    bad_dependency.dependencies.push(WorkerDependency {
        name: "upstream".to_owned(),
        source: format!("file://{}", dependency.display()),
        version: "1".to_owned(),
        checksum: Some(format!("sha256:{}", "0".repeat(64))),
        install: None,
    });
    assert!(
        runtime
            .upsert(bad_dependency, Some("echo-worker"))
            .await
            .unwrap_err()
            .contains("checksum mismatch")
    );

    let mut bad_smoke = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bad_smoke.description.push_str(" smoke update");
    bad_smoke.smoke_tests.push(WorkerCommand {
        command: vec!["sh".to_owned(), "-c".to_owned(), "exit 9".to_owned()],
        timeout_seconds: 5,
    });
    assert!(
        runtime
            .upsert(bad_smoke, Some("echo-worker"))
            .await
            .is_err()
    );
    let mut bad_health = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    bad_health.description.push_str(" health update");
    bad_health.health_checks.push(WorkerCommand {
        command: vec!["sh".to_owned(), "-c".to_owned(), "exit 10".to_owned()],
        timeout_seconds: 5,
    });
    assert!(
        runtime
            .upsert(bad_health, Some("echo-worker"))
            .await
            .is_err()
    );
    assert_eq!(
        runtime
            .store()
            .summary("echo-worker")
            .unwrap()
            .unwrap()
            .active_version,
        active
    );
}

#[tokio::test]
async fn post_activation_failure_disables_worker_and_enters_inbox() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "echo execution-failed >&2; exit 7".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();
    let result = runtime
        .invoke(request(&outcome.worker.worker_id, json!({}), "failure"))
        .await
        .unwrap();

    assert_eq!(result.status, "failed");
    let summary = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!summary.enabled);
    assert_eq!(summary.health, "failed");
    let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
    assert_eq!(inspection["route"]["enabled"], false);
    assert_eq!(inspection["healthHistory"][0]["status"], "failed");
    let inbox = runtime
        .store()
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(inbox[0]["severity"], "error");
    assert!(
        runtime
            .store()
            .audit(Some(&outcome.worker.worker_id), 10)
            .unwrap()
            .iter()
            .any(|item| item["action"] == "failed")
    );
}

#[tokio::test]
async fn canonical_version_tampering_disables_routing_before_execution() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let active = runtime
        .store()
        .load_active(&outcome.worker.worker_id)
        .unwrap();
    std::fs::write(active.version_dir.join("files/tampered.txt"), "changed").unwrap();

    let record = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "tampered-version",
        ))
        .await
        .unwrap();

    assert_eq!(record.status, "failed", "{record:?}");
    assert!(
        record
            .error
            .as_deref()
            .is_some_and(|error| error.contains("integrity check failed")),
        "{record:?}"
    );
    assert_eq!(record.attempt_count, 1);
    assert_eq!(
        runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        false
    );
    assert_eq!(
        runtime
            .store()
            .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
            .unwrap()
            .len(),
        1
    );
    assert!(
        runtime
            .host
            .inspect_function(
                &FunctionId::new(format!(
                    "worker_kernel::dynamic_{}",
                    outcome.worker.worker_id
                ))
                .unwrap(),
                &system_actor(),
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn direct_tool_activation_failure_cannot_leave_an_enabled_unroutable_worker() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();

    let reason = runtime
        .handle_tool_activation_failure(
            &outcome.worker.worker_id,
            &outcome.version,
            "enable",
            "synthetic catalog collision",
        )
        .await;

    assert!(reason.contains("synthetic catalog collision"));
    let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
    assert_eq!(inspection["worker"]["enabled"], false);
    assert_eq!(inspection["route"]["enabled"], false);
    assert_eq!(inspection["healthHistory"][0]["status"], "failed");
    let inbox = runtime
        .store()
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(inbox[0]["severity"], "error");
    assert_eq!(inbox[0]["result"]["phase"], "enable");
    assert!(
        runtime
            .host
            .inspect_function(
                &FunctionId::new(format!(
                    "worker_kernel::dynamic_{}",
                    outcome.worker.worker_id
                ))
                .unwrap(),
                &system_actor(),
            )
            .await
            .is_err()
    );
}
