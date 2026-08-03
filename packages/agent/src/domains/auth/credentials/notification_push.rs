//! Native-notification transport selection and relay credentials.
//!
//! The engine owns this closed transport configuration under the
//! `notification-push` provider entry in `auth.json`. Workers and clients never
//! receive the relay URL or HMAC secret. Direct APNs signing material remains
//! independently owned by the `apple-push` entry so changing transport mode
//! never copies or destroys either credential.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{
    AuthError, acquire_auth_file_lock, load_auth_storage, load_or_init_for_write, save_auth_storage,
};

pub(crate) const NOTIFICATION_PUSH_PROVIDER_ID: &str = "notification-push";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NotificationTransportMode {
    Relay,
    Direct,
}

impl NotificationTransportMode {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Relay => "relay",
            Self::Direct => "direct",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NotificationRelayCredentials {
    pub(crate) url: String,
    pub(crate) secret: String,
}

impl NotificationRelayCredentials {
    pub(crate) fn validate(&self) -> Result<(), String> {
        let parsed = reqwest::Url::parse(self.url.trim())
            .map_err(|_| "notification relay URL must be an absolute HTTPS URL".to_owned())?;
        if parsed.scheme() != "https"
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.path() != "/"
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            return Err(
                "notification relay URL must be an HTTPS origin with no path, credentials, query, or fragment"
                    .to_owned(),
            );
        }
        if self.secret.len() < 16 || self.secret.len() > 4_096 {
            return Err(
                "notification relay secret must contain between 16 and 4096 bytes".to_owned(),
            );
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NotificationPushConfig {
    pub(crate) mode: NotificationTransportMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) relay: Option<NotificationRelayCredentials>,
}

impl NotificationPushConfig {
    pub(crate) fn validate(&self) -> Result<(), String> {
        if let Some(relay) = &self.relay {
            relay.validate()?;
        }
        if self.mode == NotificationTransportMode::Relay && self.relay.is_none() {
            return Err("relay notification transport requires relay credentials".to_owned());
        }
        Ok(())
    }
}

pub(crate) fn load_notification_push_config(
    path: &Path,
) -> Result<Option<NotificationPushConfig>, AuthError> {
    let Some(storage) = load_auth_storage(path)? else {
        return Ok(None);
    };
    match storage.providers.get(NOTIFICATION_PUSH_PROVIDER_ID) {
        None => Ok(None),
        Some(value) => serde_json::from_value::<NotificationPushConfig>(value.clone())
            .map(Some)
            .map_err(|error| AuthError::MalformedProviderAuth {
                provider: NOTIFICATION_PUSH_PROVIDER_ID.to_owned(),
                details: error.to_string(),
            }),
    }
}

pub(crate) fn save_notification_relay_credentials(
    path: &Path,
    relay: NotificationRelayCredentials,
) -> Result<NotificationPushConfig, AuthError> {
    relay
        .validate()
        .map_err(|details| malformed_notification_push(details))?;
    mutate_notification_push_config(path, |_current| NotificationPushConfig {
        mode: NotificationTransportMode::Relay,
        relay: Some(relay),
    })
}

pub(crate) fn set_notification_transport_mode(
    path: &Path,
    mode: NotificationTransportMode,
) -> Result<NotificationPushConfig, AuthError> {
    mutate_notification_push_config(path, |current| NotificationPushConfig {
        mode,
        relay: current.and_then(|value| value.relay),
    })
}

pub(crate) fn clear_notification_relay_credentials(path: &Path) -> Result<bool, AuthError> {
    let _lock = acquire_auth_file_lock(path)?;
    let Some(mut storage) = load_auth_storage(path)? else {
        return Ok(false);
    };
    let Some(value) = storage
        .providers
        .get(NOTIFICATION_PUSH_PROVIDER_ID)
        .cloned()
    else {
        return Ok(false);
    };
    let mut config = serde_json::from_value::<NotificationPushConfig>(value).map_err(|error| {
        AuthError::MalformedProviderAuth {
            provider: NOTIFICATION_PUSH_PROVIDER_ID.to_owned(),
            details: error.to_string(),
        }
    })?;
    let changed = config.relay.take().is_some();
    if !changed {
        return Ok(false);
    }
    config.mode = NotificationTransportMode::Direct;
    storage.providers.insert(
        NOTIFICATION_PUSH_PROVIDER_ID.to_owned(),
        serde_json::to_value(config)
            .map_err(|error| malformed_notification_push(error.to_string()))?,
    );
    save_auth_storage(path, &mut storage)?;
    Ok(true)
}

fn mutate_notification_push_config(
    path: &Path,
    mutation: impl FnOnce(Option<NotificationPushConfig>) -> NotificationPushConfig,
) -> Result<NotificationPushConfig, AuthError> {
    let _lock = acquire_auth_file_lock(path)?;
    let mut storage = load_or_init_for_write(path)?;
    let current = storage
        .providers
        .get(NOTIFICATION_PUSH_PROVIDER_ID)
        .cloned()
        .map(serde_json::from_value::<NotificationPushConfig>)
        .transpose()
        .map_err(|error| AuthError::MalformedProviderAuth {
            provider: NOTIFICATION_PUSH_PROVIDER_ID.to_owned(),
            details: error.to_string(),
        })?;
    let config = mutation(current);
    config
        .validate()
        .map_err(|details| malformed_notification_push(details))?;
    storage.providers.insert(
        NOTIFICATION_PUSH_PROVIDER_ID.to_owned(),
        serde_json::to_value(&config)
            .map_err(|error| malformed_notification_push(error.to_string()))?,
    );
    save_auth_storage(path, &mut storage)?;
    Ok(config)
}

fn malformed_notification_push(details: String) -> AuthError {
    AuthError::MalformedProviderAuth {
        provider: NOTIFICATION_PUSH_PROVIDER_ID.to_owned(),
        details,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn relay() -> NotificationRelayCredentials {
        NotificationRelayCredentials {
            url: "https://push.example.test".to_owned(),
            secret: "0123456789abcdef0123456789abcdef".to_owned(),
        }
    }

    #[test]
    fn relay_configuration_round_trips_and_clear_selects_direct() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("auth.json");
        let configured = save_notification_relay_credentials(&path, relay()).unwrap();
        assert_eq!(configured.mode, NotificationTransportMode::Relay);
        assert_eq!(
            load_notification_push_config(&path)
                .unwrap()
                .unwrap()
                .relay
                .unwrap()
                .url,
            "https://push.example.test"
        );

        assert!(clear_notification_relay_credentials(&path).unwrap());
        let cleared = load_notification_push_config(&path).unwrap().unwrap();
        assert_eq!(cleared.mode, NotificationTransportMode::Direct);
        assert!(cleared.relay.is_none());
    }

    #[test]
    fn relay_configuration_rejects_unsafe_urls_and_short_secrets() {
        for credentials in [
            NotificationRelayCredentials {
                url: "http://push.example.test".to_owned(),
                secret: relay().secret,
            },
            NotificationRelayCredentials {
                url: "https://user@push.example.test".to_owned(),
                secret: relay().secret,
            },
            NotificationRelayCredentials {
                url: "https://push.example.test/v1/push".to_owned(),
                secret: relay().secret,
            },
            NotificationRelayCredentials {
                url: relay().url,
                secret: "short".to_owned(),
            },
        ] {
            assert!(credentials.validate().is_err());
        }
    }
}
