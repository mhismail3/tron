//! One durable dispatcher for queued, scheduled, and engine-event work.

use super::*;

impl WorkerRuntime {
    pub(super) async fn run_dispatcher(self: &Arc<Self>, cancellation: CancellationToken) {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut runs = JoinSet::new();
        loop {
            tokio::select! {
                () = cancellation.cancelled() => break,
                _ = ticker.tick() => {
                    if !self.stopped.load(Ordering::SeqCst) {
                        if self.execution_stop.lock().await.is_cancelled() {
                            *self.execution_stop.lock().await = CancellationToken::new();
                        }
                        self.dispatch_resident_supervision(&mut runs);
                        self.dispatch_queued(&mut runs).await;
                        self.dispatch_schedules(&mut runs).await;
                        self.dispatch_events(&mut runs).await;
                        self.dispatch_notifications(&mut runs).await;
                    }
                }
                Some(_) = runs.join_next(), if !runs.is_empty() => {}
            }
        }
        runs.abort_all();
        self.shutdown().await;
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
