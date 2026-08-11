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
    /// Server-owned defaults and ceilings for reusable-agent coordination.
    /// These settings are deliberately not part of the mobile product-settings
    /// projection; clients inspect effective values through agent management.
    pub coordination: AgentCoordinationSettings,
}

impl Default for AgentRuntimeSettings {
    fn default() -> Self {
        Self {
            max_turns: 250,
            coordination: AgentCoordinationSettings::default(),
        }
    }
}

/// Profile runtime limits for first-class agent collaboration.
///
/// The provider may request tighter values for a child assignment, but no
/// model-facing operation can raise these effective ceilings. Assignment turn
/// and wall-time defaults have distinct hard maxima; the remaining graph and
/// autonomy limits default to their hard product ceilings and may only be
/// lowered in settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AgentCoordinationSettings {
    /// Default provider-turn budget for one assignment.
    pub assignment_default_turns: u32,
    /// Default wall-clock budget in seconds for one assignment.
    pub assignment_default_seconds: u64,
    /// Profile ceiling for a requested assignment turn budget.
    pub assignment_max_turns: u32,
    /// Profile ceiling for a requested assignment wall-clock budget.
    pub assignment_max_seconds: u64,
    /// Maximum simultaneously active nested agents under one visible root.
    pub max_active_children: u32,
    /// Maximum mixed agent/worker execution nodes in one causal graph.
    pub max_execution_nodes: u32,
    /// Maximum mixed execution-parent depth.
    pub max_causal_depth: u32,
    /// Maximum queued or offered assignments held by one reusable agent.
    pub max_queued_assignments: u32,
    /// Maximum durable coordination messages in one trace.
    pub max_coordination_messages: u32,
    /// Maximum consecutive engine-driven wakes without user/operator input.
    pub max_autonomous_wake_hops: u32,
}

impl AgentCoordinationSettings {
    /// Hard product ceiling for assignment provider turns.
    pub const HARD_MAX_ASSIGNMENT_TURNS: u32 = 250;
    /// Hard product ceiling for assignment wall time.
    pub const HARD_MAX_ASSIGNMENT_SECONDS: u64 = 7_200;
    /// Hard product ceiling for active nested agents.
    pub const HARD_MAX_ACTIVE_CHILDREN: u32 = 8;
    /// Hard product ceiling for mixed causal graph nodes.
    pub const HARD_MAX_EXECUTION_NODES: u32 = 64;
    /// Hard product ceiling for causal graph depth.
    pub const HARD_MAX_CAUSAL_DEPTH: u32 = 16;
    /// Hard product ceiling for an agent's queued/offered assignments.
    pub const HARD_MAX_QUEUED_ASSIGNMENTS: u32 = 8;
    /// Hard product ceiling for messages in one coordination trace.
    pub const HARD_MAX_COORDINATION_MESSAGES: u32 = 256;
    /// Hard product ceiling for consecutive autonomous coordination wakes.
    pub const HARD_MAX_AUTONOMOUS_WAKE_HOPS: u32 = 16;

    /// Clamp sparse user settings to the product safety envelope. Zeroes are
    /// repaired to one because a zero-sized graph cannot admit or recover work.
    pub fn normalize(&mut self) {
        self.assignment_max_turns = self
            .assignment_max_turns
            .clamp(1, Self::HARD_MAX_ASSIGNMENT_TURNS);
        self.assignment_max_seconds = self
            .assignment_max_seconds
            .clamp(1, Self::HARD_MAX_ASSIGNMENT_SECONDS);
        self.assignment_default_turns = self
            .assignment_default_turns
            .clamp(1, self.assignment_max_turns);
        self.assignment_default_seconds = self
            .assignment_default_seconds
            .clamp(1, self.assignment_max_seconds);
        self.max_active_children = self
            .max_active_children
            .clamp(1, Self::HARD_MAX_ACTIVE_CHILDREN);
        self.max_execution_nodes = self
            .max_execution_nodes
            .clamp(1, Self::HARD_MAX_EXECUTION_NODES);
        self.max_causal_depth = self.max_causal_depth.clamp(1, Self::HARD_MAX_CAUSAL_DEPTH);
        self.max_queued_assignments = self
            .max_queued_assignments
            .clamp(1, Self::HARD_MAX_QUEUED_ASSIGNMENTS);
        self.max_coordination_messages = self
            .max_coordination_messages
            .clamp(1, Self::HARD_MAX_COORDINATION_MESSAGES);
        self.max_autonomous_wake_hops = self
            .max_autonomous_wake_hops
            .clamp(1, Self::HARD_MAX_AUTONOMOUS_WAKE_HOPS);
    }
}

impl Default for AgentCoordinationSettings {
    fn default() -> Self {
        Self {
            assignment_default_turns: 32,
            assignment_default_seconds: 15 * 60,
            assignment_max_turns: Self::HARD_MAX_ASSIGNMENT_TURNS,
            assignment_max_seconds: Self::HARD_MAX_ASSIGNMENT_SECONDS,
            max_active_children: Self::HARD_MAX_ACTIVE_CHILDREN,
            max_execution_nodes: Self::HARD_MAX_EXECUTION_NODES,
            max_causal_depth: Self::HARD_MAX_CAUSAL_DEPTH,
            max_queued_assignments: Self::HARD_MAX_QUEUED_ASSIGNMENTS,
            max_coordination_messages: Self::HARD_MAX_COORDINATION_MESSAGES,
            max_autonomous_wake_hops: Self::HARD_MAX_AUTONOMOUS_WAKE_HOPS,
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
        assert_eq!(a.coordination.assignment_default_turns, 32);
        assert_eq!(a.coordination.assignment_default_seconds, 900);
        assert_eq!(a.coordination.max_execution_nodes, 64);
    }

    #[test]
    fn agent_partial_json_uses_defaults() {
        let json = serde_json::json!({});
        let a: AgentRuntimeSettings = serde_json::from_value(json).unwrap();
        assert_eq!(a.max_turns, 250);

        let roundtrip = serde_json::to_value(&a).unwrap();
        assert_eq!(roundtrip["maxTurns"], 250);
        assert_eq!(roundtrip["coordination"]["maxActiveChildren"], 8);
    }

    #[test]
    fn coordination_limits_normalize_to_hard_ceiling_and_nonzero_defaults() {
        let mut limits: AgentCoordinationSettings = serde_json::from_value(serde_json::json!({
            "assignmentDefaultTurns": 999,
            "assignmentDefaultSeconds": 0,
            "assignmentMaxTurns": 999,
            "assignmentMaxSeconds": 99999,
            "maxActiveChildren": 99,
            "maxExecutionNodes": 0,
            "maxCausalDepth": 99,
            "maxQueuedAssignments": 99,
            "maxCoordinationMessages": 999,
            "maxAutonomousWakeHops": 99
        }))
        .unwrap();
        limits.normalize();
        assert_eq!(limits.assignment_default_turns, 250);
        assert_eq!(limits.assignment_default_seconds, 1);
        assert_eq!(limits.max_active_children, 8);
        assert_eq!(limits.max_execution_nodes, 1);
        assert_eq!(limits.max_causal_depth, 16);
        assert_eq!(limits.max_coordination_messages, 256);
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
