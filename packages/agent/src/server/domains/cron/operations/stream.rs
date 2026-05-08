//! Cron workflow operations.
use super::*;
use crate::server::domains::cron::stream::CronStreamPublisher;

pub(crate) async fn publish_cron_stream(
    invocation: &Invocation,
    deps: &Deps,
    kind: &str,
    job_id: &str,
    scheduled_at: Option<String>,
) {
    CronStreamPublisher::new(deps.engine_host.clone())
        .job_lifecycle(invocation, kind, job_id, scheduled_at)
        .await;
}
