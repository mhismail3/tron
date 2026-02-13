//! Server configuration.

use serde::{Deserialize, Serialize};

/// Configuration for the Tron server.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ServerConfig {
    /// Host to bind (default `"127.0.0.1"`).
    pub host: String,
    /// Port to bind (default `0` for auto-assign).
    pub port: u16,
    /// Maximum concurrent WebSocket connections.
    pub max_connections: usize,
    /// Heartbeat interval in seconds.
    pub heartbeat_interval_secs: u64,
    /// Heartbeat timeout in seconds (close after this many missed pongs).
    pub heartbeat_timeout_secs: u64,
    /// Max WebSocket message size in bytes.
    pub max_message_size: usize,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            max_connections: 50,
            heartbeat_interval_secs: 30,
            heartbeat_timeout_secs: 90,
            max_message_size: 16 * 1024 * 1024, // 16 MB
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_host() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.host, "127.0.0.1");
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
        assert_eq!(cfg.heartbeat_interval_secs, 30);
    }

    #[test]
    fn default_heartbeat_timeout() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.heartbeat_timeout_secs, 90);
    }

    #[test]
    fn default_max_message_size() {
        let cfg = ServerConfig::default();
        assert_eq!(cfg.max_message_size, 16 * 1024 * 1024);
    }

    #[test]
    fn serde_roundtrip() {
        let cfg = ServerConfig::default();
        let json = serde_json::to_string(&cfg).unwrap();
        let back: ServerConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.host, cfg.host);
        assert_eq!(back.port, cfg.port);
        assert_eq!(back.max_connections, cfg.max_connections);
        assert_eq!(back.heartbeat_interval_secs, cfg.heartbeat_interval_secs);
        assert_eq!(back.heartbeat_timeout_secs, cfg.heartbeat_timeout_secs);
        assert_eq!(back.max_message_size, cfg.max_message_size);
    }

    #[test]
    fn custom_values() {
        let cfg = ServerConfig {
            host: "0.0.0.0".into(),
            port: 8080,
            max_connections: 100,
            heartbeat_interval_secs: 15,
            heartbeat_timeout_secs: 45,
            max_message_size: 1024,
        };
        assert_eq!(cfg.host, "0.0.0.0");
        assert_eq!(cfg.port, 8080);
        assert_eq!(cfg.max_connections, 100);
        assert_eq!(cfg.heartbeat_interval_secs, 15);
        assert_eq!(cfg.heartbeat_timeout_secs, 45);
        assert_eq!(cfg.max_message_size, 1024);
    }

    #[test]
    fn deserialize_from_json_string() {
        let json = r#"{"host":"10.0.0.1","port":3000,"max_connections":5,"heartbeat_interval_secs":10,"heartbeat_timeout_secs":30,"max_message_size":512}"#;
        let cfg: ServerConfig = serde_json::from_str(json).unwrap();
        assert_eq!(cfg.host, "10.0.0.1");
        assert_eq!(cfg.port, 3000);
        assert_eq!(cfg.max_connections, 5);
    }
}
