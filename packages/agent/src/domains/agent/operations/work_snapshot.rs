//! Server-owned Work dashboard projection.
//!
//! This operation turns engine-owned settings, worker catalog, invocation,
//! approval, guardrail, and audit substrate into the worker-first product DTO
//! consumed by thin clients.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use crate::domains::agent::Deps;
use crate::domains::capability_support::implementations::traits::{JobInfo, JobState};
use crate::domains::settings::{AutonomyApprovalPromptMode, get_settings};
use crate::engine::{
    ActorContext, ApprovalStatus, EffectClass, EngineApprovalRecord, EngineError,
    FunctionDefinition, FunctionHealth, FunctionQuery, Invocation, InvocationRecord, RiskLevel,
    WorkerDefinition, WorkerKind,
};
use crate::shared::server::errors::CapabilityError;

const DEFAULT_LIMIT: usize = 12;
const MAX_LIMIT: usize = 50;

pub(crate) async fn work_snapshot_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = optional_string(params, "sessionId")
        .or_else(|| invocation.causal_context.session_id.clone());
    let workspace_id = optional_string(params, "workspaceId")
        .or_else(|| invocation.causal_context.workspace_id.clone());
    let subagent_jobs = scoped_subagent_jobs(deps, session_id.as_deref());
    let limit = optional_usize(params, "limit")
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, MAX_LIMIT);
    build_work_snapshot(
        &deps.engine_host,
        actor_context(invocation),
        session_id,
        workspace_id,
        limit,
        subagent_jobs,
    )
    .await
    .map_err(engine_error)
}

async fn build_work_snapshot(
    handle: &crate::engine::EngineHostHandle,
    actor: ActorContext,
    session_id: Option<String>,
    workspace_id: Option<String>,
    limit: usize,
    subagent_jobs: Vec<JobInfo>,
) -> crate::engine::Result<Value> {
    let settings = get_settings();
    let approval_prompt_mode = settings.agent.autonomy.approval_prompt_mode;
    let functions = handle
        .discover(&FunctionQuery {
            actor: Some(actor),
            ..FunctionQuery::default()
        })
        .await;
    let mut workers = worker_projection(handle, &functions).await;
    workers.extend(subagent_jobs.iter().map(subagent_worker_value));
    let invocations = scoped_invocations(
        handle.invocation_records().await,
        session_id.as_deref(),
        workspace_id.as_deref(),
        limit,
    );
    let mut approvals = handle
        .list_approvals(None, session_id.as_deref(), limit)
        .await?;
    approvals.retain(|record| {
        workspace_id
            .as_deref()
            .is_none_or(|workspace| record.workspace_id.as_deref() == Some(workspace))
    });
    let guardrails = guardrail_projection(&approvals);
    let active_work = active_work_projection(&approvals);
    let recent_milestones = milestone_projection(&invocations);
    let audit_refs = audit_ref_projection(
        handle.catalog_revision().await.0,
        &invocations,
        &approvals,
        limit,
    );

    Ok(json!({
        "autonomy": autonomy_projection(approval_prompt_mode),
        "activeWork": active_work,
        "workers": workers,
        "recentMilestones": recent_milestones,
        "guardrails": guardrails,
        "auditRefs": audit_refs,
        "scope": {
            "sessionId": session_id,
            "workspaceId": workspace_id,
        }
    }))
}

fn scoped_subagent_jobs(deps: &Deps, session_id: Option<&str>) -> Vec<JobInfo> {
    let Some(session_id) = session_id else {
        return Vec::new();
    };
    deps.subagent_manager
        .as_ref()
        .map(|manager| manager.list_active_jobs(session_id))
        .unwrap_or_default()
}

fn autonomy_projection(mode: AutonomyApprovalPromptMode) -> Value {
    match mode {
        AutonomyApprovalPromptMode::Disabled => json!({
            "mode": "independent",
            "approvalPromptMode": "disabled",
            "interactiveApprovalPrompts": false,
            "statusLabel": "Runs independently",
            "summary": "Approval-required autonomous work is audited and auto-decided unless a guardrail blocks it."
        }),
        AutonomyApprovalPromptMode::Testing => json!({
            "mode": "testing",
            "approvalPromptMode": "testing",
            "interactiveApprovalPrompts": true,
            "statusLabel": "Testing prompts enabled",
            "summary": "Approval-required autonomous work creates interactive QA prompts."
        }),
    }
}

async fn worker_projection(
    handle: &crate::engine::EngineHostHandle,
    functions: &[FunctionDefinition],
) -> Vec<Value> {
    let mut by_worker: BTreeMap<String, Vec<&FunctionDefinition>> = BTreeMap::new();
    for function in functions {
        by_worker
            .entry(function.owner_worker.as_str().to_owned())
            .or_default()
            .push(function);
    }

    let mut workers = Vec::new();
    for (worker_id, abilities) in by_worker {
        let worker = if let Ok(id) = crate::engine::WorkerId::new(&worker_id) {
            handle.inspect_worker(&id).await.ok()
        } else {
            None
        };
        let Some(worker) = worker else {
            continue;
        };
        if !dashboard_worker_visible(&worker) {
            continue;
        }
        workers.push(worker_value(&worker, &worker_id, &abilities));
    }
    workers
}

fn dashboard_worker_visible(worker: &WorkerDefinition) -> bool {
    matches!(
        worker.kind,
        WorkerKind::External | WorkerKind::Sandbox | WorkerKind::Mcp
    )
}

fn worker_value(
    worker: &WorkerDefinition,
    worker_id: &str,
    abilities: &[&FunctionDefinition],
) -> Value {
    let health = aggregate_health(abilities);
    let namespaces = worker.namespace_claims.clone();
    json!({
        "workerId": worker_id,
        "label": worker_label(worker, worker_id),
        "status": format!("{:?}", worker.lifecycle),
        "health": health,
        "trust": worker_trust(worker),
        "abilityCount": abilities.len(),
        "abilities": abilities.iter().take(6).map(|function| {
            json!({
                "functionId": function.id.as_str(),
                "label": ability_label(function),
                "risk": format!("{:?}", function.risk_level),
                "effect": format!("{:?}", function.effect_class),
                "health": format!("{:?}", function.health),
            })
        }).collect::<Vec<_>>(),
        "generatedControls": generated_controls(abilities),
        "namespaceClaims": namespaces,
    })
}

fn subagent_worker_value(job: &JobInfo) -> Value {
    json!({
        "workerId": format!("subagent:{}", job.id),
        "label": if job.label.trim().is_empty() {
            "Agent worker".to_owned()
        } else {
            job.label.clone()
        },
        "status": format!("{:?}", job.state),
        "health": subagent_job_health(&job.state),
        "trust": "Session worker",
        "abilityCount": 1,
        "abilities": [{
            "functionId": "agent::spawn_subagent",
            "label": "Delegated agent work",
            "risk": "Medium",
            "effect": "ExternalSideEffect",
            "health": subagent_ability_health(&job.state),
        }],
        "generatedControls": [{
            "controlId": format!("work-control:subagent:{}", job.id),
            "label": "View worker result",
            "kind": "Detail",
            "functionId": "agent::subagent_result",
            "status": subagent_ability_health(&job.state),
            "auditRef": audit_ref("subagent", &job.id, None),
        }],
        "namespaceClaims": ["agent"],
        "workerType": "agent",
        "runId": job.id,
        "elapsedMs": job.elapsed_ms,
        "auditRef": audit_ref("subagent", &job.id, None),
    })
}

fn subagent_job_health(state: &JobState) -> &'static str {
    match state {
        JobState::Running | JobState::Completed => "healthy",
        JobState::Failed => "unhealthy",
        JobState::Cancelled => "degraded",
    }
}

fn subagent_ability_health(state: &JobState) -> &'static str {
    match state {
        JobState::Running | JobState::Completed => "Healthy",
        JobState::Failed => "Unhealthy",
        JobState::Cancelled => "Degraded",
    }
}

fn aggregate_health(abilities: &[&FunctionDefinition]) -> &'static str {
    if abilities
        .iter()
        .any(|function| function.health == FunctionHealth::Unhealthy)
    {
        "unhealthy"
    } else if abilities
        .iter()
        .any(|function| function.health == FunctionHealth::Degraded)
    {
        "degraded"
    } else if abilities
        .iter()
        .any(|function| function.health == FunctionHealth::Unknown)
    {
        "unknown"
    } else {
        "healthy"
    }
}

fn worker_trust(worker: &WorkerDefinition) -> &'static str {
    match &worker.kind {
        WorkerKind::External | WorkerKind::Mcp => "Workspace trusted",
        WorkerKind::Sandbox => "Sandboxed",
        WorkerKind::Agent => "Session worker",
        WorkerKind::InProcess
        | WorkerKind::Client
        | WorkerKind::System
        | WorkerKind::Queue
        | WorkerKind::Stream
        | WorkerKind::Cron
        | WorkerKind::State => "System worker",
    }
}

fn generated_controls(abilities: &[&FunctionDefinition]) -> Vec<Value> {
    abilities
        .iter()
        .take(6)
        .map(|function| {
            json!({
                "controlId": format!("work-control:{}", function.id.as_str()),
                "label": ability_label(function),
                "kind": control_kind(function),
                "functionId": function.id.as_str(),
                "status": format!("{:?}", function.health),
            })
        })
        .collect()
}

fn control_kind(function: &FunctionDefinition) -> &'static str {
    if function.required_authority.approval_required || function.risk_level >= RiskLevel::High {
        return "Guarded Run";
    }

    match function.effect_class {
        EffectClass::PureRead | EffectClass::DeterministicCompute => "Read",
        EffectClass::DelegatedInvocation => "Delegate",
        EffectClass::AppendOnlyEvent => "Record",
        EffectClass::IdempotentWrite => "Update",
        EffectClass::ReversibleSideEffect | EffectClass::ExternalSideEffect => "Run",
        EffectClass::IrreversibleSideEffect => "Guarded Run",
    }
}

fn worker_label(worker: &WorkerDefinition, worker_id: &str) -> String {
    worker
        .namespace_claims
        .first()
        .cloned()
        .unwrap_or_else(|| worker_id.to_owned())
}

fn ability_label(function: &FunctionDefinition) -> String {
    function
        .metadata
        .pointer("/presentationHints/chipTitle")
        .and_then(Value::as_str)
        .or_else(|| {
            function
                .metadata
                .pointer("/presentation/displayName")
                .and_then(Value::as_str)
        })
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| function.description.clone())
}

fn scoped_invocations(
    mut records: Vec<InvocationRecord>,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    limit: usize,
) -> Vec<InvocationRecord> {
    records.retain(|record| {
        session_id.is_none_or(|session| record.session_id.as_deref() == Some(session))
            && workspace_id
                .is_none_or(|workspace| record.workspace_id.as_deref() == Some(workspace))
    });
    records.sort_by_key(|record| record.timestamp);
    records.into_iter().rev().take(limit).collect()
}

fn milestone_projection(records: &[InvocationRecord]) -> Vec<Value> {
    records
        .iter()
        .map(|record| {
            json!({
                "kind": "invocation",
                "status": if record.succeeded { "completed" } else { "failed" },
                "functionId": record.function_id.as_str(),
                "workerId": record.worker_id.as_str(),
                "invocationId": record.invocation_id.as_str(),
                "traceId": record.trace_id.as_str(),
                "auditRef": audit_ref("invocation", record.invocation_id.as_str(), Some(record.trace_id.as_str())),
            })
        })
        .collect()
}

fn guardrail_projection(approvals: &[EngineApprovalRecord]) -> Vec<Value> {
    approvals
        .iter()
        .filter(|approval| approval.status == ApprovalStatus::Pending)
        .map(|approval| {
            json!({
                "kind": "approval_prompt",
                "status": "blocked",
                "functionId": approval.function_id.as_str(),
                "approvalId": approval.approval_id,
                "traceId": approval.trace_id.as_str(),
                "risk": approval.target_metadata.as_ref().map(|metadata| format!("{:?}", metadata.risk_level)),
                "summary": "Testing-mode approval prompt is waiting for a decision.",
                "auditRef": audit_ref("approval", &approval.approval_id, Some(approval.trace_id.as_str())),
            })
        })
        .collect()
}

fn active_work_projection(approvals: &[EngineApprovalRecord]) -> Vec<Value> {
    approvals
        .iter()
        .filter(|approval| approval.status == ApprovalStatus::Pending)
        .map(|approval| {
            json!({
                "kind": "approval_wait",
                "status": "waiting",
                "functionId": approval.function_id.as_str(),
                "approvalId": approval.approval_id,
                "traceId": approval.trace_id.as_str(),
            })
        })
        .collect()
}

fn audit_ref_projection(
    catalog_revision: u64,
    invocations: &[InvocationRecord],
    approvals: &[EngineApprovalRecord],
    limit: usize,
) -> Vec<Value> {
    let mut refs = vec![json!({
        "kind": "catalog",
        "catalogRevision": catalog_revision,
    })];
    let mut seen = BTreeSet::new();
    for approval in approvals.iter().take(limit) {
        if seen.insert(format!("approval:{}", approval.approval_id)) {
            refs.push(audit_ref(
                "approval",
                &approval.approval_id,
                Some(approval.trace_id.as_str()),
            ));
        }
    }
    for invocation in invocations.iter().take(limit) {
        if seen.insert(format!("invocation:{}", invocation.invocation_id.as_str())) {
            refs.push(audit_ref(
                "invocation",
                invocation.invocation_id.as_str(),
                Some(invocation.trace_id.as_str()),
            ));
        }
    }
    refs
}

fn audit_ref(kind: &str, id: &str, trace_id: Option<&str>) -> Value {
    json!({
        "kind": kind,
        "id": id,
        "traceId": trace_id,
    })
}

fn actor_context(invocation: &Invocation) -> ActorContext {
    let mut actor = ActorContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        invocation.causal_context.authority_grant_id.clone(),
    );
    actor.authority_scopes = invocation.causal_context.authority_scopes.clone();
    actor.session_id = invocation.causal_context.session_id.clone();
    actor.workspace_id = invocation.causal_context.workspace_id.clone();
    actor
}

fn optional_string(params: Option<&Value>, key: &str) -> Option<String> {
    params?
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn optional_usize(params: Option<&Value>, key: &str) -> Option<usize> {
    params?
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
}

fn engine_error(error: EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use serde_json::json;

    use super::*;
    use crate::domains::capability_support::implementations::traits::{JobInfo, JobKind};
    use crate::engine::{
        ActorId, AuthorityGrantId, CausalContext, CompensationContract, CompensationKind,
        DeliveryMode, EffectClass, FunctionId, IdempotencyContract, InProcessFunctionHandler,
        RiskLevel, TraceId, VisibilityScope, WorkerId, WorkerKind,
    };

    #[tokio::test]
    async fn work_snapshot_projects_idle_autonomy_workers_milestones_guardrails_and_audit_refs() {
        let _settings = settings_mode(AutonomyApprovalPromptMode::Testing);
        let handle = crate::engine::EngineHostHandle::new_in_memory().unwrap();
        handle
            .register_worker_for_setup(test_worker("worker-demo", "demo"), false)
            .unwrap();
        handle
            .register_function_for_setup(
                FunctionDefinition::new(
                    FunctionId::new("demo::echo").unwrap(),
                    WorkerId::new("worker-demo").unwrap(),
                    "Echo work input",
                    VisibilityScope::Agent,
                    EffectClass::PureRead,
                ),
                Some(std::sync::Arc::new(EchoHandler)),
                false,
            )
            .unwrap();
        handle
            .register_function_for_setup(
                FunctionDefinition::new(
                    FunctionId::new("demo::write").unwrap(),
                    WorkerId::new("worker-demo").unwrap(),
                    "Write demo state",
                    VisibilityScope::Agent,
                    EffectClass::IrreversibleSideEffect,
                )
                .with_required_authority(
                    crate::engine::AuthorityRequirement::scope("demo.write")
                        .with_approval_required(),
                )
                .with_risk(RiskLevel::High)
                .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test work snapshot write is manually compensated",
                )),
                Some(std::sync::Arc::new(EchoHandler)),
                false,
            )
            .unwrap();
        let echo = handle
            .invoke(Invocation::new_sync(
                FunctionId::new("demo::echo").unwrap(),
                json!({"value": 7}),
                test_context("trace-work-echo", "echo-key").with_scope("demo.read"),
            ))
            .await;
        assert_eq!(echo.error, None);
        let pending = handle
            .request_approval(crate::engine::EngineApprovalRequest {
                function_id: FunctionId::new("demo::write").unwrap(),
                payload: json!({"value": 1}),
                causal_context: test_context("trace-work-approval", "approval-key")
                    .with_scope("demo.write"),
                delivery_mode: DeliveryMode::Sync,
                target_metadata: None,
            })
            .await
            .unwrap();

        let snapshot = build_work_snapshot(
            &handle,
            actor_for_snapshot(),
            Some("session-work".to_owned()),
            Some("workspace-work".to_owned()),
            10,
            Vec::new(),
        )
        .await
        .unwrap();

        assert_eq!(snapshot["autonomy"]["approvalPromptMode"], "testing");
        assert_eq!(snapshot["autonomy"]["interactiveApprovalPrompts"], true);
        assert_eq!(snapshot["workers"][0]["workerId"], "worker-demo");
        assert_eq!(snapshot["workers"][0]["trust"], "Workspace trusted");
        assert_eq!(snapshot["workers"][0]["abilityCount"], 2);
        assert_eq!(snapshot["workers"][0]["health"], "healthy");
        assert_eq!(
            snapshot["workers"][0]["generatedControls"][0]["functionId"],
            "demo::echo"
        );
        assert_eq!(
            snapshot["workers"][0]["generatedControls"][1]["kind"],
            "Guarded Run"
        );
        assert_eq!(snapshot["activeWork"][0]["approvalId"], pending.approval_id);
        assert_eq!(snapshot["activeWork"][0]["status"], "waiting");
        assert_eq!(snapshot["recentMilestones"][0]["functionId"], "demo::echo");
        assert_eq!(snapshot["guardrails"][0]["approvalId"], pending.approval_id);
        assert_eq!(snapshot["guardrails"][0]["status"], "blocked");
        assert!(
            snapshot["auditRefs"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| { item["kind"] == "approval" && item["id"] == pending.approval_id })
        );
    }

    #[tokio::test]
    async fn work_snapshot_projects_subagents_as_workers() {
        let _settings = settings_mode(AutonomyApprovalPromptMode::Disabled);
        let handle = crate::engine::EngineHostHandle::new_in_memory().unwrap();
        let snapshot = build_work_snapshot(
            &handle,
            actor_for_snapshot(),
            Some("session-work".to_owned()),
            Some("workspace-work".to_owned()),
            10,
            vec![JobInfo {
                id: "subagent-session-1".to_owned(),
                kind: JobKind::Agent,
                label: "Review worker guide".to_owned(),
                state: JobState::Running,
                elapsed_ms: 1200,
                session_id: "session-work".to_owned(),
            }],
        )
        .await
        .unwrap();

        assert_eq!(
            snapshot["workers"][0]["workerId"],
            "subagent:subagent-session-1"
        );
        assert_eq!(snapshot["workers"][0]["label"], "Review worker guide");
        assert_eq!(snapshot["workers"][0]["workerType"], "agent");
        assert_eq!(snapshot["workers"][0]["trust"], "Session worker");
        assert_eq!(snapshot["workers"][0]["status"], "Running");
        assert_eq!(snapshot["workers"][0]["health"], "healthy");
        assert_eq!(snapshot["workers"][0]["abilityCount"], 1);
        assert_eq!(
            snapshot["workers"][0]["abilities"][0]["functionId"],
            "agent::spawn_subagent"
        );
        assert_eq!(
            snapshot["workers"][0]["abilities"][0]["label"],
            "Delegated agent work"
        );
        assert_eq!(
            snapshot["workers"][0]["generatedControls"][0]["label"],
            "View worker result"
        );
        assert_eq!(snapshot["workers"][0]["auditRef"]["kind"], "subagent");
    }

    #[tokio::test]
    async fn work_snapshot_idle_state_uses_disabled_autonomy_defaults() {
        let _settings = settings_mode(AutonomyApprovalPromptMode::Disabled);
        let handle = crate::engine::EngineHostHandle::new_in_memory().unwrap();
        let snapshot =
            build_work_snapshot(&handle, actor_for_snapshot(), None, None, 10, Vec::new())
                .await
                .unwrap();

        assert_eq!(snapshot["autonomy"]["approvalPromptMode"], "disabled");
        assert_eq!(snapshot["autonomy"]["mode"], "independent");
        assert_eq!(snapshot["activeWork"].as_array().unwrap().len(), 0);
        assert_eq!(snapshot["workers"].as_array().unwrap().len(), 0);
        assert_eq!(snapshot["recentMilestones"].as_array().unwrap().len(), 0);
        assert_eq!(snapshot["guardrails"].as_array().unwrap().len(), 0);
        assert_eq!(snapshot["auditRefs"][0]["kind"], "catalog");
    }

    struct SettingsModeGuard {
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl Drop for SettingsModeGuard {
        fn drop(&mut self) {
            crate::domains::settings::reset_settings();
        }
    }

    fn settings_mode(mode: AutonomyApprovalPromptMode) -> SettingsModeGuard {
        let guard = crate::domains::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut settings = crate::domains::settings::TronSettings::default();
        settings.agent.autonomy.approval_prompt_mode = mode;
        crate::domains::settings::init_settings(settings);
        SettingsModeGuard { _guard: guard }
    }

    fn test_worker(id: &str, namespace: &str) -> WorkerDefinition {
        WorkerDefinition::new(
            WorkerId::new(id).unwrap(),
            WorkerKind::External,
            ActorId::new("owner").unwrap(),
            AuthorityGrantId::new("grant").unwrap(),
        )
        .with_namespace_claim(namespace)
    }

    fn actor_for_snapshot() -> ActorContext {
        let mut actor = ActorContext::new(
            ActorId::new("agent-work").unwrap(),
            crate::engine::ActorKind::Agent,
            AuthorityGrantId::new("grant").unwrap(),
        );
        actor.authority_scopes = vec!["demo.read".to_owned(), "demo.write".to_owned()];
        actor.session_id = Some("session-work".to_owned());
        actor.workspace_id = Some("workspace-work".to_owned());
        actor
    }

    fn test_context(trace_id: &str, key: &str) -> CausalContext {
        CausalContext::new(
            ActorId::new("agent-work").unwrap(),
            crate::engine::ActorKind::Agent,
            AuthorityGrantId::new("grant").unwrap(),
            TraceId::new(trace_id).unwrap(),
        )
        .with_session_id("session-work")
        .with_workspace_id("workspace-work")
        .with_idempotency_key(key)
    }

    #[derive(Clone)]
    struct EchoHandler;

    #[async_trait]
    impl InProcessFunctionHandler for EchoHandler {
        async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
            Ok(json!({"echo": invocation.payload}))
        }
    }
}
