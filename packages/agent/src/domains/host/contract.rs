//! Closed contracts for Tron's minimal trusted-host surface.

use serde_json::{Value, json};

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    DelegationPolicy, EffectClass, FunctionDefinition, IdempotencyContract, ModelToolAudience,
    RiskLevel, WorkspaceEffect,
};

const OWNER: &str = "host";
pub(crate) const READ_FUNCTION: &str = "host::read";
pub(crate) const WRITE_FUNCTION: &str = "host::write";
pub(crate) const EDIT_FUNCTION: &str = "host::edit";
pub(crate) const BASH_FUNCTION: &str = "host::bash";

pub(crate) fn function_definitions() -> crate::engine::Result<Vec<FunctionDefinition>> {
    Ok(vec![
        model_contract(
            READ_FUNCTION,
            EffectClass::PureRead,
            RiskLevel::Low,
            read_request_schema(),
            read_response_schema(),
            "Read one bounded UTF-8 file or list one directory. Use Bash for search, Git, or multi-file composition.",
            "read",
            10,
        )?
        .with_workspace_effect(WorkspaceEffect::Read),
        model_contract(
            WRITE_FUNCTION,
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            json!({
                "type":"object","additionalProperties":false,
                "required":["path","content"],
                "properties":{
                    "path":{"type":"string","minLength":1},
                    "content":{"type":"string","maxLength":4194304},
                    "createParents":{"type":"boolean"},
                    "expectedSha256":expected_sha256_schema(true)
                }
            }),
            mutation_response_schema(false),
            "Atomically publish a complete UTF-8 file. Supply expectedSha256 after reading when overwriting concurrent work would be unsafe.",
            "write",
            20,
        )?
        .with_workspace_effect(WorkspaceEffect::ScopedWrite),
        model_contract(
            EDIT_FUNCTION,
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            json!({
                "type":"object","additionalProperties":false,
                "required":["path","replacements"],
                "properties":{
                    "path":{"type":"string","minLength":1},
                    "expectedSha256":expected_sha256_schema(false),
                    "replacements":{
                        "type":"array","minItems":1,"maxItems":128,
                        "items":{
                            "type":"object","additionalProperties":false,
                            "required":["oldText","newText"],
                            "properties":{
                                "oldText":{"type":"string","minLength":1},
                                "newText":{"type":"string"},
                                "expectedOccurrences":{"type":"integer","minimum":1,"maximum":10000}
                            }
                        }
                    }
                }
            }),
            mutation_response_schema(true),
            "Apply bounded exact-text replacements to one UTF-8 file and publish atomically only when every occurrence and optional checksum still match.",
            "edit",
            30,
        )?
        .with_workspace_effect(WorkspaceEffect::ScopedWrite),
        model_contract(
            BASH_FUNCTION,
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
            json!({
                "type":"object","additionalProperties":false,
                "required":["script"],
                "properties":{
                    "script":{"type":"string","minLength":1,"maxLength":1048576},
                    "cwd":{"type":"string"},
                    "stdin":{},
                    "timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}
                }
            }),
            json!({
                "type":"object","additionalProperties":false,
                "required":["script","cwd","status","success","stdout","stderr","stdoutTruncated","stderrTruncated"],
                "properties":{
                    "script":{"type":"string"},"cwd":{"type":"string"},"status":{},
                    "success":{"type":"boolean"},"stdout":{"type":"string"},"stderr":{"type":"string"},
                    "stdoutTruncated":{"type":"boolean"},"stderrTruncated":{"type":"boolean"}
                }
            }),
            "Run a Bash script with the Tron user's ordinary host authority and bounded stdin, output, deadline, and process-tree custody. This is an explicit trusted-host escape, not a sandbox.",
            "bash",
            40,
        )?
        .with_workspace_effect(WorkspaceEffect::ArbitraryProcess),
    ])
}

#[allow(clippy::too_many_arguments)]
fn model_contract(
    function: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
    request: Value,
    response: Value,
    description: &'static str,
    model_name: &'static str,
    order: u16,
) -> crate::engine::Result<FunctionDefinition> {
    let mut contract = FunctionContract::new(function, OWNER, effect, risk)
        .request_schema(request)
        .response_schema(response)
        .description(description)
        .delegation_policy(DelegationPolicy::Inherit)
        .model_tool(model_name, ModelToolAudience::Ordinary, order, "host");
    if effect.requires_idempotency() {
        contract = contract.idempotency(IdempotencyContract::session());
    }
    contract.build()
}

fn read_request_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["path"],
        "properties":{
            "path":{"type":"string","minLength":1},
            "maxBytes":{"type":"integer","minimum":1,"maximum":4194304},
            "maxEntries":{"type":"integer","minimum":1,"maximum":5000}
        }
    })
}

fn read_response_schema() -> Value {
    json!({
        "oneOf":[
            {
                "type":"object","additionalProperties":false,
                "required":["kind","path","content","bytes","retainedBytes","truncated"],
                "properties":{
                    "kind":{"const":"file"},"path":{"type":"string"},"content":{"type":"string"},
                    "bytes":{},"retainedBytes":{"type":"integer"},"truncated":{"type":"boolean"}
                }
            },
            {
                "type":"object","additionalProperties":false,
                "required":["kind","path","entries","visitedEntries","resultLimitReached","walkLimitReached","truncated"],
                "properties":{
                    "kind":{"const":"directory"},"path":{"type":"string"},"entries":{"type":"array"},
                    "visitedEntries":{"type":"integer"},"resultLimitReached":{"type":"boolean"},
                    "walkLimitReached":{"type":"boolean"},"truncated":{"type":"boolean"}
                }
            }
        ]
    })
}

fn mutation_response_schema(edit: bool) -> Value {
    let mut properties = serde_json::Map::from_iter([
        ("path".to_owned(), json!({"type":"string"})),
        ("bytes".to_owned(), json!({"type":"integer"})),
        ("changed".to_owned(), json!({"type":"boolean"})),
        ("previousSha256".to_owned(), json!({})),
        ("sha256".to_owned(), json!({"type":"string"})),
    ]);
    let mut required = vec!["path", "bytes", "changed", "previousSha256", "sha256"];
    if edit {
        properties.insert("replacementsApplied".to_owned(), json!({"type":"integer"}));
        required.push("replacementsApplied");
    } else {
        properties.insert("written".to_owned(), json!({"type":"boolean"}));
        required.push("written");
    }
    json!({
        "type":"object","additionalProperties":false,
        "required":required,"properties":properties
    })
}

fn expected_sha256_schema(allow_absent: bool) -> Value {
    let pattern = if allow_absent {
        "^(?:absent|(?:sha256:)?[0-9A-Fa-f]{64})$"
    } else {
        "^(?:sha256:)?[0-9A-Fa-f]{64}$"
    };
    json!({"type":"string","pattern":pattern})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_surface_is_exactly_four_general_primitives() {
        let definitions = function_definitions().unwrap();
        let names = definitions
            .iter()
            .map(|definition| {
                definition
                    .model_tool
                    .as_ref()
                    .expect("model tool")
                    .name
                    .as_str()
            })
            .collect::<Vec<_>>();
        assert_eq!(names, ["read", "write", "edit", "bash"]);
        assert!(definitions.iter().all(|definition| {
            definition.delegation_policy == DelegationPolicy::Inherit
                && matches!(
                    definition.model_tool.as_ref().map(|tool| &tool.audience),
                    Some(ModelToolAudience::Ordinary)
                )
        }));
    }

    #[test]
    fn host_requests_and_responses_are_closed() {
        for definition in function_definitions().unwrap() {
            assert_eq!(
                definition.request_schema.as_ref().unwrap()["additionalProperties"],
                false
            );
            let response = definition.response_schema.as_ref().unwrap();
            let closed = response["additionalProperties"] == false
                || response["oneOf"].as_array().is_some_and(|branches| {
                    branches
                        .iter()
                        .all(|branch| branch["additionalProperties"] == false)
                });
            assert!(closed, "{} response must be closed", definition.id);
        }
    }
}
