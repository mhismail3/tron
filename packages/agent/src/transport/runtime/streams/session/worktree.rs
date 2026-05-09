use super::*;

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    match event {
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
            Some(session_scoped(
                event,
                "worktree.session_finalized",
                Some(data),
            ))
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
            stash_ref, paths, ..
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
        _ => None,
    }
}
