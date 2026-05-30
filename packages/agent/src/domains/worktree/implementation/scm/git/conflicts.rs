use std::path::Path;

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::git::GitExecutor;
use crate::domains::worktree::types::{ConflictKind, ConflictedFile};

impl GitExecutor {
    // ────────────────────────────────────────────────────────────────
    // Phase 1 primitives — conflict helpers
    // ────────────────────────────────────────────────────────────────

    /// Is there an in-progress merge? (Detected via `.git/MERGE_HEAD`.)
    pub async fn has_merge_in_progress(&self, dir: &Path) -> Result<bool> {
        let git_dir = self.git_dir(dir).await?;
        Ok(Path::new(&git_dir).join("MERGE_HEAD").exists())
    }

    /// Is there an in-progress rebase? (Detected via
    /// `.git/rebase-merge/` or `.git/rebase-apply/`.)
    pub async fn has_rebase_in_progress(&self, dir: &Path) -> Result<bool> {
        let git_dir = self.git_dir(dir).await?;
        let gd = Path::new(&git_dir);
        Ok(gd.join("rebase-merge").is_dir() || gd.join("rebase-apply").is_dir())
    }

    /// List currently staged files (those that would go into the next
    /// commit). Uses `git diff --cached --name-only`.
    pub async fn staged_files(&self, dir: &Path) -> Result<Vec<String>> {
        let output = self.run(dir, &["diff", "--cached", "--name-only"]).await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Read the three index stages for a conflicted path and return a
    /// `ConflictedFile` describing the conflict shape.
    ///
    /// Uses `git ls-files --unmerged -z` to determine which stages exist
    /// (1/2/3) and `git show :<stage>:<path>` to read each stage's blob.
    /// Binary detection: we run `git check-attr` — cheap, authoritative,
    /// and respects `.gitattributes`. A NUL byte in any stage is also
    /// considered binary.
    pub async fn conflict_sections(&self, dir: &Path, path: &str) -> Result<ConflictedFile> {
        // 1. Figure out which stages exist. Output from ls-files --unmerged:
        //    <mode> SP <sha> SP <stage>\t<path>\0
        // For simplicity we just split on \t (path may legitimately contain
        // tabs but that's very rare; we ignore that edge case here).
        let (ls_out, _err, ok) = self
            .run_capture(dir, &["ls-files", "--unmerged", "--", path])
            .await?;
        if !ok || ls_out.trim().is_empty() {
            return Err(WorktreeError::Git(format!("not an unmerged path: {path}")));
        }
        let mut have_stage = [false; 4]; // index 1..=3 used
        for line in ls_out.lines() {
            // <mode> <sha> <stage>\t<path>
            let mut iter = line.split_whitespace();
            let _mode = iter.next();
            let _sha = iter.next();
            if let Some(stage_str) = iter.next()
                && let Ok(stage) = stage_str.parse::<usize>()
                && (1..=3).contains(&stage)
            {
                have_stage[stage] = true;
            }
        }

        // 2. Read each stage's blob (if present).
        let base = if have_stage[1] {
            Some(self.show_blob_bytes(dir, &format!(":1:{path}")).await?)
        } else {
            None
        };
        let ours = if have_stage[2] {
            Some(self.show_blob_bytes(dir, &format!(":2:{path}")).await?)
        } else {
            None
        };
        let theirs = if have_stage[3] {
            Some(self.show_blob_bytes(dir, &format!(":3:{path}")).await?)
        } else {
            None
        };

        // 3. Determine conflict kind from stage presence (classic matrix).
        let kind = match (have_stage[1], have_stage[2], have_stage[3]) {
            (true, true, true) => ConflictKind::BothModified,
            (false, true, true) => ConflictKind::BothAdded,
            (true, false, true) => ConflictKind::DeletedByUs,
            (true, true, false) => ConflictKind::DeletedByThem,
            _ => ConflictKind::Other,
        };

        // 4. Binary detection: `check-attr binary <path>` returns
        //    "<path>: binary: set" if .gitattributes marks it binary; else
        //    we fall back to scanning for NUL bytes in any present stage.
        let binary_attr = self
            .run(dir, &["check-attr", "binary", "--", path])
            .await
            .ok()
            .map(|s| s.contains(": set"))
            .unwrap_or(false);
        let nul_in_any = [&base, &ours, &theirs]
            .iter()
            .any(|b| b.as_ref().is_some_and(|v| v.contains(&0u8)));
        let is_binary = binary_attr || nul_in_any;

        Ok(ConflictedFile {
            path: path.to_string(),
            is_binary,
            base,
            ours,
            theirs,
            kind,
        })
    }

    /// Resolve a conflicted path by taking "ours" (stage 2).
    ///
    /// Runs `git checkout --ours -- <path>` then stages the result. For
    /// delete/modify conflicts where "ours" deleted, this leaves the file
    /// deleted (and stages the deletion).
    pub async fn checkout_ours(&self, dir: &Path, path: &str) -> Result<()> {
        // If ours deleted the file, `checkout --ours` errors — recover by
        // removing via `git rm`.
        match self.run(dir, &["checkout", "--ours", "--", path]).await {
            Ok(_) => {
                let _ = self.run(dir, &["add", "--", path]).await?;
                Ok(())
            }
            Err(_) => {
                let _ = self.run(dir, &["rm", "-f", "--", path]).await?;
                Ok(())
            }
        }
    }

    /// Resolve a conflicted path by taking "theirs" (stage 3). Mirror of
    /// `checkout_ours`.
    pub async fn checkout_theirs(&self, dir: &Path, path: &str) -> Result<()> {
        match self.run(dir, &["checkout", "--theirs", "--", path]).await {
            Ok(_) => {
                let _ = self.run(dir, &["add", "--", path]).await?;
                Ok(())
            }
            Err(_) => {
                let _ = self.run(dir, &["rm", "-f", "--", path]).await?;
                Ok(())
            }
        }
    }

    /// Complete an in-progress merge after conflicts were resolved. Uses
    /// `--no-edit` so git accepts the default commit message.
    pub async fn merge_continue(&self, dir: &Path, message: Option<&str>) -> Result<String> {
        match message {
            Some(m) => {
                let _ = self.run(dir, &["commit", "--no-edit", "-m", m]).await?;
            }
            None => {
                let _ = self.run(dir, &["commit", "--no-edit"]).await?;
            }
        }
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Continue an in-progress rebase after conflicts were resolved. Needs
    /// `GIT_EDITOR=true` so git doesn't open an editor on the commit message.
    pub async fn rebase_continue(&self, dir: &Path) -> Result<()> {
        let _ = self
            .run_with_env(dir, &["rebase", "--continue"], &[("GIT_EDITOR", "true")])
            .await?;
        Ok(())
    }
}
