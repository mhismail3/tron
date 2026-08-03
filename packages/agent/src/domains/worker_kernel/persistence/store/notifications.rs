//! Durable notification installations, logical inbox, fan-out, and responses.
//!
//! Quiet refreshes coalesce per installation. An inbox mutation that arrives
//! while a provider request is in flight moves the row to `sending_pending`;
//! the completed attempt then queues the latest unread count instead of
//! deleting the newer refresh request.

use chrono::{Duration, Utc};
use rusqlite::{OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::notification_validation::{decode_environment, validate_notification_identifier};
use super::*;
use crate::domains::worker_kernel::notifications::{
    NotificationAcknowledgeRequest, NotificationAcknowledgementKind, NotificationEnvironment,
    NotificationIntent,
};

const ACTIVE_INSTALLATION_DAYS: i64 = 30;
const INBOX_RETENTION_DAYS: i64 = 90;
const INBOX_RETENTION_COUNT: usize = 500;

#[derive(Clone, Debug)]
pub(in crate::domains::worker_kernel) struct NotificationTargetDispatch {
    pub(in crate::domains::worker_kernel) target_id: String,
    pub(in crate::domains::worker_kernel) delivery_id: String,
    pub(in crate::domains::worker_kernel) worker_id: String,
    pub(in crate::domains::worker_kernel) source_record_id: Option<String>,
    pub(in crate::domains::worker_kernel) trace_id: String,
    pub(in crate::domains::worker_kernel) installation_id: String,
    pub(in crate::domains::worker_kernel) client_server_id: String,
    pub(in crate::domains::worker_kernel) token: String,
    pub(in crate::domains::worker_kernel) topic: String,
    pub(in crate::domains::worker_kernel) environment: NotificationEnvironment,
    pub(in crate::domains::worker_kernel) title: String,
    pub(in crate::domains::worker_kernel) body: String,
    pub(in crate::domains::worker_kernel) thread_key: Option<String>,
    pub(in crate::domains::worker_kernel) actions: Vec<String>,
    pub(in crate::domains::worker_kernel) expires_at: String,
    pub(in crate::domains::worker_kernel) unread_count: u32,
    pub(in crate::domains::worker_kernel) attempt_number: u32,
}

#[derive(Clone, Debug)]
pub(in crate::domains::worker_kernel) struct NotificationRefreshDispatch {
    pub(in crate::domains::worker_kernel) refresh_id: String,
    pub(in crate::domains::worker_kernel) installation_id: String,
    pub(in crate::domains::worker_kernel) client_server_id: String,
    pub(in crate::domains::worker_kernel) token: String,
    pub(in crate::domains::worker_kernel) topic: String,
    pub(in crate::domains::worker_kernel) environment: NotificationEnvironment,
    pub(in crate::domains::worker_kernel) unread_count: u32,
    pub(in crate::domains::worker_kernel) attempt_number: u32,
}

#[derive(Clone, Debug)]
pub(in crate::domains::worker_kernel) enum NotificationDispatchOutcome {
    Accepted {
        apns_id: String,
    },
    Retryable {
        code: String,
        retry_at: String,
    },
    Permanent {
        code: String,
        invalidate_token: bool,
    },
    Blocked {
        code: String,
        retry_at: String,
    },
}

impl WorkerStore {
    pub(in crate::domains::worker_kernel) fn requeue_notification_configuration_blocks(
        &self,
    ) -> Result<(), String> {
        let now = Utc::now().to_rfc3339();
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE notification_delivery_targets
                 SET state='retry_wait',next_attempt_at=?1,updated_at=?1
                 WHERE state='blocked'
                   AND error_code IN (
                     'notification_relay_credentials_missing',
                     'notification_relay_credentials_invalid',
                     'notification_relay_auth_failed',
                     'notification_relay_contract_unavailable',
                     'notification_transport_config_invalid',
                     'apns_credentials_missing',
                     'apns_credentials_invalid'
                   )
                   AND delivery_id IN (
                     SELECT delivery_id FROM notification_deliveries WHERE expires_at>?1
                   )",
                [&now],
            )
            .map_err(|error| format!("requeue notification configuration blocks: {error}"))?;
        connection
            .execute(
                "UPDATE notification_refreshes
                 SET state='retry_wait',next_attempt_at=?1,updated_at=?1
                 WHERE state='retry_wait'
                   AND error_code IN (
                     'notification_relay_credentials_missing',
                     'notification_relay_credentials_invalid',
                     'notification_relay_auth_failed',
                     'notification_relay_contract_unavailable',
                     'notification_transport_config_invalid',
                     'apns_credentials_missing',
                     'apns_credentials_invalid'
                   )",
                [&now],
            )
            .map_err(|error| {
                format!("requeue notification refresh configuration blocks: {error}")
            })?;
        Ok(())
    }

    pub(super) fn insert_notification_deliveries(
        transaction: &Transaction<'_>,
        invocation_id: &str,
        worker_id: &str,
        worker_version: &str,
        trace_id: &str,
        intents: &[NotificationIntent],
        created_at: &str,
    ) -> Result<(), String> {
        let dispatched_source = transaction
            .query_row(
                "SELECT source_invocation_id,source_worker_id,source_worker_version,
                        response_binding
                 FROM worker_dispatches WHERE target_invocation_id=?1",
                [invocation_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| format!("load notification dispatch ownership: {error}"))?;
        let (source_invocation_id, source_worker_id, source_worker_version) =
            dispatched_source.as_ref().map_or_else(
                || {
                    (
                        invocation_id.to_owned(),
                        worker_id.to_owned(),
                        worker_version.to_owned(),
                    )
                },
                |(source_invocation_id, source_worker_id, source_worker_version, _)| {
                    (
                        source_invocation_id.clone(),
                        source_worker_id.clone(),
                        source_worker_version.clone(),
                    )
                },
            );
        let source_owns_responses = dispatched_source
            .as_ref()
            .is_some_and(|(_, _, _, binding)| binding == "source");
        let (response_worker_id, response_worker_version) = if source_owns_responses {
            (source_worker_id.as_str(), source_worker_version.as_str())
        } else {
            (worker_id, worker_version)
        };
        for intent in intents {
            let delivery_id = format!("notification_{}", uuid::Uuid::now_v7());
            let actions = serde_json::to_string(
                &intent
                    .actions
                    .iter()
                    .map(|action| action.as_str())
                    .collect::<Vec<_>>(),
            )
            .map_err(|error| format!("encode notification actions: {error}"))?;
            let inserted = transaction
                .execute(
                    "INSERT OR IGNORE INTO notification_deliveries(
                        delivery_id,worker_id,worker_version,invocation_id,deduplication_key,
                        title,body,thread_key,source_record_id,expires_at,actions_json,
                        on_open_complete,trace_id,created_at,updated_at,
                        source_worker_id,source_worker_version,producer_worker_id,
                        producer_worker_version,source_invocation_id,not_before
                     ) VALUES (
                        ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?14,
                        ?15,?16,?17,?18,?19,?20
                     )",
                    params![
                        delivery_id,
                        response_worker_id,
                        response_worker_version,
                        invocation_id,
                        intent.deduplication_key,
                        intent.title,
                        intent.body,
                        intent.thread_key,
                        intent.source_record_id,
                        intent.expires_at.to_rfc3339(),
                        actions,
                        i64::from(intent.on_open_complete),
                        trace_id,
                        created_at,
                        source_worker_id,
                        source_worker_version,
                        worker_id,
                        worker_version,
                        source_invocation_id,
                        intent.not_before.to_rfc3339(),
                    ],
                )
                .map_err(|error| format!("persist notification delivery: {error}"))?;
            if inserted == 0 {
                continue;
            }
            let mut statement = transaction
                .prepare(
                    "SELECT installation_id,authorization_status,token
                     FROM notification_installations
                     WHERE enabled=1 AND last_registered_at>=?1
                     ORDER BY installation_id",
                )
                .map_err(|error| format!("prepare notification fan-out: {error}"))?;
            let active_since = (Utc::now() - Duration::days(ACTIVE_INSTALLATION_DAYS)).to_rfc3339();
            let installations = statement
                .query_map([active_since], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                })
                .map_err(|error| format!("query notification fan-out: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode notification fan-out: {error}"))?;
            drop(statement);
            if installations.is_empty() {
                insert_notification_attention(
                    transaction,
                    &source_invocation_id,
                    response_worker_id,
                    &delivery_id,
                    None,
                    "no_active_installations",
                    created_at,
                )?;
            }
            for (installation_id, authorization_status, token) in installations {
                let ready = matches!(
                    authorization_status.as_str(),
                    "authorized" | "provisional" | "ephemeral"
                ) && token.as_deref().is_some_and(|token| !token.is_empty());
                let (state, error_code) = if ready {
                    ("queued", None)
                } else if authorization_status == "denied" {
                    ("blocked", Some("permission_denied"))
                } else {
                    ("blocked", Some("missing_device_token"))
                };
                let target_id = format!("notification_target_{}", uuid::Uuid::now_v7());
                transaction
                    .execute(
                        "INSERT OR IGNORE INTO notification_delivery_targets(
                            target_id,delivery_id,installation_id,state,next_attempt_at,
                            attempt_count,error_code,created_at,updated_at
                         ) VALUES (?1,?2,?3,?4,?5,0,?6,?5,?5)",
                        params![
                            target_id,
                            delivery_id,
                            installation_id,
                            state,
                            intent.not_before.to_rfc3339(),
                            error_code,
                        ],
                    )
                    .map_err(|error| format!("persist notification target: {error}"))?;
                if let Some(error_code) = error_code {
                    insert_notification_attention(
                        transaction,
                        &source_invocation_id,
                        response_worker_id,
                        &delivery_id,
                        Some(&target_id),
                        error_code,
                        created_at,
                    )?;
                }
            }
        }
        Ok(())
    }

    pub(in crate::domains::worker_kernel) fn acknowledge_notification_delivery(
        &self,
        request: NotificationAcknowledgeRequest,
    ) -> Result<Value, String> {
        validate_notification_identifier(&request.delivery_id, "deliveryId")?;
        validate_notification_identifier(&request.installation_id, "installationId")?;
        validate_notification_identifier(&request.client_mutation_id, "clientMutationId")?;
        let now = Utc::now().to_rfc3339();
        let occurred_at = request
            .occurred_at
            .as_deref()
            .map(|value| {
                chrono::DateTime::parse_from_rfc3339(value)
                    .map(|parsed| parsed.with_timezone(&Utc).to_rfc3339())
                    .map_err(|error| format!("occurredAt must be RFC3339: {error}"))
            })
            .transpose()?
            .unwrap_or_else(|| now.clone());
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification acknowledgement: {error}"))?;
        if let Some(existing) = transaction
            .query_row(
                "SELECT response_json FROM notification_responses WHERE client_mutation_id=?1",
                [&request.client_mutation_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("load notification mutation replay: {error}"))?
        {
            return serde_json::from_str(&existing)
                .map_err(|error| format!("decode notification mutation replay: {error}"));
        }
        let (
            worker_id,
            source_record_id,
            actions_json,
            on_open_complete,
            terminal_response,
            trace_id,
            not_before,
        ): (
            String,
            Option<String>,
            String,
            bool,
            Option<String>,
            String,
            String,
        ) = transaction
            .query_row(
                "SELECT worker_id,source_record_id,actions_json,on_open_complete,
                        terminal_response,trace_id,not_before
                 FROM notification_deliveries WHERE delivery_id=?1",
                [&request.delivery_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                    ))
                },
            )
            .map_err(|error| format!("load acknowledged notification: {error}"))?;
        let installation_exists: bool = transaction
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM notification_installations
                    WHERE installation_id=?1 AND enabled=1
                 )",
                [&request.installation_id],
                |row| row.get(0),
            )
            .map_err(|error| format!("authorize notification installation: {error}"))?;
        if !installation_exists {
            return Err("notification installation is not registered".to_owned());
        }
        let actions: Vec<String> = serde_json::from_str(&actions_json)
            .map_err(|error| format!("decode notification actions: {error}"))?;
        match request.acknowledgement {
            NotificationAcknowledgementKind::Opened if !on_open_complete => {
                return Err("notification does not support completion on open".to_owned());
            }
            NotificationAcknowledgementKind::Complete
                if !actions.iter().any(|action| action == "complete") =>
            {
                return Err("notification does not support complete".to_owned());
            }
            NotificationAcknowledgementKind::Snooze
                if !actions.iter().any(|action| action == "snooze") =>
            {
                return Err("notification does not support snooze".to_owned());
            }
            _ => {}
        }
        let accepted = if request.acknowledgement.is_terminal_response() {
            terminal_response.is_none()
        } else {
            true
        };
        if request.acknowledgement.is_terminal_response() && accepted {
            transaction
                .execute(
                    "UPDATE notification_deliveries
                     SET read_at=COALESCE(read_at,?2),read_reason=?3,
                         terminal_response=?3,terminal_responded_at=?2,updated_at=?4
                     WHERE delivery_id=?1 AND terminal_response IS NULL",
                    params![
                        request.delivery_id,
                        occurred_at,
                        request.acknowledgement.as_str(),
                        now,
                    ],
                )
                .map_err(|error| format!("record notification terminal response: {error}"))?;
            if not_before > now {
                transaction
                    .execute(
                        "UPDATE notification_delivery_targets
                         SET state='cancelled',error_code='resolved_before_delivery',
                             next_attempt_at=?2,updated_at=?2
                         WHERE delivery_id=?1 AND attempt_count=0
                           AND state IN ('queued','retry_wait','blocked')",
                        params![request.delivery_id, now],
                    )
                    .map_err(|error| {
                        format!("cancel deferred notification targets after response: {error}")
                    })?;
            }
        } else if matches!(
            request.acknowledgement,
            NotificationAcknowledgementKind::ClearUnread
        ) {
            transaction
                .execute(
                    "UPDATE notification_deliveries
                     SET read_at=COALESCE(read_at,?2),read_reason='clear_unread',updated_at=?3
                     WHERE delivery_id=?1",
                    params![request.delivery_id, occurred_at, now],
                )
                .map_err(|error| format!("clear notification unread state: {error}"))?;
        }
        let current_terminal: Option<String> = transaction
            .query_row(
                "SELECT terminal_response FROM notification_deliveries WHERE delivery_id=?1",
                [&request.delivery_id],
                |row| row.get(0),
            )
            .map_err(|error| format!("load current notification response: {error}"))?;
        let event_required = accepted && request.acknowledgement.is_terminal_response();
        let response = json!({
            "deliveryId":request.delivery_id,
            "clientMutationId":request.client_mutation_id,
            "acknowledgement":request.acknowledgement.as_str(),
            "accepted":accepted,
            "currentTerminalResponse":current_terminal,
            "read":true,
            "eventRequired":event_required,
            "workerId":worker_id,
            "sourceRecordId":source_record_id,
            "traceId":trace_id,
            "occurredAt":occurred_at,
        });
        transaction
            .execute(
                "INSERT INTO notification_responses(
                    response_id,client_mutation_id,delivery_id,installation_id,
                    acknowledgement,accepted,response_json,created_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    format!("notification_response_{}", uuid::Uuid::now_v7()),
                    request.client_mutation_id,
                    request.delivery_id,
                    request.installation_id,
                    request.acknowledgement.as_str(),
                    i64::from(accepted),
                    serde_json::to_string(&response)
                        .map_err(|error| format!("encode notification response: {error}"))?,
                    now,
                ],
            )
            .map_err(|error| format!("persist notification response: {error}"))?;
        enqueue_refreshes(&transaction, &now)?;
        transaction
            .commit()
            .map_err(|error| format!("commit notification acknowledgement: {error}"))?;
        Ok(response)
    }

    pub(in crate::domains::worker_kernel) fn claim_notification_targets(
        &self,
        limit: usize,
    ) -> Result<Vec<NotificationTargetDispatch>, String> {
        let now = Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification target claim: {error}"))?;
        transaction
            .execute(
                "UPDATE notification_delivery_targets
                 SET state='expired',error_code='expired',updated_at=?1
                 WHERE state IN ('queued','retry_wait','blocked','sending')
                   AND delivery_id IN (
                       SELECT delivery_id FROM notification_deliveries WHERE expires_at<=?1
                   )",
                [&now],
            )
            .map_err(|error| format!("expire notification targets: {error}"))?;
        let mut statement = transaction
            .prepare(
                "SELECT target.target_id,target.delivery_id,delivery.worker_id,
                        delivery.source_record_id,delivery.trace_id,target.installation_id,
                        installation.client_server_id,installation.token,
                        installation.topic,installation.environment,
                        delivery.title,delivery.body,delivery.thread_key,
                        delivery.actions_json,delivery.expires_at,
                        target.attempt_count + 1,
                        (SELECT COUNT(*) FROM notification_deliveries unread
                         WHERE unread.read_at IS NULL)
                 FROM notification_delivery_targets target
                 JOIN notification_deliveries delivery USING(delivery_id)
                 JOIN notification_installations installation USING(installation_id)
                 WHERE target.state IN ('queued','retry_wait','blocked')
                   AND target.next_attempt_at<=?1
                   AND delivery.expires_at>?1
                   AND installation.enabled=1
                   AND installation.last_registered_at>=?2
                   AND installation.authorization_status IN ('authorized','provisional','ephemeral')
                   AND installation.token IS NOT NULL
                 ORDER BY target.next_attempt_at,target.target_id LIMIT ?3",
            )
            .map_err(|error| format!("prepare notification target claim: {error}"))?;
        let active_since = (Utc::now() - Duration::days(ACTIVE_INSTALLATION_DAYS)).to_rfc3339();
        let targets = statement
            .query_map(
                params![now, active_since, i64::try_from(limit).unwrap_or(i64::MAX)],
                |row| {
                    let environment = decode_environment(row.get::<_, String>(9)?)?;
                    let actions_json: String = row.get(13)?;
                    let actions = serde_json::from_str(&actions_json).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            actions_json.len(),
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?;
                    Ok(NotificationTargetDispatch {
                        target_id: row.get(0)?,
                        delivery_id: row.get(1)?,
                        worker_id: row.get(2)?,
                        source_record_id: row.get(3)?,
                        trace_id: row.get(4)?,
                        installation_id: row.get(5)?,
                        client_server_id: row.get(6)?,
                        token: row.get(7)?,
                        topic: row.get(8)?,
                        environment,
                        title: row.get(10)?,
                        body: row.get(11)?,
                        thread_key: row.get(12)?,
                        actions,
                        expires_at: row.get(14)?,
                        attempt_number: row.get(15)?,
                        unread_count: row.get(16)?,
                    })
                },
            )
            .map_err(|error| format!("query notification target claim: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode notification target claim: {error}"))?;
        drop(statement);
        for target in &targets {
            transaction
                .execute(
                    "UPDATE notification_delivery_targets
                     SET state='sending',attempt_count=?2,updated_at=?3
                     WHERE target_id=?1 AND state IN ('queued','retry_wait','blocked')",
                    params![target.target_id, target.attempt_number, now],
                )
                .map_err(|error| format!("claim notification target: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit notification target claim: {error}"))?;
        Ok(targets)
    }

    pub(in crate::domains::worker_kernel) fn record_notification_target_outcome(
        &self,
        target: &NotificationTargetDispatch,
        transport_kind: &str,
        outcome: NotificationDispatchOutcome,
    ) -> Result<(), String> {
        let now = Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification target outcome: {error}"))?;
        let (state, apns_id, error_code, next_attempt_at, invalidate_token) = match &outcome {
            NotificationDispatchOutcome::Accepted { apns_id } => (
                "accepted_by_apns",
                Some(apns_id.as_str()),
                None,
                now.as_str(),
                false,
            ),
            NotificationDispatchOutcome::Retryable { code, retry_at } => (
                "retry_wait",
                None,
                Some(code.as_str()),
                retry_at.as_str(),
                false,
            ),
            NotificationDispatchOutcome::Permanent {
                code,
                invalidate_token,
            } => (
                "permanent_failure",
                None,
                Some(code.as_str()),
                now.as_str(),
                *invalidate_token,
            ),
            NotificationDispatchOutcome::Blocked { code, retry_at } => (
                "blocked",
                None,
                Some(code.as_str()),
                retry_at.as_str(),
                false,
            ),
        };
        let attempt_id = format!("notification_attempt_{}", uuid::Uuid::now_v7());
        let inserted = transaction
            .execute(
                "INSERT OR IGNORE INTO notification_delivery_attempts(
                    attempt_id,target_kind,target_id,attempt_number,state,apns_id,
                    error_code,started_at,completed_at,transport_kind,provider_request_id
                 ) VALUES (?1,'alert',?2,?3,?4,?5,?6,?7,?7,?8,?2)",
                params![
                    attempt_id,
                    target.target_id,
                    target.attempt_number,
                    state,
                    apns_id,
                    error_code,
                    now,
                    transport_kind,
                ],
            )
            .map_err(|error| format!("record notification attempt: {error}"))?;
        if inserted == 0 {
            transaction
                .commit()
                .map_err(|error| format!("commit duplicate notification outcome: {error}"))?;
            return Ok(());
        }
        transaction
            .execute(
                "UPDATE notification_delivery_targets
                 SET state=?2,apns_id=?3,error_code=?4,next_attempt_at=?5,
                     accepted_at=CASE WHEN ?2='accepted_by_apns' THEN ?6 ELSE accepted_at END,
                     updated_at=?6
                 WHERE target_id=?1 AND state='sending'",
                params![
                    target.target_id,
                    state,
                    apns_id,
                    error_code,
                    next_attempt_at,
                    now,
                ],
            )
            .map_err(|error| format!("update notification target outcome: {error}"))?;
        if matches!(state, "blocked" | "permanent_failure") {
            insert_notification_attention(
                &transaction,
                &format!("notification_transport_{}", target.target_id),
                &target.worker_id,
                &target.delivery_id,
                Some(&target.target_id),
                error_code.unwrap_or("notification_transport_failure"),
                &now,
            )?;
        }
        if invalidate_token {
            transaction
                .execute(
                    "UPDATE notification_installations
                     SET enabled=0,token=NULL,token_hash=NULL,invalidated_at=?2,updated_at=?2
                     WHERE installation_id=?1",
                    params![target.installation_id, now],
                )
                .map_err(|error| format!("invalidate APNs installation: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit notification target outcome: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn claim_notification_refreshes(
        &self,
        limit: usize,
    ) -> Result<Vec<NotificationRefreshDispatch>, String> {
        let now = Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification refresh claim: {error}"))?;
        let mut statement = transaction
            .prepare(
                "SELECT refresh.refresh_id,refresh.installation_id,
                        installation.client_server_id,installation.token,
                        installation.topic,installation.environment,
                        refresh.unread_count,refresh.attempt_count + 1
                 FROM notification_refreshes refresh
                 JOIN notification_installations installation USING(installation_id)
                 WHERE refresh.state IN ('queued','retry_wait')
                   AND refresh.next_attempt_at<=?1
                   AND installation.enabled=1
                   AND installation.last_registered_at>=?2
                   AND installation.authorization_status IN ('authorized','provisional','ephemeral')
                   AND installation.token IS NOT NULL
                 ORDER BY refresh.next_attempt_at,refresh.refresh_id LIMIT ?3",
            )
            .map_err(|error| format!("prepare notification refresh claim: {error}"))?;
        let active_since = (Utc::now() - Duration::days(ACTIVE_INSTALLATION_DAYS)).to_rfc3339();
        let refreshes = statement
            .query_map(
                params![now, active_since, i64::try_from(limit).unwrap_or(i64::MAX)],
                |row| {
                    Ok(NotificationRefreshDispatch {
                        refresh_id: row.get(0)?,
                        installation_id: row.get(1)?,
                        client_server_id: row.get(2)?,
                        token: row.get(3)?,
                        topic: row.get(4)?,
                        environment: decode_environment(row.get::<_, String>(5)?)?,
                        unread_count: row.get(6)?,
                        attempt_number: row.get(7)?,
                    })
                },
            )
            .map_err(|error| format!("query notification refresh claim: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode notification refresh claim: {error}"))?;
        drop(statement);
        for refresh in &refreshes {
            transaction
                .execute(
                    "UPDATE notification_refreshes
                     SET state='sending',attempt_count=?2,updated_at=?3
                     WHERE refresh_id=?1 AND state IN ('queued','retry_wait')",
                    params![refresh.refresh_id, refresh.attempt_number, now],
                )
                .map_err(|error| format!("claim notification refresh: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit notification refresh claim: {error}"))?;
        Ok(refreshes)
    }

    pub(in crate::domains::worker_kernel) fn record_notification_refresh_outcome(
        &self,
        refresh: &NotificationRefreshDispatch,
        transport_kind: &str,
        outcome: NotificationDispatchOutcome,
    ) -> Result<(), String> {
        let now = Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification refresh outcome: {error}"))?;
        let (state, apns_id, error_code, next_attempt_at, invalidate_token) = match &outcome {
            NotificationDispatchOutcome::Accepted { apns_id } => (
                "accepted_by_apns",
                Some(apns_id.as_str()),
                None,
                now.as_str(),
                false,
            ),
            NotificationDispatchOutcome::Retryable { code, retry_at } => (
                "retry_wait",
                None,
                Some(code.as_str()),
                retry_at.as_str(),
                false,
            ),
            NotificationDispatchOutcome::Permanent {
                code,
                invalidate_token,
            } => (
                "permanent_failure",
                None,
                Some(code.as_str()),
                now.as_str(),
                *invalidate_token,
            ),
            NotificationDispatchOutcome::Blocked { code, retry_at } => (
                "retry_wait",
                None,
                Some(code.as_str()),
                retry_at.as_str(),
                false,
            ),
        };
        let inserted = transaction
            .execute(
                "INSERT OR IGNORE INTO notification_delivery_attempts(
                    attempt_id,target_kind,target_id,attempt_number,state,apns_id,
                    error_code,started_at,completed_at,transport_kind,provider_request_id
                 ) VALUES (?1,'refresh',?2,?3,?4,?5,?6,?7,?7,?8,?2)",
                params![
                    format!("notification_attempt_{}", uuid::Uuid::now_v7()),
                    refresh.refresh_id,
                    refresh.attempt_number,
                    state,
                    apns_id,
                    error_code,
                    now,
                    transport_kind,
                ],
            )
            .map_err(|error| format!("record notification refresh attempt: {error}"))?;
        if inserted == 0 {
            transaction.commit().map_err(|error| {
                format!("commit duplicate notification refresh outcome: {error}")
            })?;
            return Ok(());
        }
        if state == "permanent_failure" {
            transaction
                .execute(
                    "DELETE FROM notification_refreshes
                     WHERE refresh_id=?1 AND state IN ('sending','sending_pending')",
                    [&refresh.refresh_id],
                )
                .map_err(|error| format!("finish notification refresh: {error}"))?;
        } else if state == "accepted_by_apns" {
            transaction
                .execute(
                    "DELETE FROM notification_refreshes
                     WHERE refresh_id=?1 AND state='sending'",
                    [&refresh.refresh_id],
                )
                .map_err(|error| format!("finish notification refresh: {error}"))?;
            transaction
                .execute(
                    "UPDATE notification_refreshes
                     SET state='queued',next_attempt_at=?2,error_code=NULL,updated_at=?2
                     WHERE refresh_id=?1 AND state='sending_pending'",
                    params![refresh.refresh_id, now],
                )
                .map_err(|error| format!("queue coalesced notification refresh: {error}"))?;
        } else {
            transaction
                .execute(
                    "UPDATE notification_refreshes
                     SET state=?2,next_attempt_at=?3,error_code=?4,updated_at=?5
                     WHERE refresh_id=?1 AND state IN ('sending','sending_pending')",
                    params![refresh.refresh_id, state, next_attempt_at, error_code, now],
                )
                .map_err(|error| format!("retry notification refresh: {error}"))?;
        }
        if invalidate_token {
            transaction
                .execute(
                    "UPDATE notification_installations
                     SET enabled=0,token=NULL,token_hash=NULL,invalidated_at=?2,updated_at=?2
                     WHERE installation_id=?1",
                    params![refresh.installation_id, now],
                )
                .map_err(|error| format!("invalidate refresh installation: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit notification refresh outcome: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn maintain_notification_history(
        &self,
    ) -> Result<(), String> {
        let cutoff = (Utc::now() - Duration::days(INBOX_RETENTION_DAYS)).to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification retention: {error}"))?;
        transaction
            .execute(
                "DELETE FROM notification_deliveries
                 WHERE created_at<?1 OR delivery_id NOT IN (
                    SELECT delivery_id FROM notification_deliveries
                    ORDER BY created_at DESC,delivery_id DESC LIMIT ?2
                 )",
                params![cutoff, i64::try_from(INBOX_RETENTION_COUNT).unwrap_or(500)],
            )
            .map_err(|error| format!("retain notification history: {error}"))?;
        transaction
            .execute(
                "DELETE FROM notification_delivery_attempts
                 WHERE target_kind='alert'
                   AND target_id NOT IN (
                       SELECT target_id FROM notification_delivery_targets
                   )",
                [],
            )
            .map_err(|error| format!("purge orphaned notification attempts: {error}"))?;
        transaction
            .execute(
                "DELETE FROM notification_delivery_attempts
                 WHERE target_kind='refresh' AND completed_at<?1",
                [&cutoff],
            )
            .map_err(|error| format!("retain notification refresh attempts: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit notification retention: {error}"))
    }
}

pub(super) fn enqueue_refreshes(transaction: &Transaction<'_>, now: &str) -> Result<(), String> {
    let unread_count: u64 = transaction
        .query_row(
            "SELECT COUNT(*) FROM notification_deliveries WHERE read_at IS NULL",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("count unread notifications for refresh: {error}"))?;
    transaction
        .execute(
            "INSERT INTO notification_refreshes(
                refresh_id,installation_id,unread_count,state,next_attempt_at,
                attempt_count,created_at,updated_at
             )
             SELECT 'notification_refresh_' || lower(hex(randomblob(16))),
                    installation_id,?1,'queued',?2,0,?2,?2
             FROM notification_installations
             WHERE enabled=1
               AND authorization_status IN ('authorized','provisional','ephemeral')
               AND token IS NOT NULL
             ON CONFLICT(installation_id) DO UPDATE SET
                unread_count=excluded.unread_count,
                state=CASE
                    WHEN notification_refreshes.state IN ('sending','sending_pending')
                    THEN 'sending_pending'
                    ELSE 'queued'
                END,
                next_attempt_at=CASE
                    WHEN notification_refreshes.state IN ('sending','sending_pending')
                    THEN notification_refreshes.next_attempt_at
                    ELSE excluded.next_attempt_at
                END,
                attempt_count=CASE
                    WHEN notification_refreshes.state IN ('sending','sending_pending')
                    THEN notification_refreshes.attempt_count
                    ELSE 0
                END,
                error_code=CASE
                    WHEN notification_refreshes.state IN ('sending','sending_pending')
                    THEN notification_refreshes.error_code
                    ELSE NULL
                END,
                updated_at=excluded.updated_at",
            params![unread_count, now],
        )
        .map_err(|error| format!("enqueue notification refreshes: {error}"))?;
    Ok(())
}
