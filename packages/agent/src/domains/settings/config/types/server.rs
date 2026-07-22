//! Server and agent settings.
//!
//! These are grouped here because they are all relatively small and
//! server-oriented.

use serde::{Deserialize, Serialize};

/// Server network and runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ServerSettings {
    /// WebSocket heartbeat interval in milliseconds.
    ///
    /// Must be non-zero before it reaches the runtime because
    /// `tokio::time::interval(Duration::ZERO)` panics.
    pub heartbeat_interval_ms: u64,
    /// Default LLM model identifier.
    pub default_model: String,
    /// Default workspace path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_workspace: Option<String>,
    /// Cached Tailscale IP address. Populated by the Mac wrapper / install
    /// scripts (or manually) so iOS clients can display "your Mac is at
    /// 100.x.y.z" without shelling out to the `tailscale` binary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailscale_ip: Option<String>,
}

impl Default for ServerSettings {
    fn default() -> Self {
        Self {
            heartbeat_interval_ms: 30_000,
            default_model: "claude-sonnet-5".to_string(),
            default_workspace: None,
            tailscale_ip: None,
        }
    }
}

impl ServerSettings {
    /// Minimum allowed WebSocket heartbeat interval in milliseconds.
    pub const MIN_HEARTBEAT_INTERVAL_MS: u64 = 1_000;
    /// Maximum allowed WebSocket heartbeat interval in milliseconds.
    pub const MAX_HEARTBEAT_INTERVAL_MS: u64 = 600_000;

    /// Validate invariants that cannot be safely corrected at runtime.
    pub fn validate_strict(&self) -> crate::domains::settings::Result<()> {
        if !(Self::MIN_HEARTBEAT_INTERVAL_MS..=Self::MAX_HEARTBEAT_INTERVAL_MS)
            .contains(&self.heartbeat_interval_ms)
        {
            return Err(crate::domains::settings::SettingsError::InvalidValue(
                format!(
                    "server.heartbeatIntervalMs must be between {} and {} milliseconds",
                    Self::MIN_HEARTBEAT_INTERVAL_MS,
                    Self::MAX_HEARTBEAT_INTERVAL_MS
                ),
            ));
        }
        Ok(())
    }
}

/// Agent runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AgentRuntimeSettings {
    /// Maximum number of agentic turns per prompt.
    pub max_turns: u32,
}

impl Default for AgentRuntimeSettings {
    fn default() -> Self {
        Self { max_turns: 250 }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_defaults() {
        let s = ServerSettings::default();
        assert_eq!(s.heartbeat_interval_ms, 30_000);
        assert_eq!(s.default_model, "claude-sonnet-5");
        assert!(s.default_workspace.is_none());
        // tailscaleIp defaults absent (populated by installer scripts).
        assert!(s.tailscale_ip.is_none());
    }

    #[test]
    fn tailscale_ip_roundtrip_when_present() {
        let json = serde_json::json!({
            "tailscaleIp": "100.64.213.113"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.tailscale_ip.as_deref(), Some("100.64.213.113"));
        let back = serde_json::to_value(&s).unwrap();
        assert_eq!(back["tailscaleIp"], "100.64.213.113");
    }

    #[test]
    fn tailscale_ip_omitted_when_absent() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        // skip_serializing_if = "Option::is_none" — the key shouldn't appear.
        assert!(json.get("tailscaleIp").is_none());
    }

    #[test]
    fn server_serde_camel_case() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("heartbeatIntervalMs").is_some());
        assert!(json.get("defaultModel").is_some());
    }

    #[test]
    fn server_omits_none_fields() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("defaultWorkspace").is_none());
    }

    #[test]
    fn stale_server_fields_are_rejected() {
        let json = serde_json::json!({
            "wsPort": 8082,
            "defaultModel": "claude-sonnet-4-6"
        });
        let err = serde_json::from_value::<ServerSettings>(json).unwrap_err();
        assert!(err.to_string().contains("unknown field"));
    }

    #[test]
    fn unknown_auth_setting_is_rejected() {
        let json = serde_json::json!({
            "auth": { "enforced": true }
        });
        let err = serde_json::from_value::<ServerSettings>(json).unwrap_err();
        assert!(err.to_string().contains("unknown field"));
    }

    #[test]
    fn agent_defaults() {
        let a = AgentRuntimeSettings::default();
        assert_eq!(a.max_turns, 250);
    }

    #[test]
    fn agent_partial_json_uses_defaults() {
        let json = serde_json::json!({});
        let a: AgentRuntimeSettings = serde_json::from_value(json).unwrap();
        assert_eq!(a.max_turns, 250);

        let roundtrip = serde_json::to_value(&a).unwrap();
        assert_eq!(roundtrip["maxTurns"], 250);
    }

    #[test]
    fn server_partial_json() {
        let json = serde_json::json!({
            "defaultModel": "claude-sonnet-4-5-20250929"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.default_model, "claude-sonnet-4-5-20250929");
    }
}
