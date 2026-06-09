//! Auth storage file I/O.
//!
//! Reads and writes `~/.tron/profiles/auth.json` with secure file permissions
//! (`0o600`). Fresh Mac installs intentionally seed this file as `{}`; the
//! loader treats only that exact empty object as a pristine install sentinel and
//! materializes the normal schema on the first write.

use std::path::{Path, PathBuf};

use super::errors::AuthError;
use super::types::{
    ActiveCredential, ApiKeyEntry, AuthStorage, GoogleProviderAuth, OAuthTokens, ProviderAuth,
    ServiceAuth,
};

/// Default auth file name.
const AUTH_FILE_NAME: &str = "auth.json";

/// Get the auth file path under the given data directory.
pub fn auth_file_path(data_dir: &Path) -> PathBuf {
    data_dir.join(AUTH_FILE_NAME)
}

/// Load auth storage from file (sync).
///
/// * `Ok(None)`     — file does not exist (first-use on a clean machine).
/// * `Ok(Some(..))` — file exists, parsed successfully, version matches. An
///   exact empty JSON object (`{}`) returns a pristine [`AuthStorage::new()`]
///   so fresh installer seeds can be materialized by the first write.
/// * `Err(..)`      — read I/O failure, parse failure, or unsupported version.
///
/// INVARIANT: A parse error surfaces as [`AuthError::MalformedAuthFile`] and
/// is **never** silently treated as "no auth configured". Earlier versions
/// returned `Option<AuthStorage>` and logged a `warn!` on parse failure,
/// which silently masked the entire file and made a single malformed
/// provider or service block look like a global "no auth" state. The only
/// present-file exception is the exact empty object sentinel (`{}`). Callers
/// must distinguish "not configured" (`Ok(None)` or the pristine sentinel)
/// from "broken on disk" (`Err(_)`) — especially writers, which would otherwise
/// `unwrap_or_default()` and overwrite the user's real file with an empty
/// default.
pub fn load_auth_storage(path: &Path) -> Result<Option<AuthStorage>, AuthError> {
    let data = match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(AuthError::Io(e)),
    };

    let value = serde_json::from_str::<serde_json::Value>(&data).map_err(|e| {
        AuthError::MalformedAuthFile {
            path: path.display().to_string(),
            details: e.to_string(),
        }
    })?;
    if value.as_object().is_some_and(serde_json::Map::is_empty) {
        return Ok(Some(AuthStorage::new()));
    }

    match serde_json::from_value::<AuthStorage>(value) {
        Ok(storage) if storage.version == 1 => Ok(Some(storage)),
        Ok(storage) => Err(AuthError::MalformedAuthFile {
            path: path.display().to_string(),
            details: format!(
                "unsupported auth storage version: {} (expected 1)",
                storage.version
            ),
        }),
        Err(e) => Err(AuthError::MalformedAuthFile {
            path: path.display().to_string(),
            details: e.to_string(),
        }),
    }
}

/// Load auth storage for a write path.
///
/// Returns the parsed storage if the file exists, a fresh default if the file
/// is missing (legitimate first-use), or an error if the file is present but
/// malformed. Writers must use this helper to avoid the historical
/// `load_auth_storage(path).unwrap_or_default()` footgun, which silently
/// replaced a corrupt file with an empty default and destroyed user data.
pub fn load_or_init_for_write(path: &Path) -> Result<AuthStorage, AuthError> {
    Ok(load_auth_storage(path)?.unwrap_or_default())
}

/// Save auth storage to file (sync).
///
/// Creates parent directories if needed. Writes atomically via a temp file in
/// the same directory, created with mode 0o600 at `open(2)` time, then
/// `rename(2)`d into place. Readers observe either the prior contents or the
/// new contents — never a partial file — and the file is never world-readable
/// at any point.
///
/// INVARIANT: auth.json is 0o600 from the moment it exists on disk. The
/// atomic temp-then-rename pattern ensures there is no window where the file
/// carries wider permissions, regardless of the caller's umask.
pub fn save_auth_storage(path: &Path, storage: &mut AuthStorage) -> Result<(), AuthError> {
    storage.last_updated = chrono::Utc::now().to_rfc3339();

    let parent = path.parent().ok_or_else(|| {
        AuthError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "auth path must have a parent directory",
        ))
    })?;
    std::fs::create_dir_all(parent)?;

    let json = serde_json::to_vec_pretty(storage)
        .map_err(|error| AuthError::json("encode auth storage", error))?;
    atomic_write_0600(parent, path, &json)
}

/// Atomically write `contents` to `final_path`. The temp file is created in
/// `parent` so that `rename` is guaranteed to stay within a single filesystem.
///
/// On Unix `tempfile::Builder::tempfile_in` opens the temp file with mode 0o600
/// at `open(2)` time, so the file never exists on disk with wider permissions.
/// On any failure the temp file is cleaned up by `NamedTempFile`'s drop guard.
fn atomic_write_0600(parent: &Path, final_path: &Path, contents: &[u8]) -> Result<(), AuthError> {
    use std::io::Write as _;

    let mut tmp = tempfile::Builder::new()
        .prefix(".auth.tmp.")
        .tempfile_in(parent)?;

    tmp.write_all(contents)?;
    tmp.as_file().sync_all()?;
    let _persisted = tmp
        .persist(final_path)
        .map_err(|e| AuthError::Io(e.error))?;
    Ok(())
}

/// Get provider auth from storage file.
///
/// * `Ok(None)`      — auth file missing, or the provider is not configured.
/// * `Ok(Some(..))`  — provider is configured.
/// * `Err(..)`       — auth file is malformed on disk (propagated from
///   [`load_auth_storage`]).
pub fn get_provider_auth(path: &Path, provider: &str) -> Result<Option<ProviderAuth>, AuthError> {
    Ok(load_auth_storage(path)?.and_then(|s| s.get_provider_auth(provider)))
}

/// Get Google provider auth from storage file.
pub fn get_google_provider_auth(path: &Path) -> Result<Option<GoogleProviderAuth>, AuthError> {
    Ok(load_auth_storage(path)?.and_then(|s| s.get_google_auth()))
}

/// Strict Google provider auth getter — returns `Err` when the stored
/// shape fails to deserialize (e.g. retired `endpoint` field). Used by
/// `load_server_auth` to surface `MalformedProviderAuth` with re-auth
/// guidance instead of silently falling back to "not configured".
pub fn try_get_google_provider_auth(path: &Path) -> Result<Option<GoogleProviderAuth>, AuthError> {
    let Some(storage) = load_auth_storage(path)? else {
        return Ok(None);
    };
    storage.try_get_google_auth()
}

/// Get service auth from storage file.
pub fn get_service_auth(path: &Path, service: &str) -> Result<Option<ServiceAuth>, AuthError> {
    Ok(load_auth_storage(path)?.and_then(|s| s.get_service_auth(service).cloned()))
}

/// Get service API keys from storage file.
///
/// Returns an empty vec when the file is missing or the service is not
/// configured; propagates [`AuthError::MalformedAuthFile`] when the file
/// exists but fails to parse.
pub fn get_service_api_keys(path: &Path, service: &str) -> Result<Vec<String>, AuthError> {
    Ok(load_auth_storage(path)?
        .map(|s| s.get_service_api_keys(service))
        .unwrap_or_default())
}

/// Save OAuth tokens for a named account.
pub fn save_account_oauth_tokens(
    path: &Path,
    provider: &str,
    label: &str,
    tokens: &OAuthTokens,
) -> Result<(), AuthError> {
    let mut storage = load_or_init_for_write(path)?;
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();

    let accounts = pa.accounts.get_or_insert_with(Vec::new);
    if let Some(existing) = accounts.iter_mut().find(|a| a.label == label) {
        existing.oauth = tokens.clone();
    } else {
        accounts.push(super::types::AccountEntry {
            label: label.to_string(),
            oauth: tokens.clone(),
        });
    }

    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Rename an account label for a provider.
///
/// Also updates `active_credential` if it pointed to the old label.
pub fn rename_account(
    path: &Path,
    provider: &str,
    old_label: &str,
    new_label: &str,
) -> Result<(), AuthError> {
    let mut storage = load_or_init_for_write(path)?;
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();

    let accounts = pa.accounts.get_or_insert_with(Vec::new);
    if let Some(existing) = accounts.iter_mut().find(|a| a.label == old_label) {
        existing.label = new_label.to_string();
    } else {
        return Err(AuthError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("Account '{old_label}' not found"),
        )));
    }

    // Update active_credential if it pointed to the old label
    if pa.active_credential
        == Some(ActiveCredential::OAuth {
            label: old_label.to_string(),
        })
    {
        pa.active_credential = Some(ActiveCredential::OAuth {
            label: new_label.to_string(),
        });
    }

    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Get account labels for a provider.
pub fn get_account_labels(path: &Path, provider: &str) -> Result<Vec<String>, AuthError> {
    let Some(pa) = get_provider_auth(path, provider)? else {
        return Ok(Vec::new());
    };
    Ok(pa
        .accounts
        .map(|accts| accts.iter().map(|a| a.label.clone()).collect())
        .unwrap_or_default())
}

/// Save a named API key for a provider.
///
/// If an entry with the same label exists, updates the key. Otherwise appends.
pub fn save_named_api_key(
    path: &Path,
    provider: &str,
    label: &str,
    key: &str,
) -> Result<(), AuthError> {
    if label.is_empty() {
        return Err(AuthError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "API key label cannot be empty",
        )));
    }

    let mut storage = load_or_init_for_write(path)?;
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();

    let api_keys = pa.api_keys.get_or_insert_with(Vec::new);
    if let Some(existing) = api_keys.iter_mut().find(|k| k.label == label) {
        existing.key = key.to_string();
    } else {
        api_keys.push(ApiKeyEntry {
            label: label.to_string(),
            key: key.to_string(),
        });
    }

    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Remove a named API key by label.
///
/// If the removed key was the active credential, clears `active_credential`.
pub fn remove_named_api_key(path: &Path, provider: &str, label: &str) -> Result<(), AuthError> {
    let Some(mut storage) = load_auth_storage(path)? else {
        return Ok(());
    };
    let Some(mut pa) = storage.get_provider_auth(provider) else {
        return Ok(());
    };

    if let Some(ref mut api_keys) = pa.api_keys {
        let before = api_keys.len();
        api_keys.retain(|k| k.label != label);
        if api_keys.len() < before {
            // Check if active_credential pointed to this key
            if pa.active_credential
                == Some(ActiveCredential::ApiKey {
                    label: label.to_string(),
                })
            {
                pa.active_credential = None;
            }
        }
    }

    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Remove an OAuth account by label.
///
/// If the removed account was the active credential, clears `active_credential`.
pub fn remove_account(path: &Path, provider: &str, label: &str) -> Result<(), AuthError> {
    let Some(mut storage) = load_auth_storage(path)? else {
        return Ok(());
    };
    let Some(mut pa) = storage.get_provider_auth(provider) else {
        return Ok(());
    };

    if let Some(ref mut accounts) = pa.accounts {
        let before = accounts.len();
        accounts.retain(|a| a.label != label);
        if accounts.len() < before {
            // Clear active_credential if it pointed to the removed account
            if pa.active_credential
                == Some(ActiveCredential::OAuth {
                    label: label.to_string(),
                })
            {
                pa.active_credential = None;
            }
        }
    }

    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Set the active credential for a provider.
///
/// Validates that the referenced credential exists. Returns error if not found.
pub fn set_active_credential(
    path: &Path,
    provider: &str,
    credential: &ActiveCredential,
) -> Result<(), AuthError> {
    let mut storage = load_or_init_for_write(path)?;
    let mut pa = storage.get_provider_auth(provider).unwrap_or_default();

    // Validate the credential exists
    match credential {
        ActiveCredential::OAuth { label } => {
            let exists = pa
                .accounts
                .as_ref()
                .is_some_and(|accts| accts.iter().any(|a| a.label == *label));
            if !exists {
                return Err(AuthError::Io(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    format!("OAuth account '{label}' not found for provider '{provider}'"),
                )));
            }
        }
        ActiveCredential::ApiKey { label } => {
            let exists = pa
                .api_keys
                .as_ref()
                .is_some_and(|keys| keys.iter().any(|k| k.label == *label));
            if !exists {
                return Err(AuthError::Io(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    format!("API key '{label}' not found for provider '{provider}'"),
                )));
            }
        }
    }

    pa.active_credential = Some(credential.clone());
    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Clear the active credential for a provider (falls back to default priority).
pub fn clear_active_credential(path: &Path, provider: &str) -> Result<(), AuthError> {
    let Some(mut storage) = load_auth_storage(path)? else {
        return Ok(());
    };
    let Some(mut pa) = storage.get_provider_auth(provider) else {
        return Ok(());
    };

    pa.active_credential = None;
    storage.save_provider_base(provider, &pa);
    save_auth_storage(path, &mut storage)
}

/// Get the active credential for a provider.
pub fn get_active_credential(
    path: &Path,
    provider: &str,
) -> Result<Option<ActiveCredential>, AuthError> {
    Ok(get_provider_auth(path, provider)?.and_then(|pa| pa.active_credential))
}

/// Save Google-specific provider auth.
pub fn save_google_provider_auth(path: &Path, auth: &GoogleProviderAuth) -> Result<(), AuthError> {
    let mut storage = load_or_init_for_write(path)?;
    storage.set_google_auth(auth);
    save_auth_storage(path, &mut storage)
}

/// Clear auth for a specific provider.
pub fn clear_provider_auth(path: &Path, provider: &str) -> Result<(), AuthError> {
    let Some(mut storage) = load_auth_storage(path)? else {
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

/// RAII guard that holds an advisory file lock. Lock released on drop.
pub struct AuthFileLock {
    _file: std::fs::File,
}

/// Acquire a blocking exclusive advisory lock for the built-in auth store.
///
/// Uses `flock(2)` to coordinate token refresh across multiple Tron server
/// processes on the same machine. The lock file is created if absent (0o600).
/// The lock is released when the returned guard is dropped.
#[allow(unsafe_code)]
pub fn acquire_auth_file_lock(auth_path: &Path) -> std::io::Result<AuthFileLock> {
    use std::os::unix::io::AsRawFd;

    let lock_path = auth_file_lock_path(auth_path);
    if let Some(parent) = lock_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&lock_path)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600));
    }

    let ret = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX) };
    if ret != 0 {
        return Err(std::io::Error::last_os_error());
    }

    Ok(AuthFileLock { _file: lock_file })
}

fn auth_file_lock_path(auth_path: &Path) -> std::path::PathBuf {
    let Some(parent) = auth_path.parent() else {
        return auth_path.with_extension("lock");
    };

    if parent.file_name().and_then(|name| name.to_str()) == Some("profiles")
        && let Some(home) = parent.parent()
    {
        return crate::shared::foundation::paths::auth_lock_path_for_home(home);
    }

    if parent.file_name().and_then(|name| name.to_str()) == Some("vault")
        && let Some(workspace) = parent.parent()
        && workspace.file_name().and_then(|name| name.to_str()) == Some("workspace")
        && let Some(home) = workspace.parent()
    {
        return crate::shared::foundation::paths::auth_lock_path_for_home(home);
    }

    parent.join("run/auth.lock")
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests;
