//! Durable schedule, event-cursor, and authenticated-webhook trigger state.

use super::*;

impl WorkerStore {
    /// Project upcoming recurring triggers and already-admitted deferred runs
    /// through one bounded, chronological operator view. This reads the same
    /// durable cursors used by dispatch; it does not maintain a second queue.
    pub fn scheduled_work_page(&self, limit: u32, offset: u32) -> Result<Vec<Value>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "WITH scheduled(
                    scheduled_id,worker_id,worker_name,kind,trigger_id,
                    invocation_id,scheduled_at,every_seconds,trigger_kind
                 ) AS (
                    SELECT 'schedule:' || t.worker_id || ':' || t.trigger_id,
                           t.worker_id,w.name,'recurring',t.trigger_id,NULL,
                           t.next_run_at,
                           CAST(json_extract(t.config_json,'$.everySeconds') AS INTEGER),
                           'schedule'
                    FROM worker_triggers t
                    JOIN workers w ON w.worker_id=t.worker_id
                    WHERE t.kind='schedule' AND t.enabled=1
                      AND w.enabled=1 AND w.retired=0
                      AND t.next_run_at IS NOT NULL
                    UNION ALL
                    SELECT 'invocation:' || invocation.invocation_id,
                           invocation.worker_id,w.name,'deferred',NULL,
                           invocation.invocation_id,invocation.not_before,NULL,
                           invocation.trigger_kind
                    FROM worker_invocations invocation
                    JOIN workers w ON w.worker_id=invocation.worker_id
                    WHERE invocation.status='queued'
                      AND invocation.not_before IS NOT NULL
                      AND julianday(invocation.not_before)>julianday('now')
                      AND w.enabled=1 AND w.retired=0
                 )
                 SELECT scheduled_id,worker_id,worker_name,kind,trigger_id,
                        invocation_id,scheduled_at,every_seconds,trigger_kind
                 FROM scheduled
                 ORDER BY julianday(scheduled_at),scheduled_id
                 LIMIT ?1 OFFSET ?2",
            )
            .map_err(|error| format!("prepare scheduled worker projection: {error}"))?;
        statement
            .query_map(params![limit.min(101), offset], |row| {
                Ok(json!({
                    "scheduledId": row.get::<_, String>(0)?,
                    "workerId": row.get::<_, String>(1)?,
                    "workerName": row.get::<_, String>(2)?,
                    "kind": row.get::<_, String>(3)?,
                    "triggerId": row.get::<_, Option<String>>(4)?,
                    "invocationId": row.get::<_, Option<String>>(5)?,
                    "scheduledAt": row.get::<_, String>(6)?,
                    "everySeconds": row.get::<_, Option<u64>>(7)?,
                    "triggerKind": row.get::<_, String>(8)?,
                }))
            })
            .map_err(|error| format!("query scheduled worker projection: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode scheduled worker projection: {error}"))
    }

    pub fn due_schedules(&self) -> Result<Vec<(String, WorkerTrigger, String)>, String> {
        let now = chrono::Utc::now().to_rfc3339();
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT t.worker_id,t.config_json,t.next_run_at FROM worker_triggers t
                 JOIN workers w ON w.worker_id=t.worker_id
                 WHERE t.kind='schedule' AND t.enabled=1 AND w.enabled=1 AND w.retired=0
                   AND t.next_run_at<=?1",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([now], |row| {
                let config: String = row.get(1)?;
                let trigger = serde_json::from_str(&config).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?;
                Ok((row.get(0)?, trigger, row.get(2)?))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn advance_schedule(
        &self,
        worker_id: &str,
        trigger_id: &str,
        every_seconds: u64,
    ) -> Result<(), String> {
        let connection = self.connection()?;
        let prior = connection
            .query_row(
                "SELECT next_run_at FROM worker_triggers WHERE worker_id=?1 AND trigger_id=?2",
                params![worker_id, trigger_id],
                |row| row.get::<_, String>(0),
            )
            .map_err(|error| format!("read worker schedule cursor: {error}"))?;
        let interval = chrono::Duration::seconds(
            i64::try_from(every_seconds).map_err(|_| "schedule interval is too large")?,
        );
        let mut next = chrono::DateTime::parse_from_rfc3339(&prior)
            .map_err(|error| format!("decode worker schedule cursor: {error}"))?
            .with_timezone(&chrono::Utc)
            + interval;
        while next <= chrono::Utc::now() {
            next += interval;
        }
        connection
            .execute(
                "UPDATE worker_triggers SET next_run_at=?3 WHERE worker_id=?1 AND trigger_id=?2",
                params![worker_id, trigger_id, next.to_rfc3339()],
            )
            .map_err(|error| format!("advance worker schedule: {error}"))?;
        Ok(())
    }

    pub fn event_triggers(&self) -> Result<Vec<(String, WorkerTrigger, i64)>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT t.worker_id,t.config_json,t.stream_cursor FROM worker_triggers t
                 JOIN workers w ON w.worker_id=t.worker_id
                 WHERE t.kind='engine_event' AND t.enabled=1 AND w.enabled=1 AND w.retired=0",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([], |row| {
                let config: String = row.get(1)?;
                let trigger = serde_json::from_str(&config).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?;
                Ok((row.get(0)?, trigger, row.get(2)?))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())
    }

    pub fn update_stream_cursor(
        &self,
        worker_id: &str,
        trigger_id: &str,
        cursor: i64,
    ) -> Result<(), String> {
        self.connection()?
            .execute(
                "UPDATE worker_triggers SET stream_cursor=?3 WHERE worker_id=?1 AND trigger_id=?2",
                params![worker_id, trigger_id, cursor],
            )
            .map_err(|error| format!("advance worker event cursor: {error}"))?;
        Ok(())
    }

    pub fn verify_webhook(
        &self,
        worker_id: &str,
        trigger_id: &str,
        token: &str,
    ) -> Result<Value, String> {
        let row = self
            .connection()?
            .query_row(
                "SELECT t.config_json,t.token_hash FROM worker_triggers t
                 JOIN workers w ON w.worker_id=t.worker_id
                 WHERE t.worker_id=?1 AND t.trigger_id=?2 AND t.kind='webhook'
                   AND t.enabled=1 AND w.enabled=1 AND w.retired=0",
                params![worker_id, trigger_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|error| format!("load worker webhook: {error}"))?
            .ok_or_else(|| "worker webhook was not found or is disabled".to_owned())?;
        if hash_secret(token) != row.1 {
            return Err("worker webhook token is invalid".to_owned());
        }
        let trigger: WorkerTrigger =
            serde_json::from_str(&row.0).map_err(|error| error.to_string())?;
        match trigger {
            WorkerTrigger::Webhook { input, .. } => Ok(input),
            _ => Err("stored trigger is not a webhook".to_owned()),
        }
    }

    pub fn rotate_webhook(
        &self,
        worker_id: &str,
        trigger_id: &str,
    ) -> Result<WebhookCredential, String> {
        let token = generate_token();
        let changed = self
            .connection()?
            .execute(
                "UPDATE worker_triggers SET token_hash=?3,enabled=1
                 WHERE worker_id=?1 AND trigger_id=?2 AND kind='webhook'",
                params![worker_id, trigger_id, hash_secret(&token)],
            )
            .map_err(|error| format!("rotate worker webhook token: {error}"))?;
        if changed == 0 {
            return Err("worker webhook was not found".to_owned());
        }
        Ok(WebhookCredential {
            trigger_id: trigger_id.to_owned(),
            path: format!("/engine/webhooks/workers/{worker_id}/{trigger_id}"),
            token,
        })
    }
}
