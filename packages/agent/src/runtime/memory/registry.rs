//! In-memory registry for user-memory content.
//!
//! Caches the rendered content of `~/.tron/memory/MEMORY.md`
//! plus the listing of detail files under `rules/`. Re-reads only when
//! the filesystem fingerprint (mtime of `MEMORY.md` + every `rules/*.md`)
//! changes. See [`MemoryFingerprint`] for scope and [`MemoryRegistry`]
//! for the public API.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::UNIX_EPOCH;

use tracing::{error, warn};

use crate::core::paths;

/// Soft size cap on `MEMORY.md` — above this, a `tracing::warn!` fires but
/// the full content is still injected. Matches the "keep MEMORY.md lightweight"
/// design intent without hard-clipping user data.
const MEMORY_MD_WARN_BYTES: u64 = 100 * 1024; // 100KB

/// Hard size cap on `MEMORY.md` — above this, the loader injects a truncation
/// stub (first 10KB + notice) to prevent one runaway file from wrecking every
/// turn's context.
const MEMORY_MD_HARD_CAP_BYTES: u64 = 1024 * 1024; // 1MB

/// Bytes preserved when the hard cap fires.
const MEMORY_MD_TRUNCATION_BYTES: usize = 10 * 1024;

// =============================================================================
// Fingerprint
// =============================================================================

/// Filesystem fingerprint of the user-memory directory.
///
/// Records second-precision mtimes for `MEMORY.md` and every direct child
/// under `rules/` ending in `.md`. `sessions/` is deliberately excluded
/// (see module doc). Two fingerprints are equal iff they contain exactly
/// the same `(path, mtime)` pairs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MemoryFingerprint {
    /// Sorted map of absolute path -> mtime (seconds since epoch).
    /// Missing files record as mtime `0` so absence is captured explicitly
    /// and a future create flips the fingerprint.
    entries: BTreeMap<String, u64>,
}

impl MemoryFingerprint {
    /// Compute a fingerprint against the process's resolved `$HOME`.
    pub fn compute() -> Self {
        Self::compute_for_home(&paths::home_dir())
    }

    /// Compute a fingerprint against a caller-supplied home path.
    ///
    /// Lets tests point scans at a tempdir without manipulating `$HOME`
    /// (the workspace lints `unsafe_code = "deny"`).
    pub fn compute_for_home(home: &str) -> Self {
        let mut entries = BTreeMap::new();

        // MEMORY.md: record mtime or 0 if absent. Absence is still an entry
        // so a future create flips the fingerprint.
        let memory_md = paths::memory_file_for_home(home);
        let _ = entries.insert(
            memory_md.to_string_lossy().into_owned(),
            Self::mtime_or_zero(&memory_md),
        );

        // rules/*.md: flat scan, only files directly under rules/.
        let rules = paths::memory_rules_dir_for_home(home);
        if let Ok(read_dir) = std::fs::read_dir(&rules) {
            for entry in read_dir.flatten() {
                let path = entry.path();
                // Skip nested directories (flat convention).
                let is_file = entry
                    .file_type()
                    .map(|t| t.is_file() || t.is_symlink())
                    .unwrap_or(false);
                if !is_file {
                    continue;
                }
                // Only `.md` files count.
                if path.extension().and_then(|e| e.to_str()) != Some("md") {
                    continue;
                }
                let _ = entries.insert(
                    path.to_string_lossy().into_owned(),
                    Self::mtime_or_zero(&path),
                );
            }
        }

        // sessions/ deliberately NOT scanned — retain system writes there.

        Self { entries }
    }

    fn mtime_or_zero(path: &Path) -> u64 {
        std::fs::metadata(path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
}

// =============================================================================
// Rule file listing
// =============================================================================

/// One entry in the `rules/` directory listing.
///
/// `description` comes from YAML frontmatter (first `---` block,
/// single-line `description:` value). Falls back to `None` when the file
/// has no frontmatter, no `description:` field, or uses an unsupported
/// multi-line YAML form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryRuleFile {
    /// Filename relative to `rules/` (e.g. `"user-preferences.md"`).
    pub name: String,
    /// Single-line description from YAML frontmatter, if any.
    pub description: Option<String>,
}

// =============================================================================
// Registry
// =============================================================================

/// Cached user-memory content + rules listing.
///
/// Holds the last-computed fingerprint and the last-rendered content.
/// `content()` re-reads only when the fingerprint flips. See module doc
/// for the full invariant set.
#[derive(Debug, Default)]
pub struct MemoryRegistry {
    last_fingerprint: Option<MemoryFingerprint>,
    /// Cached rendered content (MEMORY.md body + rules listing footer,
    /// or bootstrap stub if MEMORY.md is absent).
    cached_content: Option<String>,
    /// Cached rule-file listing (parsed for iOS wire format).
    cached_rule_files: Vec<MemoryRuleFile>,
    /// Cached `bootstrapped` flag (true iff `MEMORY.md` exists + readable).
    cached_bootstrapped: bool,
}

impl MemoryRegistry {
    /// Create a new empty registry. The first `content()` call populates caches.
    pub fn new() -> Self {
        Self::default()
    }

    /// Rendered content to inject into the LLM-bound context.
    ///
    /// Re-reads filesystem on fingerprint mismatch; otherwise returns the
    /// cached string. Always returns `Some` content — either the rendered
    /// MEMORY.md + rules listing, or the bootstrap stub when MEMORY.md is
    /// absent. The caller passes this to `ContextManager::set_memory_content`.
    pub fn content(&mut self, home: &str) -> &str {
        self.refresh_if_stale(home);
        self.cached_content.as_deref().unwrap_or("")
    }

    /// Wire-format listing of `rules/*.md` files (for iOS MemorySection).
    pub fn list_rule_files(&mut self, home: &str) -> Vec<MemoryRuleFile> {
        self.refresh_if_stale(home);
        self.cached_rule_files.clone()
    }

    /// Whether `MEMORY.md` exists and was readable at last fingerprint.
    pub fn memory_md_exists(&mut self, home: &str) -> bool {
        self.refresh_if_stale(home);
        self.cached_bootstrapped
    }

    fn refresh_if_stale(&mut self, home: &str) {
        let fp = MemoryFingerprint::compute_for_home(home);
        if self.last_fingerprint.as_ref() == Some(&fp) {
            return;
        }
        self.rebuild(home);
        self.last_fingerprint = Some(fp);
    }

    fn rebuild(&mut self, home: &str) {
        // Load MEMORY.md (if present + readable).
        let memory_md_path = paths::memory_file_for_home(home);
        let memory_md_body = match std::fs::read_to_string(&memory_md_path) {
            Ok(body) => {
                let size = body.len() as u64;
                if size > MEMORY_MD_HARD_CAP_BYTES {
                    error!(
                        bytes = size,
                        "MEMORY.md exceeds hard cap ({} bytes); truncating to {} bytes",
                        MEMORY_MD_HARD_CAP_BYTES,
                        MEMORY_MD_TRUNCATION_BYTES
                    );
                    Some(truncation_stub(&body))
                } else {
                    if size > MEMORY_MD_WARN_BYTES {
                        warn!(
                            bytes = size,
                            "MEMORY.md is unusually large ({} bytes). Keep it lightweight — \
                             promote detail topics to rules/*.md files.",
                            size
                        );
                    }
                    Some(body)
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => {
                warn!(
                    error = %e,
                    path = %memory_md_path.display(),
                    "failed to read MEMORY.md; treating as absent"
                );
                None
            }
        };

        // Scan rules/*.md for the listing.
        let mut rule_files = scan_rule_files(home);
        // Deterministic ordering for deterministic tests + UI.
        rule_files.sort_by(|a, b| a.name.cmp(&b.name));

        self.cached_bootstrapped = memory_md_body.is_some();
        self.cached_rule_files = rule_files.clone();
        self.cached_content = Some(render_content(memory_md_body.as_deref(), &rule_files));
    }
}

// =============================================================================
// Rule file scanning
// =============================================================================

fn scan_rule_files(home: &str) -> Vec<MemoryRuleFile> {
    let rules = paths::memory_rules_dir_for_home(home);
    let Ok(read_dir) = std::fs::read_dir(&rules) else {
        return Vec::new();
    };

    let mut out = Vec::new();
    for entry in read_dir.flatten() {
        let path = entry.path();
        let is_file = entry
            .file_type()
            .map(|t| t.is_file() || t.is_symlink())
            .unwrap_or(false);
        if !is_file {
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let description = std::fs::read_to_string(&path)
            .ok()
            .as_deref()
            .and_then(extract_description);
        out.push(MemoryRuleFile {
            name: name.to_string(),
            description,
        });
    }
    out
}

// =============================================================================
// Content rendering
// =============================================================================

fn render_content(memory_md: Option<&str>, rule_files: &[MemoryRuleFile]) -> String {
    let mut out = String::new();
    match memory_md {
        Some(body) => {
            out.push_str(body);
            if !body.ends_with('\n') {
                out.push('\n');
            }
        }
        None => {
            out.push_str(bootstrap_stub());
        }
    }

    // Always append the rules listing (even when empty — keeps the agent
    // aware that the location exists).
    out.push_str("\n## Detail files (not auto-loaded — Read on demand)\n\n");
    out.push_str("Path: `~/.tron/memory/rules/`\n\n");
    if rule_files.is_empty() {
        out.push_str(
            "_No detail files yet. When you learn a larger topic about the user, \
                      create `~/.tron/memory/rules/<topic>.md` with YAML frontmatter \
                      (`description: <one-line>`)._\n",
        );
    } else {
        for rf in rule_files {
            match &rf.description {
                Some(desc) if !desc.is_empty() => {
                    out.push_str(&format!("- `rules/{}` — {}\n", rf.name, desc));
                }
                _ => {
                    out.push_str(&format!("- `rules/{}`\n", rf.name));
                }
            }
        }
    }
    out
}

fn bootstrap_stub() -> &'static str {
    "# MEMORY.md is empty\n\
     \n\
     You have no user-memory file yet at `~/.tron/memory/MEMORY.md`. \
     When you learn user-specific info (name, email, preferences, active projects, \
     tools they use), create this file and record it. See the 'YOUR HUMAN' section \
     of your system prompt for the discipline. Secrets (API keys, tokens, passwords) \
     go in the `vault` skill — NEVER in MEMORY.md or rules/.\n"
}

fn truncation_stub(full: &str) -> String {
    let prefix: String = full.chars().take(MEMORY_MD_TRUNCATION_BYTES).collect();
    format!(
        "> ⚠️ MEMORY.md is too large ({} bytes) and has been truncated for context injection. \
         Please prune it — move detail topics into `rules/*.md` files. First {} bytes follow:\n\n\
         {}\n",
        full.len(),
        prefix.len(),
        prefix,
    )
}

// =============================================================================
// Frontmatter description extraction
// =============================================================================

/// Extract the `description:` value from a single-line YAML scalar in the first
/// frontmatter block. Returns `None` if:
/// - No frontmatter
/// - No `description:` field
/// - Multi-line form (`|`, `>`)
/// - Empty or whitespace-only value
///
/// This parser is deliberately minimal; users who want richer frontmatter still
/// get filename-based listing (no serde_yaml dep).
pub(crate) fn extract_description(content: &str) -> Option<String> {
    // Must start with a frontmatter opener.
    if !content.starts_with("---\n") && !content.starts_with("---\r\n") {
        return None;
    }
    let after_opener = content
        .strip_prefix("---\n")
        .or_else(|| content.strip_prefix("---\r\n"))?;

    // Find the closing --- on its own line.
    let mut end_idx = None;
    for (start, _) in after_opener.match_indices("\n---") {
        // The `---` must be on its own line: followed by `\n`, `\r\n`, or EOF.
        let after = &after_opener[start + 4..];
        if after.is_empty() || after.starts_with('\n') || after.starts_with("\r\n") {
            end_idx = Some(start);
            break;
        }
    }
    // Also accept an opener-adjacent `---` (empty frontmatter block).
    let block = match end_idx {
        Some(i) => &after_opener[..i],
        None => return None,
    };

    for line in block.lines() {
        let Some(rest) = line.strip_prefix("description:") else {
            continue;
        };
        let val = rest.trim();
        // Multi-line YAML scalar opener? → reject (fall back to filename).
        if val.starts_with('|') || val.starts_with('>') {
            return None;
        }
        // Empty value?
        if val.is_empty() {
            return None;
        }
        // Strip matching surrounding quotes (both "..." and '...').
        let unquoted = strip_matching_quotes(val).trim();
        if unquoted.is_empty() {
            return None;
        }
        return Some(unquoted.to_string());
    }
    None
}

fn strip_matching_quotes(s: &str) -> &str {
    let bytes = s.as_bytes();
    if bytes.len() >= 2 {
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if (first == b'"' && last == b'"') || (first == b'\'' && last == b'\'') {
            return &s[1..s.len() - 1];
        }
    }
    s
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::tempdir;

    /// Create a memory-dir layout for tests: `<home>/.tron/memory/`.
    fn make_memory_root(home: &std::path::Path) -> PathBuf {
        let mem = home.join(".tron/memory");
        std::fs::create_dir_all(mem.join("rules")).unwrap();
        std::fs::create_dir_all(mem.join("sessions")).unwrap();
        mem
    }

    // ── Fingerprint: additions ──

    #[test]
    fn fingerprint_changes_when_memory_md_is_added() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::write(
            home.path().join(".tron/memory/MEMORY.md"),
            "# Personal\n- Name: Alice\n",
        )
        .unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_ne!(fp0, fp1, "adding MEMORY.md must flip fingerprint");
    }

    #[test]
    fn fingerprint_changes_when_rule_file_is_added() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::write(
            home.path().join(".tron/memory/rules/user-preferences.md"),
            "---\ndescription: prefs\n---\nbody\n",
        )
        .unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_ne!(fp0, fp1, "adding a rules file must flip fingerprint");
    }

    // ── Fingerprint: exclusions ──

    #[test]
    fn fingerprint_stable_when_session_file_is_added() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        std::fs::write(
            home.path().join(".tron/memory/MEMORY.md"),
            "# Personal\n- Name: Alice\n",
        )
        .unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::write(
            home.path().join(".tron/memory/sessions/sess_abc.md"),
            "journal\n",
        )
        .unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_eq!(
            fp0, fp1,
            "sessions/ writes must NOT invalidate memory fingerprint"
        );
    }

    #[test]
    fn fingerprint_ignores_non_md_files_in_rules() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        std::fs::write(home.path().join(".tron/memory/MEMORY.md"), "root").unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::write(home.path().join(".tron/memory/rules/.DS_Store"), "junk").unwrap();
        std::fs::write(
            home.path().join(".tron/memory/rules/readme.txt"),
            "not a rule",
        )
        .unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_eq!(
            fp0, fp1,
            "non-.md files under rules/ must not affect fingerprint"
        );
    }

    #[test]
    fn fingerprint_ignores_nested_dirs_in_rules() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        std::fs::write(home.path().join(".tron/memory/MEMORY.md"), "root").unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::create_dir_all(home.path().join(".tron/memory/rules/nested")).unwrap();
        std::fs::write(
            home.path().join(".tron/memory/rules/nested/sub.md"),
            "nested content",
        )
        .unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_eq!(fp0, fp1, "rules/ is flat — nested dirs must be ignored");
    }

    // ── Fingerprint: deletions / renames ──

    #[test]
    fn fingerprint_changes_when_memory_md_is_deleted() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        let md = home.path().join(".tron/memory/MEMORY.md");
        std::fs::write(&md, "v1").unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::remove_file(&md).unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_ne!(fp0, fp1, "deleting MEMORY.md must flip fingerprint");
    }

    #[test]
    fn fingerprint_changes_when_rule_file_is_deleted() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        let rule = home.path().join(".tron/memory/rules/foo.md");
        std::fs::write(&rule, "v1").unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::remove_file(&rule).unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_ne!(fp0, fp1, "deleting a rules file must flip fingerprint");
    }

    #[test]
    fn fingerprint_changes_when_rule_file_is_renamed() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let home_str = home.path().to_str().unwrap();
        let rules = home.path().join(".tron/memory/rules");
        std::fs::write(rules.join("foo.md"), "v1").unwrap();
        let fp0 = MemoryFingerprint::compute_for_home(home_str);
        std::fs::rename(rules.join("foo.md"), rules.join("bar.md")).unwrap();
        let fp1 = MemoryFingerprint::compute_for_home(home_str);
        assert_ne!(fp0, fp1, "renaming a rules file must flip fingerprint");
    }

    // ── Fingerprint: absent root ──

    #[test]
    fn fingerprint_when_memory_root_is_absent() {
        let home = tempdir().unwrap();
        // Do NOT create .tron/memory at all.
        let home_str = home.path().to_str().unwrap();
        let fp = MemoryFingerprint::compute_for_home(home_str);
        // Repeated calls must be stable.
        let fp2 = MemoryFingerprint::compute_for_home(home_str);
        assert_eq!(fp, fp2, "fingerprint must be stable when memory/ is absent");
        // And non-empty: at minimum, the MEMORY.md slot is recorded with mtime 0.
        assert!(!fp.entries.is_empty(), "absent root must record an entry");
    }

    // ── Registry: content rendering ──

    #[test]
    fn content_returns_memory_md_plus_rules_listing() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "# Personal\n- Name: Alice\n").unwrap();
        std::fs::write(
            mem.join("rules/user-preferences.md"),
            "---\ndescription: Work style and tech prefs\n---\nbody\n",
        )
        .unwrap();
        std::fs::write(mem.join("rules/apple-cert.md"), "no frontmatter\n").unwrap();

        let mut reg = MemoryRegistry::new();
        let out = reg.content(home.path().to_str().unwrap()).to_string();

        assert!(out.contains("# Personal"), "output: {out}");
        assert!(out.contains("- Name: Alice"));
        assert!(out.contains("## Detail files"));
        assert!(
            out.contains("`rules/user-preferences.md` — Work style and tech prefs"),
            "expected backticked listing with description, got: {out}"
        );
        assert!(
            out.contains("`rules/apple-cert.md`"),
            "missing rules/apple-cert.md in listing: {out}"
        );
    }

    #[test]
    fn content_returns_bootstrap_stub_when_memory_md_absent() {
        let home = tempdir().unwrap();
        make_memory_root(home.path());
        let mut reg = MemoryRegistry::new();
        let out = reg.content(home.path().to_str().unwrap()).to_string();
        assert!(out.contains("MEMORY.md is empty"), "output: {out}");
        assert!(out.contains("~/.tron/memory/MEMORY.md"));
    }

    #[test]
    fn content_caches_until_fingerprint_flips() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "v1").unwrap();
        let home_str = home.path().to_str().unwrap();
        let mut reg = MemoryRegistry::new();
        let a = reg.content(home_str).to_string();
        let b = reg.content(home_str).to_string();
        assert_eq!(a, b);
        // Sleep a tick to ensure mtime advances on filesystems with 1s granularity.
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(mem.join("MEMORY.md"), "v2").unwrap();
        let c = reg.content(home_str).to_string();
        assert_ne!(a, c, "content must refresh after mtime flip");
    }

    #[test]
    fn content_ignores_non_md_files_in_rules() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "root\n").unwrap();
        std::fs::write(mem.join("rules/.DS_Store"), "junk").unwrap();
        std::fs::write(mem.join("rules/readme.txt"), "not a rule").unwrap();
        std::fs::write(
            mem.join("rules/good.md"),
            "---\ndescription: ok\n---\nbody\n",
        )
        .unwrap();
        let mut reg = MemoryRegistry::new();
        let out = reg.content(home.path().to_str().unwrap()).to_string();
        assert!(out.contains("rules/good.md"));
        assert!(!out.contains(".DS_Store"));
        assert!(!out.contains("readme.txt"));
    }

    #[cfg(unix)]
    #[test]
    fn content_follows_symlinked_memory_dir() {
        let home = tempdir().unwrap();
        let dotfiles = tempdir().unwrap();
        std::fs::create_dir_all(dotfiles.path().join("memory/rules")).unwrap();
        std::fs::create_dir_all(dotfiles.path().join("memory/sessions")).unwrap();
        std::fs::write(
            dotfiles.path().join("memory/MEMORY.md"),
            "# from dotfiles\n",
        )
        .unwrap();
        std::fs::create_dir_all(home.path().join(".tron/workspace")).unwrap();
        std::os::unix::fs::symlink(
            dotfiles.path().join("memory"),
            home.path().join(".tron/memory"),
        )
        .unwrap();
        let mut reg = MemoryRegistry::new();
        let out = reg.content(home.path().to_str().unwrap()).to_string();
        assert!(
            out.contains("from dotfiles"),
            "symlinked memory/ must be followed: {out}"
        );
    }

    // ── Registry: deletions / renames ──

    #[test]
    fn content_returns_stub_after_memory_md_deleted() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "v1").unwrap();
        let home_str = home.path().to_str().unwrap();
        let mut reg = MemoryRegistry::new();
        let _first = reg.content(home_str).to_string();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::remove_file(mem.join("MEMORY.md")).unwrap();
        let out = reg.content(home_str).to_string();
        assert!(
            out.contains("MEMORY.md is empty"),
            "expected bootstrap stub after deletion, got: {out}"
        );
    }

    #[test]
    fn content_returns_stub_after_memory_md_renamed() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "v1").unwrap();
        let home_str = home.path().to_str().unwrap();
        let mut reg = MemoryRegistry::new();
        let _first = reg.content(home_str).to_string();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::rename(mem.join("MEMORY.md"), mem.join("MEMORY.md.bak")).unwrap();
        let out = reg.content(home_str).to_string();
        assert!(
            out.contains("MEMORY.md is empty"),
            "rename away from MEMORY.md must trigger stub: {out}"
        );
    }

    #[test]
    fn content_omits_deleted_rule_from_listing() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "root\n").unwrap();
        std::fs::write(
            mem.join("rules/foo.md"),
            "---\ndescription: foo\n---\nbody\n",
        )
        .unwrap();
        let home_str = home.path().to_str().unwrap();
        let mut reg = MemoryRegistry::new();
        let a = reg.content(home_str).to_string();
        assert!(a.contains("rules/foo.md"));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::remove_file(mem.join("rules/foo.md")).unwrap();
        let b = reg.content(home_str).to_string();
        assert!(
            !b.contains("rules/foo.md"),
            "deleted rule must disappear from listing: {b}"
        );
    }

    // ── Registry: size caps ──

    #[test]
    fn content_truncates_when_memory_md_exceeds_hard_cap() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        // 2MB of content — past the 1MB hard cap.
        std::fs::write(mem.join("MEMORY.md"), "a".repeat(2 * 1024 * 1024)).unwrap();
        let mut reg = MemoryRegistry::new();
        let out = reg.content(home.path().to_str().unwrap()).to_string();
        assert!(
            out.contains("MEMORY.md is too large"),
            "hard-cap injection must include truncation notice: {out:.400}"
        );
        // Rendered content = truncation stub + rules listing, well under 20KB.
        assert!(
            out.len() < 20_000,
            "truncation injection must be small, got {} bytes",
            out.len()
        );
    }

    #[test]
    fn content_injects_full_memory_md_under_soft_cap() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        // 80KB — under the 100KB soft cap.
        let body = "x".repeat(80 * 1024);
        std::fs::write(mem.join("MEMORY.md"), &body).unwrap();
        let mut reg = MemoryRegistry::new();
        let out = reg.content(home.path().to_str().unwrap()).to_string();
        assert!(
            out.contains(&body),
            "soft-cap path must still inject full content"
        );
    }

    // ── Registry: rule-file listing wire format ──

    #[test]
    fn list_rule_files_returns_sorted_listing() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        std::fs::write(mem.join("MEMORY.md"), "root").unwrap();
        std::fs::write(
            mem.join("rules/zed.md"),
            "---\ndescription: zed desc\n---\n",
        )
        .unwrap();
        std::fs::write(
            mem.join("rules/alpha.md"),
            "---\ndescription: alpha desc\n---\n",
        )
        .unwrap();
        std::fs::write(mem.join("rules/no-desc.md"), "no frontmatter").unwrap();

        let mut reg = MemoryRegistry::new();
        let files = reg.list_rule_files(home.path().to_str().unwrap());
        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, vec!["alpha.md", "no-desc.md", "zed.md"]);
        assert_eq!(files[0].description.as_deref(), Some("alpha desc"));
        assert_eq!(files[1].description, None);
        assert_eq!(files[2].description.as_deref(), Some("zed desc"));
    }

    #[test]
    fn memory_md_exists_reports_presence() {
        let home = tempdir().unwrap();
        let mem = make_memory_root(home.path());
        let mut reg = MemoryRegistry::new();
        let home_str = home.path().to_str().unwrap();
        assert!(
            !reg.memory_md_exists(home_str),
            "bootstrapped=false when MEMORY.md absent"
        );
        std::fs::write(mem.join("MEMORY.md"), "hello").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert!(
            reg.memory_md_exists(home_str),
            "bootstrapped=true once MEMORY.md exists"
        );
    }

    // ── Frontmatter parser ──

    #[test]
    fn description_extraction_parses_simple_single_line() {
        let c = "---\ndescription: Work style and tech prefs\ntype: wiki\n---\nbody\n";
        assert_eq!(
            extract_description(c).as_deref(),
            Some("Work style and tech prefs")
        );
    }

    #[test]
    fn description_extraction_strips_surrounding_double_quotes() {
        let c = "---\ndescription: \"with: colons and symbols\"\n---\n";
        assert_eq!(
            extract_description(c).as_deref(),
            Some("with: colons and symbols")
        );
    }

    #[test]
    fn description_extraction_strips_surrounding_single_quotes() {
        let c = "---\ndescription: 'single quoted'\n---\n";
        assert_eq!(extract_description(c).as_deref(), Some("single quoted"));
    }

    #[test]
    fn description_extraction_returns_none_for_multiline_description() {
        let c_pipe = "---\ndescription: |\n  Line 1\n  Line 2\n---\nbody\n";
        assert_eq!(extract_description(c_pipe), None);
        let c_fold = "---\ndescription: >\n  Folded\n---\n";
        assert_eq!(extract_description(c_fold), None);
    }

    #[test]
    fn description_extraction_returns_none_when_field_missing() {
        let c = "---\ntype: wiki\ntags: [personal]\n---\nbody\n";
        assert_eq!(extract_description(c), None);
    }

    #[test]
    fn description_extraction_returns_none_when_no_frontmatter() {
        assert_eq!(extract_description("just markdown\n"), None);
        assert_eq!(extract_description(""), None);
        assert_eq!(extract_description("---no newline after opener"), None);
    }

    #[test]
    fn description_extraction_handles_empty_description() {
        let c = "---\ndescription: \n---\n";
        assert_eq!(extract_description(c), None);
        // All-whitespace also None.
        let c2 = "---\ndescription:     \n---\n";
        assert_eq!(extract_description(c2), None);
    }

    #[test]
    fn description_extraction_trims_whitespace() {
        let c = "---\ndescription:    spaced out    \n---\n";
        assert_eq!(extract_description(c).as_deref(), Some("spaced out"));
    }
}
