//! Per-session skill tracker.
//!
//! Tracks which skills are active in a session and which have been deactivated
//! (for removal notice generation). State is reconstructed from events via
//! [`SkillTracker::from_events_with_policy`], which respects the configured
//! [`CompactionPolicy`](crate::domains::settings::types::CompactionPolicy). All
//! reconstruction goes through this single entry point — there is no
//! policy-less variant — so handlers and helpers can't drift apart on which
//! event types they query or how they treat compaction boundaries.
//!
//! ## Event types handled
//!
//! - `skill.activated` — adds skill to active set
//! - `skill.deactivated` — removes skill, adds to pending removal notices
//! - `compact.boundary` — behavior depends on `CompactionPolicy`:
//!   - `ClearAll` (default): records the active skill names into
//!     `cleared_at_boundary` (so iOS can render an informational notice),
//!     clears all state, sets `skills_cleared_by_compaction` if skills were
//!     active at boundary time.
//!   - `AutoRestore`: clears ephemeral state but keeps active skills; does
//!     NOT populate `cleared_at_boundary` (there's nothing cleared).
//!   - `AskUser`: records the active skill names into `cleared_at_boundary`
//!     (so iOS can render an interactive re-activation picker), clears all
//!     state, sets `skills_cleared_by_compaction` if skills were active.
//!
//!   `ClearAll` and `AskUser` differ only in iOS render mode (carried on the
//!   emitted `skills.cleared` event's `mode` field), not in server bookkeeping.
//! - `context.cleared` — always clears all state regardless of policy
//! - `skills.cleared` — resets `cleared_at_boundary` to prevent duplicate emission
//! - `skill.activated` (post-boundary) — resets `skills_cleared_by_compaction`

use std::collections::{HashMap, HashSet};

use crate::domains::skills::types::{AddedSkillInfo, SkillAddMethod, SkillSource};

/// Internal tracking information for an added skill.
#[derive(Debug, Clone)]
struct TrackedSkill {
    source: SkillSource,
    added_via: SkillAddMethod,
    event_id: Option<String>,
    content_length: Option<usize>,
}

/// Per-session tracker of active skills and removal notices.
///
/// Maintains the set of currently active skills and skills pending removal
/// notice. Supports event-sourced reconstruction.
#[derive(Debug)]
pub struct SkillTracker {
    /// Currently active skills.
    added_skills: HashMap<String, TrackedSkill>,
    /// Skills deactivated since the last prompt (for "stop following" notice).
    /// Cleared after the first prompt that includes the removal notice.
    pending_removal_notices: HashSet<String>,
    /// Skills that were explicitly removed during this session (superset of pending).
    removed_skill_names: HashSet<String>,
    /// Names of skills that were active when cleared by a `compact.boundary`
    /// under `AskUser` policy. Empty for other policies. Reset on each boundary.
    cleared_at_boundary: Vec<String>,
    /// `true` when a `compact.boundary` cleared active skills (ClearAll/AskUser)
    /// and no new skill has been activated since. Used to generate a post-compaction
    /// notice in the system prompt telling the model not to use skills from the
    /// compaction summary.
    skills_cleared_by_compaction: bool,
}

impl SkillTracker {
    /// Create a new empty skill tracker.
    pub fn new() -> Self {
        Self {
            added_skills: HashMap::new(),
            pending_removal_notices: HashSet::new(),
            removed_skill_names: HashSet::new(),
            cleared_at_boundary: Vec::new(),
            skills_cleared_by_compaction: false,
        }
    }

    /// Record a skill as activated in the session context.
    ///
    /// If the skill was previously removed, it is removed from the removal lists.
    pub fn add_skill(
        &mut self,
        name: String,
        source: SkillSource,
        added_via: SkillAddMethod,
        event_id: Option<String>,
    ) {
        let _ = self.removed_skill_names.remove(&name);
        let _ = self.pending_removal_notices.remove(&name);
        let _ = self.added_skills.insert(
            name,
            TrackedSkill {
                source,
                added_via,
                event_id,
                content_length: None,
            },
        );
    }

    /// Record a skill as deactivated from the session context.
    ///
    /// Adds to both the removal set and pending removal notices.
    /// Returns `true` if the skill was present, `false` if not found.
    pub fn remove_skill(&mut self, name: &str) -> bool {
        if self.added_skills.remove(name).is_some() {
            let _ = self.removed_skill_names.insert(name.to_string());
            let _ = self.pending_removal_notices.insert(name.to_string());
            true
        } else {
            false
        }
    }

    /// Set the content length for a tracked skill (used for token estimation).
    pub fn set_content_length(&mut self, name: &str, length: usize) {
        if let Some(skill) = self.added_skills.get_mut(name) {
            skill.content_length = Some(length);
        }
    }

    /// Check if a skill is currently active.
    pub fn has_skill(&self, name: &str) -> bool {
        self.added_skills.contains_key(name)
    }

    /// Get information about all currently active skills.
    ///
    /// Token count is estimated at ~4 bytes per token from content length.
    pub fn added_skills(&self) -> Vec<AddedSkillInfo> {
        self.added_skills
            .iter()
            .map(|(name, tracked)| AddedSkillInfo {
                name: name.clone(),
                source: tracked.source,
                added_via: tracked.added_via,
                event_id: tracked.event_id.clone(),
                tokens: tracked.content_length.map(|len| (len as u64).div_ceil(4)),
            })
            .collect()
    }

    /// Get the names of all currently active skills.
    pub fn active_skill_names(&self) -> Vec<String> {
        self.added_skills.keys().cloned().collect()
    }

    /// Get the number of currently active skills.
    pub fn count(&self) -> usize {
        self.added_skills.len()
    }

    /// Get the names of explicitly removed skills.
    pub fn removed_skill_names(&self) -> &HashSet<String> {
        &self.removed_skill_names
    }

    /// Get skill names pending a "stop following" removal notice.
    ///
    /// These are skills deactivated since the last prompt. The prompt handler
    /// should inject a removal notice for these, then call [`clear_pending_removals`].
    pub fn pending_removal_notices(&self) -> &HashSet<String> {
        &self.pending_removal_notices
    }

    /// Clear pending removal notices after they've been injected into a prompt.
    pub fn clear_pending_removals(&mut self) {
        self.pending_removal_notices.clear();
    }

    /// Estimate the total token count for all active skills.
    pub fn estimate_active_tokens(&self) -> u64 {
        self.added_skills
            .values()
            .filter_map(|s| s.content_length.map(|len| (len as u64).div_ceil(4)))
            .sum()
    }

    /// Clear all tracked state (for context clear/compaction).
    pub fn clear(&mut self) {
        self.added_skills.clear();
        self.removed_skill_names.clear();
        self.pending_removal_notices.clear();
        self.cleared_at_boundary.clear();
        self.skills_cleared_by_compaction = false;
    }

    /// Clear ephemeral state but keep active skills (for `AutoRestore` compaction).
    ///
    /// Clears removed names, pending removal notices, and boundary records
    /// but leaves `added_skills` intact so they survive compaction.
    pub fn clear_ephemeral(&mut self) {
        self.removed_skill_names.clear();
        self.pending_removal_notices.clear();
        self.cleared_at_boundary.clear();
        self.skills_cleared_by_compaction = false;
    }

    /// Names of skills that were active when cleared by a `compact.boundary`
    /// under `AskUser` policy. Empty for other policies.
    pub fn cleared_at_boundary(&self) -> &[String] {
        &self.cleared_at_boundary
    }

    /// Whether skills were cleared by a compaction boundary and no new skill
    /// has been activated since. Used to inject a post-compaction notice into
    /// the system prompt.
    pub fn skills_cleared_by_compaction(&self) -> bool {
        self.skills_cleared_by_compaction
    }

    /// Reconstruct tracker state with compaction policy awareness.
    ///
    /// Like [`from_events`], but respects the `CompactionPolicy` when
    /// processing `compact.boundary` events:
    ///
    /// - `ClearAll` — clears all state (same as `from_events`).
    /// - `AutoRestore` — clears ephemeral state but keeps active skills.
    /// - `AskUser` — records cleared skill names in [`cleared_at_boundary`],
    ///   then clears all state. A subsequent `skills.cleared` event resets
    ///   the recorded names to prevent duplicate emission.
    ///
    /// `context.cleared` always performs a full clear regardless of policy.
    pub fn from_events_with_policy(
        events: &[serde_json::Value],
        policy: &crate::domains::settings::types::CompactionPolicy,
    ) -> Self {
        use crate::domains::settings::types::CompactionPolicy;

        let mut tracker = Self::new();

        for event in events {
            let event_type = event
                .get("type")
                .and_then(|t| t.as_str())
                .unwrap_or_default();
            let event_id = event
                .get("id")
                .and_then(|id| id.as_str())
                .map(ToString::to_string);

            match event_type {
                "skill.activated" => {
                    if let Some(payload) = event.get("payload") {
                        let name = payload
                            .get("skillName")
                            .and_then(|n| n.as_str())
                            .unwrap_or_default()
                            .to_string();
                        let source = match payload
                            .get("source")
                            .and_then(|s| s.as_str())
                            .unwrap_or("global")
                        {
                            "project" => SkillSource::Project,
                            _ => SkillSource::Global,
                        };
                        let added_via = match payload
                            .get("addedVia")
                            .and_then(|a| a.as_str())
                            .unwrap_or("explicit")
                        {
                            "mention" => SkillAddMethod::Mention,
                            _ => SkillAddMethod::Explicit,
                        };

                        if !name.is_empty() {
                            tracker.add_skill(name, source, added_via, event_id);
                            tracker.skills_cleared_by_compaction = false;
                        }
                    }
                }
                "skill.deactivated" => {
                    if let Some(payload) = event.get("payload") {
                        let name = payload
                            .get("skillName")
                            .and_then(|n| n.as_str())
                            .unwrap_or_default();
                        if !name.is_empty() {
                            let _ = tracker.remove_skill(name);
                        }
                    }
                }
                "context.cleared" => {
                    tracker.clear();
                }
                "compact.boundary" => {
                    let had_skills = tracker.count() > 0;
                    match policy {
                        // ClearAll and AskUser share a branch: both clear active
                        // skills AND record the names so a user-visible notice
                        // (informational for ClearAll, interactive re-activation
                        // picker for AskUser) can be emitted on the next prompt.
                        // See M6 in the audit plan: the only difference is iOS
                        // render mode, not server bookkeeping. AutoRestore never
                        // populates `cleared_at_boundary` because it preserves
                        // active skills through the boundary.
                        CompactionPolicy::ClearAll | CompactionPolicy::AskUser => {
                            let names = tracker.active_skill_names();
                            tracker.clear();
                            tracker.cleared_at_boundary = names;
                            tracker.skills_cleared_by_compaction = had_skills;
                        }
                        CompactionPolicy::AutoRestore => tracker.clear_ephemeral(),
                    }
                }
                "skills.cleared" => {
                    tracker.cleared_at_boundary.clear();
                }
                _ => {}
            }
        }

        tracker
    }
}

impl Default for SkillTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::settings::types::CompactionPolicy;

    // ── Direct API tests ────────────────────────────────────────────

    #[test]
    fn test_add_and_has_skill() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "browser".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            Some("evt-1".to_string()),
        );
        assert!(tracker.has_skill("browser"));
        assert!(!tracker.has_skill("other"));
    }

    #[test]
    fn test_remove_skill() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "browser".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        assert!(tracker.remove_skill("browser"));
        assert!(!tracker.has_skill("browser"));
        assert!(tracker.removed_skill_names().contains("browser"));
    }

    #[test]
    fn test_remove_nonexistent_returns_false() {
        let mut tracker = SkillTracker::new();
        assert!(!tracker.remove_skill("nonexistent"));
    }

    #[test]
    fn test_removed_skill_names_tracked() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        let _ = tracker.remove_skill("a");
        assert!(tracker.removed_skill_names().contains("a"));
    }

    #[test]
    fn test_count() {
        let mut tracker = SkillTracker::new();
        assert_eq!(tracker.count(), 0);
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        assert_eq!(tracker.count(), 1);
        tracker.add_skill(
            "b".to_string(),
            SkillSource::Project,
            SkillAddMethod::Explicit,
            None,
        );
        assert_eq!(tracker.count(), 2);
    }

    #[test]
    fn test_clear() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        tracker.clear();
        assert_eq!(tracker.count(), 0);
        assert!(tracker.removed_skill_names().is_empty());
        assert!(tracker.pending_removal_notices().is_empty());
    }

    #[test]
    fn test_set_content_length_and_tokens() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "browser".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        tracker.set_content_length("browser", 400);

        let skills = tracker.added_skills();
        let skill = skills.iter().find(|s| s.name == "browser").unwrap();
        assert_eq!(skill.tokens, Some(100)); // 400 / 4
    }

    #[test]
    fn test_readd_after_remove() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        let _ = tracker.remove_skill("a");
        assert!(!tracker.has_skill("a"));
        assert!(tracker.removed_skill_names().contains("a"));
        assert!(tracker.pending_removal_notices().contains("a"));

        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        assert!(tracker.has_skill("a"));
        assert!(!tracker.removed_skill_names().contains("a"));
        assert!(!tracker.pending_removal_notices().contains("a"));
    }

    #[test]
    fn test_active_skill_names() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            None,
        );
        tracker.add_skill(
            "b".to_string(),
            SkillSource::Project,
            SkillAddMethod::Explicit,
            None,
        );
        let mut names = tracker.active_skill_names();
        names.sort();
        assert_eq!(names, vec!["a", "b"]);
    }

    #[test]
    fn test_estimate_active_tokens() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            None,
        );
        tracker.add_skill(
            "b".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            None,
        );
        tracker.set_content_length("a", 400);
        tracker.set_content_length("b", 800);
        assert_eq!(tracker.estimate_active_tokens(), 300); // 100 + 200
    }

    // ── Pending removal notices ─────────────────────────────────────

    #[test]
    fn test_pending_removal_notices() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            None,
        );
        tracker.add_skill(
            "b".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            None,
        );
        let _ = tracker.remove_skill("a");

        assert!(tracker.pending_removal_notices().contains("a"));
        assert!(!tracker.pending_removal_notices().contains("b"));
    }

    #[test]
    fn test_pending_removal_notices_cleared() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            None,
        );
        let _ = tracker.remove_skill("a");
        assert!(!tracker.pending_removal_notices().is_empty());

        tracker.clear_pending_removals();
        assert!(tracker.pending_removal_notices().is_empty());
        // removed_skill_names still tracks it
        assert!(tracker.removed_skill_names().contains("a"));
    }

    // ── Legacy spell-event tolerance ────────────────────────────────

    #[test]
    fn test_from_events_ignores_legacy_spell_events() {
        // Post-removal invariant: legacy spell.cast / spell.consumed rows in
        // existing session DBs must not affect any tracker state.
        let events = vec![
            serde_json::json!({
                "type": "spell.cast",
                "id": "e1",
                "payload": { "spellName": "commit", "source": "global" }
            }),
            serde_json::json!({
                "type": "spell.consumed",
                "id": "e2",
                "payload": { "spellName": "commit", "castEventId": "e1" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert_eq!(tracker.count(), 0);
        assert!(tracker.pending_removal_notices().is_empty());
        assert!(tracker.active_skill_names().is_empty());
    }

    #[test]
    fn test_legacy_spell_before_compact_boundary_preserves_flags() {
        use crate::domains::settings::types::CompactionPolicy;
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "sa1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "spell.cast",
                "id": "sc1",
                "payload": { "spellName": "commit", "source": "global" }
            }),
            serde_json::json!({ "type": "compact.boundary", "id": "cb1", "payload": {} }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        // Compaction clears `browser`; legacy spell never mattered.
        assert!(tracker.active_skill_names().is_empty());
        assert!(tracker.skills_cleared_by_compaction());
    }

    // ── Activate idempotency ────────────────────────────────────────

    #[test]
    fn test_activate_idempotent() {
        let mut tracker = SkillTracker::new();
        tracker.add_skill(
            "browser".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            Some("evt-1".to_string()),
        );
        tracker.add_skill(
            "browser".to_string(),
            SkillSource::Global,
            SkillAddMethod::Explicit,
            Some("evt-2".to_string()),
        );
        assert_eq!(tracker.count(), 1);
    }

    #[test]
    fn test_deactivate_idempotent() {
        let mut tracker = SkillTracker::new();
        // Deactivating a non-active skill is a no-op
        assert!(!tracker.remove_skill("nonexistent"));
        assert!(tracker.pending_removal_notices().is_empty());
    }

    // ── from_events: new event types ────────────────────────────────

    #[test]
    fn test_from_events_empty() {
        let tracker = SkillTracker::from_events_with_policy(&[], &CompactionPolicy::ClearAll);
        assert_eq!(tracker.count(), 0);
    }

    #[test]
    fn test_from_events_skill_activated() {
        let events = vec![serde_json::json!({
            "type": "skill.activated",
            "id": "evt-1",
            "payload": {
                "skillName": "browser",
                "source": "global"
            }
        })];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert!(tracker.has_skill("browser"));
    }

    #[test]
    fn test_from_events_skill_deactivated() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "browser" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert!(!tracker.has_skill("browser"));
        assert!(tracker.removed_skill_names().contains("browser"));
        assert!(tracker.pending_removal_notices().contains("browser"));
    }

    // ── from_events: compaction ─────────────────────────────────────

    #[test]
    fn test_from_events_context_cleared() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "context.cleared",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert_eq!(tracker.count(), 0);
    }

    #[test]
    fn test_from_events_compact_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert_eq!(tracker.count(), 0);
    }

    #[test]
    fn test_from_events_post_compaction_only() {
        // Events before compaction should be ignored
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "old-skill", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "new-skill", "source": "project" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert!(!tracker.has_skill("old-skill"));
        assert!(tracker.has_skill("new-skill"));
        assert_eq!(tracker.count(), 1);
    }

    #[test]
    fn test_from_events_post_compaction_reactivation() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "browser", "source": "global" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert!(tracker.has_skill("browser"));
        assert_eq!(tracker.count(), 1);
    }

    #[test]
    fn test_from_events_compaction_clears_pending_removals() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "browser" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert!(tracker.pending_removal_notices().is_empty());
        assert!(tracker.removed_skill_names().is_empty());
    }

    // ── from_events: edge cases ─────────────────────────────────────

    #[test]
    fn test_from_events_duplicate_add() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-2",
                "payload": { "skillName": "browser", "source": "project" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        assert_eq!(tracker.count(), 1); // Idempotent
    }

    #[test]
    fn test_from_events_project_source() {
        let events = vec![serde_json::json!({
            "type": "skill.activated",
            "id": "evt-1",
            "payload": { "skillName": "tool", "source": "project" }
        })];
        let tracker = SkillTracker::from_events_with_policy(&events, &CompactionPolicy::ClearAll);
        let skills = tracker.added_skills();
        assert_eq!(skills[0].source, SkillSource::Project);
        assert_eq!(skills[0].added_via, SkillAddMethod::Explicit);
    }

    // ── from_events_with_policy: ClearAll ──────────────────────────

    #[test]
    fn test_policy_clear_all_clears_skills_on_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert_eq!(tracker.count(), 0);
        assert!(!tracker.has_skill("browser"));
    }

    #[test]
    fn test_policy_clear_all_clears_removals_on_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "browser" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(tracker.removed_skill_names().is_empty());
        assert!(tracker.pending_removal_notices().is_empty());
    }

    #[test]
    fn test_policy_clear_all_post_boundary_skills_survive() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "old", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "new", "source": "project" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(!tracker.has_skill("old"));
        assert!(tracker.has_skill("new"));
        assert_eq!(tracker.count(), 1);
    }

    #[test]
    fn test_policy_clear_all_records_cleared_names() {
        // M6: ClearAll must record cleared-at-boundary names so iOS can render
        // a user-visible "previously active" notice (mode="clearAll"). This
        // parallels the AskUser code path but is not the same UX: the iOS
        // render is informational, not an interactive picker.
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-2",
                "payload": { "skillName": "code", "source": "project" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        let mut cleared = tracker.cleared_at_boundary().to_vec();
        cleared.sort();
        assert_eq!(cleared, vec!["browser", "code"]);
        assert_eq!(tracker.count(), 0, "ClearAll still zeroes active skills");
    }

    #[test]
    fn test_policy_clear_all_empty_skills_no_cleared_names() {
        let events = vec![serde_json::json!({
            "type": "compact.boundary",
            "id": "evt-1",
            "payload": {}
        })];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    #[test]
    fn test_policy_clear_all_deactivated_before_boundary_not_in_cleared() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "a" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    #[test]
    fn test_policy_clear_all_multiple_boundaries_resets_cleared() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "b", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-4",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        // Each boundary replaces the prior cleared set — no bleed-through.
        assert_eq!(tracker.cleared_at_boundary(), &["b"]);
    }

    #[test]
    fn test_policy_clear_all_context_cleared_no_cleared_names() {
        // context.cleared is a user-initiated hard reset distinct from compaction.
        // It clears active skills but does NOT populate cleared_at_boundary,
        // because there's no pending "previously active" notice to show — the
        // user just told us to wipe everything.
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "context.cleared",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert_eq!(tracker.count(), 0);
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    #[test]
    fn test_policy_clear_all_skills_cleared_event_suppresses_repeat() {
        // Once a `skills.cleared` event is appended, the tracker must
        // forget the pending names so a subsequent reconstruction doesn't
        // re-emit the notice.
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skills.cleared",
                "id": "evt-3",
                "payload": { "clearedSkills": ["a"], "reason": "compaction", "mode": "clearAll" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    // ── from_events_with_policy: AutoRestore ───────────────────────

    #[test]
    fn test_policy_auto_restore_keeps_skills_through_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-2",
                "payload": { "skillName": "code", "source": "project" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(tracker.has_skill("browser"));
        assert!(tracker.has_skill("code"));
        assert_eq!(tracker.count(), 2);
    }

    #[test]
    fn test_policy_auto_restore_clears_pending_removals_on_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "a" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(tracker.pending_removal_notices().is_empty());
    }

    #[test]
    fn test_policy_auto_restore_clears_removed_names_on_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "a" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(tracker.removed_skill_names().is_empty());
    }

    #[test]
    fn test_policy_auto_restore_deactivated_before_boundary_stays_gone() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "a" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(!tracker.has_skill("a"));
    }

    #[test]
    fn test_policy_auto_restore_multiple_boundaries() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "b", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-4",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(tracker.has_skill("a"));
        assert!(tracker.has_skill("b"));
        assert_eq!(tracker.count(), 2);
    }

    #[test]
    fn test_policy_auto_restore_post_boundary_deactivation() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-3",
                "payload": { "skillName": "a" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(!tracker.has_skill("a"));
        assert!(tracker.removed_skill_names().contains("a"));
    }

    #[test]
    fn test_policy_auto_restore_cleared_at_boundary_is_empty() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    // ── from_events_with_policy: AskUser ───────────────────────────

    #[test]
    fn test_policy_ask_user_clears_skills_on_boundary() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert_eq!(tracker.count(), 0);
    }

    #[test]
    fn test_policy_ask_user_records_cleared_names() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-2",
                "payload": { "skillName": "code", "source": "project" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        let mut cleared = tracker.cleared_at_boundary().to_vec();
        cleared.sort();
        assert_eq!(cleared, vec!["browser", "code"]);
    }

    #[test]
    fn test_policy_ask_user_empty_skills_no_cleared_names() {
        let events = vec![serde_json::json!({
            "type": "compact.boundary",
            "id": "evt-1",
            "payload": {}
        })];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    #[test]
    fn test_policy_ask_user_deactivated_before_boundary_not_in_cleared() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "a" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    #[test]
    fn test_policy_ask_user_multiple_boundaries_resets_cleared() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "b", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-4",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert_eq!(tracker.cleared_at_boundary(), &["b"]);
    }

    // ── from_events_with_policy: context.cleared is unconditional ──

    #[test]
    fn test_policy_auto_restore_context_cleared_always_clears() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "context.cleared",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert_eq!(tracker.count(), 0);
    }

    #[test]
    fn test_policy_ask_user_context_cleared_no_cleared_names() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "context.cleared",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert_eq!(tracker.count(), 0);
        assert!(tracker.cleared_at_boundary().is_empty());
    }

    // ── from_events_with_policy: skills_cleared_by_compaction ──────

    #[test]
    fn test_cleared_by_compaction_clear_all_with_active_skills() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_clear_all_no_active_skills() {
        let events = vec![serde_json::json!({
            "type": "compact.boundary",
            "id": "evt-1",
            "payload": {}
        })];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(!tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_auto_restore_does_not_set() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AutoRestore,
        );
        assert!(!tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_ask_user_with_active_skills() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert!(tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_reset_on_activation() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-3",
                "payload": { "skillName": "code", "source": "global" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(!tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_context_cleared_does_not_set() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "context.cleared",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        // context.cleared calls clear() which sets flag to false
        assert!(!tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_multiple_boundaries_last_counts() {
        // First boundary clears skills (flag=true), second boundary has no skills (flag=false)
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        // Second boundary had no skills to clear
        assert!(!tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_persists_across_turns() {
        // Flag stays true when no new skill.activated events arrive
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skills.cleared",
                "id": "evt-3",
                "payload": { "clearedSkills": ["browser"], "reason": "compaction" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        // skills.cleared resets cleared_at_boundary but NOT skills_cleared_by_compaction
        assert!(tracker.skills_cleared_by_compaction());
    }

    #[test]
    fn test_cleared_by_compaction_deactivated_before_boundary() {
        // Skill deactivated before boundary: boundary has no active skills
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global" }
            }),
            serde_json::json!({
                "type": "skill.deactivated",
                "id": "evt-2",
                "payload": { "skillName": "browser" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-3",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::ClearAll,
        );
        assert!(!tracker.skills_cleared_by_compaction());
    }

    // ── from_events_with_policy: skills.cleared suppression ────────

    #[test]
    fn test_policy_ask_user_skills_cleared_event_suppresses_repeat() {
        let events = vec![
            serde_json::json!({
                "type": "skill.activated",
                "id": "evt-1",
                "payload": { "skillName": "a", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
            serde_json::json!({
                "type": "skills.cleared",
                "id": "evt-3",
                "payload": { "clearedSkills": ["a"], "reason": "compaction" }
            }),
        ];
        let tracker = SkillTracker::from_events_with_policy(
            &events,
            &crate::domains::settings::types::CompactionPolicy::AskUser,
        );
        assert!(tracker.cleared_at_boundary().is_empty());
    }
}
