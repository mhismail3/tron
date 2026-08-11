//! Closed worker-declared delivery effects.
//!
//! Workers may select a target and bounded provider-visible content only when
//! their immutable bundle declares `engineDeliveries: ["agent_delivery"]`.
//! Source identity, workspace, causality, authority, and result grants are
//! always derived by the kernel from the completing invocation.

use serde::Deserialize;
use serde_json::Value;

use super::types::{WorkerBundle, WorkerEngineDelivery};

pub(super) const MAX_AGENT_DELIVERY_EFFECTS: usize = 16;
const MAX_AGENT_DELIVERY_CONTENT_BYTES: usize = 40_000;
const MAX_AGENT_DELIVERY_TOTAL_BYTES: usize = 128_000;
const MAX_AGENT_DELIVERY_KEY_BYTES: usize = 64;
const MAX_AGENT_DELIVERY_MAILBOX_BYTES: usize = 64;

#[derive(Clone, Debug)]
pub(super) struct PreparedAgentDeliveryEffect {
    pub(super) deduplication_key: String,
    pub(super) target: PreparedAgentDeliveryTarget,
    pub(super) content: String,
    pub(super) intent: AgentDeliveryEffectIntent,
    pub(super) wake_policy: AgentDeliveryEffectWakePolicy,
    pub(super) boundary: AgentDeliveryEffectBoundary,
    pub(super) expires_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) enum PreparedAgentDeliveryTarget {
    Session {
        session_id: String,
    },
    Mailbox {
        scope: AgentDeliveryEffectMailboxScope,
        name: String,
    },
}

#[derive(Clone, Copy, Debug)]
pub(super) enum AgentDeliveryEffectMailboxScope {
    Workspace,
    Profile,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum AgentDeliveryEffectIntent {
    Information,
    Request,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum AgentDeliveryEffectWakePolicy {
    Passive,
    Wake,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum AgentDeliveryEffectBoundary {
    NextTurn,
    NextRun,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AgentDeliveryEffectOutput {
    deduplication_key: String,
    target: AgentDeliveryTargetOutput,
    content: String,
    #[serde(default)]
    intent: AgentDeliveryIntentOutput,
    #[serde(default)]
    wake_policy: AgentDeliveryWakePolicyOutput,
    #[serde(default)]
    boundary: AgentDeliveryBoundaryOutput,
    #[serde(default)]
    expires_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", deny_unknown_fields)]
enum AgentDeliveryTargetOutput {
    Session {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Mailbox {
        scope: AgentDeliveryMailboxScopeOutput,
        name: String,
    },
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AgentDeliveryMailboxScopeOutput {
    Workspace,
    Profile,
}

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AgentDeliveryIntentOutput {
    #[default]
    Information,
    Request,
}

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AgentDeliveryWakePolicyOutput {
    #[default]
    Passive,
    Wake,
}

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AgentDeliveryBoundaryOutput {
    #[default]
    NextTurn,
    NextRun,
}

pub(super) fn parse_agent_delivery_effects(
    bundle: &WorkerBundle,
    output: &Value,
) -> Result<Vec<PreparedAgentDeliveryEffect>, String> {
    let Some(raw) = output.get("agentDeliveries") else {
        return Ok(Vec::new());
    };
    if !bundle
        .engine_deliveries
        .contains(&WorkerEngineDelivery::AgentDelivery)
    {
        return Err(
            "worker output uses reserved agentDeliveries without declaring engineDeliveries agent_delivery"
                .to_owned(),
        );
    }
    let values = raw
        .as_array()
        .ok_or_else(|| "agentDeliveries must be an array".to_owned())?;
    if values.len() > MAX_AGENT_DELIVERY_EFFECTS {
        return Err(format!(
            "agentDeliveries may contain at most {MAX_AGENT_DELIVERY_EFFECTS} items"
        ));
    }

    let mut total_content_bytes = 0_usize;
    values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let effect: AgentDeliveryEffectOutput = serde_json::from_value(value.clone())
                .map_err(|error| format!("agentDeliveries[{index}] is invalid: {error}"))?;
            validate_key(&effect.deduplication_key, index)?;
            if effect.content.trim().is_empty()
                || effect.content.len() > MAX_AGENT_DELIVERY_CONTENT_BYTES
            {
                return Err(format!(
                    "agentDeliveries[{index}].content must contain 1..={MAX_AGENT_DELIVERY_CONTENT_BYTES} UTF-8 bytes"
                ));
            }
            total_content_bytes = total_content_bytes.saturating_add(effect.content.len());
            if total_content_bytes > MAX_AGENT_DELIVERY_TOTAL_BYTES {
                return Err(format!(
                    "agentDeliveries content exceeds {MAX_AGENT_DELIVERY_TOTAL_BYTES} total bytes"
                ));
            }
            let target = match effect.target {
                AgentDeliveryTargetOutput::Session { session_id } => {
                    validate_identifier(&session_id, "sessionId", index)?;
                    PreparedAgentDeliveryTarget::Session { session_id }
                }
                AgentDeliveryTargetOutput::Mailbox { scope, name } => {
                    if name.trim().is_empty() || name.len() > MAX_AGENT_DELIVERY_MAILBOX_BYTES {
                        return Err(format!(
                            "agentDeliveries[{index}].target.name must contain 1..={MAX_AGENT_DELIVERY_MAILBOX_BYTES} UTF-8 bytes"
                        ));
                    }
                    if matches!(effect.wake_policy, AgentDeliveryWakePolicyOutput::Wake) {
                        return Err(format!(
                            "agentDeliveries[{index}] cannot wake a logical mailbox"
                        ));
                    }
                    PreparedAgentDeliveryTarget::Mailbox {
                        scope: match scope {
                            AgentDeliveryMailboxScopeOutput::Workspace => {
                                AgentDeliveryEffectMailboxScope::Workspace
                            }
                            AgentDeliveryMailboxScopeOutput::Profile => {
                                AgentDeliveryEffectMailboxScope::Profile
                            }
                        },
                        name,
                    }
                }
            };
            if let Some(expires_at) = effect.expires_at.as_deref() {
                chrono::DateTime::parse_from_rfc3339(expires_at).map_err(|error| {
                    format!(
                        "agentDeliveries[{index}].expiresAt must be an RFC 3339 timestamp: {error}"
                    )
                })?;
            }
            Ok(PreparedAgentDeliveryEffect {
                deduplication_key: effect.deduplication_key,
                target,
                content: effect.content,
                intent: match effect.intent {
                    AgentDeliveryIntentOutput::Information => {
                        AgentDeliveryEffectIntent::Information
                    }
                    AgentDeliveryIntentOutput::Request => AgentDeliveryEffectIntent::Request,
                },
                wake_policy: match effect.wake_policy {
                    AgentDeliveryWakePolicyOutput::Passive => {
                        AgentDeliveryEffectWakePolicy::Passive
                    }
                    AgentDeliveryWakePolicyOutput::Wake => AgentDeliveryEffectWakePolicy::Wake,
                },
                boundary: match effect.boundary {
                    AgentDeliveryBoundaryOutput::NextTurn => AgentDeliveryEffectBoundary::NextTurn,
                    AgentDeliveryBoundaryOutput::NextRun => AgentDeliveryEffectBoundary::NextRun,
                },
                expires_at: effect.expires_at,
            })
        })
        .collect()
}

fn validate_key(value: &str, index: usize) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > MAX_AGENT_DELIVERY_KEY_BYTES {
        return Err(format!(
            "agentDeliveries[{index}].deduplicationKey must contain 1..={MAX_AGENT_DELIVERY_KEY_BYTES} UTF-8 bytes"
        ));
    }
    if value
        .chars()
        .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(format!(
            "agentDeliveries[{index}].deduplicationKey must not contain whitespace or control characters"
        ));
    }
    Ok(())
}

fn validate_identifier(value: &str, field: &str, index: usize) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > 256 {
        return Err(format!(
            "agentDeliveries[{index}].target.{field} must contain 1..=256 UTF-8 bytes"
        ));
    }
    if value.chars().any(char::is_control) {
        return Err(format!(
            "agentDeliveries[{index}].target.{field} must not contain control characters"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::domains::worker_kernel::types::{
        WorkerExecutionLimits, WorkerModelExposure, WorkerRouting, WorkerRunner,
    };

    fn bundle() -> WorkerBundle {
        WorkerBundle {
            schema_version: "tron.worker_bundle.v1".to_owned(),
            worker_id: Some("source".to_owned()),
            name: "Source".to_owned(),
            description: "Source".to_owned(),
            tool_name: None,
            model_exposure: WorkerModelExposure::Internal,
            tool_input_schema: None,
            agent_tools: None,
            agent_role: None,
            input_schema: json!({"type":"object"}),
            output_schema: json!({
                "type":"object",
                "properties":{"agentDeliveries":{"type":"array"}}
            }),
            runner: WorkerRunner::Command {
                command: vec!["true".to_owned()],
            },
            files: Default::default(),
            dependencies: Vec::new(),
            triggers: Vec::new(),
            secret_bindings: Vec::new(),
            smoke_tests: Vec::new(),
            health_checks: Vec::new(),
            provenance: Vec::new(),
            engine_hooks: Vec::new(),
            engine_deliveries: vec![WorkerEngineDelivery::AgentDelivery],
            client_actions: Vec::new(),
            client_deliveries: Vec::new(),
            worker_dispatch_routes: Vec::new(),
            routing: WorkerRouting::default(),
            execution_limits: WorkerExecutionLimits::default(),
            presentation: None,
        }
    }

    #[test]
    fn parses_closed_bounded_agent_delivery_effects() {
        let effects = parse_agent_delivery_effects(
            &bundle(),
            &json!({"agentDeliveries":[{
                "deduplicationKey":"result-ready",
                "target":{"kind":"session","sessionId":"session-1"},
                "content":"The requested result is ready.",
                "intent":"information",
                "wakePolicy":"wake",
                "boundary":"next_run"
            }]}),
        )
        .unwrap();
        assert_eq!(effects.len(), 1);
        assert!(matches!(
            effects[0].target,
            PreparedAgentDeliveryTarget::Session { .. }
        ));
    }

    #[test]
    fn rejects_undeclared_or_waking_mailbox_effects() {
        let mut undeclared = bundle();
        undeclared.engine_deliveries.clear();
        assert!(
            parse_agent_delivery_effects(&undeclared, &json!({"agentDeliveries":[]}))
                .unwrap_err()
                .contains("without declaring")
        );
        assert!(
            parse_agent_delivery_effects(
                &bundle(),
                &json!({"agentDeliveries":[{
                    "deduplicationKey":"mail",
                    "target":{"kind":"mailbox","scope":"profile","name":"updates"},
                    "content":"Ready",
                    "wakePolicy":"wake"
                }]})
            )
            .unwrap_err()
            .contains("cannot wake")
        );
    }
}
