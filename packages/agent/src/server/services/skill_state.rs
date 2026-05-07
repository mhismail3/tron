//! Session-scoped skill state.
//!
//! Canonical `skills::*` engine functions and prompt assembly share this
//! event-sourced reconstruction helper.

use serde_json::Value;

use crate::skills::tracker::SkillTracker;

/// Reconstruct a [`SkillTracker`] from the event store for a given session.
pub fn reconstruct_tracker(
    event_store: &crate::events::EventStore,
    session_id: &str,
    policy: &crate::settings::types::CompactionPolicy,
) -> SkillTracker {
    let events = event_store
        .get_events_by_type(
            session_id,
            &[
                "skill.activated",
                "skill.deactivated",
                "context.cleared",
                "compact.boundary",
                "skills.cleared",
            ],
            None,
        )
        .unwrap_or_default();
    let json_events: Vec<Value> = events
        .iter()
        .filter_map(
            |event| match serde_json::from_str::<Value>(&event.payload) {
                Ok(payload) => Some(serde_json::json!({
                    "type": event.event_type,
                    "id": event.id,
                    "payload": payload,
                })),
                Err(error) => {
                    tracing::warn!(
                        event_id = %event.id,
                        event_type = %event.event_type,
                        error = %error,
                        "skill_session: corrupt event payload JSON; dropping from skill tracker"
                    );
                    None
                }
            },
        )
        .collect();
    SkillTracker::from_events_with_policy(&json_events, policy)
}
