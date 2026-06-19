//! Filesystem workspace-browser domain.
//!
//! This domain restores only the human-facing workspace picker subset from the
//! old capability branch: home discovery, bounded directory browsing, hidden
//! entry visibility, and folder creation. It is not the old model-facing
//! filesystem tool suite; agent read/write/process primitives still flow
//! through `capability::execute` with working-directory authority.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Narrow `filesystem::*` workspace-browser contracts |
//! | `handlers` | Operation-key binding table |
//! | `service` | Hardened local filesystem reads/writes for selector UX |
//!
//! # INVARIANT: workspace browser, not agent filesystem toolbox
//!
//! This domain may expose `filesystem::get_home`, `filesystem::list_dir`, and
//! `filesystem::create_dir` for authenticated iOS UI selection flows. It must
//! not restore read/write/search/diff/apply-patch/model-tool filesystem
//! operations without a later Phase 2 agent-execution scorecard.

use std::path::PathBuf;

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::shared::foundation::paths;

pub(crate) mod contract;
mod handlers;
mod service;

pub(crate) const WORKER: &str = "filesystem";
const STREAM_TOPICS: &[&str] = &[];

#[derive(Clone)]
pub(crate) struct Deps {
    home_dir: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(_deps: &DomainRegistrationContext) -> Self {
        Self {
            home_dir: PathBuf::from(paths::home_dir()),
        }
    }

    #[cfg(test)]
    fn for_home(home_dir: PathBuf) -> Self {
        Self { home_dir }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;
    use tempfile::tempdir;

    use super::service::{CreateDirParams, ListDirParams};
    use super::*;

    #[test]
    fn list_dir_filters_hidden_entries_unless_requested() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir(dir.path().join("visible")).expect("visible dir");
        fs::create_dir(dir.path().join(".hidden")).expect("hidden dir");
        let deps = Deps::for_home(dir.path().to_path_buf());

        let hidden_filtered = service::list_dir(
            &deps,
            ListDirParams {
                path: Some(dir.path().display().to_string()),
                show_hidden: Some(false),
                max_results: None,
            },
        )
        .expect("list without hidden");
        assert_eq!(hidden_filtered.entries.len(), 1);
        assert_eq!(hidden_filtered.entries[0].name, "visible");

        let with_hidden = service::list_dir(
            &deps,
            ListDirParams {
                path: Some(dir.path().display().to_string()),
                show_hidden: Some(true),
                max_results: None,
            },
        )
        .expect("list with hidden");
        let names = with_hidden
            .entries
            .iter()
            .map(|entry| entry.name.as_str())
            .collect::<Vec<_>>();
        assert!(names.contains(&"visible"));
        assert!(names.contains(&".hidden"));
    }

    #[test]
    fn list_dir_sorts_directories_before_files_and_reports_truncation() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("aaa-file.txt"), "data").expect("file");
        fs::create_dir(dir.path().join("zzz-dir")).expect("dir");
        fs::create_dir(dir.path().join("aaa-dir")).expect("dir");
        let deps = Deps::for_home(dir.path().to_path_buf());

        let result = service::list_dir(
            &deps,
            ListDirParams {
                path: Some(dir.path().display().to_string()),
                show_hidden: Some(false),
                max_results: Some(2),
            },
        )
        .expect("list");

        assert!(result.truncated);
        assert_eq!(
            result
                .entries
                .iter()
                .map(|entry| (entry.name.as_str(), entry.is_directory))
                .collect::<Vec<_>>(),
            vec![("aaa-dir", true), ("zzz-dir", true)]
        );
    }

    #[test]
    fn create_dir_is_idempotent_for_existing_directory() {
        let dir = tempdir().expect("tempdir");
        let deps = Deps::for_home(dir.path().to_path_buf());
        let target = dir.path().join("created");

        let created = service::create_dir(
            CreateDirParams {
                path: target.display().to_string(),
                recursive: Some(false),
            },
            &deps,
        )
        .expect("create");
        assert_eq!(created.created, true);
        assert!(target.is_dir());

        let replay = service::create_dir(
            CreateDirParams {
                path: target.display().to_string(),
                recursive: Some(false),
            },
            &deps,
        )
        .expect("idempotent create");
        assert_eq!(replay.created, false);
    }

    #[test]
    fn create_dir_rejects_existing_file() {
        let dir = tempdir().expect("tempdir");
        let deps = Deps::for_home(dir.path().to_path_buf());
        let target = dir.path().join("file.txt");
        fs::write(&target, "data").expect("file");

        let error = service::create_dir(
            CreateDirParams {
                path: target.display().to_string(),
                recursive: Some(false),
            },
            &deps,
        )
        .expect_err("file cannot become directory");
        assert!(error.to_string().contains("exists but is not a directory"));
    }

    #[tokio::test]
    async fn handlers_round_trip_workspace_browser_payloads() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir(dir.path().join("project")).expect("project");
        let deps = Deps::for_home(dir.path().to_path_buf());

        let get_home = service::get_home_value(&deps).await.expect("home");
        assert_eq!(get_home["homePath"], dir.path().display().to_string());

        let listed = service::list_dir_value(
            json!({
                "path": dir.path().display().to_string(),
                "showHidden": false
            }),
            &deps,
        )
        .await
        .expect("list");
        assert_eq!(listed["entries"][0]["name"], "project");

        let created = service::create_dir_value(
            json!({
                "path": dir.path().join("from-handler").display().to_string(),
                "recursive": false
            }),
            &deps,
        )
        .await
        .expect("create");
        assert_eq!(created["created"], true);
    }
}
