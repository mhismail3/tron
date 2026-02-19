//! ADAPTER(ios-compat): Temporary compatibility adapters for iOS client.
//!
//! This entire module exists to transform Rust server responses into the format
//! the iOS app currently expects. Every public function is tagged for future removal.
//!
//! To find all adapter usage:  `grep -rn "ADAPTER(ios-compat)" packages/agent/`
//! To remove: delete this module, remove `pub mod adapters` from lib.rs,
//!            and revert each tagged call site (instructions inline at each site).

use std::collections::HashMap;

use crate::rpc::context::RpcContext;
use serde_json::{Value, json};
use tron_core::tools::Tool;

/// ADAPTER(ios-compat): iOS splits tools on ":" to show name + description in context sheet.
///
/// Converts bare tool names like `["bash", "read"]` into formatted strings
/// like `["bash: Execute shell commands", "read: Read file contents"]`.
///
/// REMOVE: delete this function and revert call sites to use bare names.
pub fn adapt_tools_content(bare_names: &[String], tool_defs: &[Tool]) -> Vec<String> {
    let lookup: HashMap<&str, &str> = tool_defs
        .iter()
        .map(|t| (t.name.as_str(), t.description.as_str()))
        .collect();

    bare_names
        .iter()
        .map(|name| {
            if let Some(desc) = lookup.get(name.as_str()) {
                let first_line = desc.lines().next().unwrap_or(desc);
                let truncated = tron_core::text::truncate_with_suffix(first_line, 120, "...");
                format!("{name}: {truncated}")
            } else {
                name.clone()
            }
        })
        .collect()
}

/// ADAPTER(ios-compat): iOS expects `input` not `arguments` on `tool_use` content blocks.
///
/// Core/runtime/persistence now use canonical `arguments` only. This adapter
/// applies wire conversion at the protocol boundary.
pub fn adapt_assistant_content_for_ios(content: &mut [Value]) {
    for block in content.iter_mut() {
        if block.get("type").and_then(Value::as_str) == Some("tool_use") {
            if let Some(args) = block.get("arguments").cloned() {
                if let Some(obj) = block.as_object_mut() {
                    let _ = obj.remove("arguments");
                    let _ = obj.insert("input".into(), args);
                }
            }
        }
    }
}

/// ADAPTER(ios-compat): iOS expects `totalCount` in `skill.list` response.
///
/// Mutates the response JSON to add `totalCount` field alongside `skills` array.
///
/// REMOVE: delete this function; revert call site to `Ok(json!({ "skills": skills }))`.
pub fn adapt_skill_list(response: &mut Value) {
    if let Some(arr) = response.get("skills").and_then(Value::as_array) {
        response["totalCount"] = json!(arr.len());
    }
}

/// ADAPTER(tool-compat): Normalize `AskUserQuestion` options from strings to objects.
///
/// The LLM may still send string options `["A", "B"]` even though the schema
/// specifies object items. This normalizes them to `[{"label": "A"}, {"label": "B"}]`
/// so iOS can always parse structured option objects.
///
/// REMOVE: When the schema has been live long enough that LLMs always produce objects.
pub fn adapt_ask_user_options(options: &mut Value) {
    if let Some(arr) = options.as_array_mut() {
        for item in arr.iter_mut() {
            if let Some(s) = item.as_str().map(String::from) {
                *item = json!({"label": s});
            }
        }
    }
}

/// Centralized outbound RPC adaptation for iOS compatibility.
///
/// This is the only response adaptation entrypoint used by WebSocket RPC.
pub fn adapt_rpc_result_for_ios(method: &str, result: &mut Value, ctx: &RpcContext) {
    match method {
        "settings.get" => adapt_settings_get(result),
        "skill.list" => adapt_skill_list(result),
        "context.getDetailedSnapshot" => adapt_context_detailed_snapshot(result, ctx),
        "session.getHistory" => adapt_session_get_history(result),
        _ => {}
    }
}

/// ADAPTER(ios-compat): iOS expects additional flat settings fields.
fn adapt_settings_get(settings: &mut Value) {
    let Some(obj) = settings.as_object_mut() else {
        return;
    };

    if let Some(model) = obj.get("models").and_then(|m| m.get("default")).cloned() {
        let _ = obj.insert("defaultModel".into(), model);
    }

    if let Some(val) = obj
        .get("server")
        .and_then(|s| s.get("maxConcurrentSessions"))
        .cloned()
    {
        let _ = obj.insert("maxConcurrentSessions".into(), val);
    }

    if let Some(val) = obj
        .get("server")
        .and_then(|s| s.get("defaultWorkspace"))
        .cloned()
    {
        let _ = obj.insert("defaultWorkspace".into(), val);
    }

    if let Some(context) = obj.get("context").cloned() {
        if let Some(mut compaction) = context.get("compactor").cloned() {
            if let Some(c) = compaction.as_object_mut()
                && let Some(val) = c.remove("preserveRecentCount")
            {
                let _ = c.insert("preserveRecentTurns".into(), val);
            }
            let _ = obj.insert("compaction".into(), compaction);
        }
        if let Some(memory) = context.get("memory").cloned() {
            let _ = obj.insert("memory".into(), memory);
        }
        if let Some(rules) = context.get("rules").cloned() {
            let _ = obj.insert("rules".into(), rules);
        }
        if let Some(tasks) = context.get("tasks").cloned() {
            let _ = obj.insert("tasks".into(), tasks);
        }
    }
}

/// ADAPTER(ios-compat): decorate `toolsContent` entries in detailed snapshots.
fn adapt_context_detailed_snapshot(result: &mut Value, ctx: &RpcContext) {
    let Some(raw) = result.get("toolsContent").and_then(Value::as_array) else {
        return;
    };
    let bare_names: Option<Vec<String>> =
        raw.iter().map(|v| v.as_str().map(String::from)).collect();
    let Some(bare_names) = bare_names else {
        return;
    };

    let tool_defs = ctx
        .agent_deps
        .as_ref()
        .map(|d| (d.tool_factory)().definitions())
        .unwrap_or_default();
    result["toolsContent"] = json!(adapt_tools_content(&bare_names, &tool_defs));
}

/// ADAPTER(ios-compat): reconstruct `TaskManager` tool results as iOS text format.
fn adapt_session_get_history(result: &mut Value) {
    let Some(messages) = result.get_mut("messages").and_then(Value::as_array_mut) else {
        return;
    };

    for msg in messages {
        if msg
            .get("role")
            .and_then(Value::as_str)
            .is_some_and(|role| role == "assistant")
            && let Some(blocks) = msg
                .get_mut("content")
                .and_then(Value::as_object_mut)
                .and_then(|content| content.get_mut("content"))
                .and_then(Value::as_array_mut)
        {
            adapt_assistant_content_for_ios(blocks);
        }

        let is_task_manager = msg
            .get("toolUse")
            .and_then(|t| t.get("name"))
            .and_then(Value::as_str)
            .is_some_and(|name| name == "TaskManager");
        if !is_task_manager {
            continue;
        }
        let Some(content) = msg.get_mut("content").and_then(Value::as_object_mut) else {
            continue;
        };
        let Some(raw) = content.get("content").and_then(Value::as_str) else {
            continue;
        };
        let _ = content.insert(
            "content".into(),
            Value::String(adapt_task_manager_result_auto(raw)),
        );
    }
}

/// ADAPTER(ios-compat): normalize tool execution output for WebSocket events.
pub fn adapt_tool_execution_result_for_ios(
    tool_name: &str,
    success: bool,
    result_text: &str,
    details: Option<&Value>,
) -> String {
    if tool_name == "TaskManager"
        && success
        && let Some(action) = details
            .and_then(|d| d.get("action"))
            .and_then(Value::as_str)
    {
        return adapt_task_manager_result(action, result_text);
    }
    result_text.to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// TaskManager result formatting
// ─────────────────────────────────────────────────────────────────────────────

/// ADAPTER(ios-compat): Format `TaskManager` JSON results as text for iOS parsing,
/// auto-detecting the action from JSON structure.
///
/// Used during session reconstruction where the action is not available.
/// If the input is already adapted text (not valid JSON), passes through unchanged.
///
/// REMOVE: When iOS is updated to parse JSON natively instead of text.
pub fn adapt_task_manager_result_auto(result_text: &str) -> String {
    let json: Value = match serde_json::from_str(result_text) {
        Ok(v) => v,
        Err(_) => return result_text.to_string(), // Already adapted text
    };

    let action = detect_task_manager_action(&json);
    adapt_task_manager_result(action, result_text)
}

/// Detect the `TaskManager` action from JSON result structure.
fn detect_task_manager_action(json: &Value) -> &str {
    // List results: arrays with count/total metadata
    if json.get("tasks").and_then(Value::as_array).is_some() {
        if json.get("total").is_some() || json.get("count").is_some() {
            return "list";
        }
        return "search";
    }
    if json.get("projects").and_then(Value::as_array).is_some() {
        return "list_projects";
    }
    if json.get("areas").and_then(Value::as_array).is_some() {
        return "list_areas";
    }

    // Delete/log_time results: {"success": true, "<id-key>": "..."}
    if json.get("success").is_some() {
        if json.get("minutesLogged").is_some() {
            return "log_time";
        }
        if json.get("taskId").is_some() {
            return "delete";
        }
        if json.get("projectId").is_some() {
            return "delete_project";
        }
        if json.get("areaId").is_some() {
            return "delete_area";
        }
    }

    // Entity results: single object with "id" field
    if let Some(id) = json.get("id").and_then(Value::as_str) {
        if id.starts_with("task-") || id.starts_with("task_") {
            // get returns TaskWithDetails (has subtasks/recentActivity)
            if json.get("subtasks").is_some() || json.get("recentActivity").is_some() {
                return "get";
            }
            return "create"; // create/update use same format
        }
        if id.starts_with("proj-") || id.starts_with("proj_") {
            return if json.get("taskCount").is_some() {
                "get_project"
            } else {
                "create_project"
            };
        }
        if id.starts_with("area-") || id.starts_with("area_") {
            return if json.get("projectCount").is_some() {
                "get_area"
            } else {
                "create_area"
            };
        }
    }

    "unknown"
}

/// ADAPTER(ios-compat): Format `TaskManager` JSON results as text for iOS parsing.
///
/// The Rust `TaskManager` tool returns raw JSON objects via `serde_json::to_string_pretty`,
/// but the iOS app's `parseEntityDetail()` expects a specific text format with `# Title`
/// headers, `ID: ... | Status: ...` metadata lines, and key-value pairs.
///
/// This adapter converts JSON results into the text format matching the TypeScript
/// server's `formatTaskDetail()`, `formatProjectDetail()`, and `formatAreaDetail()`.
///
/// REMOVE: When iOS is updated to parse JSON natively instead of text.
pub fn adapt_task_manager_result(action: &str, result_text: &str) -> String {
    let json: Value = match serde_json::from_str(result_text) {
        Ok(v) => v,
        Err(_) => return result_text.to_string(),
    };

    match action {
        "create" | "update" => fmt_task_action(action, &json),
        "get" => fmt_task_detail(&json),
        "delete" => fmt_delete("task", "taskId", &json),
        "log_time" => fmt_log_time(&json),
        "list" => fmt_task_list(&json),
        "search" => fmt_task_search(&json),
        "create_project" | "update_project" => fmt_project_action(action, &json),
        "get_project" => fmt_project_detail(&json),
        "delete_project" => fmt_delete("project", "projectId", &json),
        "list_projects" => fmt_project_list(&json),
        "create_area" | "update_area" => fmt_area_action(action, &json),
        "get_area" => fmt_area_detail(&json),
        "delete_area" => fmt_delete("area", "areaId", &json),
        "list_areas" => fmt_area_list(&json),
        _ => result_text.to_string(),
    }
}

fn str_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

// ── Task formatting ──────────────────────────────────────────────────────────

#[allow(clippy::too_many_lines)]
fn fmt_task_detail(task: &Value) -> String {
    let title = str_field(task, "title").unwrap_or("Untitled");
    let id = str_field(task, "id").unwrap_or("?");
    let status = str_field(task, "status").unwrap_or("unknown");
    let priority = str_field(task, "priority").unwrap_or("medium");

    let mut lines = vec![
        format!("# {title}"),
        format!("ID: {id} | Status: {status} | Priority: {priority}"),
    ];

    if let Some(desc) = str_field(task, "description") {
        lines.push(String::new());
        lines.push(desc.to_string());
    }
    if let Some(af) = str_field(task, "activeForm") {
        lines.push(format!("Active form: {af}"));
    }
    if let Some(proj) = str_field(task, "projectId") {
        lines.push(format!("Project: {proj}"));
    }
    if let Some(area) = str_field(task, "areaId") {
        lines.push(format!("Area: {area}"));
    }
    if let Some(parent) = str_field(task, "parentTaskId") {
        lines.push(format!("Parent: {parent}"));
    }
    if let Some(due) = str_field(task, "dueDate") {
        lines.push(format!("Due: {due}"));
    }
    if let Some(deferred) = str_field(task, "deferredUntil") {
        lines.push(format!("Deferred until: {deferred}"));
    }
    if let Some(est) = task.get("estimatedMinutes").and_then(Value::as_i64) {
        let actual = task
            .get("actualMinutes")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        lines.push(format!("Time: {actual}/{est}min"));
    }
    if let Some(tags) = task.get("tags").and_then(Value::as_array) {
        if !tags.is_empty() {
            let strs: Vec<&str> = tags.iter().filter_map(Value::as_str).collect();
            lines.push(format!("Tags: {}", strs.join(", ")));
        }
    }
    if let Some(source) = str_field(task, "source") {
        lines.push(format!("Source: {source}"));
    }
    if let Some(v) = str_field(task, "startedAt") {
        lines.push(format!("Started: {v}"));
    }
    if let Some(v) = str_field(task, "completedAt") {
        lines.push(format!("Completed: {v}"));
    }
    if let Some(v) = str_field(task, "createdAt") {
        lines.push(format!("Created: {v}"));
    }
    if let Some(v) = str_field(task, "updatedAt") {
        lines.push(format!("Updated: {v}"));
    }

    if let Some(notes) = str_field(task, "notes") {
        lines.push(String::new());
        lines.push(format!("Notes:\n{notes}"));
    }

    // Subtasks (TaskWithDetails only)
    if let Some(subtasks) = task.get("subtasks").and_then(Value::as_array) {
        if !subtasks.is_empty() {
            lines.push(String::new());
            lines.push(format!("Subtasks ({}):", subtasks.len()));
            for sub in subtasks {
                let mark = match str_field(sub, "status") {
                    Some("completed") => "x",
                    Some("in_progress") => ">",
                    _ => " ",
                };
                let sub_id = str_field(sub, "id").unwrap_or("?");
                let sub_title = str_field(sub, "title").unwrap_or("Untitled");
                lines.push(format!("  [{mark}] {sub_id}: {sub_title}"));
            }
        }
    }

    // Dependencies (TaskWithDetails only)
    if let Some(blocked_by) = task.get("blockedBy").and_then(Value::as_array) {
        let ids: Vec<&str> = blocked_by
            .iter()
            .filter_map(|d| str_field(d, "blockerTaskId"))
            .collect();
        if !ids.is_empty() {
            lines.push(String::new());
            lines.push(format!("Blocked by: {}", ids.join(", ")));
        }
    }
    if let Some(blocks) = task.get("blocks").and_then(Value::as_array) {
        let ids: Vec<&str> = blocks
            .iter()
            .filter_map(|d| str_field(d, "blockedTaskId"))
            .collect();
        if !ids.is_empty() {
            lines.push(format!("Blocks: {}", ids.join(", ")));
        }
    }

    // Recent activity (TaskWithDetails only)
    if let Some(activity) = task.get("recentActivity").and_then(Value::as_array) {
        if !activity.is_empty() {
            lines.push(String::new());
            lines.push("Recent activity:".to_string());
            for act in activity.iter().take(5) {
                let ts = str_field(act, "timestamp").unwrap_or("?");
                let date = ts.split('T').next().unwrap_or(ts);
                let action = str_field(act, "action").unwrap_or("?");
                let detail = str_field(act, "detail")
                    .map(|d| format!(" - {d}"))
                    .unwrap_or_default();
                lines.push(format!("  {date}: {action}{detail}"));
            }
        }
    }

    lines.join("\n")
}

fn fmt_task_action(action: &str, task: &Value) -> String {
    let id = str_field(task, "id").unwrap_or("?");
    let title = str_field(task, "title").unwrap_or("Untitled");
    let status = str_field(task, "status").unwrap_or("pending");
    let verb = if action == "create" {
        "Created"
    } else {
        "Updated"
    };
    format!(
        "{verb} task {id}: {title} [{status}]\n\n{}",
        fmt_task_detail(task)
    )
}

fn fmt_task_list(json: &Value) -> String {
    let Some(tasks) = json.get("tasks").and_then(Value::as_array) else {
        return json.to_string();
    };
    if tasks.is_empty() {
        return "No tasks found.".to_string();
    }

    let count = json
        .get("count")
        .and_then(Value::as_u64)
        .unwrap_or(tasks.len() as u64);
    let mut lines = vec![format!("Tasks ({count}):")];

    for task in tasks {
        let mark = match str_field(task, "status") {
            Some("completed") => "x",
            Some("in_progress") => ">",
            Some("cancelled") => "-",
            Some("backlog") => "b",
            _ => " ",
        };
        let id = str_field(task, "id").unwrap_or("?");
        let title = str_field(task, "title").unwrap_or("Untitled");

        let mut meta = Vec::new();
        if let Some(p) = str_field(task, "priority") {
            if p != "medium" {
                meta.push(format!("P:{p}"));
            }
        }
        if let Some(due) = str_field(task, "dueDate") {
            meta.push(format!("due:{due}"));
        }
        let suffix = if meta.is_empty() {
            String::new()
        } else {
            format!(" ({})", meta.join(", "))
        };

        lines.push(format!("[{mark}] {id}: {title}{suffix}"));
    }

    lines.join("\n")
}

fn fmt_task_search(json: &Value) -> String {
    let Some(tasks) = json.get("tasks").and_then(Value::as_array) else {
        return json.to_string();
    };
    if tasks.is_empty() {
        return "No tasks found.".to_string();
    }

    let mut lines = vec![format!("Search results ({}):", tasks.len())];
    for task in tasks {
        let id = str_field(task, "id").unwrap_or("?");
        let title = str_field(task, "title").unwrap_or("Untitled");
        let status = str_field(task, "status").unwrap_or("unknown");
        lines.push(format!("  {id}: {title} [{status}]"));
    }
    lines.join("\n")
}

// ── Project formatting ───────────────────────────────────────────────────────

fn fmt_project_detail(project: &Value) -> String {
    let title = str_field(project, "title").unwrap_or("Untitled");
    let id = str_field(project, "id").unwrap_or("?");
    let status = str_field(project, "status").unwrap_or("active");

    let task_count = project.get("taskCount").and_then(Value::as_u64);
    let completed_count = project.get("completedTaskCount").and_then(Value::as_u64);

    let mut meta_parts = vec![format!("ID: {id}"), format!("Status: {status}")];
    if let (Some(comp), Some(total)) = (completed_count, task_count) {
        meta_parts.push(format!("{comp}/{total} tasks"));
    }

    let mut lines = vec![format!("# {title}"), meta_parts.join(" | ")];

    if let Some(desc) = str_field(project, "description") {
        lines.push(String::new());
        lines.push(desc.to_string());
    }
    if let Some(area) = str_field(project, "areaId") {
        lines.push(format!("Area: {area}"));
    }
    if let Some(tags) = project.get("tags").and_then(Value::as_array) {
        if !tags.is_empty() {
            let strs: Vec<&str> = tags.iter().filter_map(Value::as_str).collect();
            lines.push(format!("Tags: {}", strs.join(", ")));
        }
    }
    if let Some(v) = str_field(project, "createdAt") {
        lines.push(format!("Created: {v}"));
    }
    if let Some(v) = str_field(project, "updatedAt") {
        lines.push(format!("Updated: {v}"));
    }

    // Tasks list (if available from enriched response)
    if let Some(tasks) = project.get("tasks").and_then(Value::as_array) {
        if !tasks.is_empty() {
            lines.push(String::new());
            lines.push(format!("Tasks ({}):", tasks.len()));
            for task in tasks {
                let mark = match str_field(task, "status") {
                    Some("completed") => "x",
                    Some("in_progress") => ">",
                    _ => " ",
                };
                let tid = str_field(task, "id").unwrap_or("?");
                let task_title = str_field(task, "title").unwrap_or("Untitled");
                let priority_suffix = match str_field(task, "priority") {
                    Some(p) if p != "medium" => format!(" [{p}]"),
                    _ => String::new(),
                };
                lines.push(format!("  [{mark}] {tid}: {task_title}{priority_suffix}"));
            }
        }
    }

    lines.join("\n")
}

fn fmt_project_action(action: &str, project: &Value) -> String {
    let id = str_field(project, "id").unwrap_or("?");
    let title = str_field(project, "title").unwrap_or("Untitled");
    let verb = if action == "create_project" {
        "Created"
    } else {
        "Updated"
    };
    format!(
        "{verb} project {id}: {title}\n\n{}",
        fmt_project_detail(project)
    )
}

fn fmt_project_list(json: &Value) -> String {
    let Some(projects) = json.get("projects").and_then(Value::as_array) else {
        return json.to_string();
    };
    if projects.is_empty() {
        return "No projects found.".to_string();
    }

    let mut lines = vec![format!("Projects ({}):", projects.len())];
    for project in projects {
        let id = str_field(project, "id").unwrap_or("?");
        let title = str_field(project, "title").unwrap_or("Untitled");
        let status = str_field(project, "status").unwrap_or("active");

        let progress = match (
            project.get("completedTaskCount").and_then(Value::as_u64),
            project.get("taskCount").and_then(Value::as_u64),
        ) {
            (Some(comp), Some(total)) if total > 0 => format!(" ({comp}/{total} tasks)"),
            _ => String::new(),
        };

        lines.push(format!("  {id}: {title} [{status}]{progress}"));
    }
    lines.join("\n")
}

// ── Area formatting ──────────────────────────────────────────────────────────

fn fmt_area_detail(area: &Value) -> String {
    let title = str_field(area, "title").unwrap_or("Untitled");
    let id = str_field(area, "id").unwrap_or("?");
    let status = str_field(area, "status").unwrap_or("active");

    let mut lines = vec![format!("# {title}"), format!("ID: {id} | Status: {status}")];

    let project_count = area.get("projectCount").and_then(Value::as_u64);
    let task_count = area.get("taskCount").and_then(Value::as_u64);
    let active_count = area.get("activeTaskCount").and_then(Value::as_u64);
    if let (Some(pc), Some(tc), Some(ac)) = (project_count, task_count, active_count) {
        let ps = if pc == 1 { "" } else { "s" };
        let ts = if tc == 1 { "" } else { "s" };
        lines.push(format!("{pc} project{ps}, {tc} task{ts} ({ac} active)"));
    }

    if let Some(desc) = str_field(area, "description") {
        lines.push(String::new());
        lines.push(desc.to_string());
    }
    if let Some(tags) = area.get("tags").and_then(Value::as_array) {
        if !tags.is_empty() {
            let strs: Vec<&str> = tags.iter().filter_map(Value::as_str).collect();
            lines.push(format!("Tags: {}", strs.join(", ")));
        }
    }
    if let Some(v) = str_field(area, "createdAt") {
        lines.push(format!("Created: {v}"));
    }
    if let Some(v) = str_field(area, "updatedAt") {
        lines.push(format!("Updated: {v}"));
    }

    lines.join("\n")
}

fn fmt_area_action(action: &str, area: &Value) -> String {
    // update_area returns {"success": true, "areaId": "..."} — no full object
    if area.get("success").is_some() {
        let id = str_field(area, "areaId").unwrap_or("?");
        let verb = if action == "create_area" {
            "Created"
        } else {
            "Updated"
        };
        return format!("{verb} area {id}");
    }

    let id = str_field(area, "id").unwrap_or("?");
    let title = str_field(area, "title").unwrap_or("Untitled");
    let status = str_field(area, "status").unwrap_or("active");
    let verb = if action == "create_area" {
        "Created"
    } else {
        "Updated"
    };
    format!(
        "{verb} area {id}: {title} [{status}]\n\n{}",
        fmt_area_detail(area)
    )
}

fn fmt_area_list(json: &Value) -> String {
    let Some(areas) = json.get("areas").and_then(Value::as_array) else {
        return json.to_string();
    };
    if areas.is_empty() {
        return "No areas found.".to_string();
    }

    let mut lines = vec![format!("Areas ({}):", areas.len())];
    for area in areas {
        let id = str_field(area, "id").unwrap_or("?");
        let title = str_field(area, "title").unwrap_or("Untitled");
        let status = str_field(area, "status").unwrap_or("active");

        let counts = match (
            area.get("projectCount").and_then(Value::as_u64),
            area.get("taskCount").and_then(Value::as_u64),
            area.get("activeTaskCount").and_then(Value::as_u64),
        ) {
            (Some(pc), Some(tc), Some(ac)) => format!(" {pc}p/{tc}t ({ac} active)"),
            _ => String::new(),
        };

        lines.push(format!("  {id}: {title} [{status}]{counts}"));
    }
    lines.join("\n")
}

// ── Shared helpers ───────────────────────────────────────────────────────────

fn fmt_delete(entity_type: &str, id_key: &str, json: &Value) -> String {
    let id = str_field(json, id_key).unwrap_or("?");
    format!("Deleted {entity_type} {id}")
}

fn fmt_log_time(json: &Value) -> String {
    let id = str_field(json, "taskId").unwrap_or("?");
    let minutes = json
        .get("minutesLogged")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    format!("Logged {minutes}min on {id}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use tron_core::tools::{Tool, ToolParameterSchema};

    fn make_tool(name: &str, desc: &str) -> Tool {
        Tool {
            name: name.into(),
            description: desc.into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    // --- adapt_tools_content ---

    #[test]
    fn adapt_tools_content_adds_descriptions() {
        let names = vec!["bash".into(), "read".into()];
        let tools = vec![
            make_tool("bash", "Execute shell commands"),
            make_tool("read", "Read file contents"),
        ];
        let result = adapt_tools_content(&names, &tools);
        assert_eq!(result[0], "bash: Execute shell commands");
        assert_eq!(result[1], "read: Read file contents");
    }

    #[test]
    fn adapt_tools_content_unknown_passthrough() {
        let names = vec!["unknown_tool".into()];
        let tools = vec![make_tool("bash", "Execute shell commands")];
        let result = adapt_tools_content(&names, &tools);
        assert_eq!(result[0], "unknown_tool");
    }

    #[test]
    fn adapt_tools_content_empty() {
        let result = adapt_tools_content(&[], &[]);
        assert!(result.is_empty());
    }

    #[test]
    fn adapt_tools_content_multiline_description_uses_first_line() {
        let names = vec!["bash".into()];
        let tools = vec![make_tool(
            "bash",
            "Execute shell commands\nWith great power comes great responsibility",
        )];
        let result = adapt_tools_content(&names, &tools);
        assert_eq!(result[0], "bash: Execute shell commands");
    }

    // --- adapt_assistant_content_for_ios ---

    #[test]
    fn adapt_assistant_content_renames_arguments_to_input() {
        let mut content = vec![
            json!({"type": "text", "text": "I'll run that"}),
            json!({"type": "tool_use", "id": "tc1", "name": "bash", "arguments": {"cmd": "ls"}}),
        ];
        adapt_assistant_content_for_ios(&mut content);
        // text block unchanged
        assert_eq!(content[0]["text"], "I'll run that");
        // tool_use: arguments renamed to input
        assert!(content[1].get("arguments").is_none());
        assert_eq!(content[1]["input"]["cmd"], "ls");
    }

    #[test]
    fn adapt_assistant_content_already_has_input_unchanged() {
        let mut content =
            vec![json!({"type": "tool_use", "id": "tc1", "name": "bash", "input": {"cmd": "ls"}})];
        adapt_assistant_content_for_ios(&mut content);
        // Already has input, no arguments to rename
        assert_eq!(content[0]["input"]["cmd"], "ls");
    }

    // --- adapt_skill_list ---

    #[test]
    fn adapt_skill_list_adds_total_count() {
        let mut response = json!({ "skills": [{"name": "a"}, {"name": "b"}] });
        adapt_skill_list(&mut response);
        assert_eq!(response["totalCount"], 2);
    }

    #[test]
    fn adapt_skill_list_empty_skills() {
        let mut response = json!({ "skills": [] });
        adapt_skill_list(&mut response);
        assert_eq!(response["totalCount"], 0);
    }

    // --- adapt_ask_user_options ---

    #[test]
    fn adapt_ask_user_string_options() {
        let mut options = json!(["A", "B"]);
        adapt_ask_user_options(&mut options);
        assert_eq!(options, json!([{"label": "A"}, {"label": "B"}]));
    }

    #[test]
    fn adapt_ask_user_object_options_passthrough() {
        let mut options = json!([{"label": "A"}, {"label": "B"}]);
        let expected = options.clone();
        adapt_ask_user_options(&mut options);
        assert_eq!(options, expected);
    }

    #[test]
    fn adapt_ask_user_mixed_options() {
        let mut options = json!(["A", {"label": "B"}]);
        adapt_ask_user_options(&mut options);
        assert_eq!(options, json!([{"label": "A"}, {"label": "B"}]));
    }

    #[test]
    fn adapt_ask_user_empty_array() {
        let mut options = json!([]);
        adapt_ask_user_options(&mut options);
        assert_eq!(options, json!([]));
    }

    // --- adapt_task_manager_result ---

    #[test]
    fn task_create_formats_header() {
        let task = json!({
            "id": "task-abc",
            "title": "Fix bug",
            "status": "pending",
            "priority": "high",
            "source": "agent",
            "tags": [],
            "createdAt": "2026-02-16T10:00:00Z",
            "updatedAt": "2026-02-16T10:00:00Z",
            "actualMinutes": 0,
            "sortOrder": 0
        });
        let input = serde_json::to_string_pretty(&task).unwrap();
        let result = adapt_task_manager_result("create", &input);
        assert!(result.starts_with("Created task task-abc: Fix bug [pending]"));
        assert!(result.contains("# Fix bug"));
        assert!(result.contains("ID: task-abc | Status: pending | Priority: high"));
        assert!(result.contains("Source: agent"));
    }

    #[test]
    fn task_get_formats_with_details() {
        let task = json!({
            "id": "task-1",
            "title": "Implement feature",
            "status": "in_progress",
            "priority": "medium",
            "description": "Add the new widget",
            "activeForm": "Implementing feature",
            "projectId": "proj-1",
            "areaId": "area-1",
            "dueDate": "2026-03-01",
            "estimatedMinutes": 120,
            "actualMinutes": 45,
            "source": "agent",
            "tags": ["frontend", "urgent"],
            "startedAt": "2026-02-15T09:00:00Z",
            "createdAt": "2026-02-14T08:00:00Z",
            "updatedAt": "2026-02-15T09:00:00Z",
            "subtasks": [
                {"id": "task-2", "title": "Design UI", "status": "completed"},
                {"id": "task-3", "title": "Write tests", "status": "pending"}
            ],
            "blockedBy": [
                {"blockerTaskId": "task-10", "blockedTaskId": "task-1"}
            ],
            "blocks": [
                {"blockerTaskId": "task-1", "blockedTaskId": "task-20"}
            ],
            "recentActivity": [
                {"timestamp": "2026-02-15T09:00:00Z", "action": "status_changed", "detail": "pending → in_progress"},
                {"timestamp": "2026-02-14T08:00:00Z", "action": "created"}
            ]
        });
        let input = serde_json::to_string_pretty(&task).unwrap();
        let result = adapt_task_manager_result("get", &input);
        assert!(result.starts_with("# Implement feature"));
        assert!(result.contains("ID: task-1 | Status: in_progress | Priority: medium"));
        assert!(result.contains("Add the new widget"));
        assert!(result.contains("Active form: Implementing feature"));
        assert!(result.contains("Project: proj-1"));
        assert!(result.contains("Area: area-1"));
        assert!(result.contains("Due: 2026-03-01"));
        assert!(result.contains("Time: 45/120min"));
        assert!(result.contains("Tags: frontend, urgent"));
        assert!(result.contains("Subtasks (2):"));
        assert!(result.contains("  [x] task-2: Design UI"));
        assert!(result.contains("  [ ] task-3: Write tests"));
        assert!(result.contains("Blocked by: task-10"));
        assert!(result.contains("Blocks: task-20"));
        assert!(result.contains("Recent activity:"));
        assert!(result.contains("  2026-02-15: status_changed - pending → in_progress"));
    }

    #[test]
    fn task_list_formats_with_marks() {
        let list = json!({
            "tasks": [
                {"id": "t1", "title": "Done task", "status": "completed", "priority": "medium"},
                {"id": "t2", "title": "Active task", "status": "in_progress", "priority": "high"},
                {"id": "t3", "title": "Todo task", "status": "pending", "priority": "medium"}
            ],
            "count": 3
        });
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result("list", &input);
        assert!(result.starts_with("Tasks (3):"));
        assert!(result.contains("[x] t1: Done task"));
        assert!(result.contains("[>] t2: Active task (P:high)"));
        assert!(result.contains("[ ] t3: Todo task"));
    }

    #[test]
    fn task_list_empty() {
        let list = json!({"tasks": [], "count": 0});
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result("list", &input);
        assert_eq!(result, "No tasks found.");
    }

    #[test]
    fn task_search_formats() {
        let list = json!({
            "tasks": [
                {"id": "t1", "title": "Bug fix", "status": "pending", "priority": "high"}
            ],
            "count": 1
        });
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result("search", &input);
        assert!(result.starts_with("Search results (1):"));
        assert!(result.contains("  t1: Bug fix [pending]"));
    }

    #[test]
    fn task_delete_formats() {
        let resp = json!({"success": true, "taskId": "task-99"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result("delete", &input);
        assert_eq!(result, "Deleted task task-99");
    }

    #[test]
    fn task_log_time_formats() {
        let resp = json!({"success": true, "taskId": "task-5", "minutesLogged": 30});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result("log_time", &input);
        assert_eq!(result, "Logged 30min on task-5");
    }

    #[test]
    fn project_create_formats() {
        let project = json!({
            "id": "proj-1",
            "title": "Dashboard v2",
            "status": "active",
            "tags": ["frontend"],
            "createdAt": "2026-01-01",
            "updatedAt": "2026-02-01"
        });
        let input = serde_json::to_string_pretty(&project).unwrap();
        let result = adapt_task_manager_result("create_project", &input);
        assert!(result.starts_with("Created project proj-1: Dashboard v2"));
        assert!(result.contains("# Dashboard v2"));
        assert!(result.contains("ID: proj-1 | Status: active"));
        assert!(result.contains("Tags: frontend"));
    }

    #[test]
    fn project_list_formats() {
        let list = json!({
            "projects": [
                {"id": "p1", "title": "Alpha", "status": "active", "completedTaskCount": 3, "taskCount": 10}
            ],
            "count": 1
        });
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result("list_projects", &input);
        assert!(result.starts_with("Projects (1):"));
        assert!(result.contains("  p1: Alpha [active] (3/10 tasks)"));
    }

    #[test]
    fn project_delete_formats() {
        let resp = json!({"success": true, "projectId": "proj-5"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result("delete_project", &input);
        assert_eq!(result, "Deleted project proj-5");
    }

    #[test]
    fn area_create_formats() {
        let area = json!({
            "id": "area-1",
            "title": "Engineering",
            "status": "active",
            "tags": [],
            "createdAt": "2026-01-01",
            "updatedAt": "2026-01-01"
        });
        let input = serde_json::to_string_pretty(&area).unwrap();
        let result = adapt_task_manager_result("create_area", &input);
        assert!(result.starts_with("Created area area-1: Engineering [active]"));
        assert!(result.contains("# Engineering"));
        assert!(result.contains("ID: area-1 | Status: active"));
    }

    #[test]
    fn area_get_with_counts() {
        let area = json!({
            "id": "area-1",
            "title": "Security",
            "status": "active",
            "projectCount": 2,
            "taskCount": 15,
            "activeTaskCount": 8,
            "createdAt": "2026-01-01",
            "updatedAt": "2026-02-01"
        });
        let input = serde_json::to_string_pretty(&area).unwrap();
        let result = adapt_task_manager_result("get_area", &input);
        assert!(result.contains("# Security"));
        assert!(result.contains("2 projects, 15 tasks (8 active)"));
    }

    #[test]
    fn area_update_minimal_response() {
        let resp = json!({"success": true, "areaId": "area-3"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result("update_area", &input);
        assert_eq!(result, "Updated area area-3");
    }

    #[test]
    fn area_list_formats() {
        let list = json!({
            "areas": [
                {"id": "a1", "title": "Dev", "status": "active", "projectCount": 3, "taskCount": 20, "activeTaskCount": 12}
            ],
            "count": 1
        });
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result("list_areas", &input);
        assert!(result.starts_with("Areas (1):"));
        assert!(result.contains("  a1: Dev [active] 3p/20t (12 active)"));
    }

    #[test]
    fn area_delete_formats() {
        let resp = json!({"success": true, "areaId": "area-5"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result("delete_area", &input);
        assert_eq!(result, "Deleted area area-5");
    }

    #[test]
    fn unknown_action_passthrough() {
        let result = adapt_task_manager_result("unknown", "some raw text");
        assert_eq!(result, "some raw text");
    }

    #[test]
    fn invalid_json_passthrough() {
        let result = adapt_task_manager_result("create", "not json at all");
        assert_eq!(result, "not json at all");
    }

    // --- adapt_task_manager_result_auto (auto-detection) ---

    #[test]
    fn auto_detect_task_list() {
        let list = json!({"tasks": [{"id": "t1", "title": "A", "status": "pending", "priority": "medium"}], "count": 1});
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert!(result.starts_with("Tasks (1):"));
        assert!(result.contains("[ ] t1: A"));
    }

    #[test]
    fn auto_detect_search() {
        let search = json!({"tasks": [{"id": "t1", "title": "Bug", "status": "pending"}]});
        let input = serde_json::to_string_pretty(&search).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert!(result.starts_with("Search results (1):"));
    }

    #[test]
    fn auto_detect_project_list() {
        let list =
            json!({"projects": [{"id": "p1", "title": "Alpha", "status": "active"}], "total": 1});
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert!(result.starts_with("Projects (1):"));
    }

    #[test]
    fn auto_detect_area_list() {
        let list = json!({"areas": [{"id": "a1", "title": "Dev", "status": "active", "projectCount": 2, "taskCount": 10, "activeTaskCount": 5}], "total": 1});
        let input = serde_json::to_string_pretty(&list).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert!(result.starts_with("Areas (1):"));
    }

    #[test]
    fn auto_detect_delete() {
        let resp = json!({"success": true, "taskId": "task-99"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert_eq!(result, "Deleted task task-99");
    }

    #[test]
    fn auto_detect_log_time() {
        let resp = json!({"success": true, "taskId": "task-5", "minutesLogged": 30});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert_eq!(result, "Logged 30min on task-5");
    }

    #[test]
    fn auto_detect_task_entity() {
        let task = json!({"id": "task-abc", "title": "Fix", "status": "pending", "priority": "high", "tags": [], "source": "agent", "createdAt": "2026-01-01", "updatedAt": "2026-01-01", "actualMinutes": 0, "sortOrder": 0});
        let input = serde_json::to_string_pretty(&task).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert!(result.contains("# Fix"));
        assert!(result.contains("ID: task-abc"));
    }

    #[test]
    fn auto_detect_task_with_details() {
        let task = json!({"id": "task-1", "title": "Test", "status": "pending", "priority": "medium", "subtasks": [], "recentActivity": [], "blockedBy": [], "blocks": [], "tags": [], "source": "agent", "createdAt": "2026-01-01", "updatedAt": "2026-01-01", "actualMinutes": 0, "sortOrder": 0});
        let input = serde_json::to_string_pretty(&task).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert!(result.starts_with("# Test"));
    }

    #[test]
    fn auto_detect_already_adapted_passthrough() {
        let adapted = "Tasks (2):\n[>] t1: Active task\n[ ] t2: Pending task";
        let result = adapt_task_manager_result_auto(adapted);
        assert_eq!(result, adapted);
    }

    #[test]
    fn auto_detect_delete_project() {
        let resp = json!({"success": true, "projectId": "proj-5"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert_eq!(result, "Deleted project proj-5");
    }

    #[test]
    fn auto_detect_delete_area() {
        let resp = json!({"success": true, "areaId": "area-3"});
        let input = serde_json::to_string_pretty(&resp).unwrap();
        let result = adapt_task_manager_result_auto(&input);
        assert_eq!(result, "Deleted area area-3");
    }

    #[test]
    fn task_notes_included() {
        let task = json!({
            "id": "t1", "title": "Test", "status": "pending", "priority": "medium",
            "notes": "First note\nSecond note",
            "tags": [], "source": "agent",
            "createdAt": "2026-01-01", "updatedAt": "2026-01-01",
            "actualMinutes": 0, "sortOrder": 0
        });
        let input = serde_json::to_string_pretty(&task).unwrap();
        let result = adapt_task_manager_result("get", &input);
        assert!(result.contains("Notes:\nFirst note\nSecond note"));
    }

    #[test]
    fn area_singular_plurals() {
        let area = json!({
            "id": "a1", "title": "Solo", "status": "active",
            "projectCount": 1, "taskCount": 1, "activeTaskCount": 1,
            "createdAt": "2026-01-01", "updatedAt": "2026-01-01"
        });
        let input = serde_json::to_string_pretty(&area).unwrap();
        let result = adapt_task_manager_result("get_area", &input);
        assert!(result.contains("1 project, 1 task (1 active)"));
    }

    #[test]
    fn adapt_rpc_result_settings_get_adds_ios_flat_fields() {
        let ctx = make_test_context();
        let mut result = json!({
            "models": {"default": "claude-opus-4-6"},
            "server": {"maxConcurrentSessions": 3, "defaultWorkspace": "/tmp"},
            "context": {
                "compactor": {"preserveRecentCount": 8},
                "memory": {"ledger": {}, "autoInject": {}},
                "rules": {},
                "tasks": {}
            }
        });
        adapt_rpc_result_for_ios("settings.get", &mut result, &ctx);
        assert_eq!(result["defaultModel"], "claude-opus-4-6");
        assert_eq!(result["maxConcurrentSessions"], 3);
        assert_eq!(result["defaultWorkspace"], "/tmp");
        assert_eq!(result["compaction"]["preserveRecentTurns"], 8);
    }

    #[test]
    fn adapt_rpc_result_session_history_maps_tool_use_arguments_to_input() {
        let ctx = make_test_context();
        let mut result = json!({
            "messages": [{
                "role": "assistant",
                "content": {
                    "content": [{
                        "type": "tool_use",
                        "id": "tc1",
                        "name": "bash",
                        "arguments": {"cmd": "ls"}
                    }]
                }
            }],
            "hasMore": false
        });
        adapt_rpc_result_for_ios("session.getHistory", &mut result, &ctx);
        let block = &result["messages"][0]["content"]["content"][0];
        assert!(block.get("arguments").is_none());
        assert_eq!(block["input"]["cmd"], "ls");
    }

    #[test]
    fn adapt_tool_execution_result_passthrough_for_non_task_manager() {
        let rendered = adapt_tool_execution_result_for_ios("Read", true, "plain output", None);
        assert_eq!(rendered, "plain output");
    }

    #[test]
    fn adapt_settings_get_preserves_recent_count_from_rust_struct() {
        let ctx = make_test_context();
        let settings = tron_settings::TronSettings::default();
        let mut result = serde_json::to_value(&settings).unwrap();
        adapt_rpc_result_for_ios("settings.get", &mut result, &ctx);
        // preserveRecentCount should be renamed to preserveRecentTurns
        assert_eq!(result["compaction"]["preserveRecentTurns"], 5);
        assert!(result["compaction"].get("preserveRecentCount").is_none());
    }
}
