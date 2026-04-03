//! Skill event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `skill.activated` events (server-owned state).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillActivatedPayload {
    /// Skill name.
    pub skill_name: String,
    /// Source: "global" or "project".
    pub source: String,
}

/// Payload for `skill.deactivated` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillDeactivatedPayload {
    /// Skill name.
    pub skill_name: String,
}

/// Payload for `spell.cast` events (ephemeral, one-shot).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpellCastPayload {
    /// Spell name.
    pub spell_name: String,
    /// Source: "global" or "project".
    pub source: String,
}

/// Payload for `spell.consumed` events (marks a spell.cast as used by a prompt).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpellConsumedPayload {
    /// Spell name.
    pub spell_name: String,
    /// Event ID of the `spell.cast` event that was consumed.
    pub cast_event_id: String,
}

/// Payload for `skills.cleared` events (emitted on compaction with `askUser` policy).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillsClearedPayload {
    /// Names of skills that were cleared.
    pub cleared_skills: Vec<String>,
    /// Reason for clearing: "compaction".
    pub reason: String,
}
