//! iOS integration settings.
//!
//! Controls device-side features: context injection, clipboard, haptics,
//! calendar, contacts, health, and location. All default to `enabled: false`
//! (opt-in). Sub-toggles default to `true` when the parent is enabled.

use serde::{Deserialize, Serialize};

/// Root container for all iOS integration settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IntegrationSettings {
    /// Device context signals injected into system prompt.
    pub device_context: DeviceContextSettings,
    /// Clipboard write access.
    pub clipboard: ClipboardSettings,
    /// Haptic feedback on events.
    pub haptics: HapticsSettings,
    /// Calendar read/write access.
    pub calendar: CalendarSettings,
    /// Contact search access.
    pub contacts: ContactsSettings,
    /// HealthKit read access.
    pub health: HealthSettings,
    /// Location awareness (enriches DeviceContext).
    pub location: LocationSettings,
}

impl Default for IntegrationSettings {
    fn default() -> Self {
        Self {
            device_context: DeviceContextSettings::default(),
            clipboard: ClipboardSettings::default(),
            haptics: HapticsSettings::default(),
            calendar: CalendarSettings::default(),
            contacts: ContactsSettings::default(),
            health: HealthSettings::default(),
            location: LocationSettings::default(),
        }
    }
}

/// Device context signals piggybacked on agent prompts.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DeviceContextSettings {
    pub enabled: bool,
    pub battery: bool,
    pub network: bool,
    pub audio_route: bool,
    pub display: bool,
    pub activity: bool,
    pub calendar_preview: bool,
}

impl Default for DeviceContextSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            battery: true,
            network: true,
            audio_route: true,
            display: true,
            activity: false,
            calendar_preview: false,
        }
    }
}

/// Clipboard write access.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClipboardSettings {
    pub enabled: bool,
}

impl Default for ClipboardSettings {
    fn default() -> Self {
        Self { enabled: false }
    }
}

/// Haptic feedback on agent events.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HapticsSettings {
    pub enabled: bool,
    pub on_task_complete: bool,
    pub on_error: bool,
    pub on_notification: bool,
}

impl Default for HapticsSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            on_task_complete: true,
            on_error: true,
            on_notification: true,
        }
    }
}

/// Calendar read/write access via EventKit.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CalendarSettings {
    pub enabled: bool,
    pub allow_write: bool,
}

impl Default for CalendarSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            allow_write: false,
        }
    }
}

/// Contact search access via Contacts framework.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ContactsSettings {
    pub enabled: bool,
}

impl Default for ContactsSettings {
    fn default() -> Self {
        Self { enabled: false }
    }
}

/// HealthKit read access.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HealthSettings {
    pub enabled: bool,
    pub data_types: Vec<String>,
}

impl Default for HealthSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            data_types: vec![
                "steps".into(),
                "sleep".into(),
                "heartRate".into(),
                "workouts".into(),
            ],
        }
    }
}

/// Location awareness (enriches DeviceContext).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LocationSettings {
    pub enabled: bool,
    /// `"city"` (reverse geocoded) or `"coordinates"`.
    pub precision: String,
}

impl Default for LocationSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            precision: "city".into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_all_disabled() {
        let s = IntegrationSettings::default();
        assert!(!s.device_context.enabled);
        assert!(!s.clipboard.enabled);
        assert!(!s.haptics.enabled);
        assert!(!s.calendar.enabled);
        assert!(!s.contacts.enabled);
        assert!(!s.health.enabled);
        assert!(!s.location.enabled);
    }

    #[test]
    fn sub_toggles_default_true() {
        let s = IntegrationSettings::default();
        assert!(s.device_context.battery);
        assert!(s.device_context.network);
        assert!(s.haptics.on_task_complete);
        assert!(s.haptics.on_error);
    }

    #[test]
    fn serde_roundtrip() {
        let s = IntegrationSettings::default();
        let json = serde_json::to_string(&s).unwrap();
        let back: IntegrationSettings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.device_context.enabled, s.device_context.enabled);
        assert_eq!(back.health.data_types, s.health.data_types);
        assert_eq!(back.location.precision, s.location.precision);
    }

    #[test]
    fn partial_json_override() {
        let json = serde_json::json!({
            "clipboard": { "enabled": true },
            "haptics": { "enabled": true, "onError": false }
        });
        let s: IntegrationSettings = serde_json::from_value(json).unwrap();
        assert!(s.clipboard.enabled);
        assert!(s.haptics.enabled);
        assert!(!s.haptics.on_error);
        assert!(s.haptics.on_task_complete); // default preserved
        assert!(!s.calendar.enabled); // default preserved
    }

    #[test]
    fn empty_json_produces_defaults() {
        let s: IntegrationSettings = serde_json::from_str("{}").unwrap();
        assert!(!s.device_context.enabled);
        assert_eq!(s.location.precision, "city");
        assert_eq!(s.health.data_types.len(), 4);
    }

    #[test]
    fn camel_case_field_names() {
        let s = IntegrationSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        let dc = json.get("deviceContext").unwrap();
        assert!(dc.get("audioRoute").is_some());
        assert!(dc.get("calendarPreview").is_some());
        let h = json.get("haptics").unwrap();
        assert!(h.get("onTaskComplete").is_some());
        assert!(h.get("onError").is_some());
        let cal = json.get("calendar").unwrap();
        assert!(cal.get("allowWrite").is_some());
        let health = json.get("health").unwrap();
        assert!(health.get("dataTypes").is_some());
    }

    #[test]
    fn health_custom_data_types() {
        let json = serde_json::json!({
            "health": {
                "enabled": true,
                "dataTypes": ["steps", "heartRate"]
            }
        });
        let s: IntegrationSettings = serde_json::from_value(json).unwrap();
        assert!(s.health.enabled);
        assert_eq!(s.health.data_types, vec!["steps", "heartRate"]);
    }

    #[test]
    fn location_precision_coordinates() {
        let json = serde_json::json!({
            "location": {
                "enabled": true,
                "precision": "coordinates"
            }
        });
        let s: IntegrationSettings = serde_json::from_value(json).unwrap();
        assert!(s.location.enabled);
        assert_eq!(s.location.precision, "coordinates");
    }

    #[test]
    fn calendar_allow_write_default_false() {
        let s = CalendarSettings::default();
        assert!(!s.allow_write);
    }
}
