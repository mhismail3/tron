use serde_json::json;
use crate::core::events::TronEvent;

use super::routed::{BridgedEvent, global, session_scoped, set_opt};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::AgentStart { .. } => Some(session_scoped(event, "agent.start", Some(json!({})))),
        TronEvent::AgentEnd { error, .. } => {
            let mut data = json!({ "agentPhase": "postProcessing" });
            if let Some(message) = error {
                data["error"] = json!(message);
            }
            Some(global(event, "agent.complete", Some(data)))
        }
        TronEvent::AgentReady { .. } => Some(global(event, "agent.ready", Some(json!({ "agentPhase": "idle" })))),
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
        TronEvent::SessionCreated {
            base,
            model,
            working_directory,
            source,
            title,
            ..
        } => Some(global(
            event,
            "session.created",
            Some(json!({
                "model": model,
                "workingDirectory": working_directory,
                "title": title,
                "messageCount": 0,
                "inputTokens": 0,
                "outputTokens": 0,
                "cost": 0.0,
                "lastActivity": base.timestamp,
                "isActive": true,
                "source": source,
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
            activity_lines,
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
                "activityLines": activity_lines,
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
        TronEvent::MemoryAutoRetainTriggered {
            interval_fired,
            ..
        } => Some(session_scoped(
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
            total_commit_count,
            has_uncommitted_changes,
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
                "totalCommitCount": total_commit_count,
                "hasUncommittedChanges": has_uncommitted_changes,
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
        TronEvent::WorktreeRenamed {
            old_branch,
            new_branch,
            ..
        } => {
            let data = json!({
                "oldBranch": old_branch,
                "newBranch": new_branch,
            });
            Some(session_scoped(event, "worktree.renamed", Some(data)))
        }
        TronEvent::WorktreeMainSynced {
            main_branch,
            old_head,
            new_head,
            advanced_by,
            ..
        } => Some(session_scoped(
            event,
            "worktree.main_synced",
            Some(json!({
                "mainBranch": main_branch,
                "oldHead": old_head,
                "newHead": new_head,
                "advancedBy": advanced_by,
            })),
        )),
        TronEvent::WorktreeSessionFinalized {
            source_branch,
            target_branch,
            merge_commit,
            strategy,
            new_branch,
            new_base_commit,
            old_branch_deleted,
            old_branch_delete_error,
            ..
        } => {
            let mut data = json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "strategy": strategy,
                "newBranch": new_branch,
                "newBaseCommit": new_base_commit,
                "oldBranchDeleted": old_branch_deleted,
            });
            set_opt(&mut data, "mergeCommit", merge_commit);
            set_opt(&mut data, "oldBranchDeleteError", old_branch_delete_error);
            Some(session_scoped(event, "worktree.session_finalized", Some(data)))
        }
        TronEvent::WorktreeMergeStarted {
            source_branch,
            target_branch,
            strategy,
            conflict_count,
            ..
        } => Some(session_scoped(
            event,
            "worktree.merge_started",
            Some(json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "strategy": strategy,
                "conflictCount": conflict_count,
            })),
        )),
        TronEvent::WorktreeConflictDetected {
            source_branch,
            target_branch,
            origin,
            paths,
            ..
        } => Some(session_scoped(
            event,
            "worktree.conflict_detected",
            Some(json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "origin": origin,
                "paths": paths,
            })),
        )),
        TronEvent::WorktreeConflictResolved {
            path,
            resolution,
            remaining,
            ..
        } => Some(session_scoped(
            event,
            "worktree.conflict_resolved",
            Some(json!({
                "path": path,
                "resolution": resolution,
                "remaining": remaining,
            })),
        )),
        TronEvent::WorktreeMergeContinued {
            merge_commit,
            strategy,
            origin,
            ..
        } => Some(session_scoped(
            event,
            "worktree.merge_continued",
            Some(json!({
                "mergeCommit": merge_commit,
                "strategy": strategy,
                "origin": origin,
            })),
        )),
        TronEvent::WorktreeMergeAborted {
            strategy,
            reason,
            origin,
            ..
        } => Some(session_scoped(
            event,
            "worktree.merge_aborted",
            Some(json!({
                "strategy": strategy,
                "reason": reason,
                "origin": origin,
            })),
        )),
        TronEvent::WorktreePushed {
            branch,
            remote,
            set_upstream,
            dry_run,
            force_with_lease,
            ..
        } => Some(session_scoped(
            event,
            "worktree.pushed",
            Some(json!({
                "branch": branch,
                "remote": remote,
                "setUpstream": set_upstream,
                "dryRun": dry_run,
                "forceWithLease": force_with_lease,
            })),
        )),
        TronEvent::WorktreePendingMergeDetected {
            source_branch,
            target_branch,
            strategy,
            started_at_ms,
            auto_abort_at_ms,
            ..
        } => Some(session_scoped(
            event,
            "worktree.pending_merge_detected",
            Some(json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "strategy": strategy,
                "startedAtMs": started_at_ms,
                "autoAbortAtMs": auto_abort_at_ms,
            })),
        )),
        TronEvent::WorktreeRebasedOnMain {
            main_branch,
            strategy,
            old_base_commit,
            new_base_commit,
            main_commits_incorporated,
            had_auto_stash,
            ..
        } => Some(session_scoped(
            event,
            "worktree.rebased_on_main",
            Some(json!({
                "mainBranch": main_branch,
                "strategy": strategy,
                "oldBaseCommit": old_base_commit,
                "newBaseCommit": new_base_commit,
                "mainCommitsIncorporated": main_commits_incorporated,
                "hadAutoStash": had_auto_stash,
            })),
        )),
        TronEvent::WorktreePostRebaseStashConflict {
            stash_ref,
            paths,
            ..
        } => Some(session_scoped(
            event,
            "worktree.post_rebase_stash_conflict",
            Some(json!({
                "stashRef": stash_ref,
                "paths": paths,
            })),
        )),
        TronEvent::RepoLockAcquired {
            repo_root,
            session_id,
            op,
            ..
        } => Some(global(
            event,
            "repo.lock_acquired",
            Some(json!({
                "repoRoot": repo_root,
                "sessionId": session_id,
                "op": op,
            })),
        )),
        TronEvent::RepoLockReleased {
            repo_root,
            session_id,
            op,
            ..
        } => Some(global(
            event,
            "repo.lock_released",
            Some(json!({
                "repoRoot": repo_root,
                "sessionId": session_id,
                "op": op,
            })),
        )),
        TronEvent::RepoMainAdvanced {
            repo_root,
            old_head,
            new_head,
            source_session_id,
            cause,
            ..
        } => Some(global(
            event,
            "repo.main_advanced",
            Some(json!({
                "repoRoot": repo_root,
                "oldHead": old_head,
                "newHead": new_head,
                "sourceSessionId": source_session_id,
                "cause": cause,
            })),
        )),
        TronEvent::SessionProcessingChanged { is_processing, .. } => Some(global(
            event,
            "session.processing_changed",
            Some(json!({ "isProcessing": is_processing })),
        )),
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
