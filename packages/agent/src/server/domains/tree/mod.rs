//! tree domain worker.
//!
//! This module owns canonical function execution for the tree namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use serde_json::{Value, json};

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "tree",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::tree_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps {
    event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            event_store: deps.event_store.clone(),
        }
    }
}

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "tree::get_visualization" => get_visualization(&invocation.payload, deps).await,
        "tree::get_branches" => get_branches(&invocation.payload, deps).await,
        "tree::get_subtree" => get_subtree(&invocation.payload, deps).await,
        "tree::get_ancestors" => get_ancestors(&invocation.payload, deps).await,
        "tree::compare_branches" => compare_branches(&invocation.payload).await,
        _ => Err(CapabilityError::Internal {
            message: format!("tree method {method} is not engine-owned"),
        }),
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
    let opts = crate::events::sqlite::repositories::event::ListEventsOptions {
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
    let nodes: Vec<Value> = ancestors
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
    Ok(json!({ "ancestors": nodes }))
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
