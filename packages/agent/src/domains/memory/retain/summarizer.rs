//! Retain summarizer subagent execution.

use std::sync::Arc;

use tracing::warn;

use crate::domains::agent::runner::orchestrator::subagent_manager::{
    SubagentManager, SubsessionConfig,
};

/// Outcome of an attempt to run the LLM summarizer subsession.
pub(super) enum SummarizerOutcome {
    /// Real output from the summarizer subagent.
    Ok(String),
    /// Subagent failed or returned an error. The returned string is the
    /// graceful keyword recovery; `reason` names what went wrong.
    Err { recovery: String, reason: String },
}

/// Run the LLM summarizer subsession and return its text output.
pub(super) async fn run_summarizer(
    manager: Arc<SubagentManager>,
    parent_session_id: &str,
    working_directory: &str,
    transcript: String,
) -> SummarizerOutcome {
    let task = format!("Summarize the provided session transcript:\n\n{transcript}");
    let process_plan = match manager.plan_process("memoryRetain") {
        Ok(plan) => plan,
        Err(error) => {
            let reason = error.to_string();
            warn!(session_id = %parent_session_id, error = %reason, "memory retain process planning failed, using keyword recovery");
            return SummarizerOutcome::Err {
                recovery: keyword_summary(parent_session_id),
                reason,
            };
        }
    };
    let process = &process_plan.process;

    match manager
        .spawn_subsession(SubsessionConfig {
            process_id: Some("memoryRetain".into()),
            parent_session_id: parent_session_id.to_owned(),
            task,
            model: None,
            system_prompt: process_plan
                .prompt
                .as_ref()
                .map(|prompt| prompt.content.clone())
                .unwrap_or_default(),
            working_directory: working_directory.to_owned(),
            timeout_ms: process
                .timeout_ms
                .expect("memoryRetain process must define timeoutMs"),
            inherit_capabilities: process
                .inherit_capabilities
                .expect("memoryRetain process must define inheritCapabilities"),
            max_turns: process
                .max_turns
                .expect("memoryRetain process must define maxTurns"),
            max_depth: process
                .max_depth
                .expect("memoryRetain process must define maxDepth"),
            blocking_timeout_ms: process.blocking_timeout_ms,
            ..SubsessionConfig::default()
        })
        .await
    {
        Ok(result) => SummarizerOutcome::Ok(result.output),
        Err(e) => {
            let reason = e.to_string();
            warn!(session_id = %parent_session_id, error = %reason, "memory summarizer subagent failed, using keyword recovery");
            SummarizerOutcome::Err {
                recovery: keyword_summary(parent_session_id),
                reason,
            }
        }
    }
}

/// Minimal keyword-based recovery when no subagent manager is available.
pub(super) fn keyword_summary(session_id: &str) -> String {
    format!("Session {session_id}")
}
