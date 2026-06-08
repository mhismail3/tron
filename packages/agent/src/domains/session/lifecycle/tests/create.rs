use super::support::*;

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
        },
    )
    .await
    .unwrap();

    assert_eq!(response["workingDirectory"], expected);
    let session_id = response["sessionId"].as_str().unwrap();
    let session = ctx.event_store.get_session(session_id).unwrap().unwrap();
    assert_eq!(session.working_directory, expected);
}
