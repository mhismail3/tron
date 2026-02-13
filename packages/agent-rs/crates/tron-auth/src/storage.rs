//! Auth storage file I/O.
//!
//! Reads and writes `~/.tron/auth.json` with secure file permissions (0o600).

use std::path::{Path, PathBuf};

use crate::errors::AuthError;
use crate::types::{AuthStorage, GoogleProviderAuth, OAuthTokens, ProviderAuth, ServiceAuth};

/// Default auth file name.
const AUTH_FILE_NAME: &str = "auth.json";

/// Get the auth file path under the given data directory.
pub fn auth_file_path(data_dir: &Path) -> PathBuf {
    data_dir.join(AUTH_FILE_NAME)
}

/// Load auth storage from file (sync).
///
/// Returns `None` if the file doesn't exist or is invalid.
pub fn load_auth_storage(path: &Path) -> Option<AuthStorage> {
    let data = match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            tracing::warn!("failed to read auth file: {e}");
            return None;
        }
    };

    match serde_json::from_str::<AuthStorage>(&data) {
        Ok(storage) if storage.version == 1 => Some(storage),
        Ok(storage) => {
            tracing::warn!("unsupported auth storage version: {}", storage.version);
            None
        }
        Err(e) => {
            tracing::warn!("failed to parse auth file: {e}");
            None
        }
    }
}

/// Save auth storage to file (sync).
///
/// Creates parent directories if needed. Sets file permissions to 0o600.
pub fn save_auth_storage(path: &Path, storage: &mut AuthStorage) -> Result<(), AuthError> {
    storage.last_updated = chrono::Utc::now().to_rfc3339();

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let json = serde_json::to_string_pretty(storage)?;
    std::fs::write(path, &json)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        let _ = std::fs::set_permissions(path, perms);
    }

    Ok(())
}

/// Get provider auth from storage file.
pub fn get_provider_auth(path: &Path, provider: &str) -> Option<ProviderAuth> {
    load_auth_storage(path)?.get_provider_auth(provider)
}

/// Get Google provider auth from storage file.
pub fn get_google_provider_auth(path: &Path) -> Option<GoogleProviderAuth> {
    load_auth_storage(path)?.get_google_auth()
}

/// Get service auth from storage file.
pub fn get_service_auth(path: &Path, service: &str) -> Option<ServiceAuth> {
    load_auth_storage(path)?
        .get_service_auth(service)
        .cloned()
}

/// Get service API keys from storage file.
pub fn get_service_api_keys(path: &Path, service: &str) -> Vec<String> {
    load_auth_storage(path)
        .map(|s| s.get_service_api_keys(service))
        .unwrap_or_default()
}

/// Save OAuth tokens for a provider.
///
/// Loads existing storage, patches the provider's OAuth tokens, and saves.
pub fn save_provider_oauth_tokens(
    path: &Path,
    provider: &str,
    tokens: &OAuthTokens,
) -> Result<(), AuthError> {
    let mut storage = load_auth_storage(path).unwrap_or_default();
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();
    pa.oauth = Some(tokens.clone());
    storage.set_provider_auth(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Save an API key for a provider.
pub fn save_provider_api_key(
    path: &Path,
    provider: &str,
    api_key: &str,
) -> Result<(), AuthError> {
    let mut storage = load_auth_storage(path).unwrap_or_default();
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();
    pa.api_key = Some(api_key.to_string());
    storage.set_provider_auth(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Save OAuth tokens for a named account.
pub fn save_account_oauth_tokens(
    path: &Path,
    provider: &str,
    label: &str,
    tokens: &OAuthTokens,
) -> Result<(), AuthError> {
    let mut storage = load_auth_storage(path).unwrap_or_default();
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();

    let accounts = pa.accounts.get_or_insert_with(Vec::new);
    if let Some(existing) = accounts.iter_mut().find(|a| a.label == label) {
        existing.oauth = tokens.clone();
    } else {
        accounts.push(crate::types::AccountEntry {
            label: label.to_string(),
            oauth: tokens.clone(),
        });
    }

    storage.set_provider_auth(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Get account labels for a provider.
pub fn get_account_labels(path: &Path, provider: &str) -> Vec<String> {
    let Some(pa) = get_provider_auth(path, provider) else {
        return Vec::new();
    };
    pa.accounts
        .map(|accts| accts.iter().map(|a| a.label.clone()).collect())
        .unwrap_or_default()
}

/// Save Google-specific provider auth.
pub fn save_google_provider_auth(
    path: &Path,
    auth: &GoogleProviderAuth,
) -> Result<(), AuthError> {
    let mut storage = load_auth_storage(path).unwrap_or_default();
    storage.set_google_auth(auth);
    save_auth_storage(path, &mut storage)
}

/// Clear auth for a specific provider.
pub fn clear_provider_auth(path: &Path, provider: &str) -> Result<(), AuthError> {
    let Some(mut storage) = load_auth_storage(path) else {
        return Ok(());
    };
    let _ = storage.providers.remove(provider);
    save_auth_storage(path, &mut storage)
}

/// Delete the entire auth file.
pub fn clear_all_auth(path: &Path) -> Result<(), AuthError> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(AuthError::Io(e)),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_path(dir: &TempDir) -> PathBuf {
        dir.path().join("auth.json")
    }

    fn make_tokens() -> OAuthTokens {
        OAuthTokens {
            access_token: "tok".to_string(),
            refresh_token: "ref".to_string(),
            expires_at: 999_999,
        }
    }

    #[test]
    fn auth_file_path_construction() {
        let p = auth_file_path(Path::new("/home/user/.tron"));
        assert_eq!(p, PathBuf::from("/home/user/.tron/auth.json"));
    }

    #[test]
    fn load_missing_file_returns_none() {
        let dir = TempDir::new().unwrap();
        assert!(load_auth_storage(&test_path(&dir)).is_none());
    }

    #[test]
    fn load_invalid_json_returns_none() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        std::fs::write(&path, "not json").unwrap();
        assert!(load_auth_storage(&path).is_none());
    }

    #[test]
    fn load_wrong_version_returns_none() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        std::fs::write(
            &path,
            r#"{"version":2,"providers":{},"lastUpdated":"2024-01-01T00:00:00Z"}"#,
        )
        .unwrap();
        assert!(load_auth_storage(&path).is_none());
    }

    #[test]
    fn save_and_load_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let mut storage = AuthStorage::new();
        let pa = ProviderAuth {
            api_key: Some("sk-123".to_string()),
            ..Default::default()
        };
        storage.set_provider_auth("anthropic", &pa);
        save_auth_storage(&path, &mut storage).unwrap();

        let loaded = load_auth_storage(&path).unwrap();
        assert_eq!(loaded.version, 1);
        let restored = loaded.get_provider_auth("anthropic").unwrap();
        assert_eq!(restored.api_key.as_deref(), Some("sk-123"));
    }

    #[test]
    fn save_creates_parent_dirs() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("dir").join("auth.json");
        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();
        assert!(path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn save_sets_permissions_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();
        let perms = std::fs::metadata(&path).unwrap().permissions();
        assert_eq!(perms.mode() & 0o777, 0o600);
    }

    #[test]
    fn save_provider_oauth_tokens_patches() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        // Save API key first
        save_provider_api_key(&path, "anthropic", "sk-123").unwrap();

        // Then add OAuth tokens
        let tokens = make_tokens();
        save_provider_oauth_tokens(&path, "anthropic", &tokens).unwrap();

        // Both should be present
        let pa = get_provider_auth(&path, "anthropic").unwrap();
        assert_eq!(pa.api_key.as_deref(), Some("sk-123"));
        assert_eq!(pa.oauth.unwrap().access_token, "tok");
    }

    #[test]
    fn save_account_oauth_tokens_creates_new() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let tokens = make_tokens();
        save_account_oauth_tokens(&path, "anthropic", "work", &tokens).unwrap();

        let labels = get_account_labels(&path, "anthropic");
        assert_eq!(labels, vec!["work"]);
    }

    #[test]
    fn save_account_oauth_tokens_updates_existing() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let tokens1 = make_tokens();
        save_account_oauth_tokens(&path, "anthropic", "work", &tokens1).unwrap();

        let tokens2 = OAuthTokens {
            access_token: "new-tok".to_string(),
            ..make_tokens()
        };
        save_account_oauth_tokens(&path, "anthropic", "work", &tokens2).unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap();
        let accounts = pa.accounts.unwrap();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].oauth.access_token, "new-tok");
    }

    #[test]
    fn get_service_api_keys_from_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let mut storage = AuthStorage::new();
        let mut services = std::collections::HashMap::new();
        let _ = services.insert(
            "brave".to_string(),
            ServiceAuth {
                api_key: Some("key1".to_string()),
                api_keys: None,
            },
        );
        storage.services = Some(services);
        save_auth_storage(&path, &mut storage).unwrap();

        let keys = get_service_api_keys(&path, "brave");
        assert_eq!(keys, vec!["key1"]);
    }

    #[test]
    fn clear_provider_auth_removes_one() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_provider_api_key(&path, "anthropic", "sk-a").unwrap();
        save_provider_api_key(&path, "openai", "sk-o").unwrap();

        clear_provider_auth(&path, "anthropic").unwrap();

        assert!(get_provider_auth(&path, "anthropic").is_none());
        assert!(get_provider_auth(&path, "openai").is_some());
    }

    #[test]
    fn clear_all_auth_deletes_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();
        assert!(path.exists());

        clear_all_auth(&path).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn clear_all_auth_noop_missing_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        assert!(clear_all_auth(&path).is_ok());
    }

    #[test]
    fn clear_provider_auth_noop_missing_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        assert!(clear_provider_auth(&path, "anthropic").is_ok());
    }

    #[test]
    fn get_google_provider_auth_from_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        use crate::types::GoogleOAuthEndpoint;
        let gpa = GoogleProviderAuth {
            endpoint: Some(GoogleOAuthEndpoint::Antigravity),
            project_id: Some("proj-123".to_string()),
            ..Default::default()
        };
        save_google_provider_auth(&path, &gpa).unwrap();

        let loaded = get_google_provider_auth(&path).unwrap();
        assert_eq!(
            loaded.endpoint,
            Some(GoogleOAuthEndpoint::Antigravity)
        );
        assert_eq!(loaded.project_id.as_deref(), Some("proj-123"));
    }
}
