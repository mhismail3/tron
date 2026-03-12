use std::cmp::Ordering;
use std::path::Path;

use serde_json::Value;

use crate::rpc::errors::{self, RpcError};

pub(crate) fn list_dir(path: &str, show_hidden: bool) -> Result<Value, RpcError> {
    let entries = std::fs::read_dir(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("Directory not found: {path}"),
            }
        } else {
            RpcError::Custom {
                code: errors::FILESYSTEM_ERROR.into(),
                message: error.to_string(),
                details: None,
            }
        }
    })?;

    let mut items: Vec<Value> = entries
        .filter_map(std::result::Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            if !show_hidden && name.starts_with('.') {
                return None;
            }

            let file_type = entry.file_type().ok()?;
            let is_dir = file_type.is_dir();
            let is_symlink = file_type.is_symlink();
            let entry_path = format!("{path}/{name}");

            let mut item = serde_json::json!({
                "name": name,
                "path": entry_path,
                "isDirectory": is_dir,
                "isSymlink": is_symlink,
            });

            if !is_dir && let Ok(metadata) = entry.metadata() {
                item["size"] = serde_json::json!(metadata.len());
                if let Ok(modified) = metadata.modified() {
                    let datetime: chrono::DateTime<chrono::Utc> = modified.into();
                    item["modifiedAt"] = serde_json::json!(datetime.to_rfc3339());
                }
            }

            Some(item)
        })
        .collect();

    items.sort_by(|left, right| {
        let left_dir = left["isDirectory"].as_bool().unwrap_or(false);
        let right_dir = right["isDirectory"].as_bool().unwrap_or(false);
        match (left_dir, right_dir) {
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            _ => {
                let left_name = left["name"].as_str().unwrap_or("");
                let right_name = right["name"].as_str().unwrap_or("");
                left_name.to_lowercase().cmp(&right_name.to_lowercase())
            }
        }
    });

    let parent = Path::new(&path)
        .parent()
        .map(|parent| parent.to_string_lossy().to_string());

    Ok(serde_json::json!({
        "path": path,
        "parent": parent,
        "entries": items,
    }))
}

pub(crate) fn get_home(home: &str) -> Value {
    let mut suggested = Vec::new();
    for name in &[
        "Desktop",
        "Documents",
        "Projects",
        "Workspace",
        "Developer",
        "Code",
    ] {
        let path = format!("{home}/{name}");
        if Path::new(&path).is_dir() {
            suggested.push(serde_json::json!({
                "name": name,
                "path": path,
                "exists": true,
            }));
        }
    }

    serde_json::json!({
        "homePath": home,
        "suggestedPaths": suggested,
    })
}

pub(crate) fn create_dir(path: &str) -> Result<Value, RpcError> {
    std::fs::create_dir_all(path).map_err(|error| RpcError::Custom {
        code: errors::FILESYSTEM_ERROR.into(),
        message: error.to_string(),
        details: None,
    })?;

    Ok(serde_json::json!({ "created": true, "path": path }))
}

pub(crate) fn read_file(path: &str) -> Result<Value, RpcError> {
    let content = std::fs::read_to_string(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("File not found: {path}"),
            }
        } else {
            RpcError::Custom {
                code: errors::FILE_ERROR.into(),
                message: error.to_string(),
                details: None,
            }
        }
    })?;

    Ok(serde_json::json!({ "content": content, "path": path }))
}
