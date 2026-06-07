use super::*;

fn write(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(path, content).unwrap();
}

fn seed_auth(home: &Path) {
    write(
        &home.join(dirs::PROFILES).join(files::AUTH_TOML),
        r#"
version = "1"
default = "default"

[profiles.default]
store = "auth.json"
"#,
    );
}

#[test]
fn active_profile_reads_toml() {
    assert_eq!(
        parse_active_profile("active = \"user\"\n").as_deref(),
        Some("user")
    );
}

#[test]
fn bundled_default_profile_parses_as_primitive_profile() {
    let spec = bundled_default_execution_spec();

    assert_eq!(spec.version, CURRENT_PROFILE_VERSION);
    assert_eq!(spec.name, DEFAULT_PROFILE);
    assert!(spec.managed);
    assert_eq!(spec.auth_profile, DEFAULT_AUTH_PROFILE);
    assert_eq!(spec.settings.server.default_model, "claude-sonnet-4-6");
    assert_eq!(spec.settings.server.default_provider, "anthropic");
}

#[test]
fn managed_profiles_resolve_from_seeded_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();

    let normal = resolve_profile_at(&home, NORMAL_PROFILE).unwrap();
    let chat = resolve_profile_at(&home, CHAT_PROFILE).unwrap();
    let local = resolve_profile_at(&home, LOCAL_PROFILE).unwrap();

    assert_eq!(normal.spec.profile_class.as_deref(), Some("normal"));
    assert_eq!(chat.spec.profile_class.as_deref(), Some("chat"));
    assert_eq!(local.spec.profile_class.as_deref(), Some("local"));
    assert_eq!(normal.spec.auth_profile, DEFAULT_AUTH_PROFILE);
    assert!(normal.spec.auth_registry.is_some());
}

#[test]
fn product_control_plane_tables_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home
            .join(dirs::PROFILES)
            .join("child")
            .join(files::PROFILE_TOML),
        r#"
version = "3"
name = "child"
authProfile = "default"
inherits = ["default"]

[entrypoints.main]
modelPolicy = "sessionDefault"
"#,
    );

    let error = resolve_profile_at(&home, "child").unwrap_err();

    assert!(error.to_string().contains("unknown field"));
}

#[test]
fn user_sparse_settings_overlay_is_retained() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::PROFILE_TOML),
        r#"
version = "3"
name = "user"
authProfile = "default"
inherits = []

[settings.server]
defaultProvider = "openai"
"#,
    );

    let resolved = resolve_profile_at(&home, NORMAL_PROFILE).unwrap();

    assert_eq!(resolved.spec.settings.server.default_provider, "openai");
}

#[test]
fn user_runtime_policy_overlay_is_ignored_before_schema_validation() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::PROFILE_TOML),
        r#"
version = "3"
name = "user"
authProfile = "default"
inherits = []

[settings.server]
defaultProvider = "openai"

[primitiveSurfacePolicies.bad]
allowedPrimitives = ["execute"]
"#,
    );

    let resolved = resolve_profile_at(&home, NORMAL_PROFILE).unwrap();

    assert_eq!(resolved.spec.settings.server.default_provider, "openai");
}

#[test]
fn spec_hash_changes_when_auth_registry_changes() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();

    let before = resolve_profile_at(&home, NORMAL_PROFILE).unwrap().spec_hash;
    write(
        &home.join(dirs::PROFILES).join(files::AUTH_TOML),
        r#"
version = "1"
default = "default"

[profiles.default]
description = "changed"
store = "auth.json"
"#,
    );
    let after = resolve_profile_at(&home, NORMAL_PROFILE).unwrap().spec_hash;

    assert_ne!(before, after);
}

#[test]
fn settings_tables_deep_merge_and_arrays_replace() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home
            .join(dirs::PROFILES)
            .join("child")
            .join(files::PROFILE_TOML),
        r#"
version = "3"
name = "child"
authProfile = "default"
inherits = ["default"]

[settings.ui.input]
maxHistory = 7

[settings.ui.thinkingAnimation]
chars = ["*"]
"#,
    );

    let resolved = resolve_profile_at(&home, "child").unwrap();

    assert_eq!(resolved.spec.settings.ui.input.max_history, 7);
    assert_eq!(
        resolved.spec.settings.ui.thinking_animation.chars,
        vec!["*".to_string()]
    );
    assert_eq!(
        resolved.spec.settings.server.default_provider, "anthropic",
        "sibling settings should survive child overlays"
    );
}

#[test]
fn profile_auth_validation_uses_profile_registry_ref() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home.join(dirs::PROFILES).join("custom-auth.toml"),
        r#"
version = "1"
default = "secondary"

[profiles.secondary]
store = "auth.json"
"#,
    );
    write(
        &home
            .join(dirs::PROFILES)
            .join("child")
            .join(files::PROFILE_TOML),
        r#"
version = "3"
name = "child"
authProfile = "secondary"
inherits = ["default"]

[auth]
registry = "custom-auth.toml"
"#,
    );

    let resolved = resolve_profile_at(&home, "child").unwrap();

    assert_eq!(resolved.spec.auth_profile, "secondary");
}

#[test]
fn profile_cycle_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    seed_auth(&home);
    write(
        &home
            .join(dirs::PROFILES)
            .join("a")
            .join(files::PROFILE_TOML),
        r#"version = "3"
name = "a"
authProfile = "default"
inherits = ["b"]
"#,
    );
    write(
        &home
            .join(dirs::PROFILES)
            .join("b")
            .join(files::PROFILE_TOML),
        r#"version = "3"
name = "b"
authProfile = "default"
inherits = ["a"]
"#,
    );

    let error = resolve_profile_at(&home, "a").unwrap_err();
    assert!(error.to_string().contains("cycle"));
}
