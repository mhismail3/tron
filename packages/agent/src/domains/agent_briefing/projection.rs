use serde_json::{Value, json};

use crate::engine::Invocation;

use super::contract;

const MAX_TITLE_BYTES: usize = 96;
const MAX_DETAIL_BYTES: usize = 220;
const MAX_ITEMS_PER_SECTION: usize = 6;

pub(crate) fn briefing_from_module_activity(
    module_activity: Value,
    invocation: &Invocation,
    limit: usize,
) -> Value {
    let summary = module_activity.get("summary").unwrap_or(&Value::Null);
    let active = number(summary, "active");
    let waiting = number(summary, "waiting");
    let blocked = number(summary, "blocked");
    let total = number(summary, "total");
    let timeline = array(&module_activity, "timeline");
    let active_items = filter_status(timeline, "active", limit);
    let waiting_items = filter_status(timeline, "waiting", limit);
    let blocked_items = filter_status(timeline, "blocked", limit);
    let recorded_items = timeline
        .iter()
        .take(limit)
        .enumerate()
        .map(|(index, item)| briefing_item(item, index))
        .collect::<Vec<_>>();

    json!({
        "schemaVersion": contract::SCHEMA_VERSION,
        "operation": "agent_briefing_overview",
        "summary": {
            "title": summary_title(active, waiting, blocked, total),
            "detail": summary_detail(active, waiting, blocked, total),
            "activeWorkCount": active,
            "needsYouCount": waiting,
            "weakPointCount": blocked,
            "activityCount": total,
            "degraded": blocked > 0
        },
        "scope": {
            "sessionScoped": invocation.causal_context.session_id.is_some(),
            "workspaceScoped": invocation.causal_context.workspace_id.is_some(),
            "exactScopeRequired": true,
            "payloadScopeTrusted": false
        },
        "sections": [
            section(
                "what_tron_has_been_doing",
                "What Tron has been doing",
                "What changed recently?",
                section_narrative(total, "Recent module-plane work is summarized from server-owned activity records.", "No module-plane work has been recorded for this scope."),
                recorded_items,
                "No recent activity is available for this session or workspace.",
            ),
            section(
                "how_tron_adapted",
                "How Tron adapted",
                "Did Tron change its operating posture?",
                adaptation_narrative(active, waiting, blocked),
                adaptation_items(&module_activity),
                "No lifecycle, runtime, rollback, or quarantine adaptation evidence is available.",
            ),
            section(
                "active_work",
                "Active work",
                "What is currently in motion?",
                section_narrative(active, "Active module runtime work is in progress.", "No active module runtime work is in progress."),
                active_items,
                "No active work is in progress.",
            ),
            section(
                "needs_you",
                "Needs you",
                "Where is user input or review needed?",
                section_narrative(waiting, "Some work is waiting for review or a decision.", "No work is currently waiting on you."),
                waiting_items,
                "No review queue items are visible in this scope.",
            ),
            section(
                "weak_points_failures",
                "Weak points/failures",
                "What is blocked or degraded?",
                section_narrative(blocked, "Blocked or degraded work needs attention.", "No blocked module activity is visible."),
                blocked_items,
                "No blocked or failed module activity is visible.",
            ),
            section(
                "memory_learned_state",
                "Memory and learned state",
                "What durable learning changed?",
                "This briefing does not infer or create learned behavior. Memory evidence remains limited to redacted refs when the owning memory domain exposes them.",
                Vec::new(),
                "No memory or learned-state changes are part of this briefing projection.",
            ),
            section(
                "audit_trail",
                "Audit trail",
                "What evidence backs this briefing?",
                "Evidence rows are derived from redacted module activity metadata and omit raw payloads, paths, commands, logs, grants, authorities, traces, and invocation ids.",
                audit_items(timeline, limit),
                "No audit rows are available for this scope.",
            )
        ],
        "projection": {
            "allowlist": "agent_briefing_metadata_redacted_v1",
            "serverOwnedTruth": true,
            "projectionOnly": true,
            "autonomyBehaviorCreated": false,
            "metadataOnly": true,
            "rawPayloadsReturned": false,
            "rawCommandsReturned": false,
            "rawLogsReturned": false,
            "promptBodiesReturned": false,
            "fileContentsReturned": false,
            "absolutePathsReturned": false,
            "grantIdsReturned": false,
            "authorityIdsReturned": false,
            "traceIdsReturned": false,
            "invocationIdsReturned": false,
            "tokenLikeMaterialReturned": false,
            "boundedItems": true,
            "sourceProjection": module_activity.get("operation").and_then(Value::as_str).unwrap_or("module_activity_overview")
        }
    })
}

fn section(
    id: &str,
    title: &str,
    question: &str,
    narrative: impl Into<String>,
    items: Vec<Value>,
    empty_state: &str,
) -> Value {
    json!({
        "id": id,
        "title": title,
        "question": question,
        "narrative": bounded(narrative.into(), MAX_DETAIL_BYTES),
        "items": items.into_iter().take(MAX_ITEMS_PER_SECTION).collect::<Vec<_>>(),
        "emptyState": empty_state,
        "drilldownAvailable": true
    })
}

fn briefing_item(item: &Value, index: usize) -> Value {
    let status = safe_field(item, "status", "recorded", MAX_TITLE_BYTES);
    let title = safe_field(item, "title", "Recorded activity", MAX_TITLE_BYTES);
    let detail = safe_field(
        item,
        "detail",
        "Provider-safe metadata only",
        MAX_DETAIL_BYTES,
    );
    json!({
        "id": format!("briefing-item-{}", index + 1),
        "title": title,
        "detail": detail,
        "status": status,
        "evidence": evidence(item, index)
    })
}

fn audit_items(items: &[Value], limit: usize) -> Vec<Value> {
    items
        .iter()
        .take(limit)
        .enumerate()
        .map(|(index, item)| {
            json!({
                "id": format!("audit-row-{}", index + 1),
                "title": safe_field(item, "resourceKind", "module_resource", MAX_TITLE_BYTES),
                "detail": format!(
                    "{} / {}",
                    safe_field(item, "status", "recorded", MAX_TITLE_BYTES),
                    safe_field(item, "state", "unknown", MAX_TITLE_BYTES)
                ),
                "status": safe_field(item, "status", "recorded", MAX_TITLE_BYTES),
                "evidence": evidence(item, index)
            })
        })
        .collect()
}

fn adaptation_items(module_activity: &Value) -> Vec<Value> {
    let resources = array(module_activity, "resources");
    resources
        .iter()
        .take(MAX_ITEMS_PER_SECTION)
        .enumerate()
        .map(|(index, item)| {
            let total = item.get("total").and_then(Value::as_u64).unwrap_or(0);
            let blocked = item.get("blocked").and_then(Value::as_u64).unwrap_or(0);
            let waiting = item.get("waiting").and_then(Value::as_u64).unwrap_or(0);
            json!({
                "id": format!("adaptation-{}", index + 1),
                "title": safe_field(item, "kind", "module_resource", MAX_TITLE_BYTES),
                "detail": format!("{total} records, {waiting} waiting, {blocked} blocked"),
                "status": if blocked > 0 { "blocked" } else if waiting > 0 { "waiting" } else { "recorded" },
                "evidence": {
                    "label": "Resource-kind summary",
                    "resourceKind": safe_field(item, "kind", "module_resource", MAX_TITLE_BYTES),
                    "providerSafe": true
                }
            })
        })
        .collect()
}

fn evidence(item: &Value, index: usize) -> Value {
    json!({
        "label": format!("Evidence {}", index + 1),
        "resourceKind": safe_field(item, "resourceKind", "module_resource", MAX_TITLE_BYTES),
        "updatedAt": safe_field(item, "updatedAt", "unknown", MAX_TITLE_BYTES),
        "providerSafe": true
    })
}

fn filter_status(items: &[Value], status: &str, limit: usize) -> Vec<Value> {
    items
        .iter()
        .filter(|item| item.get("status").and_then(Value::as_str) == Some(status))
        .take(limit)
        .enumerate()
        .map(|(index, item)| briefing_item(item, index))
        .collect()
}

fn section_narrative(count: usize, present: &str, empty: &str) -> String {
    if count == 0 {
        empty.to_owned()
    } else {
        present.to_owned()
    }
}

fn adaptation_narrative(active: usize, waiting: usize, blocked: usize) -> String {
    if active == 0 && waiting == 0 && blocked == 0 {
        return "No adaptation evidence is visible in this scope.".to_owned();
    }
    "Adaptation evidence is limited to lifecycle, runtime, rollback, quarantine, and review states already recorded by module owners.".to_owned()
}

fn summary_title(active: usize, waiting: usize, blocked: usize, total: usize) -> String {
    if blocked > 0 {
        "Tron has blocked work to review".to_owned()
    } else if waiting > 0 {
        "Tron is waiting on review".to_owned()
    } else if active > 0 {
        "Tron has active work".to_owned()
    } else if total > 0 {
        "Tron has recent activity".to_owned()
    } else {
        "No active briefing yet".to_owned()
    }
}

fn summary_detail(active: usize, waiting: usize, blocked: usize, total: usize) -> String {
    if total == 0 {
        return "No module-plane activity is visible for this session or workspace.".to_owned();
    }
    format!(
        "{active} active, {waiting} waiting on review, {blocked} blocked, {total} total records."
    )
}

fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn number(value: &Value, key: &str) -> usize {
    value.get(key).and_then(Value::as_u64).unwrap_or(0) as usize
}

fn safe_field(value: &Value, key: &str, fallback: &str, max_bytes: usize) -> String {
    let raw = value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or(fallback)
        .to_owned();
    bounded(redact(raw), max_bytes)
}

fn bounded(value: String, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value;
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &value[..end])
}

fn redact(value: String) -> String {
    let lower = value.to_ascii_lowercase();
    if lower.contains("/users/")
        || lower.contains("token=")
        || lower.contains("secret")
        || lower.contains("api_key")
        || lower.contains("grant:")
        || lower.contains("authority:")
        || lower.contains("trace:")
        || lower.contains("invocation:")
    {
        return "[redacted]".to_owned();
    }
    value
}
