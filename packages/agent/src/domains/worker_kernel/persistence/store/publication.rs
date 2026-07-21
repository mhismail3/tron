//! Candidate preparation, immutable version publication, canonical loading,
//! and profile inventory queries.

use super::*;

impl WorkerStore {
    pub fn prepare(
        &self,
        mut bundle: WorkerBundle,
        predecessor: Option<&str>,
    ) -> Result<PreparedWorker, String> {
        validate_bundle(&bundle)?;
        let explicit_worker_id = bundle.worker_id.clone();
        let explicit_worker_exists = explicit_worker_id
            .as_deref()
            .map(|worker_id| self.read_state(worker_id))
            .transpose()?
            .flatten()
            .is_some();
        let overlap_threshold = if explicit_worker_id.is_some() {
            0.90
        } else {
            0.60
        };
        let worker_id = if let Some(predecessor) = predecessor {
            if self.read_state(predecessor)?.is_none() {
                return Err(format!("predecessor worker '{predecessor}' was not found"));
            }
            predecessor.to_owned()
        } else if explicit_worker_exists {
            explicit_worker_id.expect("checked explicit worker identity")
        } else if let Some(overlap) = self.closest_overlap(&bundle, overlap_threshold)? {
            overlap
        } else {
            explicit_worker_id.unwrap_or_else(|| slug(&bundle.name))
        };
        validate_identifier(&worker_id, "workerId")?;
        bundle.worker_id = Some(worker_id.clone());
        let requested_tool = self
            .summary(&worker_id)?
            .map(|existing| existing.tool_name)
            .or_else(|| bundle.tool_name.clone())
            .unwrap_or_else(|| format!("worker_{}", slug(&bundle.name)));
        let tool_name = normalize_tool_name(&requested_tool)?;
        bundle.tool_name = Some(tool_name.clone());

        let staging_dir =
            self.root
                .join(".staging")
                .join(format!("{}-{}", worker_id, uuid::Uuid::now_v7()));
        fs::create_dir_all(staging_dir.join("files"))
            .map_err(|error| format!("create worker staging directory: {error}"))?;
        fs::write(
            staging_dir.join("manifest.json"),
            serde_json::to_vec_pretty(&bundle)
                .map_err(|error| format!("encode worker manifest: {error}"))?,
        )
        .map_err(|error| format!("write worker manifest: {error}"))?;
        for (relative, contents) in &bundle.files {
            let relative = safe_relative_path(relative)?;
            let target = staging_dir.join("files").join(relative);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .map_err(|error| format!("create worker file directory: {error}"))?;
            }
            fs::write(&target, contents)
                .map_err(|error| format!("write worker file {}: {error}", target.display()))?;
        }
        fs::write(
            staging_dir.join("dependencies.lock.json"),
            serde_json::to_vec_pretty(&bundle.dependencies)
                .map_err(|error| format!("encode dependency lock: {error}"))?,
        )
        .map_err(|error| format!("write dependency lock: {error}"))?;
        fs::write(
            staging_dir.join("provenance.json"),
            serde_json::to_vec_pretty(&bundle.provenance)
                .map_err(|error| format!("encode provenance: {error}"))?,
        )
        .map_err(|error| format!("write provenance: {error}"))?;
        let version = tree_version(&staging_dir)?;

        Ok(PreparedWorker {
            prior_state: self.read_state(&worker_id)?,
            worker_id,
            version,
            tool_name,
            bundle,
            staging_dir,
        })
    }

    pub fn abandon(&self, prepared: &PreparedWorker) {
        let _ = fs::remove_dir_all(&prepared.staging_dir);
    }

    /// Rewrite the staged canonical metadata after dependency acquisition has
    /// filled every optional input checksum. Publication must never preserve an
    /// unresolved dependency even though callers may omit expected digests.
    pub fn seal_resolved_dependencies(&self, prepared: &PreparedWorker) -> Result<(), String> {
        for dependency in &prepared.bundle.dependencies {
            if dependency.checksum.is_none() {
                return Err(format!(
                    "dependency '{}' was not resolved to a checksum",
                    dependency.name
                ));
            }
        }
        fs::write(
            prepared.staging_dir.join("manifest.json"),
            serde_json::to_vec_pretty(&prepared.bundle)
                .map_err(|error| format!("encode resolved worker manifest: {error}"))?,
        )
        .map_err(|error| format!("write resolved worker manifest: {error}"))?;
        fs::write(
            prepared.staging_dir.join("dependencies.lock.json"),
            serde_json::to_vec_pretty(&prepared.bundle.dependencies)
                .map_err(|error| format!("encode resolved dependency lock: {error}"))?,
        )
        .map_err(|error| format!("write resolved dependency lock: {error}"))
    }

    /// Seal the exact staged tree after dependency acquisition and smoke tests.
    /// The resulting full SHA-256 is the immutable content-version directory.
    pub fn finalize(&self, prepared: &mut PreparedWorker) -> Result<(), String> {
        prepared.version = tree_version(&prepared.staging_dir)?;
        fs::write(
            prepared.staging_dir.join("content.sha256"),
            format!("{}\n", prepared.version),
        )
        .map_err(|error| format!("write worker content hash: {error}"))
    }

    pub fn publish(&self, prepared: PreparedWorker) -> Result<UpsertOutcome, String> {
        self.publish_with_pointer_writer(prepared, write_json_atomic)
    }

    pub(super) fn publish_with_pointer_writer(
        &self,
        prepared: PreparedWorker,
        write_pointer: impl FnOnce(&Path, &WorkerState) -> Result<(), String>,
    ) -> Result<UpsertOutcome, String> {
        validate_content_version(&prepared.version)?;
        let sealed = fs::read_to_string(prepared.staging_dir.join("content.sha256"))
            .map_err(|error| format!("read finalized worker content hash: {error}"))?;
        let actual = tree_version(&prepared.staging_dir)?;
        if sealed.trim() != prepared.version || actual != prepared.version {
            return Err(format!(
                "worker candidate was not finalized consistently: expected {}, recorded {}, resolved {}",
                prepared.version,
                sealed.trim(),
                actual
            ));
        }
        let worker_dir = self.root.join(&prepared.worker_id);
        let versions_dir = worker_dir.join("versions");
        fs::create_dir_all(&versions_dir)
            .map_err(|error| format!("create worker versions directory: {error}"))?;
        let version_dir = versions_dir.join(&prepared.version);
        let created_version = !version_dir.exists();
        if created_version {
            fs::rename(&prepared.staging_dir, &version_dir)
                .map_err(|error| format!("publish worker version: {error}"))?;
        } else {
            let _ = fs::remove_dir_all(&prepared.staging_dir);
        }
        let cleanup_target = if created_version && prepared.prior_state.is_none() {
            Some(worker_dir.clone())
        } else {
            created_version.then(|| version_dir.clone())
        };
        let mut version_cleanup = RemoveDirectoryOnDrop(cleanup_target);

        let now = chrono::Utc::now().to_rfc3339();
        let state = WorkerState {
            worker_id: prepared.worker_id.clone(),
            active_version: prepared.version.clone(),
            enabled: true,
            retired: false,
            health: "healthy".to_owned(),
            failure: None,
            updated_at: now.clone(),
        };
        let state_path = worker_dir.join("worker.json");

        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker publish transaction: {error}"))?;
        let created = transaction
            .query_row(
                "SELECT 1 FROM workers WHERE worker_id=?1",
                [&prepared.worker_id],
                |_| Ok(()),
            )
            .optional()
            .map_err(|error| format!("inspect prior worker: {error}"))?
            .is_none();
        transaction
            .execute(
                "INSERT INTO workers(worker_id,name,description,tool_name,runner_kind,active_version,enabled,retired,health,created_at,updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,1,0,'healthy',?7,?7)
                 ON CONFLICT(worker_id) DO UPDATE SET
                    name=excluded.name, description=excluded.description,
                    tool_name=excluded.tool_name, runner_kind=excluded.runner_kind,
                    active_version=excluded.active_version, enabled=1, retired=0,
                    health='healthy', updated_at=excluded.updated_at",
                params![
                    prepared.worker_id,
                    prepared.bundle.name,
                    prepared.bundle.description,
                    prepared.tool_name,
                    prepared.bundle.runner.kind(),
                    prepared.version,
                    now,
                ],
            )
            .map_err(|error| format!("upsert worker index: {error}"))?;
        transaction
            .execute(
                "INSERT OR IGNORE INTO worker_versions(worker_id,version,manifest_json,content_hash,created_at)
                 VALUES (?1,?2,?3,?2,?4)",
                params![
                    prepared.worker_id,
                    prepared.version,
                    serde_json::to_string(&prepared.bundle).map_err(|error| error.to_string())?,
                    now,
                ],
            )
            .map_err(|error| format!("insert worker version: {error}"))?;
        transaction
            .execute(
                "INSERT INTO worker_routes(worker_id,worker_version,tool_name,description,routing_json,enabled,updated_at)
                 VALUES (?1,?2,?3,?4,?5,1,?6)
                 ON CONFLICT(worker_id) DO UPDATE SET
                    worker_version=excluded.worker_version,tool_name=excluded.tool_name,
                    description=excluded.description,routing_json=excluded.routing_json,
                    enabled=1,updated_at=excluded.updated_at",
                params![
                    prepared.worker_id,
                    prepared.version,
                    prepared.tool_name,
                    prepared.bundle.description,
                    serde_json::to_string(&prepared.bundle.routing)
                        .map_err(|error| error.to_string())?,
                    now,
                ],
            )
            .map_err(|error| format!("activate worker route: {error}"))?;
        let mut webhooks = Vec::new();
        replace_active_triggers(
            &transaction,
            &prepared.worker_id,
            &prepared.bundle.triggers,
            true,
            &mut webhooks,
        )?;
        insert_audit(
            &transaction,
            &prepared.worker_id,
            if created { "created" } else { "updated" },
            &json!({
                "version": prepared.version,
                "runner": prepared.bundle.runner.kind(),
                "contentHash": prepared.version,
                "provenance": prepared.bundle.provenance,
            }),
        )?;
        insert_health(
            &transaction,
            &prepared.worker_id,
            &prepared.version,
            "healthy",
            "activation",
            &json!({"verification":"verification.json"}),
        )?;
        // INVARIANT: the filesystem pointer is the publication linearization
        // point. Commit the rebuildable indexes first so a crash can leave the
        // database ahead of the canonical pointer, never the pointer ahead of
        // its durable indexes. Startup reconstruction resolves the former back
        // to the prior pointer.
        transaction
            .commit()
            .map_err(|error| format!("commit worker publish: {error}"))?;
        if let Err(error) = write_pointer(&state_path, &state) {
            let cleanup = version_cleanup.cleanup_now();
            let recovery = super::super::migration::rebuild_indexes(&self.root, &self.database);
            let cleanup_evidence = cleanup
                .err()
                .map(|cleanup_error| format!("; candidate cleanup also failed: {cleanup_error}"))
                .unwrap_or_default();
            return Err(match recovery {
                Ok(()) => format!(
                    "publish canonical worker pointer: {error}; restored indexes from filesystem state{cleanup_evidence}"
                ),
                Err(recovery_error) => format!(
                    "publish canonical worker pointer: {error}; index recovery also failed: {recovery_error}{cleanup_evidence}"
                ),
            });
        }
        version_cleanup.disarm();

        let worker = self
            .summary(&prepared.worker_id)?
            .ok_or_else(|| "published worker is missing from index".to_owned())?;
        Ok(UpsertOutcome {
            worker,
            version: prepared.version,
            created,
            replaced_worker_id: prepared.prior_state.map(|state| state.worker_id),
            webhooks,
        })
    }

    pub fn list(&self, include_retired: bool) -> Result<Vec<WorkerSummary>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT w.worker_id,w.name,w.description,w.tool_name,w.runner_kind,w.active_version,
                        w.enabled,w.retired,w.health,w.updated_at,
                        (SELECT COUNT(*) FROM worker_triggers t WHERE t.worker_id=w.worker_id AND t.enabled=1)
                 FROM workers w WHERE (?1=1 OR w.retired=0) ORDER BY w.updated_at DESC",
            )
            .map_err(|error| format!("prepare worker list: {error}"))?;
        let rows = statement
            .query_map([i64::from(include_retired)], row_summary)
            .map_err(|error| format!("query worker list: {error}"))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker list: {error}"))
    }

    pub fn summary(&self, worker_id: &str) -> Result<Option<WorkerSummary>, String> {
        self.connection()?
            .query_row(
                "SELECT w.worker_id,w.name,w.description,w.tool_name,w.runner_kind,w.active_version,
                        w.enabled,w.retired,w.health,w.updated_at,
                        (SELECT COUNT(*) FROM worker_triggers t WHERE t.worker_id=w.worker_id AND t.enabled=1)
                 FROM workers w WHERE w.worker_id=?1",
                [worker_id],
                row_summary,
            )
            .optional()
            .map_err(|error| format!("load worker summary: {error}"))
    }

    pub fn inspect(&self, worker_id: &str) -> Result<Value, String> {
        let active = self.load_active(worker_id)?;
        let connection = self.connection()?;
        let versions = {
            let mut statement = connection
                .prepare(
                    "SELECT version,content_hash,created_at FROM worker_versions
                     WHERE worker_id=?1 ORDER BY created_at DESC",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| {
                    Ok(json!({
                        "version": row.get::<_, String>(0)?,
                        "contentHash": row.get::<_, String>(1)?,
                        "createdAt": row.get::<_, String>(2)?,
                    }))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let triggers = {
            let mut statement = connection
                .prepare(
                    "SELECT trigger_id,kind,config_json,token_hash,next_run_at,stream_cursor,enabled
                     FROM worker_triggers WHERE worker_id=?1 ORDER BY trigger_id",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| {
                    let config: String = row.get(2)?;
                    Ok(json!({
                        "triggerId": row.get::<_, String>(0)?,
                        "kind": row.get::<_, String>(1)?,
                        "configuration": serde_json::from_str::<Value>(&config).unwrap_or(Value::Null),
                        "tokenConfigured": row.get::<_, Option<String>>(3)?.is_some(),
                        "nextRunAt": row.get::<_, Option<String>>(4)?,
                        "streamCursor": row.get::<_, i64>(5)?,
                        "enabled": row.get::<_, i64>(6)? != 0,
                    }))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        let audit = self.audit(Some(worker_id), 100)?;
        let route = connection
            .query_row(
                "SELECT worker_version,tool_name,description,routing_json,enabled,updated_at
                 FROM worker_routes WHERE worker_id=?1",
                [worker_id],
                |row| {
                    let routing: String = row.get(3)?;
                    Ok(json!({
                        "workerVersion":row.get::<_, String>(0)?,
                        "toolName":row.get::<_, String>(1)?,
                        "description":row.get::<_, String>(2)?,
                        "routing":serde_json::from_str::<Value>(&routing).unwrap_or(Value::Null),
                        "enabled":row.get::<_, i64>(4)? != 0,
                        "updatedAt":row.get::<_, String>(5)?,
                    }))
                },
            )
            .optional()
            .map_err(|error| format!("load worker route: {error}"))?;
        let health_history = {
            let mut statement = connection
                .prepare(
                    "SELECT health_id,worker_version,status,source,details_json,recorded_at
                     FROM worker_health WHERE worker_id=?1 ORDER BY recorded_at DESC LIMIT 100",
                )
                .map_err(|error| error.to_string())?;
            statement
                .query_map([worker_id], |row| {
                    let details: String = row.get(4)?;
                    Ok(json!({
                        "healthId":row.get::<_, String>(0)?,
                        "workerVersion":row.get::<_, String>(1)?,
                        "status":row.get::<_, String>(2)?,
                        "source":row.get::<_, String>(3)?,
                        "details":serde_json::from_str::<Value>(&details).unwrap_or(Value::Null),
                        "recordedAt":row.get::<_, String>(5)?,
                    }))
                })
                .map_err(|error| error.to_string())?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| error.to_string())?
        };
        Ok(json!({
            "worker": active.summary,
            "bundle": active.bundle,
            "route": route,
            "versions": versions,
            "triggers": triggers,
            "healthHistory": health_history,
            "audit": audit,
            "versionDirectory": active.version_dir,
        }))
    }

    pub fn load_active(&self, worker_id: &str) -> Result<ActiveWorker, String> {
        let state = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let (bundle, version_dir) =
            self.load_verified_bundle(worker_id, &state.active_version, "active")?;
        let summary = self.summary_from_state_bundle(&state, &bundle)?;
        Ok(ActiveWorker {
            summary,
            bundle,
            version_dir,
        })
    }

    /// Load the active contract from the rebuildable index for pre-dispatch
    /// schema validation. Execution always follows with `load_version`, which
    /// verifies the canonical filesystem tree before running any code.
    pub fn load_indexed_active(&self, worker_id: &str) -> Result<ActiveWorker, String> {
        validate_identifier(worker_id, "workerId")?;
        let summary = self
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        validate_content_version(&summary.active_version)?;
        let manifest: String = self
            .connection()?
            .query_row(
                "SELECT manifest_json FROM worker_versions WHERE worker_id=?1 AND version=?2",
                params![worker_id, summary.active_version],
                |row| row.get(0),
            )
            .map_err(|error| format!("load indexed worker manifest: {error}"))?;
        let bundle: WorkerBundle = serde_json::from_str(&manifest)
            .map_err(|error| format!("decode indexed worker manifest: {error}"))?;
        validate_bundle(&bundle)?;
        let version_dir = self
            .root
            .join(worker_id)
            .join("versions")
            .join(&summary.active_version);
        Ok(ActiveWorker {
            summary,
            bundle,
            version_dir,
        })
    }

    pub fn load_version(&self, worker_id: &str, version: &str) -> Result<ActiveWorker, String> {
        let mut state = self
            .read_state(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        let (bundle, version_dir) = self.load_verified_bundle(worker_id, version, "worker")?;
        state.active_version = version.to_owned();
        let summary = self.summary_from_state_bundle(&state, &bundle)?;
        Ok(ActiveWorker {
            summary,
            bundle,
            version_dir,
        })
    }

    pub(super) fn load_verified_bundle(
        &self,
        worker_id: &str,
        version: &str,
        context: &str,
    ) -> Result<(WorkerBundle, PathBuf), String> {
        validate_identifier(worker_id, "workerId")?;
        validate_content_version(version)?;
        let version_dir = self.root.join(worker_id).join("versions").join(version);
        let recorded = fs::read_to_string(version_dir.join("content.sha256"))
            .map_err(|error| format!("read {context} worker content hash: {error}"))?;
        if recorded.trim() != version {
            return Err(format!(
                "{context} worker version '{worker_id}@{version}' has a mismatched content.sha256"
            ));
        }
        let actual = tree_version(&version_dir)?;
        if actual != version {
            return Err(format!(
                "{context} worker version '{worker_id}@{version}' failed integrity verification: content resolves to {actual}"
            ));
        }
        let bundle: WorkerBundle = serde_json::from_slice(
            &fs::read(version_dir.join("manifest.json"))
                .map_err(|error| format!("read {context} worker manifest: {error}"))?,
        )
        .map_err(|error| format!("decode {context} worker manifest: {error}"))?;
        validate_bundle(&bundle)?;
        Ok((bundle, version_dir))
    }

    pub(super) fn summary_from_state_bundle(
        &self,
        state: &WorkerState,
        bundle: &WorkerBundle,
    ) -> Result<WorkerSummary, String> {
        let tool_name = bundle
            .tool_name
            .clone()
            .ok_or_else(|| format!("worker '{}' has no toolName", state.worker_id))?;
        let trigger_count = self
            .connection()?
            .query_row(
                "SELECT COUNT(*) FROM worker_triggers WHERE worker_id=?1 AND enabled=1",
                [&state.worker_id],
                |row| row.get::<_, u64>(0),
            )
            .unwrap_or(0);
        Ok(WorkerSummary {
            worker_id: state.worker_id.clone(),
            name: bundle.name.clone(),
            description: bundle.description.clone(),
            tool_name,
            runner_kind: bundle.runner.kind().to_owned(),
            active_version: state.active_version.clone(),
            enabled: state.enabled,
            retired: state.retired,
            health: state.health.clone(),
            trigger_count,
            updated_at: state.updated_at.clone(),
        })
    }
}
