//! iOS integration settings.
//!
//! Controls device-side features: context injection, clipboard, haptics,
//! calendar, contacts, health, and location. All default to `enabled: false`
//! (opt-in). Sub-toggles default to `true` when the parent is enabled.

use serde::{Deserialize, Serialize};

/// Root container for all iOS integration settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
#[derive(Default)]
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
    /// `HealthKit` read access.
    pub health: HealthSettings,
    /// Location awareness (enriches `DeviceContext`).
    pub location: LocationSettings,
}


/// Device context signals piggybacked on agent prompts.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DeviceContextSettings {
    /// Master toggle for device context injection.
    pub enabled: bool,
    /// Include battery level/state.
    pub battery: bool,
    /// Include network type (WiFi/cellular).
    pub network: bool,
    /// Include current audio route.
    pub audio_route: bool,
    /// Include display metrics.
    pub display: bool,
    /// Include motion/activity state.
    pub activity: bool,
    /// Include upcoming calendar events.
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
#[derive(Default)]
pub struct ClipboardSettings {
    /// Master toggle for clipboard write access.
    pub enabled: bool,
}


/// Haptic feedback on agent events.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HapticsSettings {
    /// Master toggle for haptic feedback.
    pub enabled: bool,
    /// Haptic on task completion.
    pub on_task_complete: bool,
    /// Haptic on errors.
    pub on_error: bool,
    /// Haptic on notifications.
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

/// Calendar read/write access via `EventKit`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
#[derive(Default)]
pub struct CalendarSettings {
    /// Master toggle for calendar access.
    pub enabled: bool,
    /// Allow creating/modifying calendar events.
    pub allow_write: bool,
}


/// Contact search access via Contacts framework.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
#[derive(Default)]
pub struct ContactsSettings {
    /// Master toggle for contact search access.
    pub enabled: bool,
}


/// `HealthKit` read access.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HealthSettings {
    /// Master toggle for `HealthKit` read access.
    pub enabled: bool,
    /// Which `HealthKit` data types to expose.
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

/// Location awareness (enriches `DeviceContext`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LocationSettings {
    /// Master toggle for location awareness.
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
