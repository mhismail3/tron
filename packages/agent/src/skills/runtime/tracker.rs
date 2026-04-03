//! Per-session skill tracker.
//!
//! Tracks which skills are active in a session, which have been deactivated
//! (for removal notice generation), and which spells are pending consumption.
//! State is reconstructed from events via [`SkillTracker::from_events`].
//!
//! ## Event types handled
//!
//! - `skill.activated` — adds skill to active set
//! - `skill.deactivated` — removes skill, adds to pending removal notices
//! - `spell.cast` — queues spell for next prompt
//! - `spell.consumed` — marks a queued spell as consumed
//! - `compact.boundary` / `context.cleared` — clears all state (respects compaction policy externally)

use std::collections::{HashMap, HashSet};

use crate::skills::types::{AddedSkillInfo, SkillAddMethod, SkillSource};

/// Internal tracking information for an added skill.
#[derive(Debug, Clone)]
struct TrackedSkill {
    source: SkillSource,
    added_via: SkillAddMethod,
    event_id: Option<String>,
    content_length: Option<usize>,
}

/// A pending spell awaiting consumption by the next prompt.
#[derive(Debug, Clone)]
pub struct PendingSpell {
    /// Event ID of the `spell.cast` event.
    pub event_id: String,
    /// Spell name.
    pub name: String,
    /// Source: global or project.
    pub source: SkillSource,
}

/// Per-session tracker of active skills, pending spells, and removal notices.
///
/// Maintains the set of currently active skills, skills pending removal notice,
/// and spells awaiting consumption. Supports event-sourced reconstruction.
#[derive(Debug)]
pub struct SkillTracker {
    /// Currently active skills.
    added_skills: HashMap<String, TrackedSkill>,
    /// Skills deactivated since the last prompt (for "stop following" notice).
    /// Cleared after the first prompt that includes the removal notice.
    pending_removal_notices: HashSet<String>,
    /// Skills that were explicitly removed during this session (superset of pending).
    removed_skill_names: HashSet<String>,
    /// Spells cast but not yet consumed by a prompt.
    pending_spells: Vec<PendingSpell>,
}

impl SkillTracker {
    /// Create a new empty skill tracker.
    pub fn new() -> Self {
        Self {
            added_skills: HashMap::new(),
            pending_removal_notices: HashSet::new(),
            removed_skill_names: HashSet::new(),
            pending_spells: Vec::new(),
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

    /// Record that an ephemeral spell was cast.
    pub fn add_spell(&mut self, event_id: String, name: String, source: SkillSource) {
        // Avoid duplicates by event_id
        if !self.pending_spells.iter().any(|s| s.event_id == event_id) {
            self.pending_spells.push(PendingSpell {
                event_id,
                name,
                source,
            });
        }
    }

    /// Mark a spell as consumed by a prompt.
    pub fn consume_spell(&mut self, cast_event_id: &str) {
        self.pending_spells
            .retain(|s| s.event_id != cast_event_id);
    }

    /// Get spells that have been cast but not yet consumed.
    pub fn unconsumed_spells(&self) -> &[PendingSpell] {
        &self.pending_spells
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
        self.pending_spells.clear();
    }

    /// Reconstruct tracker state from a sequence of session events.
    ///
    /// Processes events in order, handling:
    /// `skill.activated`, `skill.deactivated`, `spell.cast`, `spell.consumed`,
    /// `compact.boundary`, `context.cleared`.
    ///
    /// Events before the last `compact.boundary` or `context.cleared` are discarded
    /// (the caller controls whether compaction clears skills via the compaction policy setting).
    pub fn from_events(events: &[serde_json::Value]) -> Self {
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
                // Spell cast: queue for next prompt
                "spell.cast" => {
                    if let Some(payload) = event.get("payload") {
                        let name = payload
                            .get("spellName")
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
                        if !name.is_empty() {
                            if let Some(eid) = &event_id {
                                tracker.add_spell(eid.clone(), name, source);
                            }
                        }
                    }
                }
                // Spell consumed: remove from pending
                "spell.consumed" => {
                    if let Some(payload) = event.get("payload") {
                        let cast_id = payload
                            .get("castEventId")
                            .and_then(|id| id.as_str())
                            .unwrap_or_default();
                        if !cast_id.is_empty() {
                            tracker.consume_spell(cast_id);
                        }
                    }
                }
                // Compaction / context clear: reset all state
                "context.cleared" | "compact.boundary" => {
                    tracker.clear();
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
        tracker.add_spell(
            "evt-1".to_string(),
            "spell1".to_string(),
            SkillSource::Global,
        );
        tracker.clear();
        assert_eq!(tracker.count(), 0);
        assert!(tracker.removed_skill_names().is_empty());
        assert!(tracker.unconsumed_spells().is_empty());
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

    // ── Spell tracking ──────────────────────────────────────────────

    #[test]
    fn test_add_spell() {
        let mut tracker = SkillTracker::new();
        tracker.add_spell(
            "evt-1".to_string(),
            "commit".to_string(),
            SkillSource::Global,
        );
        assert_eq!(tracker.unconsumed_spells().len(), 1);
        assert_eq!(tracker.unconsumed_spells()[0].name, "commit");
    }

    #[test]
    fn test_add_spell_dedup_by_event_id() {
        let mut tracker = SkillTracker::new();
        tracker.add_spell(
            "evt-1".to_string(),
            "commit".to_string(),
            SkillSource::Global,
        );
        tracker.add_spell(
            "evt-1".to_string(),
            "commit".to_string(),
            SkillSource::Global,
        );
        assert_eq!(tracker.unconsumed_spells().len(), 1);
    }

    #[test]
    fn test_consume_spell() {
        let mut tracker = SkillTracker::new();
        tracker.add_spell(
            "evt-1".to_string(),
            "commit".to_string(),
            SkillSource::Global,
        );
        tracker.add_spell(
            "evt-2".to_string(),
            "review".to_string(),
            SkillSource::Global,
        );
        tracker.consume_spell("evt-1");
        assert_eq!(tracker.unconsumed_spells().len(), 1);
        assert_eq!(tracker.unconsumed_spells()[0].name, "review");
    }

    #[test]
    fn test_consume_spell_nonexistent_noop() {
        let mut tracker = SkillTracker::new();
        tracker.add_spell(
            "evt-1".to_string(),
            "commit".to_string(),
            SkillSource::Global,
        );
        tracker.consume_spell("evt-999");
        assert_eq!(tracker.unconsumed_spells().len(), 1);
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
        let tracker = SkillTracker::from_events(&[]);
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
        let tracker = SkillTracker::from_events(&events);
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
        let tracker = SkillTracker::from_events(&events);
        assert!(!tracker.has_skill("browser"));
        assert!(tracker.removed_skill_names().contains("browser"));
        assert!(tracker.pending_removal_notices().contains("browser"));
    }

    #[test]
    fn test_from_events_spell_cast_tracked() {
        let events = vec![serde_json::json!({
            "type": "spell.cast",
            "id": "evt-1",
            "payload": {
                "spellName": "commit",
                "source": "global"
            }
        })];
        let tracker = SkillTracker::from_events(&events);
        assert_eq!(tracker.unconsumed_spells().len(), 1);
        assert_eq!(tracker.unconsumed_spells()[0].name, "commit");
        assert_eq!(tracker.unconsumed_spells()[0].event_id, "evt-1");
    }

    #[test]
    fn test_from_events_spell_consumed_tracking() {
        let events = vec![
            serde_json::json!({
                "type": "spell.cast",
                "id": "evt-1",
                "payload": { "spellName": "commit", "source": "global" }
            }),
            serde_json::json!({
                "type": "spell.consumed",
                "id": "evt-2",
                "payload": { "spellName": "commit", "castEventId": "evt-1" }
            }),
        ];
        let tracker = SkillTracker::from_events(&events);
        assert!(tracker.unconsumed_spells().is_empty());
    }

    #[test]
    fn test_from_events_unconsumed_spells() {
        let events = vec![
            serde_json::json!({
                "type": "spell.cast",
                "id": "evt-1",
                "payload": { "spellName": "commit", "source": "global" }
            }),
            serde_json::json!({
                "type": "spell.cast",
                "id": "evt-2",
                "payload": { "spellName": "review", "source": "project" }
            }),
            serde_json::json!({
                "type": "spell.consumed",
                "id": "evt-3",
                "payload": { "spellName": "commit", "castEventId": "evt-1" }
            }),
        ];
        let tracker = SkillTracker::from_events(&events);
        let unconsumed = tracker.unconsumed_spells();
        assert_eq!(unconsumed.len(), 1);
        assert_eq!(unconsumed[0].name, "review");
        assert_eq!(unconsumed[0].source, SkillSource::Project);
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
        let tracker = SkillTracker::from_events(&events);
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
        let tracker = SkillTracker::from_events(&events);
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
        let tracker = SkillTracker::from_events(&events);
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
        let tracker = SkillTracker::from_events(&events);
        assert!(tracker.has_skill("browser"));
        assert_eq!(tracker.count(), 1);
    }

    #[test]
    fn test_from_events_compaction_clears_spells() {
        let events = vec![
            serde_json::json!({
                "type": "spell.cast",
                "id": "evt-1",
                "payload": { "spellName": "commit", "source": "global" }
            }),
            serde_json::json!({
                "type": "compact.boundary",
                "id": "evt-2",
                "payload": {}
            }),
        ];
        let tracker = SkillTracker::from_events(&events);
        assert!(tracker.unconsumed_spells().is_empty());
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
        let tracker = SkillTracker::from_events(&events);
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
        let tracker = SkillTracker::from_events(&events);
        assert_eq!(tracker.count(), 1); // Idempotent
    }

    #[test]
    fn test_from_events_project_source() {
        let events = vec![serde_json::json!({
            "type": "skill.activated",
            "id": "evt-1",
            "payload": { "skillName": "tool", "source": "project" }
        })];
        let tracker = SkillTracker::from_events(&events);
        let skills = tracker.added_skills();
        assert_eq!(skills[0].source, SkillSource::Project);
        assert_eq!(skills[0].added_via, SkillAddMethod::Explicit);
    }

}
