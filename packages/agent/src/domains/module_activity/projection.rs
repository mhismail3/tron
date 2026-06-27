use std::collections::BTreeMap;

use chrono::DateTime;
use serde::Serialize;
use serde_json::Value;

use crate::engine::{EngineResource, EngineResourceVersion};

use super::contract;

const TEXT_BYTES: usize = 180;
const LABEL_BYTES: usize = 80;
const MAX_LABELS: usize = 8;
const MAX_RESOURCE_SUMMARIES: usize = 10;
const MAX_TIMELINE: usize = 100;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ActivityStatus {
    Active,
    Waiting,
    Blocked,
    Ready,
    Recorded,
}

impl ActivityStatus {
    fn rank(&self) -> u8 {
        match self {
            Self::Blocked => 0,
            Self::Waiting => 1,
            Self::Active => 2,
            Self::Ready => 3,
            Self::Recorded => 4,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ModuleActivityItem {
    id: String,
    resource_id: String,
    resource_kind: String,
    status: ActivityStatus,
    state: String,
    title: String,
    detail: String,
    authority_labels: Vec<String>,
    touched_resources: Vec<ResourceTouchSummary>,
    rollback_status: GateStatus,
    quarantine_status: GateStatus,
    runtime_authorization_status: GateStatus,
    updated_at: String,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct GateStatus {
    label: String,
    state: String,
    blocked: bool,
    waiting: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResourceTouchSummary {
    label: String,
    total: usize,
    truncated: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ModuleActivityProjection {
    schema_version: &'static str,
    operation: &'static str,
    summary: ActivitySummary,
    timeline: Vec<ModuleActivityItem>,
    blocked: Vec<ModuleActivityItem>,
    waiting: Vec<ModuleActivityItem>,
    resources: Vec<ResourceKindSummary>,
    projection: ProjectionPolicy,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActivitySummary {
    total: usize,
    active: usize,
    waiting: usize,
    blocked: usize,
    ready: usize,
    recorded: usize,
    title: String,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResourceKindSummary {
    kind: String,
    total: usize,
    active: usize,
    waiting: usize,
    blocked: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectionPolicy {
    allowlist: &'static str,
    server_owned_truth: bool,
    metadata_only: bool,
    raw_payloads_returned: bool,
    raw_commands_returned: bool,
    raw_logs_returned: bool,
    file_contents_returned: bool,
    absolute_paths_returned: bool,
    grant_ids_returned: bool,
    authority_ids_returned: bool,
    trace_ids_returned: bool,
    invocation_ids_returned: bool,
    token_like_material_returned: bool,
    bounded_items: bool,
}

impl ModuleActivityProjection {
    pub(crate) fn from_items(mut items: Vec<ModuleActivityItem>, limit: usize) -> Self {
        items.sort_by(|left, right| {
            left.status
                .rank()
                .cmp(&right.status.rank())
                .then_with(|| right.updated_at.cmp(&left.updated_at))
                .then_with(|| left.resource_kind.cmp(&right.resource_kind))
        });
        let timeline = items
            .into_iter()
            .take(limit.min(MAX_TIMELINE))
            .collect::<Vec<_>>();
        let summary = ActivitySummary::from_items(&timeline);
        let blocked = timeline
            .iter()
            .filter(|item| item.status == ActivityStatus::Blocked)
            .take(MAX_RESOURCE_SUMMARIES)
            .cloned()
            .collect();
        let waiting = timeline
            .iter()
            .filter(|item| item.status == ActivityStatus::Waiting)
            .take(MAX_RESOURCE_SUMMARIES)
            .cloned()
            .collect();
        let resources = resource_summaries(&timeline);
        Self {
            schema_version: contract::SCHEMA_VERSION,
            operation: "module_activity_overview",
            summary,
            timeline,
            blocked,
            waiting,
            resources,
            projection: ProjectionPolicy {
                allowlist: "module_activity_cockpit_metadata_redacted_v1",
                server_owned_truth: true,
                metadata_only: true,
                raw_payloads_returned: false,
                raw_commands_returned: false,
                raw_logs_returned: false,
                file_contents_returned: false,
                absolute_paths_returned: false,
                grant_ids_returned: false,
                authority_ids_returned: false,
                trace_ids_returned: false,
                invocation_ids_returned: false,
                token_like_material_returned: false,
                bounded_items: true,
            },
        }
    }

    pub(crate) fn into_value(self) -> Value {
        serde_json::to_value(self).expect("module activity projection must serialize")
    }
}

impl ActivitySummary {
    fn from_items(items: &[ModuleActivityItem]) -> Self {
        let mut summary = Self {
            total: items.len(),
            title: "No module work".to_owned(),
            detail: "No module-plane activity has been recorded.".to_owned(),
            ..Self::default()
        };
        for item in items {
            match item.status {
                ActivityStatus::Active => summary.active += 1,
                ActivityStatus::Waiting => summary.waiting += 1,
                ActivityStatus::Blocked => summary.blocked += 1,
                ActivityStatus::Ready => summary.ready += 1,
                ActivityStatus::Recorded => summary.recorded += 1,
            }
        }
        if summary.blocked > 0 {
            summary.title = "Module work blocked".to_owned();
            summary.detail = format!("{} blocked module activities need review.", summary.blocked);
        } else if summary.waiting > 0 {
            summary.title = "Module work waiting".to_owned();
            summary.detail = format!("{} module activities are pending review.", summary.waiting);
        } else if summary.active > 0 {
            summary.title = "Module work active".to_owned();
            summary.detail = format!("{} module runtime activities are active.", summary.active);
        } else if summary.total > 0 {
            summary.title = "Module work recorded".to_owned();
            summary.detail = format!("{} module activity records are available.", summary.total);
        }
        summary
    }
}

impl ModuleActivityItem {
    pub(crate) fn from_resource(
        resource: &EngineResource,
        version: &EngineResourceVersion,
        payload: &Value,
    ) -> Self {
        let state = projected_state(resource, payload);
        let rollback_status = rollback_status(resource, payload);
        let quarantine_status = quarantine_status(resource, payload);
        let runtime_authorization_status = runtime_authorization_status(resource, payload);
        let status = derive_status(
            &resource.kind,
            &state,
            &rollback_status,
            &quarantine_status,
            &runtime_authorization_status,
            payload,
        );
        Self {
            id: format!(
                "{}:{}",
                safe_identifier(&resource.kind),
                safe_identifier(&version.version_id)
            ),
            resource_id: safe_identifier(&resource.resource_id),
            resource_kind: safe_identifier(&resource.kind),
            status,
            state,
            title: title_for(resource, payload),
            detail: detail_for(resource, payload),
            authority_labels: authority_labels(payload),
            touched_resources: touched_resources(payload),
            rollback_status,
            quarantine_status,
            runtime_authorization_status,
            updated_at: timestamp(resource, payload),
        }
    }
}

fn derive_status(
    kind: &str,
    state: &str,
    rollback: &GateStatus,
    quarantine: &GateStatus,
    runtime_authorization: &GateStatus,
    payload: &Value,
) -> ActivityStatus {
    let normalized_state = normalize(state);
    if quarantine.blocked || rollback.blocked || runtime_authorization.blocked {
        return ActivityStatus::Blocked;
    }
    if matches!(
        normalized_state.as_str(),
        "quarantined" | "rolledback" | "failed" | "rejected" | "denied" | "blocked"
    ) {
        return ActivityStatus::Blocked;
    }
    if rollback.waiting || runtime_authorization.waiting {
        return ActivityStatus::Waiting;
    }
    if matches!(
        normalized_state.as_str(),
        "pendingreview" | "pending" | "requested" | "awaitingapproval" | "reviewrequired"
    ) {
        return ActivityStatus::Waiting;
    }
    if kind == crate::engine::MODULE_RUNTIME_STATE_KIND
        && matches!(
            normalized_state.as_str(),
            "running" | "active" | "supervising" | "started"
        )
    {
        return ActivityStatus::Active;
    }
    if payload
        .pointer("/supervision/state")
        .and_then(Value::as_str)
        .is_some_and(|value| normalize(value) == "running")
    {
        return ActivityStatus::Active;
    }
    if matches!(
        normalized_state.as_str(),
        "passed" | "approved" | "installcandidate" | "enabled" | "ready" | "active"
    ) {
        return ActivityStatus::Ready;
    }
    ActivityStatus::Recorded
}

fn projected_state(resource: &EngineResource, payload: &Value) -> String {
    first_string(
        payload,
        &[
            "/state",
            "/lifecycle/state",
            "/validation/status",
            "/decision/state",
            "/transition/to",
            "/supervision/state",
        ],
    )
    .unwrap_or_else(|| resource.lifecycle.clone())
    .pipe(|value| safe_text(&value, LABEL_BYTES))
}

fn title_for(resource: &EngineResource, payload: &Value) -> String {
    first_string(
        payload,
        &[
            "/identity/title",
            "/title",
            "/runtime/label",
            "/dependency/name",
            "/transition/action",
        ],
    )
    .map(|value| safe_text(&value, TEXT_BYTES))
    .filter(|value| !value.is_empty())
    .unwrap_or_else(|| title_from_kind(&resource.kind).to_owned())
}

fn detail_for(resource: &EngineResource, payload: &Value) -> String {
    first_string(
        payload,
        &[
            "/identity/summary",
            "/summary",
            "/reason",
            "/needs/rationale",
            "/decision/reason",
            "/transition/reason",
        ],
    )
    .map(|value| safe_text(&value, TEXT_BYTES))
    .filter(|value| !value.is_empty())
    .unwrap_or_else(|| format!("{} {}", title_from_kind(&resource.kind), resource.lifecycle))
}

fn rollback_status(_resource: &EngineResource, payload: &Value) -> GateStatus {
    let state = first_string(payload, &["/rollback/status", "/rollback/readiness"])
        .unwrap_or_else(|| "not_declared".to_owned());
    let normalized = normalize(&state);
    GateStatus {
        label: "Rollback".to_owned(),
        state: safe_text(&state, LABEL_BYTES),
        blocked: matches!(normalized.as_str(), "blocked" | "missing" | "notready"),
        waiting: matches!(
            normalized.as_str(),
            "pending" | "pendingreview" | "reviewrequired"
        ),
    }
}

fn quarantine_status(resource: &EngineResource, payload: &Value) -> GateStatus {
    let state = first_string(payload, &["/quarantine/status"]).unwrap_or_else(|| {
        if normalize(&resource.lifecycle) == "quarantined" {
            "quarantined".to_owned()
        } else {
            "clear".to_owned()
        }
    });
    let normalized = normalize(&state);
    GateStatus {
        label: "Quarantine".to_owned(),
        state: safe_text(&state, LABEL_BYTES),
        blocked: normalized == "quarantined",
        waiting: false,
    }
}

fn runtime_authorization_status(_resource: &EngineResource, payload: &Value) -> GateStatus {
    let fail_closed = payload
        .pointer("/runtimeAuthorization/failClosed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let enabled = payload
        .pointer("/runtimeAuthorization/enabledAllowsRuntime")
        .and_then(Value::as_bool);
    let disabled_denied = payload
        .pointer("/runtimeAuthorization/disabledDenied")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let quarantined_denied = payload
        .pointer("/runtimeAuthorization/quarantinedDenied")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let rolled_back_denied = payload
        .pointer("/runtimeAuthorization/rolledBackDenied")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let blocked = fail_closed
        && enabled == Some(false)
        && (disabled_denied || quarantined_denied || rolled_back_denied);
    GateStatus {
        label: "Runtime authorization".to_owned(),
        state: if blocked {
            "denied".to_owned()
        } else if enabled == Some(true) {
            "allowed".to_owned()
        } else {
            "not_declared".to_owned()
        },
        blocked,
        waiting: false,
    }
}

fn authority_labels(payload: &Value) -> Vec<String> {
    let Some(authority) = payload.get("authority").and_then(Value::as_object) else {
        return vec!["server-owned projection".to_owned()];
    };
    let mut labels = Vec::new();
    push_bool_label(authority, &mut labels, "grantRedacted", "grant redacted");
    push_bool_label(
        authority,
        &mut labels,
        "derivedRuntimeGrantRequired",
        "derived runtime grant required",
    );
    push_bool_label(
        authority,
        &mut labels,
        "lifecycleAuthorizationRequired",
        "lifecycle authorization required",
    );
    push_bool_label(
        authority,
        &mut labels,
        "approvalEvidenceOnly",
        "approval evidence only",
    );
    if authority
        .get("wildcardGrantsAllowed")
        .and_then(Value::as_bool)
        == Some(false)
    {
        labels.push("no wildcard grants".to_owned());
    }
    if labels.is_empty() {
        labels.push("server-owned projection".to_owned());
    }
    labels.truncate(MAX_LABELS);
    labels
}

fn push_bool_label(
    map: &serde_json::Map<String, Value>,
    labels: &mut Vec<String>,
    key: &str,
    label: &str,
) {
    if map.get(key).and_then(Value::as_bool) == Some(true) {
        labels.push(label.to_owned());
    }
}

fn touched_resources(payload: &Value) -> Vec<ResourceTouchSummary> {
    let mut summaries = Vec::new();
    collect_refs(
        payload,
        &mut summaries,
        "module refs",
        "/subjectRefs/modules",
    );
    collect_refs(
        payload,
        &mut summaries,
        "proposal refs",
        "/subjectRefs/proposals",
    );
    collect_refs(payload, &mut summaries, "source refs", "/refs/source");
    collect_refs(payload, &mut summaries, "doc refs", "/refs/docs");
    collect_refs(payload, &mut summaries, "test refs", "/refs/tests");
    collect_refs(payload, &mut summaries, "evidence refs", "/evidenceRefs");
    collect_refs(payload, &mut summaries, "trace refs", "/traceRefs");
    collect_refs(payload, &mut summaries, "replay refs", "/replayRefs");
    collect_refs(payload, &mut summaries, "input refs", "/inputRefs");
    collect_refs(
        payload,
        &mut summaries,
        "output refs",
        "/outputArtifactRefs",
    );
    collect_refs(
        payload,
        &mut summaries,
        "rollback proof refs",
        "/rollback/proofRefs",
    );
    summaries.truncate(MAX_LABELS);
    summaries
}

fn collect_refs(
    payload: &Value,
    summaries: &mut Vec<ResourceTouchSummary>,
    label: &str,
    pointer: &str,
) {
    let Some(Value::Array(items)) = payload.pointer(pointer) else {
        return;
    };
    if !items.is_empty() {
        summaries.push(ResourceTouchSummary {
            label: label.to_owned(),
            total: items.len(),
            truncated: items.len() > MAX_RESOURCE_SUMMARIES,
        });
    }
}

fn timestamp(resource: &EngineResource, payload: &Value) -> String {
    first_string(payload, &["/updatedAt", "/createdAt"])
        .filter(|value| DateTime::parse_from_rfc3339(value).is_ok())
        .unwrap_or_else(|| {
            resource
                .updated_at
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
        })
}

fn resource_summaries(items: &[ModuleActivityItem]) -> Vec<ResourceKindSummary> {
    let mut by_kind: BTreeMap<String, ResourceKindSummary> = BTreeMap::new();
    for item in items {
        let summary = by_kind
            .entry(item.resource_kind.clone())
            .or_insert_with(|| ResourceKindSummary {
                kind: item.resource_kind.clone(),
                total: 0,
                active: 0,
                waiting: 0,
                blocked: 0,
            });
        summary.total += 1;
        match item.status {
            ActivityStatus::Active => summary.active += 1,
            ActivityStatus::Waiting => summary.waiting += 1,
            ActivityStatus::Blocked => summary.blocked += 1,
            ActivityStatus::Ready | ActivityStatus::Recorded => {}
        }
    }
    by_kind.into_values().collect()
}

fn first_string(payload: &Value, pointers: &[&str]) -> Option<String> {
    pointers
        .iter()
        .filter_map(|pointer| payload.pointer(pointer).and_then(Value::as_str))
        .find(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

fn title_from_kind(kind: &str) -> &str {
    match kind {
        crate::engine::MODULE_MANIFEST_KIND => "Module manifest",
        crate::engine::MODULE_PROPOSAL_KIND => "Module proposal",
        crate::engine::MODULE_VALIDATION_REPORT_KIND => "Validation report",
        crate::engine::MODULE_INSTALL_REQUEST_KIND => "Install request",
        crate::engine::MODULE_INSTALL_DECISION_KIND => "Install decision",
        crate::engine::MODULE_DEPENDENCY_REQUEST_KIND => "Dependency request",
        crate::engine::MODULE_DEPENDENCY_DECISION_KIND => "Dependency decision",
        crate::engine::MODULE_DEPENDENCY_POLICY_KIND => "Dependency policy",
        crate::engine::MODULE_LIFECYCLE_STATE_KIND => "Lifecycle state",
        crate::engine::MODULE_RUNTIME_STATE_KIND => "Runtime state",
        _ => "Module activity",
    }
}

fn safe_identifier(value: &str) -> String {
    safe_text(value, LABEL_BYTES)
}

fn safe_text(value: &str, max_bytes: usize) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if contains_sensitive_shape(trimmed) {
        return "[redacted]".to_owned();
    }
    truncate_utf8(trimmed, max_bytes)
}

fn contains_sensitive_shape(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    lower.contains("/users/")
        || lower.contains("/home/")
        || lower.contains("authorization:")
        || lower.contains("bearer ")
        || lower.contains("api_key")
        || lower.contains("apikey")
        || lower.contains("secret")
        || lower.contains("token=")
        || lower.contains("grant:")
        || lower.contains("trace:")
        || lower.contains("invocation:")
        || looks_like_long_hex(value)
}

fn looks_like_long_hex(value: &str) -> bool {
    let hex_count = value.chars().filter(|ch| ch.is_ascii_hexdigit()).count();
    hex_count >= 32 && value.chars().all(|ch| ch.is_ascii_hexdigit() || ch == '-')
}

fn truncate_utf8(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &value[..end])
}

fn normalize(value: &str) -> String {
    value
        .trim()
        .replace(['_', '-', ' '], "")
        .to_ascii_lowercase()
}

trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}

impl<T> Pipe for T {}

#[cfg(test)]
pub(crate) fn test_item(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    serde_json::to_value(ModuleActivityItem::from_resource(
        resource, version, payload,
    ))
    .expect("test item serializes")
}

#[cfg(test)]
pub(crate) fn test_projection(items: Vec<ModuleActivityItem>, limit: usize) -> Value {
    ModuleActivityProjection::from_items(items, limit).into_value()
}
