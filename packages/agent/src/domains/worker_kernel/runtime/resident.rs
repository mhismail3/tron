//! Resident-service readiness, supervision, verified-snapshot reuse, and
//! deterministic teardown.

use super::*;

impl WorkerRuntime {
    pub(super) async fn ensure_resident(
        &self,
        worker: &ActiveWorker,
        command: &[String],
        health_url: Option<&str>,
        secrets: &HashMap<String, String>,
    ) -> Result<(), String> {
        let process = self
            .residents
            .entry(resident_key(worker))
            .or_insert_with(|| {
                Arc::new(Mutex::new(ResidentProcess {
                    child: None,
                    ready: false,
                    consecutive_health_failures: 0,
                    runtime_root: None,
                    worker: None,
                    health_url: None,
                }))
            })
            .clone();
        let mut process = process.lock().await;
        let still_running = match process.child.as_mut() {
            Some(child) => child
                .try_wait()
                .map_err(|error| error.to_string())?
                .is_none(),
            None => false,
        };
        if !still_running {
            if let Some(child) = process.child.as_mut() {
                child.terminate().await;
            }
            if let Some(runtime_root) = process.runtime_root.take() {
                let _ = std::fs::remove_dir_all(runtime_root);
            }
            process.worker = None;
            process.health_url = None;
            let (runtime_root, workdir) = self.materialize_runtime_artifact(
                worker,
                "worker-services",
                &format!("{}-{}", worker.summary.worker_id, uuid::Uuid::now_v7()),
            )?;
            let child = spawn_process(
                command,
                &workdir,
                Some(&self.store.state_dir(&worker.summary.worker_id)?),
                secrets,
                Stdio::null(),
                // Resident output is not part of an invocation result. Leaving
                // stderr piped without a reader eventually blocks a normally
                // logging service once the OS pipe fills.
                Stdio::null(),
                None,
            );
            let child = match child {
                Ok(child) => child,
                Err(error) => {
                    let _ = std::fs::remove_dir_all(&runtime_root);
                    return Err(error);
                }
            };
            process.child = Some(child);
            let mut resident_worker = worker.clone();
            resident_worker.version_dir = runtime_root.join("artifact");
            process.worker = Some(resident_worker);
            process.health_url = match &worker.bundle.runner {
                WorkerRunner::Service { health_url, .. } => health_url.clone(),
                _ => None,
            };
            process.runtime_root = Some(runtime_root);
            process.ready = health_url.is_none();
            process.consecutive_health_failures = 0;
        }
        if !process.ready
            && let Some(url) = health_url
        {
            let mut healthy = false;
            let deadline = tokio::time::Instant::now() + RESIDENT_STARTUP_TIMEOUT;
            loop {
                let now = tokio::time::Instant::now();
                if now >= deadline {
                    break;
                }
                let probe_timeout = RESIDENT_HEALTH_TIMEOUT.min(deadline - now);
                if self
                    .http
                    .get(url)
                    .timeout(probe_timeout)
                    .send()
                    .await
                    .is_ok_and(|response| response.status().is_success())
                {
                    healthy = true;
                    break;
                }
                if process
                    .child
                    .as_mut()
                    .expect("resident startup requires a child")
                    .try_wait()
                    .map_err(|error| error.to_string())?
                    .is_some()
                {
                    break;
                }
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    break;
                }
                tokio::time::sleep(RESIDENT_STARTUP_POLL_INTERVAL.min(remaining)).await;
            }
            if !healthy {
                if let Some(child) = process.child.as_mut() {
                    child.terminate().await;
                }
                process.child = None;
                process.ready = false;
                process.worker = None;
                process.health_url = None;
                if let Some(runtime_root) = process.runtime_root.take() {
                    let _ = std::fs::remove_dir_all(runtime_root);
                }
                return Err(format!(
                    "resident worker failed its startup health check within {} seconds",
                    RESIDENT_STARTUP_TIMEOUT.as_secs()
                ));
            }
            process.ready = true;
        }
        Ok(())
    }

    /// Return the exact verified snapshot owned by a currently ready resident
    /// process. Missing, unready, and exited processes deliberately return
    /// `None`, forcing canonical full-tree verification before any restart.
    pub(super) async fn running_resident_worker(
        &self,
        worker_id: &str,
        version: &str,
    ) -> Option<ActiveWorker> {
        let key = format!("{worker_id}@{version}");
        let process = self
            .residents
            .get(&key)
            .map(|entry| Arc::clone(entry.value()))?;
        let mut process = process.lock().await;
        if !process.ready {
            return None;
        }
        let running = process
            .child
            .as_mut()
            .is_some_and(|child| child.try_wait().is_ok_and(|status| status.is_none()));
        running.then(|| process.worker.clone()).flatten()
    }

    pub(super) fn dispatch_resident_supervision(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let residents = self
            .residents
            .iter()
            .map(|entry| (entry.key().clone(), Arc::clone(entry.value())))
            .collect::<Vec<_>>();
        for (key, process) in residents {
            if !self.resident_supervisions.insert(key.clone()) {
                continue;
            }
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                runtime.supervise_resident(&key, process).await;
                let _ = runtime.resident_supervisions.remove(&key);
            });
        }
    }

    #[cfg(test)]
    pub(super) async fn supervise_residents(self: &Arc<Self>) {
        let mut runs = JoinSet::new();
        self.dispatch_resident_supervision(&mut runs);
        while runs.join_next().await.is_some() {}
    }

    pub(super) async fn supervise_resident(&self, key: &str, process: Arc<Mutex<ResidentProcess>>) {
        let Some((worker_id, version)) = key.rsplit_once('@') else {
            return;
        };
        if !self.resident_is_current(worker_id, version)
            || !self.resident_process_is_registered(key, &process)
        {
            return;
        }

        let exited = {
            let mut process = process.lock().await;
            match process.child.as_mut() {
                Some(child) => match child.try_wait() {
                    Ok(Some(status)) => {
                        process.child = None;
                        Some(format!("resident service exited with {status}"))
                    }
                    Ok(None) => None,
                    Err(error) => Some(format!(
                        "resident service process supervision failed: {error}"
                    )),
                },
                None => Some("resident service process disappeared".to_owned()),
            }
        };
        if let Some(error) = exited {
            if self.resident_is_current(worker_id, version)
                && self.resident_process_is_registered(key, &process)
            {
                let _ = self
                    .handle_worker_runtime_failure(
                        worker_id,
                        version,
                        "resident_supervision",
                        &error,
                    )
                    .await;
            }
            return;
        }

        let health_url = {
            let process = process.lock().await;
            process.health_url.clone()
        };
        let Some(health_url) = health_url else {
            return;
        };
        let health = self
            .http
            .get(&health_url)
            .timeout(RESIDENT_HEALTH_TIMEOUT)
            .send()
            .await;
        if !self.resident_is_current(worker_id, version)
            || !self.resident_process_is_registered(key, &process)
        {
            return;
        }
        let healthy = health
            .as_ref()
            .is_ok_and(|response| response.status().is_success());
        let failure = {
            let mut process = process.lock().await;
            if healthy {
                process.consecutive_health_failures = 0;
                None
            } else {
                process.consecutive_health_failures =
                    process.consecutive_health_failures.saturating_add(1);
                (process.consecutive_health_failures >= RESIDENT_HEALTH_FAILURE_LIMIT).then(
                    || match health {
                        Ok(response) => format!(
                            "resident health endpoint {health_url} returned {} {} consecutive times",
                            response.status(),
                            process.consecutive_health_failures
                        ),
                        Err(error) => format!(
                            "resident health endpoint {health_url} failed {} consecutive times: {error}",
                            process.consecutive_health_failures
                        ),
                    },
                )
            }
        };
        if let Some(error) = failure
            && self.resident_is_current(worker_id, version)
            && self.resident_process_is_registered(key, &process)
        {
            let _ = self
                .handle_worker_runtime_failure(worker_id, version, "resident_supervision", &error)
                .await;
        }
    }

    pub(super) fn resident_is_current(&self, worker_id: &str, version: &str) -> bool {
        self.store
            .summary(worker_id)
            .ok()
            .flatten()
            .is_some_and(|summary| {
                summary.enabled && !summary.retired && summary.active_version == version
            })
    }

    pub(super) fn resident_process_is_registered(
        &self,
        key: &str,
        process: &Arc<Mutex<ResidentProcess>>,
    ) -> bool {
        self.residents
            .get(key)
            .is_some_and(|registered| Arc::ptr_eq(registered.value(), process))
    }

    pub(super) async fn stop_residents(&self, worker_id: Option<&str>) {
        let ids = self
            .residents
            .iter()
            .filter(|entry| {
                worker_id.is_none_or(|id| {
                    entry.key() == id || entry.key().starts_with(&format!("{id}@"))
                })
            })
            .map(|entry| entry.key().clone())
            .collect::<Vec<_>>();
        for id in ids {
            self.stop_resident_key(&id).await;
        }
    }

    pub(super) async fn stop_resident_key(&self, key: &str) {
        if let Some((_, process)) = self.residents.remove(key) {
            let mut process = process.lock().await;
            if let Some(mut child) = process.child.take() {
                child.terminate().await;
            }
            if let Some(runtime_root) = process.runtime_root.take() {
                let _ = std::fs::remove_dir_all(runtime_root);
            }
            process.worker = None;
            process.health_url = None;
        }
        let _ = self.resident_users.remove(key);
    }

    pub(super) async fn stop_obsolete_residents(&self, worker_id: &str, active_version: &str) {
        let active_key = format!("{worker_id}@{active_version}");
        let keys = self
            .residents
            .iter()
            .filter(|entry| {
                entry.key().starts_with(&format!("{worker_id}@"))
                    && entry.key() != &active_key
                    && self
                        .resident_users
                        .get(entry.key())
                        .is_none_or(|users| users.load(Ordering::SeqCst) == 0)
            })
            .map(|entry| entry.key().clone())
            .collect::<Vec<_>>();
        for key in keys {
            self.stop_resident_key(&key).await;
        }
    }
}
