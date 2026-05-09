//! Skill system settings.
//!
//! Controls how skills behave during compaction and whether the skill
//! index is included in the system prompt.

use serde::{Deserialize, Serialize};

/// What happens to active skills when context compaction occurs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompactionPolicy {
    /// All active skills are cleared on compaction. User must re-activate.
    #[default]
    ClearAll,
    /// Active skills survive compaction and are automatically re-injected.
    AutoRestore,
    /// Skills are cleared, but a `skills.cleared` event is emitted so the
    /// client can prompt the user to re-activate.
    AskUser,
}

/// When to include the lightweight skill index in the system prompt.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShowIndex {
    /// Always include the index listing all available skills.
    #[default]
    Always,
    /// Never include the skill index.
    Never,
    /// Include the index only when no skills are currently active.
    WhenNoActiveSkills,
}

/// Skill system configuration.
///
/// Controls compaction behavior and skill index visibility.
///
/// # JSON Example
///
/// ```json
/// {
///   "compactionPolicy": "clearAll",
///   "showIndex": "always"
/// }
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SkillsSettings {
    /// What happens to active skills on compaction.
    pub compaction_policy: CompactionPolicy,
    /// When to include the skill index in the system prompt.
    pub show_index: ShowIndex,
}

impl Default for SkillsSettings {
    fn default() -> Self {
        Self {
            compaction_policy: CompactionPolicy::ClearAll,
            show_index: ShowIndex::Always,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skills_settings_defaults() {
        let s = SkillsSettings::default();
        assert_eq!(s.compaction_policy, CompactionPolicy::ClearAll);
        assert_eq!(s.show_index, ShowIndex::Always);
    }

    #[test]
    fn compaction_policy_serde_roundtrip() {
        for variant in [
            CompactionPolicy::ClearAll,
            CompactionPolicy::AutoRestore,
            CompactionPolicy::AskUser,
        ] {
            let json = serde_json::to_value(&variant).unwrap();
            let back: CompactionPolicy = serde_json::from_value(json).unwrap();
            assert_eq!(variant, back);
        }
    }

    #[test]
    fn show_index_serde_roundtrip() {
        for variant in [
            ShowIndex::Always,
            ShowIndex::Never,
            ShowIndex::WhenNoActiveSkills,
        ] {
            let json = serde_json::to_value(&variant).unwrap();
            let back: ShowIndex = serde_json::from_value(json).unwrap();
            assert_eq!(variant, back);
        }
    }

    #[test]
    fn partial_json_uses_defaults() {
        let json = serde_json::json!({});
        let s: SkillsSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.compaction_policy, CompactionPolicy::ClearAll);
        assert_eq!(s.show_index, ShowIndex::Always);
    }

    #[test]
    fn partial_json_overrides_one_field() {
        let json = serde_json::json!({ "compactionPolicy": "autoRestore" });
        let s: SkillsSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.compaction_policy, CompactionPolicy::AutoRestore);
        assert_eq!(s.show_index, ShowIndex::Always);
    }

    #[test]
    fn camel_case_serialization() {
        let s = SkillsSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("compactionPolicy").is_some());
        assert!(json.get("showIndex").is_some());
        // No snake_case keys
        assert!(json.get("compaction_policy").is_none());
        assert!(json.get("show_index").is_none());
    }

    #[test]
    fn compaction_policy_json_values() {
        assert_eq!(
            serde_json::to_value(CompactionPolicy::ClearAll).unwrap(),
            "clearAll"
        );
        assert_eq!(
            serde_json::to_value(CompactionPolicy::AutoRestore).unwrap(),
            "autoRestore"
        );
        assert_eq!(
            serde_json::to_value(CompactionPolicy::AskUser).unwrap(),
            "askUser"
        );
    }

    #[test]
    fn show_index_json_values() {
        assert_eq!(serde_json::to_value(ShowIndex::Always).unwrap(), "always");
        assert_eq!(serde_json::to_value(ShowIndex::Never).unwrap(), "never");
        assert_eq!(
            serde_json::to_value(ShowIndex::WhenNoActiveSkills).unwrap(),
            "whenNoActiveSkills"
        );
    }

    #[test]
    fn full_settings_roundtrip() {
        let s = SkillsSettings {
            compaction_policy: CompactionPolicy::AskUser,
            show_index: ShowIndex::WhenNoActiveSkills,
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: SkillsSettings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.compaction_policy, CompactionPolicy::AskUser);
        assert_eq!(back.show_index, ShowIndex::WhenNoActiveSkills);
    }
}
