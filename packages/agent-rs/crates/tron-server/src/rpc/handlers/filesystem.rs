//! Filesystem handlers: listDir, getHome, createDir, file.read.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// List directory contents.
pub struct ListDirHandler;

#[async_trait]
impl MethodHandler for ListDirHandler {
    #[instrument(skip(self, _ctx), fields(method = "filesystem.listDir"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
        let path = params
            .as_ref()
            .and_then(|p| p.get("path"))
            .and_then(Value::as_str)
            .unwrap_or(&home)
            .to_string();

        let show_hidden = params
            .as_ref()
            .and_then(|p| p.get("showHidden"))
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let entries = std::fs::read_dir(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                RpcError::NotFound {
                    code: errors::FILE_NOT_FOUND.into(),
                    message: format!("Directory not found: {path}"),
                }
            } else {
                RpcError::Custom {
                    code: errors::FILESYSTEM_ERROR.into(),
                    message: e.to_string(),
                    details: None,
                }
            }
        })?;

        let mut items: Vec<Value> = entries
            .filter_map(std::result::Result::ok)
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                if !show_hidden && name.starts_with('.') {
                    return None;
                }
                let ft = e.file_type().ok()?;
                let is_dir = ft.is_dir();
                let is_symlink = ft.is_symlink();
                let entry_path = format!("{path}/{name}");

                let mut entry = serde_json::json!({
                    "name": name,
                    "path": entry_path,
                    "isDirectory": is_dir,
                    "isSymlink": is_symlink,
                });

                // Add size and modifiedAt for files
                if !is_dir {
                    if let Ok(meta) = e.metadata() {
                        entry["size"] = serde_json::json!(meta.len());
                        if let Ok(modified) = meta.modified() {
                            let dt: chrono::DateTime<chrono::Utc> = modified.into();
                            entry["modifiedAt"] = serde_json::json!(dt.to_rfc3339());
                        }
                    }
                }

                Some(entry)
            })
            .collect();

        // Sort: directories first, then alphabetically
        items.sort_by(|a, b| {
            let a_dir = a["isDirectory"].as_bool().unwrap_or(false);
            let b_dir = b["isDirectory"].as_bool().unwrap_or(false);
            match (a_dir, b_dir) {
                (true, false) => std::cmp::Ordering::Less,
                (false, true) => std::cmp::Ordering::Greater,
                _ => {
                    let a_name = a["name"].as_str().unwrap_or("");
                    let b_name = b["name"].as_str().unwrap_or("");
                    a_name.to_lowercase().cmp(&b_name.to_lowercase())
                }
            }
        });

        let parent = std::path::Path::new(&path)
            .parent()
            .map(|p| p.to_string_lossy().to_string());

        Ok(serde_json::json!({
            "path": path,
            "parent": parent,
            "entries": items,
        }))
    }
}

/// Get user home directory.
pub struct GetHomeHandler;

#[async_trait]
impl MethodHandler for GetHomeHandler {
    #[instrument(skip(self, _ctx), fields(method = "filesystem.getHome"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());

        // Build suggested paths (common workspaces)
        let mut suggested = Vec::new();
        for name in &["Desktop", "Documents", "Projects", "Workspace", "Developer", "Code"] {
            let path = format!("{home}/{name}");
            let exists = std::path::Path::new(&path).is_dir();
            if exists {
                suggested.push(serde_json::json!({
                    "name": name,
                    "path": path,
                    "exists": true,
                }));
            }
        }

        Ok(serde_json::json!({
            "homePath": home,
            "suggestedPaths": suggested,
        }))
    }
}

/// Create a directory (recursive).
pub struct CreateDirHandler;

#[async_trait]
impl MethodHandler for CreateDirHandler {
    #[instrument(skip(self, _ctx), fields(method = "filesystem.mkdir"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;

        std::fs::create_dir_all(&path).map_err(|e| RpcError::Custom {
            code: errors::FILESYSTEM_ERROR.into(),
            message: e.to_string(),
            details: None,
        })?;

        Ok(serde_json::json!({ "created": true, "path": path }))
    }
}

/// Read file contents.
pub struct ReadFileHandler;

#[async_trait]
impl MethodHandler for ReadFileHandler {
    #[instrument(skip(self, _ctx), fields(method = "file.read"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;

        let content = std::fs::read_to_string(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                RpcError::NotFound {
                    code: errors::FILE_NOT_FOUND.into(),
                    message: format!("File not found: {path}"),
                }
            } else {
                RpcError::Custom {
                    code: errors::FILE_ERROR.into(),
                    message: e.to_string(),
                    details: None,
                }
            }
        })?;

        Ok(serde_json::json!({ "content": content, "path": path }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_dir_success() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert!(result["entries"].is_array());
        assert_eq!(result["path"], "/tmp");
        assert!(result["parent"].is_string());
    }

    #[tokio::test]
    async fn list_dir_entries_have_full_fields() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        let entries = result["entries"].as_array().unwrap();
        for entry in entries {
            assert!(entry["name"].is_string());
            assert!(entry["path"].is_string());
            assert!(entry.get("isDirectory").is_some());
            assert!(entry.get("isSymlink").is_some());
        }
    }

    #[tokio::test]
    async fn list_dir_defaults_to_home() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap();
        assert!(result["entries"].is_array());
        assert!(result["path"].is_string());
    }

    #[tokio::test]
    async fn list_dir_not_found() {
        let ctx = make_test_context();
        let err = ListDirHandler
            .handle(
                Some(json!({"path": "/nonexistent_dir_xyz_12345"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn list_dir_hides_dotfiles_by_default() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        let entries = result["entries"].as_array().unwrap();
        for entry in entries {
            let name = entry["name"].as_str().unwrap();
            assert!(!name.starts_with('.'));
        }
    }

    #[tokio::test]
    async fn list_dir_directories_first() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        let entries = result["entries"].as_array().unwrap();
        let mut seen_file = false;
        for entry in entries {
            let is_dir = entry["isDirectory"].as_bool().unwrap_or(false);
            if !is_dir {
                seen_file = true;
            }
            if seen_file && is_dir {
                panic!("directory appeared after file — not sorted correctly");
            }
        }
    }

    #[tokio::test]
    async fn get_home() {
        let ctx = make_test_context();
        let result = GetHomeHandler.handle(None, &ctx).await.unwrap();
        assert!(result["homePath"].is_string());
        assert!(!result["homePath"].as_str().unwrap().is_empty());
        assert!(result["suggestedPaths"].is_array());
    }

    #[tokio::test]
    async fn read_file_not_found() {
        let ctx = make_test_context();
        let err = ReadFileHandler
            .handle(
                Some(json!({"path": "/nonexistent_file_xyz_12345.txt"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn read_file_missing_param() {
        let ctx = make_test_context();
        let err = ReadFileHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
