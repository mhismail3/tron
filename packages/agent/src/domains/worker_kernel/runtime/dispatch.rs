//! One durable dispatcher for queued, scheduled, and engine-event work.

use super::*;

const ORPHANED_DELIVERY_REASON: &str = "claimed worker delivery lost its in-process owner";

impl WorkerRuntime {
    pub(super) async fn run_dispatcher(self: &Arc<Self>, cancellation: CancellationToken) {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut runs = JoinSet::new();
        loop {
            let maintain = tokio::select! {
                () = cancellation.cancelled() => break,
                _ = ticker.tick() => true,
                () = self.delivery_maintenance.notified() => true,
                Some(_) = runs.join_next(), if !runs.is_empty() => false,
            };
            if maintain {
                // Durability plumbing continues while stop-all suppresses
                // worker execution. Notify provides the fast path; the ticker
                // remains the crash/lost-signal reconciliation fallback.
                self.import_agent_delivery_outbox().await;
                let _ = self.import_agent_coordination_outbox().await;
                if let Err(error) = self.expire_due_agent_assignments().await {
                    tracing::warn!(error = %error, "reusable-agent deadline maintenance will retry");
                }
                if !self.stopped.load(Ordering::SeqCst) {
                    if self.execution_stop.lock().await.is_cancelled() {
                        *self.execution_stop.lock().await = CancellationToken::new();
                    }
                    self.reconcile_orphaned_invocations(true).await;
                    self.dispatch_resident_supervision(&mut runs);
                    self.dispatch_queued(&mut runs).await;
                    self.dispatch_agent_assignments(&mut runs).await;
                    self.dispatch_schedules(&mut runs).await;
                    self.dispatch_events(&mut runs).await;
                    self.dispatch_notifications(&mut runs).await;
                    self.dispatch_session_organization(&mut runs).await;
                }
            }
        }
        self.shutdown().await;
        runs.abort_all();
        while runs.join_next().await.is_some() {}
        self.inflight.clear();
        self.agent_assignment_inflight.clear();
        self.reconcile_orphaned_invocations(false).await;
    }

    pub(super) async fn reconcile_orphaned_invocations(&self, record_attention: bool) {
        let Ok(running) =
            self.store
                .runs_filtered_page_exact(None, Some("running"), None, None, None, 128, 0)
        else {
            return;
        };
        for invocation in running {
            if self.inflight.contains(&invocation.invocation_id) {
                continue;
            }
            let Ok(requeued) = self
                .store
                .interrupt_running_invocation(&invocation.invocation_id, ORPHANED_DELIVERY_REASON)
            else {
                continue;
            };
            metrics::counter!(
                "worker_orphan_recoveries_total",
                "outcome" => "requeued"
            )
            .increment(1);
            if self
                .store
                .execution_node_for_worker_invocation(&invocation.invocation_id)
                .ok()
                .flatten()
                .is_some_and(|execution| execution.owner_agent_id.is_some())
            {
                metrics::counter!(
                    "agent_coordination_orphan_recoveries_total",
                    "execution_kind" => "worker",
                    "outcome" => "requeued"
                )
                .increment(1);
            }
            if record_attention
                && let Ok(count) = self
                    .store
                    .interrupted_attempt_count(&invocation.worker_id, ORPHANED_DELIVERY_REASON)
            {
                if count == 3 {
                    let _ = self.store.record_system_inbox(
                        &invocation.worker_id,
                        "orphan_recovery",
                        &json!({
                            "status":"failed",
                            "phase":"orphan_recovery",
                            "error":"Worker delivery ownership was recovered repeatedly",
                            "recoveryCount":count,
                        }),
                    );
                }
            }
            self.publish_invocation_event(
                &requeued,
                json!({
                    "action":"queued",
                    "invocationId":requeued.invocation_id,
                    "workerId":requeued.worker_id,
                    "causalDepth":requeued.causal_depth,
                    "recoveredOwnership":true,
                }),
            )
            .await;
        }
    }

    pub(super) async fn dispatch_queued(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Ok(queued) = self.store.queued_invocations(128) else {
            return;
        };
        for invocation in queued {
            if self.inflight.contains(&invocation.invocation_id) {
                continue;
            }
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                let _ = runtime.execute_queued(invocation).await;
            });
        }
    }

    pub(super) async fn dispatch_schedules(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Ok(due) = self.store.due_schedules() else {
            return;
        };
        for (worker_id, trigger, due_at) in due {
            let WorkerTrigger::Schedule {
                id,
                every_seconds,
                input,
            } = trigger
            else {
                continue;
            };
            let queued = self.enqueue_request(InvokeRequest {
                worker_id: worker_id.clone(),
                input,
                model: None,
                reasoning_level: None,
                idempotency_key: format!("schedule:{id}:{due_at}"),
                trace_id: format!("worker-schedule-{}", uuid::Uuid::now_v7()),
                causal_depth: 0,
                trigger_kind: "schedule".to_owned(),
                origin_session_id: None,
            });
            let Ok((queued, _)) = queued else {
                continue;
            };
            if self
                .store
                .advance_schedule(&worker_id, &id, every_seconds)
                .is_err()
            {
                continue;
            }
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                let _ = runtime.execute_queued(queued).await;
            });
        }
    }

    pub(super) async fn dispatch_events(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Ok(triggers) = self.store.event_triggers() else {
            return;
        };
        for (worker_id, trigger, cursor) in triggers {
            let WorkerTrigger::EngineEvent {
                id,
                topic,
                filter,
                input,
            } = trigger
            else {
                continue;
            };
            let page = self
                .host
                .poll_stream_topic(
                    &topic,
                    StreamCursor(u64::try_from(cursor).unwrap_or_default()),
                    100,
                    &StreamActorScope::all(),
                )
                .await;
            let Ok(page) = page else {
                continue;
            };
            let active = match self.store.load_active(&worker_id) {
                Ok(active) => active,
                Err(_) => continue,
            };
            let worker_function =
                match FunctionId::new(format!("worker_kernel::dynamic_{worker_id}")) {
                    Ok(function) => function,
                    Err(_) => continue,
                };
            let next_cursor = page.next_cursor.0;
            let mut durable = Vec::new();
            let mut persistence_failed = false;
            for event in page.events {
                if !json_subset_matches(&filter, &event.payload) {
                    continue;
                }
                let merged = materialize_engine_event_input(
                    &input,
                    &event.payload,
                    &active.bundle.input_schema,
                );
                let event_cursor = event.cursor.0;
                let event_worker = worker_id.clone();
                let event_trigger = id.clone();
                let causal_depth = event
                    .payload
                    .get("causalDepth")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    .unwrap_or(0)
                    .saturating_add(1);
                let idempotency_key = format!("event:{event_trigger}:{event_cursor}");
                let trace_id = event.trace_id.as_ref().map_or_else(
                    || format!("worker-event-{}", uuid::Uuid::now_v7()),
                    |id| id.as_str().to_owned(),
                );
                if causal_depth > MAX_CAUSAL_DEPTH {
                    if self
                        .store
                        .record_trigger_suppression(
                            &trace_id,
                            &event_worker,
                            "engine_event",
                            &idempotency_key,
                            causal_depth,
                            "causal_depth_limit",
                        )
                        .is_err()
                    {
                        persistence_failed = true;
                        break;
                    }
                    continue;
                }
                let input_validation = crate::engine::validate_engine_schema_payload(
                    &worker_function,
                    "request",
                    &active.bundle.input_schema,
                    &merged,
                )
                .map_err(|error| format!(
                    "engine-event trigger '{event_trigger}' produced input outside inputSchema: {error}"
                ))
                .and_then(|()| {
                    self.reject_secret_material_in_value(&merged, "engine-event worker input")
                });
                if let Err(error) = input_validation {
                    let _ = self
                        .handle_worker_runtime_failure(
                            &worker_id,
                            &active.summary.active_version,
                            "trigger_dispatch",
                            &error,
                        )
                        .await;
                    if self
                        .store
                        .summary(&worker_id)
                        .ok()
                        .flatten()
                        .is_none_or(|summary| summary.enabled)
                    {
                        persistence_failed = true;
                    }
                    break;
                }
                match self.enqueue_request(InvokeRequest {
                    worker_id: event_worker,
                    input: merged,
                    model: None,
                    reasoning_level: None,
                    idempotency_key,
                    trace_id,
                    causal_depth,
                    trigger_kind: "engine_event".to_owned(),
                    origin_session_id: None,
                }) {
                    Ok((queued, _)) => durable.push(queued),
                    Err(_) => {
                        persistence_failed = true;
                        break;
                    }
                }
            }
            if !persistence_failed {
                let _ = self.store.update_stream_cursor(
                    &worker_id,
                    &id,
                    i64::try_from(next_cursor).unwrap_or(i64::MAX),
                );
            }
            for queued in durable {
                let runtime = Arc::clone(self);
                runs.spawn(async move {
                    let _ = runtime.execute_queued(queued).await;
                });
            }
        }
    }
}
