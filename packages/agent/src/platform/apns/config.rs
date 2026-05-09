//! APNS relay configuration.
//!
//! Production push delivery is relay-only: the server signs requests to the
//! Cloudflare Worker, and the Worker owns the Apple `.p8` key material.

use tracing::{debug, warn};

/// Build-time relay URL (compiled via `TRON_RELAY_URL` env var at build time).
const RELAY_URL: Option<&str> = option_env!("TRON_RELAY_URL");
/// Build-time relay HMAC secret (compiled via `TRON_RELAY_SECRET` env var at build time).
const RELAY_SECRET: Option<&str> = option_env!("TRON_RELAY_SECRET");

/// Relay service configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayConfig {
    /// Relay worker URL (e.g., "https://relay.tron.dev").
    pub relay_url: String,
    /// Shared HMAC secret for request signing.
    pub relay_secret: String,
    /// APNs environment: "sandbox" or "production".
    pub environment: String,
}

/// Resolved push notification configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushConfig {
    /// Relay delivery via Cloudflare Worker.
    Relay(RelayConfig),
    /// Push notifications disabled.
    Disabled,
}

/// Load push configuration with one paved production path: relay or disabled.
pub fn load_push_config() -> PushConfig {
    load_relay_config()
        .map(PushConfig::Relay)
        .unwrap_or(PushConfig::Disabled)
}

/// Try to load relay config from runtime env vars or build-time constants.
pub fn load_relay_config() -> Option<RelayConfig> {
    let url = std::env::var("TRON_RELAY_URL")
        .ok()
        .or_else(|| RELAY_URL.map(String::from));
    let secret = std::env::var("TRON_RELAY_SECRET")
        .ok()
        .or_else(|| RELAY_SECRET.map(String::from));
    let environment = std::env::var("TRON_RELAY_ENVIRONMENT").ok();
    relay_config_from_values(url, secret, environment)
}

fn relay_config_from_values(
    url: Option<String>,
    secret: Option<String>,
    environment: Option<String>,
) -> Option<RelayConfig> {
    let (Some(url), Some(secret)) = (url, secret) else {
        return None;
    };

    if url.is_empty() {
        warn!("TRON_RELAY_URL is empty — relay disabled");
        return None;
    }
    if secret.is_empty() {
        warn!("TRON_RELAY_SECRET is empty — relay disabled");
        return None;
    }

    let environment = environment.unwrap_or_else(|| "production".to_string());

    debug!(
        relay_url = %url,
        environment = %environment,
        "relay config loaded"
    );

    Some(RelayConfig {
        relay_url: url,
        relay_secret: secret,
        environment,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_config_requires_url_and_secret() {
        assert!(relay_config_from_values(None, Some("secret".into()), None).is_none());
        assert!(relay_config_from_values(Some("https://relay.test".into()), None, None).is_none());
    }

    #[test]
    fn relay_config_rejects_empty_values() {
        assert!(
            relay_config_from_values(Some(String::new()), Some("secret".into()), None).is_none()
        );
        assert!(
            relay_config_from_values(Some("https://relay.test".into()), Some(String::new()), None)
                .is_none()
        );
    }

    #[test]
    fn relay_config_defaults_to_production_environment() {
        let config = relay_config_from_values(
            Some("https://relay.test".into()),
            Some("secret".into()),
            None,
        )
        .unwrap();

        assert_eq!(config.relay_url, "https://relay.test");
        assert_eq!(config.relay_secret, "secret");
        assert_eq!(config.environment, "production");
    }

    #[test]
    fn relay_config_accepts_explicit_environment() {
        let config = relay_config_from_values(
            Some("https://relay.test".into()),
            Some("secret".into()),
            Some("sandbox".into()),
        )
        .unwrap();

        assert_eq!(config.environment, "sandbox");
    }
}
