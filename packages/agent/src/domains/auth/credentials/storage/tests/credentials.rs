use super::*;

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
