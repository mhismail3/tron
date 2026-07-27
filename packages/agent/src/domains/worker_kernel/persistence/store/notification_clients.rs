//! Authenticated installation registration and synchronized notification reads.

use chrono::Utc;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::notification_validation::{
    normalize_device_token, validate_notification_identifier, validate_topic_environment,
};
use super::*;
use crate::domains::worker_kernel::notifications::{
    NotificationDeliveriesRequest, NotificationDeliveryStatusRequest,
    NotificationDeviceDisableRequest, NotificationDeviceUpsertRequest,
};

impl WorkerStore {
    pub(in crate::domains::worker_kernel) fn notification_device_upsert(
        &self,
        request: NotificationDeviceUpsertRequest,
    ) -> Result<Value, String> {
        validate_notification_identifier(&request.installation_id, "installationId")?;
        validate_notification_identifier(&request.client_server_id, "clientServerId")?;
        validate_topic_environment(&request.topic, request.environment)?;
        let token = normalize_device_token(request.token.as_deref())?;
        if request.authorization_status.permits_delivery() && token.is_none() {
            return Err(
                "authorized notification registration requires the current APNs token".to_owned(),
            );
        }
        let now = Utc::now().to_rfc3339();
        let token_hash = token
            .as_deref()
            .map(|value| hex::encode(Sha256::digest(value.as_bytes())));
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin notification registration: {error}"))?;
        transaction
            .execute(
                "INSERT INTO notification_installations(
                    installation_id,client_server_id,topic,environment,
                    authorization_status,token,token_hash,enabled,last_registered_at,
                    invalidated_at,created_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,1,?8,NULL,?8,?8)
                 ON CONFLICT(installation_id) DO UPDATE SET
                    client_server_id=excluded.client_server_id,
                    topic=excluded.topic,
                    environment=excluded.environment,
                    authorization_status=excluded.authorization_status,
                    token=excluded.token,
                    token_hash=excluded.token_hash,
                    enabled=1,
                    last_registered_at=excluded.last_registered_at,
                    invalidated_at=NULL,
                    updated_at=excluded.updated_at",
                params![
                    request.installation_id,
                    request.client_server_id,
                    request.topic,
                    request.environment.as_str(),
                    request.authorization_status.as_str(),
                    token,
                    token_hash,
                    now,
                ],
            )
            .map_err(|error| format!("upsert notification installation: {error}"))?;
        let ready = request.authorization_status.permits_delivery();
        if ready {
            transaction
                .execute(
                    "UPDATE notification_delivery_targets
                     SET state='queued',error_code=NULL,next_attempt_at=?2,updated_at=?2
                     WHERE installation_id=?1 AND state='blocked'
                       AND error_code IN ('permission_denied','missing_device_token','invalid_device_token')
                       AND delivery_id IN (
                           SELECT delivery_id FROM notification_deliveries
                           WHERE expires_at>?2
                       )",
                    params![request.installation_id, now],
                )
                .map_err(|error| format!("requeue notification targets: {error}"))?;
            transaction
                .execute(
                    "INSERT OR IGNORE INTO notification_delivery_targets(
                        target_id,delivery_id,installation_id,state,next_attempt_at,
                        attempt_count,created_at,updated_at
                     )
                     SELECT 'notification_target_' || lower(hex(randomblob(16))),
                            delivery_id,?1,'queued',?2,0,?2,?2
                     FROM notification_deliveries
                     WHERE expires_at>?2",
                    params![request.installation_id, now],
                )
                .map_err(|error| format!("fan outstanding deliveries to installation: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit notification registration: {error}"))?;
        Ok(json!({
            "installationId":request.installation_id,
            "authorizationStatus":request.authorization_status.as_str(),
            "environment":request.environment.as_str(),
            "topic":request.topic,
            "enabled":true,
            "ready":ready,
            "registeredAt":now,
        }))
    }

    pub(in crate::domains::worker_kernel) fn notification_device_disable(
        &self,
        request: NotificationDeviceDisableRequest,
    ) -> Result<Value, String> {
        validate_notification_identifier(&request.installation_id, "installationId")?;
        let now = Utc::now().to_rfc3339();
        let connection = self.connection()?;
        let changed = connection
            .execute(
                "UPDATE notification_installations
                 SET enabled=0,token=NULL,token_hash=NULL,updated_at=?2
                 WHERE installation_id=?1",
                params![request.installation_id, now],
            )
            .map_err(|error| format!("disable notification installation: {error}"))?;
        Ok(json!({
            "installationId":request.installation_id,
            "enabled":false,
            "changed":changed > 0,
        }))
    }

    pub(in crate::domains::worker_kernel) fn notification_deliveries(
        &self,
        request: NotificationDeliveriesRequest,
    ) -> Result<Value, String> {
        let limit = request.limit.clamp(1, 200);
        let connection = self.connection()?;
        let unread_count: u64 = connection
            .query_row(
                "SELECT COUNT(*) FROM notification_deliveries WHERE read_at IS NULL",
                [],
                |row| row.get(0),
            )
            .map_err(|error| format!("count unread notifications: {error}"))?;
        let cursor_created_at = request
            .cursor
            .as_deref()
            .map(|cursor| {
                validate_notification_identifier(cursor, "cursor")?;
                connection
                    .query_row(
                        "SELECT created_at FROM notification_deliveries WHERE delivery_id=?1",
                        [cursor],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()
                    .map_err(|error| format!("resolve notification cursor: {error}"))?
                    .ok_or_else(|| "notification cursor does not exist".to_owned())
            })
            .transpose()?;
        let mut statement = connection
            .prepare(
                "SELECT delivery_id,worker_id,worker_version,source_record_id,title,body,
                        thread_key,expires_at,actions_json,on_open_complete,read_at,
                        terminal_response,terminal_responded_at,created_at,updated_at,
                        source_worker_id,source_worker_version,producer_worker_id,
                        producer_worker_version,source_invocation_id,not_before,
                        (
                            SELECT json_object(
                                'total',COUNT(*),
                                'queued',COALESCE(SUM(target.state='queued'),0),
                                'retryWait',COALESCE(SUM(target.state='retry_wait'),0),
                                'acceptedByAPNs',COALESCE(SUM(target.state='accepted_by_apns'),0),
                                'blocked',COALESCE(SUM(target.state='blocked'),0),
                                'permanentFailure',COALESCE(SUM(target.state='permanent_failure'),0),
                                'expired',COALESCE(SUM(target.state='expired'),0),
                                'cancelled',COALESCE(SUM(target.state='cancelled'),0)
                            )
                            FROM notification_delivery_targets target
                            WHERE target.delivery_id=notification_deliveries.delivery_id
                        )
                 FROM notification_deliveries
                 WHERE (?1=0 OR read_at IS NULL)
                   AND (?2 IS NULL OR created_at<?2 OR (created_at=?2 AND delivery_id<?3))
                 ORDER BY created_at DESC,delivery_id DESC LIMIT ?4",
            )
            .map_err(|error| format!("prepare notification inbox: {error}"))?;
        let mut deliveries = statement
            .query_map(
                params![
                    i64::from(request.unread_only),
                    cursor_created_at,
                    request.cursor,
                    i64::try_from(limit + 1).unwrap_or(201)
                ],
                notification_delivery_row,
            )
            .map_err(|error| format!("query notification inbox: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode notification inbox: {error}"))?;
        let next_cursor = if deliveries.len() > limit {
            deliveries.truncate(limit);
            deliveries
                .last()
                .and_then(|value| value.get("deliveryId"))
                .cloned()
        } else {
            None
        };
        Ok(json!({
            "deliveries":deliveries,
            "unreadCount":unread_count,
            "nextCursor":next_cursor,
        }))
    }

    pub(in crate::domains::worker_kernel) fn notification_delivery_status(
        &self,
        request: NotificationDeliveryStatusRequest,
    ) -> Result<Value, String> {
        validate_notification_identifier(&request.delivery_id, "deliveryId")?;
        let connection = self.connection()?;
        let delivery = connection
            .query_row(
                "SELECT delivery_id,worker_id,worker_version,source_record_id,title,body,
                        thread_key,expires_at,actions_json,on_open_complete,read_at,
                        terminal_response,terminal_responded_at,created_at,updated_at,
                        source_worker_id,source_worker_version,producer_worker_id,
                        producer_worker_version,source_invocation_id,not_before,
                        (
                            SELECT json_object(
                                'total',COUNT(*),
                                'queued',COALESCE(SUM(target.state='queued'),0),
                                'retryWait',COALESCE(SUM(target.state='retry_wait'),0),
                                'acceptedByAPNs',COALESCE(SUM(target.state='accepted_by_apns'),0),
                                'blocked',COALESCE(SUM(target.state='blocked'),0),
                                'permanentFailure',COALESCE(SUM(target.state='permanent_failure'),0),
                                'expired',COALESCE(SUM(target.state='expired'),0),
                                'cancelled',COALESCE(SUM(target.state='cancelled'),0)
                            )
                            FROM notification_delivery_targets target
                            WHERE target.delivery_id=notification_deliveries.delivery_id
                        )
                 FROM notification_deliveries WHERE delivery_id=?1",
                [&request.delivery_id],
                notification_delivery_row,
            )
            .optional()
            .map_err(|error| format!("load notification delivery: {error}"))?
            .ok_or_else(|| "notification delivery does not exist".to_owned())?;
        let mut statement = connection
            .prepare(
                "SELECT target_id,installation_id,state,attempt_count,apns_id,error_code,
                        accepted_at,updated_at
                 FROM notification_delivery_targets
                 WHERE delivery_id=?1 ORDER BY installation_id",
            )
            .map_err(|error| format!("prepare notification target evidence: {error}"))?;
        let targets = statement
            .query_map([&request.delivery_id], |row| {
                Ok(json!({
                    "targetId":row.get::<_, String>(0)?,
                    "installationId":row.get::<_, String>(1)?,
                    "state":row.get::<_, String>(2)?,
                    "attemptCount":row.get::<_, u32>(3)?,
                    "apnsId":row.get::<_, Option<String>>(4)?,
                    "errorCode":row.get::<_, Option<String>>(5)?,
                    "acceptedAt":row.get::<_, Option<String>>(6)?,
                    "updatedAt":row.get::<_, String>(7)?,
                }))
            })
            .map_err(|error| format!("query notification target evidence: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode notification target evidence: {error}"))?;
        let mut statement = connection
            .prepare(
                "SELECT attempt_id,target_id,attempt_number,state,apns_id,error_code,
                        started_at,completed_at,transport_kind,provider_request_id
                 FROM notification_delivery_attempts
                 WHERE target_kind='alert' AND target_id IN (
                    SELECT target_id FROM notification_delivery_targets WHERE delivery_id=?1
                 )
                 ORDER BY started_at,attempt_id",
            )
            .map_err(|error| format!("prepare notification attempt evidence: {error}"))?;
        let attempts = statement
            .query_map([&request.delivery_id], |row| {
                Ok(json!({
                    "attemptId":row.get::<_, String>(0)?,
                    "targetId":row.get::<_, String>(1)?,
                    "attemptNumber":row.get::<_, u32>(2)?,
                    "state":row.get::<_, String>(3)?,
                    "apnsId":row.get::<_, Option<String>>(4)?,
                    "errorCode":row.get::<_, Option<String>>(5)?,
                    "startedAt":row.get::<_, String>(6)?,
                    "completedAt":row.get::<_, String>(7)?,
                    "transportKind":row.get::<_, Option<String>>(8)?,
                    "providerRequestId":row.get::<_, Option<String>>(9)?,
                }))
            })
            .map_err(|error| format!("query notification attempt evidence: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode notification attempt evidence: {error}"))?;
        Ok(json!({"delivery":delivery,"targets":targets,"attempts":attempts}))
    }
}

fn notification_delivery_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let actions_json: String = row.get(8)?;
    let actions: Value = serde_json::from_str(&actions_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            actions_json.len(),
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })?;
    let target_summary_json: String = row.get(21)?;
    let target_summary: Value = serde_json::from_str(&target_summary_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            target_summary_json.len(),
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })?;
    Ok(json!({
        "deliveryId":row.get::<_, String>(0)?,
        "workerId":row.get::<_, String>(1)?,
        "workerVersion":row.get::<_, String>(2)?,
        "sourceRecordId":row.get::<_, Option<String>>(3)?,
        "title":row.get::<_, String>(4)?,
        "body":row.get::<_, String>(5)?,
        "threadKey":row.get::<_, Option<String>>(6)?,
        "expiresAt":row.get::<_, String>(7)?,
        "actions":actions,
        "onOpen":if row.get::<_, bool>(9)? { Value::String("complete".to_owned()) } else { Value::Null },
        "readAt":row.get::<_, Option<String>>(10)?,
        "terminalResponse":row.get::<_, Option<String>>(11)?,
        "terminalRespondedAt":row.get::<_, Option<String>>(12)?,
        "createdAt":row.get::<_, String>(13)?,
        "updatedAt":row.get::<_, String>(14)?,
        "sourceWorkerId":row.get::<_, Option<String>>(15)?,
        "sourceWorkerVersion":row.get::<_, Option<String>>(16)?,
        "producerWorkerId":row.get::<_, Option<String>>(17)?,
        "producerWorkerVersion":row.get::<_, Option<String>>(18)?,
        "sourceInvocationId":row.get::<_, Option<String>>(19)?,
        "notBefore":row.get::<_, Option<String>>(20)?,
        "targetSummary":target_summary,
    }))
}
