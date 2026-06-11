//! Primitive worker and function registration assembly.

use super::*;

use crate::engine::kernel::ids::{ActorId, AuthorityGrantId};
use crate::engine::kernel::types::{WorkerDefinition, WorkerKind};

const ENGINE_OWNER_ACTOR: &str = "system";
const ENGINE_AUTHORITY_GRANT: &str = "engine-system";

pub(in crate::engine) fn primitive_workers() -> Result<Vec<WorkerDefinition>> {
    let resource_worker = primitive_worker(RESOURCE_WORKER_ID, WorkerKind::System)?
        .with_namespace_claim("artifact")
        .with_namespace_claim("goal")
        .with_namespace_claim("claim")
        .with_namespace_claim("evidence")
        .with_namespace_claim("decision")
        .with_namespace_claim("agent_memory")
        .with_namespace_claim("agent_rule")
        .with_namespace_claim("materialized_file")
        .with_namespace_claim("patch");
    Ok(vec![
        primitive_worker(STREAM_WORKER_ID, WorkerKind::Stream)?,
        primitive_worker(STATE_WORKER_ID, WorkerKind::State)?,
        primitive_worker(QUEUE_WORKER_ID, WorkerKind::Queue)?,
        resource_worker,
        primitive_worker(TRIGGER_WORKER_ID, WorkerKind::System)?,
        primitive_worker(GRANT_WORKER_ID, WorkerKind::System)?,
        primitive_worker(CATALOG_WORKER_ID, WorkerKind::System)?,
        primitive_worker(UI_WORKER_ID, WorkerKind::System)?,
        primitive_worker(WORKER_WORKER_ID, WorkerKind::System)?,
        primitive_worker(STORAGE_WORKER_ID, WorkerKind::System)?,
    ])
}

pub(in crate::engine) fn primitive_function_definitions(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let mut registrations = Vec::new();
    registrations.extend(stream::registrations(stores)?);
    registrations.extend(state::registrations(stores)?);
    registrations.extend(queue::registrations(stores)?);
    registrations.extend(resource::registrations(stores)?);
    registrations.extend(trigger::registrations(stores)?);
    registrations.extend(grant::registrations(stores)?);
    registrations.extend(catalog::registrations()?);
    registrations.extend(ui::registrations()?);
    registrations.extend(worker::registrations()?);
    registrations.extend(storage::registrations()?);
    Ok(registrations)
}

fn primitive_worker(id: &str, kind: WorkerKind) -> Result<WorkerDefinition> {
    Ok(WorkerDefinition::new(
        worker_id(id)?,
        kind,
        actor_id(ENGINE_OWNER_ACTOR)?,
        grant_id(ENGINE_AUTHORITY_GRANT)?,
    )
    .with_namespace_claim(id))
}

fn actor_id(value: &str) -> Result<ActorId> {
    ActorId::new(value)
}

fn grant_id(value: &str) -> Result<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}
