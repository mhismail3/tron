//! Domain-specific dependency bundle for the cron worker.

use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) cron_scheduler: Option<Arc<crate::domains::cron::CronScheduler>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            cron_scheduler: deps.cron_scheduler.clone(),
            engine_host: deps.engine_host.clone(),
        }
    }
}
