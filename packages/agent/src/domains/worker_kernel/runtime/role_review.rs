//! Engine-owned reusable-agent role review workflow.
//!
//! A dynamically selected healthy hook may propose only an explicit
//! `agentRole` plus rationale. Durable proposal custody, immutable-version
//! validation, user confirmation, and canonical publication stay here.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;

use super::*;
use crate::domains::worker_kernel::persistence::{
    AGENT_ROLE_REVIEW_SCHEMA_VERSION, AgentRoleReviewProposalRecord, AgentRoleReviewStatus,
    NewAgentRoleReviewProposal,
};
use crate::engine::{ActorContext, ActorId, ActorKind};

pub(crate) const AGENT_ROLE_REVIEW_CAPABILITY: &str = "agent_role_review.v1";
const MAX_ROLE_REVIEW_QUEUE: usize = 100;
const MAX_DELEGABLE_TOOLS: usize = 256;
const REVIEW_REPAIR_REQUIREMENT: &str = "No healthy active worker declares the agent_role_review reviewer capability. Activate a compatible reviewer worker, then retry; legacy agent runners remain directly callable in the meantime.";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReviewerProposalOutput {
    agent_role: WorkerAgentRole,
    rationale: String,
}

impl WorkerRuntime {
    pub(crate) async fn client_agent_role_reviews(
        &self,
        limit: usize,
        offset: u64,
        queue_limit: usize,
        queue_offset: u64,
    ) -> Result<Value, String> {
        let reviewer = self.agent_role_reviewer()?;
        let reviewer_projection = reviewer.as_ref().map_or_else(
            || {
                json!({
                    "available":false,
                    "repairRequirement":REVIEW_REPAIR_REQUIREMENT,
                })
            },
            |worker| {
                json!({
                    "available":true,
                    "workerId":worker.summary.worker_id,
                    "workerVersion":worker.summary.active_version,
                })
            },
        );
        let candidates = self.agent_role_review_candidates()?;
        let queue_total = candidates.len();
        let queue_offset = usize::try_from(queue_offset).unwrap_or(usize::MAX);
        let page_candidates = candidates
            .into_iter()
            .skip(queue_offset)
            .take(queue_limit.clamp(1, MAX_ROLE_REVIEW_QUEUE))
            .collect::<Vec<_>>();
        let queue_returned = page_candidates.len();
        let queue_consumed = queue_offset.saturating_add(queue_returned);
        let queue_next_offset = (queue_consumed < queue_total).then_some(queue_consumed);
        let mut items = Vec::with_capacity(page_candidates.len());
        for worker in page_candidates {
            let latest = self
                .store
                .latest_agent_role_review_proposal(&worker.summary.worker_id)?;
            let has_open_proposal = latest.as_ref().is_some_and(|proposal| {
                proposal.target_worker_version == worker.summary.active_version
                    && matches!(
                        proposal.status,
                        AgentRoleReviewStatus::Proposed | AgentRoleReviewStatus::Applying
                    )
            });
            let start_reason = if has_open_proposal {
                Some("An active proposal already exists for this worker version.")
            } else if reviewer.is_none() {
                Some(REVIEW_REPAIR_REQUIREMENT)
            } else if reviewer
                .as_ref()
                .is_some_and(|candidate| candidate.summary.worker_id == worker.summary.worker_id)
            {
                Some(
                    "The current reviewer cannot review its own bundle; activate another compatible reviewer.",
                )
            } else {
                None
            };
            let proposal = latest
                .as_ref()
                .map(|proposal| self.project_agent_role_review_proposal(proposal))
                .transpose()?;
            items.push(json!({
                "workerId":worker.summary.worker_id,
                "name":worker.summary.name,
                "description":worker.summary.description,
                "targetVersion":worker.summary.active_version,
                "classification":"needs_role_review",
                "proposal":proposal,
                "allowedActions":[
                    role_review_action("start_review", start_reason.is_none(), start_reason),
                    role_review_action(
                        "inspect",
                        latest.is_some(),
                        latest.is_none().then_some("No durable proposal exists yet."),
                    ),
                ],
            }));
        }
        let page = self.store.list_agent_role_review_proposals(limit, offset)?;
        let proposals = page
            .proposals
            .iter()
            .map(|proposal| self.project_agent_role_review_proposal(proposal))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(json!({
            "capability":AGENT_ROLE_REVIEW_CAPABILITY,
            "reviewer":reviewer_projection,
            "items":items,
            "queueTotal":queue_total,
            "queueReturned":queue_returned,
            "queueTruncated":queue_next_offset.is_some(),
            "queueNextOffset":queue_next_offset,
            "proposals":proposals,
            "returned":proposals.len(),
            "total":page.total,
            "nextOffset":page.next_offset,
        }))
    }

    pub(crate) async fn start_agent_role_review(
        self: &Arc<Self>,
        worker_id: &str,
        invocation: &crate::engine::Invocation,
    ) -> Result<Value, String> {
        let target = self.store.load_active(worker_id)?;
        if !target.summary.enabled || target.summary.retired {
            return Err(format!(
                "worker '{worker_id}' is not an active agent role review candidate"
            ));
        }
        if role_review_classification(&target.bundle) != "needs_role_review" {
            return Err(format!(
                "worker '{worker_id}' does not require an agent role review"
            ));
        }
        if let Some(existing) = self.store.latest_agent_role_review_proposal(worker_id)?
            && existing.target_worker_version == target.summary.active_version
            && matches!(
                existing.status,
                AgentRoleReviewStatus::Proposed | AgentRoleReviewStatus::Applying
            )
        {
            return self.project_agent_role_review_proposal(&existing);
        }
        let Some(reviewer) =
            self.active_engine_hook(WorkerEngineHook::AgentRoleReview, Some(worker_id))?
        else {
            metrics::counter!("worker_agent_role_reviews_unavailable_total").increment(1);
            return Err(REVIEW_REPAIR_REQUIREMENT.to_owned());
        };
        let delegable_tools = self.agent_role_delegable_authoring_catalog().await?;
        let reviewer_input = json!({
            "action":"agent_role_review",
            "target":agent_role_review_target(&target),
            "agentRoleSchema":super::super::contract::agent_role_authoring_schema(),
            "delegableTools":delegable_tools,
        });
        let execution = self
            .execute_engine_hook(
                WorkerEngineHook::AgentRoleReview,
                reviewer_input,
                Some(worker_id),
                invocation,
            )
            .await?
            .ok_or_else(|| REVIEW_REPAIR_REQUIREMENT.to_owned())?;
        if execution.worker_id != reviewer.summary.worker_id
            || execution.worker_version != reviewer.summary.active_version
        {
            return Err("agent role reviewer changed during proposal execution".to_owned());
        }
        let output: ReviewerProposalOutput = match serde_json::from_value(execution.output.clone())
        {
            Ok(output) => output,
            Err(error) => {
                let reason = self
                    .reject_engine_hook_output(
                        &execution,
                        WorkerEngineHook::AgentRoleReview,
                        &format!("output must contain only agentRole and rationale: {error}"),
                    )
                    .await;
                return Err(reason);
            }
        };
        let rationale =
            crate::shared::foundation::redaction::redact_sensitive_content(output.rationale.trim());
        if rationale.is_empty()
            || rationale.len() > 2_000
            || rationale.chars().any(char::is_control)
        {
            let reason = self
                .reject_engine_hook_output(
                    &execution,
                    WorkerEngineHook::AgentRoleReview,
                    "rationale must contain 1..=2000 UTF-8 bytes without controls",
                )
                .await;
            return Err(reason);
        }
        if let Err(error) = self
            .store
            .validate_agent_role_review_declaration(&target.bundle, &output.agent_role)
        {
            let reason = self
                .reject_engine_hook_output(&execution, WorkerEngineHook::AgentRoleReview, &error)
                .await;
            return Err(reason);
        }
        let mut activation_candidate = target.bundle.clone();
        activation_candidate.agent_role = Some(output.agent_role.clone());
        if let Err(error) = self
            .validate_agent_tool_allowlist_at_activation(&activation_candidate)
            .await
        {
            let reason = self
                .reject_engine_hook_output(&execution, WorkerEngineHook::AgentRoleReview, &error)
                .await;
            return Err(reason);
        }
        let available_tool_names = delegable_tools
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str))
            .collect::<BTreeSet<_>>();
        if let WorkerAgentRole::Enabled { tool_ceiling, .. } = &output.agent_role {
            let unavailable = tool_ceiling
                .iter()
                .filter(|tool| !available_tool_names.contains(tool.as_str()))
                .cloned()
                .collect::<Vec<_>>();
            if !unavailable.is_empty() {
                let reason = self
                    .reject_engine_hook_output(
                        &execution,
                        WorkerEngineHook::AgentRoleReview,
                        &format!(
                            "proposed agentRole names unavailable or nondelegable tools: {}",
                            unavailable.join(", ")
                        ),
                    )
                    .await;
                return Err(reason);
            }
        }
        let request_key = role_review_mutation_key(invocation, "start")?;
        let proposal_hash = agent_role_review_proposal_hash(
            &target.summary.worker_id,
            &target.summary.active_version,
            &target.summary.active_version,
            &reviewer.summary.worker_id,
            &reviewer.summary.active_version,
            &execution.invocation_id,
            &output.agent_role,
            &rationale,
        )?;
        let (proposal, created) =
            self.store
                .create_agent_role_review_proposal(&NewAgentRoleReviewProposal {
                    proposal_id: format!("agent_role_review_{proposal_hash}"),
                    request_key,
                    proposal_hash,
                    target_worker_id: target.summary.worker_id,
                    target_worker_version: target.summary.active_version.clone(),
                    target_content_hash: target.summary.active_version,
                    reviewer_worker_id: reviewer.summary.worker_id,
                    reviewer_worker_version: reviewer.summary.active_version,
                    reviewer_invocation_id: execution.invocation_id,
                    agent_role: output.agent_role,
                    rationale,
                })?;
        if created {
            metrics::counter!("worker_agent_role_reviews_proposed_total").increment(1);
            self.publish_role_review_event("proposed", &proposal).await;
        }
        self.project_agent_role_review_proposal(&proposal)
    }

    pub(crate) fn inspect_agent_role_review(&self, proposal_id: &str) -> Result<Value, String> {
        let proposal = self
            .store
            .agent_role_review_proposal(proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))?;
        self.project_agent_role_review_proposal(&proposal)
    }

    pub(crate) async fn apply_agent_role_review(
        self: &Arc<Self>,
        proposal_id: &str,
        invocation: &crate::engine::Invocation,
    ) -> Result<Value, String> {
        let proposal = self
            .store
            .agent_role_review_proposal(proposal_id)?
            .ok_or_else(|| format!("agent role review proposal '{proposal_id}' was not found"))?;
        self.validate_agent_role_review_proposal(&proposal)?;
        let target = self
            .store
            .load_version(&proposal.target_worker_id, &proposal.target_worker_version)?;
        let mut expected_bundle = target.bundle.clone();
        expected_bundle.agent_role = Some(proposal.agent_role.clone());
        let active = self.store.load_active(&proposal.target_worker_id)?;
        if !active.summary.enabled || active.summary.retired {
            let reason = format!(
                "target worker '{}' is no longer active",
                proposal.target_worker_id
            );
            if matches!(
                proposal.status,
                AgentRoleReviewStatus::Proposed | AgentRoleReviewStatus::Applying
            ) {
                let stale = self
                    .store
                    .mark_agent_role_review_stale(proposal_id, &reason)?;
                metrics::counter!("worker_agent_role_reviews_stale_total").increment(1);
                self.publish_role_review_event("stale", &stale).await;
            }
            return Err(reason);
        }
        if active.summary.active_version != proposal.target_worker_version {
            if bundles_equal(&active.bundle, &expected_bundle)? {
                let recovered_publication = proposal.status != AgentRoleReviewStatus::Applied;
                let proposal = self.store.complete_agent_role_review_apply(
                    proposal_id,
                    &active.summary.active_version,
                )?;
                if recovered_publication {
                    metrics::counter!("worker_agent_role_reviews_applied_total").increment(1);
                    self.publish_role_review_event("applied", &proposal).await;
                }
                return Ok(json!({
                    "proposal":self.project_agent_role_review_proposal(&proposal)?,
                    "worker":active.summary,
                }));
            }
            let reason = format!(
                "active target version changed from {} to {}",
                proposal.target_worker_version, active.summary.active_version
            );
            let stale = self
                .store
                .mark_agent_role_review_stale(proposal_id, &reason)?;
            metrics::counter!("worker_agent_role_reviews_stale_total").increment(1);
            self.publish_role_review_event("stale", &stale).await;
            return Err(reason);
        }
        if proposal.status != AgentRoleReviewStatus::Proposed {
            return Err(format!(
                "agent role review proposal '{proposal_id}' cannot apply while {}",
                proposal.status.as_str()
            ));
        }
        let application_key = role_review_mutation_key(invocation, "apply")?;
        self.store
            .begin_agent_role_review_apply(proposal_id, &application_key)?;
        let outcome = match self
            .upsert(expected_bundle, Some(&proposal.target_worker_id))
            .await
        {
            Ok(outcome) => outcome,
            Err(error) => {
                let _ = self.store.restore_agent_role_review_proposed(
                    proposal_id,
                    &application_key,
                    &error,
                );
                return Err(error);
            }
        };
        let proposal = self
            .store
            .complete_agent_role_review_apply(proposal_id, &outcome.version)?;
        metrics::counter!("worker_agent_role_reviews_applied_total").increment(1);
        self.publish_role_review_event("applied", &proposal).await;
        Ok(json!({
            "proposal":self.project_agent_role_review_proposal(&proposal)?,
            "worker":outcome.worker,
        }))
    }

    pub(crate) async fn reject_agent_role_review(
        &self,
        proposal_id: &str,
        reason: Option<&str>,
        invocation: &crate::engine::Invocation,
    ) -> Result<Value, String> {
        let rejection_key = role_review_mutation_key(invocation, "reject")?;
        let proposal =
            self.store
                .reject_agent_role_review_proposal(proposal_id, &rejection_key, reason)?;
        metrics::counter!("worker_agent_role_reviews_rejected_total").increment(1);
        self.publish_role_review_event("rejected", &proposal).await;
        self.project_agent_role_review_proposal(&proposal)
    }

    fn agent_role_review_candidates(&self) -> Result<Vec<ActiveWorker>, String> {
        let mut candidates = self
            .store
            .list(false)?
            .into_iter()
            .filter(|worker| worker.enabled && !worker.retired)
            .filter_map(
                |worker| match self.store.load_indexed_active(&worker.worker_id) {
                    Ok(active)
                        if role_review_classification(&active.bundle) == "needs_role_review" =>
                    {
                        Some(Ok(active))
                    }
                    Ok(_) => None,
                    Err(error) => Some(Err(error)),
                },
            )
            .collect::<Result<Vec<_>, _>>()?;
        candidates.sort_by(|left, right| left.summary.worker_id.cmp(&right.summary.worker_id));
        Ok(candidates)
    }

    fn agent_role_reviewer(&self) -> Result<Option<ActiveWorker>, String> {
        self.active_engine_hook(WorkerEngineHook::AgentRoleReview, None)
    }

    async fn agent_role_delegable_authoring_catalog(&self) -> Result<Vec<Value>, String> {
        let actor = ActorContext::new(
            ActorId::new("system:agent-role-review").map_err(|error| error.to_string())?,
            ActorKind::System,
        );
        let (_, functions) = self.host.visible_functions_with_revision(&actor).await;
        let mut tools = BTreeMap::new();
        for function in functions {
            if function.delegation_policy == crate::engine::DelegationPolicy::Never {
                continue;
            }
            let Some(model_tool) = function.model_tool else {
                continue;
            };
            tools.entry(model_tool.name.clone()).or_insert_with(|| {
                json!({
                    "name":model_tool.name,
                    "functionId":function.id.as_str(),
                    "description":crate::shared::foundation::text::truncate_with_suffix(
                        &crate::shared::foundation::redaction::redact_sensitive_content(
                            &function.description,
                        ),
                        512,
                        "…",
                    ),
                    "delegation":function.delegation_policy.as_str(),
                    "workspaceEffect":function.workspace_effect.as_str(),
                })
            });
        }
        if tools.len() > MAX_DELEGABLE_TOOLS {
            return Err(format!(
                "delegable agent-role authoring catalog contains {} tools; the reliability ceiling is {MAX_DELEGABLE_TOOLS}",
                tools.len()
            ));
        }
        Ok(tools.into_values().collect())
    }

    fn validate_agent_role_review_proposal(
        &self,
        proposal: &AgentRoleReviewProposalRecord,
    ) -> Result<(), String> {
        if proposal.schema_version != AGENT_ROLE_REVIEW_SCHEMA_VERSION {
            return Err(format!(
                "unsupported agent role review schema '{}'",
                proposal.schema_version
            ));
        }
        if proposal.target_content_hash != proposal.target_worker_version {
            return Err("agent role review target content hash/version mismatch".to_owned());
        }
        let expected_hash = agent_role_review_proposal_hash(
            &proposal.target_worker_id,
            &proposal.target_worker_version,
            &proposal.target_content_hash,
            &proposal.reviewer_worker_id,
            &proposal.reviewer_worker_version,
            &proposal.reviewer_invocation_id,
            &proposal.agent_role,
            &proposal.rationale,
        )?;
        if expected_hash != proposal.proposal_hash {
            return Err("agent role review proposal hash mismatch".to_owned());
        }
        let target = self
            .store
            .load_version(&proposal.target_worker_id, &proposal.target_worker_version)?;
        self.store
            .validate_agent_role_review_declaration(&target.bundle, &proposal.agent_role)?;
        let reviewer = self.store.load_version(
            &proposal.reviewer_worker_id,
            &proposal.reviewer_worker_version,
        )?;
        if !reviewer
            .bundle
            .engine_hooks
            .contains(&WorkerEngineHook::AgentRoleReview)
        {
            return Err("pinned reviewer version no longer declares agent_role_review".to_owned());
        }
        let reviewer_invocation = self
            .store
            .invocation(&proposal.reviewer_invocation_id)?
            .ok_or_else(|| "pinned reviewer invocation no longer exists".to_owned())?;
        if reviewer_invocation.worker_id != proposal.reviewer_worker_id
            || reviewer_invocation.worker_version != proposal.reviewer_worker_version
            || reviewer_invocation.status != "completed"
            || reviewer_invocation.trigger_kind != "engine_hook:agent_role_review"
        {
            return Err("pinned reviewer invocation provenance does not match proposal".to_owned());
        }
        Ok(())
    }

    fn project_agent_role_review_proposal(
        &self,
        proposal: &AgentRoleReviewProposalRecord,
    ) -> Result<Value, String> {
        let apply_reason = if proposal.status == AgentRoleReviewStatus::Proposed {
            self.agent_role_review_apply_disabled_reason(proposal)
        } else {
            Some(format!(
                "Proposal is {} and cannot be applied.",
                proposal.status.as_str()
            ))
        };
        let reject_reason = (proposal.status != AgentRoleReviewStatus::Proposed).then(|| {
            format!(
                "Proposal is {} and cannot be rejected.",
                proposal.status.as_str()
            )
        });
        let mut value = serde_json::to_value(proposal).map_err(|error| error.to_string())?;
        value["allowedActions"] = json!([
            role_review_action("inspect", true, None),
            role_review_action("apply", apply_reason.is_none(), apply_reason.as_deref()),
            role_review_action("reject", reject_reason.is_none(), reject_reason.as_deref()),
        ]);
        Ok(value)
    }

    fn agent_role_review_apply_disabled_reason(
        &self,
        proposal: &AgentRoleReviewProposalRecord,
    ) -> Option<String> {
        if let Err(error) = self.validate_agent_role_review_proposal(proposal) {
            return Some(error);
        }
        let active = match self.store.load_active(&proposal.target_worker_id) {
            Ok(active) => active,
            Err(error) => return Some(error),
        };
        if !active.summary.enabled || active.summary.retired {
            return Some(format!(
                "Target worker '{}' is no longer active.",
                proposal.target_worker_id
            ));
        }
        if active.summary.active_version == proposal.target_worker_version {
            return None;
        }
        let target = match self
            .store
            .load_version(&proposal.target_worker_id, &proposal.target_worker_version)
        {
            Ok(target) => target,
            Err(error) => return Some(error),
        };
        let mut expected = target.bundle;
        expected.agent_role = Some(proposal.agent_role.clone());
        match bundles_equal(&active.bundle, &expected) {
            Ok(true) => None,
            Ok(false) => Some(format!(
                "Active target version changed to {}.",
                active.summary.active_version
            )),
            Err(error) => Some(error),
        }
    }

    async fn publish_role_review_event(
        &self,
        action: &str,
        proposal: &AgentRoleReviewProposalRecord,
    ) {
        self.publish_event(
            "worker.role_review",
            json!({
                "action":action,
                "proposalId":proposal.proposal_id,
                "targetWorkerId":proposal.target_worker_id,
                "status":proposal.status,
            }),
            None,
        )
        .await;
    }
}

pub(super) fn role_review_classification(bundle: &WorkerBundle) -> &'static str {
    match (&bundle.runner, &bundle.agent_role) {
        (WorkerRunner::Agent { .. }, Some(_)) => "declared",
        (WorkerRunner::Agent { .. }, None) => "needs_role_review",
        (WorkerRunner::Command { .. } | WorkerRunner::Service { .. }, _) => "ineligible",
    }
}

fn agent_role_review_target(target: &ActiveWorker) -> Value {
    json!({
        "workerId":target.summary.worker_id,
        "workerVersion":target.summary.active_version,
        "name":target.bundle.name,
        "description":target.bundle.description,
        "modelExposure":match target.bundle.model_exposure {
            WorkerModelExposure::Direct => "direct",
            WorkerModelExposure::Internal => "internal",
        },
        "runner":target.bundle.runner,
        "agentTools":target.bundle.agent_tools,
        "inputSchema":target.bundle.input_schema,
        "outputSchema":target.bundle.output_schema,
        "routing":target.bundle.routing,
        "provenance":target.bundle.provenance.iter().take(8).map(|source| json!({
            "source":crate::shared::foundation::redaction::redact_sensitive_content(&source.source),
            "revision":source.revision,
            "checksum":source.checksum,
        })).collect::<Vec<_>>(),
    })
}

fn role_review_action(action: &str, allowed: bool, disabled_reason: Option<&str>) -> Value {
    json!({
        "action":action,
        "allowed":allowed,
        "disabledReason":disabled_reason,
    })
}

fn role_review_mutation_key(
    invocation: &crate::engine::Invocation,
    action: &str,
) -> Result<String, String> {
    let key = invocation
        .causal_context
        .idempotency_key
        .as_deref()
        .ok_or_else(|| format!("agent role review {action} requires an idempotency key"))?;
    Ok(format!(
        "role-review:{action}:{}",
        hex::encode(Sha256::digest(key.as_bytes()))
    ))
}

fn agent_role_review_proposal_hash(
    target_worker_id: &str,
    target_worker_version: &str,
    target_content_hash: &str,
    reviewer_worker_id: &str,
    reviewer_worker_version: &str,
    reviewer_invocation_id: &str,
    agent_role: &WorkerAgentRole,
    rationale: &str,
) -> Result<String, String> {
    let payload = serde_json::to_vec(&json!({
        "schemaVersion":AGENT_ROLE_REVIEW_SCHEMA_VERSION,
        "targetWorkerId":target_worker_id,
        "targetWorkerVersion":target_worker_version,
        "targetContentHash":target_content_hash,
        "reviewerWorkerId":reviewer_worker_id,
        "reviewerWorkerVersion":reviewer_worker_version,
        "reviewerInvocationId":reviewer_invocation_id,
        "agentRole":agent_role,
        "rationale":rationale,
    }))
    .map_err(|error| format!("encode agent role review proposal hash: {error}"))?;
    Ok(hex::encode(Sha256::digest(payload)))
}

fn bundles_equal(left: &WorkerBundle, right: &WorkerBundle) -> Result<bool, String> {
    Ok(
        serde_json::to_value(left).map_err(|error| error.to_string())?
            == serde_json::to_value(right).map_err(|error| error.to_string())?,
    )
}
