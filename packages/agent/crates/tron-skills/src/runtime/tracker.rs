//! Per-session skill tracker.
//!
//! Tracks which skills are active in a session, which have been removed,
//! and which spells have been used. State can be reconstructed from events
//! via [`SkillTracker::from_events`].

use std::collections::{HashMap, HashSet};

use crate::types::{AddedSkillInfo, SkillAddMethod, SkillSource};

/// Internal tracking information for an added skill.
#[derive(Debug, Clone)]
struct TrackedSkill {
    source: SkillSource,
    added_via: SkillAddMethod,
    event_id: Option<String>,
    content_length: Option<usize>,
}

/// Per-session tracker of active skills.
///
/// Maintains the set of currently active skills, previously removed skills,
/// and ephemeral spells used. Supports event-sourced reconstruction.
#[derive(Debug)]
pub struct SkillTracker {
    /// Currently active skills.
    added_skills: HashMap<String, TrackedSkill>,
    /// Skills that were explicitly removed (for "stop following" instruction).
    removed_skill_names: HashSet<String>,
    /// Ephemeral spells used this session (tracked for removal on next prompt).
    used_spell_names: Vec<String>,
}

impl SkillTracker {
    /// Create a new empty skill tracker.
    pub fn new() -> Self {
        Self {
            added_skills: HashMap::new(),
            removed_skill_names: HashSet::new(),
            used_spell_names: Vec::new(),
        }
    }

    /// Record a skill as added to the session context.
    ///
    /// If the skill was previously removed, it is removed from the removal list.
    pub fn add_skill(
        &mut self,
        name: String,
        source: SkillSource,
        added_via: SkillAddMethod,
        event_id: Option<String>,
    ) {
        let _ = self.removed_skill_names.remove(&name);
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

    /// Record a skill as removed from the session context.
    ///
    /// Adds to the removed set for "stop following" instruction generation.
    /// Returns `true` if the skill was present, `false` if not found.
    pub fn remove_skill(&mut self, name: &str) -> bool {
        if self.added_skills.remove(name).is_some() {
            let _ = self.removed_skill_names.insert(name.to_string());
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

    /// Get the number of currently active skills.
    pub fn count(&self) -> usize {
        self.added_skills.len()
    }

    /// Get the names of explicitly removed skills.
    pub fn removed_skill_names(&self) -> &HashSet<String> {
        &self.removed_skill_names
    }

    /// Record that an ephemeral spell was used.
    pub fn add_used_spell(&mut self, spell_name: String) {
        if !self.used_spell_names.contains(&spell_name) {
            self.used_spell_names.push(spell_name);
        }
    }

    /// Get names of spells used in this session.
    pub fn used_spell_names(&self) -> &[String] {
        &self.used_spell_names
    }

    /// Clear all tracked state (for context clear/compaction).
    pub fn clear(&mut self) {
        self.added_skills.clear();
        self.removed_skill_names.clear();
        self.used_spell_names.clear();
    }

    /// Reconstruct tracker state from a sequence of session events.
    ///
    /// Processes events in order, handling:
    /// - `skill.added` — adds skill to active set
    /// - `skill.removed` — removes skill, adds to removed set
    /// - `context.cleared` / `compact.boundary` — clears all state
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
                "skill.added" => {
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
                            .unwrap_or("mention")
                        {
                            "explicit" => SkillAddMethod::Explicit,
                            _ => SkillAddMethod::Mention,
                        };

                        if !name.is_empty() {
                            tracker.add_skill(name, source, added_via, event_id);
                        }
                    }
                }
                "skill.removed" => {
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
        tracker.add_used_spell("spell1".to_string());
        tracker.clear();
        assert_eq!(tracker.count(), 0);
        assert!(tracker.removed_skill_names().is_empty());
        assert!(tracker.used_spell_names().is_empty());
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
    fn test_add_used_spell() {
        let mut tracker = SkillTracker::new();
        tracker.add_used_spell("spell1".to_string());
        tracker.add_used_spell("spell2".to_string());
        tracker.add_used_spell("spell1".to_string()); // duplicate
        assert_eq!(tracker.used_spell_names().len(), 2);
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

        tracker.add_skill(
            "a".to_string(),
            SkillSource::Global,
            SkillAddMethod::Mention,
            None,
        );
        assert!(tracker.has_skill("a"));
        assert!(!tracker.removed_skill_names().contains("a"));
    }

    // --- from_events tests ---

    #[test]
    fn test_from_events_empty() {
        let tracker = SkillTracker::from_events(&[]);
        assert_eq!(tracker.count(), 0);
    }

    #[test]
    fn test_from_events_skill_added() {
        let events = vec![serde_json::json!({
            "type": "skill.added",
            "id": "evt-1",
            "payload": {
                "skillName": "browser",
                "source": "global",
                "addedVia": "mention"
            }
        })];
        let tracker = SkillTracker::from_events(&events);
        assert!(tracker.has_skill("browser"));
    }

    #[test]
    fn test_from_events_skill_added_then_removed() {
        let events = vec![
            serde_json::json!({
                "type": "skill.added",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global", "addedVia": "mention" }
            }),
            serde_json::json!({
                "type": "skill.removed",
                "id": "evt-2",
                "payload": { "skillName": "browser", "removedVia": "manual" }
            }),
        ];
        let tracker = SkillTracker::from_events(&events);
        assert!(!tracker.has_skill("browser"));
        assert!(tracker.removed_skill_names().contains("browser"));
    }

    #[test]
    fn test_from_events_context_cleared() {
        let events = vec![
            serde_json::json!({
                "type": "skill.added",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global", "addedVia": "mention" }
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
                "type": "skill.added",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global", "addedVia": "mention" }
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
    fn test_from_events_duplicate_add() {
        let events = vec![
            serde_json::json!({
                "type": "skill.added",
                "id": "evt-1",
                "payload": { "skillName": "browser", "source": "global", "addedVia": "mention" }
            }),
            serde_json::json!({
                "type": "skill.added",
                "id": "evt-2",
                "payload": { "skillName": "browser", "source": "project", "addedVia": "explicit" }
            }),
        ];
        let tracker = SkillTracker::from_events(&events);
        assert_eq!(tracker.count(), 1); // Idempotent
    }

    #[test]
    fn test_from_events_project_source() {
        let events = vec![serde_json::json!({
            "type": "skill.added",
            "id": "evt-1",
            "payload": { "skillName": "tool", "source": "project", "addedVia": "explicit" }
        })];
        let tracker = SkillTracker::from_events(&events);
        let skills = tracker.added_skills();
        assert_eq!(skills[0].source, SkillSource::Project);
        assert_eq!(skills[0].added_via, SkillAddMethod::Explicit);
    }
}
