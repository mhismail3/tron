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

// ── Retired spell-event tolerance ────────────────────────────────

#[test]
fn test_from_events_ignores_retired_spell_events() {
    // Post-removal invariant: retired spell.cast / spell.consumed rows in
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
fn test_retired_spell_before_compact_boundary_preserves_flags() {
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
    // Compaction clears `browser`; retired spell events never mattered.
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
        "payload": { "skillName": "project-skill", "source": "project" }
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
