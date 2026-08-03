//! Runtime preparation for declared asynchronous worker handoffs.

use super::*;
use crate::domains::worker_kernel::dispatches::{PreparedWorkerDispatch, parse_worker_dispatches};

impl WorkerRuntime {
    pub(super) fn validate_worker_dispatch_route_targets(
        &self,
        bundle: &WorkerBundle,
    ) -> Result<(), String> {
        for route in &bundle.worker_dispatch_routes {
            let target = self.store.load_active(&route.target_worker_id).map_err(|error| {
                format!(
                    "worker dispatch route '{}' target '{}' is not an active immutable worker: {error}",
                    route.route, route.target_worker_id
                )
            })?;
            if target.summary.retired {
                return Err(format!(
                    "worker dispatch route '{}' target '{}' is retired",
                    route.route, route.target_worker_id
                ));
            }
        }
        Ok(())
    }

    pub(super) fn prepare_worker_dispatches(
        &self,
        source_bundle: &WorkerBundle,
        output: &Value,
    ) -> Result<Vec<PreparedWorkerDispatch>, String> {
        parse_worker_dispatches(source_bundle, output)?
            .into_iter()
            .map(
                |(route, deduplication_key, input, target_worker_id, response_owner)| {
                    let target = self.store.load_active(&target_worker_id).map_err(|error| {
                        format!(
                            "worker dispatch route '{route}' could not load target '{target_worker_id}': {error}"
                        )
                    })?;
                    let function_id = FunctionId::new(format!(
                        "worker_kernel::dynamic_{}",
                        target.summary.worker_id
                    ))
                    .map_err(|error| error.to_string())?;
                    crate::engine::validate_engine_schema_payload(
                        &function_id,
                        "request",
                        &target.bundle.input_schema,
                        &input,
                    )
                    .map_err(|error| {
                        format!(
                            "worker dispatch route '{route}' input does not match target '{}' version '{}': {error}",
                            target.summary.worker_id, target.summary.active_version
                        )
                    })?;
                    self.reject_secret_material_in_value(&input, "worker dispatch input")?;
                    Ok(PreparedWorkerDispatch {
                        route,
                        deduplication_key,
                        input,
                        target_worker_id: target.summary.worker_id,
                        target_worker_version: target.summary.active_version,
                        response_owner,
                    })
                },
            )
            .collect()
    }
}
