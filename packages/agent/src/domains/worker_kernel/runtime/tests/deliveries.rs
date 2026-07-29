use super::*;

struct DeliveryWaitResponder {
    contexts: Arc<std::sync::Mutex<Vec<String>>>,
}

#[async_trait]
impl ModelResponder for DeliveryWaitResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::OpenAi,
            provider_name: "delivery-wait-test",
            model: "mock".to_owned(),
            context_window: 200_000,
        }
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        self.contexts
            .lock()
            .unwrap()
            .push(serde_json::to_string(&request.context).unwrap());
        let text = "Resumed from the durable worker result.";
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: text.to_owned(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(text)],
                        token_usage: None,
                    },
                    stop_reason: "end_turn".to_owned(),
                }),
            ])) as ModelResponseStream,
        })
    }
}

struct DeliveryWaitResponderFactory {
    contexts: Arc<std::sync::Mutex<Vec<String>>>,
}

#[async_trait]
impl ModelResponderFactory for DeliveryWaitResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(DeliveryWaitResponder {
            contexts: self.contexts.clone(),
        }))
    }
}

#[tokio::test]
async fn registered_wait_resumes_once_from_terminal_outbox_without_a_user_message() {
    let contexts = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (runtime, _home) = test_runtime(Some(Arc::new(DeliveryWaitResponderFactory {
        contexts: contexts.clone(),
    })));
    let published = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Wait target"), None)
        .unwrap()
        .session;
    let trace_id = "trace-durable-wait-resume";
    let (worker_run, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({"message":"finish later"}),
            "durable-wait-worker",
            trace_id,
            0,
            "manual",
            Some(&session.id),
            WorkerInteractionMode::Background,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let wait_call = Invocation::new_sync(
        FunctionId::new("worker_kernel::agent_wait_for_workers").unwrap(),
        json!({"invocationIds":[worker_run.invocation_id.clone()],"mode":"all"}),
        CausalContext::new(
            ActorId::new("agent:wait-test").unwrap(),
            ActorKind::Agent,
            TraceId::new(trace_id).unwrap(),
        )
        .with_session_id(session.id.clone())
        .with_workspace_id(session.workspace_id.clone()),
    );
    let registered = runtime.agent_wait_for_workers(&wait_call).await.unwrap();
    assert_eq!(registered["status"], "pending");
    assert!(
        runtime
            .store
            .claim_running(&worker_run.invocation_id)
            .unwrap()
    );
    runtime
        .store
        .complete_invocation(
            &worker_run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({
                "message":"Background worker finished successfully.",
                "completed":true
            })),
        )
        .unwrap();

    runtime.import_agent_delivery_outbox().await;
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let deliveries = runtime
                .event_store
                .list_agent_deliveries_for_session(&session.id, 10)
                .unwrap();
            if deliveries
                .iter()
                .any(|delivery| delivery.projection_status() == "observed")
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("delivery-only continuation should complete");

    let waits = runtime
        .event_store
        .list_agent_waits_for_session(&session.id, 10)
        .unwrap();
    assert_eq!(waits.len(), 1);
    assert_eq!(waits[0].disposition, "satisfied");
    let replay = runtime.agent_wait_for_workers(&wait_call).await.unwrap();
    assert_eq!(replay["waitId"], registered["waitId"]);
    assert_eq!(replay["status"], "satisfied");
    assert_eq!(
        replay["deliveryIds"][0],
        waits[0].delivery_id.as_deref().unwrap()
    );
    let deliveries = runtime
        .event_store
        .list_agent_deliveries_for_session(&session.id, 10)
        .unwrap();
    assert_eq!(
        deliveries.len(),
        1,
        "the explicit wait must replace the default passive worker delivery"
    );
    assert_eq!(
        deliveries[0].wake_policy,
        crate::domains::session::event_store::AgentDeliveryWakePolicy::Wake
    );
    assert_eq!(deliveries[0].projection_status(), "observed");
    let rows = runtime
        .event_store
        .get_events_by_session(
            &session.id,
            &crate::domains::session::event_store::ListEventsOptions::default(),
        )
        .unwrap();
    assert!(rows.iter().all(|row| row.event_type != "message.user"));
    let assistant = rows
        .iter()
        .find(|row| row.event_type == "message.assistant")
        .expect("delivery-only assistant continuation");
    let payload: Value = serde_json::from_str(&assistant.payload).unwrap();
    assert_eq!(
        payload["agentDeliveryContinuation"]["deliveries"][0]["sourceWorkerId"],
        published.worker.worker_id
    );
    assert_eq!(
        payload["agentDeliveryContinuation"]["deliveries"][0]["sourceWorkerName"],
        "Echo Worker"
    );
    assert_eq!(
        payload["agentDeliveryContinuation"]["deliveries"][0]["triggeredWake"],
        true
    );
    let contexts = contexts.lock().unwrap();
    assert_eq!(contexts.len(), 1);
    assert!(contexts[0].contains("worker_wait"));
    assert!(contexts[0].contains("Background worker finished successfully."));
}

#[tokio::test]
async fn poison_outbox_rejection_does_not_block_a_later_terminal_import() {
    let (runtime, _home) = test_runtime(None);
    let published = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Delivery target"), None)
        .unwrap()
        .session;

    let complete_detached = |suffix: &str, origin_session_id: &str| {
        let (run, _) = runtime
            .store
            .begin_invocation_with_context(
                &published.worker.worker_id,
                &published.version,
                &json!({"suffix":suffix}),
                &format!("outbox-{suffix}"),
                &format!("trace-{suffix}"),
                0,
                "manual",
                Some(origin_session_id),
                WorkerInteractionMode::Background,
                None,
                None,
                None,
                None,
                None,
            )
            .unwrap();
        assert!(runtime.store.claim_running(&run.invocation_id).unwrap());
        runtime
            .store
            .complete_invocation(
                &run.invocation_id,
                &published.worker.worker_id,
                Ok(&json!({"summary":suffix})),
            )
            .unwrap();
        run.invocation_id
    };

    let rejected_invocation = complete_detached("deleted-target", "session-does-not-exist");
    let imported_invocation = complete_detached("valid-target", &session.id);
    let pending = runtime.store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(pending.len(), 2);

    runtime.import_agent_delivery_outbox().await;

    let rejected = runtime
        .store
        .agent_delivery_outbox(&pending[0].outbox_id)
        .unwrap()
        .unwrap();
    let imported = runtime
        .store
        .agent_delivery_outbox(&pending[1].outbox_id)
        .unwrap()
        .unwrap();
    assert_eq!(rejected.invocation_id, rejected_invocation);
    assert_eq!(rejected.disposition, "rejected");
    assert_eq!(imported.invocation_id, imported_invocation);
    assert_eq!(imported.disposition, "imported");

    let deliveries = runtime
        .event_store
        .list_agent_deliveries_for_session(&session.id, 10)
        .unwrap();
    assert_eq!(deliveries.len(), 1);
    assert_eq!(
        deliveries[0].result_invocation_id.as_deref(),
        Some(imported_invocation.as_str())
    );
    assert_eq!(
        runtime
            .store
            .inbox_filtered(Some(&published.worker.worker_id), None, Some("error"), 20)
            .unwrap()
            .iter()
            .filter(|item| item["result"]["phase"] == "agent_delivery_import")
            .count(),
        1
    );
}

#[tokio::test]
async fn failed_detached_delivery_carries_evidence_without_an_unreadable_result_grant() {
    let (runtime, _home) = test_runtime(None);
    let published = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Delivery target"), None)
        .unwrap()
        .session;
    let (run, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "failed-detached-delivery",
            "trace-failed-detached-delivery",
            0,
            "manual",
            Some(&session.id),
            WorkerInteractionMode::Background,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(runtime.store.claim_running(&run.invocation_id).unwrap());
    runtime
        .store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Err("expected failure"),
        )
        .unwrap();

    runtime.import_agent_delivery_outbox().await;
    let deliveries = runtime
        .event_store
        .list_agent_deliveries_for_session(&session.id, 10)
        .unwrap();
    assert_eq!(deliveries.len(), 1);
    assert_eq!(deliveries[0].result_invocation_id, None);
    assert!(
        !runtime
            .event_store
            .has_agent_result_grant(&run.invocation_id)
            .unwrap()
    );
}

#[tokio::test]
async fn exhausted_wake_records_one_durable_operator_attention() {
    let (runtime, _home) = test_runtime(None);
    let session = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Wake target"), None)
        .unwrap()
        .session;
    let delivery = runtime
        .event_store
        .create_agent_delivery(&crate::domains::session::event_store::NewAgentDelivery {
            idempotency_key: "wake-attention".to_owned(),
            source_kind:
                crate::domains::session::event_store::AgentDeliverySourceKind::AgentMessage,
            intent: Some(crate::domains::session::event_store::AgentDeliveryIntent::Information),
            source_session_id: Some(session.id.clone()),
            source_workspace_id: session.workspace_id.clone(),
            source_invocation_id: None,
            source_trace_id: Some("trace-wake-attention".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: crate::domains::session::event_store::AgentDeliveryTarget::Session {
                session_id: session.id.clone(),
            },
            wake_policy: crate::domains::session::event_store::AgentDeliveryWakePolicy::Wake,
            boundary: crate::domains::session::event_store::AgentDeliveryBoundary::NextRun,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: None,
            content: "wake reference".to_owned(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();
    for error in ["one", "two", "three"] {
        let _ = runtime
            .event_store
            .record_agent_wake_failure(
                &session.id,
                std::slice::from_ref(&delivery.delivery_id),
                error,
            )
            .unwrap();
    }

    runtime.import_agent_delivery_outbox().await;
    runtime.import_agent_delivery_outbox().await;
    let attention = runtime
        .store
        .inbox_filtered(Some("agent-delivery"), None, Some("error"), 20)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(attention[0]["result"]["deliveryId"], delivery.delivery_id);
}

#[tokio::test]
async fn disabling_a_worker_terminalizes_queued_work_with_outbox_evidence() {
    let (runtime, _home) = test_runtime(None);
    let published = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let (queued, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "disable-queued-delivery",
            "trace-disable-queued-delivery",
            0,
            "manual",
            None,
            WorkerInteractionMode::Background,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

    runtime
        .set_enabled(&published.worker.worker_id, false)
        .await
        .unwrap();
    let cancelled = runtime
        .store
        .invocation(&queued.invocation_id)
        .unwrap()
        .unwrap();
    assert_eq!(cancelled.status, "cancelled");
    assert!(
        cancelled
            .error
            .as_deref()
            .is_some_and(|error| error.contains("disabled"))
    );
    let outbox = runtime.store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(outbox.len(), 1);
    assert_eq!(outbox[0].invocation_id, queued.invocation_id);
    assert_eq!(outbox[0].payload["status"], "cancelled");
}

#[tokio::test]
async fn agent_created_task_projects_once_and_replay_reports_not_created() {
    let (runtime, _home) = test_runtime(None);
    let source = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Source"), None)
        .unwrap()
        .session;
    let mut events = runtime.orchestrator.subscribe();
    let actor = ActorId::new("agent:test-sender").unwrap();
    let causal = CausalContext::new(actor, ActorKind::Agent, TraceId::generate())
        .with_session_id(source.id.clone())
        .with_workspace_id(source.workspace_id.clone());
    let invocation = Invocation::new_sync(
        FunctionId::new("agent::send").unwrap(),
        json!({
            "target":{"kind":"new_task","title":"Child task"},
            "content":"Investigate this request.",
            "intent":"request",
            "wakePolicy":"passive",
            "boundary":"next_turn",
        }),
        causal,
    );

    let first = runtime.agent_send(&invocation).await.unwrap();
    let replay = runtime.agent_send(&invocation).await.unwrap();
    assert_eq!(first["createdSession"], true);
    assert_eq!(replay["createdSession"], false);
    assert_eq!(first["targetSessionId"], replay["targetSessionId"]);
    let projected = events.try_recv().unwrap();
    assert_eq!(projected.event_type(), "session_created");
    assert!(
        events.try_recv().is_err(),
        "task replay must not emit twice"
    );
}

#[tokio::test]
async fn purge_is_blocked_by_pending_outbox_and_surviving_result_grant() {
    let (runtime, _home) = test_runtime(None);
    let published = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Delivery target"), None)
        .unwrap()
        .session;
    let (run, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "purge-result-grant",
            "trace-purge-result-grant",
            0,
            "manual",
            Some(&session.id),
            WorkerInteractionMode::Background,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(runtime.store.claim_running(&run.invocation_id).unwrap());
    runtime
        .store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"durable"})),
        )
        .unwrap();
    runtime.retire(&published.worker.worker_id).await.unwrap();

    let pending_error = runtime
        .purge(&published.worker.worker_id)
        .await
        .unwrap_err();
    assert!(
        pending_error.contains("outbox rows are pending"),
        "{pending_error}"
    );

    runtime.import_agent_delivery_outbox().await;
    assert!(
        runtime
            .store
            .pending_agent_delivery_outbox(10)
            .unwrap()
            .is_empty()
    );
    let grant_error = runtime
        .purge(&published.worker.worker_id)
        .await
        .unwrap_err();
    assert!(
        grant_error.contains("granted to an agent delivery"),
        "{grant_error}"
    );
}

#[tokio::test]
async fn exact_worker_results_require_origin_or_delivery_grant() {
    let (runtime, _home) = test_runtime(None);
    let published = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let source = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Source"), None)
        .unwrap()
        .session;
    let target = runtime
        .event_store
        .create_session("mock", "/tmp/project", Some("Target"), None)
        .unwrap()
        .session;
    let foreign = runtime
        .event_store
        .create_session("mock", "/tmp/foreign", Some("Foreign"), None)
        .unwrap()
        .session;
    let (run, _) = runtime
        .store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "result-access",
            "trace-result-access",
            0,
            "manual",
            Some(&source.id),
            WorkerInteractionMode::Foreground,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(runtime.store.claim_running(&run.invocation_id).unwrap());
    runtime
        .store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"narrow grant"})),
        )
        .unwrap();

    let read_as = |session_id: &str, trace_id: &str| {
        runtime.host.invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":run.invocation_id,"pointer":"/summary"}),
            CausalContext::new(
                ActorId::new("agent:result-reader").unwrap(),
                ActorKind::Agent,
                TraceId::new(trace_id).unwrap(),
            )
            .with_session_id(session_id),
        ))
    };
    assert!(
        read_as(&source.id, "trace-origin-read")
            .await
            .error
            .is_none()
    );
    assert!(
        read_as(&target.id, "trace-target-before")
            .await
            .error
            .is_some()
    );

    runtime
        .event_store
        .create_agent_delivery(&crate::domains::session::event_store::NewAgentDelivery {
            idempotency_key: "result-access-grant".to_owned(),
            source_kind:
                crate::domains::session::event_store::AgentDeliverySourceKind::WorkerResult,
            intent: Some(crate::domains::session::event_store::AgentDeliveryIntent::Information),
            source_session_id: Some(source.id.clone()),
            source_workspace_id: source.workspace_id.clone(),
            source_invocation_id: Some(run.invocation_id.clone()),
            source_trace_id: Some("trace-result-access".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: crate::domains::session::event_store::AgentDeliveryTarget::Session {
                session_id: target.id.clone(),
            },
            wake_policy: crate::domains::session::event_store::AgentDeliveryWakePolicy::Passive,
            boundary: crate::domains::session::event_store::AgentDeliveryBoundary::NextTurn,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: Some(run.invocation_id.clone()),
            content: "The exact worker result is available by reference.".to_owned(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();

    assert!(
        read_as(&target.id, "trace-target-after")
            .await
            .error
            .is_none()
    );
    assert!(
        read_as(&foreign.id, "trace-result-access")
            .await
            .error
            .is_some()
    );
}
