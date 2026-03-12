use serde_json::json;
use tron_core::events::TronEvent;

use super::routed::{BridgedEvent, global, session_scoped, set_opt};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::AgentStart { .. } => Some(session_scoped(event, "agent.start", Some(json!({})))),
        TronEvent::AgentEnd { error, .. } => {
            let data = error.as_ref().map(|message| json!({ "error": message }));
            Some(global(event, "agent.complete", data))
        }
        TronEvent::AgentReady { .. } => Some(global(event, "agent.ready", Some(json!({})))),
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
        TronEvent::SessionCreated {
            base,
            model,
            working_directory,
            source,
            ..
        } => Some(global(
            event,
            "session.created",
            Some(json!({
                "model": model,
                "workingDirectory": working_directory,
                "messageCount": 0,
                "inputTokens": 0,
                "outputTokens": 0,
                "cost": 0.0,
                "lastActivity": base.timestamp,
                "isActive": true,
                "isChat": source.as_deref() == Some("chat"),
            })),
        )),
        TronEvent::SessionForked { new_session_id, .. } => Some(global(
            event,
            "session.forked",
            Some(json!({
                "newSessionId": new_session_id,
            })),
        )),
        TronEvent::SessionUpdated {
            title,
            model,
            message_count,
            input_tokens,
            output_tokens,
            last_turn_input_tokens,
            cache_read_tokens,
            cache_creation_tokens,
            cost,
            last_activity,
            is_active,
            last_user_prompt,
            last_assistant_response,
            parent_session_id,
            ..
        } => Some(global(
            event,
            "session.updated",
            Some(json!({
                "title": title,
                "model": model,
                "messageCount": message_count,
                "inputTokens": input_tokens,
                "outputTokens": output_tokens,
                "lastTurnInputTokens": last_turn_input_tokens,
                "cacheReadTokens": cache_read_tokens,
                "cacheCreationTokens": cache_creation_tokens,
                "cost": cost,
                "lastActivity": last_activity,
                "isActive": is_active,
                "lastUserPrompt": last_user_prompt,
                "lastAssistantResponse": last_assistant_response,
                "parentSessionId": parent_session_id,
            })),
        )),
        TronEvent::MemoryUpdating { .. } => {
            Some(session_scoped(event, "agent.memory_updating", Some(json!({}))))
        }
        TronEvent::MemoryUpdated {
            title,
            entry_type,
            event_id,
            ..
        } => Some(session_scoped(
            event,
            "agent.memory_updated",
            Some(json!({
                "title": title,
                "entryType": entry_type,
                "eventId": event_id,
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
        TronEvent::MemoryLoaded { count, .. } => Some(session_scoped(
            event,
            "memory.loaded",
            Some(json!({ "count": count })),
        )),
        TronEvent::SkillRemoved { skill_name, .. } => Some(session_scoped(
            event,
            "agent.skill_removed",
            Some(json!({ "skillName": skill_name })),
        )),
        TronEvent::SubagentSpawned {
            subagent_session_id,
            task,
            model,
            max_turns,
            spawn_depth,
            tool_call_id,
            blocking,
            working_directory,
            ..
        } => {
            let mut data = json!({
                "subagentSessionId": subagent_session_id,
                "task": task,
                "model": model,
                "maxTurns": max_turns,
                "spawnDepth": spawn_depth,
                "blocking": blocking,
            });
            set_opt(&mut data, "toolCallId", tool_call_id);
            set_opt(&mut data, "workingDirectory", working_directory);
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
            Some(session_scoped(event, "agent.subagent_completed", Some(data)))
        }
        TronEvent::SubagentFailed {
            subagent_session_id,
            error,
            duration,
            ..
        } => Some(session_scoped(
            event,
            "agent.subagent_failed",
            Some(json!({
                "subagentSessionId": subagent_session_id,
                "error": error,
                "duration": duration,
            })),
        )),
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
            });
            set_opt(&mut data, "tokenUsage", token_usage);
            set_opt(&mut data, "error", error);
            Some(session_scoped(
                event,
                "agent.subagent_result_available",
                Some(data),
            ))
        }
        TronEvent::WorktreeAcquired {
            path,
            branch,
            base_commit,
            base_branch,
            ..
        } => {
            let mut data = json!({
                "path": path,
                "branch": branch,
                "baseCommit": base_commit,
            });
            set_opt(&mut data, "baseBranch", base_branch);
            Some(session_scoped(event, "worktree.acquired", Some(data)))
        }
        TronEvent::WorktreeCommit {
            commit_hash,
            message,
            files_changed,
            insertions,
            deletions,
            ..
        } => Some(session_scoped(
            event,
            "worktree.commit",
            Some(json!({
                "commitHash": commit_hash,
                "message": message,
                "filesChanged": files_changed,
                "insertions": insertions,
                "deletions": deletions,
            })),
        )),
        TronEvent::WorktreeMerged {
            source_branch,
            target_branch,
            merge_commit,
            strategy,
            ..
        } => {
            let mut data = json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "strategy": strategy,
            });
            set_opt(&mut data, "mergeCommit", merge_commit);
            Some(session_scoped(event, "worktree.merged", Some(data)))
        }
        TronEvent::WorktreeReleased {
            final_commit,
            branch_preserved,
            deleted,
            ..
        } => {
            let mut data = json!({
                "branchPreserved": branch_preserved,
                "deleted": deleted,
            });
            set_opt(&mut data, "finalCommit", final_commit);
            Some(session_scoped(event, "worktree.released", Some(data)))
        }
        TronEvent::SessionSaved { .. } | TronEvent::SessionLoaded { .. } => {
            Some(session_scoped(event, event.event_type(), Some(json!({}))))
        }
        TronEvent::SessionArchived { .. }
        | TronEvent::SessionUnarchived { .. }
        | TronEvent::SessionDeleted { .. } => {
            let wire_type = match event.event_type() {
                "session_archived" => "session.archived",
                "session_unarchived" => "session.unarchived",
                "session_deleted" => "session.deleted",
                other => other,
            };
            Some(global(event, wire_type, Some(json!({}))))
        }
        _ => None,
    }
}
