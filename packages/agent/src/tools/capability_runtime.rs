//! Short-lived runtime context handoff for engine-owned tool execution.
//!
//! Provider-facing schema generation now comes from the live engine catalog.
//! `ToolRegistry` remains a temporary implementation store for built-ins, and
//! prompt-time execution routes through canonical `tool::*` engine functions.
//! Those engine functions need the exact [`ToolContext`] built by the turn
//! runtime so progress output, cancellation, process managers, and event
//! persistence remain intact. This module provides a process-local, one-shot
//! handoff keyed by a deterministic runtime invocation id.

use std::collections::HashMap;
use std::sync::OnceLock;

use parking_lot::Mutex;
use serde_json::Value;

use crate::tools::traits::ToolContext;

/// One pending tool execution prepared by the agent runtime.
#[derive(Clone)]
pub(crate) struct RuntimeToolExecution {
    /// Tool name expected by the engine function.
    pub tool_name: String,
    /// Effective arguments after guardrails and pre-tool hooks.
    pub params: Value,
    /// Rich runtime context for this exact tool call.
    pub context: ToolContext,
}

fn executions() -> &'static Mutex<HashMap<String, RuntimeToolExecution>> {
    static EXECUTIONS: OnceLock<Mutex<HashMap<String, RuntimeToolExecution>>> = OnceLock::new();
    EXECUTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Insert a one-shot runtime execution context.
pub(crate) fn insert_runtime_tool_execution(id: String, execution: RuntimeToolExecution) {
    let _ = executions().lock().insert(id, execution);
}

/// Take a one-shot runtime execution context.
pub(crate) fn take_runtime_tool_execution(id: &str) -> Option<RuntimeToolExecution> {
    executions().lock().remove(id)
}

/// Remove a pending runtime execution context that was never consumed.
pub(crate) fn remove_runtime_tool_execution(id: &str) {
    let _ = executions().lock().remove(id);
}

/// Return the canonical engine function id for a tool name.
pub(crate) fn canonical_tool_function_id(tool_name: &str) -> String {
    format!("tool::{}", sanitize_tool_function_name(tool_name))
}

fn sanitize_tool_function_name(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            output.push(ch.to_ascii_lowercase());
        } else {
            output.push('_');
        }
    }
    let trimmed = output.trim_matches('_');
    if trimmed.is_empty() {
        "unnamed".to_owned()
    } else {
        trimmed.to_owned()
    }
}
