//! Candidate acquisition, verification, atomic publication, and activation
//! failure isolation.

use super::*;

impl WorkerRuntime {
    pub async fn upsert(
        self: &Arc<Self>,
        bundle: WorkerBundle,
        predecessor: Option<&str>,
    ) -> Result<UpsertOutcome, String> {
        self.reject_secret_material_in_bundle(&bundle)?;
        let mut prepared = self.store.prepare(bundle, predecessor)?;
        if let Err(error) = self.prepare_dependencies_and_test(&mut prepared).await {
            self.store.abandon(&prepared);
            return Err(error);
        }
        self.store.finalize(&mut prepared)?;
        let outcome = self.store.publish(prepared)?;
        self.stop_obsolete_residents(&outcome.worker.worker_id, &outcome.version)
            .await;
        self.reset_worker_stop(&outcome.worker.worker_id);
        if let Err(error) = self.register_dynamic_tool(&outcome.worker.worker_id).await {
            let reason = self
                .handle_tool_activation_failure(
                    &outcome.worker.worker_id,
                    &outcome.version,
                    "activation",
                    &error,
                )
                .await;
            return Err(reason);
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action": "activated",
                "worker": outcome.worker,
                "version": outcome.version,
            }),
            None,
        )
        .await;
        Ok(outcome)
    }

    pub(super) async fn handle_tool_activation_failure(
        &self,
        worker_id: &str,
        version: &str,
        phase: &str,
        error: &str,
    ) -> String {
        self.handle_worker_runtime_failure(
            worker_id,
            version,
            phase,
            &format!("dynamic tool {phase} failed: {error}"),
        )
        .await
    }

    pub(super) async fn handle_worker_runtime_failure(
        &self,
        worker_id: &str,
        version: &str,
        phase: &str,
        error: &str,
    ) -> String {
        let secrets = self.load_all_vault_secrets().unwrap_or_default();
        let reason = redact_known_secrets(error, &secrets);
        let mut recording_failures = Vec::new();
        if let Err(recording_error) = self.store.mark_failed(worker_id, phase, &reason) {
            recording_failures.push(format!("disable failed worker: {recording_error}"));
        } else if let Err(recording_error) = self.refresh_worker_surface_evidence(worker_id).await {
            recording_failures.push(format!("refresh failed worker evidence: {recording_error}"));
        }
        if let Err(recording_error) = self.store.record_system_inbox(
            worker_id,
            phase,
            &json!({
                "status":"failed",
                "phase":phase,
                "workerId":worker_id,
                "version":version,
                "error":reason,
                "disabled":true,
            }),
        ) {
            recording_failures.push(format!("record failure inbox: {recording_error}"));
        }
        self.cancel_worker(worker_id);
        self.unregister_dynamic_tool(worker_id).await;
        self.stop_residents(Some(worker_id)).await;
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":"failed",
                "phase":phase,
                "workerId":worker_id,
                "version":version,
                "reason":reason,
                "disabled":true,
            }),
            None,
        )
        .await;
        if recording_failures.is_empty() {
            reason
        } else {
            format!("{reason}; {}", recording_failures.join("; "))
        }
    }

    pub(super) async fn prepare_dependencies_and_test(
        &self,
        prepared: &mut PreparedWorker,
    ) -> Result<(), String> {
        let workdir = prepared.staging_dir.join("files");
        let dependencies = prepared.staging_dir.join("dependencies");
        let runtime = prepared.staging_dir.join("dependency-runtime");
        let secrets = self.load_secrets(&prepared.bundle)?;
        let redactions = self.load_all_vault_secrets()?;
        let mut install_evidence = Vec::new();
        let mut smoke_evidence = Vec::new();
        let mut health_evidence = Vec::new();
        std::fs::create_dir_all(&dependencies).map_err(|error| error.to_string())?;
        std::fs::create_dir_all(&runtime).map_err(|error| error.to_string())?;
        for index in 0..prepared.bundle.dependencies.len() {
            let dependency = prepared.bundle.dependencies[index].clone();
            let dependency_dir = dependencies.join(&dependency.name);
            let actual_checksum = self
                .fetch_dependency(&dependency, &dependency_dir)
                .await
                .map_err(|error| redact_known_secrets(&error, &redactions))?;
            prepared.bundle.dependencies[index].checksum = Some(actual_checksum);
            if let Some(install) = &dependency.install {
                let output = run_worker_command(install, &dependency_dir, None, &secrets, None)
                    .await
                    .map_err(|error| redact_known_secrets(&error, &redactions))?;
                install_evidence.push(json!({
                    "dependency":dependency.name,
                    "command":install.command,
                    "output":redact_json_known_secrets(output, &redactions),
                }));
            }
        }
        self.store.seal_resolved_dependencies(prepared)?;
        for test in &prepared.bundle.smoke_tests {
            let output = run_worker_command(test, &workdir, None, &secrets, None)
                .await
                .map_err(|error| redact_known_secrets(&error, &redactions))?;
            smoke_evidence.push(json!({
                "command":test.command,
                "output":redact_json_known_secrets(output, &redactions),
            }));
        }
        for check in &prepared.bundle.health_checks {
            let output = run_worker_command(check, &workdir, None, &secrets, None)
                .await
                .map_err(|error| redact_known_secrets(&error, &redactions))?;
            health_evidence.push(json!({
                "command":check.command,
                "output":redact_json_known_secrets(output, &redactions),
            }));
        }
        let verification = json!({
            "format":"tron.worker_verification.v1",
            "verifiedAt":chrono::Utc::now().to_rfc3339(),
            "dependencies":prepared.bundle.dependencies,
            "dependencyInstalls":install_evidence,
            "smokeTests":smoke_evidence,
            "healthChecks":health_evidence,
            "status":"passed",
        });
        std::fs::write(
            prepared.staging_dir.join("verification.json"),
            serde_json::to_vec_pretty(&verification).map_err(|error| error.to_string())?,
        )
        .map_err(|error| format!("write worker verification evidence: {error}"))?;
        Ok(())
    }

    pub(super) async fn fetch_dependency(
        &self,
        dependency: &WorkerDependency,
        destination: &Path,
    ) -> Result<String, String> {
        if destination.exists() {
            std::fs::remove_dir_all(destination).map_err(|error| error.to_string())?;
        }
        std::fs::create_dir_all(destination).map_err(|error| error.to_string())?;
        if let Some(source) = dependency.source.strip_prefix("file://") {
            let source = PathBuf::from(source);
            if source.is_dir() {
                copy_tree(&source, destination)?;
            } else {
                std::fs::copy(&source, destination.join("source"))
                    .map_err(|error| format!("copy dependency '{}': {error}", dependency.name))?;
            }
        } else if let Some(source) = dependency.source.strip_prefix("git+") {
            let clone = WorkerCommand {
                command: vec![
                    "git".to_owned(),
                    "clone".to_owned(),
                    "--quiet".to_owned(),
                    "--no-checkout".to_owned(),
                    source.to_owned(),
                    ".".to_owned(),
                ],
                timeout_seconds: 1_800,
            };
            run_worker_command(&clone, destination, None, &HashMap::new(), None).await?;
            let checkout = WorkerCommand {
                command: vec![
                    "git".to_owned(),
                    "checkout".to_owned(),
                    "--quiet".to_owned(),
                    "--detach".to_owned(),
                    dependency.version.clone(),
                ],
                timeout_seconds: 300,
            };
            run_worker_command(&checkout, destination, None, &HashMap::new(), None).await?;
            let _ = std::fs::remove_dir_all(destination.join(".git"));
        } else {
            let url = url::Url::parse(&dependency.source)
                .map_err(|error| format!("dependency '{}' source URL: {error}", dependency.name))?;
            if !matches!(url.scheme(), "http" | "https") {
                return Err(format!(
                    "dependency '{}' source must use file://, git+https://, http://, or https://",
                    dependency.name
                ));
            }
            let response = self
                .http
                .get(url)
                .send()
                .await
                .map_err(|error| format!("fetch dependency '{}': {error}", dependency.name))?
                .error_for_status()
                .map_err(|error| format!("fetch dependency '{}': {error}", dependency.name))?;
            if response
                .content_length()
                .is_some_and(|length| length > MAX_DEPENDENCY_DOWNLOAD_BYTES as u64)
            {
                return Err(format!("dependency '{}' exceeds 128 MiB", dependency.name));
            }
            let destination_file = destination.join("source");
            let mut file = tokio::fs::File::create(&destination_file)
                .await
                .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
            let mut response = response;
            let mut downloaded = 0_usize;
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|error| format!("read dependency '{}': {error}", dependency.name))?
            {
                downloaded = downloaded.saturating_add(chunk.len());
                if downloaded > MAX_DEPENDENCY_DOWNLOAD_BYTES {
                    return Err(format!("dependency '{}' exceeds 128 MiB", dependency.name));
                }
                file.write_all(&chunk)
                    .await
                    .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
            }
            file.flush()
                .await
                .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
        }
        let actual = format!("sha256:{}", digest_tree(destination)?);
        if let Some(expected) = dependency.checksum.as_deref()
            && !actual.eq_ignore_ascii_case(expected)
        {
            return Err(format!(
                "dependency '{}' checksum mismatch: expected {expected}, got {actual}",
                dependency.name
            ));
        }
        Ok(actual)
    }
}
