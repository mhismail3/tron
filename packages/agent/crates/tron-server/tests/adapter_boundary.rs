#![allow(missing_docs)]

use std::path::{Path, PathBuf};

fn collect_rs_files(root: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_rs_files(&path, out);
            } else if path.extension().and_then(std::ffi::OsStr::to_str) == Some("rs") {
                out.push(path);
            }
        }
    }
}

#[test]
fn rpc_handlers_do_not_call_adapters_directly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let handlers_dir = manifest_dir.join("src").join("rpc").join("handlers");
    let mut files = Vec::new();
    collect_rs_files(&handlers_dir, &mut files);

    let offenders: Vec<String> = files
        .iter()
        .filter_map(|file| {
            let content = std::fs::read_to_string(file).ok()?;
            if content.contains("crate::rpc::adapters::") {
                Some(file.display().to_string())
            } else {
                None
            }
        })
        .collect();

    assert!(
        offenders.is_empty(),
        "direct adapter calls are forbidden in rpc handlers: {offenders:?}"
    );
}

#[test]
fn adapter_calls_are_confined_to_dispatch_boundaries() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let src_dir = manifest_dir.join("src");
    let mut files = Vec::new();
    collect_rs_files(&src_dir, &mut files);

    let allowed = [
        manifest_dir.join("src").join("rpc").join("adapters.rs"),
        manifest_dir
            .join("src")
            .join("websocket")
            .join("handler.rs"),
        manifest_dir
            .join("src")
            .join("websocket")
            .join("event_bridge.rs"),
    ];

    let offenders: Vec<String> = files
        .iter()
        .filter_map(|file| {
            if allowed.iter().any(|allowed_file| allowed_file == file) {
                return None;
            }
            let content = std::fs::read_to_string(file).ok()?;
            if content.contains("crate::rpc::adapters::") {
                Some(file.display().to_string())
            } else {
                None
            }
        })
        .collect();

    assert!(
        offenders.is_empty(),
        "adapter calls must stay in websocket dispatch boundaries: {offenders:?}"
    );
}
