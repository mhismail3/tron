use super::*;
use std::fs;
use tempfile::TempDir;

fn create_skill(dir: &Path, name: &str, content: &str) {
    let skill_dir = dir.join(name);
    fs::create_dir_all(&skill_dir).unwrap();
    fs::write(skill_dir.join(SKILL_MD_FILENAME), content).unwrap();
}

#[test]
fn test_scan_empty_directory() {
    let tmp = TempDir::new().unwrap();
    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert!(result.skills.is_empty());
    assert!(result.errors.is_empty());
}

#[test]
fn test_scan_nonexistent_directory() {
    let result = scan_directory(
        Path::new("/nonexistent/path"),
        SkillSource::Global,
        "tron",
        "",
    );
    assert!(result.skills.is_empty());
    assert!(result.errors.is_empty());
}

#[test]
fn test_scan_finds_skills() {
    let tmp = TempDir::new().unwrap();
    create_skill(
        tmp.path(),
        "browser",
        "---\nname: Browser\n---\nBrowse the web.",
    );
    create_skill(tmp.path(), "git", "---\nname: Git\n---\nGit operations.");

    let result = scan_directory(tmp.path(), SkillSource::Project, "tron", "");
    assert_eq!(result.skills.len(), 2);
    assert!(result.errors.is_empty());

    let names: Vec<&str> = result.skills.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"browser"));
    assert!(names.contains(&"git"));
}

#[test]
fn test_scan_skips_non_directory() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("not-a-dir.txt"), "hello").unwrap();

    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert!(result.skills.is_empty());
}

#[test]
fn test_scan_skips_directory_without_skill_md() {
    let tmp = TempDir::new().unwrap();
    let no_skill = tmp.path().join("no-skill");
    fs::create_dir_all(&no_skill).unwrap();
    fs::write(no_skill.join("README.md"), "Not a skill").unwrap();

    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert!(result.skills.is_empty());
}

#[test]
fn test_file_too_large_error() {
    let tmp = TempDir::new().unwrap();
    let skill_dir = tmp.path().join("large-skill");
    fs::create_dir_all(&skill_dir).unwrap();

    // Write a file larger than MAX_SKILL_FILE_SIZE
    let content = "x".repeat(MAX_SKILL_FILE_SIZE as usize + 1);
    fs::write(skill_dir.join(SKILL_MD_FILENAME), &content).unwrap();

    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert!(result.skills.is_empty());
    assert_eq!(result.errors.len(), 1);
    assert!(result.errors[0].recoverable);
    assert!(result.errors[0].message.contains("too large"));
}

#[test]
fn test_additional_files_listed() {
    let tmp = TempDir::new().unwrap();
    let skill_dir = tmp.path().join("my-skill");
    fs::create_dir_all(&skill_dir).unwrap();
    fs::write(
        skill_dir.join(SKILL_MD_FILENAME),
        "---\nname: Test\n---\nBody",
    )
    .unwrap();
    fs::write(skill_dir.join("helper.sh"), "#!/bin/bash").unwrap();
    fs::write(skill_dir.join("config.json"), "{}").unwrap();

    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert_eq!(result.skills.len(), 1);
    let skill = &result.skills[0];
    assert!(skill.additional_files.contains(&"helper.sh".to_string()));
    assert!(skill.additional_files.contains(&"config.json".to_string()));
    assert!(
        !skill
            .additional_files
            .contains(&SKILL_MD_FILENAME.to_string())
    );
}

#[test]
fn test_skill_metadata_populated() {
    let tmp = TempDir::new().unwrap();
    create_skill(
        tmp.path(),
        "browser",
        "---\nname: Browser ModelCapability\ndescription: Browse websites\ntags: [web, browser]\n---\n# Browser\n\nUse this to browse.",
    );

    let result = scan_directory(tmp.path(), SkillSource::Project, "tron", "");
    assert_eq!(result.skills.len(), 1);

    let skill = &result.skills[0];
    assert_eq!(skill.name, "browser");
    assert_eq!(skill.display_name, "Browser ModelCapability");
    assert_eq!(skill.description, "Browse websites");
    assert_eq!(skill.source, SkillSource::Project);
    assert!(skill.content.contains("Use this to browse."));
    assert!(skill.last_modified > 0);
}

#[test]
fn test_display_name_defaults_to_folder_name() {
    let tmp = TempDir::new().unwrap();
    create_skill(
        tmp.path(),
        "project-skill",
        "---\ndescription: A capability helper\n---\nBody",
    );

    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert_eq!(result.skills[0].display_name, "project-skill");
}

// --- discover_project_skills_dirs ---

#[test]
fn discover_finds_root_skills_dirs() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join(".claude/skills")).unwrap();
    fs::create_dir_all(tmp.path().join(".tron/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 2);
    assert!(dirs.iter().all(|d| d.scope_dir.is_empty()));
}

#[test]
fn discover_finds_nested_skills_dirs() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join("packages/foo/.claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "packages/foo");
    assert!(dirs[0].path.ends_with("packages/foo/.claude/skills"));
}

#[test]
fn discover_finds_deeply_nested() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join("packages/foo/bar/.tron/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "packages/foo/bar");
}

#[test]
fn discover_skips_node_modules() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join("node_modules/pkg/.claude/skills")).unwrap();
    fs::create_dir_all(tmp.path().join("src/.claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "src");
}

#[test]
fn discover_skips_hidden_dirs() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join(".hidden/.claude/skills")).unwrap();
    fs::create_dir_all(tmp.path().join("visible/.claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "visible");
}

#[test]
fn discover_skips_all_excluded_dirs() {
    let tmp = TempDir::new().unwrap();
    for excluded in SKILL_SCAN_EXCLUDE_DIRS {
        fs::create_dir_all(tmp.path().join(format!("{excluded}/.claude/skills"))).unwrap();
    }
    // Add one valid dir
    fs::create_dir_all(tmp.path().join("src/.claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "src");
}

#[test]
fn discover_respects_max_depth() {
    let tmp = TempDir::new().unwrap();
    // Create a path deeper than SKILL_SCAN_MAX_DEPTH
    let mut deep = tmp.path().to_path_buf();
    for i in 0..=SKILL_SCAN_MAX_DEPTH + 1 {
        deep = deep.join(format!("d{i}"));
    }
    fs::create_dir_all(deep.join(".claude/skills")).unwrap();

    // Also create a shallow one
    fs::create_dir_all(tmp.path().join("shallow/.claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "shallow");
}

#[test]
fn discover_returns_root_first() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join(".claude/skills")).unwrap();
    fs::create_dir_all(tmp.path().join("packages/foo/.claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 2);
    // Root-level should come first
    assert!(dirs[0].scope_dir.is_empty());
    assert_eq!(dirs[1].scope_dir, "packages/foo");
}

#[test]
fn discover_nonexistent_working_dir() {
    let dirs = discover_project_skills_dirs("/nonexistent/path/that/does/not/exist");
    assert!(dirs.is_empty());
}

#[test]
fn discover_empty_dir() {
    let tmp = TempDir::new().unwrap();
    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert!(dirs.is_empty());
}

#[test]
fn discover_multiple_packages() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join("packages/foo/.claude/skills")).unwrap();
    fs::create_dir_all(tmp.path().join("packages/bar/.tron/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 2);
    let scopes: Vec<&str> = dirs.iter().map(|d| d.scope_dir.as_str()).collect();
    assert!(scopes.contains(&"packages/foo"));
    assert!(scopes.contains(&"packages/bar"));
}

#[test]
fn discover_claude_dir_without_skills_subdir_ignored() {
    let tmp = TempDir::new().unwrap();
    // .claude/ exists but no skills/ inside
    fs::create_dir_all(tmp.path().join("packages/foo/.claude/rules")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert!(dirs.is_empty());
}

#[test]
fn discover_scope_dir_correct_for_root() {
    let tmp = TempDir::new().unwrap();
    fs::create_dir_all(tmp.path().join(".claude/skills")).unwrap();

    let dirs = discover_project_skills_dirs(tmp.path().to_str().unwrap());
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].scope_dir, "");
}

// --- scan_all with nested discovery ---

#[test]
fn scan_all_discovers_nested_skills() {
    let tmp = TempDir::new().unwrap();
    let skills_dir = tmp.path().join("packages/foo/.claude/skills");
    fs::create_dir_all(&skills_dir).unwrap();
    create_skill(
        &skills_dir,
        "deploy",
        "---\nname: Deploy\n---\nDeploy things.",
    );

    let (_global, project) = scan_all(tmp.path().to_str().unwrap());
    assert_eq!(project.skills.len(), 1);
    assert_eq!(project.skills[0].name, "deploy");
    assert_eq!(project.skills[0].scope_dir, "packages/foo");
}

#[test]
fn scan_all_root_and_nested_together() {
    let tmp = TempDir::new().unwrap();
    let root_skills = tmp.path().join(".claude/skills");
    fs::create_dir_all(&root_skills).unwrap();
    create_skill(&root_skills, "browser", "---\nname: Browser\n---\nBrowse.");

    let nested_skills = tmp.path().join("packages/ios/.tron/skills");
    fs::create_dir_all(&nested_skills).unwrap();
    create_skill(&nested_skills, "device", "---\nname: Device\n---\nDevice.");

    let (_global, project) = scan_all(tmp.path().to_str().unwrap());
    assert_eq!(project.skills.len(), 2);
    let names: Vec<&str> = project.skills.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"browser"));
    assert!(names.contains(&"device"));
}

#[test]
fn scope_dir_set_on_loaded_skill() {
    let tmp = TempDir::new().unwrap();
    let skills_dir = tmp.path().join("packages/bar/.claude/skills");
    fs::create_dir_all(&skills_dir).unwrap();
    create_skill(&skills_dir, "test", "---\nname: Test\n---\nTest.");

    let result = scan_directory(&skills_dir, SkillSource::Project, "tron", "packages/bar");
    assert_eq!(result.skills.len(), 1);
    assert_eq!(result.skills[0].scope_dir, "packages/bar");
}

#[test]
fn valid_skill_names() {
    assert!(is_valid_skill_name("my-skill"));
    assert!(is_valid_skill_name("skill_v2"));
    assert!(is_valid_skill_name("MySkill123"));
    assert!(is_valid_skill_name("a"));
}

#[test]
fn invalid_skill_names() {
    assert!(!is_valid_skill_name("../escape"));
    assert!(!is_valid_skill_name("has space"));
    assert!(!is_valid_skill_name(".hidden"));
    assert!(!is_valid_skill_name("has/slash"));
    assert!(!is_valid_skill_name("-starts-dash"));
    assert!(!is_valid_skill_name("_starts-underscore"));
}

#[test]
fn empty_skill_name() {
    assert!(!is_valid_skill_name(""));
}

#[test]
fn scan_rejects_invalid_skill_name() {
    let tmp = tempfile::TempDir::new().unwrap();
    let bad_dir = tmp.path().join("..escape");
    std::fs::create_dir_all(&bad_dir).unwrap();
    std::fs::write(bad_dir.join("SKILL.md"), "# Test\nTest skill").unwrap();

    let result = scan_directory(tmp.path(), SkillSource::Global, "tron", "");
    assert!(result.skills.is_empty());
    assert_eq!(result.errors.len(), 1);
    assert!(result.errors[0].message.contains("Invalid skill name"));
}

// --- multi-service global detection + cross-service dedup ---

#[test]
fn global_skills_dirs_for_home_lists_both_services() {
    let dirs = global_skills_dirs_for_home("/fake/home");
    let expected: Vec<PathBuf> = crate::domains::skills::constants::SKILL_RELATIVE_SUBDIRS
        .iter()
        .map(|rel| PathBuf::from("/fake/home").join(rel))
        .collect();
    assert_eq!(dirs, expected);
}

#[test]
fn scan_all_includes_claude_global_skills() {
    let home = TempDir::new().unwrap();
    let claude_skills = home.path().join(".claude/skills");
    fs::create_dir_all(&claude_skills).unwrap();
    create_skill(
        &claude_skills,
        "claude-only",
        "---\nname: claude-only\ndescription: from claude\n---\nbody\n",
    );

    let working = TempDir::new().unwrap();
    let (global, _project) = scan_all_for_home(
        home.path().to_str().unwrap(),
        working.path().to_str().unwrap(),
    );

    assert!(global.skills.iter().any(|s| s.name == "claude-only"));
    assert_eq!(
        global
            .skills
            .iter()
            .find(|s| s.name == "claude-only")
            .unwrap()
            .source,
        SkillSource::Global
    );
}

#[test]
fn scan_all_dedupes_same_name_global_tron_wins() {
    let home = TempDir::new().unwrap();
    for svc in ["tron", "claude"] {
        let svc_skills = home.path().join(format!(".{svc}/skills"));
        fs::create_dir_all(&svc_skills).unwrap();
        create_skill(
            &svc_skills,
            "dup",
            &format!("---\nname: dup\ndescription: from {svc}\n---\nbody\n"),
        );
    }

    let working = TempDir::new().unwrap();
    let (global, _project) = scan_all_for_home(
        home.path().to_str().unwrap(),
        working.path().to_str().unwrap(),
    );

    let dup: Vec<_> = global.skills.iter().filter(|s| s.name == "dup").collect();
    assert_eq!(
        dup.len(),
        1,
        "duplicate 'dup' skill must be deduped across services"
    );
    assert_eq!(
        dup[0].description, "from tron",
        "tron service must win on collision"
    );
}

#[test]
fn scan_all_dedupes_same_name_project_same_scope_tron_wins() {
    let project = TempDir::new().unwrap();
    for svc in ["tron", "claude"] {
        let svc_skills = project.path().join(format!(".{svc}/skills"));
        fs::create_dir_all(&svc_skills).unwrap();
        create_skill(
            &svc_skills,
            "pd",
            &format!("---\nname: pd\ndescription: from {svc}\n---\nbody\n"),
        );
    }

    let home = TempDir::new().unwrap();
    let (_global, proj) = scan_all_for_home(
        home.path().to_str().unwrap(),
        project.path().to_str().unwrap(),
    );

    let pd: Vec<_> = proj.skills.iter().filter(|s| s.name == "pd").collect();
    assert_eq!(
        pd.len(),
        1,
        "same-scope duplicate must be deduped across services"
    );
    assert_eq!(
        pd[0].description, "from tron",
        "tron service must win on collision"
    );
}

// --- service tagging (which .tron/.claude folder produced the skill) ---

#[test]
fn scan_all_tags_tron_global_with_tron_service() {
    let home = TempDir::new().unwrap();
    let tron_skills = home.path().join(".tron/skills");
    fs::create_dir_all(&tron_skills).unwrap();
    create_skill(&tron_skills, "one", "---\nname: one\n---\nbody\n");

    let working = TempDir::new().unwrap();
    let (global, _project) = scan_all_for_home(
        home.path().to_str().unwrap(),
        working.path().to_str().unwrap(),
    );

    let one = global.skills.iter().find(|s| s.name == "one").unwrap();
    assert_eq!(one.service, "tron");
}

#[test]
fn scan_all_tags_claude_global_with_claude_service() {
    let home = TempDir::new().unwrap();
    let claude_skills = home.path().join(".claude/skills");
    fs::create_dir_all(&claude_skills).unwrap();
    create_skill(&claude_skills, "two", "---\nname: two\n---\nbody\n");

    let working = TempDir::new().unwrap();
    let (global, _project) = scan_all_for_home(
        home.path().to_str().unwrap(),
        working.path().to_str().unwrap(),
    );

    let two = global.skills.iter().find(|s| s.name == "two").unwrap();
    assert_eq!(two.service, "claude");
}

#[test]
fn scan_all_tags_project_skills_with_service() {
    let project = TempDir::new().unwrap();

    let tron_dir = project.path().join(".tron/skills");
    let claude_dir = project.path().join(".claude/skills");
    fs::create_dir_all(&tron_dir).unwrap();
    fs::create_dir_all(&claude_dir).unwrap();
    create_skill(&tron_dir, "tron-proj", "---\nname: tron-proj\n---\nbody\n");
    create_skill(
        &claude_dir,
        "claude-proj",
        "---\nname: claude-proj\n---\nbody\n",
    );

    let home = TempDir::new().unwrap();
    let (_global, proj) = scan_all_for_home(
        home.path().to_str().unwrap(),
        project.path().to_str().unwrap(),
    );

    let tron_proj = proj.skills.iter().find(|s| s.name == "tron-proj").unwrap();
    let claude_proj = proj
        .skills
        .iter()
        .find(|s| s.name == "claude-proj")
        .unwrap();
    assert_eq!(tron_proj.service, "tron");
    assert_eq!(claude_proj.service, "claude");
}

#[test]
fn skill_info_from_metadata_carries_service() {
    let home = TempDir::new().unwrap();
    let claude_skills = home.path().join(".claude/skills");
    fs::create_dir_all(&claude_skills).unwrap();
    create_skill(&claude_skills, "c1", "---\nname: c1\n---\nbody\n");

    let working = TempDir::new().unwrap();
    let (global, _) = scan_all_for_home(
        home.path().to_str().unwrap(),
        working.path().to_str().unwrap(),
    );
    let meta = global.skills.iter().find(|s| s.name == "c1").unwrap();
    let info = crate::domains::skills::types::SkillInfo::from(meta);
    assert_eq!(info.service, "claude");
}

#[test]
fn scan_all_keeps_same_name_across_different_scopes() {
    // Same skill name in two different scope_dirs remains two distinct entries;
    // cross-scope shadowing is handled by SkillRegistry::initialize, not by scan_all.
    let project = TempDir::new().unwrap();
    let root_skills = project.path().join(".tron/skills");
    let nested_skills = project.path().join("pkg/foo/.tron/skills");
    fs::create_dir_all(&root_skills).unwrap();
    fs::create_dir_all(&nested_skills).unwrap();
    create_skill(
        &root_skills,
        "shared",
        "---\nname: shared\n---\nroot body\n",
    );
    create_skill(
        &nested_skills,
        "shared",
        "---\nname: shared\n---\nnested body\n",
    );

    let home = TempDir::new().unwrap();
    let (_global, proj) = scan_all_for_home(
        home.path().to_str().unwrap(),
        project.path().to_str().unwrap(),
    );

    let shared: Vec<_> = proj.skills.iter().filter(|s| s.name == "shared").collect();
    assert_eq!(shared.len(), 2);
}
