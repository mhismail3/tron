//! Domain-specific dependency bundle for the cron worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) cron_scheduler: Option<Arc<crate::cron::CronScheduler>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            cron_scheduler: deps.server_context.cron_scheduler.clone(),
            engine_host: deps.engine_host.clone(),
        }
    }
}
