use serde_json::{Map, Value, json};

use super::super::super::registry::{CapabilityTarget, parse_target, string_field};
use super::super::target_arguments::{intent_requests_resource_inventory, normalized_intent_words};
use super::result::correction_record;
use crate::shared::server::errors::CapabilityError;

const EXECUTE_WRAPPER_KEYS: &[&str] = &[
    "intent",
    "target",
    "arguments",
    "constraints",
    "operation",
    "payload",
    "idempotencyKey",
    "idempotency_key",
    "reason",
    "mode",
    "capabilityId",
    "contractId",
    "implementationId",
    "functionId",
    "language",
    "code",
    "args",
    "allowedContracts",
    "allowedImplementations",
    "timeoutMs",
    "budget",
    "expectedRevision",
    "expectedSchemaDigest",
    "inspectionHandle",
    "sessionId",
    "workspaceId",
    "traceId",
    "parentInvocationId",
    "authorityScopes",
];

#[derive(Debug)]
pub(in crate::domains::capability::operations) struct OrchestratedExecuteInput {
    pub(in crate::domains::capability::operations) intent: Option<String>,
    pub(in crate::domains::capability::operations) target_params: Option<Value>,
    pub(in crate::domains::capability::operations) arguments: Value,
    pub(in crate::domains::capability::operations) constraints: Value,
    pub(in crate::domains::capability::operations) operation: Option<String>,
    pub(in crate::domains::capability::operations) idempotency_key: Option<String>,
    pub(in crate::domains::capability::operations) reason: Option<String>,
    pub(in crate::domains::capability::operations) corrections: Vec<Value>,
}

impl OrchestratedExecuteInput {
    pub(super) fn discovery_only(&self) -> bool {
        if self.operation.as_deref() == Some("discover") {
            return true;
        }
        if self.operation.as_deref() == Some("run") {
            return false;
        }
        if self
            .arguments
            .as_object()
            .is_some_and(|object| !object.is_empty())
        {
            return false;
        }
        discovery_only_text(self.intent.as_deref())
            || discovery_only_text(self.reason.as_deref())
            || self
                .constraints
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(|value| value.eq_ignore_ascii_case("discover"))
    }
}

pub(super) fn is_orchestrated_execute_payload(params: &Value) -> bool {
    params.get("intent").is_some()
        || params.get("target").is_some()
        || params.get("arguments").is_some()
        || params.get("constraints").is_some()
        || (params.get("mode").is_none() && params.get("payload").is_some())
        || (params.get("mode").is_none()
            && params
                .as_object()
                .is_some_and(|object| object.keys().any(|key| !is_execute_wrapper_key(key))))
        || (params.get("mode").is_none() && params.as_object().is_some_and(Map::is_empty))
}

pub(in crate::domains::capability::operations) fn parse_orchestrated_execute_input(
    params: &Value,
) -> Result<OrchestratedExecuteInput, CapabilityError> {
    let mut corrections = Vec::new();
    let intent = string_field(params, "intent");
    let mut target_params = target_params_from_hint(params.get("target"))?;
    if target_params.is_none() {
        let mut direct_target = Map::new();
        for key in [
            "functionId",
            "implementationId",
            "contractId",
            "capabilityId",
        ] {
            if let Some(value) = params.get(key).cloned() {
                direct_target.insert(key.to_owned(), value);
            }
        }
        if !direct_target.is_empty() {
            let target = Value::Object(direct_target);
            if parse_target(&target).is_none() {
                return Err(CapabilityError::InvalidParams {
                    message: "top-level target fields must include a non-empty functionId, implementationId, capabilityId, or contractId".to_owned(),
                });
            }
            target_params = Some(target);
            corrections.push(correction_record(
                "top_level_target_to_target",
                "moved top-level target fields into target",
                1.0,
            ));
        }
    }
    let mut idempotency_key =
        string_field(params, "idempotencyKey").or_else(|| string_field(params, "idempotency_key"));
    let mut reason = string_field(params, "reason");
    let constraints = params
        .get("constraints")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if !constraints.is_object() {
        return Err(CapabilityError::InvalidParams {
            message: "execute.constraints must be an object when provided".to_owned(),
        });
    }

    let mut arguments = match (params.get("arguments"), params.get("payload")) {
        (Some(arguments), Some(payload)) if arguments != payload => {
            return Err(CapabilityError::InvalidParams {
                message: "execute received both arguments and payload with different values; use arguments only".to_owned(),
            });
        }
        (Some(arguments), _) => object_value(arguments, "execute.arguments")?,
        (None, Some(payload)) => {
            corrections.push(correction_record(
                "payload_to_arguments",
                "moved top-level payload into arguments",
                1.0,
            ));
            object_value(payload, "execute payload alias")?
        }
        (None, None) => json!({}),
    };
    let operation = string_field(params, "operation")
        .map(|value| normalize_execute_operation(&value))
        .transpose()?;

    normalize_nested_wrapper_shape(
        &mut arguments,
        &mut target_params,
        &mut idempotency_key,
        &mut reason,
        &mut corrections,
    )?;
    normalize_execute_self_target(&mut target_params, &mut corrections);
    normalize_flattened_target_arguments(params, &mut arguments, &mut corrections)?;

    Ok(OrchestratedExecuteInput {
        intent,
        target_params,
        arguments,
        constraints,
        operation,
        idempotency_key,
        reason,
        corrections,
    })
}

fn is_execute_wrapper_key(key: &str) -> bool {
    EXECUTE_WRAPPER_KEYS.contains(&key)
}

fn normalize_flattened_target_arguments(
    params: &Value,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) -> Result<(), CapabilityError> {
    let Some(params_object) = params.as_object() else {
        return Ok(());
    };
    let Some(arguments_object) = arguments.as_object_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "execute.arguments must be an object".to_owned(),
        });
    };

    let flattened = params_object
        .iter()
        .filter(|(key, _)| !is_execute_wrapper_key(key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect::<Vec<_>>();
    if flattened.is_empty() {
        return Ok(());
    }

    let mut moved = Vec::new();
    let mut deduped = Vec::new();
    for (key, value) in flattened {
        if let Some(existing) = arguments_object.get(&key) {
            if existing == &value {
                deduped.push(key);
                continue;
            }
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "execute received conflicting values for target argument '{key}' at the root and inside arguments; keep target arguments inside arguments"
                ),
            });
        }
        arguments_object.insert(key.clone(), value);
        moved.push(key);
    }
    if !moved.is_empty() {
        corrections.push(correction_record(
            "top_level_arguments_to_arguments",
            format!(
                "moved flattened target argument fields into arguments: {}",
                moved.join(", ")
            ),
            0.95,
        ));
    }
    if !deduped.is_empty() {
        corrections.push(correction_record(
            "duplicate_flattened_arguments_deduped",
            format!(
                "ignored duplicate flattened target argument fields already present in arguments: {}",
                deduped.join(", ")
            ),
            1.0,
        ));
    }
    Ok(())
}

fn object_value(value: &Value, label: &str) -> Result<Value, CapabilityError> {
    if value.is_object() {
        Ok(value.clone())
    } else {
        Err(CapabilityError::InvalidParams {
            message: format!("{label} must be an object"),
        })
    }
}

fn normalize_execute_operation(value: &str) -> Result<String, CapabilityError> {
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "" | "auto" => Ok("auto".to_owned()),
        "discover" | "discovery" | "inspect" | "describe" | "dry_run" | "dry-run" => {
            Ok("discover".to_owned())
        }
        "run" | "invoke" | "execute" => Ok("run".to_owned()),
        _ => Err(CapabilityError::InvalidParams {
            message: format!(
                "Unsupported execute.operation '{value}'; use discover, run, or omit it for auto"
            ),
        }),
    }
}

fn normalize_execute_self_target(target_params: &mut Option<Value>, corrections: &mut Vec<Value>) {
    let Some(target) = target_params.as_ref() else {
        return;
    };
    if !is_execute_self_target(target) {
        return;
    }
    *target_params = None;
    corrections.push(correction_record(
        "execute_self_target_removed",
        "removed target=capability::execute so execute can resolve the real capability from intent",
        1.0,
    ));
}

pub(super) fn normalize_live_resource_inventory_operation(input: &mut OrchestratedExecuteInput) {
    let Some(intent) = input.intent.as_deref() else {
        return;
    };
    if !intent_requests_resource_inventory(intent, &input.arguments)
        || explicit_discovery_only_request(intent)
    {
        return;
    }
    if input
        .target_params
        .as_ref()
        .is_some_and(|target| !target_is_resource_list(target))
    {
        return;
    }
    if input.operation.as_deref() == Some("run") {
        return;
    }
    input.operation = Some("run".to_owned());
    input.corrections.push(correction_record(
        "resource_inventory_discovery_to_read_only_run",
        "treated resource inventory discovery as a pure-read resource::list operation",
        1.0,
    ));
}

fn explicit_discovery_only_request(intent: &str) -> bool {
    let normalized = intent.to_ascii_lowercase();
    [
        "do not execute",
        "don't execute",
        "no child invocation",
        "without executing",
        "dry run",
        "dry-run",
        "required fields",
        "required arguments",
        "schema",
        "schemas",
    ]
    .iter()
    .any(|phrase| normalized.contains(phrase))
}

fn target_is_resource_list(target: &Value) -> bool {
    matches!(
        parse_target(target),
        Some(CapabilityTarget::Function(id))
            | Some(CapabilityTarget::Contract(id))
            | Some(CapabilityTarget::Capability(id))
            if id == "resource::list"
    )
}

fn is_execute_self_target(target: &Value) -> bool {
    match parse_target(target) {
        Some(CapabilityTarget::Function(id))
        | Some(CapabilityTarget::Contract(id))
        | Some(CapabilityTarget::Capability(id)) => id == "capability::execute",
        Some(CapabilityTarget::Implementation(id)) => {
            id == "function:capability::execute"
                || (id.starts_with("first_party.capability.v") && id.ends_with(".execute"))
        }
        None => false,
    }
}

fn discovery_only_text(value: Option<&str>) -> bool {
    let Some(value) = value else {
        return false;
    };
    let normalized = value.to_ascii_lowercase();
    let explicit_discovery_terms = [
        "discovery only",
        "required fields",
        "required arguments",
        "capability id",
        "capability ids",
        "schema",
        "schemas",
        "safe sequence",
        "dry run",
        "dry-run",
        "do not execute",
        "don't execute",
        "no child invocation",
        "without executing",
    ];
    if explicit_discovery_terms
        .iter()
        .any(|term| normalized.contains(term))
    {
        return true;
    }
    let words = normalized_intent_words(value);
    let asks_to_discover = words.contains("discover") || words.contains("discovery");
    let asks_to_use_result = [
        "use",
        "run",
        "invoke",
        "execute",
        "get",
        "read",
        "list",
        "query",
        "report",
        "show",
        "return",
        "fetch",
        "count",
        "current",
        "status",
        "summary",
        "available",
        "recent",
    ]
    .iter()
    .any(|word| words.contains(*word));
    asks_to_discover && !asks_to_use_result
}

fn target_params_from_hint(value: Option<&Value>) -> Result<Option<Value>, CapabilityError> {
    let Some(value) = value else {
        return Ok(None);
    };
    if let Some(target) = value
        .as_str()
        .map(str::trim)
        .filter(|target| !target.is_empty())
    {
        return Ok(Some(json!({ "capabilityId": target })));
    }
    if value.is_object() {
        if parse_target(value).is_none() {
            return Err(CapabilityError::InvalidParams {
                message: "execute.target object must include one of functionId, implementationId, capabilityId, or contractId".to_owned(),
            });
        }
        return Ok(Some(value.clone()));
    }
    Err(CapabilityError::InvalidParams {
        message: "execute.target must be a capability id string or target object".to_owned(),
    })
}

fn normalize_nested_wrapper_shape(
    arguments: &mut Value,
    target_params: &mut Option<Value>,
    idempotency_key: &mut Option<String>,
    reason: &mut Option<String>,
    corrections: &mut Vec<Value>,
) -> Result<(), CapabilityError> {
    let Some(object) = arguments.as_object_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "execute.arguments must be an object".to_owned(),
        });
    };

    if target_params.is_none() {
        let mut nested_target = Map::new();
        for key in [
            "functionId",
            "implementationId",
            "contractId",
            "capabilityId",
        ] {
            if let Some(value) = object.remove(key) {
                nested_target.insert(key.to_owned(), value);
            }
        }
        if !nested_target.is_empty() {
            let target = Value::Object(nested_target);
            if parse_target(&target).is_none() {
                return Err(CapabilityError::InvalidParams {
                    message: "wrapper target fields inside arguments were not valid strings"
                        .to_owned(),
                });
            }
            *target_params = Some(target);
            corrections.push(correction_record(
                "nested_target_to_target",
                "moved target fields out of arguments into target",
                1.0,
            ));
        }
    }

    if idempotency_key.is_none()
        && let Some(value) = object
            .remove("idempotencyKey")
            .or_else(|| object.remove("idempotency_key"))
        && let Some(value) = value
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
    {
        *idempotency_key = Some(value.to_owned());
        corrections.push(correction_record(
            "nested_idempotency_key_to_wrapper",
            "moved idempotencyKey out of arguments",
            1.0,
        ));
    }
    if reason.is_none()
        && let Some(value) = object.remove("reason")
        && let Some(value) = value
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
    {
        *reason = Some(value.to_owned());
        corrections.push(correction_record(
            "nested_reason_to_wrapper",
            "moved reason out of arguments",
            1.0,
        ));
    }

    if let Some(payload) = object.remove("payload") {
        if !payload.is_object() {
            return Err(CapabilityError::InvalidParams {
                message: "nested arguments.payload must be an object when supplied".to_owned(),
            });
        }
        if object.is_empty() {
            *arguments = payload;
            corrections.push(correction_record(
                "nested_payload_to_arguments",
                "moved nested payload into arguments",
                1.0,
            ));
        } else {
            object.insert("payload".to_owned(), payload);
        }
    }

    Ok(())
}
