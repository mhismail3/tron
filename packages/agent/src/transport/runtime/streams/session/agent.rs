use super::*;

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    match event {
        TronEvent::AgentStart { .. } => Some(session_scoped(event, "agent.start", Some(json!({})))),
        TronEvent::AgentEnd { error, .. } => {
            let mut data = json!({ "agentPhase": "postProcessing" });
            if let Some(message) = error {
                data["error"] = json!(message);
            }
            Some(global(event, "agent.complete", Some(data)))
        }
        TronEvent::AgentReady { .. } => Some(global(
            event,
            "agent.ready",
            Some(json!({ "agentPhase": "idle" })),
        )),
        TronEvent::Error {
            error,
            context,
            code,
            provider,
            category,
            suggestion,
            retryable,
            status_code,
            error_type,
            model,
            ..
        } => {
            let mut data = json!({ "message": error });
            set_opt(&mut data, "context", context);
            set_opt(&mut data, "code", code);
            set_opt(&mut data, "provider", provider);
            set_opt(&mut data, "category", category);
            set_opt(&mut data, "suggestion", suggestion);
            set_opt(&mut data, "retryable", retryable);
            set_opt(&mut data, "statusCode", status_code);
            set_opt(&mut data, "errorType", error_type);
            set_opt(&mut data, "model", model);
            Some(global(event, "agent.error", Some(data)))
        }
        TronEvent::CompactionStart {
            reason,
            tokens_before,
            ..
        } => Some(session_scoped(
            event,
            "agent.compaction_started",
            Some(json!({
                "reason": reason,
                "tokensBefore": tokens_before,
            })),
        )),
        TronEvent::CompactionComplete {
            success,
            tokens_before,
            tokens_after,
            compression_ratio,
            reason,
            summary,
            estimated_context_tokens,
            preserved_turns,
            summarized_turns,
            ..
        } => {
            let mut data = json!({
                "success": success,
                "tokensBefore": tokens_before,
                "tokensAfter": tokens_after,
                "compressionRatio": compression_ratio,
            });
            if let Some(reason) = reason {
                data["reason"] = serde_json::to_value(reason).unwrap_or_default();
            }
            set_opt(&mut data, "summary", summary);
            set_opt(
                &mut data,
                "estimatedContextTokens",
                estimated_context_tokens,
            );
            set_opt(&mut data, "preservedTurns", preserved_turns);
            set_opt(&mut data, "summarizedTurns", summarized_turns);
            Some(session_scoped(event, "agent.compaction", Some(data)))
        }
        TronEvent::ContextWarning {
            usage_percent,
            message,
            ..
        } => Some(session_scoped(
            event,
            "context.warning",
            Some(json!({
                "usagePercent": usage_percent,
                "message": message,
            })),
        )),
        TronEvent::MemoryUpdating { .. } => Some(session_scoped(
            event,
            "agent.memory_updating",
            Some(json!({})),
        )),
        TronEvent::MemoryUpdated {
            title,
            summary,
            entry_type,
            event_id,
            ..
        } => Some(session_scoped(
            event,
            "agent.memory_updated",
            Some(json!({
                "title": title,
                "summary": summary,
                "entryType": entry_type,
                "eventId": event_id,
            })),
        )),
        TronEvent::MemoryAutoRetainTriggered { interval_fired, .. } => Some(session_scoped(
            event,
            "agent.memory_auto_retain_triggered",
            Some(json!({
                "intervalFired": interval_fired,
            })),
        )),
        TronEvent::ContextCleared {
            tokens_before,
            tokens_after,
            ..
        } => Some(session_scoped(
            event,
            "agent.context_cleared",
            Some(json!({
                "tokensBefore": tokens_before,
                "tokensAfter": tokens_after,
            })),
        )),
        TronEvent::RulesLoaded {
            total_files,
            dynamic_rules_count,
            ..
        } => Some(session_scoped(
            event,
            "rules.loaded",
            Some(json!({
                "totalFiles": total_files,
                "dynamicRulesCount": dynamic_rules_count,
            })),
        )),
        TronEvent::RulesActivated {
            rules,
            total_activated,
            ..
        } => Some(session_scoped(
            event,
            "rules.activated",
            Some(json!({
                "rules": rules.iter().map(|rule| json!({
                    "relativePath": rule.relative_path,
                    "scopeDir": rule.scope_dir,
                })).collect::<Vec<_>>(),
                "totalActivated": total_activated,
            })),
        )),
        TronEvent::SkillActivated {
            skill_name, source, ..
        } => Some(session_scoped(
            event,
            "agent.skill_activated",
            Some(json!({ "skillName": skill_name, "source": source })),
        )),
        TronEvent::SkillDeactivated { skill_name, .. } => Some(session_scoped(
            event,
            "agent.skill_deactivated",
            Some(json!({ "skillName": skill_name })),
        )),
        TronEvent::SubagentSpawned {
            subagent_session_id,
            task,
            model,
            max_turns,
            spawn_depth,
            tool_call_id,
            blocking_timeout_ms,
            working_directory,
            spawn_type,
            ..
        } => {
            let mut data = json!({
                "subagentSessionId": subagent_session_id,
                "task": task,
                "model": model,
                "maxTurns": max_turns,
                "spawnDepth": spawn_depth,
            });
            if let Some(timeout) = blocking_timeout_ms {
                data["blockingTimeoutMs"] = json!(timeout);
            }
            set_opt(&mut data, "toolCallId", tool_call_id);
            set_opt(&mut data, "workingDirectory", working_directory);
            set_opt(&mut data, "spawnType", spawn_type);
            Some(session_scoped(event, "agent.subagent_spawned", Some(data)))
        }
        TronEvent::SubagentStatusUpdate {
            subagent_session_id,
            status,
            current_turn,
            activity,
            ..
        } => {
            let mut data = json!({
                "subagentSessionId": subagent_session_id,
                "status": status,
                "currentTurn": current_turn,
            });
            set_opt(&mut data, "activity", activity);
            Some(session_scoped(event, "agent.subagent_status", Some(data)))
        }
        TronEvent::SubagentCompleted {
            subagent_session_id,
            total_turns,
            duration,
            full_output,
            result_summary,
            token_usage,
            model,
            spawn_type,
            ..
        } => {
            let mut data = json!({
                "subagentSessionId": subagent_session_id,
                "totalTurns": total_turns,
                "duration": duration,
            });
            set_opt(&mut data, "fullOutput", full_output);
            set_opt(&mut data, "resultSummary", result_summary);
            set_opt(&mut data, "tokenUsage", token_usage);
            set_opt(&mut data, "model", model);
            set_opt(&mut data, "spawnType", spawn_type);
            Some(session_scoped(
                event,
                "agent.subagent_completed",
                Some(data),
            ))
        }
        TronEvent::SubagentFailed {
            subagent_session_id,
            error,
            duration,
            spawn_type,
            ..
        } => {
            let mut data = json!({
                "subagentSessionId": subagent_session_id,
                "error": error,
                "duration": duration,
            });
            set_opt(&mut data, "spawnType", spawn_type);
            Some(session_scoped(event, "agent.subagent_failed", Some(data)))
        }
        TronEvent::SubagentEvent {
            subagent_session_id,
            event: inner,
            ..
        } => Some(session_scoped(
            event,
            "agent.subagent_event",
            Some(json!({
                "subagentSessionId": subagent_session_id,
                "event": inner,
            })),
        )),
        TronEvent::SubagentResultAvailable {
            parent_session_id,
            subagent_session_id,
            task,
            result_summary,
            success,
            total_turns,
            duration,
            token_usage,
            error,
            completed_at,
            notify,
            ..
        } => {
            let mut data = json!({
                "parentSessionId": parent_session_id,
                "subagentSessionId": subagent_session_id,
                "task": task,
                "resultSummary": result_summary,
                "success": success,
                "totalTurns": total_turns,
                "duration": duration,
                "completedAt": completed_at,
                "notify": notify,
            });
            set_opt(&mut data, "tokenUsage", token_usage);
            set_opt(&mut data, "error", error);
            Some(session_scoped(
                event,
                "agent.subagent_result_available",
                Some(data),
            ))
        }
        _ => None,
    }
}
