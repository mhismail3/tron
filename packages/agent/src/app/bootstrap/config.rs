//! Server configuration.

use serde::{Deserialize, Serialize};

/// Configuration for the Tron server.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ServerConfig {
    /// Host to bind (default `"0.0.0.0"`).
    pub host: String,
    /// Port to bind (default `0` for auto-assign).
    pub port: u16,
    /// Maximum concurrent WebSocket connections.
    pub max_connections: usize,
    /// Heartbeat interval in milliseconds.
    pub heartbeat_interval_ms: u64,
    /// Heartbeat timeout in milliseconds (close after this many missed pongs).
    pub heartbeat_timeout_ms: u64,
    /// Max WebSocket message size in bytes (default 150 MB).
    pub max_message_size: usize,
    /// Rate limit: max requests per second per connection. 0 = disabled (default).
    pub rate_limit_rps: u64,
    /// Whether CORS is enabled (default false).
    pub cors_enabled: bool,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "0.0.0.0".into(),
            port: 0,
            max_connections: 50,
            heartbeat_interval_ms: 30_000,
            heartbeat_timeout_ms: 90_000,
            max_message_size: 150 * 1024 * 1024, // 150 MB — accommodates 15-min voice notes at 48kHz (~115 MB base64)
            rate_limit_rps: 0,                   // disabled by default
            cors_enabled: false,                 // disabled by default
        }
    }
}

impl ServerConfig {
    /// Build runtime server config from CLI-owned bind values and settings-owned
    /// heartbeat tuning.
    pub fn from_settings(
        host: String,
        port: u16,
        settings: &crate::domains::settings::types::ServerSettings,
    ) -> Self {
        let heartbeat_interval_ms = settings.heartbeat_interval_ms;
        let heartbeat_timeout_ms = heartbeat_interval_ms
            .saturating_mul(3)
            .max(heartbeat_interval_ms);
        Self {
            host,
            port,
            heartbeat_interval_ms,
            heartbeat_timeout_ms,
            ..Self::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_host() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.host, "0.0.0.0");
    }

    #[test]
    fn default_port_is_zero() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.port, 0);
    }

    #[test]
    fn default_max_connections() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.max_connections, 50);
    }

    #[test]
    fn default_heartbeat_interval() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.heartbeat_interval_ms, 30_000);
    }

    #[test]
    fn default_heartbeat_timeout() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.heartbeat_timeout_ms, 90_000);
    }

    #[test]
    fn default_max_message_size() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.max_message_size, 150 * 1024 * 1024);
    }

    #[test]
    fn default_rate_limit_disabled() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.rate_limit_rps, 0);
    }

    #[test]
    fn default_cors_disabled() {
        let cfg = ServerConfig::default();
        assert!(!cfg.cors_enabled);
    }

    #[test]
    fn serde_roundtrip() {
        let cfg = ServerConfig::default();
        let json = serde_json::to_string(&cfg).unwrap();
        let back: ServerConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.host, cfg.host);
        assert_eq!(back.port, cfg.port);
        assert_eq!(back.max_connections, cfg.max_connections);
        assert_eq!(back.heartbeat_interval_ms, cfg.heartbeat_interval_ms);
        assert_eq!(back.heartbeat_timeout_ms, cfg.heartbeat_timeout_ms);
        assert_eq!(back.max_message_size, cfg.max_message_size);
        assert_eq!(back.rate_limit_rps, cfg.rate_limit_rps);
        assert_eq!(back.cors_enabled, cfg.cors_enabled);
    }

    #[test]
    fn custom_values() {
        let cfg = ServerConfig {
            host: "0.0.0.0".into(),
            port: 8080,
            max_connections: 100,
            heartbeat_interval_ms: 15_000,
            heartbeat_timeout_ms: 45_000,
            max_message_size: 1024,
            rate_limit_rps: 100,
            cors_enabled: true,
        };
        assert_eq!(cfg.host, "0.0.0.0");
        assert_eq!(cfg.port, 8080);
        assert_eq!(cfg.max_connections, 100);
        assert_eq!(cfg.heartbeat_interval_ms, 15_000);
        assert_eq!(cfg.heartbeat_timeout_ms, 45_000);
        assert_eq!(cfg.max_message_size, 1024);
        assert_eq!(cfg.rate_limit_rps, 100);
        assert!(cfg.cors_enabled);
    }

    #[test]
    fn deserialize_from_json_string() {
        let json = r#"{"host":"10.0.0.1","port":3000,"max_connections":5,"heartbeat_interval_ms":10000,"heartbeat_timeout_ms":30000,"max_message_size":512,"rate_limit_rps":0,"cors_enabled":false}"#;
        let cfg: ServerConfig = serde_json::from_str(json).unwrap();
        assert_eq!(cfg.host, "10.0.0.1");
        assert_eq!(cfg.port, 3000);
        assert_eq!(cfg.max_connections, 5);
        assert_eq!(cfg.heartbeat_interval_ms, 10_000);
        assert_eq!(cfg.heartbeat_timeout_ms, 30_000);
    }

    #[test]
    fn from_settings_uses_settings_heartbeat_and_cli_bind_values() {
        let mut settings = crate::domains::settings::types::ServerSettings::default();
        settings.heartbeat_interval_ms = 12_345;
        let cfg = ServerConfig::from_settings("127.0.0.1".to_string(), 9847, &settings);
        assert_eq!(cfg.host, "127.0.0.1");
        assert_eq!(cfg.port, 9847);
        assert_eq!(cfg.heartbeat_interval_ms, 12_345);
        assert_eq!(cfg.heartbeat_timeout_ms, 37_035);
    }
}
