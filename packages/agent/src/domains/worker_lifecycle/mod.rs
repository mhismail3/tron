//! Worker lifecycle domain.
//!
//! This module owns package/install/launch lifecycle policy for self-updating
//! workers. It deliberately stays separate from `/engine/workers`: the runtime
//! protocol hosts already-running loopback workers, while this domain records
//! package provenance, validates manifests, derives scoped worker grants,
//! launches local packages, and proves conformance before a launched worker is
//! treated as running. Startup reconciliation downgrades stale durable running
//! launch attempts when no in-process owner can safely stop them, and lifecycle
//! functions wait for that reconciliation before handling new requests.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Canonical lifecycle capability contracts and schemas |
//! | `handlers` | Operation binding and lifecycle command flow |
//! | `inspection` | Read-only package lifecycle projections for `capability::execute` |
//! | `manifest` | `tron.worker_package.v1` parsing and local package validation |
//! | `launcher` | Process launcher, scoped token derivation, and conformance checks |
//! | `resources` | Generic resource writes, links, stream events, and ids |
//!
//! # INVARIANT: launch policy is not worker protocol hosting
//!
//! Lifecycle functions may mint a one-time scoped token and start a local
//! process, but the worker still has to connect through `/engine/workers` and
//! register matching functions/triggers. This module must not accept direct
//! function registration, bypass scoped tokens, or widen provider-visible tools.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::shared::foundation::paths;
use crate::shared::server::errors::CapabilityError;
use tokio::sync::OnceCell;

mod authority;
mod contract;
mod errors;
mod handlers;
pub(crate) mod inspection;
mod launcher;
mod manifest;
mod params;
mod resources;

#[cfg(test)]
mod tests;

use launcher::{SystemWorkerLauncher, WorkerLauncher};

pub(super) const WORKER: &str = "worker_lifecycle";
pub(super) const WORKER_LIFECYCLE_TOPIC: &str = "worker.lifecycle";
pub(super) const PACKAGE_SCHEMA_VERSION: &str = "tron.worker_package.v1";
pub(super) const SOURCE_KIND_LOCAL_FILESYSTEM: &str = "local_filesystem";
pub(super) const APPLY_SCOPE: &str = "worker.lifecycle.write";
pub(super) const PROPOSE_SCOPE: &str = "worker.lifecycle.propose";
pub(super) const DEFAULT_CONFORMANCE_TIMEOUT_MS: u64 = 2_000;

pub(super) const PACKAGE_KIND: &str = "worker_package";
pub(super) const INSTALLATION_KIND: &str = "worker_package_installation";
pub(super) const PROPOSAL_KIND: &str = "worker_package_proposal";
pub(super) const CONFORMANCE_KIND: &str = "worker_package_conformance_report";
pub(super) const LAUNCH_KIND: &str = "worker_launch_attempt";

pub(super) const PROPOSE_FUNCTION: &str = "worker_lifecycle::propose_package_change";
pub(super) const INSTALL_FUNCTION: &str = "worker_lifecycle::install_package";
pub(super) const ENABLE_FUNCTION: &str = "worker_lifecycle::enable_package";
pub(super) const DISABLE_FUNCTION: &str = "worker_lifecycle::disable_package";
pub(super) const LAUNCH_FUNCTION: &str = "worker_lifecycle::launch_worker";
pub(super) const STOP_FUNCTION: &str = "worker_lifecycle::stop_worker";
pub(super) const RETIRE_FUNCTION: &str = "worker_lifecycle::retire_package";

/// Worker lifecycle dependencies narrowed from server setup.
#[derive(Clone)]
pub(crate) struct Deps {
    engine_host: crate::engine::EngineHostHandle,
    package_root: PathBuf,
    launcher: Arc<dyn WorkerLauncher>,
    ws_port: Arc<AtomicU16>,
    startup_reconciliation: Arc<OnceCell<Result<usize, String>>>,
    #[cfg(test)]
    startup_reconciliation_hook: Option<Arc<dyn resources::StartupReconciliationHook>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        let deps = Self {
            engine_host: deps.engine_host.clone(),
            package_root: paths::worker_packages_dir(),
            launcher: Arc::new(SystemWorkerLauncher::default()),
            ws_port: deps.ws_port.clone(),
            startup_reconciliation: Arc::new(OnceCell::new()),
            #[cfg(test)]
            startup_reconciliation_hook: None,
        };
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let reconcile_deps = deps.clone();
            handle.spawn(async move {
                let _ = reconcile_deps.ensure_startup_reconciled().await;
            });
        }
        deps
    }

    pub(super) async fn ensure_startup_reconciled(&self) -> Result<usize, CapabilityError> {
        let result = self
            .startup_reconciliation
            .get_or_init(|| async {
                resources::reconcile_owned_launch_attempts_on_startup(self)
                    .await
                    .map_err(|error| error.to_string())
            })
            .await;
        match result {
            Ok(reconciled) => Ok(*reconciled),
            Err(error) => Err(CapabilityError::Custom {
                code: "WORKER_LIFECYCLE_STARTUP_RECONCILE_FAILED".to_owned(),
                message: error.clone(),
                details: None,
            }),
        }
    }

    #[cfg(test)]
    fn for_test(
        engine_host: crate::engine::EngineHostHandle,
        package_root: PathBuf,
        launcher: Arc<dyn WorkerLauncher>,
    ) -> Self {
        let startup_reconciliation = Arc::new(OnceCell::new());
        startup_reconciliation
            .set(Ok(0))
            .expect("test startup reconciliation cell should be empty");
        Self {
            engine_host,
            package_root,
            launcher,
            ws_port: Arc::new(AtomicU16::new(17345)),
            startup_reconciliation,
            startup_reconciliation_hook: None,
        }
    }

    #[cfg(test)]
    fn for_test_pending_startup_reconciliation(
        engine_host: crate::engine::EngineHostHandle,
        package_root: PathBuf,
        launcher: Arc<dyn WorkerLauncher>,
        startup_reconciliation_hook: Option<Arc<dyn resources::StartupReconciliationHook>>,
    ) -> Self {
        Self {
            engine_host,
            package_root,
            launcher,
            ws_port: Arc::new(AtomicU16::new(17345)),
            startup_reconciliation: Arc::new(OnceCell::new()),
            startup_reconciliation_hook,
        }
    }
}

/// Build the domain worker registration.
pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[WORKER_LIFECYCLE_TOPIC],
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}
