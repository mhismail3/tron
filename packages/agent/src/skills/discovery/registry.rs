//! In-memory skill registry.
//!
//! Maintains a `HashMap` of skills keyed by name. Project skills take
//! precedence over global skills with the same name.
//!
//! Supports staleness detection via filesystem fingerprinting: before each
//! prompt, callers can use [`SkillRegistry::refresh_if_stale`] to cheaply
//! check whether skill directories have changed on disk and only do a full
//! rescan when something is different.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use tracing::{debug, warn};

use crate::skills::loader;
use crate::skills::types::{SkillInfo, SkillMetadata, SkillSource};

// =============================================================================
// Fingerprint
// =============================================================================

/// Lightweight fingerprint of skill directories for staleness detection.
///
/// Tracks modification times of skill directories and SKILL.md files.
/// Two fingerprints are equal iff they have exactly the same set of paths
/// with the same modification times.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillFingerprint {
    /// Sorted map of absolute path -> mtime (seconds since epoch).
    /// Includes both parent directories and individual SKILL.md files.
    entries: BTreeMap<String, u64>,
}

impl SkillFingerprint {
    /// Compute a fingerprint by stat-ing all skill directories and SKILL.md files.
    ///
    /// This is cheap: only `readdir` + `stat` calls, no file content is read.
    pub fn compute(working_dir: &str) -> Self {
        let mut entries = BTreeMap::new();

        let global_dir = loader::global_skills_dir();
        Self::scan_dir(&global_dir, &mut entries);

        for psd in loader::discover_project_skills_dirs(working_dir) {
            Self::scan_dir(&psd.path, &mut entries);
        }

        Self { entries }
    }

    /// Scan a single skills directory and add entries for the directory itself
    /// and each SKILL.md file found within subdirectories.
    fn scan_dir(dir: &Path, entries: &mut BTreeMap<String, u64>) {
        // Record the directory's own mtime (detects new/removed subdirectories)
        if let Ok(meta) = std::fs::metadata(dir) {
            if let Ok(mtime) = meta.modified() {
                let secs = mtime
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let _ = entries.insert(dir.to_string_lossy().into_owned(), secs);
            }
        } else {
            // Directory doesn't exist — record absence so creation is detected
            let _ = entries.insert(dir.to_string_lossy().into_owned(), 0);
            return;
        }

        // Record each subdirectory's SKILL.md mtime (detects content changes)
        let Ok(read_dir) = std::fs::read_dir(dir) else {
            return;
        };

        for entry in read_dir.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let skill_md = path.join(crate::skills::constants::SKILL_MD_FILENAME);
            let mtime = std::fs::metadata(&skill_md)
                .and_then(|m| m.modified())
                .map(|t| {
                    t.duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs()
                })
                .unwrap_or(0);
            let _ = entries.insert(skill_md.to_string_lossy().into_owned(), mtime);
        }
    }
}

// =============================================================================
// Registry
// =============================================================================

/// In-memory registry of available skills.
#[derive(Debug)]
pub struct SkillRegistry {
    skills: HashMap<String, SkillMetadata>,
    /// Fingerprint from the last refresh (for staleness detection).
    last_fingerprint: Option<SkillFingerprint>,
    /// Working directory used for the last refresh.
    last_working_dir: Option<String>,
}

impl SkillRegistry {
    /// Create a new empty skill registry.
    pub fn new() -> Self {
        Self {
            skills: HashMap::new(),
            last_fingerprint: None,
            last_working_dir: None,
        }
    }

    /// Initialize the registry by scanning skill directories.
    ///
    /// Scans both global (`~/.tron/skills/`) and project-local skill directories.
    /// Project skills take precedence over global skills with the same name.
    pub fn initialize(&mut self, working_dir: &str) {
        let (global_result, project_result) = loader::scan_all(working_dir);

        // Add project skills — root-level skills come first in scan order and
        // shadow nested skills with the same name (first-write-wins).
        for skill in project_result.skills {
            let name = skill.name.clone();
            match self.skills.entry(name) {
                std::collections::hash_map::Entry::Vacant(e) => {
                    let _ = e.insert(skill);
                }
                std::collections::hash_map::Entry::Occupied(e) => {
                    debug!(
                        name = %e.key(),
                        existing_scope = %e.get().scope_dir,
                        shadowed_scope = %skill.scope_dir,
                        "Project skill shadowed by earlier-discovered skill with same name"
                    );
                }
            }
        }

        for err in &project_result.errors {
            warn!(path = %err.path, message = %err.message, "Project skill scan error");
        }

        // Add global skills only if not shadowed by project
        for skill in global_result.skills {
            if self.skills.contains_key(&skill.name) {
                debug!(name = %skill.name, "Global skill shadowed by project skill");
            } else {
                let _ = self.skills.insert(skill.name.clone(), skill);
            }
        }

        for error in &global_result.errors {
            warn!(path = %error.path, message = %error.message, "Global skill scan error");
        }

        debug!(count = self.skills.len(), "Skill registry initialized");
    }

    /// Get a skill by name.
    pub fn get(&self, name: &str) -> Option<&SkillMetadata> {
        self.skills.get(name)
    }

    /// Check if a skill exists.
    pub fn has(&self, name: &str) -> bool {
        self.skills.contains_key(name)
    }

    /// List skills as lightweight `SkillInfo`, optionally filtered by source.
    ///
    /// Results are sorted alphabetically by name.
    pub fn list(&self, source: Option<SkillSource>) -> Vec<SkillInfo> {
        let mut infos: Vec<SkillInfo> = self
            .skills
            .values()
            .filter(|s| source.is_none_or(|src| s.source == src))
            .map(SkillInfo::from)
            .collect();
        infos.sort_by(|a, b| a.name.cmp(&b.name));
        infos
    }

    /// List skills with full metadata, optionally filtered by source.
    ///
    /// Results are sorted alphabetically by name.
    pub fn list_full(&self, source: Option<SkillSource>) -> Vec<&SkillMetadata> {
        let mut skills: Vec<&SkillMetadata> = self
            .skills
            .values()
            .filter(|s| source.is_none_or(|src| s.source == src))
            .collect();
        skills.sort_by(|a, b| a.name.cmp(&b.name));
        skills
    }

    /// Get multiple skills by name.
    ///
    /// Returns `(found, not_found)` — found skills and names not in the registry.
    pub fn get_many(&self, names: &[&str]) -> (Vec<&SkillMetadata>, Vec<String>) {
        let mut found = Vec::new();
        let mut not_found = Vec::new();

        for name in names {
            match self.skills.get(*name) {
                Some(skill) => found.push(skill),
                None => not_found.push((*name).to_string()),
            }
        }

        (found, not_found)
    }

    /// Get the total number of skills.
    pub fn size(&self) -> usize {
        self.skills.len()
    }

    /// Remove a skill by name. Returns `true` if the skill existed and was removed.
    pub fn remove(&mut self, name: &str) -> bool {
        self.skills.remove(name).is_some()
    }

    /// Check if the registry has no skills.
    pub fn is_empty(&self) -> bool {
        self.skills.is_empty()
    }

    /// Clear and reload all skills from disk, updating the fingerprint.
    pub fn refresh(&mut self, working_dir: &str) {
        self.skills.clear();
        self.initialize(working_dir);
        self.last_fingerprint = Some(SkillFingerprint::compute(working_dir));
        self.last_working_dir = Some(working_dir.to_string());
    }

    /// Refresh only if skill directories have changed on disk.
    ///
    /// Computes a cheap filesystem fingerprint (stat calls only, no file reads)
    /// and compares it to the fingerprint from the last refresh. Returns `true`
    /// if a refresh was performed.
    ///
    /// This is designed to be called before every prompt — the fingerprint
    /// check is <1ms even with many skills.
    pub fn refresh_if_stale(&mut self, working_dir: &str) -> bool {
        let current = SkillFingerprint::compute(working_dir);

        // Check if working directory changed (session switched projects)
        let dir_changed = self.last_working_dir.as_deref() != Some(working_dir);

        if !dir_changed {
            if let Some(ref last) = self.last_fingerprint {
                if *last == current {
                    return false;
                }
            }
        }

        debug!("Skill directory changed on disk, refreshing registry");
        self.refresh(working_dir);
        true
    }

    /// Insert a skill directly (for testing or programmatic use).
    pub fn insert(&mut self, skill: SkillMetadata) {
        let _ = self.skills.insert(skill.name.clone(), skill);
    }
}

impl Default for SkillRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skills::types::SkillFrontmatter;

    fn make_skill(name: &str, display_name: &str, source: SkillSource) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: display_name.to_string(),
            description: format!("{display_name} skill"),
            content: format!("{display_name} content"),
            frontmatter: SkillFrontmatter::default(),
            source,
            scope_dir: String::new(),
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        }
    }

    fn make_registry_with_skills() -> SkillRegistry {
        let mut registry = SkillRegistry::new();
        registry.insert(make_skill("alpha", "Alpha", SkillSource::Global));
        registry.insert(make_skill("beta", "Beta", SkillSource::Global));
        registry
    }

    #[test]
    fn test_new_registry_is_empty() {
        let registry = SkillRegistry::new();
        assert_eq!(registry.size(), 0);
    }

    #[test]
    fn test_insert_and_get() {
        let registry = make_registry_with_skills();
        assert_eq!(registry.size(), 2);
        assert!(registry.has("alpha"));
        assert!(registry.has("beta"));
    }

    #[test]
    fn test_get_returns_skill() {
        let registry = make_registry_with_skills();
        let skill = registry.get("alpha").unwrap();
        assert_eq!(skill.display_name, "Alpha");
    }

    #[test]
    fn test_get_returns_none_for_unknown() {
        let registry = SkillRegistry::new();
        assert!(registry.get("nonexistent").is_none());
    }

    #[test]
    fn test_has_true_false() {
        let registry = make_registry_with_skills();
        assert!(registry.has("alpha"));
        assert!(!registry.has("nonexistent"));
    }

    #[test]
    fn test_list_sorted_by_name() {
        let registry = make_registry_with_skills();
        let list = registry.list(None);
        let names: Vec<&str> = list.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, vec!["alpha", "beta"]);
    }

    #[test]
    fn test_get_many() {
        let registry = make_registry_with_skills();
        let (found, not_found) = registry.get_many(&["alpha", "nonexistent"]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "alpha");
        assert_eq!(not_found, vec!["nonexistent"]);
    }

    #[test]
    fn test_list_filtered_by_source() {
        let mut registry = SkillRegistry::new();
        registry.insert(make_skill("global-only", "GO", SkillSource::Global));
        registry.insert(make_skill("project-only", "PO", SkillSource::Project));

        let global_list = registry.list(Some(SkillSource::Global));
        let project_list = registry.list(Some(SkillSource::Project));

        assert!(global_list.iter().any(|s| s.name == "global-only"));
        assert!(project_list.iter().any(|s| s.name == "project-only"));
        assert!(!global_list.iter().any(|s| s.name == "project-only"));
        assert!(!project_list.iter().any(|s| s.name == "global-only"));
    }

    #[test]
    fn test_list_full() {
        let registry = make_registry_with_skills();
        let full = registry.list_full(None);
        assert_eq!(full.len(), 2);
        assert!(!full[0].content.is_empty());
    }

    #[test]
    fn test_insert_overwrites() {
        let mut registry = SkillRegistry::new();
        registry.insert(make_skill("a", "First", SkillSource::Global));
        registry.insert(make_skill("a", "Second", SkillSource::Project));
        assert_eq!(registry.size(), 1);
        assert_eq!(registry.get("a").unwrap().display_name, "Second");
    }

    // --- SkillFingerprint ---

    #[test]
    fn fingerprint_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        let fp = SkillFingerprint::compute(dir.path().to_str().unwrap());
        // Should have entries for the non-existent skill dirs (recorded as 0)
        assert!(!fp.entries.is_empty());
    }

    #[test]
    fn fingerprint_equal_when_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path().to_str().unwrap();
        let fp1 = SkillFingerprint::compute(wd);
        let fp2 = SkillFingerprint::compute(wd);
        assert_eq!(fp1, fp2);
    }

    #[test]
    fn fingerprint_changes_when_skill_added() {
        let dir = tempfile::tempdir().unwrap();
        let skills_dir = dir.path().join(".tron/skills");
        std::fs::create_dir_all(&skills_dir).unwrap();
        let wd = dir.path().to_str().unwrap();

        let fp_before = SkillFingerprint::compute(wd);

        // Add a new skill
        let skill_dir = skills_dir.join("new-skill");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: New Skill\ndescription: A test\n---\nContent",
        )
        .unwrap();

        let fp_after = SkillFingerprint::compute(wd);
        assert_ne!(fp_before, fp_after);
    }

    #[test]
    fn fingerprint_changes_when_skill_md_modified() {
        let dir = tempfile::tempdir().unwrap();
        let skills_dir = dir.path().join(".tron/skills");
        let skill_dir = skills_dir.join("test-skill");
        std::fs::create_dir_all(&skill_dir).unwrap();
        let skill_md = skill_dir.join("SKILL.md");
        std::fs::write(&skill_md, "---\nname: Test\n---\nOriginal").unwrap();

        let wd = dir.path().to_str().unwrap();
        let fp_before = SkillFingerprint::compute(wd);

        // Wait to ensure mtime changes (filesystem granularity)
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(&skill_md, "---\nname: Test\n---\nModified").unwrap();

        let fp_after = SkillFingerprint::compute(wd);
        assert_ne!(fp_before, fp_after);
    }

    #[test]
    fn fingerprint_changes_when_skill_removed() {
        let dir = tempfile::tempdir().unwrap();
        let skills_dir = dir.path().join(".tron/skills");
        let skill_dir = skills_dir.join("doomed");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: Doomed\n---\nContent",
        )
        .unwrap();

        let wd = dir.path().to_str().unwrap();
        let fp_before = SkillFingerprint::compute(wd);

        std::fs::remove_dir_all(&skill_dir).unwrap();

        let fp_after = SkillFingerprint::compute(wd);
        assert_ne!(fp_before, fp_after);
    }

    #[test]
    fn fingerprint_nonexistent_dir_is_stable() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path().join("nonexistent").to_string_lossy().to_string();
        let fp1 = SkillFingerprint::compute(&wd);
        let fp2 = SkillFingerprint::compute(&wd);
        assert_eq!(fp1, fp2);
    }

    // --- refresh_if_stale ---

    #[test]
    fn refresh_if_stale_returns_true_on_first_call() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path().to_str().unwrap();
        let mut registry = SkillRegistry::new();
        assert!(registry.refresh_if_stale(wd));
    }

    #[test]
    fn refresh_if_stale_returns_false_when_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path().to_str().unwrap();
        let mut registry = SkillRegistry::new();
        registry.refresh_if_stale(wd);
        assert!(!registry.refresh_if_stale(wd));
    }

    #[test]
    fn refresh_if_stale_detects_new_skill() {
        let dir = tempfile::tempdir().unwrap();
        let skills_dir = dir.path().join(".tron/skills");
        std::fs::create_dir_all(&skills_dir).unwrap();
        let wd = dir.path().to_str().unwrap();

        let mut registry = SkillRegistry::new();
        registry.refresh_if_stale(wd);
        let initial_count = registry.size();
        assert!(!registry.has("hot-skill"));

        // Add a new skill to the project skills dir
        let skill_dir = skills_dir.join("hot-skill");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: Hot Skill\ndescription: Just added\n---\n# Hot Skill",
        )
        .unwrap();

        assert!(registry.refresh_if_stale(wd));
        assert!(registry.has("hot-skill"));
        assert_eq!(registry.size(), initial_count + 1);
    }

    #[test]
    fn refresh_if_stale_detects_working_dir_change() {
        let dir1 = tempfile::tempdir().unwrap();
        let dir2 = tempfile::tempdir().unwrap();
        let wd1 = dir1.path().to_str().unwrap();
        let wd2 = dir2.path().to_str().unwrap();

        let mut registry = SkillRegistry::new();
        registry.refresh_if_stale(wd1);
        // Different working dir should trigger refresh
        assert!(registry.refresh_if_stale(wd2));
    }

    #[test]
    fn refresh_stores_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let wd = dir.path().to_str().unwrap();
        let mut registry = SkillRegistry::new();
        assert!(registry.last_fingerprint.is_none());
        registry.refresh(wd);
        assert!(registry.last_fingerprint.is_some());
        assert_eq!(registry.last_working_dir.as_deref(), Some(wd));
    }

    // --- Nested discovery: fingerprint ---

    #[test]
    fn fingerprint_includes_nested_skills_dir() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("packages/foo/.claude/skills");
        std::fs::create_dir_all(&nested).unwrap();

        let fp = SkillFingerprint::compute(dir.path().to_str().unwrap());
        // Should have an entry for the nested skills dir
        let has_nested = fp
            .entries
            .keys()
            .any(|k| k.contains("packages/foo/.claude/skills"));
        assert!(has_nested, "Fingerprint should include nested skills dir");
    }

    #[test]
    fn fingerprint_detects_nested_skill_added() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("packages/foo/.claude/skills");
        std::fs::create_dir_all(&nested).unwrap();
        let wd = dir.path().to_str().unwrap();

        let fp_before = SkillFingerprint::compute(wd);

        // Add a skill in the nested dir
        let skill = nested.join("new-skill");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "---\nname: New\n---\nBody").unwrap();

        let fp_after = SkillFingerprint::compute(wd);
        assert_ne!(fp_before, fp_after);
    }

    #[test]
    fn fingerprint_detects_nested_dir_created() {
        let dir = tempfile::tempdir().unwrap();
        // Create the parent structure but NOT the .claude/skills/ dir
        std::fs::create_dir_all(dir.path().join("packages/bar")).unwrap();
        let wd = dir.path().to_str().unwrap();

        let fp_before = SkillFingerprint::compute(wd);

        // Now create .claude/skills/ in the sub-package
        std::fs::create_dir_all(dir.path().join("packages/bar/.claude/skills")).unwrap();

        let fp_after = SkillFingerprint::compute(wd);
        assert_ne!(fp_before, fp_after);
    }

    // --- Nested discovery: shadowing ---

    #[test]
    fn root_project_skill_shadows_nested() {
        let dir = tempfile::tempdir().unwrap();

        // Root-level skill
        let root_skills = dir.path().join(".claude/skills");
        std::fs::create_dir_all(root_skills.join("browser")).unwrap();
        std::fs::write(
            root_skills.join("browser/SKILL.md"),
            "---\nname: Root Browser\n---\nRoot version.",
        )
        .unwrap();

        // Nested skill with same name
        let nested_skills = dir.path().join("packages/foo/.claude/skills");
        std::fs::create_dir_all(nested_skills.join("browser")).unwrap();
        std::fs::write(
            nested_skills.join("browser/SKILL.md"),
            "---\nname: Nested Browser\n---\nNested version.",
        )
        .unwrap();

        let mut registry = SkillRegistry::new();
        registry.refresh(dir.path().to_str().unwrap());

        // Only one "browser" should exist — the root-level one
        assert!(registry.has("browser"));
        let skill = registry.get("browser").unwrap();
        assert_eq!(skill.display_name, "Root Browser");
        assert!(skill.scope_dir.is_empty());
    }

    #[test]
    fn nested_skill_not_shadowed_when_name_differs() {
        let dir = tempfile::tempdir().unwrap();

        let root_skills = dir.path().join(".claude/skills");
        std::fs::create_dir_all(root_skills.join("browser")).unwrap();
        std::fs::write(
            root_skills.join("browser/SKILL.md"),
            "---\nname: Browser\n---\nBrowse.",
        )
        .unwrap();

        let nested_skills = dir.path().join("packages/foo/.claude/skills");
        std::fs::create_dir_all(nested_skills.join("deploy")).unwrap();
        std::fs::write(
            nested_skills.join("deploy/SKILL.md"),
            "---\nname: Deploy\n---\nDeploy.",
        )
        .unwrap();

        let mut registry = SkillRegistry::new();
        registry.refresh(dir.path().to_str().unwrap());

        // Both project skills coexist (global skills may also be present)
        assert!(registry.has("browser"));
        assert!(registry.has("deploy"));
        assert_eq!(registry.get("deploy").unwrap().scope_dir, "packages/foo");
    }

    #[test]
    fn refresh_if_stale_detects_nested_changes() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("packages/foo/.claude/skills");
        std::fs::create_dir_all(&nested).unwrap();
        let wd = dir.path().to_str().unwrap();

        let mut registry = SkillRegistry::new();
        registry.refresh_if_stale(wd);
        assert!(!registry.has("new-skill"));

        // Add a skill in the nested dir
        let skill = nested.join("new-skill");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(skill.join("SKILL.md"), "---\nname: New\n---\nBody").unwrap();

        assert!(registry.refresh_if_stale(wd));
        assert!(registry.has("new-skill"));
        assert_eq!(
            registry.get("new-skill").unwrap().scope_dir,
            "packages/foo"
        );
    }
}
