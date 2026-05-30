use super::*;

#[test]
fn home_dir_returns_env_var() {
    let home = std::env::var("HOME").unwrap();
    assert_eq!(home_dir(), home);
}

#[test]
fn paths_source_has_no_hardcoded_user_directory() {
    let src = include_str!("../paths.rs");
    // Construct the needle from parts so this very test doesn't trigger itself.
    let needle = format!("/Users/{}", "moose");
    assert!(
        !src.contains(&needle),
        "hardcoded user path leaked back into paths.rs"
    );
}

/// Regression guard: `Cargo.toml` `repository` URL must not contain a
/// short personal GitHub handle (the dev-machine username) in the
/// `/<handle>/` path segment. An older draft pointed at a stale handle
/// that would 404 for any user trying to follow the link from
/// crates.io / docs.rs / IDE pop-ups.
///
/// Needle constructed from parts so this test doesn't self-match.
#[test]
fn cargo_pkg_repository_has_no_personal_handle() {
    let repo = env!("CARGO_PKG_REPOSITORY");
    let needle = format!("/{}/", "moose");
    assert!(
        !repo.contains(&needle),
        "Cargo.toml `repository` field points at a personal handle: {repo}"
    );
}

/// Regression guard: `import/parser.rs` doc-comments must not embed
/// example paths from the developer's home directory. An earlier doc
/// comment used a literal Claude-Code-encoded form of the developer's
/// project tree as its "example"; that leaks the developer's directory
/// layout into a public-facing comment that ships in `cargo doc`.
///
/// Both forms are checked: the raw filesystem prefix and the encoded
/// form that Claude Code generates (slashes replaced with hyphens).
/// Needles constructed from parts so this test doesn't self-match.
#[test]
fn import_parser_doc_comments_have_no_personal_path_examples() {
    let src = include_str!("../../../domains/import/implementation/parser.rs");
    let raw_needle = format!("/Users/{}", "moose");
    let encoded_needle = format!("-Users-{}-", "moose");
    assert!(
        !src.contains(&raw_needle),
        "import/parser.rs contains a hardcoded user path: {raw_needle}"
    );
    assert!(
        !src.contains(&encoded_needle),
        "import/parser.rs doc-comment example references the developer's \
             home directory in encoded form: {encoded_needle}"
    );
}

/// Regression guard: managed skill bundles (every `packages/agent/skills/*`
/// with a `.managed` sentinel) must contain no hardcoded personal-info
/// literals. Needles are constructed from parts so this test file itself
/// doesn't contain them.
#[test]
fn managed_skills_contain_no_personal_info_literals() {
    let needles = [
        format!("{}{}{}", "M", "oh", "sin"),
        format!("{}{}{}", "Is", "ma", "il"),
        format!("{}{}{}", "is", "ma", "il"),
        format!("{}{}{}", "mh", "is", "mail"),
    ];
    let skills_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills");
    let Ok(entries) = std::fs::read_dir(&skills_dir) else {
        // No skills dir in this checkout — nothing to guard.
        return;
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        // Only scan managed skills (sentinel present).
        if !dir.join(".managed").exists() {
            continue;
        }
        // Recursively scan every .md file under the managed skill.
        scan_md_for_needles(&dir, &needles);
    }
}

fn scan_md_for_needles(dir: &std::path::Path, needles: &[String]) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_md_for_needles(&path, needles);
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        for needle in needles {
            assert!(
                !content.contains(needle.as_str()),
                "{}: contains personal-info literal `{needle}` — route through MEMORY.md / rules/",
                path.display()
            );
        }
    }
}

/// Regression guard: no hardcoded personal info leaks into embedded system
/// prompts or critical skill/memory source files. Banned needles are
/// constructed from parts so this test file itself doesn't contain them.
///
/// User info belongs in `~/.tron/memory/MEMORY.md` (auto-loaded
/// into every session's context). Hardcoded names/emails/handles are a
/// correctness bug — they assume one user and ship that assumption in the
/// binary. See [`crate::domains::agent::runner::memory`] for the canonical load path.
#[test]
fn workspace_has_no_personal_info_literals() {
    let needles = [
        format!("{}{}{}", "M", "oh", "sin"),
        format!("{}{}{}", "Is", "ma", "il"),
        format!("{}{}{}", "is", "ma", "il"),
        format!("{}{}{}", "mh", "is", "mail"),
    ];
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let offenders: Vec<(&str, String)> = vec![
        ("paths.rs", include_str!("../paths.rs").to_owned()),
        (
            "defaults/profiles/default/prompts/core.md",
            std::fs::read_to_string(manifest_dir.join("defaults/profiles/default/prompts/core.md"))
                .unwrap(),
        ),
        (
            "defaults/profiles/default/prompts/chat.md",
            std::fs::read_to_string(manifest_dir.join("defaults/profiles/default/prompts/chat.md"))
                .unwrap(),
        ),
        (
            "defaults/profiles/default/prompts/local.md",
            std::fs::read_to_string(
                manifest_dir.join("defaults/profiles/default/prompts/local.md"),
            )
            .unwrap(),
        ),
        (
            "runtime/memory/registry.rs",
            include_str!("../../../domains/agent/runner/memory/registry.rs").to_owned(),
        ),
        (
            "runtime/memory/mod.rs",
            include_str!("../../../domains/agent/runner/memory/mod.rs").to_owned(),
        ),
        (
            "skills/discovery/loader.rs",
            include_str!("../../../domains/skills/implementation/discovery/loader.rs").to_owned(),
        ),
        (
            "skills/discovery/registry.rs",
            include_str!("../../../domains/skills/implementation/discovery/registry.rs").to_owned(),
        ),
    ];
    for (name, src) in &offenders {
        for needle in &needles {
            assert!(
                !src.contains(needle.as_str()),
                "{name}: contains personal-info literal `{needle}` — route through MEMORY.md instead"
            );
        }
    }
}

/// Regression guard covering every production file this refactor touched.
/// Extending the list is a cheap review-time change.
#[test]
fn skill_detection_source_has_no_hardcoded_user_directory() {
    // Construct the needle from parts so this very test doesn't self-match.
    let needle = format!("/Users/{}", "moose");
    let offenders: &[(&str, &str)] = &[
        ("paths.rs", include_str!("../paths.rs")),
        (
            "skills/model/constants.rs",
            include_str!("../../../domains/skills/implementation/model/constants.rs"),
        ),
        (
            "skills/model/types.rs",
            include_str!("../../../domains/skills/implementation/model/types.rs"),
        ),
        (
            "skills/discovery/loader.rs",
            include_str!("../../../domains/skills/implementation/discovery/loader.rs"),
        ),
        (
            "skills/discovery/registry.rs",
            include_str!("../../../domains/skills/implementation/discovery/registry.rs"),
        ),
        (
            "skills/runtime/injector.rs",
            include_str!("../../../domains/skills/implementation/runtime/injector.rs"),
        ),
        (
            "skills/mod.rs",
            include_str!("../../../domains/skills/mod.rs"),
        ),
    ];
    for (name, src) in offenders {
        assert!(!src.contains(&needle), "hardcoded user path in {name}");
    }
}

#[test]
fn tron_home_appends_dot_tron() {
    let home = home_dir();
    assert_eq!(tron_home(), PathBuf::from(home).join(".tron"));
}

#[test]
fn tron_home_supports_explicit_developer_roots() {
    assert_eq!(
        resolve_tron_home("/Users/dev", Some("/tmp/tron-data"), None),
        PathBuf::from("/tmp/tron-data")
    );
    assert_eq!(
        resolve_tron_home("/Users/dev", None, Some(".tron-dev")),
        PathBuf::from("/Users/dev/.tron-dev")
    );
}

#[test]
fn tron_home_name_rejects_nested_paths() {
    assert!(!valid_home_relative_name("../other"));
    assert!(!valid_home_relative_name("nested/path"));
    assert!(!valid_home_relative_name("."));
    assert!(valid_home_relative_name(".tron-dev"));
}

#[test]
fn tron_home_returns_pathbuf() {
    let result = tron_home();
    assert!(result.to_string_lossy().ends_with(".tron"));
}

// ── Top-level dirs ─────────────────────────────────────────────

#[test]
fn internal_dir_under_tron_home() {
    let p = internal_dir();
    assert!(p.ends_with(format!(".tron/{}", dirs::INTERNAL)));
}

#[test]
fn workspace_dir_under_tron_home() {
    let p = workspace_dir();
    assert!(p.ends_with(format!(".tron/{}", dirs::WORKSPACE)));
}

#[test]
fn skills_dir_under_tron_home() {
    let p = skills_dir();
    assert!(p.ends_with(format!(".tron/{}", dirs::SKILLS)));
}

#[test]
fn profiles_dir_under_tron_home() {
    let p = profiles_dir();
    assert!(p.ends_with(format!(".tron/{}", dirs::PROFILES)));
}

#[test]
fn memory_dir_under_tron_home() {
    let p = memory_dir();
    assert!(p.ends_with(format!(".tron/{}", dirs::MEMORY)));
}

// ── Workspace subdirs ──────────────────────────────────────────

#[test]
fn rules_dir_chains_correctly() {
    let p = rules_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::MEMORY, dirs::RULES)));
}

#[test]
fn scratch_dir_chains_correctly() {
    let p = scratch_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::SCRATCH)));
}

#[test]
fn automations_dir_chains_correctly() {
    let p = automations_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::AUTOMATIONS)));
}

#[test]
fn screenshots_dir_chains_correctly() {
    let p = screenshots_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::SCREENSHOTS)));
}

#[test]
fn renders_dir_chains_correctly() {
    let p = renders_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::WORKSPACE, dirs::RENDERS)));
}

// ── Composite file paths ───────────────────────────────────────

#[test]
fn global_system_prompt_path_correct() {
    let p = global_system_prompt_path();
    assert!(p.ends_with(format!("{}/user/{}/core.md", dirs::PROFILES, dirs::PROMPTS)));
}

#[test]
fn settings_path_correct() {
    let p = settings_path();
    assert!(p.ends_with(format!("{}/user/{}", dirs::PROFILES, files::PROFILE_TOML)));
}

#[test]
fn tron_binary_path_correct() {
    let p = tron_binary_path();
    assert!(
        p.file_name().is_some(),
        "current executable path should resolve to a concrete file name"
    );
}

#[test]
fn run_dir_under_internal() {
    let p = run_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::INTERNAL, dirs::RUN)));
}

#[test]
fn run_dir_for_home_uses_same_canonical_segments() {
    let home = std::path::Path::new("/tmp/tron-home");
    assert_eq!(
        run_dir_for_home(home),
        home.join(dirs::INTERNAL).join(dirs::RUN)
    );
    assert_eq!(
        auth_lock_path_for_home(home),
        home.join(dirs::INTERNAL).join(dirs::RUN).join("auth.lock")
    );
}

#[test]
fn runtime_locks_under_run_dir() {
    assert!(auth_lock_path().ends_with(format!("{}/{}/auth.lock", dirs::INTERNAL, dirs::RUN)));
    assert!(mac_wrapper_lock_path().ends_with(format!(
        "{}/{}/.mac-wrapper.com.tron.mac.lock",
        dirs::INTERNAL,
        dirs::RUN
    )));
    assert!(
        mac_wrapper_lock_path_for("com.tron.mac.dev").ends_with(format!(
            "{}/{}/.mac-wrapper.com.tron.mac.dev.lock",
            dirs::INTERNAL,
            dirs::RUN
        ))
    );
}

#[test]
fn journals_dir_under_db() {
    let p = journals_dir();
    assert!(p.ends_with(format!(
        "{}/{}/{}",
        dirs::INTERNAL,
        dirs::DB,
        dirs::JOURNALS
    )));
}

#[test]
fn updater_state_path_lives_under_internal_dir() {
    let p = updater_state_path();
    let s = p.to_string_lossy();
    assert!(s.ends_with("/run/updater-state.json"), "got: {s}");
    assert!(
        s.contains("/.tron/internal/run/"),
        "must live under ~/.tron/internal/run/, got: {s}"
    );
}

#[test]
fn auto_update_pause_path_lives_under_internal_run() {
    let p = auto_update_pause_path();
    let s = p.to_string_lossy();
    assert!(
        s.ends_with("/.tron/internal/run/auto-update.pause"),
        "got: {s}"
    );
    assert!(
        s.contains("/.tron/internal/run/"),
        "auto-update.pause must live under ~/.tron/internal/run/, got: {s}"
    );
}

// ── Transcription sidecar ──────────────────────────────────────

#[test]
fn transcription_dir_under_internal() {
    let p = transcription_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::INTERNAL, dirs::TRANSCRIPTION)));
}

#[test]
fn transcription_venv_dir_correct() {
    let p = transcription_venv_dir();
    assert!(p.ends_with(format!("{}/{}/venv", dirs::INTERNAL, dirs::TRANSCRIPTION)));
}

#[test]
fn transcription_worker_script_correct() {
    let p = transcription_worker_script();
    assert!(p.ends_with(format!(
        "{}/{}/worker.py",
        dirs::INTERNAL,
        dirs::TRANSCRIPTION
    )));
}

#[test]
fn transcription_requirements_path_correct() {
    let p = transcription_requirements_path();
    assert!(p.ends_with(format!(
        "{}/{}/requirements.txt",
        dirs::INTERNAL,
        dirs::TRANSCRIPTION
    )));
}

#[test]
fn transcription_hf_cache_dir_correct() {
    let p = transcription_hf_cache_dir();
    assert!(p.ends_with(format!(
        "{}/{}/models/hf",
        dirs::INTERNAL,
        dirs::TRANSCRIPTION
    )));
}

// ── Memory subdirs ──────────────────────────────────────────────

#[test]
fn memory_sessions_dir_chains_correctly() {
    let p = memory_sessions_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::MEMORY, dirs::SESSIONS)));
}

#[test]
fn memory_rules_dir_chains_correctly() {
    let p = memory_rules_dir();
    assert!(p.ends_with(format!("{}/{}", dirs::MEMORY, dirs::RULES)));
}

// ── Consistency guards ─────────────────────────────────────────

#[test]
fn tron_rules_relative_matches_constants() {
    let expected = format!(".tron/{}/{}", dirs::MEMORY, dirs::RULES);
    assert_eq!(
        dirs::TRON_RULES_RELATIVE,
        expected,
        "TRON_RULES_RELATIVE is out of sync with MEMORY/RULES constants"
    );
}
