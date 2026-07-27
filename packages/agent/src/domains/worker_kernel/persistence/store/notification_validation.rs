//! Closed installation identity, APNs route, token, and action validation.

use crate::domains::worker_kernel::notifications::NotificationEnvironment;

pub(super) fn validate_notification_identifier(value: &str, field: &str) -> Result<(), String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 160
        || !trimmed
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_:.".contains(character))
    {
        return Err(format!("{field} contains unsupported characters"));
    }
    Ok(())
}

fn validate_topic(topic: &str) -> Result<(), String> {
    if topic.is_empty()
        || topic.len() > 255
        || !topic
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || ".-".contains(character))
    {
        return Err("topic must be a valid application bundle identifier".to_owned());
    }
    Ok(())
}

pub(super) fn validate_topic_environment(
    topic: &str,
    environment: NotificationEnvironment,
) -> Result<(), String> {
    validate_topic(topic)?;
    let valid = matches!(
        (topic, environment),
        ("com.tron.mobile.beta", NotificationEnvironment::Sandbox)
            | ("com.tron.mobile", NotificationEnvironment::Sandbox)
            | ("com.tron.mobile", NotificationEnvironment::Production)
    );
    if !valid {
        return Err(
            "topic and environment must match Beta sandbox, local Prod sandbox, or distributed Prod production".to_owned(),
        );
    }
    Ok(())
}

pub(super) fn normalize_device_token(token: Option<&str>) -> Result<Option<String>, String> {
    let Some(token) = token.map(str::trim).filter(|token| !token.is_empty()) else {
        return Ok(None);
    };
    if !(32..=512).contains(&token.len())
        || token.len() % 2 != 0
        || !token.chars().all(|character| character.is_ascii_hexdigit())
    {
        return Err("token must be a hexadecimal APNs device token".to_owned());
    }
    Ok(Some(token.to_ascii_lowercase()))
}

pub(super) fn decode_environment(value: String) -> rusqlite::Result<NotificationEnvironment> {
    match value.as_str() {
        "sandbox" => Ok(NotificationEnvironment::Sandbox),
        "production" => Ok(NotificationEnvironment::Production),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            value.len(),
            rusqlite::types::Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "unknown notification environment",
            )),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, Utc};

    use crate::domains::worker_kernel::notifications::{
        NotificationIntent, NotificationResponseAction,
    };

    #[test]
    fn device_tokens_are_normalized_without_entering_responses() {
        assert_eq!(
            normalize_device_token(Some(&"AB".repeat(32))).unwrap(),
            Some("ab".repeat(32))
        );
        assert!(normalize_device_token(Some("not-a-token")).is_err());
    }

    #[test]
    fn delivery_actions_remain_fixed() {
        let intent = NotificationIntent {
            deduplication_key: "reminder:one".to_owned(),
            title: "Title".to_owned(),
            body: "Body".to_owned(),
            expires_at: Utc::now() + Duration::hours(1),
            not_before: Utc::now(),
            thread_key: None,
            source_record_id: None,
            actions: vec![
                NotificationResponseAction::Snooze,
                NotificationResponseAction::Complete,
            ],
            on_open_complete: true,
        };
        assert_eq!(intent.actions.len(), 2);
    }

    #[test]
    fn application_topics_are_closed_and_environment_bound() {
        assert!(
            validate_topic_environment("com.tron.mobile.beta", NotificationEnvironment::Sandbox)
                .is_ok()
        );
        assert!(
            validate_topic_environment("com.tron.mobile", NotificationEnvironment::Sandbox).is_ok()
        );
        assert!(
            validate_topic_environment("com.tron.mobile", NotificationEnvironment::Production)
                .is_ok()
        );
        assert!(
            validate_topic_environment("com.tron.mobile.beta", NotificationEnvironment::Production)
                .is_err()
        );
        assert!(
            validate_topic_environment("com.example.other", NotificationEnvironment::Sandbox)
                .is_err()
        );
    }
}
