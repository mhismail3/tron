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

    pub fn purge(&self, worker_id: &str) -> Result<bool, String> {
        validate_identifier(worker_id, "workerId")?;
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        if !summary.retired {
            return Err("a worker must be retired before permanent purge".to_owned());
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| error.to_string())?;
        let worker_dir = self.root.join(worker_id);
        let purging_root = self.root.join(".purging");
        fs::create_dir_all(&purging_root).map_err(|error| error.to_string())?;
        let staged = purging_root.join(format!("{worker_id}-{}", uuid::Uuid::now_v7()));
        fs::rename(&worker_dir, &staged)
            .map_err(|error| format!("stage worker bundle for purge: {error}"))?;
        let result = (|| -> Result<usize, String> {
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
                return Err(error);
            }
        };
        if let Err(error) = fs::remove_dir_all(&staged) {
            return Err(format!(
                "worker was purged from the active index but its staged bundle could not be erased at {}: {error}",
                staged.display()
            ));
        }
        Ok(changed > 0)
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
