use std::fs;

use serde_json::json;
use tempfile::tempdir;

use super::service::{CreateDirParams, ListDirParams};
use super::*;

#[test]
fn fixed_contract_is_exactly_the_four_workspace_picker_operations() {
    let functions = contract::function_definitions()
        .expect("workspace contracts")
        .into_iter()
        .map(|definition| definition.id.as_str().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(
        functions,
        [
            "filesystem::get_home",
            "filesystem::list_dir",
            "filesystem::create_dir",
            "filesystem::inspect_source_control"
        ]
    );
}

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
    assert!(created.created);
    assert!(target.is_dir());

    let replay = service::create_dir(
        CreateDirParams {
            path: target.display().to_string(),
            recursive: Some(false),
        },
        &deps,
    )
    .expect("idempotent create");
    assert!(!replay.created);
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
        json!({"path": dir.path().display().to_string(), "showHidden": false}),
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

    let inspected = service::inspect_source_control_value(
        json!({"path": dir.path().display().to_string()}),
        &deps,
    )
    .await
    .expect("inspect source control");
    assert_eq!(inspected["isGitRepository"], false);
    assert!(inspected["currentBranch"].is_null());
}
