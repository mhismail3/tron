use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::domains::session::event_store::EventStore;

use super::process::{ProcessTree, wait_with_bounded_output};

const MAX_CORE_TEST_EVIDENCE_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreProposal {
    pub proposal_id: String,
    pub title: String,
    pub intent: String,
    pub repository_path: String,
    pub worktree_path: String,
    pub branch: String,
    pub commit: String,
    pub test_command: Vec<String>,
    pub test_output: String,
    pub status: String,
    pub created_at: String,
    pub applied_at: Option<String>,
    #[serde(default)]
    pub applied_commit: Option<String>,
    pub approval_session_id: Option<String>,
    pub approval_message_id: Option<String>,
}

pub struct CoreProposalService {
    root: PathBuf,
    event_store: Arc<EventStore>,
}

impl CoreProposalService {
    pub fn new(home: &Path, event_store: Arc<EventStore>) -> Result<Self, String> {
        let root = home.join("workspace").join("core-proposals");
        fs::create_dir_all(&root).map_err(|error| error.to_string())?;
        Ok(Self { root, event_store })
    }

    pub async fn create(
        &self,
        title: String,
        intent: String,
        repository_path: String,
        patch: String,
        test_command: Vec<String>,
    ) -> Result<CoreProposal, String> {
        if title.trim().is_empty() || intent.trim().is_empty() || patch.trim().is_empty() {
            return Err("core proposal title, intent, and patch are required".to_owned());
        }
        if test_command.is_empty() {
            return Err("core proposal requires a test command".to_owned());
        }
        let repository = PathBuf::from(repository_path)
            .canonicalize()
            .map_err(|error| format!("resolve core repository: {error}"))?;
        if !repository.join(".git").exists() {
            return Err(format!("{} is not a Git worktree", repository.display()));
        }
        let proposal_id = format!("core_proposal_{}", uuid::Uuid::now_v7());
        let proposal_dir = self.root.join(&proposal_id);
        let worktree = proposal_dir.join("worktree");
        fs::create_dir_all(&proposal_dir).map_err(|error| error.to_string())?;
        let branch = format!(
            "codex/core-proposal-{}",
            &proposal_id[proposal_id.len() - 12..]
        );
        run_git(
            &repository,
            &[
                "worktree",
                "add",
                "-b",
                &branch,
                worktree.to_string_lossy().as_ref(),
                "HEAD",
            ],
            None,
        )
        .await?;
        let prepared = async {
            run_git(
                &worktree,
                &["apply", "--whitespace=nowarn", "-"],
                Some(&patch),
            )
            .await
            .map_err(|error| format!("apply core proposal patch: {error}"))?;
            let test_output = run_command(&worktree, &test_command).await?;
            run_git(&worktree, &["add", "--all"], None).await?;
            run_git(
                &worktree,
                &[
                    "-c",
                    "user.name=Tron",
                    "-c",
                    "user.email=tron@localhost",
                    "commit",
                    "-m",
                    &format!("core proposal: {title}"),
                ],
                None,
            )
            .await?;
            let commit = run_git(&worktree, &["rev-parse", "HEAD"], None)
                .await?
                .trim()
                .to_owned();
            Ok::<_, String>((test_output, commit))
        }
        .await;
        let (test_output, commit) = match prepared {
            Ok(prepared) => prepared,
            Err(error) => {
                cleanup_failed_worktree(&repository, &worktree, &branch).await;
                return Err(error);
            }
        };
        let proposal = CoreProposal {
            proposal_id: proposal_id.clone(),
            title,
            intent,
            repository_path: repository.display().to_string(),
            worktree_path: worktree.display().to_string(),
            branch,
            commit,
            test_command,
            test_output: bounded(test_output, 64 * 1024),
            status: "tested".to_owned(),
            created_at: chrono::Utc::now().to_rfc3339(),
            applied_at: None,
            applied_commit: None,
            approval_session_id: None,
            approval_message_id: None,
        };
        self.write(&proposal)?;
        Ok(proposal)
    }

    pub fn list(&self) -> Result<Vec<CoreProposal>, String> {
        let mut proposals = Vec::new();
        for entry in fs::read_dir(&self.root).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            let path = entry.path().join("proposal.json");
            if path.is_file() {
                proposals.push(read_proposal(&path)?);
            }
        }
        proposals.sort_by(|left, right| right.created_at.cmp(&left.created_at));
        Ok(proposals)
    }

    pub fn inspect(&self, proposal_id: &str) -> Result<CoreProposal, String> {
        validate_proposal_id(proposal_id)?;
        read_proposal(&self.root.join(proposal_id).join("proposal.json"))
    }

    pub async fn apply(
        &self,
        proposal_id: &str,
        approval_session_id: &str,
        approval_message_id: &str,
    ) -> Result<CoreProposal, String> {
        let mut proposal = self.inspect(proposal_id)?;
        if proposal.status == "applied" {
            return Ok(proposal);
        }
        self.validate_approval(
            proposal_id,
            &proposal.created_at,
            approval_session_id,
            approval_message_id,
        )?;
        let repository = PathBuf::from(&proposal.repository_path);
        let original_head = run_git(&repository, &["rev-parse", "HEAD"], None)
            .await?
            .trim()
            .to_owned();
        let cherry_pick_head = git_state_path(&repository, "CHERRY_PICK_HEAD").await?;
        if cherry_pick_head.exists() {
            return Err(
                "cannot apply a core proposal while another cherry-pick is in progress".to_owned(),
            );
        }
        if let Err(error) = run_git(&repository, &["cherry-pick", &proposal.commit], None).await {
            let cleanup = if cherry_pick_head.exists() {
                run_git(&repository, &["cherry-pick", "--abort"], None)
                    .await
                    .map(|_| ())
            } else {
                Ok(())
            };
            let restored_head = run_git(&repository, &["rev-parse", "HEAD"], None)
                .await
                .map(|head| head.trim().to_owned());
            return match (cleanup, restored_head) {
                (Ok(()), Ok(restored)) if restored == original_head => Err(format!(
                    "apply approved core proposal: {error}; failed cherry-pick was aborted and the live tree was restored"
                )),
                (cleanup, restored) => Err(format!(
                    "apply approved core proposal: {error}; cleanup failed (abort={cleanup:?}, head={restored:?}, expected={original_head})"
                )),
            };
        }
        proposal.applied_commit = Some(
            run_git(&repository, &["rev-parse", "HEAD"], None)
                .await?
                .trim()
                .to_owned(),
        );
        proposal.status = "applied".to_owned();
        proposal.applied_at = Some(chrono::Utc::now().to_rfc3339());
        proposal.approval_session_id = Some(approval_session_id.to_owned());
        proposal.approval_message_id = Some(approval_message_id.to_owned());
        self.write(&proposal)?;
        Ok(proposal)
    }

    fn validate_approval(
        &self,
        proposal_id: &str,
        proposal_created_at: &str,
        session_id: &str,
        message_id: &str,
    ) -> Result<(), String> {
        let event = self
            .event_store
            .get_event(message_id)
            .map_err(|error| format!("load core proposal approval: {error}"))?
            .ok_or_else(|| "approval message was not found".to_owned())?;
        if event.session_id != session_id || event.event_type != "message.user" {
            return Err(
                "core proposal approval must reference a user message in the named session"
                    .to_owned(),
            );
        }
        let proposal_created = chrono::DateTime::parse_from_rfc3339(proposal_created_at)
            .map_err(|error| format!("decode core proposal timestamp: {error}"))?;
        let approval_created = chrono::DateTime::parse_from_rfc3339(&event.timestamp)
            .map_err(|error| format!("decode approval message timestamp: {error}"))?;
        if approval_created <= proposal_created {
            return Err(
                "core proposal approval must be a later user message, not prior authority"
                    .to_owned(),
            );
        }
        let payloads = self
            .event_store
            .resolve_event_payloads(&[event])
            .map_err(|error| format!("resolve core proposal approval: {error}"))?;
        let content = payloads
            .first()
            .and_then(|payload| payload.get("content"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !is_unambiguous_approval(content, proposal_id) {
            return Err(format!(
                "approval message must unambiguously approve or apply proposal '{proposal_id}' without negation"
            ));
        }
        Ok(())
    }

    fn write(&self, proposal: &CoreProposal) -> Result<(), String> {
        let path = self.root.join(&proposal.proposal_id).join("proposal.json");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let temporary = path.with_extension("json.tmp");
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(proposal).map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        fs::rename(temporary, path).map_err(|error| error.to_string())
    }
}

fn validate_proposal_id(proposal_id: &str) -> Result<(), String> {
    let suffix = proposal_id
        .strip_prefix("core_proposal_")
        .ok_or_else(|| "core proposal id has an invalid format".to_owned())?;
    uuid::Uuid::parse_str(suffix)
        .map(|_| ())
        .map_err(|_| "core proposal id has an invalid format".to_owned())
}

fn is_unambiguous_approval(content: &str, proposal_id: &str) -> bool {
    let content = content.to_ascii_lowercase();
    if !content.contains(&proposal_id.to_ascii_lowercase()) {
        return false;
    }
    let words = content
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>();
    let affirmative = words
        .iter()
        .any(|word| matches!(*word, "approve" | "approved" | "apply"));
    let negated = words.iter().any(|word| {
        matches!(
            *word,
            "no" | "not"
                | "never"
                | "dont"
                | "reject"
                | "rejected"
                | "decline"
                | "declined"
                | "deny"
                | "denied"
                | "cancel"
                | "cancelled"
        )
    }) || content.contains("don't")
        || content.contains("do not")
        || content.contains("must not");
    affirmative && !negated
}

fn read_proposal(path: &Path) -> Result<CoreProposal, String> {
    serde_json::from_slice(
        &fs::read(path)
            .map_err(|error| format!("read core proposal {}: {error}", path.display()))?,
    )
    .map_err(|error| format!("decode core proposal {}: {error}", path.display()))
}

async fn cleanup_failed_worktree(repository: &Path, worktree: &Path, branch: &str) {
    let _ = run_git(
        repository,
        &[
            "worktree",
            "remove",
            "--force",
            worktree.to_string_lossy().as_ref(),
        ],
        None,
    )
    .await;
    let _ = run_git(repository, &["branch", "-D", branch], None).await;
}

async fn git_state_path(repository: &Path, state: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(
        run_git(repository, &["rev-parse", "--git-path", state], None)
            .await?
            .trim(),
    );
    Ok(if path.is_absolute() {
        path
    } else {
        repository.join(path)
    })
}

async fn run_git(cwd: &Path, arguments: &[&str], stdin: Option<&str>) -> Result<String, String> {
    let mut command = tokio::process::Command::new("git");
    command
        .args(arguments)
        .current_dir(cwd)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|error| format!("start git: {error}"))?;
    if let (Some(value), Some(mut child_stdin)) = (stdin, child.stdin.take()) {
        child_stdin
            .write_all(value.as_bytes())
            .await
            .map_err(|error| format!("write git stdin: {error}"))?;
    }
    let output = child
        .wait_with_output()
        .await
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "git {} failed: {}",
            arguments.join(" "),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

async fn run_command(cwd: &Path, command: &[String]) -> Result<String, String> {
    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| "core proposal test command is empty".to_owned())?;
    let mut command = tokio::process::Command::new(program);
    command
        .args(arguments)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child = ProcessTree::spawn(&mut command)
        .map_err(|error| format!("run core proposal tests: {error}"))?;
    let output = wait_with_bounded_output(
        child,
        None,
        std::time::Duration::from_secs(7_200),
        "core proposal tests exceeded two hours".to_owned(),
        MAX_CORE_TEST_EVIDENCE_BYTES,
    )
    .await
    .map_err(|error| format!("run core proposal tests: {error}"))?;
    let mut combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if output.stdout_truncated || output.stderr_truncated {
        combined.push_str("\n[test output truncated while the remaining pipes were drained]");
    }
    if !output.status.success() {
        return Err(format!(
            "core proposal tests failed: {}",
            bounded(combined, 64 * 1024)
        ));
    }
    Ok(combined)
}

fn bounded(mut value: String, max: usize) -> String {
    if value.len() > max {
        value.truncate(max);
        value.push_str("\n[truncated]");
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::session::event_store::{AppendOptions, EventType};
    use serde_json::json;

    fn git(repo: &Path, arguments: &[&str]) -> String {
        let output = std::process::Command::new("git")
            .args(arguments)
            .current_dir(repo)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {} failed: {}",
            arguments.join(" "),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }

    fn repository() -> tempfile::TempDir {
        let repo = tempfile::tempdir().unwrap();
        git(repo.path(), &["init", "--quiet"]);
        git(repo.path(), &["config", "user.name", "Core Proposal Test"]);
        git(
            repo.path(),
            &["config", "user.email", "core-proposal-test@localhost"],
        );
        fs::write(repo.path().join("value.txt"), "before\n").unwrap();
        git(repo.path(), &["add", "value.txt"]);
        git(repo.path(), &["commit", "--quiet", "-m", "initial"]);
        repo
    }

    #[tokio::test]
    async fn tested_core_patch_cannot_touch_live_tree_until_later_user_approval() {
        let repository = repository();
        let home = tempfile::tempdir().unwrap();
        let context = crate::shared::server::test_support::make_test_context();
        let service = CoreProposalService::new(home.path(), context.event_store.clone()).unwrap();
        assert!(
            service
                .inspect("../../outside")
                .unwrap_err()
                .contains("invalid format")
        );
        let patch = "diff --git a/value.txt b/value.txt\n--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-before\n+after\n";

        let proposal = service
            .create(
                "Change fixture value".to_owned(),
                "Prove the isolated core-change boundary".to_owned(),
                repository.path().display().to_string(),
                patch.to_owned(),
                vec![
                    "sh".to_owned(),
                    "-c".to_owned(),
                    "test \"$(cat value.txt)\" = after".to_owned(),
                ],
            )
            .await
            .unwrap();

        assert_eq!(proposal.status, "tested");
        assert_eq!(
            fs::read_to_string(repository.path().join("value.txt")).unwrap(),
            "before\n"
        );
        assert_eq!(
            fs::read_to_string(Path::new(&proposal.worktree_path).join("value.txt")).unwrap(),
            "after\n"
        );
        assert!(
            service
                .apply(&proposal.proposal_id, "missing-session", "missing-message")
                .await
                .unwrap_err()
                .contains("not found")
        );
        assert_eq!(
            fs::read_to_string(repository.path().join("value.txt")).unwrap(),
            "before\n"
        );

        let session = context
            .event_store
            .create_session("test", "/tmp", Some("approval"), None)
            .unwrap();
        let wrong_kind = context
            .event_store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::MessageAssistant,
                payload: json!({
                    "content": format!("approve {}", proposal.proposal_id)
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        assert!(
            service
                .apply(&proposal.proposal_id, &session.session.id, &wrong_kind.id)
                .await
                .unwrap_err()
                .contains("user message")
        );
        let negated = context
            .event_store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::MessageUser,
                payload: json!({
                    "content": format!("Do not apply {}", proposal.proposal_id)
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        assert!(
            service
                .apply(&proposal.proposal_id, &session.session.id, &negated.id)
                .await
                .unwrap_err()
                .contains("without negation")
        );
        assert_eq!(
            fs::read_to_string(repository.path().join("value.txt")).unwrap(),
            "before\n"
        );
        let approval = context
            .event_store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::MessageUser,
                payload: json!({
                    "content": format!("Approve and apply {}", proposal.proposal_id)
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let applied = service
            .apply(&proposal.proposal_id, &session.session.id, &approval.id)
            .await
            .unwrap();

        assert_eq!(applied.status, "applied");
        assert_eq!(
            applied.approval_session_id.as_deref(),
            Some(session.session.id.as_str())
        );
        assert_eq!(
            applied.approval_message_id.as_deref(),
            Some(approval.id.as_str())
        );
        assert_eq!(
            fs::read_to_string(repository.path().join("value.txt")).unwrap(),
            "after\n"
        );
        assert_eq!(
            applied.applied_commit.as_deref(),
            Some(git(repository.path(), &["rev-parse", "HEAD"]).as_str())
        );
        assert_eq!(
            git(repository.path(), &["rev-parse", "HEAD^{tree}"]),
            git(
                repository.path(),
                &["rev-parse", &format!("{}^{{tree}}", proposal.commit)]
            )
        );
    }

    #[tokio::test]
    async fn conflicting_approved_patch_restores_the_live_tree_and_remains_tested() {
        let repository = repository();
        let home = tempfile::tempdir().unwrap();
        let context = crate::shared::server::test_support::make_test_context();
        let service = CoreProposalService::new(home.path(), context.event_store.clone()).unwrap();
        let patch = "diff --git a/value.txt b/value.txt\n--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-before\n+proposed\n";
        let proposal = service
            .create(
                "Conflicting fixture value".to_owned(),
                "Prove a failed approved apply restores the live checkout".to_owned(),
                repository.path().display().to_string(),
                patch.to_owned(),
                vec![
                    "sh".to_owned(),
                    "-c".to_owned(),
                    "test \"$(cat value.txt)\" = proposed".to_owned(),
                ],
            )
            .await
            .unwrap();

        fs::write(repository.path().join("value.txt"), "live\n").unwrap();
        git(repository.path(), &["add", "value.txt"]);
        git(
            repository.path(),
            &["commit", "--quiet", "-m", "live conflict"],
        );
        let live_head = git(repository.path(), &["rev-parse", "HEAD"]);
        let session = context
            .event_store
            .create_session("test", "/tmp", Some("approval"), None)
            .unwrap();
        let approval = context
            .event_store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::MessageUser,
                payload: json!({
                    "content": format!("Approve and apply {}", proposal.proposal_id)
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let error = service
            .apply(&proposal.proposal_id, &session.session.id, &approval.id)
            .await
            .unwrap_err();

        assert!(
            error.contains("was aborted") && error.contains("restored"),
            "{error}"
        );
        assert_eq!(
            fs::read_to_string(repository.path().join("value.txt")).unwrap(),
            "live\n"
        );
        assert_eq!(git(repository.path(), &["rev-parse", "HEAD"]), live_head);
        assert_eq!(git(repository.path(), &["status", "--porcelain"]), "");
        assert!(!repository.path().join(".git/CHERRY_PICK_HEAD").exists());
        let retained = service.inspect(&proposal.proposal_id).unwrap();
        assert_eq!(retained.status, "tested");
        assert!(retained.approval_message_id.is_none());
        assert!(retained.applied_commit.is_none());
    }

    #[tokio::test]
    async fn failed_core_patch_tests_leave_no_branch_or_worktree() {
        let repository = repository();
        let home = tempfile::tempdir().unwrap();
        let context = crate::shared::server::test_support::make_test_context();
        let service = CoreProposalService::new(home.path(), context.event_store.clone()).unwrap();
        let patch = "diff --git a/value.txt b/value.txt\n--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-before\n+unverified\n";

        let error = service
            .create(
                "Fail fixture test".to_owned(),
                "Prove failed evidence is not retained as a proposal".to_owned(),
                repository.path().display().to_string(),
                patch.to_owned(),
                vec!["sh".to_owned(), "-c".to_owned(), "exit 9".to_owned()],
            )
            .await
            .unwrap_err();

        assert!(error.contains("tests failed"));
        assert!(service.list().unwrap().is_empty());
        assert_eq!(
            git(
                repository.path(),
                &["branch", "--list", "codex/core-proposal-*"]
            ),
            ""
        );
        assert_eq!(
            fs::read_to_string(repository.path().join("value.txt")).unwrap(),
            "before\n"
        );
    }
}
