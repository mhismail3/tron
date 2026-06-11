//! Public settings DTOs shared across server transport and thin clients.
//!
//! These DTOs intentionally expose only the user-facing settings surface used by
//! paired clients. Internal runtime-only settings stay in
//! `domains::settings::types::TronSettings`.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::domains::settings::types::TronSettings;

/// Current public settings contract version exposed by `settings::*`.
pub const SETTINGS_CONTRACT_VERSION: u64 = 1;

/// Stable public settings snapshot returned by `settings::get` and
/// `settings::reset_to_defaults`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicSettingsSnapshot {
    /// Contract version for this public settings snapshot.
    pub contract_version: u64,
    /// Public server defaults used by thin clients.
    pub server: PublicServerSettings,
    /// Public context-management settings.
    pub context: PublicContextSettings,
    /// Public observability retention and verbosity settings.
    pub observability: PublicObservabilitySettings,
    /// Public storage retention settings.
    pub storage: PublicStorageSettings,
}

impl PublicSettingsSnapshot {
    /// Project internal settings into the stable public settings snapshot.
    #[must_use]
    pub fn from_internal(settings: &TronSettings) -> Self {
        let defaults = crate::domains::settings::types::CompactorSettings::default();
        Self {
            contract_version: SETTINGS_CONTRACT_VERSION,
            server: PublicServerSettings {
                default_model: settings.server.default_model.clone(),
                default_workspace: settings.server.default_workspace.clone(),
                tailscale_ip: settings.server.tailscale_ip.clone(),
            },
            context: PublicContextSettings {
                compactor: PublicCompactorSettings {
                    preserve_recent_count: settings.context.compactor.preserve_recent_count,
                    trigger_token_threshold: settings
                        .context
                        .compactor
                        .trigger_token_threshold
                        .unwrap_or(
                            defaults
                                .trigger_token_threshold
                                .expect("default public trigger threshold must exist"),
                        ),
                },
            },
            observability: PublicObservabilitySettings {
                log_level: settings.observability.log_level.as_filter_str().to_owned(),
                verbose_retention_days: settings.observability.verbose_retention_days,
            },
            storage: PublicStorageSettings {
                retention_enabled: settings.storage.retention_enabled,
                max_database_mb: settings.storage.max_database_mb,
            },
        }
    }

    /// Serialize the snapshot as a JSON value for engine capability responses.
    pub fn to_value(&self) -> serde_json::Result<Value> {
        serde_json::to_value(self)
    }
}

/// Sparse public settings update accepted by `settings::update`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicSettingsUpdate {
    /// Contract version expected by the server for this update payload.
    pub contract_version: u64,
    /// Optional sparse server-setting updates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server: Option<PublicServerSettingsUpdate>,
    /// Optional sparse context-setting updates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<PublicContextSettingsUpdate>,
    /// Optional sparse observability-setting updates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observability: Option<PublicObservabilitySettingsUpdate>,
    /// Optional sparse storage-setting updates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage: Option<PublicStorageSettingsUpdate>,
}

impl Default for PublicSettingsUpdate {
    fn default() -> Self {
        Self {
            contract_version: SETTINGS_CONTRACT_VERSION,
            server: None,
            context: None,
            observability: None,
            storage: None,
        }
    }
}

impl PublicSettingsUpdate {
    /// Validate that the client is using the current settings contract version.
    pub fn validate_contract_version(&self) -> Result<(), String> {
        if self.contract_version == SETTINGS_CONTRACT_VERSION {
            Ok(())
        } else {
            Err(format!(
                "settings contractVersion {} is not supported; expected {}",
                self.contract_version, SETTINGS_CONTRACT_VERSION
            ))
        }
    }

    /// Convert a public update into the sparse profile overlay shape.
    pub fn into_sparse_settings_value(self) -> Result<Value, String> {
        self.validate_contract_version()?;
        serde_json::to_value(SparsePublicSettingsUpdate {
            server: self.server,
            context: self.context,
            observability: self.observability,
            storage: self.storage,
        })
        .map_err(|error| format!("failed to encode public settings update: {error}"))
    }
}

/// Public subset of server settings exposed to paired clients.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicServerSettings {
    /// Default model identifier.
    pub default_model: String,
    /// Optional default workspace path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_workspace: Option<String>,
    /// Optional cached Tailscale IP for pairing/onboarding display.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tailscale_ip: Option<String>,
}

/// Public context-management settings exposed to paired clients.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicContextSettings {
    /// Prompt compaction settings.
    pub compactor: PublicCompactorSettings,
}

/// Public prompt compaction settings exposed to paired clients.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicCompactorSettings {
    /// Number of recent turns preserved before compaction.
    pub preserve_recent_count: usize,
    /// Token-threshold ratio that triggers compaction.
    pub trigger_token_threshold: f64,
}

/// Public observability settings exposed to paired clients.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicObservabilitySettings {
    /// Minimum diagnostic log level.
    pub log_level: String,
    /// Verbose diagnostic retention window in days.
    pub verbose_retention_days: u64,
}

/// Public storage settings exposed to paired clients.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicStorageSettings {
    /// Whether automatic retention may prune low-signal data.
    pub retention_enabled: bool,
    /// Soft database-size cap in megabytes.
    pub max_database_mb: u64,
}

/// Sparse update for public server settings.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicServerSettingsUpdate {
    /// New default model identifier.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_model: Option<String>,
    /// New optional default workspace path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_workspace: Option<String>,
    /// New optional cached Tailscale IP.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailscale_ip: Option<String>,
}

/// Sparse update for public context settings.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicContextSettingsUpdate {
    /// Optional prompt compaction update.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compactor: Option<PublicCompactorSettingsUpdate>,
}

/// Sparse update for public prompt compaction settings.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicCompactorSettingsUpdate {
    /// New recent-turn preservation count.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preserve_recent_count: Option<usize>,
    /// New compaction trigger threshold.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger_token_threshold: Option<f64>,
}

/// Sparse update for public observability settings.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicObservabilitySettingsUpdate {
    /// New minimum diagnostic log level.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_level: Option<String>,
    /// New verbose diagnostic retention window in days.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verbose_retention_days: Option<u64>,
}

/// Sparse update for public storage settings.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicStorageSettingsUpdate {
    /// New retention enabled flag.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retention_enabled: Option<bool>,
    /// New soft database-size cap in megabytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_database_mb: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SparsePublicSettingsUpdate {
    #[serde(skip_serializing_if = "Option::is_none")]
    server: Option<PublicServerSettingsUpdate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: Option<PublicContextSettingsUpdate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    observability: Option<PublicObservabilitySettingsUpdate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    storage: Option<PublicStorageSettingsUpdate>,
}

#[must_use]
/// JSON schema for the public settings snapshot contract.
pub fn public_settings_snapshot_schema() -> Value {
    json!({
        "type": "object",
        "required": ["contractVersion", "server", "context", "observability", "storage"],
        "additionalProperties": false,
        "properties": {
            "contractVersion": {"type": "integer", "const": SETTINGS_CONTRACT_VERSION},
            "server": {
                "type": "object",
                "required": ["defaultModel"],
                "additionalProperties": false,
                "properties": {
                    "defaultModel": {"type": "string"},
                    "defaultWorkspace": {"type": ["string", "null"]},
                    "tailscaleIp": {"type": ["string", "null"]}
                }
            },
            "context": {
                "type": "object",
                "required": ["compactor"],
                "additionalProperties": false,
                "properties": {
                    "compactor": {
                        "type": "object",
                        "required": ["preserveRecentCount", "triggerTokenThreshold"],
                        "additionalProperties": false,
                        "properties": {
                            "preserveRecentCount": {"type": "integer"},
                            "triggerTokenThreshold": {"type": "number"}
                        }
                    }
                }
            },
            "observability": {
                "type": "object",
                "required": ["logLevel", "verboseRetentionDays"],
                "additionalProperties": false,
                "properties": {
                    "logLevel": {"type": "string"},
                    "verboseRetentionDays": {"type": "integer"}
                }
            },
            "storage": {
                "type": "object",
                "required": ["retentionEnabled", "maxDatabaseMb"],
                "additionalProperties": false,
                "properties": {
                    "retentionEnabled": {"type": "boolean"},
                    "maxDatabaseMb": {"type": "integer"}
                }
            }
        }
    })
}

#[must_use]
/// JSON schema for the public sparse settings update contract.
pub fn public_settings_update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["contractVersion"],
        "additionalProperties": false,
        "properties": {
            "contractVersion": {"type": "integer", "const": SETTINGS_CONTRACT_VERSION},
            "server": {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "defaultModel": {"type": "string"},
                    "defaultWorkspace": {"type": "string"},
                    "tailscaleIp": {"type": "string"}
                }
            },
            "context": {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "compactor": {
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {
                            "preserveRecentCount": {"type": "integer"},
                            "triggerTokenThreshold": {"type": "number"}
                        }
                    }
                }
            },
            "observability": {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "logLevel": {"type": "string"},
                    "verboseRetentionDays": {"type": "integer"}
                }
            },
            "storage": {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "retentionEnabled": {"type": "boolean"},
                    "maxDatabaseMb": {"type": "integer"}
                }
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_settings_snapshot_exposes_only_client_surface() {
        let value = PublicSettingsSnapshot::from_internal(&TronSettings::default())
            .to_value()
            .expect("settings snapshot value");
        assert_eq!(value["contractVersion"], SETTINGS_CONTRACT_VERSION);
        assert!(value.pointer("/server/defaultModel").is_some());
        assert!(
            value
                .pointer("/context/compactor/preserveRecentCount")
                .is_some()
        );
        assert!(value.pointer("/observability/logLevel").is_some());
        assert!(value.pointer("/storage/maxDatabaseMb").is_some());
        assert!(value.pointer("/server/defaultProvider").is_none());
        assert!(value.pointer("/server/heartbeatIntervalMs").is_none());
        assert!(value.pointer("/context/compactor/maxTokens").is_none());
    }

    #[test]
    fn public_settings_update_requires_current_contract_version() {
        let update = PublicSettingsUpdate {
            contract_version: SETTINGS_CONTRACT_VERSION + 1,
            ..PublicSettingsUpdate::default()
        };
        let error = update
            .into_sparse_settings_value()
            .expect_err("stale version");
        assert!(error.contains("contractVersion"));
    }

    #[test]
    fn public_settings_update_preserves_sparse_semantics() {
        let update = PublicSettingsUpdate {
            server: Some(PublicServerSettingsUpdate {
                default_workspace: Some("/tmp/demo".to_owned()),
                ..PublicServerSettingsUpdate::default()
            }),
            ..PublicSettingsUpdate::default()
        };
        let value = update
            .into_sparse_settings_value()
            .expect("sparse update value");
        assert_eq!(value, json!({"server": {"defaultWorkspace": "/tmp/demo"}}));
    }
}
