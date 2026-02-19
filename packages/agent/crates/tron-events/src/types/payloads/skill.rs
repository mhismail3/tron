//! Skill event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `skill.added` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillAddedPayload {
    /// Skill name.
    pub skill_name: String,
    /// Source: "global" or "project".
    pub source: String,
    /// How the skill was added: "mention" or "explicit".
    pub added_via: String,
}

/// Payload for `skill.removed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillRemovedPayload {
    /// Skill name.
    pub skill_name: String,
    /// How the skill was removed: "manual", "clear", or "compact".
    pub removed_via: String,
}
