//! Auth storage file I/O.
//!
//! Reads and writes `~/.tron/system/auth.json` with secure file permissions (0o600).

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
/// * `Ok(Some(..))` — file exists, parsed successfully, version matches.
/// * `Err(..)`      — read I/O failure, parse failure, or unsupported version.
///
/// INVARIANT: A parse error surfaces as [`AuthError::MalformedAuthFile`] and
/// is **never** silently treated as "no auth configured". Earlier versions
/// returned `Option<AuthStorage>` and logged a `warn!` on parse failure,
/// which silently masked the entire file and made a single malformed
/// provider or service block look like a global "no auth" state. Callers
/// must distinguish "not configured" (`Ok(None)`) from "broken on disk"
/// (`Err(_)`) — especially writers, which would otherwise `unwrap_or_default()`
/// and overwrite the user's real file with an empty default.
pub fn load_auth_storage(path: &Path) -> Result<Option<AuthStorage>, AuthError> {
    let data = match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(AuthError::Io(e)),
    };

    match serde_json::from_str::<AuthStorage>(&data) {
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

    let json = serde_json::to_vec_pretty(storage)?;
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
/// shape fails to deserialize (e.g. legacy `endpoint` field). Used by
/// `load_server_auth` to surface `MalformedProviderAuth` with re-auth
/// guidance instead of silently falling back to "not configured".
pub fn try_get_google_provider_auth(path: &Path) -> Result<Option<GoogleProviderAuth>, AuthError> {
    let Some(storage) = load_auth_storage(path)? else {
        return Ok(None);
    };
    storage
        .try_get_google_auth()
        .map_err(|e| AuthError::MalformedProviderAuth {
            provider: "google".into(),
            details: e.to_string(),
        })
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

/// Acquire a blocking exclusive advisory lock on `{auth_path}.lock`.
///
/// Uses `flock(2)` to coordinate token refresh across multiple Tron server
/// processes on the same machine. The lock file is created if absent (0o600).
/// The lock is released when the returned guard is dropped.
#[allow(unsafe_code)]
pub fn acquire_auth_file_lock(auth_path: &Path) -> std::io::Result<AuthFileLock> {
    use std::os::unix::io::AsRawFd;

    // Place lock file in system/deployment/ to keep ~/.tron/ clean.
    let lock_path = auth_path
        .parent()
        .unwrap_or(auth_path)
        .join("deployment/auth.lock");
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
        let p = auth_file_path(Path::new("/home/user/.tron/system"));
        assert_eq!(p, PathBuf::from("/home/user/.tron/system/auth.json"));
    }

    #[test]
    fn load_missing_file_returns_ok_none() {
        let dir = TempDir::new().unwrap();
        let result = load_auth_storage(&test_path(&dir)).unwrap();
        assert!(
            result.is_none(),
            "missing file must be Ok(None), not an error"
        );
    }

    #[test]
    fn load_invalid_json_returns_malformed_error() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        std::fs::write(&path, "not json").unwrap();
        let err = load_auth_storage(&path).expect_err("must surface parse error, not None");
        assert!(matches!(err, AuthError::MalformedAuthFile { .. }));
        let msg = err.to_string();
        assert!(msg.contains("malformed auth file"), "message: {msg}");
        assert!(msg.contains(&path.display().to_string()), "message: {msg}");
    }

    #[test]
    fn load_wrong_version_returns_malformed_error() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        std::fs::write(
            &path,
            r#"{"version":2,"providers":{},"lastUpdated":"2024-01-01T00:00:00Z"}"#,
        )
        .unwrap();
        let err = load_auth_storage(&path).expect_err("version mismatch must be a hard error");
        assert!(matches!(err, AuthError::MalformedAuthFile { .. }));
        assert!(err.to_string().contains("version: 2"));
    }

    #[test]
    fn save_and_load_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "(default)", "sk-123").unwrap();

        let loaded = load_auth_storage(&path).unwrap().unwrap();
        assert_eq!(loaded.version, 1);
        let restored = loaded.get_provider_auth("anthropic").unwrap();
        assert_eq!(restored.api_keys.as_ref().unwrap()[0].key, "sk-123");
    }

    /// Regression guard: a legacy `services.{name}.apiKey` shape (singular
    /// string field) no longer silently wipes all configured providers — it
    /// produces a loud, actionable error naming the bad file. Prior to this
    /// change, R2 removed the singular field from `ServiceAuth` but
    /// `load_auth_storage` kept swallowing parse errors with a `warn!` and
    /// returning `None`, which made every provider appear unconfigured.
    #[test]
    fn load_legacy_services_apikey_singular_shape_surfaces_error() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        std::fs::write(
            &path,
            r#"{
                "version": 1,
                "providers": {},
                "services": {
                    "brave": { "apiKey": "legacy-key-value" }
                },
                "lastUpdated": "2026-04-22T00:00:00Z"
            }"#,
        )
        .unwrap();

        let err = load_auth_storage(&path).expect_err(
            "legacy singular `apiKey` shape must surface as a hard error, \
             not silently wipe all providers",
        );
        assert!(matches!(err, AuthError::MalformedAuthFile { .. }));
        let msg = err.to_string();
        assert!(
            msg.contains("unknown field")
                || msg.contains("apiKey")
                || msg.contains("missing field"),
            "error must name the offending field. got: {msg}"
        );
    }

    /// Regression guard: a parse failure must NOT be silently absorbed by
    /// writers using `load_or_init_for_write` — otherwise saving new tokens
    /// would overwrite a broken-but-recoverable auth file with an empty
    /// default, destroying user data.
    #[test]
    fn load_or_init_for_write_refuses_to_overwrite_malformed_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        std::fs::write(&path, "{ corrupt").unwrap();

        let err = load_or_init_for_write(&path)
            .expect_err("writer helper must refuse a malformed file to prevent data loss");
        assert!(matches!(err, AuthError::MalformedAuthFile { .. }));
    }

    /// Missing file is a legitimate first-use case — `load_or_init_for_write`
    /// returns a fresh default so the caller can write for the first time.
    #[test]
    fn load_or_init_for_write_returns_default_for_missing_file() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        let storage = load_or_init_for_write(&path).unwrap();
        assert_eq!(storage.version, 1);
        assert!(storage.providers.is_empty());
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

    #[cfg(unix)]
    #[test]
    fn save_leaves_no_temp_artifacts_on_success() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();

        let leftovers: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| {
                let name = e.file_name();
                let name = name.to_string_lossy();
                name != "auth.json" && name != "deployment"
            })
            .map(|e| e.file_name())
            .collect();
        assert!(
            leftovers.is_empty(),
            "unexpected files left by save: {leftovers:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn save_cleans_tmp_on_write_failure() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let readonly = dir.path().join("readonly");
        std::fs::create_dir(&readonly).unwrap();
        std::fs::set_permissions(&readonly, std::fs::Permissions::from_mode(0o500)).unwrap();

        let target = readonly.join("auth.json");
        let mut storage = AuthStorage::new();
        let result = save_auth_storage(&target, &mut storage);

        std::fs::set_permissions(&readonly, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(result.is_err(), "save into read-only parent must fail");

        let leftovers: Vec<_> = std::fs::read_dir(&readonly)
            .unwrap()
            .filter_map(Result::ok)
            .map(|e| e.file_name())
            .collect();
        assert!(
            leftovers.is_empty(),
            "no temp files should remain after failed save: {leftovers:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn save_is_atomic_under_concurrent_readers() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "seed", "sk-seed").unwrap();

        let stop = Arc::new(AtomicBool::new(false));
        let bad_reads = Arc::new(std::sync::atomic::AtomicU32::new(0));

        let reader = {
            let path = path.clone();
            let stop = Arc::clone(&stop);
            let bad_reads = Arc::clone(&bad_reads);
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    if let Ok(content) = std::fs::read_to_string(&path)
                        && serde_json::from_str::<AuthStorage>(&content).is_err()
                    {
                        bad_reads.fetch_add(1, Ordering::Relaxed);
                    }
                }
            })
        };

        for i in 0..100 {
            save_named_api_key(&path, "anthropic", &format!("k-{i}"), &format!("sk-{i}")).unwrap();
        }

        stop.store(true, Ordering::Relaxed);
        reader.join().unwrap();

        assert_eq!(
            bad_reads.load(Ordering::Relaxed),
            0,
            "reader saw invalid JSON — write was not atomic"
        );
    }

    #[cfg(unix)]
    #[test]
    fn save_over_existing_wider_permissions_narrows_to_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        std::fs::write(&path, "{}").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o644
        );

        let mut storage = AuthStorage::new();
        save_auth_storage(&path, &mut storage).unwrap();

        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600,
            "atomic save must rewrite permissions to 0o600 regardless of prior mode"
        );
    }

    #[test]
    fn save_account_and_api_key_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-123").unwrap();
        let tokens = make_tokens();
        save_account_oauth_tokens(&path, "anthropic", "main", &tokens).unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        let api_keys = pa.api_keys.unwrap();
        assert_eq!(api_keys[0].label, "work");
        assert_eq!(api_keys[0].key, "sk-123");
        let accounts = pa.accounts.unwrap();
        assert_eq!(accounts[0].label, "main");
        assert_eq!(accounts[0].oauth.access_token, "tok");
    }

    #[test]
    fn save_account_oauth_tokens_creates_new() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let tokens = make_tokens();
        save_account_oauth_tokens(&path, "anthropic", "work", &tokens).unwrap();

        let labels = get_account_labels(&path, "anthropic").unwrap();
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

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
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
        let _ = services.insert("brave".to_string(), ServiceAuth::from_single("key1"));
        storage.services = Some(services);
        save_auth_storage(&path, &mut storage).unwrap();

        let keys = get_service_api_keys(&path, "brave").unwrap();
        assert_eq!(keys, vec!["key1"]);
    }

    #[test]
    fn clear_provider_auth_removes_one() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "(default)", "sk-a").unwrap();
        save_named_api_key(&path, "openai", "(default)", "sk-o").unwrap();

        clear_provider_auth(&path, "anthropic").unwrap();

        assert!(get_provider_auth(&path, "anthropic").unwrap().is_none());
        assert!(get_provider_auth(&path, "openai").unwrap().is_some());
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

        let gpa = GoogleProviderAuth {
            project_id: Some("proj-123".to_string()),
            ..Default::default()
        };
        save_google_provider_auth(&path, &gpa).unwrap();

        let loaded = get_google_provider_auth(&path).unwrap().unwrap();
        assert_eq!(loaded.project_id.as_deref(), Some("proj-123"));
    }

    /// Helper: derive the lock path the same way `acquire_auth_file_lock` does.
    fn lock_path_for(auth_path: &Path) -> std::path::PathBuf {
        auth_path
            .parent()
            .unwrap_or(auth_path)
            .join("deployment/auth.lock")
    }

    #[allow(unsafe_code)]
    #[test]
    fn file_lock_is_exclusive() {
        use std::os::unix::io::AsRawFd;

        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        let _lock = acquire_auth_file_lock(&path).unwrap();

        // Try non-blocking lock from another fd — should fail
        let lock_path = lock_path_for(&path);
        let lock_file2 = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&lock_path)
            .unwrap();
        let ret = unsafe { libc::flock(lock_file2.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        assert_ne!(ret, 0, "second lock should fail with LOCK_NB");

        drop(_lock);

        // Now it should succeed
        let ret = unsafe { libc::flock(lock_file2.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        assert_eq!(ret, 0, "lock should succeed after first lock dropped");
    }

    // ── Named API keys ──

    #[test]
    fn save_named_api_key_creates_new() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-work-123").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        let keys = pa.api_keys.unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].label, "work");
        assert_eq!(keys[0].key, "sk-work-123");
    }

    #[test]
    fn save_named_api_key_updates_existing() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-old").unwrap();
        save_named_api_key(&path, "anthropic", "work", "sk-new").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        let keys = pa.api_keys.unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].key, "sk-new");
    }

    #[test]
    fn save_named_api_key_multiple_labels() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-w").unwrap();
        save_named_api_key(&path, "anthropic", "personal", "sk-p").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        let keys = pa.api_keys.unwrap();
        assert_eq!(keys.len(), 2);
    }

    #[test]
    fn save_named_api_key_empty_label_errors() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let result = save_named_api_key(&path, "anthropic", "", "sk-123");
        assert!(result.is_err());
    }

    #[test]
    fn remove_named_api_key_removes() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-w").unwrap();
        save_named_api_key(&path, "anthropic", "personal", "sk-p").unwrap();

        remove_named_api_key(&path, "anthropic", "work").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        let keys = pa.api_keys.unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].label, "personal");
    }

    #[test]
    fn remove_named_api_key_nonexistent_noop() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-w").unwrap();
        remove_named_api_key(&path, "anthropic", "nonexistent").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert_eq!(pa.api_keys.unwrap().len(), 1);
    }

    #[test]
    fn remove_named_api_key_clears_active_if_pointing_to_removed() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-w").unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::ApiKey {
                label: "work".to_string(),
            },
        )
        .unwrap();

        remove_named_api_key(&path, "anthropic", "work").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert!(pa.active_credential.is_none());
    }

    #[test]
    fn remove_named_api_key_preserves_active_if_pointing_elsewhere() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-w").unwrap();
        save_named_api_key(&path, "anthropic", "personal", "sk-p").unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::ApiKey {
                label: "personal".to_string(),
            },
        )
        .unwrap();

        remove_named_api_key(&path, "anthropic", "work").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert_eq!(
            pa.active_credential,
            Some(ActiveCredential::ApiKey {
                label: "personal".to_string()
            })
        );
    }

    // ── Remove account ──

    #[test]
    fn remove_account_removes() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "acct1", &make_tokens()).unwrap();
        save_account_oauth_tokens(&path, "anthropic", "acct2", &make_tokens()).unwrap();

        remove_account(&path, "anthropic", "acct1").unwrap();

        let labels = get_account_labels(&path, "anthropic").unwrap();
        assert_eq!(labels, vec!["acct2"]);
    }

    #[test]
    fn remove_account_clears_active_if_pointing_to_removed() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "main", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "main".to_string(),
            },
        )
        .unwrap();

        remove_account(&path, "anthropic", "main").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert!(pa.active_credential.is_none());
    }

    #[test]
    fn remove_account_preserves_active_if_pointing_elsewhere() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "acct1", &make_tokens()).unwrap();
        save_account_oauth_tokens(&path, "anthropic", "acct2", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "acct2".to_string(),
            },
        )
        .unwrap();

        remove_account(&path, "anthropic", "acct1").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert_eq!(
            pa.active_credential,
            Some(ActiveCredential::OAuth {
                label: "acct2".to_string()
            })
        );
    }

    #[test]
    fn rename_account_updates_active_credential() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "old-name", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "old-name".to_string(),
            },
        )
        .unwrap();

        rename_account(&path, "anthropic", "old-name", "new-name").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert_eq!(
            pa.active_credential,
            Some(ActiveCredential::OAuth {
                label: "new-name".to_string()
            })
        );
    }

    #[test]
    fn rename_account_preserves_active_if_different_account() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "acct1", &make_tokens()).unwrap();
        save_account_oauth_tokens(&path, "anthropic", "acct2", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "acct2".to_string(),
            },
        )
        .unwrap();

        rename_account(&path, "anthropic", "acct1", "renamed").unwrap();

        // acct2 should still be active
        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert_eq!(
            pa.active_credential,
            Some(ActiveCredential::OAuth {
                label: "acct2".to_string()
            })
        );
    }

    #[test]
    fn remove_account_nonexistent_noop() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "main", &make_tokens()).unwrap();
        remove_account(&path, "anthropic", "nonexistent").unwrap();

        assert_eq!(
            get_account_labels(&path, "anthropic").unwrap(),
            vec!["main"]
        );
    }

    // ── Active credential ──

    #[test]
    fn set_active_credential_oauth() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "main", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "main".to_string(),
            },
        )
        .unwrap();

        let active = get_active_credential(&path, "anthropic").unwrap().unwrap();
        assert_eq!(
            active,
            ActiveCredential::OAuth {
                label: "main".to_string()
            }
        );
    }

    #[test]
    fn set_active_credential_api_key() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_named_api_key(&path, "anthropic", "work", "sk-w").unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::ApiKey {
                label: "work".to_string(),
            },
        )
        .unwrap();

        let active = get_active_credential(&path, "anthropic").unwrap().unwrap();
        assert_eq!(
            active,
            ActiveCredential::ApiKey {
                label: "work".to_string()
            }
        );
    }

    #[test]
    fn set_active_credential_nonexistent_oauth_errors() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let result = set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "nonexistent".to_string(),
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn set_active_credential_nonexistent_api_key_errors() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        let result = set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::ApiKey {
                label: "nonexistent".to_string(),
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn set_active_credential_oauth_but_no_accounts_errors() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        // Only an API key, no accounts
        save_named_api_key(&path, "anthropic", "key1", "sk-x").unwrap();
        let result = set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "main".to_string(),
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn clear_active_credential_works() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "main", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "main".to_string(),
            },
        )
        .unwrap();

        clear_active_credential(&path, "anthropic").unwrap();
        assert!(get_active_credential(&path, "anthropic").unwrap().is_none());
    }

    #[test]
    fn clear_active_credential_noop_missing_provider() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        assert!(clear_active_credential(&path, "anthropic").is_ok());
    }

    #[test]
    fn get_active_credential_none_when_not_set() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "main", &make_tokens()).unwrap();
        assert!(get_active_credential(&path, "anthropic").unwrap().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn file_lock_creates_lock_file_with_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        let _lock = acquire_auth_file_lock(&path).unwrap();

        let lock_path = lock_path_for(&path);
        assert!(lock_path.exists());
        let perms = std::fs::metadata(&lock_path).unwrap().permissions();
        assert_eq!(perms.mode() & 0o777, 0o600);
    }

    // ─── Extra fields preservation ────────────────────────────────────

    /// Helper: write raw JSON to auth.json, bypassing the typed struct.
    fn write_raw_auth(path: &Path, json: &str) {
        std::fs::write(path, json).unwrap();
    }

    /// Helper: read raw JSON from auth.json as a serde_json::Value.
    fn read_raw_auth(path: &Path) -> serde_json::Value {
        let content = std::fs::read_to_string(path).unwrap();
        serde_json::from_str(&content).unwrap()
    }

    /// Auth.json with a relay section for testing extra-field preservation.
    const AUTH_WITH_RELAY: &str = r#"{
        "version": 1,
        "providers": {},
        "lastUpdated": "2026-01-01T00:00:00Z",
        "relay": {
            "url": "https://relay.tron.dev",
            "secret": "hmac-shared-secret-123"
        }
    }"#;

    #[test]
    fn extra_fields_survive_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);

        let mut storage = load_auth_storage(&path).unwrap().unwrap();
        save_auth_storage(&path, &mut storage).unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
        assert_eq!(raw["relay"]["secret"], "hmac-shared-secret-123");
    }

    #[test]
    fn extra_fields_survive_multiple_saves() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);

        for _ in 0..3 {
            let mut storage = load_auth_storage(&path).unwrap().unwrap();
            save_auth_storage(&path, &mut storage).unwrap();
        }

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
        assert_eq!(raw["relay"]["secret"], "hmac-shared-secret-123");
    }

    #[test]
    fn multiple_extra_keys_preserved() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(
            &path,
            r#"{
                "version": 1,
                "providers": {},
                "lastUpdated": "2026-01-01T00:00:00Z",
                "relay": {"url": "https://relay.tron.dev", "secret": "s"},
                "customThing": "hello",
                "anotherField": [1, 2, 3]
            }"#,
        );

        let mut storage = load_auth_storage(&path).unwrap().unwrap();
        save_auth_storage(&path, &mut storage).unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
        assert_eq!(raw["customThing"], "hello");
        assert_eq!(raw["anotherField"], serde_json::json!([1, 2, 3]));
    }

    #[test]
    fn save_oauth_tokens_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);

        save_account_oauth_tokens(&path, "anthropic", "test", &make_tokens()).unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
        assert_eq!(raw["relay"]["secret"], "hmac-shared-secret-123");
        // Also verify the tokens were saved
        assert!(raw["providers"]["anthropic"].is_object());
    }

    #[test]
    fn save_named_api_key_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);

        save_named_api_key(&path, "openai", "(default)", "sk-key").unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
    }

    #[test]
    fn clear_provider_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(
            &path,
            r#"{
                "version": 1,
                "providers": {"anthropic": {"apiKeys": [{"label": "x", "key": "sk-x"}]}},
                "lastUpdated": "2026-01-01T00:00:00Z",
                "relay": {"url": "https://relay.tron.dev", "secret": "s"}
            }"#,
        );

        clear_provider_auth(&path, "anthropic").unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
        assert!(raw["providers"]["anthropic"].is_null());
    }

    #[test]
    fn remove_account_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);
        save_account_oauth_tokens(&path, "anthropic", "work", &make_tokens()).unwrap();

        remove_account(&path, "anthropic", "work").unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
    }

    #[test]
    fn set_active_credential_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);
        save_account_oauth_tokens(&path, "anthropic", "main", &make_tokens()).unwrap();

        set_active_credential(
            &path,
            "anthropic",
            &ActiveCredential::OAuth {
                label: "main".to_string(),
            },
        )
        .unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
    }

    #[test]
    fn rename_account_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);
        save_account_oauth_tokens(&path, "anthropic", "old", &make_tokens()).unwrap();

        rename_account(&path, "anthropic", "old", "new").unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
    }

    #[test]
    fn save_google_provider_auth_preserves_extra() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(&path, AUTH_WITH_RELAY);

        let gpa = GoogleProviderAuth {
            project_id: Some("test-proj".to_string()),
            ..Default::default()
        };
        save_google_provider_auth(&path, &gpa).unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["url"], "https://relay.tron.dev");
    }

    #[test]
    fn empty_extra_not_serialized() {
        let storage = AuthStorage::new();
        let json = serde_json::to_string(&storage).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Only known fields should be present
        let obj = raw.as_object().unwrap();
        for key in obj.keys() {
            assert!(
                ["version", "providers", "lastUpdated"].contains(&key.as_str()),
                "unexpected key in serialized output: {key}"
            );
        }
    }

    #[test]
    fn load_file_without_extra_fields() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(
            &path,
            r#"{"version": 1, "providers": {}, "lastUpdated": "2026-01-01T00:00:00Z"}"#,
        );

        let storage = load_auth_storage(&path).unwrap().unwrap();
        assert!(storage.extra.is_empty());
        assert_eq!(storage.version, 1);
    }

    #[test]
    fn extra_with_nested_objects() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(
            &path,
            r#"{
                "version": 1,
                "providers": {},
                "lastUpdated": "2026-01-01T00:00:00Z",
                "relay": {
                    "url": "https://relay.tron.dev",
                    "secret": "s",
                    "nested": {"deep": {"value": 42}}
                }
            }"#,
        );

        let mut storage = load_auth_storage(&path).unwrap().unwrap();
        save_auth_storage(&path, &mut storage).unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["relay"]["nested"]["deep"]["value"], 42);
    }

    #[test]
    fn extra_with_null_values() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(
            &path,
            r#"{
                "version": 1,
                "providers": {},
                "lastUpdated": "2026-01-01T00:00:00Z",
                "nullField": null
            }"#,
        );

        let mut storage = load_auth_storage(&path).unwrap().unwrap();
        save_auth_storage(&path, &mut storage).unwrap();

        let raw = read_raw_auth(&path);
        assert!(raw.get("nullField").is_some());
        assert!(raw["nullField"].is_null());
    }

    #[test]
    fn extra_with_array_values() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        write_raw_auth(
            &path,
            r#"{
                "version": 1,
                "providers": {},
                "lastUpdated": "2026-01-01T00:00:00Z",
                "tags": ["alpha", "beta", "gamma"]
            }"#,
        );

        let mut storage = load_auth_storage(&path).unwrap().unwrap();
        save_auth_storage(&path, &mut storage).unwrap();

        let raw = read_raw_auth(&path);
        assert_eq!(raw["tags"], serde_json::json!(["alpha", "beta", "gamma"]));
    }

    #[test]
    fn auth_storage_default_has_empty_extra() {
        let storage = AuthStorage::default();
        assert!(storage.extra.is_empty());
    }

    // ── Google provider-specific field preservation ──
    //
    // GoogleProviderAuth has extra fields (client_id, client_secret, project_id)
    // beyond the base ProviderAuth. Every storage mutation that writes back via
    // set_provider_auth must NOT drop these fields. These tests verify that.

    fn seed_google_with_credentials(path: &std::path::Path) {
        save_google_provider_auth(
            path,
            &GoogleProviderAuth {
                base: ProviderAuth::default(),
                client_id: Some("test-cid".into()),
                client_secret: Some("test-csec".into()),
                project_id: Some("test-proj".into()),
            },
        )
        .unwrap();
    }

    fn assert_google_fields_intact(path: &std::path::Path) {
        let gpa = get_google_provider_auth(path)
            .expect("auth file parses")
            .expect("GoogleProviderAuth should exist");
        assert_eq!(gpa.client_id.as_deref(), Some("test-cid"), "client_id lost");
        assert_eq!(
            gpa.client_secret.as_deref(),
            Some("test-csec"),
            "client_secret lost"
        );
        assert_eq!(
            gpa.project_id.as_deref(),
            Some("test-proj"),
            "project_id lost"
        );
    }

    #[test]
    fn google_fields_survive_save_oauth_tokens() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);

        save_account_oauth_tokens(&path, "google", "work", &make_tokens()).unwrap();

        assert_google_fields_intact(&path);
        let gpa = get_google_provider_auth(&path).unwrap().unwrap();
        assert_eq!(gpa.base.accounts.unwrap().len(), 1);
    }

    #[test]
    fn google_fields_survive_save_oauth_tokens_update_existing() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);
        save_account_oauth_tokens(&path, "google", "work", &make_tokens()).unwrap();

        // Update with new tokens
        let new_tokens = OAuthTokens {
            access_token: "new-tok".into(),
            refresh_token: "new-ref".into(),
            expires_at: 111_111,
        };
        save_account_oauth_tokens(&path, "google", "work", &new_tokens).unwrap();

        assert_google_fields_intact(&path);
        let gpa = get_google_provider_auth(&path).unwrap().unwrap();
        let acct = &gpa.base.accounts.unwrap()[0];
        assert_eq!(acct.oauth.access_token, "new-tok");
    }

    #[test]
    fn google_fields_survive_rename_account() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);
        save_account_oauth_tokens(&path, "google", "old-name", &make_tokens()).unwrap();

        rename_account(&path, "google", "old-name", "new-name").unwrap();

        assert_google_fields_intact(&path);
        let gpa = get_google_provider_auth(&path).unwrap().unwrap();
        assert_eq!(gpa.base.accounts.unwrap()[0].label, "new-name");
    }

    #[test]
    fn google_fields_survive_save_api_key() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);

        save_named_api_key(&path, "google", "my-key", "AIza-test").unwrap();

        assert_google_fields_intact(&path);
        let gpa = get_google_provider_auth(&path).unwrap().unwrap();
        assert_eq!(gpa.base.api_keys.unwrap()[0].key, "AIza-test");
    }

    #[test]
    fn google_fields_survive_remove_api_key() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);
        save_named_api_key(&path, "google", "my-key", "AIza-test").unwrap();

        remove_named_api_key(&path, "google", "my-key").unwrap();

        assert_google_fields_intact(&path);
    }

    #[test]
    fn google_fields_survive_remove_account() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);
        save_account_oauth_tokens(&path, "google", "acct", &make_tokens()).unwrap();

        remove_account(&path, "google", "acct").unwrap();

        assert_google_fields_intact(&path);
    }

    #[test]
    fn google_fields_survive_set_active_credential() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);
        save_account_oauth_tokens(&path, "google", "acct", &make_tokens()).unwrap();

        set_active_credential(
            &path,
            "google",
            &ActiveCredential::OAuth {
                label: "acct".into(),
            },
        )
        .unwrap();

        assert_google_fields_intact(&path);
    }

    #[test]
    fn google_fields_survive_clear_active_credential() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);
        save_account_oauth_tokens(&path, "google", "acct", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "google",
            &ActiveCredential::OAuth {
                label: "acct".into(),
            },
        )
        .unwrap();

        clear_active_credential(&path, "google").unwrap();

        assert_google_fields_intact(&path);
    }

    #[test]
    fn google_fields_survive_multiple_mutations() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);
        seed_google_with_credentials(&path);

        // Chain multiple mutations
        save_account_oauth_tokens(&path, "google", "acct1", &make_tokens()).unwrap();
        save_named_api_key(&path, "google", "key1", "AIza-1").unwrap();
        save_account_oauth_tokens(&path, "google", "acct2", &make_tokens()).unwrap();
        set_active_credential(
            &path,
            "google",
            &ActiveCredential::ApiKey {
                label: "key1".into(),
            },
        )
        .unwrap();
        remove_account(&path, "google", "acct1").unwrap();
        rename_account(&path, "google", "acct2", "main").unwrap();

        assert_google_fields_intact(&path);
        let gpa = get_google_provider_auth(&path).unwrap().unwrap();
        assert_eq!(gpa.base.accounts.as_ref().unwrap().len(), 1);
        assert_eq!(gpa.base.accounts.as_ref().unwrap()[0].label, "main");
        assert_eq!(gpa.base.api_keys.as_ref().unwrap().len(), 1);
    }

    #[test]
    fn non_google_provider_unaffected_by_save_provider_base() {
        let dir = TempDir::new().unwrap();
        let path = test_path(&dir);

        save_account_oauth_tokens(&path, "anthropic", "work", &make_tokens()).unwrap();
        save_named_api_key(&path, "anthropic", "key1", "sk-123").unwrap();

        let pa = get_provider_auth(&path, "anthropic").unwrap().unwrap();
        assert_eq!(pa.accounts.unwrap().len(), 1);
        assert_eq!(pa.api_keys.unwrap()[0].key, "sk-123");
    }
}
