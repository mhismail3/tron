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
/// Serializes as camelCase (`"clearAll"` / `"askUser"`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SkillsClearedMode {
    /// Informational notice only — matches `CompactionPolicy::ClearAll`.
    ClearAll,
    /// Interactive re-activation picker — matches `CompactionPolicy::AskUser`.
    AskUser,
}

/// Payload for `skills.cleared` events.
///
/// Emitted by [`prepare_skill_context_from_session`] on the first prompt after
/// a `compact.boundary` under either `ClearAll` or `AskUser` compaction policy.
/// The server-side bookkeeping is identical for both policies; the `mode` field
/// discriminates the iOS render (informational vs interactive).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillsClearedPayload {
    /// Names of skills that were cleared.
    pub cleared_skills: Vec<String>,
    /// Reason for clearing: "compaction".
    pub reason: String,
    /// Render mode — controls whether iOS shows a notice (`ClearAll`) or an
    /// interactive re-activation picker (`AskUser`). Required on the wire.
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
    fn skills_cleared_payload_missing_mode_is_rejected() {
        // Strict wire contract: `mode` is required. A payload without it
        // must fail to deserialize so iOS cannot silently render a
        // mis-classified event.
        let missing_mode = serde_json::json!({
            "clearedSkills": ["x"],
            "reason": "compaction",
        });
        let err = serde_json::from_value::<SkillsClearedPayload>(missing_mode).unwrap_err();
        assert!(
            err.to_string().contains("mode"),
            "expected error naming `mode` field, got: {err}"
        );
    }

    #[test]
    fn skills_cleared_payload_missing_reason_is_rejected() {
        // Strict wire contract: `reason` is required.
        let missing_reason = serde_json::json!({
            "clearedSkills": ["x"],
            "mode": "askUser",
        });
        let err = serde_json::from_value::<SkillsClearedPayload>(missing_reason).unwrap_err();
        assert!(
            err.to_string().contains("reason"),
            "expected error naming `reason` field, got: {err}"
        );
    }

    #[test]
    fn skills_cleared_mode_rejects_unknown_variant() {
        // Defense: serde's camelCase matching rejects unknown mode strings.
        let bad = serde_json::json!({
            "clearedSkills": [],
            "reason": "compaction",
            "mode": "someInvalid",
        });
        assert!(serde_json::from_value::<SkillsClearedPayload>(bad).is_err());
    }

    #[test]
    fn skills_cleared_payload_rejects_unknown_fields() {
        // `deny_unknown_fields` guards the schema against drift.
        let bad = serde_json::json!({
            "clearedSkills": [],
            "reason": "compaction",
            "mode": "askUser",
            "future": "value",
        });
        assert!(serde_json::from_value::<SkillsClearedPayload>(bad).is_err());
    }
}
