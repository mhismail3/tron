//! Closed worker-to-engine session organization intent contract.
//!
//! A declaring `session_organization` worker may propose bounded replacement
//! labels, one group patch, and a reversible archive transition. Successful
//! completion admits the exact validated batch to the worker outbox; the
//! dispatcher later applies it to canonical `sessions.tags`/`ended_at`.
//! Omitted labels/group preserve canonical state and explicit null clears the
//! group. No arbitrary tag, delete, session content, or policy primitive is
//! expressible here.

use std::collections::HashSet;

use serde::de::Error as _;
use serde::ser::SerializeMap;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::types::{WorkerBundle, WorkerEngineHook};

pub(crate) const SESSION_ORGANIZATION_OUTPUT_FIELD: &str = "sessionOrganizationMutations";
const MAX_MUTATIONS: usize = 16;
const MAX_LABELS: usize = 12;
const MAX_SESSION_ID_BYTES: usize = 160;
const MAX_LABEL_CHARS: usize = 64;
const MAX_GROUP_CHARS: usize = 80;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SessionOrganizationArchiveAction {
    Preserve,
    Archive,
    Restore,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SessionOrganizationMutation {
    pub(crate) session_id: String,
    /// Replacement ordinary labels. Omission preserves the canonical value.
    pub(crate) labels: Option<Vec<String>>,
    /// Replacement group. Omission preserves the canonical value; an explicit
    /// JSON `null` clears it.
    pub(crate) group: Option<Option<String>>,
    pub(crate) archive_action: SessionOrganizationArchiveAction,
}

impl Serialize for SessionOrganizationMutation {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(
            2 + usize::from(self.labels.is_some()) + usize::from(self.group.is_some()),
        ))?;
        map.serialize_entry("sessionId", &self.session_id)?;
        if let Some(labels) = &self.labels {
            map.serialize_entry("labels", labels)?;
        }
        if let Some(group) = &self.group {
            map.serialize_entry("group", group)?;
        }
        map.serialize_entry("archiveAction", &self.archive_action)?;
        map.end()
    }
}

impl<'de> Deserialize<'de> for SessionOrganizationMutation {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        parse_mutation(&value).map_err(D::Error::custom)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PreparedSessionOrganizationIntent {
    pub(crate) mutations: Vec<SessionOrganizationMutation>,
}

pub(crate) fn session_organization_intent_for_bundle(
    bundle: &WorkerBundle,
    output: &Value,
) -> Result<Option<PreparedSessionOrganizationIntent>, String> {
    let Some(value) = output.get(SESSION_ORGANIZATION_OUTPUT_FIELD) else {
        return Ok(None);
    };
    if !bundle
        .engine_hooks
        .contains(&WorkerEngineHook::SessionOrganization)
    {
        return Err(format!(
            "{SESSION_ORGANIZATION_OUTPUT_FIELD} requires engineHooks to declare session_organization"
        ));
    }
    if !bundle
        .output_schema
        .get("properties")
        .and_then(Value::as_object)
        .is_some_and(|properties| properties.contains_key(SESSION_ORGANIZATION_OUTPUT_FIELD))
    {
        return Err(format!(
            "outputSchema must explicitly declare the reserved {SESSION_ORGANIZATION_OUTPUT_FIELD} field"
        ));
    }
    let values = value
        .as_array()
        .ok_or_else(|| format!("invalid {SESSION_ORGANIZATION_OUTPUT_FIELD}: expected an array"))?;
    if values.is_empty() || values.len() > MAX_MUTATIONS {
        return Err(format!(
            "{SESSION_ORGANIZATION_OUTPUT_FIELD} must contain 1 to {MAX_MUTATIONS} mutations"
        ));
    }
    let mutations = values
        .iter()
        .map(parse_mutation)
        .collect::<Result<Vec<_>, _>>()?;
    let mut session_ids = HashSet::new();
    for mutation in &mutations {
        validate_text(
            &mutation.session_id,
            "sessionId",
            MAX_SESSION_ID_BYTES,
            true,
        )?;
        if !session_ids.insert(mutation.session_id.as_str()) {
            return Err(format!(
                "{SESSION_ORGANIZATION_OUTPUT_FIELD} contains duplicate sessionId '{}'",
                mutation.session_id
            ));
        }
        if let Some(replacement_labels) = &mutation.labels {
            if replacement_labels.len() > MAX_LABELS {
                return Err(format!(
                    "session organization labels may contain at most {MAX_LABELS} values"
                ));
            }
            let mut labels = HashSet::new();
            for label in replacement_labels {
                validate_text(label, "label", MAX_LABEL_CHARS, false)?;
                if is_reserved_tag(label) {
                    return Err(
                        "session organization labels cannot use reserved Tron prefixes".into(),
                    );
                }
                if !labels.insert(label.as_str()) {
                    return Err("session organization labels must be unique".into());
                }
            }
        }
        if let Some(Some(group)) = &mutation.group {
            validate_text(group, "group", MAX_GROUP_CHARS, false)?;
            if is_reserved_tag(group) {
                return Err("session organization group cannot use reserved Tron prefixes".into());
            }
        }
    }
    Ok(Some(PreparedSessionOrganizationIntent { mutations }))
}

fn parse_mutation(value: &Value) -> Result<SessionOrganizationMutation, String> {
    let object = value.as_object().ok_or_else(|| {
        format!("invalid {SESSION_ORGANIZATION_OUTPUT_FIELD}: each mutation must be an object")
    })?;
    reject_unknown_fields(object)?;
    let session_id = object
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            format!("invalid {SESSION_ORGANIZATION_OUTPUT_FIELD}: sessionId must be a string")
        })?
        .to_owned();
    let archive_action = object
        .get("archiveAction")
        .cloned()
        .ok_or_else(|| {
            format!("invalid {SESSION_ORGANIZATION_OUTPUT_FIELD}: archiveAction is required")
        })
        .and_then(|value| {
            serde_json::from_value(value).map_err(|error| {
                format!("invalid {SESSION_ORGANIZATION_OUTPUT_FIELD} archiveAction: {error}")
            })
        })?;
    let labels = object
        .get("labels")
        .map(|value| {
            serde_json::from_value::<Vec<String>>(value.clone()).map_err(|error| {
                format!("invalid {SESSION_ORGANIZATION_OUTPUT_FIELD} labels: {error}")
            })
        })
        .transpose()?;
    let group = match object.get("group") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(Value::String(value)) => Some(Some(value.clone())),
        Some(_) => {
            return Err(format!(
                "invalid {SESSION_ORGANIZATION_OUTPUT_FIELD}: group must be a string or null"
            ));
        }
    };
    Ok(SessionOrganizationMutation {
        session_id,
        labels,
        group,
        archive_action,
    })
}

fn reject_unknown_fields(object: &Map<String, Value>) -> Result<(), String> {
    for field in object.keys() {
        if !matches!(
            field.as_str(),
            "sessionId" | "labels" | "group" | "archiveAction"
        ) {
            return Err(format!(
                "invalid {SESSION_ORGANIZATION_OUTPUT_FIELD}: unknown field '{field}'"
            ));
        }
    }
    Ok(())
}

fn validate_text(
    value: &str,
    field: &str,
    maximum: usize,
    bytes_not_chars: bool,
) -> Result<(), String> {
    let trimmed = value.trim();
    let length = if bytes_not_chars {
        trimmed.len()
    } else {
        trimmed.chars().count()
    };
    if trimmed != value || length == 0 || length > maximum || value.chars().any(char::is_control) {
        let unit = if bytes_not_chars {
            "bytes"
        } else {
            "characters"
        };
        return Err(format!(
            "session organization {field} must contain 1 to {maximum} {unit} without surrounding whitespace or controls"
        ));
    }
    Ok(())
}

fn is_reserved_tag(value: &str) -> bool {
    value.starts_with("tron.system.") || value.starts_with("tron.organization.")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::worker_kernel::types::*;
    use std::collections::BTreeMap;

    fn bundle() -> WorkerBundle {
        WorkerBundle {
            schema_version: BUNDLE_SCHEMA.to_owned(),
            worker_id: Some("session-organizer".to_owned()),
            name: "Session Organizer".to_owned(),
            description: "Organizes sessions".to_owned(),
            tool_name: Some("worker_sessions".to_owned()),
            model_exposure: WorkerModelExposure::Direct,
            tool_input_schema: Some(serde_json::json!({"type":"object"})),
            agent_tools: None,
            input_schema: serde_json::json!({"type":"object"}),
            output_schema: serde_json::json!({
                "type":"object",
                "properties":{"sessionOrganizationMutations":{"type":"array"}}
            }),
            runner: WorkerRunner::Command {
                command: vec!["python3".to_owned(), "worker.py".to_owned()],
            },
            files: BTreeMap::new(),
            dependencies: Vec::new(),
            triggers: Vec::new(),
            secret_bindings: Vec::new(),
            smoke_tests: Vec::new(),
            health_checks: Vec::new(),
            provenance: Vec::new(),
            engine_hooks: vec![WorkerEngineHook::SessionOrganization],
            engine_deliveries: Vec::new(),
            client_actions: Vec::new(),
            client_deliveries: Vec::new(),
            worker_dispatch_routes: Vec::new(),
            routing: WorkerRouting::default(),
            execution_limits: WorkerExecutionLimits::default(),
            presentation: None,
        }
    }

    #[test]
    fn accepts_only_closed_reversible_organization_mutations() {
        let valid = serde_json::json!({
            "sessionOrganizationMutations":[{
                "sessionId":"session_123",
                "labels":["Work","Urgent"],
                "group":"Projects",
                "archiveAction":"preserve"
            }]
        });
        let parsed = session_organization_intent_for_bundle(&bundle(), &valid)
            .unwrap()
            .unwrap();
        assert_eq!(parsed.mutations.len(), 1);
        assert_eq!(
            parsed.mutations[0].labels.as_deref(),
            Some(["Work".to_owned(), "Urgent".to_owned()].as_slice())
        );
        assert_eq!(parsed.mutations[0].group, Some(Some("Projects".to_owned())));

        let preserve_then_clear = serde_json::json!({
            "sessionOrganizationMutations":[
                {"sessionId":"session_123","archiveAction":"archive"},
                {
                    "sessionId":"session_456",
                    "group":null,
                    "archiveAction":"preserve"
                }
            ]
        });
        let parsed = session_organization_intent_for_bundle(&bundle(), &preserve_then_clear)
            .unwrap()
            .unwrap();
        assert_eq!(parsed.mutations[0].labels, None);
        assert_eq!(parsed.mutations[0].group, None);
        assert_eq!(parsed.mutations[1].group, Some(None));
        let round_trip = serde_json::from_str::<Vec<SessionOrganizationMutation>>(
            &serde_json::to_string(&parsed.mutations).unwrap(),
        )
        .unwrap();
        assert_eq!(round_trip[1].group, Some(None));

        let reserved = serde_json::json!({
            "sessionOrganizationMutations":[{
                "sessionId":"session_123",
                "labels":["tron.system.worker-session"],
                "group":null,
                "archiveAction":"archive"
            }]
        });
        assert!(
            session_organization_intent_for_bundle(&bundle(), &reserved)
                .unwrap_err()
                .contains("reserved")
        );
    }
}
