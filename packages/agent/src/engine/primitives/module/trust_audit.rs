//! Decision-backed module trust audit scheduling, status, and retention review.
//!
//! This submodule owns the trust-audit schedule parser and due-bucket helpers so
//! host queue projection, operator status, generated UI actions, and retention
//! evidence all use one schedule model without adding an audit/status table.

use std::collections::BTreeSet;

use chrono::Duration as ChronoDuration;

use super::*;
use crate::engine::primitives::action_summary::operator_action_summary;
use crate::engine::queue::EngineQueueItem;

mod schedule;

use schedule::{
    TrustAuditSchedule, parse_trust_audit_wall_clock_time, trust_audit_day_of_week_number,
    trust_audit_retention_policy, validate_schedule_token,
};
pub(in crate::engine) use schedule::{
    trust_audit_current_due_bucket, trust_audit_schedule_resource_id,
};

pub(crate) const SCHEDULE_TRUST_AUDIT_FUNCTION: &str = "module::schedule_trust_audit";
pub(crate) const RUN_SCHEDULED_TRUST_AUDIT_FUNCTION: &str = "module::run_scheduled_trust_audit";
pub(crate) const TRUST_AUDIT_STATUS_FUNCTION: &str = "module::trust_audit_status";
pub(crate) const RECORD_TRUST_AUDIT_RETENTION_FUNCTION: &str =
    "module::record_trust_audit_retention";

const MAX_MISSED_BUCKETS: usize = 25;

#[derive(Clone)]
struct TrustAuditEvidenceSummary {
    resource_id: String,
    version_id: Option<String>,
    due_bucket: Option<String>,
    evidence_type: String,
    created_at: DateTime<Utc>,
    affected_packages: Vec<Value>,
    affected_activations: Vec<Value>,
}

impl ModulePrimitiveHandler {
    pub(super) fn schedule_trust_audit(&self, invocation: &Invocation) -> Result<Value> {
        let (scope, scope_token) = resource_scope_and_token(invocation)?;
        let schedule_id = optional_string(invocation.payload.get("scheduleId"))?
            .unwrap_or_else(|| "default".to_owned());
        validate_schedule_token("scheduleId", &schedule_id)?;
        let selectors = string_array_from(invocation.payload.get("selectors"), "selectors")?;
        if selectors.is_empty() {
            return Err(EngineError::PolicyViolation(
                "schedule_trust_audit requires at least one selector".to_owned(),
            ));
        }
        let cadence = required_value_str(&invocation.payload, "cadence")?;
        if !matches!(cadence, "daily" | "weekly") {
            return Err(EngineError::PolicyViolation(
                "schedule_trust_audit cadence must be daily or weekly".to_owned(),
            ));
        }
        let timezone = required_value_str(&invocation.payload, "timezone")?;
        let _: chrono_tz::Tz = timezone.parse().map_err(|_| {
            EngineError::PolicyViolation(format!("unsupported schedule timezone {timezone}"))
        })?;
        let wall_clock_time = required_value_str(&invocation.payload, "wallClockTime")?;
        parse_trust_audit_wall_clock_time(wall_clock_time)?;
        let day_of_week = optional_string(invocation.payload.get("dayOfWeek"))?;
        if cadence == "weekly" {
            let day = day_of_week.as_deref().ok_or_else(|| {
                EngineError::PolicyViolation(
                    "weekly trust audit schedules require dayOfWeek".to_owned(),
                )
            })?;
            trust_audit_day_of_week_number(day)?;
        }
        let expires_at = parse_datetime(required_value_str(&invocation.payload, "expiresAt")?)?;
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "schedule_trust_audit expiresAt must be in the future".to_owned(),
            ));
        }
        let grant_ceiling = invocation
            .payload
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "schedule_trust_audit requires grantCeiling".to_owned(),
                )
            })?;
        ensure_grant_ceiling_narrows_caller(self, invocation, grant_ceiling)?;
        let retention_policy =
            trust_audit_retention_policy(invocation.payload.get("retentionPolicy"))?;
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({
            "selectors": selectors,
            "reason": reason,
            "retentionPolicy": retention_policy,
        }))?;

        let resource_id = trust_audit_schedule_resource_id(&scope_token, &schedule_id);
        let payload = json!({
            "status": "active",
            "summary": format!("Module trust audit schedule {schedule_id}"),
            "metadata": {
                "decisionType": "module_trust_audit_schedule",
                "scheduleId": schedule_id,
                "scope": invocation.payload.get("scope").cloned().unwrap_or_else(|| json!("workspace")),
                "scopeToken": scope_token,
                "workspaceId": invocation.payload.get("workspaceId").cloned().unwrap_or(Value::Null),
                "sessionId": invocation.payload.get("sessionId").cloned().unwrap_or(Value::Null),
                "selectors": selectors,
                "cadence": cadence,
                "timezone": timezone,
                "wallClockTime": wall_clock_time,
                "dayOfWeek": day_of_week,
                "expiresAt": expires_at.to_rfc3339(),
                "grantCeiling": grant_ceiling,
                "retentionPolicy": retention_policy,
                "redactionPolicy": invocation.payload.get("redactionPolicy").cloned().unwrap_or_else(|| json!({"mode": "redacted"})),
                "reason": reason,
                "createdByInvocationId": invocation.id.as_str(),
            }
        });
        if let Some(existing) = self.inspect_resource(&resource_id)? {
            let expected = required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
            ensure_expected_current_version(&existing, &expected)?;
            self.update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: Some(expected),
                lifecycle: Some("final".to_owned()),
                payload: payload.clone(),
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })?;
        } else {
            self.create_resource(CreateResource {
                resource_id: Some(resource_id.clone()),
                kind: "decision".to_owned(),
                schema_id: None,
                scope,
                owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some("final".to_owned()),
                policy: json!({"managedBy": "module", "schedule": "trust_audit"}),
                initial_payload: Some(payload.clone()),
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })?;
        }
        let inspection = require_inspection(self, &resource_id, "decision")?;
        let decision_ref = resource_ref_from_resource(&inspection.resource, "schedule");
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module trust audit schedule {resource_id} recorded"),
            SCHEDULE_TRUST_AUDIT_FUNCTION,
            &resource_id,
            json!({
                "evidenceType": "trust_audit_schedule_recorded",
                "scheduleResourceId": resource_id,
                "scheduleVersionId": inspection.resource.current_version_id,
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &resource_id,
            "evidence_for",
            invocation,
        )?;
        Ok(json!({
            "schedule": {
                "resourceId": resource_id,
                "versionId": inspection.resource.current_version_id,
                "payload": payload,
            },
            "decision": payload,
            "resource": inspection.resource,
            "evidence": evidence.resource,
            "resourceRefs": [decision_ref, evidence.reference],
        }))
    }

    pub(super) fn trust_audit_status(&self, invocation: &Invocation) -> Result<Value> {
        let schedule_resource_id =
            required_string_owned(&invocation.payload, "scheduleDecisionResourceId")?;
        let requested_version_id =
            optional_string(invocation.payload.get("scheduleDecisionVersionId"))?;
        let as_of = if let Some(value) = optional_string(invocation.payload.get("asOf"))? {
            parse_datetime(&value)?
        } else {
            Utc::now()
        };
        let include_evidence = invocation
            .payload
            .get("includeEvidence")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let include_queue = invocation
            .payload
            .get("includeQueue")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(50)
            .clamp(1, 500) as usize;

        let inspection = require_inspection(self, &schedule_resource_id, "decision")?;
        let mut warnings = Vec::new();
        if let Some(requested) = requested_version_id.as_deref()
            && inspection.resource.current_version_id.as_deref() != Some(requested)
        {
            warnings.push(json!({
                "code": "stale_schedule_version",
                "message": "requested schedule version is not current",
                "requestedVersionId": requested,
                "currentVersionId": inspection.resource.current_version_id,
            }));
        }
        let schedule = TrustAuditSchedule::from_inspection(&inspection)?;
        if schedule.lifecycle == "archived" {
            warnings.push(json!({"code": "schedule_archived"}));
        }
        if schedule.expires_at <= as_of {
            warnings.push(json!({"code": "schedule_expired"}));
        }
        if schedule.status != "active" {
            warnings.push(json!({"code": "schedule_not_active", "status": schedule.status}));
        }
        let current_due_bucket = schedule.current_due_bucket(as_of);
        if current_due_bucket.is_none()
            && schedule.status == "active"
            && schedule.expires_at > as_of
        {
            warnings.push(json!({"code": "not_due"}));
        }

        let evidence = self.trust_audit_evidence_for_schedule(&schedule.resource_id, 500)?;
        let queue_items = self.trust_audit_queue_items(&schedule.resource_id, limit)?;
        let last_completed_bucket = latest_completed_bucket(&evidence);
        let last_queued_bucket = latest_queued_bucket(&queue_items);
        let missed_buckets = schedule.missed_buckets(as_of, MAX_MISSED_BUCKETS);
        let latest_evidence_refs = if include_evidence {
            evidence
                .iter()
                .rev()
                .take(limit)
                .map(|summary| summary.reference())
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let queue_refs = if include_queue {
            queue_items
                .iter()
                .take(limit)
                .map(queue_item_ref)
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let retention_warnings = retention_warnings(&schedule, &evidence, as_of, limit)
            .into_iter()
            .collect::<Vec<_>>();
        let (affected_packages, affected_activations) = latest_affected_refs(&evidence, limit);

        Ok(json!({
            "schedule": {
                "resourceId": schedule.resource_id,
                "versionId": schedule.version_id,
                "lifecycle": schedule.lifecycle,
                "status": schedule.status,
                "cadence": schedule.cadence,
                "timezone": schedule.timezone_name,
                "wallClockTime": format!("{:02}:{:02}", schedule.hour, schedule.minute),
                "dayOfWeek": schedule.day_of_week,
                "selectors": schedule.selectors,
                "expiresAt": schedule.expires_at.to_rfc3339(),
                "retentionPolicy": {"reviewAfterDays": schedule.retention_review_after_days},
            },
            "due": {
                "asOf": as_of.to_rfc3339(),
                "currentDueBucket": current_due_bucket,
                "lastQueuedBucket": last_queued_bucket,
                "lastCompletedBucket": last_completed_bucket,
                "missedBuckets": missed_buckets,
            },
            "queueRefs": queue_refs,
            "latestEvidenceRefs": latest_evidence_refs,
            "affectedPackageRefs": affected_packages,
            "affectedActivationRefs": affected_activations,
            "warnings": warnings,
            "retentionWarnings": retention_warnings,
            "availableActions": trust_audit_status_actions(&schedule),
        }))
    }

    pub(super) fn run_scheduled_trust_audit(&self, invocation: &Invocation) -> Result<Value> {
        let schedule_resource_id =
            required_string_owned(&invocation.payload, "scheduleDecisionResourceId")?;
        let schedule_version_id =
            required_string_owned(&invocation.payload, "scheduleDecisionVersionId")?;
        let due_bucket = required_value_str(&invocation.payload, "dueBucket")?;
        let schedule = require_inspection(self, &schedule_resource_id, "decision")?;
        ensure_version_is_current(&schedule, &schedule_version_id)?;
        if schedule.resource.lifecycle == "archived" {
            return Err(EngineError::PolicyViolation(format!(
                "trust audit schedule {schedule_resource_id} is archived"
            )));
        }
        if self.trust_root_decision_revoked(&schedule_resource_id)? {
            return Err(EngineError::PolicyViolation(format!(
                "trust audit schedule {schedule_resource_id} is revoked"
            )));
        }
        let payload = version_payload(&schedule, &schedule_version_id)?;
        let parsed_schedule = TrustAuditSchedule::from_inspection(&schedule)?;
        if parsed_schedule.status != "active" {
            return Err(EngineError::PolicyViolation(format!(
                "trust audit schedule {schedule_resource_id} is not active"
            )));
        }
        if parsed_schedule.expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(format!(
                "trust audit schedule {schedule_resource_id} is expired"
            )));
        }
        let metadata = trust_decision_metadata(&payload, "module_trust_audit_schedule")?;
        let grant_ceiling = metadata
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation("trust audit schedule missing grantCeiling".to_owned())
            })?;
        ensure_grant_ceiling_narrows_caller(self, invocation, grant_ceiling)?;
        let packages = self.packages_matching_selectors(&parsed_schedule.selectors, 500)?;
        let mut audits = Vec::new();
        let mut skipped = Vec::new();
        for package in packages {
            let package_resource_id = package["packageResourceId"].as_str().unwrap_or_default();
            let Some(inspection) = self.inspect_resource(package_resource_id)? else {
                skipped.push(json!({
                    "packageResourceId": package_resource_id,
                    "reason": "missing_package_resource",
                }));
                continue;
            };
            let Some(version_id) = inspection.resource.current_version_id.clone() else {
                skipped.push(json!({
                    "packageResourceId": package_resource_id,
                    "reason": "missing_current_version",
                }));
                continue;
            };
            let manifest = version_payload(&inspection, &version_id)?;
            audits.push(self.policy_audit_for_manifest(
                package_resource_id,
                &version_id,
                &manifest,
                &parsed_schedule.scope_token,
                None,
                true,
            )?);
        }
        let audits_payload = json!(audits.clone());
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module scheduled trust audit {schedule_resource_id} completed"),
            RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
            &schedule_resource_id,
            json!({
                "evidenceType": "scheduled_trust_audit",
                "scheduleResourceId": schedule_resource_id,
                "scheduleVersionId": schedule_version_id,
                "dueBucket": due_bucket,
                "audits": bounded_json(&audits_payload, 32 * 1024),
                "skipped": skipped.clone(),
                "checkedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        self.link_required(
            &evidence.resource.resource_id,
            &schedule_resource_id,
            "evidence_for",
            invocation,
        )?;
        for audit in audits.iter() {
            if let Some(package_id) = audit.get("packageResourceId").and_then(Value::as_str) {
                self.link_required(
                    &evidence.resource.resource_id,
                    package_id,
                    "affects_package",
                    invocation,
                )?;
            }
            for activation in audit
                .get("affectedActivations")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(activation_id) = activation
                    .get("activationResourceId")
                    .and_then(Value::as_str)
                {
                    self.link_required(
                        &evidence.resource.resource_id,
                        activation_id,
                        "affects_activation",
                        invocation,
                    )?;
                }
            }
        }
        Ok(json!({
            "schedule": {
                "resourceId": schedule_resource_id,
                "versionId": schedule_version_id,
                "dueBucket": due_bucket,
            },
            "audit": {
                "audits": audits,
                "skipped": skipped,
            },
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference],
        }))
    }

    pub(super) fn record_trust_audit_retention(&self, invocation: &Invocation) -> Result<Value> {
        let schedule_resource_id =
            required_string_owned(&invocation.payload, "scheduleDecisionResourceId")?;
        let schedule_version_id =
            required_string_owned(&invocation.payload, "scheduleDecisionVersionId")?;
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"reason": reason}))?;
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(100)
            .clamp(1, 500) as usize;
        let schedule = require_inspection(self, &schedule_resource_id, "decision")?;
        ensure_version_is_current(&schedule, &schedule_version_id)?;
        let parsed_schedule = TrustAuditSchedule::from_inspection(&schedule)?;
        let older_than = if let Some(value) = optional_string(invocation.payload.get("olderThan"))?
        {
            parse_datetime(&value)?
        } else {
            Utc::now() - ChronoDuration::days(parsed_schedule.retention_review_after_days as i64)
        };
        let evidence = self.trust_audit_evidence_for_schedule(&schedule_resource_id, 500)?;
        let eligible = evidence
            .into_iter()
            .filter(|summary| summary.evidence_type == "scheduled_trust_audit")
            .filter(|summary| summary.created_at <= older_than)
            .take(limit)
            .collect::<Vec<_>>();
        let eligible_refs = eligible
            .iter()
            .map(TrustAuditEvidenceSummary::reference)
            .collect::<Vec<_>>();
        let review = self.create_evidence_resource(
            invocation,
            &format!("module trust audit retention reviewed for {schedule_resource_id}"),
            RECORD_TRUST_AUDIT_RETENTION_FUNCTION,
            &schedule_resource_id,
            json!({
                "evidenceType": "trust_audit_retention_review",
                "scheduleResourceId": schedule_resource_id,
                "scheduleVersionId": schedule_version_id,
                "olderThan": older_than.to_rfc3339(),
                "eligibleEvidenceRefs": eligible_refs,
                "eligibleCount": eligible.len(),
                "retentionPolicy": {"reviewAfterDays": parsed_schedule.retention_review_after_days},
                "reason": reason,
                "reviewedAt": Utc::now().to_rfc3339(),
            }),
        )?;
        self.link_required(
            &review.resource.resource_id,
            &schedule_resource_id,
            "evidence_for",
            invocation,
        )?;
        for summary in &eligible {
            self.link_required(
                &review.resource.resource_id,
                &summary.resource_id,
                "supports",
                invocation,
            )?;
        }
        Ok(json!({
            "retentionReview": {
                "scheduleResourceId": schedule_resource_id,
                "scheduleVersionId": schedule_version_id,
                "olderThan": older_than.to_rfc3339(),
                "eligibleCount": eligible.len(),
            },
            "eligibleEvidenceRefs": eligible_refs,
            "evidence": review.resource,
            "resourceRefs": [review.reference],
        }))
    }

    fn trust_audit_evidence_for_schedule(
        &self,
        schedule_resource_id: &str,
        limit: usize,
    ) -> Result<Vec<TrustAuditEvidenceSummary>> {
        let resources = self.list_resources(ListResources {
            kind: Some("evidence".to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut evidence = Vec::new();
        for resource in resources {
            let Some(inspection) = self.inspect_resource(&resource.resource_id)? else {
                continue;
            };
            let Some(payload) = current_payload(&inspection) else {
                continue;
            };
            let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
                continue;
            };
            if metadata.get("scheduleResourceId").and_then(Value::as_str)
                != Some(schedule_resource_id)
            {
                continue;
            }
            let evidence_type = metadata
                .get("evidenceType")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            if !matches!(
                evidence_type.as_str(),
                "scheduled_trust_audit" | "trust_audit_retention_review"
            ) {
                continue;
            }
            let affected_packages = inspection
                .outgoing_links
                .iter()
                .filter(|link| link.relation == "affects_package")
                .map(|link| json!({"resourceId": link.target_resource_id}))
                .collect::<Vec<_>>();
            let affected_activations = inspection
                .outgoing_links
                .iter()
                .filter(|link| link.relation == "affects_activation")
                .map(|link| json!({"resourceId": link.target_resource_id}))
                .collect::<Vec<_>>();
            evidence.push(TrustAuditEvidenceSummary {
                resource_id: inspection.resource.resource_id,
                version_id: inspection.resource.current_version_id,
                due_bucket: metadata
                    .get("dueBucket")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                evidence_type,
                created_at: inspection.resource.created_at,
                affected_packages,
                affected_activations,
            });
            if evidence.len() >= limit {
                break;
            }
        }
        evidence.sort_by_key(|summary| summary.created_at);
        Ok(evidence)
    }

    fn trust_audit_queue_items(
        &self,
        schedule_resource_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineQueueItem>> {
        let items = self
            .stores
            .queue
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .list("module", 500)?;
        Ok(items
            .into_iter()
            .filter(|item| {
                item.function_id.as_str() == RUN_SCHEDULED_TRUST_AUDIT_FUNCTION
                    && item
                        .payload
                        .get("scheduleDecisionResourceId")
                        .and_then(Value::as_str)
                        == Some(schedule_resource_id)
            })
            .take(limit)
            .collect())
    }

    fn packages_matching_selectors(
        &self,
        selectors: &[String],
        limit: usize,
    ) -> Result<Vec<Value>> {
        let resources = self.list_resources(ListResources {
            kind: Some(WORKER_PACKAGE_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 500,
        })?;
        let mut packages = Vec::new();
        for resource in resources {
            if packages.len() >= limit {
                break;
            }
            let Some(inspection) = self.inspect_resource(&resource.resource_id)? else {
                continue;
            };
            let Some(manifest) = current_payload(&inspection) else {
                continue;
            };
            if package_selector_matches(selectors, &manifest, &resource.resource_id)? {
                packages.push(package_trust_summary(&inspection)?);
            }
        }
        Ok(packages)
    }
}

impl TrustAuditEvidenceSummary {
    fn reference(&self) -> Value {
        json!({
            "resourceId": self.resource_id,
            "kind": "evidence",
            "versionId": self.version_id,
            "role": self.evidence_type,
            "contentHash": Value::Null,
            "relation": "evidence_for",
            "dueBucket": self.due_bucket,
            "createdAt": self.created_at.to_rfc3339(),
        })
    }
}

pub(in crate::engine) fn trust_audit_evidence_matches_due_bucket(
    payload: &Value,
    schedule_resource_id: &str,
    schedule_version_id: &str,
    due_bucket: &str,
) -> bool {
    let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
        return false;
    };
    metadata.get("evidenceType").and_then(Value::as_str) == Some("scheduled_trust_audit")
        && metadata.get("scheduleResourceId").and_then(Value::as_str) == Some(schedule_resource_id)
        && metadata.get("scheduleVersionId").and_then(Value::as_str) == Some(schedule_version_id)
        && metadata.get("dueBucket").and_then(Value::as_str) == Some(due_bucket)
}

fn latest_completed_bucket(evidence: &[TrustAuditEvidenceSummary]) -> Option<String> {
    evidence
        .iter()
        .filter(|summary| summary.evidence_type == "scheduled_trust_audit")
        .filter_map(|summary| {
            summary
                .due_bucket
                .clone()
                .map(|bucket| (summary.created_at, bucket))
        })
        .max_by_key(|(created_at, _)| *created_at)
        .map(|(_, bucket)| bucket)
}

fn latest_queued_bucket(items: &[EngineQueueItem]) -> Option<String> {
    items
        .iter()
        .filter_map(|item| {
            item.payload
                .get("dueBucket")
                .and_then(Value::as_str)
                .map(|bucket| (item.created_at, bucket.to_owned()))
        })
        .max_by_key(|(created_at, _)| *created_at)
        .map(|(_, bucket)| bucket)
}

fn queue_item_ref(item: &EngineQueueItem) -> Value {
    json!({
        "receiptId": item.receipt_id,
        "functionId": item.function_id,
        "status": item.status,
        "dueBucket": item.payload.get("dueBucket").cloned().unwrap_or(Value::Null),
        "createdAt": item.created_at.to_rfc3339(),
        "updatedAt": item.updated_at.to_rfc3339(),
    })
}

fn latest_affected_refs(
    evidence: &[TrustAuditEvidenceSummary],
    limit: usize,
) -> (Vec<Value>, Vec<Value>) {
    let mut packages = BTreeSet::new();
    let mut activations = BTreeSet::new();
    for summary in evidence.iter().rev() {
        for package in &summary.affected_packages {
            if let Some(resource_id) = package.get("resourceId").and_then(Value::as_str) {
                packages.insert(resource_id.to_owned());
            }
        }
        for activation in &summary.affected_activations {
            if let Some(resource_id) = activation.get("resourceId").and_then(Value::as_str) {
                activations.insert(resource_id.to_owned());
            }
        }
    }
    (
        packages
            .into_iter()
            .take(limit)
            .map(|resource_id| json!({"resourceId": resource_id, "kind": WORKER_PACKAGE_KIND}))
            .collect(),
        activations
            .into_iter()
            .take(limit)
            .map(|resource_id| json!({"resourceId": resource_id, "kind": ACTIVATION_RECORD_KIND}))
            .collect(),
    )
}

fn retention_warnings(
    schedule: &TrustAuditSchedule,
    evidence: &[TrustAuditEvidenceSummary],
    as_of: DateTime<Utc>,
    limit: usize,
) -> Vec<Value> {
    let older_than = as_of - ChronoDuration::days(schedule.retention_review_after_days as i64);
    evidence
        .iter()
        .filter(|summary| summary.evidence_type == "scheduled_trust_audit")
        .filter(|summary| summary.created_at <= older_than)
        .take(limit)
        .map(|summary| {
            json!({
                "code": "audit_evidence_retention_review_due",
                "evidenceResourceId": summary.resource_id,
                "dueBucket": summary.due_bucket,
                "createdAt": summary.created_at.to_rfc3339(),
                "reviewAfterDays": schedule.retention_review_after_days,
            })
        })
        .collect()
}

fn trust_audit_status_actions(schedule: &TrustAuditSchedule) -> Vec<Value> {
    let mut actions = vec![
        trust_audit_action(
            TRUST_AUDIT_STATUS_FUNCTION,
            &schedule.resource_id,
            "low",
            false,
        ),
        trust_audit_action(
            RECORD_TRUST_AUDIT_RETENTION_FUNCTION,
            &schedule.resource_id,
            "medium",
            false,
        ),
    ];
    if schedule.lifecycle != "archived" && schedule.status == "active" {
        actions.push(trust_audit_action(
            RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
            &schedule.resource_id,
            "medium",
            false,
        ));
        actions.push(trust_audit_action(
            EXPIRE_TRUST_DECISION_FUNCTION,
            &schedule.resource_id,
            "high",
            true,
        ));
    }
    actions
}

fn trust_audit_action(
    function_id: &str,
    schedule_resource_id: &str,
    risk: &str,
    approval_required: bool,
) -> Value {
    let mut action = operator_action_summary(
        function_id,
        "decision",
        "scheduleDecisionResourceId",
        json!(schedule_resource_id),
        risk,
        approval_required,
    );
    action["targetResourceId"] = json!(schedule_resource_id);
    action
}

pub(super) fn trust_audit_status_schema() -> Value {
    json!({
        "type": "object",
        "required": ["scheduleDecisionResourceId"],
        "additionalProperties": false,
        "properties": {
            "scheduleDecisionResourceId": {"type": "string"},
            "scheduleDecisionVersionId": {"type": "string"},
            "asOf": {"type": "string"},
            "includeEvidence": {"type": "boolean"},
            "includeQueue": {"type": "boolean"},
            "limit": {"type": "integer"}
        }
    })
}

pub(super) fn schedule_trust_audit_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "scope",
            "selectors",
            "cadence",
            "timezone",
            "wallClockTime",
            "expiresAt",
            "grantCeiling",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "scheduleId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "selectors": {"type": "array", "items": {"type": "string"}},
            "cadence": {"type": "string", "enum": ["daily", "weekly"]},
            "timezone": {"type": "string"},
            "wallClockTime": {"type": "string"},
            "dayOfWeek": {"type": "string"},
            "expiresAt": {"type": "string"},
            "grantCeiling": {"type": "object"},
            "retentionPolicy": {
                "type": "object",
                "additionalProperties": false,
                "properties": {"reviewAfterDays": {"type": "integer"}}
            },
            "redactionPolicy": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

pub(super) fn run_scheduled_trust_audit_schema() -> Value {
    json!({
        "type": "object",
        "required": ["scheduleDecisionResourceId", "scheduleDecisionVersionId", "dueBucket"],
        "additionalProperties": false,
        "properties": {
            "scheduleDecisionResourceId": {"type": "string"},
            "scheduleDecisionVersionId": {"type": "string"},
            "dueBucket": {"type": "string"}
        }
    })
}

pub(super) fn record_trust_audit_retention_schema() -> Value {
    json!({
        "type": "object",
        "required": ["scheduleDecisionResourceId", "scheduleDecisionVersionId", "reason"],
        "additionalProperties": false,
        "properties": {
            "scheduleDecisionResourceId": {"type": "string"},
            "scheduleDecisionVersionId": {"type": "string"},
            "olderThan": {"type": "string"},
            "limit": {"type": "integer"},
            "reason": {"type": "string"}
        }
    })
}
