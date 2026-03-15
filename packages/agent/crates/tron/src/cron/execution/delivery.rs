//! Result delivery: WebSocket broadcast, APNS push, webhook POST.
//!
//! Delivery is post-execution — failures are logged and recorded on the
//! run but never cause the run itself to be retried.

use crate::cron::executor::ExecutorDeps;
use crate::cron::types::{CronJob, CronRun, Delivery, DeliveryOutcome};

/// Deliver run results through all configured delivery modes.
pub async fn deliver(job: &CronJob, run: &CronRun, deps: &ExecutorDeps) {
    let delivery_modes = if job.delivery.is_empty() {
        vec![Delivery::Silent]
    } else {
        job.delivery.clone()
    };

    let mut statuses: Vec<DeliveryOutcome> = Vec::new();
    for mode in &delivery_modes {
        let result = match mode {
            Delivery::Silent => Ok(()),
            Delivery::WebSocket => deliver_ws(job, run, deps).await,
            Delivery::Apns { title } => deliver_apns(job, run, title.as_deref(), deps).await,
            Delivery::Webhook { url, headers } => {
                deliver_webhook(job, run, url, headers.as_ref(), deps).await
            }
        };
        match result {
            Ok(()) => statuses.push(DeliveryOutcome::Ok),
            Err(e) => {
                tracing::warn!(
                    job_id = %job.id,
                    delivery = ?mode,
                    error = %e,
                    "delivery failed"
                );
                statuses.push(DeliveryOutcome::Failed);
            }
        }
    }

    let overall = if statuses.iter().all(|s| *s == DeliveryOutcome::Ok) {
        DeliveryOutcome::Ok
    } else if statuses.contains(&DeliveryOutcome::Ok) {
        DeliveryOutcome::Partial
    } else {
        DeliveryOutcome::Failed
    };
    let _ = crate::cron::store::update_delivery_status(&deps.pool, &run.id, &overall);
}

async fn deliver_ws(
    job: &CronJob,
    run: &CronRun,
    deps: &ExecutorDeps,
) -> Result<(), crate::cron::errors::CronError> {
    let broadcaster = deps
        .broadcaster
        .get()
        .ok_or_else(|| crate::cron::errors::CronError::Execution("no broadcaster".into()))?;
    broadcaster.broadcast_cron_result(job, run).await;
    Ok(())
}

async fn deliver_apns(
    job: &CronJob,
    run: &CronRun,
    title: Option<&str>,
    deps: &ExecutorDeps,
) -> Result<(), crate::cron::errors::CronError> {
    // Agent turns handle their own notifications via NotifyApp.
    // Automatic APNS delivery only serves as a failure fallback for agent turns.
    // Non-agent payloads (shell commands, webhooks) use APNS delivery normally.
    if run.session_id.is_some() && run.status == crate::cron::types::RunStatus::Completed {
        tracing::debug!(
            job_id = %job.id,
            "skipping automatic APNS for successful agent turn"
        );
        return Ok(());
    }

    let notifier = deps
        .push_notifier
        .as_ref()
        .ok_or_else(|| crate::cron::errors::CronError::Execution("no push notifier".into()))?;

    let title = title.unwrap_or(&job.name);
    let body = match &run.status {
        crate::cron::types::RunStatus::Completed => run
            .output
            .as_deref()
            .unwrap_or("Completed successfully")
            .chars()
            .take(200)
            .collect::<String>(),
        _ => format!(
            "Failed: {}",
            run.error.as_deref().unwrap_or("unknown error")
        ),
    };

    notifier.notify(title, &body).await
}

async fn deliver_webhook(
    _job: &CronJob,
    run: &CronRun,
    url: &str,
    headers: Option<&serde_json::Map<String, serde_json::Value>>,
    deps: &ExecutorDeps,
) -> Result<(), crate::cron::errors::CronError> {
    let mut req = deps.http_client.post(url);
    req = req.timeout(std::time::Duration::from_secs(30));

    if let Some(hdrs) = headers {
        for (k, v) in hdrs {
            if let Some(s) = v.as_str() {
                req = req.header(k.as_str(), s);
            }
        }
    }

    let payload = serde_json::to_value(run)
        .map_err(|e| crate::cron::errors::CronError::Execution(e.to_string()))?;
    req = req.json(&payload);

    let resp = req
        .send()
        .await
        .map_err(|e| crate::cron::errors::CronError::Execution(format!("delivery webhook: {e}")))?;

    if !resp.status().is_success() {
        return Err(crate::cron::errors::CronError::Execution(format!(
            "delivery webhook returned {}",
            resp.status()
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cron::types::*;
    use chrono::Utc;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct MockPushNotifier {
        called: AtomicBool,
    }

    impl MockPushNotifier {
        fn new() -> Self {
            Self {
                called: AtomicBool::new(false),
            }
        }
        fn was_called(&self) -> bool {
            self.called.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl crate::cron::executor::PushNotifier for MockPushNotifier {
        async fn notify(&self, _title: &str, _body: &str) -> Result<(), crate::cron::errors::CronError> {
            self.called.store(true, Ordering::SeqCst);
            Ok(())
        }
    }

    fn make_deps_with_notifier(notifier: Arc<MockPushNotifier>) -> ExecutorDeps {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            crate::cron::migrations::run_migrations(&conn).unwrap();
        }
        ExecutorDeps {
            agent_executor: None,
            broadcaster: std::sync::OnceLock::new(),
            push_notifier: Some(notifier),
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool,
        }
    }

    fn make_job() -> CronJob {
        CronJob {
            id: "cron_1".into(),
            name: "Test".into(),
            description: None,
            enabled: true,
            schedule: Schedule::Every {
                interval_secs: 60,
                anchor: None,
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![],
            overlap_policy: OverlapPolicy::default(),
            misfire_policy: MisfirePolicy::default(),
            max_retries: 0,
            auto_disable_after: 0,
            stuck_timeout_secs: 7200,
            tags: vec![],
            tool_restrictions: None,
            workspace_id: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn make_run() -> CronRun {
        CronRun {
            id: "run_1".into(),
            job_id: Some("cron_1".into()),
            job_name: "Test".into(),
            status: RunStatus::Completed,
            started_at: Utc::now(),
            completed_at: Some(Utc::now()),
            duration_ms: Some(100),
            output: Some("hello".into()),
            output_truncated: false,
            error: None,
            exit_code: Some(0),
            attempt: 0,
            session_id: None,
            delivery_status: None,
        }
    }

    fn make_deps() -> ExecutorDeps {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            crate::cron::migrations::run_migrations(&conn).unwrap();
        }
        ExecutorDeps {
            agent_executor: None,
            broadcaster: std::sync::OnceLock::new(),
            push_notifier: None,
            event_injector: None,
            http_client: reqwest::Client::new(),
            pool,
        }
    }

    #[tokio::test]
    async fn deliver_silent_noop() {
        let mut job = make_job();
        job.delivery = vec![Delivery::Silent];
        let deps = make_deps();
        // Should not panic or error
        deliver(&job, &make_run(), &deps).await;
    }

    #[tokio::test]
    async fn deliver_multiple_modes_with_no_broadcaster() {
        let mut job = make_job();
        job.delivery = vec![Delivery::Silent, Delivery::WebSocket];
        let deps = make_deps();
        // WebSocket delivery fails (no broadcaster), but Silent succeeds
        deliver(&job, &make_run(), &deps).await;
        // delivery_status should be Partial (if we check the DB)
    }

    #[tokio::test]
    async fn delivery_failure_doesnt_panic() {
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns { title: None }];
        let deps = make_deps();
        // No push notifier — should log warning, not panic
        deliver(&job, &make_run(), &deps).await;
    }

    #[tokio::test]
    async fn apns_skipped_for_successful_agent_turn() {
        let notifier = Arc::new(MockPushNotifier::new());
        let deps = make_deps_with_notifier(notifier.clone());
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns { title: None }];
        let mut run = make_run();
        run.session_id = Some("sess_agent".into());
        run.status = RunStatus::Completed;

        deliver(&job, &run, &deps).await;

        assert!(
            !notifier.was_called(),
            "APNS should be skipped for successful agent turns"
        );
    }

    #[tokio::test]
    async fn apns_sent_for_failed_agent_turn() {
        let notifier = Arc::new(MockPushNotifier::new());
        let deps = make_deps_with_notifier(notifier.clone());
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns { title: None }];
        let mut run = make_run();
        run.session_id = Some("sess_agent".into());
        run.status = RunStatus::Failed;
        run.error = Some("model overloaded".into());

        deliver(&job, &run, &deps).await;

        assert!(
            notifier.was_called(),
            "APNS should be sent for failed agent turns"
        );
    }

    #[tokio::test]
    async fn apns_sent_for_timed_out_agent_turn() {
        let notifier = Arc::new(MockPushNotifier::new());
        let deps = make_deps_with_notifier(notifier.clone());
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns { title: None }];
        let mut run = make_run();
        run.session_id = Some("sess_agent".into());
        run.status = RunStatus::TimedOut;
        run.error = Some("exceeded timeout".into());

        deliver(&job, &run, &deps).await;

        assert!(
            notifier.was_called(),
            "APNS should be sent for timed out agent turns"
        );
    }

    #[tokio::test]
    async fn apns_sent_for_cancelled_agent_turn() {
        let notifier = Arc::new(MockPushNotifier::new());
        let deps = make_deps_with_notifier(notifier.clone());
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns { title: None }];
        let mut run = make_run();
        run.session_id = Some("sess_agent".into());
        run.status = RunStatus::Cancelled;
        run.error = Some("shutdown".into());

        deliver(&job, &run, &deps).await;

        assert!(
            notifier.was_called(),
            "APNS should be sent for cancelled agent turns"
        );
    }

    #[tokio::test]
    async fn apns_sent_for_non_agent_completed_run() {
        let notifier = Arc::new(MockPushNotifier::new());
        let deps = make_deps_with_notifier(notifier.clone());
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns { title: None }];
        let run = make_run(); // session_id = None, status = Completed

        deliver(&job, &run, &deps).await;

        assert!(
            notifier.was_called(),
            "APNS should be sent for non-agent payloads"
        );
    }

    #[tokio::test]
    async fn apns_uses_custom_title_for_failed_agent_turn() {
        let notifier = Arc::new(MockPushNotifier::new());
        let deps = make_deps_with_notifier(notifier.clone());
        let mut job = make_job();
        job.delivery = vec![Delivery::Apns {
            title: Some("Custom Alert".into()),
        }];
        let mut run = make_run();
        run.session_id = Some("sess_agent".into());
        run.status = RunStatus::Failed;
        run.error = Some("agent error".into());

        deliver(&job, &run, &deps).await;

        assert!(
            notifier.was_called(),
            "APNS should be sent for failed turns even with custom title"
        );
    }
}
