//! Typed contracts for the authenticated workspace-picker infrastructure.
//!
//! Model filesystem work belongs to the worker kernel's direct host
//! primitives. This domain intentionally retains only the client-facing home,
//! directory-listing, and directory-creation surface used during workspace
//! selection.

use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel};

use super::WORKER;

pub(super) const GET_HOME_FUNCTION: &str = "filesystem::get_home";
pub(super) const LIST_DIR_FUNCTION: &str = "filesystem::list_dir";
pub(super) const CREATE_DIR_FUNCTION: &str = "filesystem::create_dir";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            GET_HOME_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
        )
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "required": ["homePath", "suggestedPaths"],
            "additionalProperties": false,
            "properties": {
                "homePath": {"type": "string"},
                "suggestedPaths": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "exists"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "exists": {"type": "boolean"}
                        }
                    }
                }
            }
        }))
        .build()?,
        CapabilityContract::new(
            LIST_DIR_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
        )
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "showHidden": {"type": "boolean"},
                "maxResults": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "required": ["path", "parent", "entries", "truncated"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "parent": {"type": ["string", "null"]},
                "truncated": {"type": "boolean"},
                "entries": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "isDirectory", "isSymlink"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "isDirectory": {"type": "boolean"},
                            "isSymlink": {"type": "boolean"},
                            "size": {"type": ["integer", "null"]},
                            "modifiedAt": {"type": ["string", "null"]}
                        }
                    }
                }
            }
        }))
        .build()?,
        CapabilityContract::new(
            CREATE_DIR_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
        )
        .request_schema(json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "recursive": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "required": ["created", "path"],
            "additionalProperties": false,
            "properties": {
                "created": {"type": "boolean"},
                "path": {"type": "string"}
            }
        }))
        .idempotency(IdempotencyContract::system())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .build()?,
    ])
}
