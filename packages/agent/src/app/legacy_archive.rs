//! Verified, bounded archive of the meaningful pre-minimal-core runtime.
//!
//! The clean-break migration intentionally does not import Worker-era runtime
//! state. Before that reset, this module preserves the evidence a user may
//! reasonably need later: SQLite truth, worker-authored source, and mutable
//! worker-owned state. Reinstallable dependencies, model weights, caches,
//! sockets, logs, credentials, and recursive backup chains are excluded.
//!
//! Creation is offline-only at the CLI boundary. The archive itself is
//! content-addressed by a manifest and verified again after publication.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::{DirEntry, WalkDir};

const ARCHIVE_FORMAT: &str = "tron.legacy_runtime_archive.v1";
const RESET_FORMAT: &str = "tron.minimal_core_reset.v1";
const MANIFEST_NAME: &str = "manifest.json";
const PAYLOAD_DIR: &str = "payload";
const RESET_RECEIPT_DIR: &str = "migrations";
const RESET_PENDING_NAME: &str = "minimal-core-reset-v1.pending.json";
const RESET_RECEIPT_NAME: &str = "minimal-core-reset-v1.json";
const MAX_SOURCE_FILE_BYTES: u64 = 8 * 1_048_576;
const MAX_STATE_FILE_BYTES: u64 = 512 * 1_048_576;
const MAX_ARCHIVE_INPUT_BYTES: u64 = 16 * 1_024 * 1_024 * 1_024;
const MAX_ARCHIVE_ENTRIES: usize = 1_000_000;
const MAX_OMISSION_EXAMPLES: usize = 20;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ArchiveEntry {
    path: String,
    bytes: u64,
    sha256: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct OmissionSummary {
    count: u64,
    examples: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct LegacyArchiveManifest {
    format: String,
    created_at: String,
    entries: Vec<ArchiveEntry>,
    omissions: BTreeMap<String, OmissionSummary>,
    preserved_outside_archive: Vec<String>,
}

/// Verified published archive metadata returned to the operator.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LegacyArchiveReport {
    /// Published owner-only archive path.
    pub(crate) path: PathBuf,
    /// Digest of the compressed archive bytes.
    pub(crate) sha256: String,
    /// Number of manifest-declared payload files.
    pub(crate) files: usize,
    /// Total uncompressed payload bytes.
    pub(crate) bytes: u64,
}

/// Durable proof that one legacy profile was reset only after its exact
/// meaningful-data archive verified successfully.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MinimalCoreResetReceipt {
    /// Receipt ABI.
    pub(crate) format: String,
    /// Canonical verified archive path supplied by the operator.
    pub(crate) archive_path: PathBuf,
    /// SHA-256 of the compressed archive bytes.
    pub(crate) archive_sha256: String,
    /// Exact profile-relative roots removed by the cutover.
    pub(crate) removed_targets: Vec<String>,
    /// Completion time.
    pub(crate) completed_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct MinimalCoreResetPending {
    format: String,
    archive_path: PathBuf,
    archive_sha256: String,
    targets: Vec<String>,
    started_at: String,
}

const RESET_TARGETS: [&str; 5] = [
    "internal/database",
    "internal/terminal",
    "internal/run",
    "workspace/workers",
    "workspace/worker-state",
];

/// Create and verify one meaningful-data archive for an offline profile.
pub(crate) fn create_legacy_archive(home: &Path) -> Result<LegacyArchiveReport, String> {
    let backup_root = home.join("internal/backups");
    fs::create_dir_all(&backup_root).map_err(display_error("create archive directory"))?;
    secure_owner_only(&backup_root)?;
    let stage = tempfile::Builder::new()
        .prefix(".legacy-runtime-")
        .tempdir_in(&backup_root)
        .map_err(display_error("create archive staging directory"))?;
    secure_owner_only(stage.path())?;
    let payload = stage.path().join(PAYLOAD_DIR);
    fs::create_dir_all(&payload).map_err(display_error("create archive payload"))?;

    let mut builder = ArchiveBuilder::new(home, &payload);
    builder.capture_databases()?;
    builder.capture_runtime_evidence()?;
    builder.capture_worker_state()?;
    builder.capture_worker_sources()?;
    let manifest = builder.finish();
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)
        .map_err(|error| format!("encode legacy archive manifest: {error}"))?;
    write_private_file(&stage.path().join(MANIFEST_NAME), &manifest_bytes)?;

    let filename = format!(
        "legacy-runtime-{}-{}.tar.zst",
        chrono::Utc::now().format("%Y%m%dT%H%M%SZ"),
        uuid::Uuid::now_v7()
    );
    let destination = backup_root.join(filename);
    let temporary = destination.with_extension("tar.zst.tmp");
    write_archive(stage.path(), &temporary)?;
    fs::rename(&temporary, &destination).map_err(display_error("publish legacy archive"))?;
    secure_owner_only(&destination)?;
    let report = verify_legacy_archive(&destination)?;
    Ok(report)
}

/// Verify format, path safety, size, and digest for every archived payload.
pub(crate) fn verify_legacy_archive(path: &Path) -> Result<LegacyArchiveReport, String> {
    let archive_sha256 = hash_file(path)?;
    let extracted = tempfile::tempdir().map_err(display_error("create verification directory"))?;
    let decoder = zstd::stream::read::Decoder::new(
        File::open(path).map_err(display_error("open legacy archive"))?,
    )
    .map_err(|error| format!("decompress legacy archive: {error}"))?;
    let mut archive = tar::Archive::new(decoder);
    let mut archived_paths = BTreeSet::new();
    let mut archived_bytes = 0_u64;
    for entry in archive
        .entries()
        .map_err(|error| format!("read legacy archive: {error}"))?
    {
        let mut entry = entry.map_err(|error| format!("read legacy archive entry: {error}"))?;
        let entry_path = entry
            .path()
            .map_err(|error| format!("decode legacy archive path: {error}"))?
            .into_owned();
        validate_relative_path(&entry_path)?;
        if !archived_paths.insert(entry_path.clone()) {
            return Err(format!(
                "legacy archive contains duplicate entry {}",
                entry_path.display()
            ));
        }
        if archived_paths.len() > MAX_ARCHIVE_ENTRIES {
            return Err(format!(
                "legacy archive exceeds the {MAX_ARCHIVE_ENTRIES}-entry verification ceiling"
            ));
        }
        let kind = entry.header().entry_type();
        if !kind.is_file() && !kind.is_dir() {
            return Err(format!(
                "legacy archive contains unsupported entry {}",
                entry_path.display()
            ));
        }
        let is_manifest = entry_path == Path::new(MANIFEST_NAME);
        let is_payload =
            entry_path == Path::new(PAYLOAD_DIR) || entry_path.starts_with(Path::new(PAYLOAD_DIR));
        if (kind.is_file() && !is_manifest && !is_payload) || (kind.is_dir() && !is_payload) {
            return Err(format!(
                "legacy archive contains undeclared top-level entry {}",
                entry_path.display()
            ));
        }
        if kind.is_file() {
            archived_bytes = archived_bytes
                .checked_add(
                    entry
                        .header()
                        .size()
                        .map_err(|error| format!("read legacy archive entry size: {error}"))?,
                )
                .ok_or_else(|| "legacy archive byte count overflow".to_owned())?;
            if archived_bytes > MAX_ARCHIVE_INPUT_BYTES {
                return Err(format!(
                    "legacy archive exceeds the {MAX_ARCHIVE_INPUT_BYTES}-byte verification ceiling"
                ));
            }
        }
        entry
            .unpack_in(extracted.path())
            .map_err(|error| format!("extract legacy archive entry: {error}"))?
            .then_some(())
            .ok_or_else(|| {
                format!(
                    "legacy archive entry escaped verification root: {}",
                    entry_path.display()
                )
            })?;
    }

    let manifest: LegacyArchiveManifest = serde_json::from_slice(
        &fs::read(extracted.path().join(MANIFEST_NAME))
            .map_err(display_error("read legacy archive manifest"))?,
    )
    .map_err(|error| format!("decode legacy archive manifest: {error}"))?;
    if manifest.format != ARCHIVE_FORMAT {
        return Err(format!(
            "unsupported legacy archive format {}",
            manifest.format
        ));
    }
    if manifest.entries.len() > MAX_ARCHIVE_ENTRIES {
        return Err(format!(
            "legacy archive manifest exceeds the {MAX_ARCHIVE_ENTRIES}-entry verification ceiling"
        ));
    }
    let mut declared_paths = BTreeSet::new();
    let mut bytes = 0_u64;
    for declared in &manifest.entries {
        let relative = Path::new(&declared.path);
        validate_relative_path(relative)?;
        if !declared_paths.insert(relative.to_path_buf()) {
            return Err(format!(
                "legacy archive manifest contains duplicate payload {}",
                declared.path
            ));
        }
        let stored = extracted.path().join(PAYLOAD_DIR).join(relative);
        let metadata = fs::metadata(&stored).map_err(display_error("inspect archived payload"))?;
        if !metadata.is_file() || metadata.len() != declared.bytes {
            return Err(format!(
                "legacy archive payload metadata mismatch for {}",
                declared.path
            ));
        }
        let digest = hash_file(&stored)?;
        if digest != declared.sha256 {
            return Err(format!(
                "legacy archive payload checksum mismatch for {}",
                declared.path
            ));
        }
        bytes = bytes
            .checked_add(declared.bytes)
            .ok_or_else(|| "legacy archive byte count overflow".to_owned())?;
        if bytes > MAX_ARCHIVE_INPUT_BYTES {
            return Err(format!(
                "legacy archive manifest exceeds the {MAX_ARCHIVE_INPUT_BYTES}-byte verification ceiling"
            ));
        }
    }
    let mut actual_payloads = BTreeSet::new();
    let payload_root = extracted.path().join(PAYLOAD_DIR);
    for entry in WalkDir::new(&payload_root).follow_links(false) {
        let entry = entry.map_err(|error| format!("scan verified archive payload: {error}"))?;
        if entry.file_type().is_file() {
            actual_payloads.insert(
                entry
                    .path()
                    .strip_prefix(&payload_root)
                    .map(Path::to_path_buf)
                    .map_err(|_| "archived payload escaped payload root".to_owned())?,
            );
        }
    }
    if actual_payloads != declared_paths {
        return Err("legacy archive payload set does not exactly match its manifest".to_owned());
    }
    Ok(LegacyArchiveReport {
        path: path.to_path_buf(),
        sha256: archive_sha256,
        files: manifest.entries.len(),
        bytes,
    })
}

/// Reset legacy runtime custody after verifying the exact operator-approved
/// archive. This function is deliberately offline-only at the CLI boundary.
/// It is idempotent across process crashes: a pending receipt is persisted
/// before the first removal, and an exact replay completes the same whitelist.
///
/// Authentication, settings, vaults, ordinary workspace files, session Git
/// worktrees, backups, and future agent-authored capability roots are not in
/// [`RESET_TARGETS`] and therefore cannot be removed by this operation.
pub(crate) fn reset_to_minimal_core(
    home: &Path,
    archive: &Path,
    expected_archive_sha256: &str,
) -> Result<MinimalCoreResetReceipt, String> {
    let home = canonical_profile_root(home)?;
    let archive = archive
        .canonicalize()
        .map_err(display_error("resolve legacy archive"))?;
    let report = verify_legacy_archive(&archive)?;
    let expected_archive_sha256 = expected_archive_sha256.trim().to_ascii_lowercase();
    if expected_archive_sha256.len() != 64
        || !expected_archive_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err("archive SHA-256 must contain exactly 64 hexadecimal characters".to_owned());
    }
    if report.sha256 != expected_archive_sha256 {
        return Err(format!(
            "legacy archive checksum mismatch: expected {expected_archive_sha256}, found {}",
            report.sha256
        ));
    }

    for target in RESET_TARGETS {
        let removal = home.join(target);
        if archive == removal || archive.starts_with(&removal) {
            return Err(format!(
                "legacy archive {} is inside reset target {target}",
                archive.display()
            ));
        }
    }

    let receipt_dir = home.join("internal").join(RESET_RECEIPT_DIR);
    fs::create_dir_all(&receipt_dir).map_err(display_error("create reset receipt directory"))?;
    secure_owner_only(&receipt_dir)?;
    let complete_path = receipt_dir.join(RESET_RECEIPT_NAME);
    let pending_path = receipt_dir.join(RESET_PENDING_NAME);
    if complete_path.exists() {
        let receipt = read_reset_receipt(&complete_path)?;
        validate_reset_identity(&receipt.archive_path, &receipt.archive_sha256, &report)?;
        if pending_path.exists() {
            fs::remove_file(&pending_path)
                .map_err(display_error("remove completed reset marker"))?;
        }
        return Ok(receipt);
    }

    let targets = RESET_TARGETS
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    if pending_path.exists() {
        let pending: MinimalCoreResetPending = serde_json::from_slice(
            &fs::read(&pending_path).map_err(display_error("read pending reset receipt"))?,
        )
        .map_err(|error| format!("decode pending reset receipt: {error}"))?;
        if pending.format != RESET_FORMAT || pending.targets != targets {
            return Err("pending minimal-core reset has an unsupported contract".to_owned());
        }
        validate_reset_identity(&pending.archive_path, &pending.archive_sha256, &report)?;
    } else {
        let pending = MinimalCoreResetPending {
            format: RESET_FORMAT.to_owned(),
            archive_path: archive.clone(),
            archive_sha256: report.sha256.clone(),
            targets: targets.clone(),
            started_at: chrono::Utc::now().to_rfc3339(),
        };
        write_private_file(
            &pending_path,
            &serde_json::to_vec_pretty(&pending)
                .map_err(|error| format!("encode pending reset receipt: {error}"))?,
        )?;
        sync_directory(&receipt_dir)?;
    }

    for relative in RESET_TARGETS {
        remove_reset_target(&home, Path::new(relative))?;
    }

    let receipt = MinimalCoreResetReceipt {
        format: RESET_FORMAT.to_owned(),
        archive_path: archive,
        archive_sha256: report.sha256,
        removed_targets: targets,
        completed_at: chrono::Utc::now().to_rfc3339(),
    };
    write_private_file(
        &complete_path,
        &serde_json::to_vec_pretty(&receipt)
            .map_err(|error| format!("encode reset receipt: {error}"))?,
    )?;
    sync_directory(&receipt_dir)?;
    fs::remove_file(&pending_path).map_err(display_error("remove pending reset receipt"))?;
    sync_directory(&receipt_dir)?;
    Ok(receipt)
}

fn canonical_profile_root(home: &Path) -> Result<PathBuf, String> {
    if !home.is_absolute() {
        return Err("minimal-core reset requires an absolute profile path".to_owned());
    }
    let canonical = home
        .canonicalize()
        .map_err(display_error("resolve profile root"))?;
    if canonical == Path::new("/") || !canonical.is_dir() {
        return Err("minimal-core reset refuses an unsafe profile root".to_owned());
    }
    Ok(canonical)
}

fn validate_reset_identity(
    recorded_path: &Path,
    recorded_sha256: &str,
    report: &LegacyArchiveReport,
) -> Result<(), String> {
    if recorded_path != report.path || recorded_sha256 != report.sha256 {
        return Err(
            "existing minimal-core reset receipt belongs to a different legacy archive".to_owned(),
        );
    }
    Ok(())
}

fn read_reset_receipt(path: &Path) -> Result<MinimalCoreResetReceipt, String> {
    let receipt: MinimalCoreResetReceipt = serde_json::from_slice(
        &fs::read(path).map_err(display_error("read minimal-core reset receipt"))?,
    )
    .map_err(|error| format!("decode minimal-core reset receipt: {error}"))?;
    if receipt.format != RESET_FORMAT
        || receipt.removed_targets
            != RESET_TARGETS
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
    {
        return Err("minimal-core reset receipt has an unsupported contract".to_owned());
    }
    Ok(receipt)
}

fn remove_reset_target(home: &Path, relative: &Path) -> Result<(), String> {
    validate_relative_path(relative)?;
    let target = home.join(relative);
    let metadata = match fs::symlink_metadata(&target) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "inspect reset target {}: {error}",
                target.display()
            ));
        }
    };
    if metadata.file_type().is_symlink() || metadata.is_file() {
        fs::remove_file(&target)
            .map_err(|error| format!("remove reset target {}: {error}", target.display()))
    } else if metadata.is_dir() {
        fs::remove_dir_all(&target)
            .map_err(|error| format!("remove reset target {}: {error}", target.display()))
    } else {
        Err(format!(
            "reset target is not a regular file, directory, or symbolic link: {}",
            target.display()
        ))
    }
}

fn sync_directory(path: &Path) -> Result<(), String> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(display_error("sync reset receipt directory"))
}

struct ArchiveBuilder<'a> {
    home: &'a Path,
    payload: &'a Path,
    entries: Vec<ArchiveEntry>,
    omissions: BTreeMap<String, OmissionSummary>,
    bytes: u64,
}

impl<'a> ArchiveBuilder<'a> {
    fn new(home: &'a Path, payload: &'a Path) -> Self {
        Self {
            home,
            payload,
            entries: Vec::new(),
            omissions: BTreeMap::new(),
            bytes: 0,
        }
    }

    fn capture_databases(&mut self) -> Result<(), String> {
        for name in ["tron.sqlite", "workers.sqlite"] {
            let relative = PathBuf::from("internal/database").join(name);
            self.copy_required_if_present(&relative, u64::MAX, "database absent")?;
            for suffix in ["-wal", "-shm"] {
                let sidecar = PathBuf::from(format!("{}{}", relative.display(), suffix));
                self.copy_optional(&sidecar, u64::MAX, "database sidecar absent")?;
            }
        }
        Ok(())
    }

    fn capture_worker_state(&mut self) -> Result<(), String> {
        let root = self.home.join("workspace/worker-state");
        self.capture_tree(
            &root,
            Path::new("workspace/worker-state"),
            MAX_STATE_FILE_BYTES,
            |_| true,
        )
    }

    fn capture_runtime_evidence(&mut self) -> Result<(), String> {
        for relative in ["internal/database/journals", "internal/terminal"] {
            let root = self.home.join(relative);
            self.capture_tree(&root, Path::new(relative), MAX_STATE_FILE_BYTES, |_| true)?;
        }
        Ok(())
    }

    fn capture_worker_sources(&mut self) -> Result<(), String> {
        let root = self.home.join("workspace/workers");
        if !root.exists() {
            self.omit("worker source root absent", Path::new("workspace/workers"));
            return Ok(());
        }
        let walker = WalkDir::new(&root)
            .follow_links(false)
            .into_iter()
            .filter_entry(|entry| !excluded_source_directory(entry));
        for entry in walker {
            let entry = entry.map_err(|error| format!("scan worker source: {error}"))?;
            let relative = entry
                .path()
                .strip_prefix(self.home)
                .map_err(|_| "worker source escaped profile root".to_owned())?;
            if entry.file_type().is_dir() {
                continue;
            }
            if !entry.file_type().is_file() {
                self.omit("non-regular worker source", relative);
                continue;
            }
            if !meaningful_source_file(entry.path()) {
                self.omit("reinstallable or binary worker payload", relative);
                continue;
            }
            self.copy(relative, MAX_SOURCE_FILE_BYTES)?;
        }
        Ok(())
    }

    fn capture_tree<F>(
        &mut self,
        root: &Path,
        relative_root: &Path,
        max_file_bytes: u64,
        include: F,
    ) -> Result<(), String>
    where
        F: Fn(&Path) -> bool,
    {
        if !root.exists() {
            self.omit("state root absent", relative_root);
            return Ok(());
        }
        for entry in WalkDir::new(root).follow_links(false) {
            let entry = entry.map_err(|error| format!("scan durable state: {error}"))?;
            let relative = entry
                .path()
                .strip_prefix(self.home)
                .map_err(|_| "durable state escaped profile root".to_owned())?;
            if entry.file_type().is_dir() {
                continue;
            }
            if !entry.file_type().is_file() {
                self.omit("non-regular durable state", relative);
            } else if include(relative) {
                self.copy(relative, max_file_bytes)?;
            }
        }
        Ok(())
    }

    fn copy_required_if_present(
        &mut self,
        relative: &Path,
        max_bytes: u64,
        absent_reason: &str,
    ) -> Result<(), String> {
        if self.home.join(relative).exists() {
            self.copy(relative, max_bytes)
        } else {
            self.omit(absent_reason, relative);
            Ok(())
        }
    }

    fn copy_optional(
        &mut self,
        relative: &Path,
        max_bytes: u64,
        absent_reason: &str,
    ) -> Result<(), String> {
        self.copy_required_if_present(relative, max_bytes, absent_reason)
    }

    fn copy(&mut self, relative: &Path, max_bytes: u64) -> Result<(), String> {
        validate_relative_path(relative)?;
        let source = self.home.join(relative);
        let metadata =
            fs::symlink_metadata(&source).map_err(display_error("inspect archive input"))?;
        if !metadata.is_file() {
            return Err(format!(
                "archive input is not a regular file: {}",
                source.display()
            ));
        }
        if metadata.len() > max_bytes {
            self.omit("file exceeds archive source ceiling", relative);
            return Ok(());
        }
        self.bytes = self
            .bytes
            .checked_add(metadata.len())
            .ok_or_else(|| "legacy archive byte count overflow".to_owned())?;
        if self.bytes > MAX_ARCHIVE_INPUT_BYTES {
            return Err(format!(
                "meaningful legacy data exceeds the {}-byte archive ceiling",
                MAX_ARCHIVE_INPUT_BYTES
            ));
        }
        let target = self.payload.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(display_error("create archive payload path"))?;
        }
        fs::copy(&source, &target).map_err(display_error("copy archive payload"))?;
        self.entries.push(ArchiveEntry {
            path: normalized_relative_path(relative)?,
            bytes: metadata.len(),
            sha256: hash_file(&target)?,
        });
        Ok(())
    }

    fn omit(&mut self, reason: &str, path: &Path) {
        let summary = self.omissions.entry(reason.to_owned()).or_default();
        summary.count = summary.count.saturating_add(1);
        if summary.examples.len() < MAX_OMISSION_EXAMPLES {
            summary.examples.push(path.display().to_string());
        }
    }

    fn finish(mut self) -> LegacyArchiveManifest {
        self.entries
            .sort_by(|left, right| left.path.cmp(&right.path));
        LegacyArchiveManifest {
            format: ARCHIVE_FORMAT.to_owned(),
            created_at: chrono::Utc::now().to_rfc3339(),
            entries: self.entries,
            omissions: self.omissions,
            preserved_outside_archive: vec![
                "auth.json and credential stores".to_owned(),
                "settings.toml".to_owned(),
                "pairing and platform permission state".to_owned(),
                "workspace/vault".to_owned(),
                "workspace/session-worktrees and ordinary workspace files".to_owned(),
            ],
        }
    }
}

fn excluded_source_directory(entry: &DirEntry) -> bool {
    if !entry.file_type().is_dir() {
        return false;
    }
    matches!(
        entry.file_name().to_str(),
        Some(
            "dependencies"
                | "node_modules"
                | ".venv"
                | "venv"
                | "target"
                | "models"
                | "model"
                | "cache"
                | "caches"
                | "__pycache__"
                | ".git"
        )
    )
}

fn meaningful_source_file(path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    if matches!(name, "worker.json" | "manifest.json" | "SKILL.md") {
        return true;
    }
    matches!(
        path.extension().and_then(|extension| extension.to_str()),
        Some(
            "json"
                | "toml"
                | "yaml"
                | "yml"
                | "md"
                | "txt"
                | "py"
                | "js"
                | "mjs"
                | "cjs"
                | "ts"
                | "tsx"
                | "sh"
                | "zsh"
                | "bash"
                | "rb"
                | "go"
                | "rs"
                | "swift"
                | "html"
                | "css"
                | "sql"
                | "lock"
        )
    )
}

fn validate_relative_path(path: &Path) -> Result<(), String> {
    if path.as_os_str().is_empty() || path.is_absolute() {
        return Err(format!("archive path must be relative: {}", path.display()));
    }
    if path
        .components()
        .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(format!("archive path is unsafe: {}", path.display()));
    }
    Ok(())
}

fn normalized_relative_path(path: &Path) -> Result<String, String> {
    validate_relative_path(path)?;
    Ok(path
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/"))
}

fn write_archive(source: &Path, destination: &Path) -> Result<(), String> {
    let file = create_private_file(destination).map_err(display_error("create legacy archive"))?;
    let encoder = zstd::stream::write::Encoder::new(file, 9)
        .map_err(|error| format!("create legacy archive compressor: {error}"))?;
    let mut archive = tar::Builder::new(encoder);
    archive
        .append_path_with_name(source.join(MANIFEST_NAME), MANIFEST_NAME)
        .map_err(|error| format!("archive legacy manifest: {error}"))?;
    archive
        .append_dir_all(PAYLOAD_DIR, source.join(PAYLOAD_DIR))
        .map_err(|error| format!("archive legacy payload: {error}"))?;
    let encoder = archive
        .into_inner()
        .map_err(|error| format!("finish legacy tar stream: {error}"))?;
    let mut file = encoder
        .finish()
        .map_err(|error| format!("finish legacy compression: {error}"))?;
    file.flush()
        .map_err(display_error("flush legacy archive"))?;
    file.sync_all()
        .map_err(display_error("sync legacy archive"))
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file =
        create_private_file(path).map_err(display_error("create private archive file"))?;
    file.write_all(bytes)
        .map_err(display_error("write private archive file"))?;
    file.sync_all()
        .map_err(display_error("sync private archive file"))?;
    secure_owner_only(path)
}

#[cfg(unix)]
fn create_private_file(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn create_private_file(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().create_new(true).write(true).open(path)
}

fn hash_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(display_error("open file for checksum"))?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(display_error("read file for checksum"))?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex::encode(digest.finalize()))
}

#[cfg(unix)]
fn secure_owner_only(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let mode = if path.is_dir() { 0o700 } else { 0o600 };
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(display_error("secure legacy archive path"))
}

#[cfg(not(unix))]
fn secure_owner_only(_path: &Path) -> Result<(), String> {
    Ok(())
}

fn display_error(operation: &'static str) -> impl Fn(std::io::Error) -> String {
    move |error| format!("{operation}: {error}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_preserves_meaningful_state_and_excludes_credentials_and_dependencies() {
        let profile = tempfile::tempdir().unwrap();
        let home = profile.path();
        fs::create_dir_all(home.join("internal/database")).unwrap();
        fs::write(home.join("internal/database/tron.sqlite"), b"session truth").unwrap();
        fs::write(
            home.join("internal/database/workers.sqlite"),
            b"worker truth",
        )
        .unwrap();
        fs::create_dir_all(home.join("workspace/worker-state/knowledge")).unwrap();
        fs::write(
            home.join("workspace/worker-state/knowledge/index.sqlite"),
            b"knowledge index",
        )
        .unwrap();
        fs::create_dir_all(home.join("workspace/workers/example/v1/files")).unwrap();
        fs::write(
            home.join("workspace/workers/example/v1/manifest.json"),
            b"{}",
        )
        .unwrap();
        fs::write(
            home.join("workspace/workers/example/v1/files/main.ts"),
            b"export default 1",
        )
        .unwrap();
        fs::create_dir_all(home.join("workspace/workers/example/v1/dependencies/model")).unwrap();
        fs::write(
            home.join("workspace/workers/example/v1/dependencies/model/weights.bin"),
            b"reinstallable",
        )
        .unwrap();
        fs::create_dir_all(home.join("workspace/vault")).unwrap();
        fs::write(home.join("workspace/vault/secret"), b"credential").unwrap();
        fs::write(home.join("auth.json"), b"credential").unwrap();

        let report = create_legacy_archive(home).unwrap();
        assert!(report.path.is_file());
        assert_eq!(report.sha256.len(), 64);
        assert_eq!(verify_legacy_archive(&report.path).unwrap(), report);

        let extracted = tempfile::tempdir().unwrap();
        let decoder = zstd::stream::read::Decoder::new(File::open(&report.path).unwrap()).unwrap();
        tar::Archive::new(decoder).unpack(extracted.path()).unwrap();
        let manifest: LegacyArchiveManifest =
            serde_json::from_slice(&fs::read(extracted.path().join(MANIFEST_NAME)).unwrap())
                .unwrap();
        let paths = manifest
            .entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>();
        assert!(paths.contains(&"internal/database/tron.sqlite"));
        assert!(paths.contains(&"internal/database/workers.sqlite"));
        assert!(paths.contains(&"workspace/worker-state/knowledge/index.sqlite"));
        assert!(paths.contains(&"workspace/workers/example/v1/files/main.ts"));
        assert!(!paths.iter().any(|path| path.contains("dependencies")));
        assert!(!paths.iter().any(|path| path.contains("vault")));
        assert!(!paths.iter().any(|path| path.contains("auth.json")));
    }

    #[test]
    fn verification_rejects_checksum_drift() {
        let profile = tempfile::tempdir().unwrap();
        fs::create_dir_all(profile.path().join("internal/database")).unwrap();
        fs::write(
            profile.path().join("internal/database/tron.sqlite"),
            b"truth",
        )
        .unwrap();
        let report = create_legacy_archive(profile.path()).unwrap();
        let bytes = fs::read(&report.path).unwrap();
        fs::write(&report.path, &bytes[..bytes.len() / 2]).unwrap();
        assert!(verify_legacy_archive(&report.path).is_err());
    }

    #[test]
    fn verification_rejects_payloads_omitted_from_the_manifest() {
        let stage = tempfile::tempdir().unwrap();
        fs::create_dir_all(stage.path().join(PAYLOAD_DIR)).unwrap();
        fs::write(
            stage.path().join(PAYLOAD_DIR).join("declared.txt"),
            b"declared",
        )
        .unwrap();
        fs::write(
            stage.path().join(PAYLOAD_DIR).join("undeclared.txt"),
            b"extra",
        )
        .unwrap();
        let manifest = LegacyArchiveManifest {
            format: ARCHIVE_FORMAT.to_owned(),
            created_at: chrono::Utc::now().to_rfc3339(),
            entries: vec![ArchiveEntry {
                path: "declared.txt".to_owned(),
                bytes: 8,
                sha256: hash_file(&stage.path().join(PAYLOAD_DIR).join("declared.txt")).unwrap(),
            }],
            omissions: BTreeMap::new(),
            preserved_outside_archive: Vec::new(),
        };
        write_private_file(
            &stage.path().join(MANIFEST_NAME),
            &serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        let archive = stage.path().join("archive.tar.zst");
        write_archive(stage.path(), &archive).unwrap();

        assert!(
            verify_legacy_archive(&archive)
                .unwrap_err()
                .contains("does not exactly match")
        );
    }

    #[test]
    fn archive_paths_reject_parent_and_absolute_components() {
        assert!(validate_relative_path(Path::new("../escape")).is_err());
        assert!(validate_relative_path(Path::new("/absolute")).is_err());
        assert!(validate_relative_path(Path::new("safe/path")).is_ok());
    }

    #[test]
    fn reset_requires_exact_archive_and_preserves_nonlegacy_profile_custody() {
        let profile = tempfile::tempdir().unwrap();
        let home = profile.path();
        for relative in [
            "internal/database/journals",
            "internal/terminal",
            "internal/run",
            "workspace/workers/example",
            "workspace/worker-state/example",
            "workspace/vault",
            "workspace/session-worktrees/session-a",
            "workspace/project",
        ] {
            fs::create_dir_all(home.join(relative)).unwrap();
        }
        fs::write(home.join("internal/database/tron.sqlite"), b"sessions").unwrap();
        fs::write(home.join("internal/database/workers.sqlite"), b"workers").unwrap();
        fs::write(
            home.join("internal/database/journals/turn.jsonl"),
            b"partial turn",
        )
        .unwrap();
        fs::write(home.join("internal/terminal/terminal.log"), b"terminal").unwrap();
        fs::write(home.join("internal/run/server.sock"), b"ephemeral").unwrap();
        fs::write(home.join("workspace/workers/example/manifest.json"), b"{}").unwrap();
        fs::write(
            home.join("workspace/worker-state/example/state.sqlite"),
            b"state",
        )
        .unwrap();
        fs::write(home.join("auth.json"), b"auth").unwrap();
        fs::write(home.join("settings.toml"), b"settings").unwrap();
        fs::write(home.join("workspace/vault/secret"), b"secret").unwrap();
        fs::write(
            home.join("workspace/session-worktrees/session-a/user.txt"),
            b"uncommitted user work",
        )
        .unwrap();
        fs::write(home.join("workspace/project/file.txt"), b"ordinary work").unwrap();

        let archive = create_legacy_archive(home).unwrap();
        let error = reset_to_minimal_core(home, &archive.path, &"0".repeat(64)).unwrap_err();
        assert!(error.contains("checksum mismatch"));
        assert!(home.join("internal/database/tron.sqlite").exists());

        let receipt = reset_to_minimal_core(home, &archive.path, &archive.sha256).unwrap();
        assert_eq!(receipt.archive_sha256, archive.sha256);
        for relative in RESET_TARGETS {
            assert!(!home.join(relative).exists(), "{relative} must be reset");
        }
        for relative in [
            "auth.json",
            "settings.toml",
            "workspace/vault/secret",
            "workspace/session-worktrees/session-a/user.txt",
            "workspace/project/file.txt",
        ] {
            assert!(home.join(relative).exists(), "{relative} must be preserved");
        }
        assert!(archive.path.exists());
        let replay = reset_to_minimal_core(home, &archive.path, &archive.sha256).unwrap();
        assert_eq!(replay, receipt);
    }

    #[cfg(unix)]
    #[test]
    fn reset_unlinks_whitelisted_symlink_without_following_it() {
        use std::os::unix::fs::symlink;

        let profile = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("must-survive"), b"outside").unwrap();
        fs::create_dir_all(profile.path().join("internal/database")).unwrap();
        fs::write(
            profile.path().join("internal/database/tron.sqlite"),
            b"truth",
        )
        .unwrap();
        fs::create_dir_all(profile.path().join("workspace")).unwrap();
        symlink(
            outside.path(),
            profile.path().join("workspace/worker-state"),
        )
        .unwrap();
        let archive = create_legacy_archive(profile.path()).unwrap();

        reset_to_minimal_core(profile.path(), &archive.path, &archive.sha256).unwrap();

        assert!(outside.path().join("must-survive").exists());
        assert!(!profile.path().join("workspace/worker-state").exists());
    }
}
