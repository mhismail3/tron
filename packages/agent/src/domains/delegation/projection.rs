//! Provider- and UI-safe delegation projections.

use serde_json::{Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

pub(crate) fn summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    let accepted = resource.lifecycle == "accepted";
    json!({
        "workflowRef": {"kind": "delegation", "id": resource.resource_id, "sessionId": payload["parentSessionId"]},
        "versionRef": {"resourceKind": resource.kind, "resourceId": resource.resource_id, "versionId": version.version_id, "lifecycle": resource.lifecycle},
        "state": resource.lifecycle,
        "objectiveSummary": payload["objectiveSummary"],
        "childSessionId": payload["childSessionId"],
        "createdAt": payload["createdAt"],
        "updatedAt": payload["updatedAt"],
        "resultSummary": if accepted { payload["resultSummary"].clone() } else { Value::Null },
        "resultRefs": if accepted { payload["resultRefs"].clone() } else { json!([]) },
    })
}
