//! APNS configuration loading from `~/.tron/mods/apns/`.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tracing::{debug, warn};

/// APNS configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApnsConfig {
    /// Apple Developer Key ID (10-char alphanumeric).
    pub key_id: String,
    /// Apple Developer Team ID (10-char alphanumeric).
    pub team_id: String,
    /// App bundle identifier (e.g., "com.example.TronMobile").
    pub bundle_id: String,
    /// APNS environment: "sandbox" or "production".
    #[serde(default = "default_environment")]
    pub environment: String,
    /// Optional explicit path to the .p8 key file.
    pub key_path: Option<String>,
}

fn default_environment() -> String {
    "sandbox".to_string()
}

impl ApnsConfig {
    /// Resolve the path to the private key file.
    pub fn resolved_key_path(&self) -> PathBuf {
        if let Some(ref path) = self.key_path {
            let expanded = if path.starts_with('~') {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
                PathBuf::from(home).join(path.trim_start_matches("~/"))
            } else {
                PathBuf::from(path)
            };
            return expanded;
        }
        // Default: ~/.tron/mods/apns/AuthKey_{keyId}.p8
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        PathBuf::from(home)
            .join(".tron")
            .join("mods")
            .join("apns")
            .join(format!("AuthKey_{}.p8", self.key_id))
    }

    /// APNS server hostname based on environment.
    pub fn apns_host(&self) -> &str {
        if self.environment == "production" {
            "api.push.apple.com"
        } else {
            "api.sandbox.push.apple.com"
        }
    }
}

/// Load APNS config from `~/.tron/mods/apns/config.json`.
///
/// Returns `None` if config doesn't exist or is invalid (not an error —
/// APNS is optional).
pub fn load_apns_config() -> Option<ApnsConfig> {
    load_from_path(None)
}

/// Load APNS config from a specific base directory (for testing).
pub(crate) fn load_from_path(base: Option<&Path>) -> Option<ApnsConfig> {
    let config_path = if let Some(base) = base {
        base.join("config.json")
    } else {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        PathBuf::from(home)
            .join(".tron")
            .join("mods")
            .join("apns")
            .join("config.json")
    };

    if !config_path.exists() {
        debug!(?config_path, "APNS config not found, push notifications disabled");
        return None;
    }

    let content = match std::fs::read_to_string(&config_path) {
        Ok(c) => c,
        Err(e) => {
            warn!(?config_path, error = %e, "failed to read APNS config");
            return None;
        }
    };

    let config: ApnsConfig = match serde_json::from_str(&content) {
        Ok(c) => c,
        Err(e) => {
            warn!(?config_path, error = %e, "failed to parse APNS config");
            return None;
        }
    };

    // Validate required fields
    if config.key_id.is_empty() || config.team_id.is_empty() || config.bundle_id.is_empty() {
        warn!("APNS config missing required fields (keyId, teamId, bundleId)");
        return None;
    }

    // Check key file exists
    let key_path = config.resolved_key_path();
    if !key_path.exists() {
        warn!(?key_path, "APNS private key file not found");
        return None;
    }

    debug!(
        key_id = %config.key_id,
        team_id = %config.team_id,
        bundle_id = %config.bundle_id,
        environment = %config.environment,
        "APNS config loaded"
    );

    Some(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_environment_is_sandbox() {
        let json = r#"{"keyId": "ABC", "teamId": "XYZ", "bundleId": "com.test.App"}"#;
        let config: ApnsConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.environment, "sandbox");
    }

    #[test]
    fn resolved_key_path_default() {
        let config = ApnsConfig {
            key_id: "ABC123".to_string(),
            team_id: "XYZ".to_string(),
            bundle_id: "com.test".to_string(),
            environment: "sandbox".to_string(),
            key_path: None,
        };
        let path = config.resolved_key_path();
        assert!(path.to_string_lossy().contains("AuthKey_ABC123.p8"));
        assert!(path.to_string_lossy().contains(".tron/mods/apns"));
    }

    #[test]
    fn resolved_key_path_explicit() {
        let config = ApnsConfig {
            key_id: "ABC".to_string(),
            team_id: "XYZ".to_string(),
            bundle_id: "com.test".to_string(),
            environment: "sandbox".to_string(),
            key_path: Some("/custom/path/key.p8".to_string()),
        };
        assert_eq!(
            config.resolved_key_path(),
            PathBuf::from("/custom/path/key.p8")
        );
    }

    #[test]
    fn apns_host_sandbox() {
        let config = ApnsConfig {
            key_id: "A".to_string(),
            team_id: "B".to_string(),
            bundle_id: "C".to_string(),
            environment: "sandbox".to_string(),
            key_path: None,
        };
        assert_eq!(config.apns_host(), "api.sandbox.push.apple.com");
    }

    #[test]
    fn apns_host_production() {
        let config = ApnsConfig {
            key_id: "A".to_string(),
            team_id: "B".to_string(),
            bundle_id: "C".to_string(),
            environment: "production".to_string(),
            key_path: None,
        };
        assert_eq!(config.apns_host(), "api.push.apple.com");
    }

    #[test]
    fn load_from_nonexistent_returns_none() {
        let result = load_from_path(Some(Path::new("/nonexistent/path")));
        assert!(result.is_none());
    }

    #[test]
    fn load_from_invalid_json_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("config.json"), "not json").unwrap();
        let result = load_from_path(Some(dir.path()));
        assert!(result.is_none());
    }

    #[test]
    fn load_missing_required_fields_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("config.json"),
            r#"{"keyId": "", "teamId": "X", "bundleId": "Y"}"#,
        )
        .unwrap();
        let result = load_from_path(Some(dir.path()));
        assert!(result.is_none());
    }

    #[test]
    fn load_valid_config_without_key_file_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("config.json"),
            r#"{"keyId": "ABC", "teamId": "XYZ", "bundleId": "com.test"}"#,
        )
        .unwrap();
        // No .p8 file exists
        let result = load_from_path(Some(dir.path()));
        assert!(result.is_none());
    }

    #[test]
    fn load_valid_config_with_key_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("config.json"),
            serde_json::json!({
                "keyId": "ABC",
                "teamId": "XYZ",
                "bundleId": "com.test",
                "keyPath": dir.path().join("key.p8").to_string_lossy().to_string(),
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(dir.path().join("key.p8"), "fake key").unwrap();

        let result = load_from_path(Some(dir.path()));
        assert!(result.is_some());
        let config = result.unwrap();
        assert_eq!(config.key_id, "ABC");
        assert_eq!(config.team_id, "XYZ");
        assert_eq!(config.bundle_id, "com.test");
    }

    #[test]
    fn camel_case_deserialization() {
        let json = r#"{
            "keyId": "K1",
            "teamId": "T1",
            "bundleId": "com.test.app",
            "environment": "production",
            "keyPath": "/some/path.p8"
        }"#;
        let config: ApnsConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.key_id, "K1");
        assert_eq!(config.team_id, "T1");
        assert_eq!(config.bundle_id, "com.test.app");
        assert_eq!(config.environment, "production");
        assert_eq!(config.key_path.as_deref(), Some("/some/path.p8"));
    }
}
