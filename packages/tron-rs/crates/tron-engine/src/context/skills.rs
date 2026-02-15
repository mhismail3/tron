use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// A loaded skill definition.
#[derive(Clone, Debug)]
pub struct Skill {
    pub name: String,
    pub path: PathBuf,
    pub content: String,
    pub frontmatter: SkillFrontmatter,
}

/// Parsed YAML frontmatter from a skill file.
#[derive(Clone, Debug, Default)]
pub struct SkillFrontmatter {
    pub description: Option<String>,
    pub allowed_tools: Vec<String>,
    pub denied_tools: Vec<String>,
}

/// Registry of available skills, loaded from disk.
#[derive(Default)]
pub struct SkillRegistry {
    skills: HashMap<String, Skill>,
}

impl SkillRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Load skills from global (~/.tron/skills/) and project (.tron/skills/) dirs.
    /// Project skills shadow global skills with the same name.
    pub fn load(global_dir: &Path, project_dir: &Path) -> Self {
        let mut registry = Self::new();

        // Load global skills first
        registry.load_from_dir(global_dir);

        // Project skills shadow global
        registry.load_from_dir(project_dir);

        registry
    }

    /// Get a skill by name.
    pub fn get(&self, name: &str) -> Option<&Skill> {
        self.skills.get(name)
    }

    /// List all skill names.
    pub fn list(&self) -> Vec<&str> {
        let mut names: Vec<&str> = self.skills.keys().map(|s| s.as_str()).collect();
        names.sort();
        names
    }

    /// Total skill count.
    pub fn count(&self) -> usize {
        self.skills.len()
    }

    /// Extract @skill-name references from text.
    pub fn extract_references(text: &str) -> Vec<String> {
        let mut refs = Vec::new();
        for word in text.split_whitespace() {
            if let Some(name) = word.strip_prefix('@') {
                let name = name.trim_end_matches(|c: char| !c.is_alphanumeric() && c != '-' && c != '_');
                if !name.is_empty() {
                    refs.push(name.to_string());
                }
            }
        }
        refs
    }

    /// Format active skills as XML for context injection.
    pub fn format_skills(&self, names: &[String]) -> Option<String> {
        let mut parts = Vec::new();
        for name in names {
            if let Some(skill) = self.skills.get(name) {
                parts.push(format!(
                    "<skill name=\"{}\">\n{}\n</skill>",
                    skill.name, skill.content
                ));
            }
        }
        if parts.is_empty() {
            return None;
        }
        Some(format!("<skills>\n{}\n</skills>", parts.join("\n")))
    }

    fn load_from_dir(&mut self, dir: &Path) {
        if !dir.is_dir() {
            return;
        }
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|e| e != "md") {
                continue;
            }
            if let Some(skill) = load_skill(&path) {
                self.skills.insert(skill.name.clone(), skill);
            }
        }
    }
}

fn load_skill(path: &Path) -> Option<Skill> {
    let raw = std::fs::read_to_string(path).ok()?;
    let name = path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())?;

    let (frontmatter, content) = parse_frontmatter(&raw);

    if content.trim().is_empty() {
        return None;
    }

    Some(Skill {
        name,
        path: path.to_path_buf(),
        content,
        frontmatter,
    })
}

fn parse_frontmatter(raw: &str) -> (SkillFrontmatter, String) {
    if !raw.starts_with("---\n") {
        return (SkillFrontmatter::default(), raw.to_string());
    }

    let after_start = &raw[4..];
    let end = match after_start.find("\n---") {
        Some(pos) => pos,
        None => return (SkillFrontmatter::default(), raw.to_string()),
    };

    let yaml_str = &after_start[..end];
    let content = after_start[end + 4..].trim_start().to_string();

    let frontmatter = parse_yaml_frontmatter(yaml_str);
    (frontmatter, content)
}

fn parse_yaml_frontmatter(yaml: &str) -> SkillFrontmatter {
    let mut fm = SkillFrontmatter::default();
    for line in yaml.lines() {
        let line = line.trim();
        if let Some(desc) = line.strip_prefix("description:") {
            fm.description = Some(desc.trim().trim_matches('"').to_string());
        } else if let Some(tools) = line.strip_prefix("allowedTools:") {
            fm.allowed_tools = parse_yaml_list(tools);
        } else if let Some(tools) = line.strip_prefix("deniedTools:") {
            fm.denied_tools = parse_yaml_list(tools);
        }
    }
    fm
}

fn parse_yaml_list(value: &str) -> Vec<String> {
    let trimmed = value.trim();
    if trimmed.starts_with('[') && trimmed.ends_with(']') {
        trimmed[1..trimmed.len() - 1]
            .split(',')
            .map(|s| s.trim().trim_matches('"').trim_matches('\'').to_string())
            .filter(|s| !s.is_empty())
            .collect()
    } else {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tron_skills_test_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn load_skill_from_file() {
        let dir = temp_dir();
        fs::write(
            dir.join("commit.md"),
            "---\ndescription: \"Commit changes\"\n---\nCommit the staged changes.",
        )
        .unwrap();

        let registry = SkillRegistry::load(&dir, &PathBuf::from("/nonexistent"));
        assert_eq!(registry.count(), 1);
        let skill = registry.get("commit").unwrap();
        assert_eq!(skill.name, "commit");
        assert!(skill.content.contains("Commit the staged changes"));
        assert_eq!(skill.frontmatter.description.as_deref(), Some("Commit changes"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn project_shadows_global() {
        let global = temp_dir();
        let project = temp_dir();

        fs::write(global.join("review.md"), "Global review skill.").unwrap();
        fs::write(project.join("review.md"), "Project review skill.").unwrap();

        let registry = SkillRegistry::load(&global, &project);
        assert_eq!(registry.count(), 1);
        let skill = registry.get("review").unwrap();
        assert!(skill.content.contains("Project review"));

        fs::remove_dir_all(&global).ok();
        fs::remove_dir_all(&project).ok();
    }

    #[test]
    fn extract_references() {
        let refs = SkillRegistry::extract_references("Please use @commit to commit and @review for review.");
        assert_eq!(refs, vec!["commit", "review"]);
    }

    #[test]
    fn extract_references_with_punctuation() {
        let refs = SkillRegistry::extract_references("Run @build, then @test.");
        assert_eq!(refs, vec!["build", "test"]);
    }

    #[test]
    fn format_skills_xml() {
        let dir = temp_dir();
        fs::write(dir.join("test.md"), "Run all tests.").unwrap();

        let registry = SkillRegistry::load(&dir, &PathBuf::from("/nonexistent"));
        let xml = registry.format_skills(&["test".to_string()]).unwrap();
        assert!(xml.contains("<skills>"));
        assert!(xml.contains("<skill name=\"test\">"));
        assert!(xml.contains("Run all tests."));
        assert!(xml.contains("</skills>"));

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn format_unknown_skill_returns_none() {
        let registry = SkillRegistry::new();
        assert!(registry.format_skills(&["nonexistent".to_string()]).is_none());
    }

    #[test]
    fn empty_skill_file_skipped() {
        let dir = temp_dir();
        fs::write(dir.join("empty.md"), "").unwrap();
        fs::write(dir.join("whitespace.md"), "  \n  ").unwrap();

        let registry = SkillRegistry::load(&dir, &PathBuf::from("/nonexistent"));
        assert_eq!(registry.count(), 0);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn frontmatter_with_tool_constraints() {
        let dir = temp_dir();
        fs::write(
            dir.join("safe.md"),
            "---\ndescription: \"Safe skill\"\nallowedTools: [Read, Glob, Grep]\ndeniedTools: [Bash, Write]\n---\nOnly read operations.",
        )
        .unwrap();

        let registry = SkillRegistry::load(&dir, &PathBuf::from("/nonexistent"));
        let skill = registry.get("safe").unwrap();
        assert_eq!(skill.frontmatter.allowed_tools, vec!["Read", "Glob", "Grep"]);
        assert_eq!(skill.frontmatter.denied_tools, vec!["Bash", "Write"]);

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn list_skills_sorted() {
        let dir = temp_dir();
        fs::write(dir.join("beta.md"), "Beta skill.").unwrap();
        fs::write(dir.join("alpha.md"), "Alpha skill.").unwrap();
        fs::write(dir.join("gamma.md"), "Gamma skill.").unwrap();

        let registry = SkillRegistry::load(&dir, &PathBuf::from("/nonexistent"));
        let names = registry.list();
        assert_eq!(names, vec!["alpha", "beta", "gamma"]);

        fs::remove_dir_all(&dir).ok();
    }
}
