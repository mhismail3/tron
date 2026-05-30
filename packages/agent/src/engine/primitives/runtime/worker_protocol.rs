//! Worker protocol guide response and executable template projection.

use serde_json::{Value, json};

use super::optional_string;
use crate::engine::errors::{EngineError, Result};
use crate::engine::invocation::Invocation;

pub(in crate::engine::primitives) fn guide(invocation: &Invocation) -> Result<Value> {
    let requested_language = optional_string(invocation.payload.get("language"))?
        .unwrap_or_else(|| "python".to_owned())
        .to_ascii_lowercase();
    if !matches!(
        requested_language.as_str(),
        "python"
            | "python3"
            | "node"
            | "nodejs"
            | "node.js"
            | "javascript"
            | "typescript"
            | "ts"
            | "js"
    ) {
        return Err(EngineError::PolicyViolation(
            "worker::protocol_guide supports python plus common JavaScript/TypeScript aliases; the returned executable template is python".to_owned(),
        ));
    }
    let function_id = optional_string(invocation.payload.get("functionId"))?
        .unwrap_or_else(|| "demo::echo".to_owned());
    let worker_id = optional_string(invocation.payload.get("workerId"))?
        .unwrap_or_else(|| "demo-echo-worker".to_owned());
    let namespace = function_id
        .split_once("::")
        .map(|(namespace, _)| namespace)
        .filter(|namespace| !namespace.is_empty())
        .unwrap_or("demo");
    let protocol_version = crate::engine::protocol::WORKER_PROTOCOL_VERSION;
    let environment = json!({
        "TRON_ENGINE_WORKER_ENDPOINT": "Absolute WebSocket endpoint injected by worker::spawn, for example ws://127.0.0.1:9847/engine/workers",
        "TRON_ENGINE_BEARER_TOKEN": "Bearer token injected by worker::spawn; send it as Authorization: Bearer <token>",
        "TRON_ENGINE_WORKER_ID": "Stable worker id injected by worker::spawn",
        "TRON_ENGINE_WORKER_VISIBILITY": "session, workspace, or system",
        "TRON_ENGINE_WORKER_PROTOCOL_VERSION": protocol_version.to_string(),
        "TRON_ENGINE_WORKER_TOKEN": "Scoped worker-token JSON injected by worker::spawn; bounds pluginId, namespaceClaims, authorityGrantId, authorityGrantRevision, authorityGrantHash, resourceSelectors, visibilityCeiling, trustTier, scope binding, expiry, and signatureStatus",
        "TRON_ENGINE_SESSION_ID": "Present for session-visible sandbox workers",
        "TRON_ENGINE_WORKSPACE_ID": "Present for workspace-visible sandbox workers"
    });
    let message_flow = json!([
        "Open TRON_ENGINE_WORKER_ENDPOINT as a WebSocket with Authorization: Bearer ${TRON_ENGINE_BEARER_TOKEN}.",
        "Send a hello message with type=hello, protocolVersion, worker definition, identity, loopbackOnly=true, authPolicy=loopback_bearer, registrationMode=volatile, defaultVisibility, sessionId/workspaceId, heartbeatIntervalMs, supportedCapabilities, and workerToken.",
        "Receive catalog_snapshot from the engine. This is the live catalog visible to the worker at connect time.",
        "Send register_function for every capability the worker owns. Function definition fields use snake_case; the wrapper fields use camelCase.",
        "Handle invoke messages by executing exactly the requested function id, then send result with the same invocationId.",
        "Send heartbeat messages before the heartbeat interval expires.",
        "Send disconnect before clean exit. Volatile functions/triggers are removed from the live catalog."
    ]);
    let read_only_echo_minimum = json!({
        "id": function_id,
        "revision": 1,
        "owner_worker": worker_id,
        "description": "Echo one payload through an external sandbox worker",
        "request_schema": {"type":"object","additionalProperties":true},
        "response_schema": {"type":"object","additionalProperties":true},
        "opaque_response": false,
        "tags": ["demo", "echo", "sandbox-worker"],
        "visibility": "Session",
        "effect_class": "PureRead",
        "risk_level": "Low",
        "idempotency": null,
        "resource_lease": null,
        "compensation": null,
        "required_authority": {"scopes": [], "approval_required": false},
        "allowed_delivery_modes": ["Sync"],
        "health": "Healthy",
        "provenance": {"created_by": "system", "source": "sandbox-worker", "session_id": null, "workspace_id": null},
        "metadata": {
            "contractId": function_id,
            "implementationId": format!("session_generated.{namespace}.demo_echo"),
            "pluginId": format!("session_generated.{worker_id}"),
            "trustTier": "session_generated",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {"workerKind": "sandbox", "deliveryModes": ["Sync"]},
            "examples": [{"payload": {"hello": "world"}}],
            "modelPrimitiveName": "demo_echo",
            "streamTopics": []
        }
    });
    let function_definition_shape = json!({
        "definitionFieldCase": "snake_case",
        "wrapperFieldCase": "camelCase",
        "workerKinds": ["External", "Sandbox"],
        "visibility": ["Session", "Workspace", "System"],
        "effectClass": ["PureRead", "DeterministicCompute", "IdempotentWrite", "AppendOnlyEvent", "ReversibleSideEffect", "ExternalSideEffect", "IrreversibleSideEffect"],
        "riskLevel": ["Low", "Medium", "High", "Critical"],
        "functionHealth": ["Healthy", "Degraded", "Unhealthy", "Unknown"],
        "deliveryMode": ["Sync", "Void", "Enqueue"],
        "readOnlyEchoMinimum": read_only_echo_minimum
    });
    let rules = json!([
        "Use this guide instead of searching Tron source when asked to register a worker or create capabilities.",
        "Every executable unit is a canonical namespace::function registered by exactly one worker.",
        "Worker registrations appear in catalog::list and capability::search after catalog change propagation.",
        "Mutating functions must declare idempotency and require callers to provide stable idempotency keys.",
        "Streams must be published through the worker protocol publish_stream message or stream::publish, never by writing directly to client sockets.",
        "Use sandbox::stop_spawned_worker or worker::disconnect to remove volatile capabilities."
    ]);

    Ok(json!({
        "protocolVersion": protocol_version,
        "endpoint": "/engine/workers",
        "requestedLanguage": requested_language,
        "templateLanguage": "python",
        "templateLanguageReason": "The current local sandbox worker template is Python because it runs with the standard library only and needs no package install step. JavaScript/TypeScript requests receive this Python template intentionally.",
        "environment": environment,
        "messageFlow": message_flow,
        "functionDefinitionShape": function_definition_shape,
        "pythonTemplate": python_worker_template(&worker_id, &function_id, namespace),
        "spawnWorkerPayloadExample": {
            "workerId": worker_id,
            "command": "python3",
            "args": ["demo_worker.py"],
            "workingDirectory": "/absolute/path/to/worker-directory",
            "expectedFunctionIds": [function_id],
            "visibility": "session",
            "timeoutMs": 10000
        },
        "rules": rules
    }))
}

fn python_worker_template(worker_id: &str, function_id: &str, namespace: &str) -> String {
    const TEMPLATE: &str = include_str!("worker_protocol_template.py");
    TEMPLATE
        .replace(
            "__WORKER_ID__",
            &serde_json::to_string(worker_id).unwrap_or_else(|_| "\"demo-echo-worker\"".into()),
        )
        .replace(
            "__FUNCTION_ID__",
            &serde_json::to_string(function_id).unwrap_or_else(|_| "\"demo::echo\"".into()),
        )
        .replace(
            "__NAMESPACE__",
            &serde_json::to_string(namespace).unwrap_or_else(|_| "\"demo\"".into()),
        )
}
