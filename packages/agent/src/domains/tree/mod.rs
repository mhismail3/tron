//! tree domain worker.
//!
//! This module owns canonical function execution for the tree namespace. Tree
//! reads expose immutable event-store lineage for visualization, branch lists,
//! subtree inspection, ancestor traversal, and branch comparison. Ancestor reads
//! return the same resolved wire `events` shape used by session reconstruction,
//! including interactive capability enrichment, so clients do not need a second
//! tree-specific event representation.

use crate::shared::server::errors;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use serde_json::{Value, json};

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::error_mapping::map_event_store_error;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::events as event_wire;
use crate::shared::server::params::require_string_param;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "tree",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

async fn get_visualization(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let session = deps
        .event_store
        .get_session(&session_id)
        .map_err(map_event_store_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;
    let opts =
        crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions {
            limit: None,
            offset: None,
        };
    let events = deps
        .event_store
        .get_events_by_session(&session_id, &opts)
        .map_err(map_event_store_error)?;
    let nodes: Vec<Value> = events
        .iter()
        .map(|event| {
            json!({
                "id": event.id,
                "parentId": event.parent_id,
                "type": event.event_type,
                "sequence": event.sequence,
                "depth": event.depth,
            })
        })
        .collect();
    Ok(json!({
        "sessionId": session_id,
        "rootEventId": session.root_event_id,
        "headEventId": session.head_event_id,
        "nodes": nodes,
        "totalEvents": events.len(),
    }))
}

async fn get_branches(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let branches = deps
        .event_store
        .get_branches(&session_id)
        .map_err(map_event_store_error)?;
    let wire: Vec<Value> = branches
        .iter()
        .map(|branch| {
            json!({
                "id": branch.id,
                "name": branch.name,
                "rootEventId": branch.root_event_id,
                "headEventId": branch.head_event_id,
                "isDefault": branch.is_default,
            })
        })
        .collect();
    let main_branch = branches
        .iter()
        .find(|branch| branch.is_default)
        .map(|branch| &branch.id);
    Ok(json!({
        "branches": wire,
        "mainBranch": main_branch,
    }))
}

async fn get_subtree(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let event_id = require_string_param(Some(payload), "eventId")?;
    let descendants = deps
        .event_store
        .get_descendants(&event_id)
        .map_err(map_event_store_error)?;
    let nodes: Vec<Value> = descendants
        .iter()
        .map(|event| {
            json!({
                "id": event.id,
                "parentId": event.parent_id,
                "type": event.event_type,
                "sequence": event.sequence,
            })
        })
        .collect();
    Ok(json!({
        "rootEventId": event_id,
        "nodes": nodes,
    }))
}

async fn get_ancestors(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let event_id = require_string_param(Some(payload), "eventId")?;
    let ancestors = deps
        .event_store
        .get_ancestors(&event_id)
        .map_err(map_event_store_error)?;
    let resolved_payloads = deps
        .event_store
        .resolve_event_payloads(&ancestors)
        .map_err(map_event_store_error)?;
    let mut events: Vec<Value> = ancestors
        .iter()
        .zip(resolved_payloads)
        .map(|(event, payload)| event_wire::event_row_to_wire_with_payload(event, Some(payload)))
        .collect();
    crate::domains::capability_support::interactive_enrichment::enrich_interactive_capability_statuses(
        &mut events,
    );
    Ok(json!({ "events": events }))
}

async fn compare_branches(payload: &Value) -> Result<Value, CapabilityError> {
    let _branch_a = require_string_param(Some(payload), "branchA")?;
    let _branch_b = require_string_param(Some(payload), "branchB")?;
    Ok(json!({
        "divergencePoint": null,
        "branchAOnly": [],
        "branchBOnly": [],
    }))
}
