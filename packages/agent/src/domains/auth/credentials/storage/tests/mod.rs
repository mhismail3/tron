use super::*;
mod credentials;
mod extra_fields;
mod google;
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
    let p = auth_file_path(Path::new("/home/user/.tron/profiles"));
    assert_eq!(p, PathBuf::from("/home/user/.tron/profiles/auth.json"));
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
fn load_empty_json_object_returns_pristine_storage() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    std::fs::write(&path, "{}").unwrap();

    let storage = load_auth_storage(&path)
        .expect("empty object sentinel must load")
        .expect("present sentinel returns pristine storage");

    assert_eq!(storage.version, 1);
    assert!(storage.bearer_token.is_none());
    assert!(storage.providers.is_empty());
    assert!(storage.services.is_none());
    assert!(storage.extra.is_empty());
    assert!(
        !storage.last_updated.trim().is_empty(),
        "pristine storage must have a materializable lastUpdated"
    );
}

#[test]
fn load_or_init_for_write_accepts_empty_json_object_sentinel() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    std::fs::write(&path, "{\n}\n").unwrap();

    let storage = load_or_init_for_write(&path).unwrap();

    assert_eq!(storage.version, 1);
    assert!(storage.providers.is_empty());
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
fn load_partial_non_empty_object_returns_malformed_error() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    std::fs::write(&path, r#"{"version":1}"#).unwrap();

    let err =
        load_auth_storage(&path).expect_err("only the exact empty object is a pristine sentinel");

    assert!(matches!(err, AuthError::MalformedAuthFile { .. }));
    assert!(
        err.to_string().contains("missing field"),
        "partial auth objects must remain strict errors, got: {err}"
    );
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

/// Regression guard: a retired `services.{name}.apiKey` shape (singular
/// string field) no longer silently wipes all configured providers — it
/// produces a loud, actionable error naming the bad file. Prior to this
/// change, R2 removed the singular field from `ServiceAuth` but
/// `load_auth_storage` kept swallowing parse errors with a `warn!` and
/// returning `None`, which made every provider appear unconfigured.
#[test]
fn load_retired_services_apikey_singular_shape_surfaces_error() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    std::fs::write(
        &path,
        r#"{
                "version": 1,
                "providers": {},
                "services": {
                    "brave": { "apiKey": "retired-key-value" }
                },
                "lastUpdated": "2026-04-22T00:00:00Z"
            }"#,
    )
    .unwrap();

    let err = load_auth_storage(&path).expect_err(
        "retired singular `apiKey` shape must surface as a hard error, \
             not silently wipe all providers",
    );
    assert!(matches!(err, AuthError::MalformedAuthFile { .. }));
    let msg = err.to_string();
    assert!(
        msg.contains("unknown field") || msg.contains("apiKey") || msg.contains("missing field"),
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
            name != "auth.json" && name != "run"
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
    auth_file_lock_path(auth_path)
}

#[test]
fn auth_lock_for_profile_auth_lives_under_internal_run() {
    let dir = TempDir::new().unwrap();
    let auth_path = dir.path().join(".tron/profiles/auth.json");

    assert_eq!(
        lock_path_for(&auth_path),
        dir.path().join(".tron/internal/run/auth.lock")
    );
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
