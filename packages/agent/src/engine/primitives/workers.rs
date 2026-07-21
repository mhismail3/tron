//! Primitive worker and function registration assembly.

use super::*;

use crate::engine::kernel::ids::ActorId;
use crate::engine::kernel::types::{WorkerDefinition, WorkerKind};

const ENGINE_OWNER_ACTOR: &str = "system";

pub(in crate::engine) fn primitive_workers() -> Result<Vec<WorkerDefinition>> {
    Ok(vec![
        primitive_worker(STREAM_WORKER_ID, WorkerKind::Stream)?,
        primitive_worker(STATE_WORKER_ID, WorkerKind::State)?,
        primitive_worker(CATALOG_WORKER_ID, WorkerKind::System)?,
        primitive_worker(STORAGE_WORKER_ID, WorkerKind::System)?,
    ])
}

pub(in crate::engine) fn primitive_function_definitions(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let mut registrations = Vec::new();
    registrations.extend(stream::registrations(stores)?);
    registrations.extend(state::registrations(stores)?);
    registrations.extend(catalog::registrations()?);
    registrations.extend(storage::registrations()?);
    Ok(registrations)
}

fn primitive_worker(id: &str, kind: WorkerKind) -> Result<WorkerDefinition> {
    Ok(
        WorkerDefinition::new(worker_id(id)?, kind, actor_id(ENGINE_OWNER_ACTOR)?)
            .with_namespace_claim(id),
    )
}

fn actor_id(value: &str) -> Result<ActorId> {
    ActorId::new(value)
}
