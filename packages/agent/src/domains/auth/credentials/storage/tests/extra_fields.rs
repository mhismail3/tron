use super::*;

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

/// Auth.json with an unknown section for testing extra-field preservation.
const AUTH_WITH_EXTRA: &str = r#"{
        "version": 1,
        "providers": {},
        "lastUpdated": "2026-01-01T00:00:00Z",
        "customMetadata": {
            "url": "https://example.invalid",
            "secret": "opaque-test-value"
        }
    }"#;

#[test]
fn extra_fields_survive_roundtrip() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);

    let mut storage = load_auth_storage(&path).unwrap().unwrap();
    save_auth_storage(&path, &mut storage).unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
    assert_eq!(raw["customMetadata"]["secret"], "opaque-test-value");
}

#[test]
fn extra_fields_survive_multiple_saves() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);

    for _ in 0..3 {
        let mut storage = load_auth_storage(&path).unwrap().unwrap();
        save_auth_storage(&path, &mut storage).unwrap();
    }

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
    assert_eq!(raw["customMetadata"]["secret"], "opaque-test-value");
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
                "customMetadata": {"url": "https://example.invalid", "secret": "s"},
                "customThing": "hello",
                "anotherField": [1, 2, 3]
            }"#,
    );

    let mut storage = load_auth_storage(&path).unwrap().unwrap();
    save_auth_storage(&path, &mut storage).unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
    assert_eq!(raw["customThing"], "hello");
    assert_eq!(raw["anotherField"], serde_json::json!([1, 2, 3]));
}

#[test]
fn save_oauth_tokens_preserves_extra() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);

    save_account_oauth_tokens(&path, "anthropic", "test", &make_tokens()).unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
    assert_eq!(raw["customMetadata"]["secret"], "opaque-test-value");
    // Also verify the tokens were saved
    assert!(raw["providers"]["anthropic"].is_object());
}

#[test]
fn save_named_api_key_preserves_extra() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);

    save_named_api_key(&path, "openai", "(default)", "sk-key").unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
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
                "customMetadata": {"url": "https://example.invalid", "secret": "s"}
            }"#,
    );

    clear_provider_auth(&path, "anthropic").unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
    assert!(raw["providers"]["anthropic"].is_null());
}

#[test]
fn remove_account_preserves_extra() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);
    save_account_oauth_tokens(&path, "anthropic", "work", &make_tokens()).unwrap();

    remove_account(&path, "anthropic", "work").unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
}

#[test]
fn set_active_credential_preserves_extra() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);
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
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
}

#[test]
fn rename_account_preserves_extra() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);
    save_account_oauth_tokens(&path, "anthropic", "old", &make_tokens()).unwrap();

    rename_account(&path, "anthropic", "old", "new").unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
}

#[test]
fn save_google_provider_auth_preserves_extra() {
    let dir = TempDir::new().unwrap();
    let path = test_path(&dir);
    write_raw_auth(&path, AUTH_WITH_EXTRA);

    let gpa = GoogleProviderAuth {
        project_id: Some("test-proj".to_string()),
        ..Default::default()
    };
    save_google_provider_auth(&path, &gpa).unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["url"], "https://example.invalid");
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
                "customMetadata": {
                    "url": "https://example.invalid",
                    "secret": "s",
                    "nested": {"deep": {"value": 42}}
                }
            }"#,
    );

    let mut storage = load_auth_storage(&path).unwrap().unwrap();
    save_auth_storage(&path, &mut storage).unwrap();

    let raw = read_raw_auth(&path);
    assert_eq!(raw["customMetadata"]["nested"]["deep"]["value"], 42);
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
