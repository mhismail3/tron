//! Capability contracts owned by the native UI domain.

use serde_json::{Value, json};

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const WORKER: &str = "native_ui";
pub(crate) const SURFACE_STREAM_TOPIC: &str = "native_ui.surface";
pub(crate) const STREAM_TOPICS: &[&str] = &[SURFACE_STREAM_TOPIC];

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        read(
            "native_ui::validate_definition",
            "validate a canonical A2UI v0.9.1 definition against the live Tron catalog",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["definition"],
                "properties":{"definition":{"type":"object"}}
            }),
        )
        .build()?,
        write(
            "native_ui::create_preview",
            "store an isolated validated native UI preview revision without changing active state",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["definition"],
                "properties":{"definition":{"type":"object"}}
            }),
        )
        .build()?,
        write(
            "native_ui::activate_definition",
            "compare-and-swap a validated native UI definition into active state",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["definition","expectedActiveRevision"],
                "properties":{
                    "definition":{"type":"object"},
                    "expectedActiveRevision":{"type":["integer","null"],"minimum":0}
                }
            }),
        )
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
        read(
            "native_ui::list_revisions",
            "list bounded native UI definition revision history",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["definitionId"],
                "properties":{
                    "definitionId":{"type":"string","minLength":1},
                    "limit":{"type":"integer","minimum":1,"maximum":100}
                }
            }),
        )
        .build()?,
        write(
            "native_ui::rollback_definition",
            "compare-and-swap an earlier validated native UI revision back into active state",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["definitionId","targetRevision","expectedActiveRevision"],
                "properties":{
                    "definitionId":{"type":"string","minLength":1},
                    "targetRevision":{"type":"integer","minimum":1},
                    "expectedActiveRevision":{"type":["integer","null"],"minimum":0}
                }
            }),
        )
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
        read(
            "native_ui::get_surface",
            "project a validated persistent or transient native UI surface snapshot",
            surface_request_schema(),
        )
        .build()?,
        read(
            "native_ui::reconstruct_surface",
            "reconstruct a last-known-good native UI snapshot after a stream gap",
            surface_request_schema(),
        )
        .build()?,
        write(
            "native_ui::dismiss_surface",
            "durably dismiss a session-owned transient native UI surface",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["surfaceId"],
                "properties":{"surfaceId":{"type":"string","minLength":1}}
            }),
        )
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
        write(
            "native_ui::register_client_catalog",
            "advertise one paired client's versioned precompiled native function catalog",
            json!({
                "type":"object",
                "additionalProperties":false,
                "required":["catalog"],
                "properties":{"catalog":{"type":"object"}}
            }),
        )
        .build()?,
        CapabilityContract::new(
            "native_ui::dispatch_action",
            WORKER,
            EffectClass::DelegatedInvocation,
            RiskLevel::High,
            Some("native_ui.write"),
        )
        .description(
            "dispatch a catalog-bound surface action through its target capability contract",
        )
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["definitionId","functionId","arguments","idempotencyKey"],
            "properties":{
                "definitionId":{"type":"string","minLength":1},
                "surfaceId":{"type":"string","minLength":1},
                "functionId":{"type":"string","minLength":1},
                "arguments":{"type":"object"},
                "idempotencyKey":{"type":"string","minLength":1}
            }
        }))
        .response_schema(object_response())
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
    ])
}

fn read(
    method: &'static str,
    description: &'static str,
    request_schema: Value,
) -> CapabilityContract {
    CapabilityContract::new(
        method,
        WORKER,
        EffectClass::PureRead,
        RiskLevel::Low,
        Some("native_ui.read"),
    )
    .description(description)
    .request_schema(request_schema)
    .response_schema(object_response())
    .tags(vec!["native-ui", "a2ui", "swiftui"])
}

fn write(
    method: &'static str,
    description: &'static str,
    request_schema: Value,
) -> CapabilityContract {
    CapabilityContract::new(
        method,
        WORKER,
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        Some("native_ui.write"),
    )
    .description(description)
    .request_schema(request_schema)
    .response_schema(object_response())
    .idempotency(IdempotencyContract::caller_system_engine_ledger())
    .compensation(CompensationContract::new(
        CompensationKind::InverseCommandAvailable,
        "native UI revisions are immutable and active state can be restored with rollback_definition",
    ))
    .tags(vec!["native-ui", "a2ui", "swiftui"])
}

fn object_response() -> Value {
    json!({"type":"object","additionalProperties":true})
}

fn surface_request_schema() -> Value {
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":["definitionId"],
        "properties":{
            "definitionId":{"type":"string","minLength":1},
            "surfaceId":{"type":"string","minLength":1},
            "sessionId":{"type":"string","minLength":1},
            "eventId":{"type":"string","minLength":1},
            "clientId":{"type":"string","minLength":1}
        }
    })
}
