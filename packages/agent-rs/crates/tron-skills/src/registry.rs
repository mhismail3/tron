//! In-memory skill registry.
//!
//! Maintains a `HashMap` of skills keyed by name. Project skills take
//! precedence over global skills with the same name.

use std::collections::HashMap;

use tracing::{debug, warn};

use crate::loader;
use crate::types::{SkillInfo, SkillMetadata, SkillSource};

/// In-memory registry of available skills.
#[derive(Debug)]
pub struct SkillRegistry {
    skills: HashMap<String, SkillMetadata>,
}

impl SkillRegistry {
    /// Create a new empty skill registry.
    pub fn new() -> Self {
        Self {
            skills: HashMap::new(),
        }
    }

    /// Initialize the registry by scanning skill directories.
    ///
    /// Scans both global (`~/.tron/skills/`) and project-local skill directories.
    /// Project skills take precedence over global skills with the same name.
    pub fn initialize(&mut self, working_dir: &str) {
        let (global_result, project_result) = loader::scan_all(working_dir);

        // Add project skills first (they take precedence)
        for skill in project_result.skills {
            let _ = self.skills.insert(skill.name.clone(), skill);
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

    /// Clear and reload all skills.
    pub fn refresh(&mut self, working_dir: &str) {
        self.skills.clear();
        self.initialize(working_dir);
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
    use crate::types::SkillFrontmatter;

    fn make_skill(name: &str, display_name: &str, source: SkillSource) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: display_name.to_string(),
            description: format!("{display_name} skill"),
            content: format!("{display_name} content"),
            frontmatter: SkillFrontmatter::default(),
            source,
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
}
