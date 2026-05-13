//! Dependency bundle for the program executor worker.

use std::sync::Arc;

use serde_json::Value;

use super::process::ProcessProgramExecutor;
use super::runtime::ProgramExecutor;
use crate::domains::capability::registry::{
    SharedCapabilityRegistryStore, open_capability_registry_store,
};
use crate::domains::capability::types::CapabilityProgramRunRecord;
use crate::domains::worker::DomainRegistrationContext;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) registry_store: SharedCapabilityRegistryStore,
    pub(crate) executor: Arc<dyn ProgramExecutor>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        let storage_path = deps
            .engine_host
            .storage_path_for_setup()
            .expect("engine host storage path must be readable during program setup");
        Self {
            engine_host: deps.engine_host.clone(),
            registry_store: open_capability_registry_store(storage_path)
                .expect("program executor audit store must open"),
            executor: Arc::new(ProcessProgramExecutor::default()),
        }
    }

    pub(crate) async fn registry_audit(
        &self,
        event_type: &'static str,
        trace_id: Option<&str>,
        payload: Value,
    ) -> Result<(), CapabilityError> {
        let store = self.registry_store.clone();
        let trace_id = trace_id.map(ToOwned::to_owned);
        run_blocking_task("program.registry_audit", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_audit_event(event_type, trace_id.as_deref(), payload)
                .map_err(|message| CapabilityError::Internal { message })
        })
        .await
    }

    pub(crate) async fn record_program_run(
        &self,
        record: CapabilityProgramRunRecord,
    ) -> Result<(), CapabilityError> {
        let store = self.registry_store.clone();
        run_blocking_task("program.record_program_run", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_program_run(&record)
                .map_err(|message| CapabilityError::Internal { message })
        })
        .await
    }
}
