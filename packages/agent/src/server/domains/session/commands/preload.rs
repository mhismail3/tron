use super::*;

pub(super) fn spawn_optimistic_context_preload(deps: &Deps, session_id: &str, working_dir: &str) {
    let event_store = deps.event_store.clone();
    let context_artifacts = deps.context_artifacts.clone();
    let broadcast = deps.orchestrator.broadcast().clone();
    let shutdown_coordinator = deps.shutdown_coordinator.clone();
    let session_id_for_task = session_id.to_owned();
    let working_dir_for_task = working_dir.to_owned();
    let handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = run_blocking_task("session.optimistic_context_preload", move || {
            let summary = emit_optimistic_context_events(
                &event_store,
                context_artifacts.as_ref(),
                &broadcast,
                &session_id_for_task,
                &working_dir_for_task,
            );
            Ok::<_, CapabilityError>(summary)
        })
        .await;
        match result {
            Ok(summary) => {
                histogram!("session_context_warmup_seconds").record(start.elapsed().as_secs_f64());
                if summary.loaded_rules {
                    counter!("session_context_warmups_total", "kind" => "rules").increment(1);
                }
                if summary.loaded_memory {
                    counter!("session_context_warmups_total", "kind" => "memory").increment(1);
                }
            }
            Err(error) => {
                counter!("session_context_warmup_failures_total").increment(1);
                tracing::warn!(error = %error, "optimistic context preload task failed");
            }
        }
    });
    if let Some(coord) = shutdown_coordinator {
        coord.register_task(handle);
    }
}

/// Discover rules files and memory, then persist + broadcast notification events.
fn emit_optimistic_context_events(
    event_store: &std::sync::Arc<crate::events::EventStore>,
    context_artifacts: &ContextArtifactsService,
    broadcast: &std::sync::Arc<EventEmitter>,
    session_id: &str,
    working_dir: &str,
) -> OptimisticContextSummary {
    let settings = crate::settings::get_settings();
    let artifacts = context_artifacts.load(event_store.as_ref(), working_dir, &settings);
    let mut summary = OptimisticContextSummary::default();

    let files_json: Vec<serde_json::Value> = artifacts
        .session
        .rules
        .files
        .iter()
        .map(|file| {
            let depth = if file.level == RuleFileLevel::Global {
                0
            } else {
                file.depth
            };
            json!({
                "path": file.path.to_string_lossy(),
                "relativePath": file.relative_path,
                "level": file.level.as_str(),
                "depth": depth,
                "sizeBytes": file.size_bytes,
            })
        })
        .collect();

    if !files_json.is_empty() {
        summary.loaded_rules = true;
        #[allow(clippy::cast_possible_truncation)]
        let total = files_json.len() as u32;
        let merged_tokens = artifacts.session.rules.merged_tokens_estimate();
        let _ = event_store.append(&crate::events::AppendOptions {
            session_id,
            event_type: crate::events::EventType::RulesLoaded,
            payload: json!({
                "files": files_json,
                "totalFiles": total,
                "mergedTokens": merged_tokens,
                "dynamicRulesCount": 0,
            }),
            parent_id: None,
            sequence: None,
        });
        let _ = broadcast.emit(TronEvent::RulesLoaded {
            base: BaseEvent::now(session_id),
            total_files: total,
            dynamic_rules_count: 0,
        });
    }

    summary
}

#[derive(Default)]
struct OptimisticContextSummary {
    loaded_rules: bool,
    loaded_memory: bool,
}
