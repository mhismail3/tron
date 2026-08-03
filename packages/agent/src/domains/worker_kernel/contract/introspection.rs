//! Closed response schemas for authenticated worker-system introspection.
//!
//! This module describes projection only. It does not own worker selection,
//! routing, health policy, or persistence.

use serde_json::{Value, json};

pub(super) fn worker_architecture_response_schema() -> Value {
    let call_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["kind","label"],
        "properties":{
            "kind":{"type":"string","enum":["worker_dispatch","agent_tool"]},
            "label":{"type":"string"},
            "targetWorkerId":{"type":["string","null"]},
            "responseOwner":{"type":"string"}
        }
    });
    let presentation_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["suiteId","componentRole","primary"],
        "properties":{
            "suiteId":{"type":["string","null"]},
            "componentRole":{"type":["string","null"]},
            "primary":{"type":"boolean"}
        }
    });
    let provenance_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["source","revision","checksum"],
        "properties":{
            "source":{"type":"string"},
            "revision":{"type":"string"},
            "checksum":{"type":["string","null"]}
        }
    });
    json!({
        "type":"array",
        "items":{
            "type":"object",
            "additionalProperties":false,
            "required":["workerId","name","description","activeVersion","health","modelExposure","runnerKind","engineHooks","clientActions","clientDeliveries","triggerKinds","calls","presentation","provenance"],
            "properties":{
                "workerId":{"type":"string"},
                "name":{"type":"string"},
                "description":{"type":"string"},
                "activeVersion":{"type":"string"},
                "health":{"type":"string"},
                "modelExposure":{"type":"string","enum":["direct","internal"]},
                "runnerKind":{"type":"string","enum":["agent","command","service"]},
                "runnerModel":{"type":["string","null"]},
                "engineHooks":{"type":"array","items":{"type":"string"}},
                "clientActions":{"type":"array","items":{"type":"string"}},
                "clientDeliveries":{"type":"array","items":{"type":"string"}},
                "triggerKinds":{"type":"array","items":{"type":"string"}},
                "calls":{"type":"array","items":call_schema},
                "presentation":presentation_schema,
                "provenance":{"type":"array","items":provenance_schema}
            }
        }
    })
}
