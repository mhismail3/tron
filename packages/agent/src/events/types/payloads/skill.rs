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

/// Payload for `skills.cleared` events (emitted on compaction with `askUser` policy).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillsClearedPayload {
    /// Names of skills that were cleared.
    pub cleared_skills: Vec<String>,
    /// Reason for clearing: "compaction".
    pub reason: String,
}
