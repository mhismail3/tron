//! # `OpenAI` Message Converter
//!
//! Converts between Tron message format and `OpenAI` Responses API format.
//! Handles capability invocation ID remapping for cross-provider DTO parity.
//!
//! Key behaviors:
//! - User messages → `input_text` / `input_image` content
//! - Assistant text → `output_text` content
//! - Capability invocations → `function_call` items with remapped IDs
//! - Capability results → `function_call_output` items (truncated at 16k)
//! - Documents → placeholder text (`OpenAI` doesn't support documents directly)

use crate::domains::capability::operation_list_text;
use crate::domains::model::providers::{
    IdFormat, build_invocation_id_mapping, remap_invocation_id,
};
use crate::shared::protocol::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Message, UserMessageContent,
};
use crate::shared::protocol::model_capabilities::ModelCapability;

use super::types::{
    MessageContent, ResponsesInputItem, ResponsesToolEntry, TOOL_RESULT_MAX_LENGTH,
};

/// Convert Tron messages to Responses API input format.
///
/// Capability invocation IDs from other providers (e.g., Anthropic's `toolu_` prefix)
/// are remapped to `OpenAI`-compatible `call_` format for cross-provider support.
#[must_use]
pub fn convert_to_responses_input(messages: &[Message]) -> Vec<ResponsesInputItem> {
    let mut input = Vec::new();

    // Build capability invocation ID mapping for cross-provider switching
    let all_invocation_ids = collect_invocation_ids(messages);
    let id_refs: Vec<&str> = all_invocation_ids.iter().map(String::as_str).collect();
    let id_mapping = build_invocation_id_mapping(&id_refs, IdFormat::OpenAi);

    for msg in messages {
        match msg {
            Message::User { content, .. } => {
                convert_user_message(content, &mut input);
            }
            Message::Assistant { content, .. } => {
                convert_assistant_message(content, &id_mapping, &mut input);
            }
            Message::CapabilityResult {
                invocation_id,
                content,
                ..
            } => {
                convert_capability_result(invocation_id, content, &id_mapping, &mut input);
            }
        }
    }

    input
}

/// Convert Tron capabilities to Responses API tool entries.
///
/// The primitive branch always exports concrete function entries. Hosted
/// tool-search/deferred loading is intentionally ignored so provider requests
/// match the single checked-in `execute` surface.
#[must_use]
pub fn convert_tools_v2(capabilities: &[ModelCapability]) -> Vec<ResponsesToolEntry> {
    capabilities
        .iter()
        .map(|t| {
            let schema = serde_json::to_value(&t.parameters).unwrap_or_default();
            let params = normalize_schema_for_openai(&schema);
            ResponsesToolEntry::Function {
                name: t.name.clone(),
                description: t.description.clone(),
                parameters: params,
            }
        })
        .collect()
}

/// Normalize a JSON schema for the `OpenAI` API.
///
/// `OpenAI` requires `"items"` on every `"type": "array"` schema.
/// This recursively walks the schema and adds `"items": {}` where missing.
pub fn normalize_schema_for_openai(schema: &serde_json::Value) -> serde_json::Value {
    match schema {
        serde_json::Value::Object(map) => {
            let mut patched = serde_json::Map::new();
            for (key, value) in map {
                let _ = patched.insert(key.clone(), normalize_schema_for_openai(value));
            }
            // If this object is an array type without `items`, add a permissive default.
            if patched.get("type").and_then(|v| v.as_str()) == Some("array")
                && !patched.contains_key("items")
            {
                let _ = patched.insert("items".into(), serde_json::json!({}));
            }
            serde_json::Value::Object(patched)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(normalize_schema_for_openai).collect())
        }
        other => other.clone(),
    }
}

/// Generate provider instruction text for the single `execute` primitive.
///
/// Since `OpenAI` Codex has its own built-in system instructions that reference
/// capabilities we don't use (shell, `apply_patch`, etc.), this text clarifies
/// the actual available capability surface in the request instructions.
#[must_use]
pub fn generate_capability_instruction_text(capabilities: &[ModelCapability]) -> String {
    let tool_descriptions: Vec<String> = capabilities
        .iter()
        .map(|t| {
            let required = serde_json::to_value(&t.parameters)
                .ok()
                .and_then(|v| v.get("required").cloned())
                .and_then(|v| {
                    v.as_array().map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                })
                .unwrap_or_else(|| "none".into());
            format!(
                "- **{}**: {} (required params: {required})",
                t.name, t.description
            )
        })
        .collect();

    format!(
        "[TRON CONTEXT]\n\
        You are Tron, an AI coding assistant running in Tron's primitive loop.\n\
        \n\
        ## Available Primitive\n\
        Use ONLY this model-facing tool:\n\
        \n\
        {tool_list}\n\
        \n\
        ## Execute Operations\n\
        Each `execute` call performs one direct host operation. Set `operation` to exactly one of: \
        {operation_list}. \
        Do not send `target`, `contractId`, `functionId`, or `arguments`. \
        Catalog discovery operations inspect metadata/conformance only and never execute discovered \
        functions. Put operation fields at the top level of the execute payload. \
        Use `observe` to record reasoning-relevant facts, state operations for agent-owned memory, \
        filesystem package \
        operations for bounded read/list/find/glob/search/diff and preview-first write/edit/patch under \
        trusted roots, `git_status`, `git_diff`, and `git_branch_inventory` for read-only repository/worktree status, \
        bounded staged/unstaged diff evidence, and bounded local branch inventory, `git_stage` and `git_unstage` for explicit relative-path Git index \
        mutations that require `expectedHead`, `reason`, and a stable `idempotencyKey`, `git_commit` for one already-staged index commit with `message`, `expectedHead`, `expectedIndexTree`, `reason`, and `idempotencyKey`, `git_branch_start` for one new local branch at `expectedHead` with `branchName`, `reason`, and `idempotencyKey` without checkout/file updates, `process_run` for short bounded shell commands, job operations for durable \
        non-interactive command lifecycle/status/log/cancel, goal/question operations for durable lifecycle records and expected-version answer handoff, `web_fetch` for one explicit URL with declared network authority and durable `web_source` evidence, optionally gated by a current-session allow `web_robots_policy` using `webRobotsPolicyResourceId` plus `expectedWebRobotsPolicyVersionId`, `web_robots_check` for one origin `robots.txt` policy check with declared network authority, durable `web_robots_policy` evidence, and sitemap lines recorded only as metadata with no traversal, `web_source_list`/`web_source_inspect` for bounded citation fields from current-session `web_source` resources without network access, `web_source_archive` for current-session source archive lifecycle updates with `webSourceResourceId`, `expectedWebSourceVersionId`, `reason`, and stable `idempotencyKey` under `networkPolicy: none`, `web_research_request_record`/`web_research_request_list`/`web_research_request_inspect`, `web_research_review_record`/`web_research_review_list`/`web_research_review_inspect`, and `web_research_source_record`/`web_research_source_list`/`web_research_source_inspect` for metadata-only web research custody with bounded summaries, policy labels, source refs, citation refs, robots evidence refs, dependency-request refs, trace/replay refs, idempotency fingerprints, exact linked resource selectors, and `networkPolicy: none`, without search, crawl, browser automation, login/cookie reuse, raw HTML/page dumps, browser logs, cookies, credentials, local paths, commands, raw code/file contents, raw grant IDs, raw authority IDs, token-like strings, or debug payloads, `media_create`/`media_list`/`media_inspect`/`media_archive` for current-session or current-workspace `media_artifact` resources that store blob refs and bounded metadata only, with raw audio/base64 rejected and provider-visible raw audio disabled, `import_history_record`/`import_history_list`/`import_history_inspect` for current-session or current-workspace `import_history_record` resources that store bounded generic graph lineage refs only, with render hints fixed to `generic_graph` and raw import payloads or repository trees rejected, `repository_tree_snapshot`/`repository_tree_list`/`repository_tree_inspect` for current-session or current-workspace `repository_tree_snapshot` resources that store content-free repository/root refs, tree object refs, bounded normalized relative path metadata, counts, and evidence refs only, with raw file contents, blob bytes, absolute paths, unbounded tree dumps, visualization, and git mutation rejected, `import_preview_record`/`import_preview_list`/`import_preview_inspect` for current-session or current-workspace `import_preview` resources that link import-history and repository-tree refs with bounded relative path metadata, summaries, counts, and preview fingerprints only, with raw import payloads, preview payloads, file contents, repository contents, import execution, visualization, and git mutation rejected, `program_execution_record`/`program_execution_list`/`program_execution_inspect` for current-session or current-workspace `program_execution_record` resources that store runtime/language identifiers, resource-limit policy, I/O-envelope metadata, source/input/output refs, fingerprints, and lifecycle evidence only, with raw code, stdin/stdout/stderr, command text, runtime execution, process launch, package install, file writes, and live network behavior rejected, `prompt_artifact_record`/`prompt_artifact_list`/`prompt_artifact_inspect` for current-session or current-workspace `prompt_artifact` resources that store explicit opt-in artifact kind, bounded title/summary/preview, content refs/fingerprints, retention state, and lifecycle evidence only, with raw prompt bodies, provider-visible raw prompt payloads, automatic capture, prompt injection, learned behavior, native snippet UI, and prompt-context inclusion rejected, `device_list`/`device_inspect` for redacted server-owned `device_registration` evidence without raw APNs tokens or full token hashes, `notification_send`/`notification_list`/`notification_inspect`/`notification_mark_read`/`notification_mark_all_read` for durable notification inbox, read state, badge count, and delivery-evidence records with live APNs transport disabled, `tool_source_list`/`tool_source_inspect` for inert external tool-source proposal provenance without install/launch/registration/execution, `subagent_launch`/`subagent_status`/`subagent_result`/`subagent_cancel` for scoped delegated module-program-execution work anchored by `subagent_task` resources and the accepted `jobs_program_execution` module pack, using bounded summaries/refs/fingerprints/trace/replay refs only, exact subagent task plus module runtime/job selectors, `networkPolicy: none`, and reviewable merge proposals without raw prompts/results/tool logs/local paths/secrets/provider-visible grant IDs/authority IDs/hidden chain-of-thought/raw job payloads/package-manager output or silent parent-state mutation, `subagent_task_list`/`subagent_task_inspect` for bounded/redacted subagent task evidence, `worker_package_list`/`worker_package_inspect` for bounded/redacted worker package lifecycle evidence without install/enable/launch/stop/registration/execution, `module_list`/`module_inspect` for provider-safe module manifest identity, declaration, validation, provenance, and redaction facts without install, activation, execution, dependency resolution, network access, or raw manifest exposure, `module_proposal_record`/`module_proposal_list`/`module_proposal_inspect` for current-session or current-workspace `module_proposal` resources that store bounded proposal identity and resource-backed source/doc/test refs only, with raw prompt/proposal/code/command/file contents, unsafe paths, dependency restore, package managers, physical workspace directories, repo-managed skills, install, activation, execution, and network access rejected, `module_validation_record`/`module_validation_list`/`module_validation_inspect` for current-session or current-workspace `module_validation_report` resources that store bounded module/proposal refs, manifest/resource/provider parity checks, required docs/tests evidence, deterministic command/result refs, failure evidence, trace/replay refs, idempotency fingerprints, lifecycle, and no-install/no-execution proof only, with runtime command/module execution, raw logs/commands/env/code/file contents, unsafe paths, dependency restore, package managers, repo-managed skills, install, activation, and network access rejected, `module_install_request_record`/`module_install_request_list`/`module_install_request_inspect` and `module_install_decision_record`/`module_install_decision_list`/`module_install_decision_inspect` for current-session or current-workspace `module_install_request` and `module_install_decision` metadata-only review gate resources linked to passed validation reports, approval freshness evidence, dependency policy refs, rollback proof refs, and install-candidate or rejected lifecycle state only, without physical install, activation, execution, dependency restore, package managers, repo-managed skills, raw logs/commands/env/code/file contents, approval evidence minting authority, or network access, `module_dependency_request_record`/`module_dependency_request_list`/`module_dependency_request_inspect`, `module_dependency_decision_record`/`module_dependency_decision_list`/`module_dependency_decision_inspect`, and `module_dependency_policy_activate`/`module_dependency_policy_list`/`module_dependency_policy_inspect` for current-session or current-workspace `module_dependency_request`, `module_dependency_decision`, and `module_dependency_policy` metadata-only resources with owner module linkage, rationale, security/license/runtime need, removal plan, Cargo.toml/Cargo.lock parity evidence, denial evidence, idempotency fingerprints, and `networkPolicy: none`, without package-manager execution, dependency restoration, manifest/lockfile mutation, raw dependency artifacts, raw package-manager output, raw local material, or network access, `module_lifecycle_request`/`module_lifecycle_decision`/`module_lifecycle_list`/`module_lifecycle_inspect` for metadata-only lifecycle state guarded by approval and install-candidate prerequisites without activation, execution, dependency restore, package managers, repo-managed skills, raw local material, or network access, `module_runtime_request`/`module_runtime_list`/`module_runtime_inspect`/`module_runtime_cancel` for enabled-lifecycle-guarded supervised runtime envelopes with sandbox/network/secrets labels, timeout/cancel/shutdown metadata, bounded refs, trace-safe request projection, and provider-safe output refs only, without raw commands/logs/output, PTYs, browser automation, dependency restore, package managers, provider-visible job logs or raw job payloads, physical install, or network access, `procedural_state_list`/`procedural_state_inspect` for bounded/redacted skill/rule/hook/procedure provenance evidence without activation, trigger firing, prompt injection, learned behavior, tool execution, or autonomous execution, trace/log operations to inspect durable \
        execution records, `replay_manifest` to \
        export the current session's `tron.replay.v1` audit manifest, and catalog operations to inspect \
        available workers/functions/schemas/conformance evidence through the same execute primitive. \
        When the user asks you to extend yourself, self-adapt, add a capability, or fill a capability gap, first use `catalog_search`/`catalog_inspect` to find the relevant modular surface, then prefer `module_proposal_record`, `module_validation_record`, `module_install_request_record`, `module_lifecycle_request`, `module_runtime_request`, or procedural definition/activation records as appropriate. Do not describe raw `process_run`, direct SQLite inspection, file reads, or ad hoc notes as self-extension; those are diagnostics unless they produce reviewable module/procedural resources, code changes, tests, docs, and lifecycle evidence. \
        Procedural module-pack operations use `procedural_definition_record`, `procedural_activation_request_record`/`procedural_activation_request_list`/`procedural_activation_request_inspect`, and `procedural_activation_decision_record`/`procedural_activation_decision_list`/`procedural_activation_decision_inspect` for bounded/redacted definition, review, activation/deactivation/rollback decision, trigger declaration, conflict/ordering, scoped-authority proof, trace/replay, bounded-ref, provider-projection, and idempotency evidence only, never for activation, trigger firing, prompt injection, learned behavior, tool execution, package-manager behavior, network access, repo-managed skills, or autonomous execution. \
        Memory operations use `memory_status`/`memory_list`/`memory_inspect` for redacted current-session memory policy and record previews, and `memory_query_list`/`memory_query_inspect` plus `memory_decision_list`/`memory_decision_inspect` for deterministic retrieval and prompt-inclusion evidence; they expose bounded refs, ranking/confidence/provenance, policy proof, and bounded preview snippets only when policy allowed, never raw body refs, raw provider payloads, generated summaries, secrets, unsafe paths, grant ids, authority ids, embeddings, network access, or automatic retention. \
        Context-control operations use `context_control_snapshot`, `context_control_compact`, `context_control_clear`, `context_control_action_list`, and `context_control_action_inspect` for current-session context snapshots, compact/clear action records, and epoch audit details; compact/clear require `reason`, `idempotencyKey`, exact session-scoped authority, and `networkPolicy: none`, and projections expose token estimates, prompt block labels, redacted refs, timeline/audit refs, and redaction/truncation proof only, never raw prompt bodies, hidden system/soul prompt text, secrets, local paths, commands, logs, grant ids, authority ids, raw file contents, or hidden chain-of-thought. \
        Module program-execution operations use `module_program_execution_start`/`module_program_execution_status`/`module_program_execution_cancel`/`module_program_execution_cleanup` for enabled-lifecycle supervised non-interactive jobs linked to metadata-only program execution records and module runtime envelopes; results expose refs, fingerprints, truncation, duration, exit, timeout, cancellation, and cleanup metadata only, never raw commands, code, stdin/stdout/stderr, logs, paths, env, pids, grant ids, raw job payloads, raw output payloads, PTYs, package installs, or network access. \
        Mutating filesystem package operations require a stable `idempotencyKey`; include `reason`, use \
        preview mode before commit when possible, and provide `expectedHash` when committing changes to \
        an existing file. `job_start`, `job_cancel`, `goal_create`, `goal_cancel`, `question_create`, `question_answer`, `web_robots_check`, `web_source_archive`, `web_research_request_record`, `web_research_review_record`, `web_research_source_record`, `media_create`, `media_archive`, `import_history_record`, `repository_tree_snapshot`, `import_preview_record`, `program_execution_record`, `prompt_artifact_record`, `context_control_snapshot`, `context_control_compact`, `context_control_clear`, `module_proposal_record`, `module_validation_record`, `module_install_request_record`, `module_install_decision_record`, `module_dependency_request_record`, `module_dependency_decision_record`, `module_dependency_policy_activate`, `module_lifecycle_request`, `module_lifecycle_decision`, `module_runtime_request`, `module_runtime_cancel`, `device_register`, `device_unregister`, `notification_send`, `notification_mark_read`, `notification_mark_all_read`, `subagent_launch`, and `subagent_cancel` require a stable `idempotencyKey`; `question_answer` also requires `expectedQuestionVersionId` and `reason`; `context_control_action_inspect` requires `contextControlActionResourceId`; `web_fetch` with robots evidence requires both `webRobotsPolicyResourceId` and `expectedWebRobotsPolicyVersionId`; `web_source_archive` also requires `expectedWebSourceVersionId` and `reason`; web_research_request_record requires title and questionSummary; web_research_review_record requires webResearchRequestResourceId and reviewSummary; web_research_source_record requires request or review linkage plus artifactKind, title, and summary; all web research record operations require stable idempotencyKey, bounded summaries and refs only, exact selectors for linked writes, and networkPolicy none; `media_archive` also requires `expectedMediaVersionId` and `reason`; `import_history_record` also requires `subjectKind`, `subjectId`, and bounded lineage refs only; `repository_tree_snapshot` also requires `repositoryRef`, `rootRef`, `treeObjectRef`, and content-free path metadata only; `import_preview_record` also requires `importHistoryRef`, `repositoryTreeRef`, `previewFingerprint`, and content-free path metadata only; `program_execution_record` also requires `runtimeId`, `languageId`, `programFingerprint`, and metadata-only I/O envelope fields; `prompt_artifact_record` also requires `artifactKind`, `title`, and `contentFingerprint`, and accepts content refs/fingerprints only instead of raw prompt bodies; `module_proposal_record` also requires `title`, `summary`, and bounded source/doc/test refs only instead of raw proposal bodies or code; `module_validation_record` also requires `title`, `summary`, `moduleRefs`, `docEvidence`, and `testEvidence`, and accepts command/result refs only instead of raw commands/logs; `module_install_request_record` also requires `title`, `summary`, `moduleValidationReportResourceId`, dependency policy metadata refs/status, and rollback proof metadata refs/readiness; `module_install_decision_record` also requires `moduleInstallRequestResourceId`, approval request/decision refs, `decision`, and `reason`, and rejected decisions require denial evidence refs; `module_dependency_request_record` also requires `moduleRef`, `dependencyName`, `dependencyEcosystem`, owner rationale, security/license/runtime need, removal plan, `riskClass`, `cargoTomlEvidence`, and `cargoLockEvidence`; `module_dependency_decision_record` requires `moduleDependencyRequestResourceId`, `decision`, and `reason`, and rejected decisions require denial evidence refs; `module_dependency_policy_activate` requires `moduleDependencyDecisionResourceId` and `reason`; `module_lifecycle_request` requires `moduleInstallDecisionResourceId`, `lifecycleAction`, `reason`, and rollback proof refs for rollback; `module_lifecycle_decision` requires `moduleLifecycleResourceId`, `expectedModuleLifecycleVersionId`, approval refs, `decision`, and `reason`; `module_runtime_request` requires `moduleLifecycleResourceId`, `runtimeRequestId`, `runtimeKind`, `runtimeLabel`, `reason`, bounded refs, and optional `timeoutMs`; `module_runtime_cancel` requires `moduleRuntimeResourceId`, `expectedModuleRuntimeVersionId`, and `reason`. `device_register` requires trusted internal authority, explicit `apnsEnvironment`, and hash-only APNs token custody; `notification_send` with `pushRequested` records redacted delivery evidence only and does not send APNs. `subagent_launch` requires `objectiveSummary`, `promptSummary`, `modelPolicy: accepted_jobs_program_execution_v1`, `workerKind: module_program_execution`, `modulePackId: jobs_program_execution`, bounded summary-only `handoffRefs`, and `networkPolicy: none`; `subagent_status`, `subagent_result`, and `subagent_cancel` require exact `subagentTaskResourceId` authority using both `resource:<subagent_task_id>` and `kind:subagent_task` selectors, and validate the delegated `moduleRuntimeResourceId`/`jobResourceId` binding; `subagent_result` returns `parentConversationMutated: false` merge proposal refs only; other mutating \
        `module_program_execution_start`, `module_program_execution_cancel`, and `module_program_execution_cleanup` require a stable `idempotencyKey`; start requires `moduleLifecycleResourceId`, `runtimeRequestId`, `command`, `runtimeId`, `languageId`, `programFingerprint`, `reason`, and `networkPolicy: none`; status requires `moduleRuntimeResourceId` and `jobResourceId`; cancel requires `moduleRuntimeResourceId`, `expectedModuleRuntimeVersionId`, `jobResourceId`, and `reason`; cleanup also requires `expectedJobVersionId`. \
        Procedural definition, activation request, and activation decision record operations require a stable `idempotencyKey`, explicit `networkPolicy: none`, bounded proof refs, and exact resource linkage; definition records require `definitionId`, `proceduralKind`, `title`, `summary`, validation evidence refs, trigger declarations, and scoped-authority proof; activation request records require `proceduralRecordResourceId`, `requestedAction`, and `reason`; activation decision records require `proceduralActivationRequestResourceId`, `decision`, `reason`, and approval or denial proof refs. \
        operations should include a short `reason`; repeated writes, Git index mutations, Git commits, branch starts, or commands should include a stable \
        `idempotencyKey` when retry safety matters. Except for read-only `replay_manifest`, the engine records a trace \
        record for each execute operation with status, timing, provider/model context, authority metadata, \
        touched resources, hashes where available, errors, and implementation metadata.\n\
        \n\
        ## Important Rules\n\
        1. Use one operation per `execute` call\n\
        2. Inspect files before changing them unless the user explicitly provides full replacement content\n\
        3. Use relative paths under the current working directory\n\
        4. Prefer small, tested changes and record useful evidence through `observe` or trace inspection\n\
        5. When authority is unavailable, report the blocked state inside the current authority envelope\n\
        6. Be helpful, accurate, and efficient when working with code",
        tool_list = tool_descriptions.join("\n"),
        operation_list = operation_list_text()
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Collect all capability invocation IDs from assistant messages.
fn collect_invocation_ids(messages: &[Message]) -> Vec<String> {
    let mut ids = Vec::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for block in content {
                if let AssistantContent::CapabilityInvocation { id, .. } = block {
                    ids.push(id.clone());
                }
            }
        }
    }
    ids
}

/// Convert a user message to Responses API input items.
fn convert_user_message(content: &UserMessageContent, input: &mut Vec<ResponsesInputItem>) {
    match content {
        UserMessageContent::Text(text) => {
            input.push(ResponsesInputItem::Message {
                role: "user".into(),
                content: vec![MessageContent::InputText { text: text.clone() }],
                id: None,
            });
        }
        UserMessageContent::Blocks(blocks) => {
            let content_parts: Vec<MessageContent> = blocks
                .iter()
                .map(|block| match block {
                    UserContent::Text { text } => MessageContent::InputText { text: text.clone() },
                    UserContent::Image { data, mime_type } => MessageContent::InputImage {
                        image_url: format!("data:{mime_type};base64,{data}"),
                        detail: Some("auto".into()),
                    },
                    UserContent::Document {
                        mime_type,
                        file_name,
                        extracted_text,
                        ..
                    } => {
                        let name = file_name.as_deref().unwrap_or("unnamed");
                        match extracted_text {
                            Some(text) => MessageContent::InputText {
                                text: format!("--- Document: {name} ---\n{text}"),
                            },
                            None => MessageContent::InputText {
                                text: format!("[Document: {name} ({mime_type}) \u{2014} content not available for this model]"),
                            },
                        }
                    }
                })
                .collect();

            if !content_parts.is_empty() {
                input.push(ResponsesInputItem::Message {
                    role: "user".into(),
                    content: content_parts,
                    id: None,
                });
            }
        }
    }
}

/// Convert an assistant message to Responses API input items.
fn convert_assistant_message(
    content: &[AssistantContent],
    id_mapping: &std::collections::HashMap<String, String>,
    input: &mut Vec<ResponsesInputItem>,
) {
    // Collect text parts
    let text_parts: Vec<MessageContent> = content
        .iter()
        .filter_map(|block| {
            if let AssistantContent::Text { text } = block {
                Some(MessageContent::OutputText { text: text.clone() })
            } else {
                None
            }
        })
        .collect();

    if !text_parts.is_empty() {
        input.push(ResponsesInputItem::Message {
            role: "assistant".into(),
            content: text_parts,
            id: None,
        });
    }

    // Convert capability invocations to function_call items
    for block in content {
        if let AssistantContent::CapabilityInvocation {
            id,
            name,
            arguments,
            ..
        } = block
        {
            let remapped_id = remap_invocation_id(id, id_mapping).to_string();
            input.push(ResponsesInputItem::FunctionCall {
                id: None,
                call_id: remapped_id,
                name: name.clone(),
                arguments: serde_json::to_string(arguments).unwrap_or_else(|_| "{}".into()),
            });
        }
    }
}

/// Convert a capability result to a Responses API `function_call_output` item.
fn convert_capability_result(
    invocation_id: &str,
    content: &CapabilityResultMessageContent,
    id_mapping: &std::collections::HashMap<String, String>,
    input: &mut Vec<ResponsesInputItem>,
) {
    let output_text = match content {
        CapabilityResultMessageContent::Text(text) => text.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| {
                if let CapabilityResultContent::Text { text } = block {
                    Some(text.as_str())
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
    };

    // Truncate long outputs (Codex has 16k limit per output)
    let truncated = if output_text.len() > TOOL_RESULT_MAX_LENGTH {
        let mut t = output_text[..TOOL_RESULT_MAX_LENGTH].to_string();
        t.push_str("\n... [truncated]");
        t
    } else {
        output_text
    };

    let remapped_id = remap_invocation_id(invocation_id, id_mapping).to_string();
    input.push(ResponsesInputItem::FunctionCallOutput {
        call_id: remapped_id,
        output: truncated,
    });
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
#[allow(unused_results)]
mod tests;
