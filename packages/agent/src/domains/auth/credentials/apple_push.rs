//! Apple Push Notification service provider-token credentials.
//!
//! These are Tron-owned transport credentials, not worker secrets or model
//! provider accounts. They live in the strict `auth.json` provider map under
//! `apple-push`, are written under the canonical auth-file lock, and are never
//! included in masked client auth projections.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{
    AuthError, acquire_auth_file_lock, load_auth_storage, load_or_init_for_write, save_auth_storage,
};

pub(crate) const APPLE_PUSH_PROVIDER_ID: &str = "apple-push";

/// Token-signing credential used by the engine's APNs transport.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ApplePushCredentials {
    pub(crate) team_id: String,
    pub(crate) key_id: String,
    pub(crate) private_key: String,
}

impl ApplePushCredentials {
    pub(crate) fn validate(&self) -> Result<(), String> {
        validate_apple_identifier(&self.team_id, "team ID")?;
        validate_apple_identifier(&self.key_id, "key ID")?;
        let key = self.private_key.trim();
        if !key.starts_with("-----BEGIN PRIVATE KEY-----")
            || !key.ends_with("-----END PRIVATE KEY-----")
        {
            return Err("APNs private key must be a PKCS#8 PEM private key".to_owned());
        }
        Ok(())
    }
}

pub(crate) fn load_apple_push_credentials(
    path: &Path,
) -> Result<Option<ApplePushCredentials>, AuthError> {
    let Some(storage) = load_auth_storage(path)? else {
        return Ok(None);
    };
    match storage.providers.get(APPLE_PUSH_PROVIDER_ID) {
        None => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|error| AuthError::MalformedProviderAuth {
                provider: APPLE_PUSH_PROVIDER_ID.to_owned(),
                details: error.to_string(),
            }),
    }
}

pub(crate) fn save_apple_push_credentials(
    path: &Path,
    credentials: &ApplePushCredentials,
) -> Result<(), AuthError> {
    credentials
        .validate()
        .map_err(|details| AuthError::MalformedProviderAuth {
            provider: APPLE_PUSH_PROVIDER_ID.to_owned(),
            details,
        })?;
    let _lock = acquire_auth_file_lock(path)?;
    let mut storage = load_or_init_for_write(path)?;
    let encoded =
        serde_json::to_value(credentials).map_err(|error| AuthError::MalformedProviderAuth {
            provider: APPLE_PUSH_PROVIDER_ID.to_owned(),
            details: error.to_string(),
        })?;
    let _ = storage
        .providers
        .insert(APPLE_PUSH_PROVIDER_ID.to_owned(), encoded);
    save_auth_storage(path, &mut storage)
}

pub(crate) fn clear_apple_push_credentials(path: &Path) -> Result<bool, AuthError> {
    let _lock = acquire_auth_file_lock(path)?;
    let Some(mut storage) = load_auth_storage(path)? else {
        return Ok(false);
    };
    let changed = storage.providers.remove(APPLE_PUSH_PROVIDER_ID).is_some();
    if changed {
        save_auth_storage(path, &mut storage)?;
    }
    Ok(changed)
}

fn validate_apple_identifier(value: &str, description: &str) -> Result<(), String> {
    let value = value.trim();
    if value.is_empty()
        || value.len() > 64
        || !value
            .chars()
            .all(|character| character.is_ascii_uppercase() || character.is_ascii_digit())
    {
        return Err(format!(
            "APNs {description} must contain only uppercase ASCII letters and digits"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn credentials() -> ApplePushCredentials {
        ApplePushCredentials {
            team_id: "TEAM123456".to_owned(),
            key_id: "KEY1234567".to_owned(),
            private_key: "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----"
                .to_owned(),
        }
    }

    #[test]
    fn apple_push_credentials_round_trip_without_touching_other_auth() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("auth.json");
        let mut storage = load_or_init_for_write(&path).unwrap();
        storage.providers.insert(
            "concurrent-test".to_owned(),
            serde_json::json!({"marker":"kept"}),
        );
        save_auth_storage(&path, &mut storage).unwrap();

        save_apple_push_credentials(&path, &credentials()).unwrap();
        let loaded = load_apple_push_credentials(&path).unwrap().unwrap();
        assert_eq!(loaded.team_id, "TEAM123456");
        assert_eq!(
            load_auth_storage(&path).unwrap().unwrap().providers["concurrent-test"]["marker"],
            "kept"
        );
        assert!(clear_apple_push_credentials(&path).unwrap());
        assert!(load_apple_push_credentials(&path).unwrap().is_none());
    }
}
