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
fn bundled_default_profile_parses_as_v3_execution_spec() {
    let spec = bundled_default_execution_spec();

    assert_eq!(spec.version, CURRENT_PROFILE_VERSION);
    assert_eq!(spec.name, DEFAULT_PROFILE);
    assert!(spec.managed);
    assert!(spec.entrypoints.contains_key("chat"));
    assert_eq!(spec.processes["compaction"].kind, ProcessKind::Summarizer);
    assert_eq!(spec.processes["memoryRetain"].kind, ProcessKind::Summarizer);
    assert_eq!(
        spec.processes["webSummarizer"].kind,
        ProcessKind::CapabilityWorker
    );
    assert!(spec.context_policies.contains_key("cloudDefault"));
    assert!(spec.primitive_surface_policies.contains_key("localModel"));
    assert!(
        spec.capability_execution_policies
            .contains_key("localModel")
    );
    assert!(spec.provider_policies.contains_key("default"));
    assert!(spec.cache_policies.contains_key("default"));
    assert_eq!(spec.settings.server.default_model, "claude-sonnet-4-6");
    assert_eq!(spec.settings.server.default_provider, "anthropic");
    assert!(
        spec.settings
            .api
            .anthropic
            .oauth_beta_headers
            .contains("fine-grained-tool-streaming-2025-05-14")
    );
    assert!(
        !spec
            .settings
            .api
            .anthropic
            .oauth_beta_headers
            .contains(&format!(
                "{}{}{}",
                "fine-grained-", "capability", "-streaming"
            ))
    );
}

#[test]
fn default_context_block_manifest_declares_capability_schema_surface() {
    let manifest_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("defaults/profiles/default/context/context-blocks.toml");
    validate_context_block_manifest(&manifest_path).unwrap();
    let manifest: ContextBlockManifest =
        toml::from_str(&fs::read_to_string(&manifest_path).unwrap()).unwrap();
    let schemas = manifest
        .blocks
        .iter()
        .find(|block| block.id == "capabilities.schemas")
        .expect("capabilities.schemas block");

    assert_eq!(
        schemas
            .provider_surface
            .map(ContextBlockProviderSurface::as_str),
        Some(CAPABILITY_SCHEMA_PROVIDER_SURFACE)
    );
}

#[test]
fn managed_session_profiles_resolve_from_seeded_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();

    let normal = resolve_profile_at(&home, NORMAL_PROFILE).unwrap();
    let chat = resolve_profile_at(&home, CHAT_PROFILE).unwrap();
    let local = resolve_profile_at(&home, LOCAL_PROFILE).unwrap();

    assert_eq!(normal.spec.profile_class.as_deref(), Some("normal"));
    assert_eq!(chat.spec.profile_class.as_deref(), Some("chat"));
    assert_eq!(local.spec.profile_class.as_deref(), Some("local"));
    assert_eq!(chat.spec.entrypoint_prompt("main"), Some("prompts/chat.md"));
    assert_eq!(
        local.spec.entrypoints["main"].context_policy,
        "localDefault"
    );
    assert_eq!(
        local.spec.entrypoints["main"].primitive_surface_policy,
        "localModel"
    );
    assert_eq!(
        local.spec.entrypoints["main"].capability_execution_policy,
        "localModel"
    );
}

#[test]
fn profile_v3_rejects_v2_policy_fields() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home
            .join(dirs::PROFILES)
            .join("child")
            .join(files::PROFILE_TOML),
        &format!(
            "{}{}{}",
            r#"
version = "3"
name = "child"
inherits = ["default"]

[entrypoints.main]
"#,
            "capability",
            "Policy = \"default\"\n"
        ),
    );

    let error = resolve_profile_at(&home, "child").unwrap_err();
    assert!(
        error.to_string().contains("unknown field")
            || error
                .to_string()
                .contains(&format!("{}{}", "capability", "Policy")),
        "expected v2 {}{} rejection, got {error}",
        "capability",
        "Policy"
    );
}

#[test]
fn user_sparse_settings_survive_while_runtime_policy_overlay_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    write(
        &home
            .join(dirs::PROFILES)
            .join(USER_PROFILE)
            .join(files::PROFILE_TOML),
        r#"
version = "2"
name = "user"
inherits = ["default"]

[settings.server]
defaultProvider = "openai"

[primitiveSurfacePolicies.bad]
allowedPrimitives = ["filesystem::read_file"]
"#,
    );

    let resolved = resolve_profile_at(&home, NORMAL_PROFILE).unwrap();

    assert_eq!(resolved.spec.settings.server.default_provider, "openai");
    assert_eq!(
        resolved.spec.entrypoints["main"].primitive_surface_policy,
        "default"
    );
    assert!(
        !resolved.spec.primitive_surface_policies.contains_key("bad"),
        "user profile runtime control-plane tables must not be interpreted as profile overrides"
    );
}

#[test]
fn primitive_surface_policy_rejects_contract_ids() {
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
inherits = ["default"]

[primitiveSurfacePolicies.bad]
allowedPrimitives = ["search", "filesystem::read_file"]
"#,
    );

    let error = resolve_profile_at(&home, "child").unwrap_err();
    assert!(
        error
            .to_string()
            .contains("primitiveSurfacePolicies.bad references non-primitive"),
        "expected primitive-only validation, got {error}"
    );
}

#[test]
fn spec_hash_changes_when_referenced_prompt_changes() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();

    let before = resolve_profile_at(&home, NORMAL_PROFILE).unwrap().spec_hash;
    write(
        &home
            .join(dirs::PROFILES)
            .join(DEFAULT_PROFILE)
            .join("prompts/core.md"),
        "changed core prompt",
    );
    let after = resolve_profile_at(&home, NORMAL_PROFILE).unwrap().spec_hash;

    assert_ne!(before, after);
}

#[test]
fn profile_without_main_entrypoint_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".tron");
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    let profile_path = home
        .join(dirs::PROFILES)
        .join(DEFAULT_PROFILE)
        .join(files::PROFILE_TOML);
    let mut value: Value = toml::from_str(&fs::read_to_string(&profile_path).unwrap()).unwrap();
    value
        .get_mut("entrypoints")
        .and_then(Value::as_table_mut)
        .unwrap()
        .remove("main");
    fs::write(&profile_path, toml::to_string(&value).unwrap()).unwrap();

    let error = resolve_profile_at(&home, DEFAULT_PROFILE).unwrap_err();
    assert!(error.to_string().contains("entrypoints.main"));
}

#[test]
fn profile_inheritance_deep_merges_tables_and_replaces_arrays() {
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

[entrypoints.chat]
prompt = "prompts/custom-chat.md"
"#,
    );
    write(
        &home
            .join(dirs::PROFILES)
            .join("child")
            .join("prompts/custom-chat.md"),
        "chat",
    );

    let resolved = resolve_profile_at(&home, "child").unwrap();

    assert_eq!(
        resolved.spec.entrypoint_prompt("main"),
        Some("prompts/core.md")
    );
    assert_eq!(
        resolved.spec.entrypoint_prompt("chat"),
        Some("prompts/custom-chat.md")
    );
    assert_eq!(
        resolved.spec.entrypoints["chat"].primitive_surface_policy, "default",
        "partial child entrypoint override should inherit parent policy fields"
    );
    assert_eq!(
        resolved.spec.entrypoints["chat"].capability_execution_policy, "default",
        "partial child entrypoint override should inherit parent policy fields"
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
