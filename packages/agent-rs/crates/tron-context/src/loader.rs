//! Hierarchical context file loader.
//!
//! Loads AGENTS.md / agents.md / CLAUDE.md / claude.md from project-level
//! and directory-level locations, merges them in depth order, and supports
//! caching with freshness validation.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

// =============================================================================
// Types
// =============================================================================

/// A loaded context file.
#[derive(Clone, Debug)]
pub struct ContextFile {
    /// Absolute path.
    pub path: PathBuf,
    /// File content.
    pub content: String,
    /// Where the file was found.
    pub level: ContextLevel,
    /// Distance from project root (0 = project root).
    pub depth: usize,
}

/// Where a context file was found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ContextLevel {
    /// Root-level file (`.claude/AGENTS.md` or similar).
    Project,
    /// Nested directory file.
    Directory,
}

/// Result of loading context.
#[derive(Clone, Debug)]
pub struct LoadedContext {
    /// Merged content from all files.
    pub merged: String,
    /// Individual files in depth order.
    pub files: Vec<ContextFile>,
}

/// Configuration for the loader.
#[derive(Clone, Debug)]
pub struct ContextLoaderConfig {
    /// Absolute path to project root.
    pub project_root: PathBuf,
    /// File names to search for (in priority order).
    pub file_names: Vec<String>,
    /// Agent directory names (`.claude`, `.tron`, `.agent`).
    pub agent_dirs: Vec<String>,
    /// Maximum directory traversal depth.
    pub max_depth: usize,
}

impl Default for ContextLoaderConfig {
    fn default() -> Self {
        Self {
            project_root: PathBuf::from("."),
            file_names: vec![
                "AGENTS.md".into(),
                "agents.md".into(),
                "CLAUDE.md".into(),
                "claude.md".into(),
            ],
            agent_dirs: vec![".claude".into(), ".tron".into(), ".agent".into()],
            max_depth: 5,
        }
    }
}

// =============================================================================
// ContextLoader
// =============================================================================

/// Loads and merges context files from a project hierarchy.
pub struct ContextLoader {
    config: ContextLoaderConfig,
    cache: HashMap<PathBuf, CachedContext>,
}

/// Cached context with freshness tracking.
#[derive(Clone, Debug)]
struct CachedContext {
    result: LoadedContext,
    /// File paths and their modification times at load time.
    file_mtimes: Vec<(PathBuf, std::time::SystemTime)>,
}

impl ContextLoader {
    /// Create a new context loader with the given configuration.
    pub fn new(config: ContextLoaderConfig) -> Self {
        Self {
            config,
            cache: HashMap::new(),
        }
    }

    /// Load context for a target directory.
    ///
    /// Checks the cache first. If stale or missing, performs a fresh load.
    pub fn load(&mut self, target_dir: &Path) -> std::io::Result<LoadedContext> {
        let target = target_dir.to_path_buf();

        // Check cache freshness
        if let Some(cached) = self.cache.get(&target) {
            if is_cache_fresh(&cached.file_mtimes) {
                return Ok(cached.result.clone());
            }
        }

        let result = self.load_fresh(target_dir)?;

        // Cache with mtime tracking
        let file_mtimes: Vec<(PathBuf, std::time::SystemTime)> = result
            .files
            .iter()
            .filter_map(|f| {
                std::fs::metadata(&f.path)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .map(|mtime| (f.path.clone(), mtime))
            })
            .collect();

        let _ = self.cache.insert(
            target,
            CachedContext {
                result: result.clone(),
                file_mtimes,
            },
        );

        Ok(result)
    }

    /// Load without caching.
    fn load_fresh(&self, target_dir: &Path) -> std::io::Result<LoadedContext> {
        let mut files = Vec::new();

        // 1. Load project-level context
        if let Some(project_file) = self.load_project_context()? {
            files.push(project_file);
        }

        // 2. Load directory-level contexts (walk from root to target)
        let dir_files = self.load_directory_contexts(target_dir)?;
        files.extend(dir_files);

        // 3. Merge
        let merged = merge_contexts(&files);

        Ok(LoadedContext { merged, files })
    }

    /// Find a context file at the project root.
    ///
    /// Search order:
    /// 1. Agent dirs (`.claude/`, `.tron/`, `.agent/`) for each filename
    /// 2. Project root for each filename
    fn load_project_context(&self) -> std::io::Result<Option<ContextFile>> {
        let root = &self.config.project_root;

        // Check agent directories first
        for dir_name in &self.config.agent_dirs {
            let dir_path = root.join(dir_name);
            if dir_path.is_dir() {
                for file_name in &self.config.file_names {
                    let file_path = dir_path.join(file_name);
                    if file_path.is_file() {
                        let content = std::fs::read_to_string(&file_path)?;
                        return Ok(Some(ContextFile {
                            path: file_path,
                            content,
                            level: ContextLevel::Project,
                            depth: 0,
                        }));
                    }
                }
            }
        }

        // Check project root directly
        for file_name in &self.config.file_names {
            let file_path = root.join(file_name);
            if file_path.is_file() {
                let content = std::fs::read_to_string(&file_path)?;
                return Ok(Some(ContextFile {
                    path: file_path,
                    content,
                    level: ContextLevel::Project,
                    depth: 0,
                }));
            }
        }

        Ok(None)
    }

    /// Load directory-level context files by walking from root to target.
    fn load_directory_contexts(
        &self,
        target_dir: &Path,
    ) -> std::io::Result<Vec<ContextFile>> {
        let root = &self.config.project_root;
        let mut files = Vec::new();

        // Build path segments from root to target
        let relative = match target_dir.strip_prefix(root) {
            Ok(rel) => rel.to_path_buf(),
            Err(_) => return Ok(files), // target outside project root
        };

        let mut current = root.clone();
        for (depth_offset, component) in relative.components().enumerate() {
            current = current.join(component);
            let depth = depth_offset + 1;

            if depth > self.config.max_depth {
                break;
            }

            if let Some(file) = self.find_context_file_in(&current, depth)? {
                files.push(file);
            }
        }

        Ok(files)
    }

    /// Search for a context file in a specific directory.
    fn find_context_file_in(
        &self,
        dir: &Path,
        depth: usize,
    ) -> std::io::Result<Option<ContextFile>> {
        // Check agent subdirectories
        for agent_dir in &self.config.agent_dirs {
            let agent_path = dir.join(agent_dir);
            if agent_path.is_dir() {
                for file_name in &self.config.file_names {
                    let file_path = agent_path.join(file_name);
                    if file_path.is_file() {
                        let content = std::fs::read_to_string(&file_path)?;
                        return Ok(Some(ContextFile {
                            path: file_path,
                            content,
                            level: ContextLevel::Directory,
                            depth,
                        }));
                    }
                }
            }
        }

        // Check directory root
        for file_name in &self.config.file_names {
            let file_path = dir.join(file_name);
            if file_path.is_file() {
                let content = std::fs::read_to_string(&file_path)?;
                return Ok(Some(ContextFile {
                    path: file_path,
                    content,
                    level: ContextLevel::Directory,
                    depth,
                }));
            }
        }

        Ok(None)
    }

    /// Clear all cached contexts.
    pub fn clear_cache(&mut self) {
        self.cache.clear();
    }

    /// Invalidate cache for a specific directory.
    pub fn invalidate_cache(&mut self, dir: &Path) {
        let _ = self.cache.remove(dir);
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Merge context files into a single string.
///
/// Files are in depth order (shallowest first). Each file is prefixed with
/// a comment indicating its source.
fn merge_contexts(files: &[ContextFile]) -> String {
    let mut parts = Vec::with_capacity(files.len());
    for file in files {
        parts.push(file.content.clone());
    }
    parts.join("\n\n")
}

/// Check if a cache entry is still fresh by comparing file mtimes.
fn is_cache_fresh(file_mtimes: &[(PathBuf, std::time::SystemTime)]) -> bool {
    for (path, cached_mtime) in file_mtimes {
        match std::fs::metadata(path) {
            Ok(meta) => {
                if let Ok(current_mtime) = meta.modified() {
                    if current_mtime != *cached_mtime {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            Err(_) => return false, // File was deleted
        }
    }
    true
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn create_temp_project() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let tid = std::thread::current().id();
        let dir = std::env::temp_dir().join(format!("tron-loader-{tid:?}-{id}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn cleanup(dir: &Path) {
        let _ = fs::remove_dir_all(dir);
    }

    // -- load_project_context --

    #[test]
    fn load_project_context_from_agent_dir() {
        let root = create_temp_project();
        let claude_dir = root.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(claude_dir.join("AGENTS.md"), "# Project Rules").unwrap();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let result = loader.load_project_context().unwrap().unwrap();
        assert_eq!(result.content, "# Project Rules");
        assert_eq!(result.level, ContextLevel::Project);
        assert_eq!(result.depth, 0);

        cleanup(&root);
    }

    #[test]
    fn load_project_context_from_root() {
        let root = create_temp_project();
        fs::write(root.join("AGENTS.md"), "# Root Rules").unwrap();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let result = loader.load_project_context().unwrap().unwrap();
        assert_eq!(result.content, "# Root Rules");

        cleanup(&root);
    }

    #[test]
    fn load_project_context_agent_dir_priority() {
        let root = create_temp_project();
        let claude_dir = root.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(claude_dir.join("AGENTS.md"), "agent dir version").unwrap();
        fs::write(root.join("AGENTS.md"), "root version").unwrap();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let result = loader.load_project_context().unwrap().unwrap();
        assert_eq!(result.content, "agent dir version");

        cleanup(&root);
    }

    #[test]
    fn load_project_context_none_found() {
        let root = create_temp_project();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        assert!(loader.load_project_context().unwrap().is_none());

        cleanup(&root);
    }

    #[test]
    fn load_project_context_file_name_priority() {
        let root = create_temp_project();
        fs::write(root.join("CLAUDE.md"), "claude").unwrap();
        fs::write(root.join("AGENTS.md"), "agents").unwrap();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        // AGENTS.md comes first in default file_names
        let result = loader.load_project_context().unwrap().unwrap();
        assert_eq!(result.content, "agents");

        cleanup(&root);
    }

    // -- load_directory_contexts --

    #[test]
    fn load_directory_contexts_nested() {
        let root = create_temp_project();
        let subdir = root.join("packages").join("agent");
        fs::create_dir_all(&subdir).unwrap();
        fs::write(
            root.join("packages").join("AGENTS.md"),
            "# Packages Rules",
        )
        .unwrap();
        fs::write(subdir.join("AGENTS.md"), "# Agent Rules").unwrap();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let files = loader.load_directory_contexts(&subdir).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].depth, 1);
        assert_eq!(files[0].level, ContextLevel::Directory);
        assert_eq!(files[1].depth, 2);

        cleanup(&root);
    }

    #[test]
    fn load_directory_contexts_outside_root() {
        let root = create_temp_project();

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let files = loader
            .load_directory_contexts(Path::new("/totally/different"))
            .unwrap();
        assert!(files.is_empty());

        cleanup(&root);
    }

    #[test]
    fn load_directory_contexts_max_depth() {
        let root = create_temp_project();
        let deep = root.join("a").join("b").join("c").join("d").join("e").join("f");
        fs::create_dir_all(&deep).unwrap();
        // Write files at each level
        for (i, name) in ["a", "b", "c", "d", "e", "f"].iter().enumerate() {
            let mut path = root.clone();
            for n in &["a", "b", "c", "d", "e", "f"][..=i] {
                path = path.join(n);
            }
            fs::write(path.join("AGENTS.md"), format!("level {name}")).unwrap();
        }

        let loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            max_depth: 3,
            ..ContextLoaderConfig::default()
        });
        let files = loader.load_directory_contexts(&deep).unwrap();
        assert!(files.len() <= 3);

        cleanup(&root);
    }

    // -- full load --

    #[test]
    fn load_merges_project_and_directory() {
        let root = create_temp_project();
        let claude_dir = root.join(".claude");
        let subdir = root.join("src");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::create_dir_all(&subdir).unwrap();
        fs::write(claude_dir.join("AGENTS.md"), "project rules").unwrap();
        fs::write(subdir.join("AGENTS.md"), "src rules").unwrap();

        let mut loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let result = loader.load(&subdir).unwrap();
        assert_eq!(result.files.len(), 2);
        assert!(result.merged.contains("project rules"));
        assert!(result.merged.contains("src rules"));

        cleanup(&root);
    }

    #[test]
    fn load_empty_project() {
        let root = create_temp_project();

        let mut loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let result = loader.load(&root).unwrap();
        assert!(result.files.is_empty());
        assert!(result.merged.is_empty());

        cleanup(&root);
    }

    // -- caching --

    #[test]
    fn load_uses_cache() {
        let root = create_temp_project();
        fs::write(root.join("AGENTS.md"), "cached content").unwrap();

        let mut loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });

        let r1 = loader.load(&root).unwrap();
        assert!(r1.merged.contains("cached content"));

        // Modify file but cache should still return old content (same mtime on fast fs)
        // We test by checking the cache exists
        assert!(!loader.cache.is_empty());

        cleanup(&root);
    }

    #[test]
    fn clear_cache() {
        let root = create_temp_project();
        fs::write(root.join("AGENTS.md"), "content").unwrap();

        let mut loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let _ = loader.load(&root).unwrap();
        assert!(!loader.cache.is_empty());

        loader.clear_cache();
        assert!(loader.cache.is_empty());

        cleanup(&root);
    }

    #[test]
    fn invalidate_cache_specific() {
        let root = create_temp_project();
        let src = root.join("src");
        fs::create_dir_all(&src).unwrap();
        fs::write(root.join("AGENTS.md"), "root").unwrap();
        fs::write(src.join("AGENTS.md"), "src").unwrap();

        let mut loader = ContextLoader::new(ContextLoaderConfig {
            project_root: root.clone(),
            ..ContextLoaderConfig::default()
        });
        let _ = loader.load(&root).unwrap();
        let _ = loader.load(&src).unwrap();
        assert_eq!(loader.cache.len(), 2);

        loader.invalidate_cache(&src);
        assert_eq!(loader.cache.len(), 1);

        cleanup(&root);
    }

    // -- merge_contexts --

    #[test]
    fn merge_single_file() {
        let files = vec![ContextFile {
            path: "/f.md".into(),
            content: "hello".into(),
            level: ContextLevel::Project,
            depth: 0,
        }];
        assert_eq!(merge_contexts(&files), "hello");
    }

    #[test]
    fn merge_multiple_files() {
        let files = vec![
            ContextFile {
                path: "/a.md".into(),
                content: "first".into(),
                level: ContextLevel::Project,
                depth: 0,
            },
            ContextFile {
                path: "/b.md".into(),
                content: "second".into(),
                level: ContextLevel::Directory,
                depth: 1,
            },
        ];
        let result = merge_contexts(&files);
        assert!(result.contains("first"));
        assert!(result.contains("second"));
        // Project file comes first
        assert!(result.find("first").unwrap() < result.find("second").unwrap());
    }

    #[test]
    fn merge_empty() {
        assert!(merge_contexts(&[]).is_empty());
    }
}
