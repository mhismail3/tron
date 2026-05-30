use super::*;
use crate::domains::agent::runner::guardrails::audit::AuditLogger;
use crate::domains::agent::runner::guardrails::rules::RuleBase;
use crate::domains::agent::runner::guardrails::rules::composite::{
    CompositeOperator, CompositeRule,
};
use crate::domains::agent::runner::guardrails::rules::context::ContextRule;
use crate::domains::agent::runner::guardrails::rules::pattern::PatternRule;
use crate::domains::agent::runner::guardrails::rules::resource::ResourceRule;
use crate::domains::agent::runner::guardrails::types::{
    AuditEntry, AuditEntryParams, GuardrailEvaluation, RuleEvaluationResult,
};
use std::collections::HashMap;

fn make_process_ctx(command: &str) -> EvaluationContext {
    EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": command}),
        session_id: Some("test-session".into()),
        invocation_id: Some("call-1".into()),
    }
}

fn make_write_ctx(file_path: &str) -> EvaluationContext {
    EvaluationContext {
        model_primitive_name: "filesystem::write_file".into(),
        capability_arguments: serde_json::json!({"file_path": file_path, "content": "test"}),
        session_id: Some("test-session".into()),
        invocation_id: Some("call-1".into()),
    }
}

fn make_edit_ctx(file_path: &str) -> EvaluationContext {
    EvaluationContext {
        model_primitive_name: "filesystem::edit_file".into(),
        capability_arguments: serde_json::json!({"file_path": file_path}),
        session_id: None,
        invocation_id: None,
    }
}

fn make_read_ctx(file_path: &str) -> EvaluationContext {
    EvaluationContext {
        model_primitive_name: "filesystem::read_file".into(),
        capability_arguments: serde_json::json!({"file_path": file_path}),
        session_id: None,
        invocation_id: None,
    }
}

fn default_engine() -> GuardrailEngine {
    GuardrailEngine::new(GuardrailEngineOptions::default())
}

mod context_composite;
mod engine_audit;
mod pattern_path_resource;
mod serialization;
