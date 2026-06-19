//! Hardened service helpers for the iOS workspace browser.

use std::cmp::Ordering;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::errors::to_json_value;

use super::Deps;

const DEFAULT_MAX_RESULTS: usize = 500;
const MAX_RESULTS: usize = 2_000;
const FILESYSTEM_ERROR: &str = "FILESYSTEM_ERROR";
const FILESYSTEM_NOT_DIRECTORY: &str = "FILESYSTEM_NOT_DIRECTORY";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ListDirParams {
    #[serde(default)]
    pub(super) path: Option<String>,
    #[serde(default)]
    pub(super) show_hidden: Option<bool>,
    #[serde(default)]
    pub(super) max_results: Option<usize>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CreateDirParams {
    pub(super) path: String,
    #[serde(default)]
    pub(super) recursive: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct HomeResult {
    home_path: String,
    suggested_paths: Vec<SuggestedPath>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SuggestedPath {
    name: String,
    path: String,
    exists: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DirectoryListResult {
    pub(super) path: String,
    pub(super) parent: Option<String>,
    pub(super) entries: Vec<DirectoryEntry>,
    pub(super) truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DirectoryEntry {
    pub(super) name: String,
    pub(super) path: String,
    pub(super) is_directory: bool,
    pub(super) is_symlink: bool,
    size: Option<u64>,
    modified_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CreateDirResult {
    pub(super) created: bool,
    pub(super) path: String,
}

pub(super) async fn get_home_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let deps = deps.clone();
    run_blocking_task("filesystem::get_home", move || {
        to_json_value(&get_home(&deps))
    })
    .await
}

pub(super) async fn list_dir_value(payload: Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let params =
        serde_json::from_value(payload).map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid filesystem list_dir params: {error}"),
        })?;
    let deps = deps.clone();
    run_blocking_task("filesystem::list_dir", move || {
        let result = list_dir(&deps, params)?;
        to_json_value(&result)
    })
    .await
}

pub(super) async fn create_dir_value(
    payload: Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params =
        serde_json::from_value(payload).map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid filesystem create_dir params: {error}"),
        })?;
    let deps = deps.clone();
    run_blocking_task("filesystem::create_dir", move || {
        let result = create_dir(params, &deps)?;
        to_json_value(&result)
    })
    .await
}

fn get_home(deps: &Deps) -> HomeResult {
    let home_path = deps.home_dir.display().to_string();
    let suggested_paths = [
        "Desktop",
        "Documents",
        "Projects",
        "Workspace",
        "Developer",
        "Code",
    ]
    .into_iter()
    .filter_map(|name| {
        let path = deps.home_dir.join(name);
        path.is_dir().then(|| SuggestedPath {
            name: name.to_owned(),
            path: path.display().to_string(),
            exists: true,
        })
    })
    .collect();
    HomeResult {
        home_path,
        suggested_paths,
    }
}

pub(super) fn list_dir(
    deps: &Deps,
    params: ListDirParams,
) -> Result<DirectoryListResult, CapabilityError> {
    let path = normalize_user_path(params.path.as_deref().unwrap_or("~"), deps)?;
    let max_results = params
        .max_results
        .unwrap_or(DEFAULT_MAX_RESULTS)
        .min(MAX_RESULTS);
    let show_hidden = params.show_hidden.unwrap_or(false);

    let metadata = fs::symlink_metadata(&path).map_err(|error| map_io_error(error, &path))?;
    if !metadata.is_dir() {
        return Err(CapabilityError::Custom {
            code: FILESYSTEM_NOT_DIRECTORY.to_owned(),
            message: format!("Path is not a directory: {}", path.display()),
            details: None,
        });
    }

    let mut entries = fs::read_dir(&path)
        .map_err(|error| map_io_error(error, &path))?
        .filter_map(Result::ok)
        .filter_map(|entry| directory_entry(entry, show_hidden))
        .collect::<Vec<_>>();

    entries.sort_by(compare_entries);
    let truncated = entries.len() > max_results;
    entries.truncate(max_results);

    let parent = path.parent().map(display_path);
    Ok(DirectoryListResult {
        path: display_path(&path),
        parent,
        entries,
        truncated,
    })
}

pub(super) fn create_dir(
    params: CreateDirParams,
    deps: &Deps,
) -> Result<CreateDirResult, CapabilityError> {
    let path = normalize_user_path(&params.path, deps)?;
    if path.as_os_str().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "path must not be empty".to_owned(),
        });
    }
    if path.exists() {
        if path.is_dir() {
            return Ok(CreateDirResult {
                created: false,
                path: display_path(&path),
            });
        }
        return Err(CapabilityError::Custom {
            code: FILESYSTEM_ERROR.to_owned(),
            message: format!("Path exists but is not a directory: {}", path.display()),
            details: None,
        });
    }

    let result = if params.recursive.unwrap_or(false) {
        fs::create_dir_all(&path)
    } else {
        fs::create_dir(&path)
    };
    result.map_err(|error| map_io_error(error, &path))?;

    Ok(CreateDirResult {
        created: true,
        path: display_path(&path),
    })
}

fn directory_entry(entry: fs::DirEntry, show_hidden: bool) -> Option<DirectoryEntry> {
    let name = entry.file_name().to_string_lossy().to_string();
    if !show_hidden && name.starts_with('.') {
        return None;
    }

    let file_type = entry.file_type().ok()?;
    let is_symlink = file_type.is_symlink();
    let is_directory = if file_type.is_dir() {
        true
    } else if is_symlink {
        entry
            .metadata()
            .map(|metadata| metadata.is_dir())
            .unwrap_or(false)
    } else {
        false
    };
    let metadata = entry.metadata().ok();
    let size = metadata
        .as_ref()
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len());
    let modified_at = metadata
        .and_then(|metadata| metadata.modified().ok())
        .map(format_system_time);

    Some(DirectoryEntry {
        name,
        path: display_path(&entry.path()),
        is_directory,
        is_symlink,
        size,
        modified_at,
    })
}

fn compare_entries(left: &DirectoryEntry, right: &DirectoryEntry) -> Ordering {
    match (left.is_directory, right.is_directory) {
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
        _ => left.name.to_lowercase().cmp(&right.name.to_lowercase()),
    }
}

fn normalize_user_path(raw: &str, deps: &Deps) -> Result<PathBuf, CapabilityError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "path must not be empty".to_owned(),
        });
    }
    if raw == "~" {
        return Ok(deps.home_dir.clone());
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return Ok(deps.home_dir.join(rest));
    }
    Ok(PathBuf::from(raw))
}

fn map_io_error(error: std::io::Error, path: &Path) -> CapabilityError {
    if error.kind() == std::io::ErrorKind::NotFound {
        return CapabilityError::NotFound {
            code: "FILESYSTEM_NOT_FOUND".to_owned(),
            message: format!("Filesystem path not found: {}", path.display()),
        };
    }
    CapabilityError::Custom {
        code: FILESYSTEM_ERROR.to_owned(),
        message: format!("{}: {}", path.display(), error),
        details: None,
    }
}

fn display_path(path: &Path) -> String {
    path.display().to_string()
}

fn format_system_time(time: SystemTime) -> String {
    let datetime: DateTime<Utc> = time.into();
    datetime.to_rfc3339()
}
