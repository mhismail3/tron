//! Compare-and-swap file edits and same-directory atomic publication.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::Invocation;

use super::super::runtime::WorkerRuntime;
use super::support::{MAX_FILE_BYTES, required_string, resolve_path, run_blocking};

const DEFAULT_FILE_READ_BYTES: usize = 262_144;
const MAX_HASH_INPUT_BYTES: u64 = 64 * 1_048_576;
const MAX_EDIT_REPLACEMENTS: usize = 128;

pub(in crate::domains::worker_kernel) async fn filesystem_write(
    invocation: &Invocation,
    _runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let content = invocation
        .payload
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| "content is required".to_owned())?
        .as_bytes()
        .to_vec();
    if content.len() > MAX_FILE_BYTES {
        return Err(format!(
            "content exceeds the {MAX_FILE_BYTES}-byte reliability ceiling"
        ));
    }
    let create_parents = invocation
        .payload
        .get("createParents")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let expected_sha256 = invocation
        .payload
        .get("expectedSha256")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    run_blocking("worker_kernel::filesystem_write", move || {
        atomic_publish(&path, &content, create_parents, expected_sha256.as_deref())
    })
    .await
}
pub(in crate::domains::worker_kernel) async fn filesystem_edit(
    invocation: &Invocation,
    _runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let replacements = invocation
        .payload
        .get("replacements")
        .and_then(Value::as_array)
        .ok_or_else(|| "replacements must be an array".to_owned())?;
    if replacements.is_empty() || replacements.len() > MAX_EDIT_REPLACEMENTS {
        return Err(format!(
            "replacements must contain 1 to {MAX_EDIT_REPLACEMENTS} exact edits"
        ));
    }
    let replacements = replacements
        .iter()
        .map(|replacement| {
            let old = replacement
                .get("oldText")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| "each replacement requires non-empty oldText".to_owned())?;
            let new = replacement
                .get("newText")
                .and_then(Value::as_str)
                .ok_or_else(|| "each replacement requires newText".to_owned())?;
            let expected = replacement
                .get("expectedOccurrences")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .clamp(1, 10_000) as usize;
            Ok((old.to_owned(), new.to_owned(), expected))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let expected_sha256 = invocation
        .payload
        .get("expectedSha256")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    run_blocking("worker_kernel::filesystem_edit", move || {
        let bytes = read_file_bounded(&path, MAX_FILE_BYTES)?;
        let previous_sha256 = sha256(&bytes);
        verify_expected_hash(&path, Some(&previous_sha256), expected_sha256.as_deref())?;
        let content = String::from_utf8(bytes)
            .map_err(|_| format!("edit {}: file is not UTF-8", path.display()))?;
        let (content, applied) = apply_exact_replacements(&path, content, &replacements)?;
        if sha256(content.as_bytes()) == previous_sha256 {
            return Ok(json!({
                "path": path,
                "changed": false,
                "replacementsApplied": applied,
                "previousSha256": previous_sha256,
                "sha256": previous_sha256,
                "bytes": content.len(),
            }));
        }
        atomic_publish_bytes(&path, content.as_bytes(), Some(&previous_sha256))?;
        Ok(json!({
            "path": path,
            "changed": true,
            "replacementsApplied": applied,
            "previousSha256": previous_sha256,
            "sha256": sha256(content.as_bytes()),
            "bytes": content.len(),
        }))
    })
    .await
}

fn atomic_publish(
    path: &Path,
    content: &[u8],
    create_parents: bool,
    expected_sha256: Option<&str>,
) -> Result<Value, String> {
    if create_parents
        && let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("create {}: {error}", parent.display()))?;
    }
    let previous_sha256 = if path.exists() {
        Some(hash_file(path)?)
    } else {
        None
    };
    verify_expected_hash(path, previous_sha256.as_deref(), expected_sha256)?;
    let new_sha256 = sha256(content);
    if previous_sha256.as_deref() == Some(new_sha256.as_str()) {
        return Ok(json!({
            "path": path,
            "bytes": content.len(),
            "written": false,
            "changed": false,
            "previousSha256": previous_sha256,
            "sha256": new_sha256,
        }));
    }
    atomic_publish_bytes(
        path,
        content,
        Some(previous_sha256.as_deref().unwrap_or("absent")),
    )?;
    Ok(json!({
        "path": path,
        "bytes": content.len(),
        "written": true,
        "changed": true,
        "previousSha256": previous_sha256,
        "sha256": new_sha256,
    }))
}

fn apply_exact_replacements(
    path: &Path,
    mut content: String,
    replacements: &[(String, String, usize)],
) -> Result<(String, usize), String> {
    let mut applied = 0usize;
    for (index, (old, new, expected)) in replacements.iter().enumerate() {
        let occurrences = content.match_indices(old).count();
        if occurrences != *expected {
            return Err(format!(
                "edit {} replacement {} expected {} occurrence(s), found {}",
                path.display(),
                index + 1,
                expected,
                occurrences
            ));
        }
        content = content.replace(old, new);
        applied = applied.saturating_add(occurrences);
        if content.len() > MAX_FILE_BYTES {
            return Err(format!(
                "edited content exceeds the {MAX_FILE_BYTES}-byte reliability ceiling"
            ));
        }
    }
    Ok((content, applied))
}

fn atomic_publish_bytes(
    path: &Path,
    content: &[u8],
    expected_current_sha256: Option<&str>,
) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let metadata = std::fs::symlink_metadata(path).ok();
    if metadata
        .as_ref()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(format!(
            "atomic write refuses symbolic-link target {}",
            path.display()
        ));
    }
    let temporary = parent.join(format!(".tron-write-{}.tmp", uuid::Uuid::now_v7()));
    let publish = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| format!("stage {}: {error}", path.display()))?;
        file.write_all(content)
            .map_err(|error| format!("stage {}: {error}", path.display()))?;
        if let Some(metadata) = metadata {
            file.set_permissions(metadata.permissions())
                .map_err(|error| format!("preserve permissions for {}: {error}", path.display()))?;
        }
        file.sync_all()
            .map_err(|error| format!("sync staged {}: {error}", path.display()))?;
        if let Some(expected) = expected_current_sha256 {
            if expected == "absent" {
                if path.exists() {
                    return Err(format!(
                        "write {} lost a concurrent create before publication",
                        path.display()
                    ));
                }
            } else {
                let actual = hash_file(path)?;
                if actual != expected {
                    return Err(format!(
                        "write {} lost a concurrent update: expected {expected}, found {actual}",
                        path.display()
                    ));
                }
            }
        }
        std::fs::rename(&temporary, path)
            .map_err(|error| format!("publish {}: {error}", path.display()))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync directory {}: {error}", parent.display()))?;
        Ok(())
    })();
    if publish.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    publish
}

fn verify_expected_hash(
    path: &Path,
    actual: Option<&str>,
    expected: Option<&str>,
) -> Result<(), String> {
    let Some(expected) = expected else {
        return Ok(());
    };
    if expected.eq_ignore_ascii_case("absent") {
        return if actual.is_none() {
            Ok(())
        } else {
            Err(format!(
                "write {} expected the file to be absent",
                path.display()
            ))
        };
    }
    let expected = normalize_sha256(expected);
    if actual == Some(expected.as_str()) {
        Ok(())
    } else {
        Err(format!(
            "write {} checksum mismatch: expected {}, found {}",
            path.display(),
            expected,
            actual.unwrap_or("absent")
        ))
    }
}

fn hash_file(path: &Path) -> Result<String, String> {
    let metadata =
        std::fs::metadata(path).map_err(|error| format!("inspect {}: {error}", path.display()))?;
    if metadata.len() > MAX_HASH_INPUT_BYTES {
        return Err(format!(
            "checksum input {} exceeds the {MAX_HASH_INPUT_BYTES}-byte reliability ceiling",
            path.display()
        ));
    }
    Ok(sha256(&read_file_bounded(
        path,
        MAX_HASH_INPUT_BYTES as usize,
    )?))
}

fn read_file_bounded(path: &Path, max_bytes: usize) -> Result<Vec<u8>, String> {
    let file = File::open(path).map_err(|error| format!("read {}: {error}", path.display()))?;
    let mut bytes = Vec::with_capacity(max_bytes.min(DEFAULT_FILE_READ_BYTES).saturating_add(1));
    file.take(max_bytes.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("read {}: {error}", path.display()))?;
    if bytes.len() > max_bytes {
        return Err(format!(
            "file {} exceeds the {max_bytes}-byte reliability ceiling",
            path.display()
        ));
    }
    Ok(bytes)
}

fn sha256(bytes: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn normalize_sha256(value: &str) -> String {
    if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        format!("sha256:{}", value.to_ascii_lowercase())
    } else {
        value.to_ascii_lowercase()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atomic_publish_is_compare_and_swap_and_preserves_the_old_file_on_mismatch() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("value.txt");
        std::fs::write(&path, "before").unwrap();
        let expected = sha256(b"before");
        let result = atomic_publish(&path, b"after", false, Some(&expected)).unwrap();
        assert_eq!(result["changed"], true);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "after");
        let error = atomic_publish(&path, b"lost", false, Some(&expected)).unwrap_err();
        assert!(error.contains("checksum mismatch"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "after");
    }

    #[test]
    fn exact_replacement_admission_rejects_ambiguous_or_stale_text_before_publish() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("value.txt");
        std::fs::write(&path, "same same").unwrap();
        let error = apply_exact_replacements(
            &path,
            std::fs::read_to_string(&path).unwrap(),
            &[("same".to_owned(), "new".to_owned(), 1)],
        )
        .unwrap_err();
        assert!(error.contains("expected 1 occurrence(s), found 2"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "same same");

        let (edited, applied) = apply_exact_replacements(
            &path,
            std::fs::read_to_string(&path).unwrap(),
            &[("same".to_owned(), "new".to_owned(), 2)],
        )
        .unwrap();
        assert_eq!(edited, "new new");
        assert_eq!(applied, 2);
    }
}
