//! Memory retention settings.

use serde::{Deserialize, Serialize};

/// Memory retention settings.
///
/// Controls the retain system's auto-trigger interval and which model
/// is used for the summarizer subagent.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MemorySettings {
    /// Turns between automatic retain. 0 = disabled.
    pub auto_retain_interval: u32,
    /// Model for retain summarizer subagent.
    pub retain_model: String,
}

impl Default for MemorySettings {
    fn default() -> Self {
        Self {
            auto_retain_interval: 10,
            retain_model: "claude-sonnet-4-6".to_string(),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_settings_defaults() {
        let s = MemorySettings::default();
        assert_eq!(s.auto_retain_interval, 10);
        assert_eq!(s.retain_model, "claude-sonnet-4-6");
    }

    #[test]
    fn memory_settings_serde_roundtrip() {
        let json = serde_json::json!({"autoRetainInterval": 20, "retainModel": "claude-haiku-4-5-20251001"});
        let s: MemorySettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.auto_retain_interval, 20);
        assert_eq!(s.retain_model, "claude-haiku-4-5-20251001");

        let roundtrip = serde_json::to_value(&s).unwrap();
        assert_eq!(roundtrip.get("autoRetainInterval").unwrap(), 20);
        assert_eq!(roundtrip.get("retainModel").unwrap(), "claude-haiku-4-5-20251001");
    }

    #[test]
    fn memory_settings_zero_disables() {
        let json = serde_json::json!({"autoRetainInterval": 0});
        let s: MemorySettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.auto_retain_interval, 0);
    }

    #[test]
    fn memory_settings_partial_json_uses_defaults() {
        let s: MemorySettings = serde_json::from_str("{}").unwrap();
        assert_eq!(s.auto_retain_interval, 10);
        assert_eq!(s.retain_model, "claude-sonnet-4-6");
    }

    #[test]
    fn memory_settings_camel_case_serialization() {
        let s = MemorySettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("autoRetainInterval").is_some());
        assert!(json.get("retainModel").is_some());
    }
}
