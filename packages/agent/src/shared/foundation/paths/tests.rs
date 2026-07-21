use super::*;

#[test]
fn home_dir_returns_env_var() {
    let home = std::env::var("HOME").unwrap();
    assert_eq!(home_dir(), home);
}

#[test]
fn paths_source_has_no_hardcoded_user_directory() {
    let src = include_str!("../mod.rs");
    let developer_username = ["m", "oo", "se"].concat();
    let needle = format!("/Users/{developer_username}");
    assert!(
        !src.contains(&needle),
        "hardcoded user path leaked back into paths.rs"
    );
}

#[test]
fn cargo_pkg_repository_has_no_personal_handle() {
    let repo = env!("CARGO_PKG_REPOSITORY");
    let needles = [
        format!("/{}/", ["m", "oo", "se"].concat()),
        format!("{}{}{}", "mh", "is", "mail"),
    ];
    for needle in needles {
        assert!(
            !repo.contains(&needle),
            "Cargo.toml `repository` field points at a personal handle: {repo}"
        );
    }
}

#[test]
fn workspace_has_no_personal_info_literals() {
    let needles = [
        format!("{}{}{}", "M", "oh", "sin"),
        format!("{}{}{}", "Is", "ma", "il"),
        format!("{}{}{}", "is", "ma", "il"),
        format!("{}{}{}", "mh", "is", "mail"),
    ];
    let offenders: Vec<(&str, String)> =
        vec![("paths/mod.rs", include_str!("../mod.rs").to_owned())];
    for (name, src) in &offenders {
        for needle in &needles {
            assert!(
                !src.contains(needle.as_str()),
                "{name}: contains personal-info literal `{needle}`"
            );
        }
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
fn normalize_working_directory_expands_home_alias() {
    let home = PathBuf::from(home_dir()).canonicalize().unwrap();
    assert_eq!(normalize_working_directory("~").unwrap(), home);
}

#[test]
fn normalize_working_directory_rejects_missing_paths() {
    let missing = format!(
        "{}/definitely-missing-working-directory-for-tron-test",
        std::env::temp_dir().display()
    );
    assert!(
        normalize_working_directory(&missing).is_err(),
        "missing working directories must fail instead of becoming trace metadata"
    );
}

#[test]
fn primitive_top_level_dirs_stay_under_tron_home() {
    assert!(internal_dir().ends_with(format!(".tron/{}", dirs::INTERNAL)));
}

#[test]
fn settings_and_auth_have_distinct_canonical_paths() {
    assert!(settings_path().ends_with(files::SETTINGS_TOML));
    assert!(auth_path().ends_with(format!("{}/{}", dirs::PROFILES, files::AUTH_JSON)));
    assert_ne!(settings_path(), auth_path());
}

#[test]
fn tron_binary_path_resolves_concrete_file_name() {
    let p = tron_binary_path();
    assert!(
        p.file_name().is_some(),
        "current executable path should resolve to a concrete file name"
    );
}

#[test]
fn runtime_paths_live_under_internal_run() {
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
fn journals_dir_under_db() {
    assert!(journals_dir().ends_with(format!(
        "{}/{}/{}",
        dirs::INTERNAL,
        dirs::DB,
        dirs::JOURNALS
    )));
}
