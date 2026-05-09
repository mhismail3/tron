//! Prompt Library settings.
//!
//! Controls auto-capture of prompt history + retention policy.

use serde::{Deserialize, Serialize};

/// Prompt Library configuration.
///
/// - `history_enabled`: globally toggle the auto-capture hook. Defaults `true`.
/// - `history_max_entries`: soft cap on total rows (oldest-first prune). `0` = unlimited.
/// - `history_max_age_days`: time-based prune cutoff. `0` = no age limit.
/// - `history_auto_prune`: run prune opportunistically on server start. Defaults `true`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PromptLibrarySettings {
    /// Whether to auto-capture interactive prompts to history.
    pub history_enabled: bool,
    /// Maximum history rows retained. `0` = unlimited.
    pub history_max_entries: u32,
    /// Maximum history age in days. `0` = no age limit.
    pub history_max_age_days: u32,
    /// Run prune opportunistically on startup.
    pub history_auto_prune: bool,
}

impl Default for PromptLibrarySettings {
    fn default() -> Self {
        Self {
            history_enabled: true,
            history_max_entries: 10_000,
            history_max_age_days: 0,
            history_auto_prune: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_spec() {
        let s = PromptLibrarySettings::default();
        assert!(s.history_enabled);
        assert_eq!(s.history_max_entries, 10_000);
        assert_eq!(s.history_max_age_days, 0);
        assert!(s.history_auto_prune);
    }

    #[test]
    fn serde_roundtrip() {
        let json = serde_json::json!({
            "historyEnabled": false,
            "historyMaxEntries": 500,
            "historyMaxAgeDays": 30,
            "historyAutoPrune": false
        });
        let s: PromptLibrarySettings = serde_json::from_value(json).unwrap();
        assert!(!s.history_enabled);
        assert_eq!(s.history_max_entries, 500);
        assert_eq!(s.history_max_age_days, 30);
        assert!(!s.history_auto_prune);

        let back = serde_json::to_value(&s).unwrap();
        assert_eq!(back["historyEnabled"], false);
        assert_eq!(back["historyMaxEntries"], 500);
        assert_eq!(back["historyMaxAgeDays"], 30);
        assert_eq!(back["historyAutoPrune"], false);
    }

    #[test]
    fn partial_json_uses_defaults() {
        let s: PromptLibrarySettings = serde_json::from_str("{}").unwrap();
        let d = PromptLibrarySettings::default();
        assert_eq!(s.history_enabled, d.history_enabled);
        assert_eq!(s.history_max_entries, d.history_max_entries);
        assert_eq!(s.history_max_age_days, d.history_max_age_days);
        assert_eq!(s.history_auto_prune, d.history_auto_prune);
    }

    #[test]
    fn camel_case_serialization() {
        let s = PromptLibrarySettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("historyEnabled").is_some());
        assert!(json.get("historyMaxEntries").is_some());
        assert!(json.get("historyMaxAgeDays").is_some());
        assert!(json.get("historyAutoPrune").is_some());
        // not snake_case
        assert!(json.get("history_enabled").is_none());
    }
}
