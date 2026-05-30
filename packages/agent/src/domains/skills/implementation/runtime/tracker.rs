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
#[path = "tracker/tests.rs"]
mod tests;
