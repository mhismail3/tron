//! Enable, failure, rollback, retirement, purge, and engine stop mutations.

use super::*;

impl WorkerStore {
    pub fn set_enabled(&self, worker_id: &str, enabled: bool) -> Result<WorkerSummary, String> {
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        if enabled && prior.retired {
            return Err("a retired worker must be rolled back before it can be enabled".to_owned());
        }
        let mut state = prior.clone();
        state.enabled = enabled;
        state.health = if enabled { "healthy" } else { "disabled" }.to_owned();
        state.failure = None;
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET enabled=?2,health=?3,updated_at=?4 WHERE worker_id=?1",
                    params![
                        worker_id,
                        i64::from(enabled),
                        if enabled { "healthy" } else { "disabled" },
                        state.updated_at,
                    ],
                )
                .map_err(|error| format!("update worker enablement: {error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            insert_audit(
                &transaction,
                worker_id,
                if enabled { "enabled" } else { "disabled" },
                &json!({"activeVersion":state.active_version}),
            )?;
            transaction
                .execute(
                    "UPDATE worker_routes SET enabled=?2,updated_at=?3 WHERE worker_id=?1",
                    params![worker_id, i64::from(enabled), state.updated_at],
                )
                .map_err(|error| format!("update worker route enablement: {error}"))?;
            transaction
                .execute(
                    "UPDATE worker_triggers
                     SET enabled=CASE
                        WHEN ?2=1 AND (kind!='webhook' OR token_hash IS NOT NULL) THEN 1
                        ELSE 0
                     END
                     WHERE worker_id=?1",
                    params![worker_id, i64::from(enabled)],
                )
                .map_err(|error| format!("update worker trigger enablement: {error}"))?;
            if !enabled {
                let _ = super::invocations::cancel_worker_invocations_in_tx(
                    &transaction,
                    worker_id,
                    "worker invocation cancelled because the worker was disabled",
                )?;
            }
            insert_health(
                &transaction,
                worker_id,
                &state.active_version,
                if enabled { "healthy" } else { "disabled" },
                "lifecycle",
                &json!({"action":if enabled { "enabled" } else { "disabled" }}),
            )?;
            transaction.commit().map_err(|error| error.to_string())
        })();
        if let Err(error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(error);
        }
        self.summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))
    }

    pub fn mark_failed(&self, worker_id: &str, source: &str, error: &str) -> Result<(), String> {
        validate_runtime_identifier(source, "worker failure source", 64)?;
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let mut state = prior.clone();
        state.enabled = false;
        state.health = "failed".to_owned();
        state.failure = Some(error.to_owned());
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|db_error| db_error.to_string())?;
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET enabled=0,health='failed',updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|db_error| format!("mark worker failed after {error}: {db_error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            insert_audit(
                &transaction,
                worker_id,
                "failed",
                &json!({"error":error,"source":source,"activeVersion":state.active_version}),
            )?;
            transaction
                .execute(
                    "UPDATE worker_routes SET enabled=0,updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|db_error| format!("disable failed worker route: {db_error}"))?;
            transaction
                .execute(
                    "UPDATE worker_triggers SET enabled=0 WHERE worker_id=?1",
                    [worker_id],
                )
                .map_err(|db_error| format!("disable failed worker triggers: {db_error}"))?;
            let _ = super::invocations::cancel_worker_invocations_in_tx(
                &transaction,
                worker_id,
                "worker invocation cancelled because the worker entered a failed state",
            )?;
            insert_health(
                &transaction,
                worker_id,
                &state.active_version,
                "failed",
                source,
                &json!({"error":error}),
            )?;
            transaction
                .commit()
                .map_err(|db_error| db_error.to_string())
        })();
        if let Err(db_error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(db_error);
        }
        Ok(())
    }

    pub fn record_stopped(&self, worker_id: &str, version: &str) -> Result<(), String> {
        validate_identifier(worker_id, "workerId")?;
        validate_content_version(version)?;
        insert_audit(
            &self.connection()?,
            worker_id,
            "stopped",
            &json!({"activeVersion":version,"enabledStatePreserved":true}),
        )
    }

    pub fn rollback(
        &self,
        worker_id: &str,
        version: &str,
    ) -> Result<(WorkerSummary, Vec<WebhookCredential>), String> {
        let bundle = self.load_version(worker_id, version)?.bundle;
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let mut state = prior.clone();
        state.active_version = version.to_owned();
        state.enabled = true;
        state.retired = false;
        state.health = "healthy".to_owned();
        state.failure = None;
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let mut credentials = Vec::new();
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET name=?2,description=?3,tool_name=?4,runner_kind=?5,
                        active_version=?6,enabled=1,retired=0,health='healthy',updated_at=?7
                     WHERE worker_id=?1",
                    params![
                        worker_id,
                        bundle.name,
                        bundle.description,
                        bundle.tool_name,
                        bundle.runner.kind(),
                        version,
                        state.updated_at,
                    ],
                )
                .map_err(|error| format!("rollback worker: {error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            replace_active_triggers(
                &transaction,
                worker_id,
                &bundle.triggers,
                true,
                &mut credentials,
            )?;
            transaction
                .execute(
                    "INSERT INTO worker_routes(worker_id,worker_version,tool_name,description,routing_json,enabled,updated_at)
                     VALUES (?1,?2,?3,?4,?5,1,?6)
                     ON CONFLICT(worker_id) DO UPDATE SET worker_version=excluded.worker_version,
                        tool_name=excluded.tool_name,description=excluded.description,
                        routing_json=excluded.routing_json,enabled=1,updated_at=excluded.updated_at",
                    params![
                        worker_id,
                        version,
                        bundle.tool_name,
                        bundle.description,
                        serde_json::to_string(&bundle.routing).map_err(|error| error.to_string())?,
                        state.updated_at,
                    ],
                )
                .map_err(|error| format!("restore worker route during rollback: {error}"))?;
            insert_audit(
                &transaction,
                worker_id,
                "rolled_back",
                &json!({
                    "fromVersion":prior.active_version,
                    "toVersion":version,
                    "newWebhookCredentialsRequireInspection":credentials.iter().map(|item| &item.trigger_id).collect::<Vec<_>>(),
                }),
            )?;
            insert_health(
                &transaction,
                worker_id,
                version,
                "healthy",
                "rollback",
                &json!({"fromVersion":prior.active_version}),
            )?;
            transaction.commit().map_err(|error| error.to_string())
        })();
        if let Err(error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(error);
        }
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        Ok((summary, credentials))
    }

    pub fn retire(&self, worker_id: &str) -> Result<WorkerSummary, String> {
        let prior = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let mut state = prior.clone();
        state.enabled = false;
        state.retired = true;
        state.health = "retired".to_owned();
        state.failure = None;
        state.updated_at = chrono::Utc::now().to_rfc3339();
        let state_path = self.root.join(worker_id).join("worker.json");
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        write_json_atomic(&state_path, &state)?;
        let result = (|| -> Result<(), String> {
            let changed = transaction
                .execute(
                    "UPDATE workers SET enabled=0,retired=1,health='retired',updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|error| format!("retire worker: {error}"))?;
            if changed == 0 {
                return Err(format!("worker '{worker_id}' was not found"));
            }
            transaction
                .execute(
                    "UPDATE worker_triggers SET enabled=0 WHERE worker_id=?1",
                    [worker_id],
                )
                .map_err(|error| format!("retire worker triggers: {error}"))?;
            transaction
                .execute(
                    "UPDATE worker_routes SET enabled=0,updated_at=?2 WHERE worker_id=?1",
                    params![worker_id, state.updated_at],
                )
                .map_err(|error| format!("retire worker route: {error}"))?;
            let _ = super::invocations::cancel_worker_invocations_in_tx(
                &transaction,
                worker_id,
                "worker invocation cancelled because the worker was retired",
            )?;
            insert_audit(
                &transaction,
                worker_id,
                "retired",
                &json!({"activeVersion":state.active_version}),
            )?;
            insert_health(
                &transaction,
                worker_id,
                &state.active_version,
                "retired",
                "lifecycle",
                &json!({"action":"retired"}),
            )?;
            transaction.commit().map_err(|error| error.to_string())
        })();
        if let Err(error) = result {
            let _ = write_json_atomic(&state_path, &prior);
            return Err(error);
        }
        self.summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))
    }

    pub fn purge(
        &self,
        worker_id: &str,
        known_secrets: &[String],
    ) -> Result<super::super::super::types::PurgeOutcome, String> {
        validate_identifier(worker_id, "workerId")?;
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        if !summary.retired {
            return Err("a worker must be retired before permanent purge".to_owned());
        }
        let worker_dir = self.root.join(worker_id);
        let worker_state_dir = self.state_root.join(worker_id);
        let operational_export = self.purge_operational_export(worker_id)?;
        let archive = super::super::snapshot::create_worker_purge_archive(
            &self.home,
            worker_id,
            &worker_dir,
            &worker_state_dir,
            &operational_export,
            known_secrets,
        )?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|error| error.to_string())?;
        let has_nonterminal = transaction
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM worker_invocations
                    WHERE worker_id=?1 AND status IN ('queued','running')
                 )",
                [worker_id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("check worker purge nonterminal runs: {error}"))?;
        if has_nonterminal {
            return Err(
                "worker cannot be purged while invocations are queued or running".to_owned(),
            );
        }
        let has_pending_outbox = transaction
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM agent_delivery_outbox
                    WHERE worker_id=?1 AND disposition='pending'
                 )",
                [worker_id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("check worker purge agent outbox: {error}"))?;
        if has_pending_outbox {
            return Err(
                "worker cannot be purged while agent-delivery outbox rows are pending".to_owned(),
            );
        }
        let purging_root = self.root.join(".purging");
        fs::create_dir_all(&purging_root).map_err(|error| error.to_string())?;
        let staged = purging_root.join(format!("{worker_id}-{}", uuid::Uuid::now_v7()));
        fs::rename(&worker_dir, &staged)
            .map_err(|error| format!("stage worker bundle for purge: {error}"))?;
        let state_purging_root = self.state_root.join(".purging");
        fs::create_dir_all(&state_purging_root).map_err(|error| error.to_string())?;
        let staged_state = state_purging_root.join(format!("{worker_id}-{}", uuid::Uuid::now_v7()));
        let state_was_present = worker_state_dir.exists();
        if state_was_present {
            if let Err(error) = fs::rename(&worker_state_dir, &staged_state) {
                let _ = fs::rename(&staged, &worker_dir);
                return Err(format!("stage worker state for purge: {error}"));
            }
        }
        let result = (|| -> Result<usize, String> {
            let invocation_ids = {
                let mut statement = transaction
                    .prepare(
                        "SELECT invocation_id FROM worker_invocations
                         WHERE worker_id=?1 ORDER BY invocation_id",
                    )
                    .map_err(|error| format!("prepare worker result purge: {error}"))?;
                statement
                    .query_map([worker_id], |row| row.get::<_, String>(0))
                    .map_err(|error| format!("query worker result purge: {error}"))?
                    .collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(|error| format!("decode worker result purge: {error}"))?
            };
            Self::delete_result_owners(&transaction, &invocation_ids)?;
            transaction
                .execute(
                    "DELETE FROM notification_delivery_attempts
                     WHERE target_kind='alert' AND target_id IN (
                        SELECT target.target_id
                        FROM notification_delivery_targets target
                        JOIN notification_deliveries delivery USING(delivery_id)
                        WHERE delivery.worker_id=?1
                     )",
                    [worker_id],
                )
                .map_err(|error| format!("purge worker notification attempts: {error}"))?;
            transaction
                .execute("DELETE FROM worker_inbox WHERE worker_id=?1", [worker_id])
                .map_err(|error| format!("purge worker inbox: {error}"))?;
            transaction
                .execute(
                    "DELETE FROM worker_invocations WHERE worker_id=?1",
                    [worker_id],
                )
                .map_err(|error| format!("purge worker runs: {error}"))?;
            transaction
                .execute(
                    "DELETE FROM worker_causal_traces
                     WHERE trace_id NOT IN (SELECT DISTINCT trace_id FROM worker_trace_deliveries)",
                    [],
                )
                .map_err(|error| format!("purge orphaned worker traces: {error}"))?;
            let changed = transaction
                .execute("DELETE FROM workers WHERE worker_id=?1", [worker_id])
                .map_err(|error| format!("purge worker index: {error}"))?;
            insert_audit(
                &transaction,
                worker_id,
                "purged",
                &json!({"lastActiveVersion":summary.active_version}),
            )?;
            transaction.commit().map_err(|error| error.to_string())?;
            Ok(changed)
        })();
        let changed = match result {
            Ok(changed) => changed,
            Err(error) => {
                let _ = fs::rename(&staged, &worker_dir);
                if state_was_present {
                    let _ = fs::rename(&staged_state, &worker_state_dir);
                }
                return Err(error);
            }
        };
        if let Err(error) = fs::remove_dir_all(&staged) {
            return Err(format!(
                "worker was purged from the active index but its staged bundle could not be erased at {}: {error}",
                staged.display()
            ));
        }
        if state_was_present {
            fs::remove_dir_all(&staged_state).map_err(|error| {
                format!(
                    "worker was purged but its staged state could not be erased at {}: {error}",
                    staged_state.display()
                )
            })?;
        }
        Ok(super::super::super::types::PurgeOutcome {
            worker_id: worker_id.to_owned(),
            purged: changed > 0,
            archive_path: archive.path.display().to_string(),
            archive_sha256: archive.sha256,
        })
    }

    pub(super) fn purge_operational_export(&self, worker_id: &str) -> Result<Value, String> {
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let connection = self.connection()?;
        let runs = {
            let mut statement = connection
                .prepare(&format!(
                    "{} WHERE worker_id=?1 ORDER BY created_at",
                    invocation_select_base()
                ))
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| row_invocation(&connection, row))
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let attempts = runs
            .iter()
            .map(|run| {
                self.attempts(&run.invocation_id)
                    .map(|attempts| (run.invocation_id.clone(), attempts))
            })
            .collect::<Result<std::collections::BTreeMap<_, _>, _>>()?;
        let run_events = runs
            .iter()
            .map(|run| {
                self.run_events(std::slice::from_ref(&run.invocation_id))
                    .map(|events| (run.invocation_id.clone(), events))
            })
            .collect::<Result<std::collections::BTreeMap<_, _>, _>>()?;
        let traces = runs
            .iter()
            .map(|run| run.trace_id.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|trace_id| self.trace(&trace_id).map(|trace| (trace_id, trace)))
            .collect::<Result<std::collections::BTreeMap<_, _>, _>>()?;
        let inbox = query_json_rows(
            &connection,
            "SELECT inbox_id,invocation_id,severity,result_json,context_attached,created_at
             FROM worker_inbox WHERE worker_id=?1 ORDER BY created_at",
            worker_id,
            |row| {
                let result: String = row.get(3)?;
                Ok(json!({
                    "inboxId":row.get::<_, String>(0)?,
                    "invocationId":row.get::<_, String>(1)?,
                    "severity":row.get::<_, String>(2)?,
                    "result":serde_json::from_str::<Value>(&result).unwrap_or(Value::Null),
                    "contextAttached":row.get::<_, i64>(4)? != 0,
                    "createdAt":row.get::<_, String>(5)?,
                }))
            },
        )?;
        let audit = query_json_rows(
            &connection,
            "SELECT audit_id,action,details_json,created_at FROM worker_audit
             WHERE worker_id=?1 ORDER BY created_at",
            worker_id,
            |row| {
                let details: String = row.get(2)?;
                Ok(json!({
                    "auditId":row.get::<_, String>(0)?,
                    "action":row.get::<_, String>(1)?,
                    "details":serde_json::from_str::<Value>(&details).unwrap_or(Value::Null),
                    "createdAt":row.get::<_, String>(3)?,
                }))
            },
        )?;
        let health = query_json_rows(
            &connection,
            "SELECT health_id,worker_version,status,source,details_json,recorded_at
             FROM worker_health WHERE worker_id=?1 ORDER BY recorded_at",
            worker_id,
            |row| {
                let details: String = row.get(4)?;
                Ok(json!({
                    "healthId":row.get::<_, String>(0)?,
                    "workerVersion":row.get::<_, String>(1)?,
                    "status":row.get::<_, String>(2)?,
                    "source":row.get::<_, String>(3)?,
                    "details":serde_json::from_str::<Value>(&details).unwrap_or(Value::Null),
                    "recordedAt":row.get::<_, String>(5)?,
                }))
            },
        )?;
        let notification_deliveries = query_json_rows(
            &connection,
            "SELECT delivery_id,invocation_id,deduplication_key,title,body,thread_key,
                    source_record_id,expires_at,actions_json,on_open_complete,read_at,
                    read_reason,terminal_response,terminal_responded_at,trace_id,created_at,updated_at
             FROM notification_deliveries WHERE worker_id=?1 ORDER BY created_at",
            worker_id,
            |row| {
                let actions: String = row.get(8)?;
                Ok(json!({
                    "deliveryId":row.get::<_, String>(0)?,
                    "invocationId":row.get::<_, String>(1)?,
                    "deduplicationKey":row.get::<_, String>(2)?,
                    "title":row.get::<_, String>(3)?,
                    "body":row.get::<_, String>(4)?,
                    "threadKey":row.get::<_, Option<String>>(5)?,
                    "sourceRecordId":row.get::<_, Option<String>>(6)?,
                    "expiresAt":row.get::<_, String>(7)?,
                    "actions":serde_json::from_str::<Value>(&actions).unwrap_or(Value::Null),
                    "onOpenComplete":row.get::<_, bool>(9)?,
                    "readAt":row.get::<_, Option<String>>(10)?,
                    "readReason":row.get::<_, Option<String>>(11)?,
                    "terminalResponse":row.get::<_, Option<String>>(12)?,
                    "terminalRespondedAt":row.get::<_, Option<String>>(13)?,
                    "traceId":row.get::<_, String>(14)?,
                    "createdAt":row.get::<_, String>(15)?,
                    "updatedAt":row.get::<_, String>(16)?,
                }))
            },
        )?;
        let notification_targets = query_json_rows(
            &connection,
            "SELECT target.target_id,target.delivery_id,target.installation_id,target.state,
                    target.attempt_count,target.apns_id,target.error_code,target.accepted_at,
                    target.created_at,target.updated_at
             FROM notification_delivery_targets target
             JOIN notification_deliveries delivery USING(delivery_id)
             WHERE delivery.worker_id=?1 ORDER BY target.created_at",
            worker_id,
            |row| {
                Ok(json!({
                    "targetId":row.get::<_, String>(0)?,
                    "deliveryId":row.get::<_, String>(1)?,
                    "installationId":row.get::<_, String>(2)?,
                    "state":row.get::<_, String>(3)?,
                    "attemptCount":row.get::<_, u32>(4)?,
                    "apnsId":row.get::<_, Option<String>>(5)?,
                    "errorCode":row.get::<_, Option<String>>(6)?,
                    "acceptedAt":row.get::<_, Option<String>>(7)?,
                    "createdAt":row.get::<_, String>(8)?,
                    "updatedAt":row.get::<_, String>(9)?,
                }))
            },
        )?;
        let notification_attempts = query_json_rows(
            &connection,
            "SELECT attempt.attempt_id,attempt.target_id,attempt.attempt_number,
                    attempt.state,attempt.apns_id,attempt.error_code,
                    attempt.started_at,attempt.completed_at
             FROM notification_delivery_attempts attempt
             JOIN notification_delivery_targets target ON target.target_id=attempt.target_id
             JOIN notification_deliveries delivery USING(delivery_id)
             WHERE attempt.target_kind='alert' AND delivery.worker_id=?1
             ORDER BY attempt.started_at",
            worker_id,
            |row| {
                Ok(json!({
                    "attemptId":row.get::<_, String>(0)?,
                    "targetId":row.get::<_, String>(1)?,
                    "attemptNumber":row.get::<_, u32>(2)?,
                    "state":row.get::<_, String>(3)?,
                    "apnsId":row.get::<_, Option<String>>(4)?,
                    "errorCode":row.get::<_, Option<String>>(5)?,
                    "startedAt":row.get::<_, String>(6)?,
                    "completedAt":row.get::<_, String>(7)?,
                }))
            },
        )?;
        let notification_responses = query_json_rows(
            &connection,
            "SELECT response.response_id,response.client_mutation_id,response.delivery_id,
                    response.installation_id,response.acknowledgement,response.accepted,
                    response.response_json,response.created_at
             FROM notification_responses response
             JOIN notification_deliveries delivery USING(delivery_id)
             WHERE delivery.worker_id=?1 ORDER BY response.created_at",
            worker_id,
            |row| {
                let response: String = row.get(6)?;
                Ok(json!({
                    "responseId":row.get::<_, String>(0)?,
                    "clientMutationId":row.get::<_, String>(1)?,
                    "deliveryId":row.get::<_, String>(2)?,
                    "installationId":row.get::<_, String>(3)?,
                    "acknowledgement":row.get::<_, String>(4)?,
                    "accepted":row.get::<_, bool>(5)?,
                    "response":serde_json::from_str::<Value>(&response).unwrap_or(Value::Null),
                    "createdAt":row.get::<_, String>(7)?,
                }))
            },
        )?;
        Ok(json!({
            "format":"tron.worker_purge_records.v1",
            "exportedAt":chrono::Utc::now().to_rfc3339(),
            "worker":summary,
            "runs":runs,
            "attempts":attempts,
            "runEvents":run_events,
            "traces":traces,
            "inbox":inbox,
            "audit":audit,
            "health":health,
            "notificationDeliveries":notification_deliveries,
            "notificationTargets":notification_targets,
            "notificationAttempts":notification_attempts,
            "notificationResponses":notification_responses,
        }))
    }

    pub fn set_stop_all(&self, stopped: bool) -> Result<(), String> {
        self.connection()?
            .execute(
                "UPDATE worker_runtime_settings SET value=?1 WHERE key='stop_all'",
                [if stopped { "true" } else { "false" }],
            )
            .map_err(|error| format!("update worker stop-all: {error}"))?;
        Ok(())
    }

    pub fn stop_all(&self) -> Result<bool, String> {
        self.connection()?
            .query_row(
                "SELECT value FROM worker_runtime_settings WHERE key='stop_all'",
                [],
                |row| row.get::<_, String>(0),
            )
            .map(|value| value == "true")
            .map_err(|error| format!("read worker stop-all: {error}"))
    }
}

fn query_json_rows(
    connection: &Connection,
    sql: &str,
    worker_id: &str,
    mut map: impl FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<Value>,
) -> Result<Vec<Value>, String> {
    let mut statement = connection.prepare(sql).map_err(|error| error.to_string())?;
    statement
        .query_map([worker_id], |row| map(row))
        .map_err(|error| error.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| error.to_string())
}
