mod authority;
mod inbox;
mod support;

#[test]
fn level_two_notification_family_uses_delegation_and_retires_subagent() {
    assert_eq!(
        super::validation::parse_event_family(Some("delegation".to_owned())).unwrap(),
        "delegation"
    );
    assert!(
        super::validation::parse_event_family(Some("subagent".to_owned())).is_err(),
        "retired subagent vocabulary must not create new notifications"
    );
}
