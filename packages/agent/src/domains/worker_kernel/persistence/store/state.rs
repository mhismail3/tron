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
    if bundle.exposes_model_tool() && bundle.tool_input_schema.is_none() {
        return Err("modelExposure direct requires toolInputSchema".to_owned());
    }
    if let Some(tool_input_schema) = &bundle.tool_input_schema {
        if !bundle.exposes_model_tool() {
            return Err("toolInputSchema is only valid when modelExposure is direct".to_owned());
        }
        validate_object_schema(tool_input_schema, "toolInputSchema")?;
    }
    validate_object_schema(&bundle.output_schema, "outputSchema")?;
    if bundle
        .execution_limits
        .max_invocation_seconds
        .is_some_and(|limit| !(1..=MAX_INVOCATION_SECONDS).contains(&limit))
    {
        return Err(format!(
            "executionLimits.maxInvocationSeconds must be between 1 and {MAX_INVOCATION_SECONDS}"
        ));
    }
    if bundle
        .execution_limits
        .max_agent_turns
        .is_some_and(|limit| !(1..=250).contains(&limit))
    {
        return Err("executionLimits.maxAgentTurns must be between 1 and 250".to_owned());
    }
    if bundle
        .execution_limits
        .max_child_invocations
        .is_some_and(|limit| limit > 256)
    {
        return Err("executionLimits.maxChildInvocations must be at most 256".to_owned());
    }
    if let Some(presentation) = &bundle.presentation {
        validate_presentation(presentation, &bundle.input_schema)?;
    }
    let mut engine_hooks = BTreeSet::new();
    for hook in &bundle.engine_hooks {
        if !engine_hooks.insert(*hook) {
            return Err(format!("duplicate engine hook '{}'", hook.as_str()));
        }
        validate_engine_hook_contract(*hook, bundle)?;
    }
    let mut engine_deliveries = BTreeSet::new();
    for delivery in &bundle.engine_deliveries {
        if !engine_deliveries.insert(*delivery) {
            return Err(format!("duplicate engine delivery '{}'", delivery.as_str()));
        }
    }
    if bundle
        .engine_deliveries
        .contains(&WorkerEngineDelivery::AgentDelivery)
        && bundle
            .output_schema
            .get("properties")
            .and_then(Value::as_object)
            .is_none_or(|properties| !properties.contains_key("agentDeliveries"))
    {
        return Err(
            "outputSchema must explicitly declare the reserved agentDeliveries property when engineDeliveries contains agent_delivery"
                .to_owned(),
        );
    }
    let mut client_actions = BTreeSet::new();
    for action in &bundle.client_actions {
        if !client_actions.insert(*action) {
            return Err(format!("duplicate client action '{}'", action.as_str()));
        }
        validate_client_action_contract(*action, bundle)?;
    }
    let mut client_deliveries = BTreeSet::new();
    for delivery in &bundle.client_deliveries {
        if !client_deliveries.insert(*delivery) {
            return Err(format!("duplicate client delivery '{}'", delivery.as_str()));
        }
    }
    if bundle
        .client_deliveries
        .contains(&WorkerClientDelivery::ArtifactDelivery)
        && bundle
            .output_schema
            .get("properties")
            .and_then(Value::as_object)
            .is_none_or(|properties| !properties.contains_key("artifactDeliveries"))
    {
        return Err(
            "outputSchema must explicitly declare the reserved artifactDeliveries property when clientDeliveries contains artifact_delivery"
                .to_owned(),
        );
    }
    let mut dispatch_routes = BTreeSet::new();
    for route in &bundle.worker_dispatch_routes {
        validate_identifier(&route.route, "worker dispatch route")?;
        if route.route.len() > 64 {
            return Err("worker dispatch route must be at most 64 UTF-8 bytes".to_owned());
        }
        validate_identifier(&route.target_worker_id, "worker dispatch targetWorkerId")?;
        if !dispatch_routes.insert(route.route.as_str()) {
            return Err(format!("duplicate worker dispatch route '{}'", route.route));
        }
    }
    if !bundle.worker_dispatch_routes.is_empty()
        && bundle
            .output_schema
            .get("properties")
            .and_then(Value::as_object)
            .is_none_or(|properties| !properties.contains_key("workerDispatches"))
    {
        return Err(
            "outputSchema must explicitly declare the reserved workerDispatches property when workerDispatchRoutes are present"
                .to_owned(),
        );
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
    if let Some(agent_tools) = &bundle.agent_tools {
        if !matches!(bundle.runner, WorkerRunner::Agent { .. }) {
            return Err("agentTools is only valid for agent runners".to_owned());
        }
        if agent_tools.len() > 32 {
            return Err("agentTools must contain at most 32 model tool names".to_owned());
        }
        let mut unique_agent_tools = BTreeSet::new();
        for tool_name in agent_tools {
            if tool_name.len() > 64 {
                return Err("agentTools entries must be at most 64 UTF-8 bytes".to_owned());
            }
            validate_identifier(tool_name, "agentTools entry")?;
            if !unique_agent_tools.insert(tool_name.as_str()) {
                return Err(format!("duplicate agentTools entry '{tool_name}'"));
            }
        }
    }
    match &bundle.runner {
        WorkerRunner::Agent {
            instructions,
            model,
            reasoning_level,
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
            if reasoning_level.as_deref().is_some_and(|level| {
                crate::domains::agent::r#loop::types::ReasoningLevel::from_str_canonical(level)
                    .is_none()
            }) {
                return Err(
                    "agent runner reasoningLevel must be one of none, low, medium, high, x_high, or max"
                        .to_owned(),
                );
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

const MAX_PRESENTATION_SECTIONS: usize = 24;
const MAX_PRESENTATION_COLUMNS: usize = 8;
const MAX_PRESENTATION_POINTER_BYTES: usize = 256;
const MAX_PRESENTATION_ACTION_INPUT_BYTES: usize = 16 * 1_024;
const MAX_PRESENTATION_BYTES: usize = 64 * 1_024;

fn validate_presentation(
    presentation: &WorkerPresentation,
    input_schema: &Value,
) -> Result<(), String> {
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
    if presentation.sections.len() > MAX_PRESENTATION_SECTIONS {
        return Err(format!(
            "presentation sections must contain at most {MAX_PRESENTATION_SECTIONS} items"
        ));
    }
    let encoded_bytes = serde_json::to_vec(presentation)
        .map_err(|error| format!("encode presentation: {error}"))?
        .len();
    if encoded_bytes > MAX_PRESENTATION_BYTES {
        return Err(format!(
            "presentation descriptor must be at most {MAX_PRESENTATION_BYTES} UTF-8 bytes"
        ));
    }

    let mut section_ids = BTreeSet::new();
    let mut action_ids = BTreeSet::new();
    for section in &presentation.sections {
        validate_identifier(&section.section_id, "presentation sectionId")?;
        if !section_ids.insert(section.section_id.as_str()) {
            return Err(format!(
                "duplicate presentation sectionId '{}'",
                section.section_id
            ));
        }
        validate_optional_presentation_text(
            section.title.as_deref(),
            "presentation section title",
            80,
        )?;
        validate_optional_presentation_text(
            section.detail.as_deref(),
            "presentation section detail",
            512,
        )?;
        validate_optional_presentation_text(
            section.label.as_deref(),
            "presentation section label",
            80,
        )?;
        if let Some(pointer) = section.value_pointer.as_deref() {
            validate_presentation_pointer(pointer, "presentation section valuePointer")?;
        }
        if section.columns.len() > MAX_PRESENTATION_COLUMNS {
            return Err(format!(
                "presentation table columns must contain at most {MAX_PRESENTATION_COLUMNS} items"
            ));
        }
        for column in &section.columns {
            validate_presentation_text(&column.label, "presentation column label", 80)?;
            validate_presentation_pointer(
                &column.value_pointer,
                "presentation column valuePointer",
            )?;
        }
        if let Some(action) = section.action.as_ref() {
            validate_identifier(&action.action_id, "presentation actionId")?;
            if !action_ids.insert(action.action_id.as_str()) {
                return Err(format!(
                    "duplicate presentation actionId '{}'",
                    action.action_id
                ));
            }
            validate_presentation_text(&action.label, "presentation action label", 80)?;
            let input_bytes = serde_json::to_vec(&action.input)
                .map_err(|error| format!("encode presentation action input: {error}"))?
                .len();
            if input_bytes > MAX_PRESENTATION_ACTION_INPUT_BYTES {
                return Err(format!(
                    "presentation action input must be at most {MAX_PRESENTATION_ACTION_INPUT_BYTES} UTF-8 bytes"
                ));
            }
            let function_id = crate::engine::FunctionId::new("worker_kernel::presentation_action")
                .map_err(|error| error.to_string())?;
            crate::engine::validate_engine_schema_payload(
                &function_id,
                "request",
                input_schema,
                &action.input,
            )
            .map_err(|error| {
                format!(
                    "presentation action '{}' input does not match inputSchema: {error}",
                    action.action_id
                )
            })?;
        }
        validate_presentation_section_shape(section)?;
    }
    Ok(())
}

fn validate_presentation_section_shape(section: &WorkerPresentationSection) -> Result<(), String> {
    use WorkerPresentationSectionKind as Kind;

    let has_pointer = section.value_pointer.is_some();
    let has_columns = !section.columns.is_empty();
    let has_label = section.label.is_some();
    let has_url = section.url.is_some();
    let has_action = section.action.is_some();
    let shape_is_valid = match section.kind {
        Kind::Text | Kind::Status | Kind::Progress | Kind::List => {
            has_pointer && !has_columns && !has_label && !has_url && !has_action
        }
        Kind::Table => has_pointer && has_columns && !has_label && !has_url && !has_action,
        Kind::Link => !has_pointer && !has_columns && has_label && has_url && !has_action,
        Kind::Artifact => has_pointer && !has_columns && has_label && !has_url && !has_action,
        Kind::Confirmation => {
            section.title.is_some()
                && section.detail.is_some()
                && !has_pointer
                && !has_columns
                && !has_label
                && !has_url
                && has_action
        }
        Kind::WorkerAction => !has_pointer && !has_columns && !has_label && !has_url && has_action,
    };
    if !shape_is_valid {
        return Err(format!(
            "presentation section '{}' has fields incompatible with kind {:?}",
            section.section_id, section.kind
        ));
    }
    if let Some(url) = section.url.as_deref() {
        validate_presentation_url(url)?;
    }
    Ok(())
}

fn validate_presentation_text(value: &str, field: &str, max_bytes: usize) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > max_bytes || value.chars().any(char::is_control) {
        return Err(format!(
            "{field} must be non-empty, at most {max_bytes} UTF-8 bytes, and contain no control characters"
        ));
    }
    Ok(())
}

fn validate_optional_presentation_text(
    value: Option<&str>,
    field: &str,
    max_bytes: usize,
) -> Result<(), String> {
    value.map_or(Ok(()), |value| {
        validate_presentation_text(value, field, max_bytes)
    })
}

fn validate_presentation_pointer(value: &str, field: &str) -> Result<(), String> {
    if value.len() > MAX_PRESENTATION_POINTER_BYTES
        || (!value.is_empty() && !value.starts_with('/'))
    {
        return Err(format!(
            "{field} must be an RFC 6901 JSON pointer of at most {MAX_PRESENTATION_POINTER_BYTES} UTF-8 bytes"
        ));
    }
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'~' {
            if index + 1 >= bytes.len() || !matches!(bytes[index + 1], b'0' | b'1') {
                return Err(format!("{field} contains an invalid RFC 6901 escape"));
            }
            index += 2;
        } else {
            index += 1;
        }
    }
    Ok(())
}

fn validate_presentation_url(value: &str) -> Result<(), String> {
    if value.len() > 2_048 {
        return Err("presentation link URL must be at most 2048 UTF-8 bytes".to_owned());
    }
    let url = url::Url::parse(value).map_err(|error| format!("presentation link URL: {error}"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.host().is_some_and(presentation_host_is_local)
    {
        return Err(
            "presentation link URL must be an absolute public HTTPS URL without embedded credentials"
                .to_owned(),
        );
    }
    Ok(())
}

fn presentation_host_is_local(host: url::Host<&str>) -> bool {
    match host {
        url::Host::Domain(domain) => {
            domain.eq_ignore_ascii_case("localhost")
                || domain
                    .to_ascii_lowercase()
                    .strip_suffix(".localhost")
                    .is_some()
        }
        url::Host::Ipv4(address) => {
            address.is_private()
                || address.is_loopback()
                || address.is_link_local()
                || address.is_unspecified()
                || address.is_multicast()
                || address.is_broadcast()
        }
        url::Host::Ipv6(address) => {
            let first = address.segments()[0];
            address.is_loopback()
                || address.is_unspecified()
                || address.is_multicast()
                || first & 0xfe00 == 0xfc00
                || first & 0xffc0 == 0xfe80
        }
    }
}

fn validate_engine_hook_contract(
    hook: WorkerEngineHook,
    bundle: &WorkerBundle,
) -> Result<(), String> {
    let (input, output, invalid_inputs, invalid_outputs) = match hook {
        WorkerEngineHook::ContinuityContext => (
            json!({
                "action":"continuity_context",
                "query":"notification testing preferences",
                "project":"/workspace/example",
                "limit":6
            }),
            json!({
                "narrative":"Relevant saved continuity: use physical-device acceptance."
            }),
            vec![
                json!({}),
                json!({"action":"continuity_context","query":""}),
                json!({"action":"continuity_context","query":"x","limit":9}),
            ],
            vec![
                json!({}),
                json!({"narrative":7}),
                json!({"narrative":"x".repeat(6_001)}),
            ],
        ),
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
        WorkerEngineHook::MailboxCuration => (
            json!({
                "sessionId":"session_test",
                "candidates":[{
                    "deliveryId":"delivery_test",
                    "sourceKind":"worker_result",
                    "intent":"information",
                    "preview":"The requested report is ready.",
                    "createdAt":"2026-07-21T00:00:00Z"
                }]
            }),
            json!({"selectedDeliveryIds":["delivery_test"]}),
            vec![json!({}), json!({"sessionId":"session_test"})],
            vec![
                json!({}),
                json!({"selectedDeliveryIds":[""]}),
                json!({"selectedDeliveryIds":"delivery_test"}),
            ],
        ),
        WorkerEngineHook::SessionOrganization => (
            json!({
                "action":"session_organization",
                "session":{
                    "sessionId":"session_test",
                    "title":"Implement session organization",
                    "workingDirectory":"/workspace/example",
                    "labels":["Work"],
                    "group":"Projects",
                    "isArchived":false
                },
                "userPrompt":"Organize this completed task.",
                "assistantResponse":"The requested implementation and tests are complete."
            }),
            json!({
                "status":"proposed",
                "proposal":{
                    "sessionId":"session_test",
                    "labels":["Work","Completed"],
                    "group":"Projects",
                    "archiveAction":"preserve",
                    "reason":"Keep active implementation work together."
                }
            }),
            vec![json!({}), json!({"action":"session_organization"})],
            vec![
                json!({}),
                json!({"proposal":{"sessionId":"","labels":[],"archiveAction":"delete"}}),
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
    if hook == WorkerEngineHook::ContinuityContext
        && bundle
            .output_schema
            .pointer("/properties/sources")
            .is_some()
    {
        let sourced = json!({
            "narrative":"Relevant saved continuity.",
            "sources":[{
                "memoryId":"memory-1",
                "revision":2,
                "scope":"project",
                "project":"/workspace/example"
            }]
        });
        crate::engine::validate_engine_schema_payload(
            &function_id,
            "response",
            &bundle.output_schema,
            &sourced,
        )
        .map_err(|error| {
            format!(
                "engine hook '{}' sources do not match outputSchema: {error}",
                hook.as_str()
            )
        })?;
    }
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
