//! In-memory rules index with directory-prefix matching.
//!
//! [`RulesIndex`] answers "which rules match this file path?" using simple
//! directory-prefix matching. No glob patterns — a rule's `scope_dir` is a
//! directory prefix that activates when the agent touches any file under that
//! directory.
//!
//! ## Matching semantics
//!
//! A scoped rule matches a file path if:
//! - `file_path.starts_with(scope_dir + "/")`, OR
//! - `file_path == scope_dir`
//!
//! An empty `scope_dir` matches everything (root scope).
//!
//! Importantly, `packages/agent-tools` does NOT match `packages/agent` because
//! the slash boundary is enforced.

use crate::rules_discovery::DiscoveredRulesFile;

/// Index of discovered rules files with directory-prefix matching.
///
/// Separates rules into global (always-on) and scoped (directory-matched).
/// Scoped rules are sorted by `scope_dir` length descending (most specific
/// first) for deterministic matching order.
#[derive(Clone, Debug)]
pub struct RulesIndex {
    global_rules: Vec<DiscoveredRulesFile>,
    scoped_rules: Vec<DiscoveredRulesFile>,
}

impl RulesIndex {
    /// Create a new index from discovered rules files.
    ///
    /// Global rules (`is_global == true`) and scoped rules are separated.
    /// Scoped rules are sorted by `scope_dir` length descending so that
    /// more specific rules come first.
    #[must_use]
    pub fn new(rules_files: Vec<DiscoveredRulesFile>) -> Self {
        let mut global_rules = Vec::new();
        let mut scoped_rules = Vec::new();

        for file in rules_files {
            if file.is_global {
                global_rules.push(file);
            } else {
                scoped_rules.push(file);
            }
        }

        // Sort scoped rules by scope_dir length descending (most specific first)
        scoped_rules.sort_by(|a, b| b.scope_dir.len().cmp(&a.scope_dir.len()));

        Self {
            global_rules,
            scoped_rules,
        }
    }

    /// Get scoped rules that match a given relative file path.
    ///
    /// Returns only scoped rules — global rules are not included here since
    /// they always apply regardless of path.
    #[must_use]
    pub fn match_path(&self, relative_path: &str) -> Vec<&DiscoveredRulesFile> {
        self.scoped_rules
            .iter()
            .filter(|rule| path_starts_with(relative_path, &rule.scope_dir))
            .collect()
    }

    /// Get all global (always-on) rules.
    #[must_use]
    pub fn get_global_rules(&self) -> Vec<&DiscoveredRulesFile> {
        self.global_rules.iter().collect()
    }

    /// Get all scoped rules (for audit/debug).
    #[must_use]
    pub fn get_scoped_rules(&self) -> Vec<&DiscoveredRulesFile> {
        self.scoped_rules.iter().collect()
    }

    /// Total number of indexed rules (global + scoped).
    #[must_use]
    pub fn total_count(&self) -> usize {
        self.global_rules.len() + self.scoped_rules.len()
    }

    /// Number of global rules.
    #[must_use]
    pub fn global_count(&self) -> usize {
        self.global_rules.len()
    }

    /// Number of scoped rules.
    #[must_use]
    pub fn scoped_count(&self) -> usize {
        self.scoped_rules.len()
    }
}

/// Check if a file path falls under a scope directory.
///
/// ```text
/// path_starts_with("packages/foo/src/bar.ts", "packages/foo") → true
/// path_starts_with("packages/foo-tools/bar.ts", "packages/foo") → false
/// path_starts_with("anything", "") → true
/// ```
fn path_starts_with(file_path: &str, scope_dir: &str) -> bool {
    if scope_dir.is_empty() {
        return true; // Root scope matches everything
    }
    file_path.starts_with(&format!("{scope_dir}/")) || file_path == scope_dir
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::SystemTime;

    fn make_rule(scope_dir: &str, relative_path: &str, is_global: bool) -> DiscoveredRulesFile {
        DiscoveredRulesFile {
            path: PathBuf::from(format!("/project/{relative_path}")),
            relative_path: relative_path.to_owned(),
            content: format!("# Test rule for {relative_path}"),
            scope_dir: scope_dir.to_owned(),
            is_global,
            is_standalone: false,
            size_bytes: 100,
            modified_at: SystemTime::UNIX_EPOCH,
        }
    }

    fn make_global(relative_path: &str) -> DiscoveredRulesFile {
        make_rule("", relative_path, true)
    }

    fn make_scoped(scope_dir: &str, relative_path: &str) -> DiscoveredRulesFile {
        make_rule(scope_dir, relative_path, false)
    }

    #[test]
    fn empty_index() {
        let index = RulesIndex::new(vec![]);
        assert!(index.match_path("src/anything.ts").is_empty());
        assert!(index.get_global_rules().is_empty());
        assert_eq!(index.total_count(), 0);
    }

    #[test]
    fn global_rules_from_get_global_rules() {
        let global = make_global(".claude/CLAUDE.md");
        let index = RulesIndex::new(vec![global]);

        assert_eq!(index.get_global_rules().len(), 1);
        assert_eq!(
            index.get_global_rules()[0].relative_path,
            ".claude/CLAUDE.md"
        );
        assert_eq!(index.global_count(), 1);
        assert_eq!(index.scoped_count(), 0);
    }

    #[test]
    fn matches_path_under_scope_dir() {
        let scoped = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![scoped]);

        assert_eq!(
            index.match_path("packages/agent/src/loader.ts").len(),
            1
        );
        assert_eq!(
            index.match_path("packages/agent/package.json").len(),
            1
        );
    }

    #[test]
    fn does_not_match_unrelated_path() {
        let scoped = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![scoped]);

        assert!(index
            .match_path("packages/ios-app/src/main.swift")
            .is_empty());
        assert!(index.match_path("src/tools/fs/read.ts").is_empty());
    }

    #[test]
    fn does_not_match_partial_directory_prefix() {
        let scoped = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![scoped]);

        // "packages/agent-tools" should NOT match "packages/agent"
        assert!(index
            .match_path("packages/agent-tools/index.ts")
            .is_empty());
    }

    #[test]
    fn matches_files_directly_in_scope_dir() {
        let scoped = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![scoped]);

        assert_eq!(index.match_path("packages/agent/index.ts").len(), 1);
    }

    #[test]
    fn multiple_rules_can_match_same_path() {
        let rule1 = make_scoped("packages", "packages/.claude/CLAUDE.md");
        let rule2 = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![rule1, rule2]);

        let matched = index.match_path("packages/agent/src/loader.ts");
        assert_eq!(matched.len(), 2);
    }

    #[test]
    fn returns_most_specific_rule_first() {
        let broad = make_scoped("packages", "packages/.claude/CLAUDE.md");
        let specific = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![broad, specific]);

        let matched = index.match_path("packages/agent/src/loader.ts");
        assert_eq!(matched.len(), 2);
        // Most specific (longest scope_dir) first
        assert_eq!(matched[0].scope_dir, "packages/agent");
        assert_eq!(matched[1].scope_dir, "packages");
    }

    #[test]
    fn total_count_sums_global_and_scoped() {
        let index = RulesIndex::new(vec![
            make_global(".claude/CLAUDE.md"),
            make_global(".tron/AGENTS.md"),
            make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md"),
        ]);

        assert_eq!(index.total_count(), 3);
        assert_eq!(index.global_count(), 2);
        assert_eq!(index.scoped_count(), 1);
    }

    #[test]
    fn get_scoped_rules_returns_all() {
        let s1 = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let s2 = make_scoped("packages/ios-app", "packages/ios-app/.claude/AGENTS.md");
        let g1 = make_global(".claude/CLAUDE.md");

        let index = RulesIndex::new(vec![s1, s2, g1]);
        assert_eq!(index.get_scoped_rules().len(), 2);
    }

    #[test]
    fn rules_from_different_dirs_dont_conflict() {
        let agent_rule = make_scoped("packages/agent", "packages/agent/.claude/CLAUDE.md");
        let ios_rule = make_scoped("packages/ios-app", "packages/ios-app/.claude/CLAUDE.md");
        let index = RulesIndex::new(vec![agent_rule, ios_rule]);

        assert_eq!(
            index.match_path("packages/agent/src/loader.ts").len(),
            1
        );
        assert_eq!(
            index
                .match_path("packages/ios-app/Sources/main.swift")
                .len(),
            1
        );
        assert!(index.match_path("src/runtime/agent.ts").is_empty());
    }

    #[test]
    fn handles_deeply_nested_scope() {
        let deep = make_scoped(
            "packages/agent/src/context",
            "packages/agent/src/context/.claude/CLAUDE.md",
        );
        let index = RulesIndex::new(vec![deep]);

        assert_eq!(
            index
                .match_path("packages/agent/src/context/loader.ts")
                .len(),
            1
        );
        assert!(index
            .match_path("packages/agent/src/runtime/agent.ts")
            .is_empty());
    }

    // -- path_starts_with unit tests --

    #[test]
    fn path_starts_with_empty_scope() {
        assert!(path_starts_with("anything", ""));
    }

    #[test]
    fn path_starts_with_matching_prefix() {
        assert!(path_starts_with("packages/foo/bar.ts", "packages/foo"));
    }

    #[test]
    fn path_starts_with_exact_match() {
        assert!(path_starts_with("packages/foo", "packages/foo"));
    }

    #[test]
    fn path_starts_with_partial_name_does_not_match() {
        assert!(!path_starts_with("packages/foo-extra/bar.ts", "packages/foo"));
    }
}
