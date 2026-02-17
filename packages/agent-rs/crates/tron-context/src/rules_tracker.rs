//! Rules tracker for session-level rules management.
//!
//! [`RulesTracker`] manages tracking of rules files loaded for a session's
//! context. Rules are loaded once at session start and are immutable for the
//! session lifetime.
//!
//! ## Static rules
//!
//! Loaded from a `rules.loaded` event. Provides file list for context snapshot
//! responses. Supports event-sourced reconstruction for session resume/fork.
//!
//! ## Dynamic rules activation
//!
//! After discovery, a [`RulesIndex`] is set on the tracker. As the agent
//! touches file paths (via `PostToolUse` hook), scoped rules activate when
//! touched paths fall under their `scope_dir`. Global rules are always
//! injected; scoped rules only appear after activation.
//!
//! Content is cached until new activations occur. At compaction boundaries,
//! `clear_dynamic_state()` resets activation state but preserves the index.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::rules_discovery::DiscoveredRulesFile;
use crate::rules_index::RulesIndex;
use crate::types::RulesLevel;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// Information about a tracked rules file (from `rules.loaded` event).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackedRulesFile {
    /// Absolute path to the file.
    pub path: String,
    /// Path relative to working directory.
    pub relative_path: String,
    /// Level in the hierarchy.
    pub level: RulesLevel,
    /// Depth from project root (-1 for global, 0 for project root).
    pub depth: i32,
    /// File size in bytes.
    pub size_bytes: u64,
}

/// File info from a `rules.loaded` event payload.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesFileInfo {
    /// Absolute path.
    pub path: String,
    /// Relative path.
    pub relative_path: String,
    /// Rule level.
    pub level: RulesLevel,
    /// Depth from project root.
    pub depth: i32,
    /// File size in bytes.
    pub size_bytes: u64,
}

/// Generic event structure for reconstruction.
#[derive(Clone, Debug)]
pub struct RulesTrackingEvent {
    /// Event ID.
    pub id: String,
    /// Event type (e.g. `"rules.loaded"`).
    pub event_type: String,
    /// Event payload as JSON.
    pub payload: Value,
}

// ─────────────────────────────────────────────────────────────────────────────
// RulesTracker
// ─────────────────────────────────────────────────────────────────────────────

/// Session-level rules state manager.
///
/// Tracks statically loaded rules (from events) and dynamically activated
/// scoped rules (from file path touches). Provides content building for
/// context injection.
#[derive(Clone, Debug)]
pub struct RulesTracker {
    // Static rules state
    files: Vec<TrackedRulesFile>,
    merged_tokens: u32,
    loaded_event_id: Option<String>,
    merged_content: Option<String>,

    // Dynamic rules state
    rules_index: Option<RulesIndex>,
    touched_paths: HashSet<String>,
    /// Activated scoped rules in activation order (insertion order preserved).
    /// Each entry is `(relative_path, rule)`.
    activated_scoped_rules: Vec<(String, DiscoveredRulesFile)>,
    activated_keys: HashSet<String>,
    dynamic_content: Option<String>,
    dynamic_content_dirty: bool,
}

impl RulesTracker {
    /// Create a new empty tracker.
    #[must_use]
    pub fn new() -> Self {
        Self {
            files: Vec::new(),
            merged_tokens: 0,
            loaded_event_id: None,
            merged_content: None,
            rules_index: None,
            touched_paths: HashSet::new(),
            activated_scoped_rules: Vec::new(),
            activated_keys: HashSet::new(),
            dynamic_content: None,
            dynamic_content_dirty: true,
        }
    }

    // ── Static rules ─────────────────────────────────────────────────────

    /// Record that rules files have been loaded.
    ///
    /// Called once per session from a `rules.loaded` event.
    pub fn set_rules(
        &mut self,
        files: Vec<RulesFileInfo>,
        merged_tokens: u32,
        event_id: String,
        merged_content: Option<String>,
    ) {
        self.files = files
            .into_iter()
            .map(|f| TrackedRulesFile {
                path: f.path,
                relative_path: f.relative_path,
                level: f.level,
                depth: f.depth,
                size_bytes: f.size_bytes,
            })
            .collect();
        self.merged_tokens = merged_tokens;
        self.loaded_event_id = Some(event_id);
        self.merged_content = merged_content;
    }

    /// Get all loaded rules files.
    #[must_use]
    pub fn get_rules_files(&self) -> &[TrackedRulesFile] {
        &self.files
    }

    /// Get the total number of rules files.
    #[must_use]
    pub fn total_files(&self) -> usize {
        self.files.len()
    }

    /// Get estimated token count for merged rules content.
    #[must_use]
    pub fn merged_tokens(&self) -> u32 {
        self.merged_tokens
    }

    /// Get the event ID of the `rules.loaded` event.
    #[must_use]
    pub fn event_id(&self) -> Option<&str> {
        self.loaded_event_id.as_deref()
    }

    /// Get cached merged content (if available).
    #[must_use]
    pub fn merged_content(&self) -> Option<&str> {
        self.merged_content.as_deref()
    }

    /// Check if any rules are loaded (static or dynamic).
    #[must_use]
    pub fn has_rules(&self) -> bool {
        !self.files.is_empty()
            || self
                .rules_index
                .as_ref()
                .is_some_and(|idx| idx.total_count() > 0)
    }

    /// Get the number of files at each level.
    #[must_use]
    pub fn counts_by_level(&self) -> LevelCounts {
        let mut counts = LevelCounts::default();
        for file in &self.files {
            match file.level {
                RulesLevel::Global => counts.global += 1,
                RulesLevel::Project => counts.project += 1,
                RulesLevel::Directory => counts.directory += 1,
            }
        }
        counts
    }

    // ── Dynamic rules activation ─────────────────────────────────────────

    /// Set the rules index for dynamic path-scoped matching.
    ///
    /// Called after discovery + indexing at session start.
    pub fn set_rules_index(&mut self, index: RulesIndex) {
        self.rules_index = Some(index);
        self.dynamic_content_dirty = true;
    }

    /// Get a reference to the rules index (if set).
    #[must_use]
    pub fn rules_index(&self) -> Option<&RulesIndex> {
        self.rules_index.as_ref()
    }

    /// Record that a file path was touched by the agent.
    ///
    /// Checks scoped rules for activation. Returns `true` if new scoped
    /// rules were activated.
    pub fn touch_path(&mut self, relative_path: &str) -> bool {
        let Some(index) = &self.rules_index else {
            return false;
        };

        let _ = self.touched_paths.insert(relative_path.to_owned());

        let matched = index.match_path(relative_path);
        let mut new_activations = false;

        for rule in matched {
            if !self.activated_keys.contains(&rule.relative_path) {
                let _ = self.activated_keys
                    .insert(rule.relative_path.clone());
                self.activated_scoped_rules
                    .push((rule.relative_path.clone(), rule.clone()));
                new_activations = true;
            }
        }

        if new_activations {
            self.dynamic_content_dirty = true;
        }

        new_activations
    }

    /// Build the merged dynamic rules content string.
    ///
    /// Includes global rules (always) and activated scoped rules.
    /// Returns `None` if no index is set or no rules to include.
    ///
    /// Content is cached until new activations occur.
    #[must_use]
    pub fn build_dynamic_rules_content(&mut self) -> Option<&str> {
        let index = self.rules_index.as_ref()?;

        let global_rules = index.get_global_rules();
        let activated_count = self.activated_scoped_rules.len();

        if global_rules.is_empty() && activated_count == 0 {
            return None;
        }

        if !self.dynamic_content_dirty {
            return self.dynamic_content.as_deref();
        }

        let mut sections = Vec::new();

        // Global rules first, sorted by relative_path for determinism
        let mut sorted_globals: Vec<_> = global_rules;
        sorted_globals.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
        for rule in &sorted_globals {
            sections.push(format!(
                "<!-- Rule: {} -->\n{}",
                rule.relative_path,
                rule.content.trim()
            ));
        }

        // Scoped rules in activation order
        for (_, rule) in &self.activated_scoped_rules {
            sections.push(format!(
                "<!-- Rule: {} (activated) -->\n{}",
                rule.relative_path,
                rule.content.trim()
            ));
        }

        self.dynamic_content = Some(sections.join("\n\n"));
        self.dynamic_content_dirty = false;

        self.dynamic_content.as_deref()
    }

    /// Get all activated scoped rules.
    #[must_use]
    pub fn activated_rules(&self) -> Vec<&DiscoveredRulesFile> {
        self.activated_scoped_rules
            .iter()
            .map(|(_, rule)| rule)
            .collect()
    }

    /// Get global rules from the index (if set).
    #[must_use]
    pub fn global_rules_from_index(&self) -> Vec<&DiscoveredRulesFile> {
        self.rules_index
            .as_ref()
            .map(|idx| idx.get_global_rules())
            .unwrap_or_default()
    }

    /// Get the set of all touched file paths.
    #[must_use]
    pub fn touched_paths(&self) -> &HashSet<String> {
        &self.touched_paths
    }

    /// Get count of activated scoped rules.
    #[must_use]
    pub fn activated_scoped_rules_count(&self) -> usize {
        self.activated_scoped_rules.len()
    }

    /// Pre-activate a rule by its relative path (for session reconstruction).
    ///
    /// Looks up the rule in the index and activates it without a file path
    /// touch. Returns `true` if the rule was newly activated.
    pub fn pre_activate(&mut self, rule_relative_path: &str) -> bool {
        let Some(index) = &self.rules_index else {
            return false;
        };
        let Some(rule) = index.find_by_relative_path(rule_relative_path).cloned() else {
            return false;
        };
        if self.activated_keys.insert(rule.relative_path.clone()) {
            self.activated_scoped_rules
                .push((rule.relative_path.clone(), rule));
            self.dynamic_content_dirty = true;
            true
        } else {
            false
        }
    }

    /// Clear dynamic activation state (for compaction boundary).
    ///
    /// Resets touched paths and activated rules but preserves the index.
    pub fn clear_dynamic_state(&mut self) {
        self.touched_paths.clear();
        self.activated_scoped_rules.clear();
        self.activated_keys.clear();
        self.dynamic_content = None;
        self.dynamic_content_dirty = true;
    }

    // ── Event sourcing ───────────────────────────────────────────────────

    /// Reconstruct rules state from event history.
    ///
    /// Scans for `rules.loaded` events and extracts their payload.
    /// Rules are loaded once per session and are immutable, so we just
    /// look for the most recent `rules.loaded` event.
    #[must_use]
    pub fn from_events(events: &[RulesTrackingEvent]) -> Self {
        let mut tracker = Self::new();

        for event in events {
            if event.event_type == "rules.loaded" {
                if let Ok(files) =
                    serde_json::from_value::<Vec<RulesFileInfo>>(
                        event.payload.get("files").cloned().unwrap_or_default(),
                    )
                {
                    let merged_tokens = event
                        .payload
                        .get("mergedTokens")
                        .and_then(serde_json::Value::as_u64)
                        .unwrap_or(0);

                    #[allow(clippy::cast_possible_truncation)]
                    tracker.set_rules(
                        files,
                        merged_tokens as u32,
                        event.id.clone(),
                        None,
                    );
                }
            }
        }

        tracker
    }
}

impl Default for RulesTracker {
    fn default() -> Self {
        Self::new()
    }
}

/// Counts of rules files by level.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LevelCounts {
    /// Global-level rules.
    pub global: usize,
    /// Project-level rules.
    pub project: usize,
    /// Directory-level rules.
    pub directory: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::SystemTime;

    fn make_discovered(
        scope_dir: &str,
        relative_path: &str,
        is_global: bool,
        content: &str,
    ) -> DiscoveredRulesFile {
        DiscoveredRulesFile {
            path: PathBuf::from(format!("/project/{relative_path}")),
            relative_path: relative_path.to_owned(),
            content: content.to_owned(),
            scope_dir: scope_dir.to_owned(),
            is_global,
            is_standalone: false,
            size_bytes: content.len() as u64,
            modified_at: SystemTime::UNIX_EPOCH,
        }
    }

    fn make_global_rule(relative_path: &str, content: &str) -> DiscoveredRulesFile {
        make_discovered("", relative_path, true, content)
    }

    fn make_scoped_rule(
        scope_dir: &str,
        relative_path: &str,
        content: &str,
    ) -> DiscoveredRulesFile {
        make_discovered(scope_dir, relative_path, false, content)
    }

    // -- Construction --

    #[test]
    fn new_tracker_is_empty() {
        let tracker = RulesTracker::new();
        assert!(!tracker.has_rules());
        assert_eq!(tracker.total_files(), 0);
        assert_eq!(tracker.merged_tokens(), 0);
        assert!(tracker.event_id().is_none());
        assert!(tracker.merged_content().is_none());
    }

    #[test]
    fn default_tracker_is_empty() {
        let tracker = RulesTracker::default();
        assert!(!tracker.has_rules());
    }

    // -- Static rules --

    #[test]
    fn set_rules_stores_files() {
        let mut tracker = RulesTracker::new();
        tracker.set_rules(
            vec![RulesFileInfo {
                path: "/project/.claude/AGENTS.md".into(),
                relative_path: ".claude/AGENTS.md".into(),
                level: RulesLevel::Project,
                depth: 0,
                size_bytes: 50,
            }],
            25,
            "evt-1".into(),
            None,
        );

        assert!(tracker.has_rules());
        assert_eq!(tracker.total_files(), 1);
        assert_eq!(tracker.merged_tokens(), 25);
        assert_eq!(tracker.event_id(), Some("evt-1"));
    }

    #[test]
    fn set_rules_stores_merged_content() {
        let mut tracker = RulesTracker::new();
        tracker.set_rules(vec![], 10, "evt-1".into(), Some("merged content".into()));

        assert_eq!(tracker.merged_content(), Some("merged content"));
    }

    #[test]
    fn counts_by_level() {
        let mut tracker = RulesTracker::new();
        tracker.set_rules(
            vec![
                RulesFileInfo {
                    path: "/p/a".into(),
                    relative_path: "a".into(),
                    level: RulesLevel::Global,
                    depth: -1,
                    size_bytes: 10,
                },
                RulesFileInfo {
                    path: "/p/b".into(),
                    relative_path: "b".into(),
                    level: RulesLevel::Project,
                    depth: 0,
                    size_bytes: 10,
                },
                RulesFileInfo {
                    path: "/p/c".into(),
                    relative_path: "c".into(),
                    level: RulesLevel::Directory,
                    depth: 1,
                    size_bytes: 10,
                },
                RulesFileInfo {
                    path: "/p/d".into(),
                    relative_path: "d".into(),
                    level: RulesLevel::Directory,
                    depth: 2,
                    size_bytes: 10,
                },
            ],
            0,
            "evt-1".into(),
            None,
        );

        let counts = tracker.counts_by_level();
        assert_eq!(
            counts,
            LevelCounts {
                global: 1,
                project: 1,
                directory: 2
            }
        );
    }

    // -- Dynamic rules --

    #[test]
    fn build_dynamic_content_returns_none_without_index() {
        let mut tracker = RulesTracker::new();
        assert!(tracker.build_dynamic_rules_content().is_none());
    }

    #[test]
    fn build_dynamic_content_with_only_global_rules() {
        let global = make_global_rule(".claude/CLAUDE.md", "# Global rules");
        let index = RulesIndex::new(vec![global]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let content = tracker.build_dynamic_rules_content().unwrap();
        assert!(content.contains("# Global rules"));
        assert!(content.contains("<!-- Rule: .claude/CLAUDE.md -->"));
    }

    #[test]
    fn no_paths_touched_only_global_content() {
        let global = make_global_rule(".claude/CLAUDE.md", "# Global");
        let scoped = make_scoped_rule(
            "packages/context",
            "packages/context/.claude/CLAUDE.md",
            "# Context rules",
        );
        let index = RulesIndex::new(vec![global, scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let content = tracker.build_dynamic_rules_content().unwrap();
        assert!(content.contains("# Global"));
        assert!(!content.contains("# Context rules"));
    }

    #[test]
    fn touch_path_activates_matching_scoped_rule() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Context rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert_eq!(tracker.activated_scoped_rules_count(), 0);

        let activated = tracker.touch_path("src/context/loader.ts");
        assert!(activated);
        assert_eq!(tracker.activated_scoped_rules_count(), 1);

        let content = tracker.build_dynamic_rules_content().unwrap();
        assert!(content.contains("# Context rules"));
        assert!(content.contains("(activated)"));
    }

    #[test]
    fn touch_path_same_path_twice_is_idempotent() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let _ = tracker.touch_path("src/context/loader.ts");
        let activated = tracker.touch_path("src/context/loader.ts");
        assert!(!activated);
        assert_eq!(tracker.activated_scoped_rules_count(), 1);
    }

    #[test]
    fn touch_path_unrelated_causes_no_activation() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let activated = tracker.touch_path("src/runtime/agent.ts");
        assert!(!activated);
        assert_eq!(tracker.activated_scoped_rules_count(), 0);
    }

    #[test]
    fn touch_path_activates_multiple_overlapping_rules() {
        let rule1 = make_scoped_rule("packages", "packages/.claude/CLAUDE.md", "# Pkg");
        let rule2 = make_scoped_rule(
            "packages/agent",
            "packages/agent/.claude/CLAUDE.md",
            "# Agent",
        );
        let index = RulesIndex::new(vec![rule1, rule2]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let _ = tracker.touch_path("packages/agent/src/loader.ts");
        assert_eq!(tracker.activated_scoped_rules_count(), 2);
    }

    #[test]
    fn content_is_cached_until_new_activation() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Context",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let _ = tracker.touch_path("src/context/loader.ts");
        let content1 = tracker.build_dynamic_rules_content().unwrap().to_owned();
        let content2 = tracker.build_dynamic_rules_content().unwrap().to_owned();
        assert_eq!(content1, content2);
    }

    #[test]
    fn get_activated_rules() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert!(tracker.activated_rules().is_empty());
        let _ = tracker.touch_path("src/context/loader.ts");
        assert_eq!(tracker.activated_rules().len(), 1);
        assert_eq!(
            tracker.activated_rules()[0].relative_path,
            "src/context/.claude/CLAUDE.md"
        );
    }

    #[test]
    fn get_global_rules_from_index() {
        let global = make_global_rule(".claude/CLAUDE.md", "# G");
        let index = RulesIndex::new(vec![global]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert_eq!(tracker.global_rules_from_index().len(), 1);
    }

    #[test]
    fn get_touched_paths() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let _ = tracker.touch_path("src/context/loader.ts");
        let _ = tracker.touch_path("src/runtime/agent.ts");

        let touched = tracker.touched_paths();
        assert_eq!(touched.len(), 2);
        assert!(touched.contains("src/context/loader.ts"));
        assert!(touched.contains("src/runtime/agent.ts"));
    }

    #[test]
    fn content_format_globals_first_then_scoped_in_activation_order() {
        let global1 = make_global_rule(".claude/b-global.md", "# Global B");
        let global2 = make_global_rule(".claude/a-global.md", "# Global A");
        let scoped1 =
            make_scoped_rule("src/tools", "src/tools/.claude/CLAUDE.md", "# Tools");
        let scoped2 =
            make_scoped_rule("src/context", "src/context/.claude/CLAUDE.md", "# Context");
        let index = RulesIndex::new(vec![global1, global2, scoped1, scoped2]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        // Activate tools first, then context
        let _ = tracker.touch_path("src/tools/read.ts");
        let _ = tracker.touch_path("src/context/loader.ts");

        let content = tracker.build_dynamic_rules_content().unwrap();
        let global_a_pos = content.find("# Global A").unwrap();
        let global_b_pos = content.find("# Global B").unwrap();
        let tools_pos = content.find("# Tools").unwrap();
        let context_pos = content.find("# Context").unwrap();

        // Globals sorted by relative_path (a < b)
        assert!(global_a_pos < global_b_pos);
        // Globals before scoped
        assert!(global_b_pos < tools_pos);
        // Scoped in activation order (tools first, then context)
        assert!(tools_pos < context_pos);
    }

    #[test]
    fn rule_sections_include_comment_headers() {
        let global = make_global_rule(".claude/CLAUDE.md", "# G");
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# C",
        );
        let index = RulesIndex::new(vec![global, scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);
        let _ = tracker.touch_path("src/context/x.ts");

        let content = tracker.build_dynamic_rules_content().unwrap();
        assert!(content.contains("<!-- Rule: .claude/CLAUDE.md -->"));
        assert!(content
            .contains("<!-- Rule: src/context/.claude/CLAUDE.md (activated) -->"));
    }

    #[test]
    fn clear_dynamic_state_resets_activation() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Context",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let _ = tracker.touch_path("src/context/loader.ts");
        assert_eq!(tracker.activated_scoped_rules_count(), 1);
        assert_eq!(tracker.touched_paths().len(), 1);

        tracker.clear_dynamic_state();
        assert_eq!(tracker.activated_scoped_rules_count(), 0);
        assert_eq!(tracker.touched_paths().len(), 0);
        // Index is preserved
        assert!(tracker.rules_index().is_some());
    }

    #[test]
    fn returns_none_when_index_exists_but_no_rules_active() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        // No paths touched → no activated rules, no globals
        assert!(tracker.build_dynamic_rules_content().is_none());
    }

    #[test]
    fn touch_path_with_no_index_returns_false() {
        let mut tracker = RulesTracker::new();
        assert!(!tracker.touch_path("anything.ts"));
    }

    #[test]
    fn has_rules_with_index_only() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert!(tracker.has_rules());
    }

    // -- Pre-activate --

    #[test]
    fn pre_activate_activates_by_relative_path() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Context rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert!(tracker.pre_activate("src/context/.claude/CLAUDE.md"));
        assert_eq!(tracker.activated_scoped_rules_count(), 1);
    }

    #[test]
    fn pre_activate_unknown_path_returns_false() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert!(!tracker.pre_activate("nonexistent/.claude/CLAUDE.md"));
        assert_eq!(tracker.activated_scoped_rules_count(), 0);
    }

    #[test]
    fn pre_activate_already_activated_is_idempotent() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        assert!(tracker.pre_activate("src/context/.claude/CLAUDE.md"));
        assert!(!tracker.pre_activate("src/context/.claude/CLAUDE.md"));
        assert_eq!(tracker.activated_scoped_rules_count(), 1);
    }

    #[test]
    fn pre_activate_without_index_returns_false() {
        let mut tracker = RulesTracker::new();
        assert!(!tracker.pre_activate("anything/.claude/CLAUDE.md"));
    }

    #[test]
    fn pre_activate_makes_content_available() {
        let scoped = make_scoped_rule(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            "# Context rules",
        );
        let index = RulesIndex::new(vec![scoped]);
        let mut tracker = RulesTracker::new();
        tracker.set_rules_index(index);

        let _ = tracker.pre_activate("src/context/.claude/CLAUDE.md");
        let content = tracker.build_dynamic_rules_content().unwrap();
        assert!(content.contains("# Context rules"));
        assert!(content.contains("(activated)"));
    }

    // -- Event sourcing --

    #[test]
    fn from_events_reconstructs_state() {
        let events = vec![RulesTrackingEvent {
            id: "evt-1".into(),
            event_type: "rules.loaded".into(),
            payload: serde_json::json!({
                "files": [{
                    "path": "/p/.claude/AGENTS.md",
                    "relativePath": ".claude/AGENTS.md",
                    "level": "project",
                    "depth": 0,
                    "sizeBytes": 50
                }],
                "totalFiles": 1,
                "mergedTokens": 25
            }),
        }];

        let tracker = RulesTracker::from_events(&events);
        assert!(tracker.has_rules());
        assert_eq!(tracker.total_files(), 1);
        assert_eq!(tracker.merged_tokens(), 25);
        assert_eq!(tracker.event_id(), Some("evt-1"));
    }

    #[test]
    fn from_events_ignores_non_rules_events() {
        let events = vec![RulesTrackingEvent {
            id: "evt-1".into(),
            event_type: "session.start".into(),
            payload: serde_json::json!({}),
        }];

        let tracker = RulesTracker::from_events(&events);
        assert!(!tracker.has_rules());
        assert_eq!(tracker.total_files(), 0);
    }

    #[test]
    fn from_events_empty_list() {
        let tracker = RulesTracker::from_events(&[]);
        assert!(!tracker.has_rules());
    }

    #[test]
    fn from_events_uses_last_rules_loaded() {
        let events = vec![
            RulesTrackingEvent {
                id: "evt-1".into(),
                event_type: "rules.loaded".into(),
                payload: serde_json::json!({
                    "files": [{
                        "path": "/p/a",
                        "relativePath": "a",
                        "level": "global",
                        "depth": -1,
                        "sizeBytes": 10
                    }],
                    "totalFiles": 1,
                    "mergedTokens": 10
                }),
            },
            RulesTrackingEvent {
                id: "evt-2".into(),
                event_type: "rules.loaded".into(),
                payload: serde_json::json!({
                    "files": [{
                        "path": "/p/b",
                        "relativePath": "b",
                        "level": "project",
                        "depth": 0,
                        "sizeBytes": 20
                    }],
                    "totalFiles": 1,
                    "mergedTokens": 20
                }),
            },
        ];

        let tracker = RulesTracker::from_events(&events);
        // The second (latest) rules.loaded should be the active one
        assert_eq!(tracker.total_files(), 1);
        assert_eq!(tracker.merged_tokens(), 20);
        assert_eq!(tracker.event_id(), Some("evt-2"));
    }
}
