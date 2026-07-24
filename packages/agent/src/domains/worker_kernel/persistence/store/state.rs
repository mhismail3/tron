//! Filesystem-owned state lookup, semantic-overlap selection, and complete
//! candidate bundle validation.

use super::*;

impl WorkerStore {
    pub(super) fn read_state(&self, worker_id: &str) -> Result<Option<WorkerState>, String> {
        validate_identifier(worker_id, "workerId")?;
        let path = self.root.join(worker_id).join("worker.json");
        if !path.exists() {
            return Ok(None);
        }
        serde_json::from_slice(&fs::read(path).map_err(|error| error.to_string())?)
            .map(Some)
            .map_err(|error| format!("decode worker state: {error}"))
    }

    pub(super) fn closest_overlap(
        &self,
        bundle: &WorkerBundle,
        minimum_score: f64,
    ) -> Result<Option<String>, String> {
        let target_name = terms(&bundle.name);
        let target = terms(&format!(
            "{} {} {} {}",
            bundle.name,
            bundle.description,
            bundle.routing.intents.join(" "),
            bundle.routing.examples.join(" ")
        ));
        let mut best: Option<(f64, String)> = None;
        for worker in self.list(false)? {
            let Ok(active) = self.load_active(&worker.worker_id) else {
                continue;
            };
            let candidate_name = terms(&worker.name);
            let candidate = terms(&format!(
                "{} {} {} {}",
                worker.name,
                worker.description,
                active.bundle.routing.intents.join(" "),
                active.bundle.routing.examples.join(" ")
            ));
            let score = jaccard(&target_name, &candidate_name).max(jaccard(&target, &candidate));
            if score >= minimum_score && best.as_ref().is_none_or(|current| score > current.0) {
                best = Some((score, worker.worker_id));
            }
        }
        Ok(best.map(|(_, worker_id)| worker_id))
    }
}

pub(in crate::domains::worker_kernel::persistence) fn validate_bundle(
    bundle: &WorkerBundle,
) -> Result<(), String> {
    if bundle.schema_version != BUNDLE_SCHEMA {
        return Err(format!(
            "unsupported worker bundle schema '{}'",
            bundle.schema_version
        ));
    }
    if bundle.name.trim().is_empty() || bundle.description.trim().is_empty() {
        return Err("worker name and description are required".to_owned());
    }
    validate_object_schema(&bundle.input_schema, "inputSchema")?;
    validate_object_schema(&bundle.output_schema, "outputSchema")?;
    if let Some(presentation) = &bundle.presentation {
        validate_identifier(&presentation.experience_id, "presentation experienceId")?;
        if presentation.contract_version == 0 {
            return Err("presentation contractVersion must be greater than zero".to_owned());
        }
        if let Some(suite_id) = presentation.suite_id.as_deref() {
            validate_identifier(suite_id, "presentation suiteId")?;
        }
        if let Some(role) = presentation.component_role.as_deref() {
            validate_identifier(role, "presentation componentRole")?;
        }
        if presentation.primary && presentation.suite_id.is_none() {
            return Err("a primary presentation component requires suiteId".to_owned());
        }
    }
    let mut engine_hooks = BTreeSet::new();
    for hook in &bundle.engine_hooks {
        if !engine_hooks.insert(*hook) {
            return Err(format!("duplicate engine hook '{}'", hook.as_str()));
        }
        validate_engine_hook_contract(*hook, bundle)?;
    }
    let mut client_actions = BTreeSet::new();
    for action in &bundle.client_actions {
        if !client_actions.insert(*action) {
            return Err(format!("duplicate client action '{}'", action.as_str()));
        }
        validate_client_action_contract(*action, bundle)?;
    }
    let mut trigger_ids = BTreeSet::new();
    for trigger in &bundle.triggers {
        validate_identifier(trigger.id(), "trigger id")?;
        if !trigger_ids.insert(trigger.id()) {
            return Err(format!("duplicate trigger id '{}'", trigger.id()));
        }
        match trigger {
            WorkerTrigger::Schedule { every_seconds, .. } if *every_seconds == 0 => {
                return Err("schedule everySeconds must be greater than zero".to_owned());
            }
            WorkerTrigger::EngineEvent { topic, .. } if topic.trim().is_empty() => {
                return Err("engine event topic must not be empty".to_owned());
            }
            WorkerTrigger::EngineEvent { filter, .. } if !filter.is_object() => {
                return Err("engine event filter must be a JSON object".to_owned());
            }
            WorkerTrigger::Schedule { id, input, .. } => {
                let function_id =
                    crate::engine::FunctionId::new(format!("worker_kernel::schedule_{id}"))
                        .map_err(|error| error.to_string())?;
                crate::engine::validate_engine_schema_payload(
                    &function_id,
                    "request",
                    &bundle.input_schema,
                    input,
                )
                .map_err(|error| {
                    format!("schedule trigger '{id}' input does not match inputSchema: {error}")
                })?;
            }
            _ => {}
        }
    }
    let mut secrets = BTreeSet::new();
    for binding in &bundle.secret_bindings {
        validate_identifier(binding.name(), "secret binding")?;
        if !secrets.insert(binding.name()) {
            return Err(format!("duplicate secret binding '{}'", binding.name()));
        }
    }
    for relative in bundle.files.keys() {
        let _ = safe_relative_path(relative)?;
    }
    match &bundle.runner {
        WorkerRunner::Agent {
            instructions,
            model,
        } => {
            if instructions.trim().is_empty() {
                return Err("agent runner instructions must not be empty".to_owned());
            }
            if model
                .as_deref()
                .is_some_and(|model| model.trim().is_empty())
            {
                return Err("agent runner model must not be empty when provided".to_owned());
            }
        }
        WorkerRunner::Command { command } => validate_command(command)?,
        WorkerRunner::Service {
            command,
            invoke_url,
            health_url,
        } => {
            validate_command(command)?;
            validate_resident_url(invoke_url, "invokeUrl")?;
            if let Some(health_url) = health_url {
                validate_resident_url(health_url, "healthUrl")?;
            }
        }
    }
    for dependency in &bundle.dependencies {
        validate_identifier(&dependency.name, "dependency name")?;
        if dependency.name.trim().is_empty()
            || dependency.source.trim().is_empty()
            || dependency.version.trim().is_empty()
        {
            return Err("dependencies require name, source, and exact version".to_owned());
        }
        if dependency.version.eq_ignore_ascii_case("latest")
            || dependency
                .version
                .chars()
                .any(|character| matches!(character, '*' | '^' | '~' | '<' | '>'))
        {
            return Err(format!(
                "dependency '{}' must lock an exact version or revision",
                dependency.name
            ));
        }
        if let Some(expected) = dependency.checksum.as_deref() {
            let checksum = expected.strip_prefix("sha256:").ok_or_else(|| {
                format!(
                    "dependency '{}' checksum must start with sha256:",
                    dependency.name
                )
            })?;
            if checksum.len() != 64
                || !checksum
                    .chars()
                    .all(|character| character.is_ascii_hexdigit())
            {
                return Err(format!(
                    "dependency '{}' checksum must be sha256 followed by 64 hex characters",
                    dependency.name
                ));
            }
        }
        if let Some(install) = &dependency.install {
            validate_worker_command(install, "dependency install")?;
        }
    }
    for test in &bundle.smoke_tests {
        validate_worker_command(test, "smoke test")?;
    }
    for check in &bundle.health_checks {
        validate_worker_command(check, "health check")?;
    }
    if bundle.provenance.is_empty() {
        return Err("worker provenance requires at least one source record".to_owned());
    }
    for provenance in &bundle.provenance {
        if provenance.source.trim().is_empty() {
            return Err("worker provenance source must not be empty".to_owned());
        }
    }
    Ok(())
}

fn validate_engine_hook_contract(
    hook: WorkerEngineHook,
    bundle: &WorkerBundle,
) -> Result<(), String> {
    let (input, output, invalid_inputs, invalid_outputs) = match hook {
        WorkerEngineHook::ContextSummary => (
            json!({
                "originWorkerId":"delegated-context",
                "messages": [
                    {"role":"user","text":"Summarize the durable task context."},
                    {"role":"assistant","text":"I inspected the relevant state."},
                    {"role":"tool","text":"filesystem_read completed"}
                ]
            }),
            json!({"narrative":"The user asked to preserve the durable task context."}),
            vec![json!({})],
            vec![
                json!({}),
                json!({"narrative":""}),
                json!({"narrative":"x".repeat(super::super::super::CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES + 1)}),
            ],
        ),
        WorkerEngineHook::InboxContext => (
            json!({
                "query":"finish the background research",
                "items":[{
                    "inboxId":"worker_inbox_test",
                    "invocationId":"worker_run_test",
                    "workerId":"recent-research",
                    "workerName":"Recent Research",
                    "workerDescription":"Researches recent sources",
                    "severity":"info",
                    "triggerKind":"schedule",
                    "resultPreview":"{\"summary\":\"Research completed\"}",
                    "createdAt":"2026-07-21T00:00:00Z"
                }]
            }),
            json!({
                "consumedInboxIds":["worker_inbox_test"],
                "narrative":"The scheduled research worker completed its report."
            }),
            vec![json!({}), json!({"query":"missing items"})],
            vec![
                json!({}),
                json!({"consumedInboxIds":[""],"narrative":"invalid id"}),
                json!({"consumedInboxIds":"invalid","narrative":"invalid list"}),
                json!({"consumedInboxIds":[],"narrative":7}),
            ],
        ),
        WorkerEngineHook::SessionTitle => (
            json!({
                "userPrompt":"Build a durable work ledger for goals and questions.",
                "assistantResponse":"I created and verified the Work Ledger worker."
            }),
            json!({"title":"Build a Durable Work Ledger"}),
            vec![
                json!({}),
                json!({"userPrompt":"missing assistant response"}),
            ],
            vec![
                json!({}),
                json!({"title":""}),
                json!({"title":"x".repeat(161)}),
            ],
        ),
        WorkerEngineHook::WorkerRelevance => (
            json!({
                "query":"recent compiler research",
                "candidates":[{
                    "workerId":"recent-research",
                    "name":"Recent Research",
                    "description":"Researches recent sources",
                    "intents":["recent research"],
                    "examples":["What changed this month?"],
                    "provenance":["test:fixture@1"],
                    "completedRuns":3,
                    "updatedAt":"2026-07-21T00:00:00Z"
                }]
            }),
            json!({
                "rankings":[{
                    "workerId":"recent-research",
                    "score":900,
                    "reason":"semantic match"
                }]
            }),
            vec![json!({}), json!({"query":"missing candidates"})],
            vec![json!({}), json!({"rankings":[{"workerId":"","score":-1}]})],
        ),
    };
    let function_id =
        crate::engine::FunctionId::new(format!("worker_kernel::engine_hook_{}", hook.as_str()))
            .map_err(|error| error.to_string())?;
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "request",
        &bundle.input_schema,
        &input,
    )
    .map_err(|error| {
        format!(
            "engine hook '{}' input does not match inputSchema: {error}",
            hook.as_str()
        )
    })?;
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "response",
        &bundle.output_schema,
        &output,
    )
    .map_err(|error| {
        format!(
            "engine hook '{}' output does not match outputSchema: {error}",
            hook.as_str()
        )
    })?;
    for invalid in invalid_inputs {
        if crate::engine::validate_engine_schema_payload(
            &function_id,
            "request",
            &bundle.input_schema,
            &invalid,
        )
        .is_ok()
        {
            return Err(format!(
                "engine hook '{}' inputSchema accepts invalid hook payload {invalid}",
                hook.as_str(),
            ));
        }
    }
    for invalid in invalid_outputs {
        if crate::engine::validate_engine_schema_payload(
            &function_id,
            "response",
            &bundle.output_schema,
            &invalid,
        )
        .is_ok()
        {
            return Err(format!(
                "engine hook '{}' outputSchema accepts invalid hook payload {invalid}",
                hook.as_str(),
            ));
        }
    }
    Ok(())
}

fn validate_client_action_contract(
    action: WorkerClientAction,
    bundle: &WorkerBundle,
) -> Result<(), String> {
    let (input, output, invalid_inputs, invalid_outputs) = match action {
        WorkerClientAction::SpeechTranscription => (
            json!({
                "audioBase64":"UklGRg==",
                "mimeType":"audio/wav",
                "fileName":"voice.wav"
            }),
            json!({"text":"Hello Tron"}),
            vec![
                json!({}),
                json!({"audioBase64":"UklGRg==","mimeType":"audio/wav"}),
                json!({"audioBase64":7,"mimeType":"audio/wav","fileName":"voice.wav"}),
            ],
            vec![json!({}), json!({"text":7})],
        ),
    };
    let function_id =
        crate::engine::FunctionId::new(format!("worker_kernel::client_action_{}", action.as_str()))
            .map_err(|error| error.to_string())?;
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "request",
        &bundle.input_schema,
        &input,
    )
    .map_err(|error| {
        format!(
            "client action '{}' input does not match inputSchema: {error}",
            action.as_str()
        )
    })?;
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "response",
        &bundle.output_schema,
        &output,
    )
    .map_err(|error| {
        format!(
            "client action '{}' output does not match outputSchema: {error}",
            action.as_str()
        )
    })?;
    for invalid in invalid_inputs {
        if crate::engine::validate_engine_schema_payload(
            &function_id,
            "request",
            &bundle.input_schema,
            &invalid,
        )
        .is_ok()
        {
            return Err(format!(
                "client action '{}' inputSchema accepts invalid client payload {invalid}",
                action.as_str(),
            ));
        }
    }
    for invalid in invalid_outputs {
        if crate::engine::validate_engine_schema_payload(
            &function_id,
            "response",
            &bundle.output_schema,
            &invalid,
        )
        .is_ok()
        {
            return Err(format!(
                "client action '{}' outputSchema accepts invalid client payload {invalid}",
                action.as_str(),
            ));
        }
    }
    Ok(())
}
