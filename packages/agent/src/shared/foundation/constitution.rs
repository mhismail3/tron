//! Primitive Tron Home layout and provider-context block types.
//!
//! Runtime state has three roots: `internal/`, `profiles/`, and `workspace/`.
//! `profiles/` now contains protected `auth.json` only; named configuration
//! profiles, inheritance, active pointers, and source-owned prompt assets are
//! not part of the primitive constitution. Sparse user settings live directly
//! at `~/.tron/settings.toml` and are created only by an explicit mutation or
//! snapshot-first legacy migration.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::paths::{dirs, files};

/// Stable top-level homes in Tron state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TronHome {
    /// Engine-owned settings and protected authentication state.
    Engine,
    /// Active projects, artifacts, workers, knowledge, and vault.
    Workspace,
    /// Tron-owned runtime machinery.
    Internal,
}

/// Provider-independent cache stability class for a context block.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextCacheClass {
    /// Rarely changing foundational instructions.
    Foundation,
    /// Operator settings and other stable engine configuration.
    Configuration,
    /// Session history and agent-owned state summaries.
    Session,
    /// Latest turn input and volatile output.
    Turn,
    /// Secrets or material that must not be cached.
    None,
}

/// Context sensitivity class.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContextSensitivity {
    /// Safe to display and audit directly.
    Public,
    /// Personal but non-secret material.
    Private,
    /// Secret material that must never enter model context raw.
    Secret,
}

/// Provider surface used for a context block after compilation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderSurface {
    /// System/developer instruction surface.
    Instructions,
    /// User/message surface.
    Message,
    /// Tool schema or description surface.
    ModelCapability,
    /// Excluded from provider payload.
    Excluded,
}

/// Typed context unit compiled before provider adaptation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextBlock {
    /// Stable identifier for audit and replay.
    pub id: String,
    /// Human-friendly label.
    pub name: String,
    /// Source home.
    pub home: TronHome,
    /// Filesystem source, when applicable.
    pub source_path: Option<String>,
    /// Content-addressed DB blob, when applicable.
    pub source_blob_id: Option<String>,
    /// SHA-256 hash of rendered text.
    pub hash: String,
    /// Estimated tokens for budgeting/audit.
    pub token_estimate: u64,
    /// Sensitivity class.
    pub sensitivity: ContextSensitivity,
    /// Why this block was included or excluded.
    pub inclusion_reason: String,
    /// Canonical ordering slot.
    pub precedence: u32,
    /// Abstract cache class before provider mapping.
    pub cache_class: ContextCacheClass,
    /// Provider payload surface.
    pub provider_surface: ProviderSurface,
    /// Lifecycle hint.
    pub lifecycle: String,
    /// Audit record ids associated with this block.
    pub audit_ids: Vec<String>,
    /// Rendered text.
    pub text: String,
}

/// Summary of newly created constitutional paths.
#[derive(Debug, Default)]
pub struct SeedReport {
    /// Created paths.
    pub seeded: Vec<PathBuf>,
}

/// Ensure a specific Tron Home is structurally complete.
pub fn ensure_tron_home_at(home: &Path) -> io::Result<SeedReport> {
    let mut report = SeedReport::default();
    for directory in primitive_dirs(home) {
        create_dir(&directory, &mut report)?;
    }
    seed_private_auth_if_absent(home, &mut report)?;
    Ok(report)
}

fn primitive_dirs(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(dirs::INTERNAL),
        home.join(dirs::INTERNAL).join(dirs::DB),
        home.join(dirs::INTERNAL).join(dirs::RUN),
        home.join(dirs::INTERNAL)
            .join(dirs::DB)
            .join(dirs::JOURNALS),
        home.join(dirs::PROFILES),
        home.join(dirs::WORKSPACE),
        home.join(dirs::WORKSPACE).join(dirs::PROJECTS),
        home.join(dirs::WORKSPACE).join(dirs::REPORTS),
        home.join(dirs::WORKSPACE).join(dirs::RENDERS),
        home.join(dirs::WORKSPACE).join(dirs::SCREENSHOTS),
        home.join(dirs::WORKSPACE).join(dirs::SCRATCH),
        home.join(dirs::WORKSPACE).join(dirs::LABS),
        home.join(dirs::WORKSPACE).join(dirs::ARCHIVE),
        home.join(dirs::WORKSPACE).join(dirs::KNOWLEDGE),
        home.join(dirs::WORKSPACE).join(dirs::VAULT),
    ]
}

fn create_dir(path: &Path, report: &mut SeedReport) -> io::Result<()> {
    if !path.exists() {
        fs::create_dir_all(path)?;
        report.seeded.push(path.to_path_buf());
    }
    Ok(())
}

fn seed_private_auth_if_absent(home: &Path, report: &mut SeedReport) -> io::Result<()> {
    use std::io::Write as _;

    let path = home.join(dirs::PROFILES).join(files::AUTH_JSON);
    if path.exists() {
        return Ok(());
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("auth path has no parent"))?;
    let mut staged = tempfile::Builder::new()
        .prefix(".auth.seed.")
        .tempfile_in(parent)?;
    staged.write_all(b"{}\n")?;
    staged.as_file().sync_all()?;
    match staged.persist_noclobber(&path) {
        Ok(_) => report.seeded.push(path),
        Err(error) if error.error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.error),
    }
    Ok(())
}

/// Create a context block from rendered text and Tron Home metadata.
#[must_use]
pub fn context_block_for_text(
    id: impl Into<String>,
    name: impl Into<String>,
    home: TronHome,
    text: impl Into<String>,
    cache_class: ContextCacheClass,
    precedence: u32,
) -> ContextBlock {
    let text = text.into();
    ContextBlock {
        id: id.into(),
        name: name.into(),
        home,
        source_path: None,
        source_blob_id: None,
        hash: sha256_hex(text.as_bytes()),
        token_estimate: (text.len() as u64).div_ceil(4),
        sensitivity: ContextSensitivity::Public,
        inclusion_reason: "compiled by primitive context assembly".into(),
        precedence,
        cache_class,
        provider_surface: ProviderSurface::Instructions,
        lifecycle: "runtime".into(),
        audit_ids: Vec::new(),
        text,
    }
}

/// Hash bytes with SHA-256 as lower-case hex.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seeding_creates_only_primitive_roots_and_private_auth() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();

        assert!(home.join("internal/database").is_dir());
        assert!(home.join("workspace/vault").is_dir());
        assert!(home.join("profiles/auth.json").is_file());
        assert!(!home.join("settings.toml").exists());
        assert!(!home.join("profiles/active.toml").exists());
        assert!(!home.join("profiles/default").exists());
    }

    #[test]
    fn seeding_never_overwrites_auth_or_settings() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join(".tron");
        ensure_tron_home_at(&home).unwrap();
        fs::write(home.join("profiles/auth.json"), "{\"token\":\"kept\"}").unwrap();
        fs::write(home.join("settings.toml"), "autonomousWorkers = true\n").unwrap();

        ensure_tron_home_at(&home).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("profiles/auth.json")).unwrap(),
            "{\"token\":\"kept\"}"
        );
        assert_eq!(
            fs::read_to_string(home.join("settings.toml")).unwrap(),
            "autonomousWorkers = true\n"
        );
    }

    #[test]
    fn context_block_hashes_rendered_text() {
        let block = context_block_for_text(
            "core",
            "Core prompt",
            TronHome::Engine,
            "hello",
            ContextCacheClass::Foundation,
            10,
        );
        assert_eq!(block.hash, sha256_hex(b"hello"));
        assert_eq!(block.precedence, 10);
    }
}
