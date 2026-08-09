use super::support::*;
use std::process::Command;
use tempfile::tempdir;

fn run_git(cwd: &std::path::Path, args: &[&str]) {
    let status = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .env("GIT_TERMINAL_PROMPT", "0")
        .status()
        .expect("launch git");
    assert!(status.success(), "git {args:?}");
}

#[tokio::test]
async fn create_normalizes_home_alias_working_directory() {
    let ctx = make_test_context();
    let expected = crate::shared::foundation::paths::normalize_working_directory("~")
        .unwrap()
        .display()
        .to_string();

    let response = SessionLifecycleService::create(
        &Deps::from_test_context(&ctx),
        CreateSessionRequest {
            working_directory: "~".to_owned(),
            model: "gpt-5.5".to_owned(),
            title: Some("home alias".to_owned()),
            source_control: None,
        },
    )
    .await
    .unwrap();

    assert_eq!(response["workingDirectory"], expected);
    let session_id = response["sessionId"].as_str().unwrap();
    let session = ctx.event_store.get_session(session_id).unwrap().unwrap();
    assert_eq!(session.working_directory, expected);
}

#[tokio::test]
async fn create_persists_the_authoritative_selected_git_checkout() {
    let repository = tempdir().expect("repository");
    run_git(repository.path(), &["init", "--quiet"]);
    run_git(repository.path(), &["config", "user.name", "Tron Test"]);
    run_git(
        repository.path(),
        &["config", "user.email", "test@example.invalid"],
    );
    std::fs::write(repository.path().join("README.md"), "test\n").expect("fixture");
    run_git(repository.path(), &["add", "README.md"]);
    run_git(repository.path(), &["commit", "--quiet", "-m", "Initial"]);

    let ctx = make_test_context();
    let expected = repository
        .path()
        .canonicalize()
        .unwrap()
        .display()
        .to_string();
    let response = SessionLifecycleService::create(
        &Deps::from_test_context(&ctx),
        CreateSessionRequest {
            working_directory: expected.clone(),
            model: "gpt-5.5".to_owned(),
            title: Some("git checkout".to_owned()),
            source_control: Some(
                crate::domains::filesystem::source_control::SessionSourceControlRequest {
                    placement: crate::domains::filesystem::source_control::SessionCheckoutPlacement::Existing,
                },
            ),
        },
    )
    .await
    .unwrap();

    assert_eq!(response["workingDirectory"], expected);
    let session_id = response["sessionId"].as_str().unwrap();
    let session = ctx.event_store.get_session(session_id).unwrap().unwrap();
    assert_eq!(session.working_directory, expected);
}
