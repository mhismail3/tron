use super::support::*;

#[test]
fn sol_settings_auth_secrets_lifecycle_is_source_backed() {
    let settings_store = read_repo_file("packages/agent/src/domains/settings/profile/store.rs");
    for required in [
        "static SETTINGS_WRITE_LOCK",
        "static SETTINGS_OPERATION_LOCK",
        "pub async fn operation_lock",
        "pub fn read_sparse_value",
        "pub fn reset",
        "pub fn update",
        "pub fn replace_sparse_value",
        "pub fn restore_sparse_value_for_rollback",
        "validate_sparse_settings",
        "load_settings_defaults_for(path)",
        "validate_strict()",
        "tempfile_in(parent)",
        "persist(&self.path)",
        "sync_parent_dir(parent)",
    ] {
        assert!(
            settings_store.contains(required),
            "settings store lifecycle missing `{required}`"
        );
    }

    let settings_operations =
        read_repo_file("packages/agent/src/domains/settings/profile/operations.rs");
    assert_contains_in_order(
        "settings update rollback lifecycle",
        &settings_operations,
        &[
            "settings_update_value",
            "SettingsStore::operation_lock().await",
            "read_sparse_settings_snapshot",
            "SettingsStore::new(settings_path)",
            ".update(updates)",
            "reload_profile_runtime_or_rollback",
        ],
    );
    for required in [
        "settings_reset_to_defaults_value",
        "restore_sparse_value_for_rollback",
        "rollback_sparse_settings",
        "init_settings(deps.profile_runtime.current().settings.clone())",
        "deps.profile_runtime.reload_now(reason)",
        "sparse settings were rolled back",
    ] {
        assert!(
            settings_operations.contains(required),
            "settings operation lifecycle missing `{required}`"
        );
    }

    let settings_loader =
        read_repo_file("packages/agent/src/domains/settings/profile/storage/loader.rs");
    for required in [
        "load_settings_from_path",
        "read_sparse_settings_overlay",
        "apply_env_overrides",
        "deep_merge",
        "validate_strict()",
    ] {
        assert!(
            settings_loader.contains(required),
            "settings loader lifecycle missing `{required}`"
        );
    }

    let profile_runtime =
        read_repo_file("packages/agent/src/domains/agent/loop/profile_runtime.rs");
    for required in [
        "current: ArcSwap<ResolvedHarnessSpec>",
        "pub fn reload_now",
        "self.current.store(next.clone())",
        "crate::domains::settings::init_settings(next.settings.clone())",
        "profile runtime reload rejected; keeping previous valid spec",
        "pub fn spawn_watcher",
        "CancellationToken",
        "cancel.cancelled()",
        "fn profile_tree_hash",
        "AUTH_JSON",
        "continue;",
        "invalid_reload_keeps_previous_spec",
        "reload_updates_global_settings_snapshot",
    ] {
        assert!(
            profile_runtime.contains(required),
            "profile runtime lifecycle missing `{required}`"
        );
    }

    let auth_storage = read_repo_file("packages/agent/src/domains/auth/credentials/storage/mod.rs");
    for required in [
        "load_auth_storage",
        "serde_json::Map::is_empty",
        "AuthStorage::new()",
        "MalformedAuthFile",
        "load_or_init_for_write",
        "save_auth_storage",
        "storage.last_updated",
        "atomic_write_0600",
        "tempfile_in(parent)",
        "persist(final_path)",
        "set_permissions(&lock_path",
        "from_mode(0o600)",
        "pub fn acquire_auth_file_lock",
        "libc::flock",
        "AuthFileLock",
    ] {
        assert!(
            auth_storage.contains(required),
            "auth storage lifecycle missing `{required}`"
        );
    }

    let auth_accounts = read_repo_file("packages/agent/src/domains/auth/credentials/accounts.rs");
    for required in [
        "auth_update",
        "acquire_auth_file_lock(&auth_path)",
        "update_google_provider",
        "update_standard_provider",
        "update_service",
        "build_masked_state(&auth_path)",
        "publish_auth_updated",
        "auth_clear",
        "clear_provider_auth",
        "clear_service_auth",
    ] {
        assert!(
            auth_accounts.contains(required),
            "auth account operation lifecycle missing `{required}`"
        );
    }

    let provider_state =
        read_repo_file("packages/agent/src/domains/auth/credentials/provider_state.rs");
    for required in [
        "write_auth_and_broadcast",
        "acquire_auth_file_lock(&auth_path)",
        "mutate(&auth_path)",
        "build_masked_state(&auth_path)",
        "publish_auth_updated",
        "update_google_provider",
        "save_auth_storage(auth_path",
        "build_provider_info",
        "mask_key",
    ] {
        assert!(
            provider_state.contains(required),
            "auth provider-state lifecycle missing `{required}`"
        );
    }

    let oauth_operations = read_repo_file("packages/agent/src/domains/auth/oauth/operations.rs");
    assert_contains_in_order(
        "OAuth pending-flow lifecycle",
        &oauth_operations,
        &[
            "auth_oauth_begin",
            "flows.retain",
            "OAUTH_FLOW_TTL_SECS",
            "flows.insert",
            "PendingOAuthFlow",
            "auth_oauth_complete",
            "flows.remove(&flow_id)",
            "flow.created_at.elapsed() >",
            "OAUTH_FLOW_TTL_SECS",
            "auth::oauth_complete",
            "acquire_auth_file_lock(&auth_path)",
            "save_account_oauth_tokens",
            "publish_auth_updated",
        ],
    );
    let oauth_mod = read_repo_file("packages/agent/src/domains/auth/oauth/mod.rs");
    assert!(
        oauth_mod.contains("pub(crate) const OAUTH_FLOW_TTL_SECS: u64 = 600"),
        "OAuth pending-flow TTL must remain explicit"
    );

    let onboarding = read_repo_file("packages/agent/src/app/lifecycle/onboarding/mod.rs");
    assert_contains_in_order(
        "bearer-token auth storage lifecycle",
        &onboarding,
        &[
            "load_or_create_bearer_token",
            "read_token(path)",
            "rotate_lock().lock()",
            "load_or_init_for_write(path)",
            "generate_bearer_token()",
            "save_auth_storage(path",
            "rotate_bearer_token",
            "load_or_init_for_write(path)",
            "save_auth_storage(path",
        ],
    );
    for required in [
        "TOKEN_BYTE_LEN: usize = 32",
        "ENCODED_TOKEN_LEN: usize = 43",
        "non_empty_token",
        "rotate_lock()",
        "OnceLock<Mutex<()>>",
    ] {
        assert!(
            onboarding.contains(required),
            "bearer-token onboarding lifecycle missing `{required}`"
        );
    }

    let http_auth = read_repo_file("packages/agent/src/transport/http/auth.rs");
    for required in [
        "cached: Mutex<Option<CachedToken>>",
        "std::fs::metadata(&self.path)",
        "cached.mtime == disk",
        "load_or_create_bearer_token(&self.path)",
        "tokens_eq(presented.as_bytes(), canonical.as_bytes())",
        "verify_bearer_header",
        "strip_prefix(\"Bearer \")",
        "trim_end()",
        "StatusCode::UNAUTHORIZED",
        "concurrent_verification_under_rotation_never_panics",
    ] {
        assert!(
            http_auth.contains(required),
            "HTTP bearer-token cache lifecycle missing `{required}`"
        );
    }

    for (path, provider_key) in [
        (
            "packages/agent/src/domains/auth/credentials/anthropic.rs",
            "Anthropic",
        ),
        (
            "packages/agent/src/domains/auth/credentials/openai/mod.rs",
            "OpenAI",
        ),
        (
            "packages/agent/src/domains/auth/credentials/google.rs",
            "Google",
        ),
    ] {
        let source = read_repo_file(path);
        for required in [
            "static REFRESH_LOCK",
            "TokioMutex",
            "acquire_auth_file_lock(auth_path)",
            "read_tokens_from_disk",
            "persist_tokens",
            "-> Result<(), AuthError>",
            "persist_tokens(&auth_path, &account_label_owned, &new_tokens)?",
            "is_stale_token_error",
            "invalid_grant",
            "super::refresh::maybe_refresh",
        ] {
            assert!(
                source.contains(required),
                "{provider_key} token refresh lifecycle missing `{required}`"
            );
        }
    }
    let google_auth = read_repo_file("packages/agent/src/domains/auth/credentials/google.rs");
    assert_contains_in_order(
        "Google refresh lock and disk re-read lifecycle",
        &google_auth,
        &[
            "maybe_refresh_tokens(auth_path",
            "static REFRESH_LOCK",
            "lock.lock().await",
            "acquire_auth_file_lock(auth_path)",
            "read_tokens_from_disk(auth_path, account_label)",
            "persist_tokens(&auth_path",
            "Google refresh token consumed by another process",
        ],
    );
    assert!(
        google_auth.contains("persisting refreshed Google tokens"),
        "Google refresh lifecycle must log token persistence"
    );

    let provider_factory =
        read_repo_file("packages/agent/src/domains/model/providers/factory/mod.rs");
    for required in [
        "Auth is re-loaded from disk on each call",
        "auth_path: PathBuf",
        "load_server_auth_with_client",
        "create_google_with_credential",
        "get_google_provider_auth(&self.auth_path)",
        "provider_settings",
        "client_secret",
    ] {
        assert!(
            provider_factory.contains(required),
            "provider factory auth-copy lifecycle missing `{required}`"
        );
    }

    let readme = read_repo_file("packages/agent/docs/project-reference.md");
    for required in [
        "OAuth refresh is owned by `domains/auth/credentials/`",
        "process-local refresh mutex",
        "auth-file `flock`",
        "re-read `auth.json` after the lock",
        "fail the refresh if persistence fails",
        "Model providers receive ephemeral token copies",
    ] {
        assert!(
            readme.contains(required),
            "README auth lifecycle docs missing `{required}`"
        );
    }

    let google_provider =
        read_repo_file("packages/agent/src/domains/model/providers/google/provider/mod.rs");
    for required in [
        "tokens: Option<tokio::sync::Mutex<OAuthTokens>>",
        "Some(tokio::sync::Mutex::new(tokens.clone()))",
        "ensure_valid_tokens",
        "refresh_tokens(&tokens",
        "*tokens = new_tokens",
        "build_headers",
        "Bearer {}",
    ] {
        assert!(
            google_provider.contains(required),
            "Google provider ephemeral token lifecycle missing `{required}`"
        );
    }
    assert!(
        !google_provider.contains("save_account_oauth_tokens")
            && !google_provider.contains("auth_path"),
        "Google model provider must not persist durable auth truth directly"
    );

    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    let context = read_repo_file("packages/agent/src/shared/server/context.rs");
    let registration = read_repo_file("packages/agent/src/domains/registration/worker.rs");
    for (name, source) in [
        ("bootstrap", bootstrap.as_str()),
        ("server runtime context", context.as_str()),
        ("domain registration context", registration.as_str()),
    ] {
        for required in [
            "settings_path",
            "profile_runtime",
            "auth_path",
            "oauth_flows",
        ] {
            assert!(
                source.contains(required),
                "{name} must carry settings/auth lifecycle handle `{required}`"
            );
        }
    }
}

#[test]
fn server_auth_and_settings_writes_stay_owner_private() {
    let allowed = [
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/app/health/mod.rs",
        "packages/agent/src/domains/auth/credentials/",
        "packages/agent/src/domains/settings/profile/",
        "packages/agent/src/shared/foundation/profile/",
    ];
    let offenders = git_ls_files()
        .into_iter()
        .filter(|path| is_production_rust_or_swift(path) && path.ends_with(".rs"))
        .filter(|path| repo_path(path).is_file())
        .filter(|path| !allowed.iter().any(|prefix| path.starts_with(prefix)))
        .filter(|path| {
            let text = read_repo_file(path);
            (text.contains("auth.json") || text.contains("profile.toml"))
                && (text.contains("std::fs::write")
                    || text.contains("write_all")
                    || text.contains(".write(true)")
                    || text.contains("tokio::fs::write"))
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "settings/auth/profile writes must stay behind owner stores:\n{}",
        offenders.join("\n")
    );
}
