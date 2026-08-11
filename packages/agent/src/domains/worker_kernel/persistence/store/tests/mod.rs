//! Worker-store tests grouped by the persistence concern they exercise.

use super::*;
use crate::domains::worker_kernel::types::{WorkerPresentation, WorkerRunner, WorkerTrigger};

fn bundle() -> WorkerBundle {
    WorkerBundle {
        schema_version: BUNDLE_SCHEMA.to_owned(),
        worker_id: None,
        name: "Recent Research".to_owned(),
        description: "Research a topic across recent sources".to_owned(),
        tool_name: None,
        model_exposure: Default::default(),
        tool_input_schema: Some(json!({
            "type":"object",
            "properties":{"topic":{"type":"string"}}
        })),
        agent_tools: None,
        agent_role: None,
        input_schema: json!({"type":"object","properties":{"topic":{"type":"string"}}}),
        output_schema: json!({"type":"object"}),
        runner: WorkerRunner::Command {
            command: vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()],
        },
        files: Default::default(),
        dependencies: Vec::new(),
        triggers: vec![WorkerTrigger::Webhook {
            id: "research".to_owned(),
            input: json!({}),
        }],
        secret_bindings: Vec::new(),
        smoke_tests: Vec::new(),
        health_checks: Vec::new(),
        provenance: vec![super::super::super::types::SourceProvenance {
            source: "test:worker-store".to_owned(),
            revision: Some("1".to_owned()),
            checksum: None,
        }],
        engine_hooks: Vec::new(),
        engine_deliveries: Vec::new(),
        client_actions: Vec::new(),
        client_deliveries: Vec::new(),
        worker_dispatch_routes: Vec::new(),
        routing: Default::default(),
        execution_limits: Default::default(),
        presentation: None,
    }
}

mod agent_coordination;
mod artifacts_presentation;
mod durability;
mod notifications;
mod publication;
mod results;
mod role_review;
