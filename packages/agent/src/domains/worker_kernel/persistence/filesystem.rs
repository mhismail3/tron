//! Canonical filesystem codecs shared by publication and reconstruction.

use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};

pub(super) fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, String> {
    serde_json::from_slice(
        &fs::read(path).map_err(|error| format!("read {}: {error}", path.display()))?,
    )
    .map_err(|error| format!("decode {}: {error}", path.display()))
}

pub(super) fn write_json_atomic(path: &Path, value: &impl serde::Serialize) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = path.with_extension(format!("tmp-{}", uuid::Uuid::now_v7()));
    fs::write(
        &temporary,
        serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?,
    )
    .map_err(|error| format!("write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, path).map_err(|error| format!("activate {}: {error}", path.display()))
}

pub(super) fn tree_version(root: &Path) -> Result<String, String> {
    let mut files = walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("hash worker tree: {error}"))?;
    files.retain(|entry| {
        let is_root_hash = entry
            .path()
            .strip_prefix(root)
            .is_ok_and(|relative| relative == Path::new("content.sha256"));
        (entry.file_type().is_file() || entry.file_type().is_symlink()) && !is_root_hash
    });
    files.sort_by(|left, right| left.path().cmp(right.path()));
    let mut digest = Sha256::new();
    for entry in files {
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(|error| error.to_string())?;
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        if entry.file_type().is_symlink() {
            digest.update(
                fs::read_link(entry.path())
                    .map_err(|error| {
                        format!("hash worker symlink {}: {error}", entry.path().display())
                    })?
                    .to_string_lossy()
                    .as_bytes(),
            );
            digest.update([0xfe]);
        } else {
            digest.update(fs::read(entry.path()).map_err(|error| {
                format!("hash worker file {}: {error}", entry.path().display())
            })?);
            digest.update([0xff]);
        }
    }
    Ok(hex::encode(digest.finalize()))
}
