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

/// Mode of a `skills.cleared` event — controls the iOS render.
///
/// - [`ClearAll`](Self::ClearAll): informational banner showing the cleared
///   skill names. Users can re-activate manually via `@skill-name` mention
///   (or the sidebar picker) if desired.
/// - [`AskUser`](Self::AskUser): interactive picker chips; tapping a chip
///   calls the `skill.activate` RPC to re-add that skill to the session.
///
/// Serializes as camelCase (`"clearAll"` / `"askUser"`). Defaults to `AskUser`
/// on deserialization so on-disk events written before M6 (which only emitted
/// under `AskUser` and had no mode field) continue to parse with correct
/// semantics — see [`SkillsClearedPayload::mode`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SkillsClearedMode {
    /// Informational notice only — matches `CompactionPolicy::ClearAll`.
    ClearAll,
    /// Interactive re-activation picker — matches `CompactionPolicy::AskUser`.
    AskUser,
}

impl Default for SkillsClearedMode {
    fn default() -> Self {
        // Back-compat: pre-M6 events only existed under AskUser policy and
        // lacked this field. Defaulting to AskUser preserves their semantics.
        Self::AskUser
    }
}

/// Payload for `skills.cleared` events.
///
/// Emitted by [`prepare_skill_context_from_session`] on the first prompt after
/// a `compact.boundary` under either `ClearAll` or `AskUser` compaction policy.
/// The server-side bookkeeping is identical for both policies; the `mode` field
/// discriminates the iOS render (informational vs interactive).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillsClearedPayload {
    /// Names of skills that were cleared.
    pub cleared_skills: Vec<String>,
    /// Reason for clearing: "compaction".
    pub reason: String,
    /// Render mode — controls whether iOS shows a notice (`ClearAll`) or an
    /// interactive re-activation picker (`AskUser`).
    ///
    /// `#[serde(default)]` ensures pre-M6 events (which lacked this field and
    /// were only ever emitted under AskUser) continue to deserialize with the
    /// correct default.
    #[serde(default)]
    pub mode: SkillsClearedMode,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skills_cleared_payload_round_trip_clear_all() {
        let p = SkillsClearedPayload {
            cleared_skills: vec!["browser".into(), "code".into()],
            reason: "compaction".into(),
            mode: SkillsClearedMode::ClearAll,
        };
        let json = serde_json::to_value(&p).unwrap();
        assert_eq!(json["mode"], "clearAll");
        let back: SkillsClearedPayload = serde_json::from_value(json).unwrap();
        assert_eq!(back, p);
    }

    #[test]
    fn skills_cleared_payload_round_trip_ask_user() {
        let p = SkillsClearedPayload {
            cleared_skills: vec!["a".into()],
            reason: "compaction".into(),
            mode: SkillsClearedMode::AskUser,
        };
        let json = serde_json::to_value(&p).unwrap();
        assert_eq!(json["mode"], "askUser");
        let back: SkillsClearedPayload = serde_json::from_value(json).unwrap();
        assert_eq!(back, p);
    }

    #[test]
    fn skills_cleared_payload_missing_mode_defaults_to_ask_user() {
        // M6 back-compat: pre-M6 events lacked the `mode` field. Decoding must
        // still succeed and default to AskUser, which was the only mode that
        // emitted events before this change.
        let legacy_json = serde_json::json!({
            "clearedSkills": ["x"],
            "reason": "compaction",
        });
        let back: SkillsClearedPayload = serde_json::from_value(legacy_json).unwrap();
        assert_eq!(back.mode, SkillsClearedMode::AskUser);
        assert_eq!(back.cleared_skills, vec!["x".to_string()]);
        assert_eq!(back.reason, "compaction");
    }

    #[test]
    fn skills_cleared_mode_rejects_unknown_variant() {
        // Defense: serde's camelCase matching should reject an unknown mode
        // string rather than silently defaulting. (The default only applies
        // when the field is absent entirely.)
        let bad = serde_json::json!({
            "clearedSkills": [],
            "reason": "compaction",
            "mode": "someInvalid",
        });
        assert!(serde_json::from_value::<SkillsClearedPayload>(bad).is_err());
    }
}
