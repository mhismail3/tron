//! Atomic worker authoring and bounded staged-source import.

use std::path::Path;

use serde_json::{Value, json};

use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;

use super::super::host;
use super::super::types::WorkerBundle;
use super::Deps;
use super::support::{require_autonomous, required_string};

const MAX_WORKER_SOURCE_FILES: usize = 1_024;
const MAX_WORKER_SOURCE_BYTES: u64 = 16 * 1_048_576;

pub(super) async fn upsert(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let mut bundle: WorkerBundle = serde_json::from_value(
        invocation
            .payload
            .get("bundle")
            .cloned()
            .ok_or_else(|| "worker_upsert requires bundle".to_owned())?,
    )
    .map_err(|error| format!("decode worker bundle: {error}"))?;
    let source_import = if invocation.payload.get("sourceDirectory").is_some() {
        let source_directory = host::resolve_path(
            invocation,
            &required_string(&invocation.payload, "sourceDirectory")?,
        )?;
        let (imported_bundle, summary) =
            run_blocking_task("worker_kernel::import_source_directory", move || {
                let summary = import_source_directory(&source_directory, &mut bundle)
                    .map_err(|message| ToolError::Internal { message })?;
                Ok((bundle, summary))
            })
            .await
            .map_err(|error| error.to_string())?;
        bundle = imported_bundle;
        Some(summary)
    } else {
        None
    };
    let predecessor = invocation
        .payload
        .get("predecessorWorkerId")
        .and_then(Value::as_str);
    let outcome = deps.runtime.upsert(bundle, predecessor).await?;
    if let Some(session_id) = invocation.causal_context.session_id.as_deref() {
        crate::domains::worker_kernel::promote_worker_for_session(
            deps.runtime.host(),
            session_id,
            &outcome.worker.worker_id,
            &outcome.worker.active_version,
        )
        .await?;
    }
    let mut response = serde_json::to_value(outcome).map_err(|error| error.to_string())?;
    if let (Some(response), Some((file_count, bytes))) = (response.as_object_mut(), source_import) {
        response.insert(
            "sourceImport".to_owned(),
            json!({"fileCount":file_count,"bytes":bytes}),
        );
    }
    Ok(response)
}

/// Import a staged UTF-8 source tree into a candidate without making the model
/// echo every file through JSON. Explicit inline bundle files win on duplicate
/// relative paths. Symlinks and special files are rejected so the immutable
/// version always contains exactly the tree the caller selected.
fn import_source_directory(
    source_directory: &Path,
    bundle: &mut WorkerBundle,
) -> Result<(usize, u64), String> {
    let root_metadata = std::fs::symlink_metadata(source_directory).map_err(|error| {
        format!(
            "inspect worker source directory {}: {error}",
            source_directory.display()
        )
    })?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(format!(
            "worker source directory must be a real directory, not a symlink or file: {}",
            source_directory.display()
        ));
    }

    let mut file_count = 0usize;
    let mut total_bytes = 0u64;
    for entry in walkdir::WalkDir::new(source_directory)
        .follow_links(false)
        .sort_by_file_name()
    {
        let entry = entry.map_err(|error| format!("walk worker source directory: {error}"))?;
        if entry.depth() == 0 {
            continue;
        }
        if entry.file_type().is_symlink() {
            return Err(format!(
                "worker source directory cannot contain symlinks: {}",
                entry.path().display()
            ));
        }
        if entry.file_type().is_dir() {
            continue;
        }
        if !entry.file_type().is_file() {
            return Err(format!(
                "worker source directory contains a non-file entry: {}",
                entry.path().display()
            ));
        }
        file_count = file_count
            .checked_add(1)
            .ok_or_else(|| "worker source file count overflow".to_owned())?;
        if file_count > MAX_WORKER_SOURCE_FILES {
            return Err(format!(
                "worker source directory exceeds the {MAX_WORKER_SOURCE_FILES}-file reliability ceiling"
            ));
        }
        let bytes = std::fs::read(entry.path())
            .map_err(|error| format!("read worker source {}: {error}", entry.path().display()))?;
        total_bytes = total_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| "worker source byte count overflow".to_owned())?;
        if total_bytes > MAX_WORKER_SOURCE_BYTES {
            return Err(format!(
                "worker source directory exceeds the {MAX_WORKER_SOURCE_BYTES}-byte reliability ceiling"
            ));
        }
        let content = String::from_utf8(bytes).map_err(|_| {
            format!(
                "worker source files must be UTF-8 text: {}",
                entry.path().display()
            )
        })?;
        let relative = entry
            .path()
            .strip_prefix(source_directory)
            .map_err(|error| {
                format!(
                    "derive relative worker source path for {}: {error}",
                    entry.path().display()
                )
            })?;
        let relative = relative
            .components()
            .map(|component| {
                component
                    .as_os_str()
                    .to_str()
                    .ok_or_else(|| {
                        format!(
                            "worker source path is not UTF-8: {}",
                            entry.path().display()
                        )
                    })
                    .map(ToOwned::to_owned)
            })
            .collect::<Result<Vec<_>, _>>()?
            .join("/");
        bundle.files.entry(relative).or_insert(content);
    }
    Ok((file_count, total_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_directory_imports_nested_utf8_files_and_inline_content_wins() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("lib")).unwrap();
        std::fs::write(root.path().join("main.py"), "print('staged')\n").unwrap();
        std::fs::write(root.path().join("lib/helper.py"), "VALUE = 1\n").unwrap();
        let mut bundle = test_worker_bundle();
        bundle
            .files
            .insert("main.py".to_owned(), "print('inline')\n".to_owned());

        let summary = import_source_directory(root.path(), &mut bundle).unwrap();

        assert_eq!(summary.0, 2);
        assert_eq!(bundle.files["main.py"], "print('inline')\n");
        assert_eq!(bundle.files["lib/helper.py"], "VALUE = 1\n");
    }

    #[test]
    fn source_directory_rejects_binary_files_and_symlinks() {
        let binary_root = tempfile::tempdir().unwrap();
        std::fs::write(binary_root.path().join("binary"), [0xff, 0xfe]).unwrap();
        assert!(
            import_source_directory(binary_root.path(), &mut test_worker_bundle())
                .unwrap_err()
                .contains("UTF-8")
        );

        let linked_root = tempfile::tempdir().unwrap();
        std::fs::write(linked_root.path().join("target.txt"), "target").unwrap();
        std::os::unix::fs::symlink(
            linked_root.path().join("target.txt"),
            linked_root.path().join("link.txt"),
        )
        .unwrap();
        assert!(
            import_source_directory(linked_root.path(), &mut test_worker_bundle())
                .unwrap_err()
                .contains("symlinks")
        );
    }

    fn test_worker_bundle() -> WorkerBundle {
        serde_json::from_value(json!({
            "schemaVersion":"tron.worker_bundle.v1",
            "name":"Source Import",
            "description":"Test source directory import",
            "inputSchema":{"type":"object"},
            "outputSchema":{"type":"object"},
            "runner":{"kind":"command","command":["python3","main.py"]},
            "provenance":[{"source":"test:source-directory"}]
        }))
        .unwrap()
    }
}
