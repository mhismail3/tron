use super::*;

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
