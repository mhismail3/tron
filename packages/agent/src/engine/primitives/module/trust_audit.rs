use super::*;

pub(crate) const SCHEDULE_TRUST_AUDIT_FUNCTION: &str = "module::schedule_trust_audit";
pub(crate) const RUN_SCHEDULED_TRUST_AUDIT_FUNCTION: &str = "module::run_scheduled_trust_audit";

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
        let reason = required_value_str(&invocation.payload, "reason")?;
        reject_raw_secrets(&json!({"selectors": selectors, "reason": reason}))?;

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
        let metadata = trust_decision_metadata(&payload, "module_trust_audit_schedule")?;
        if payload.get("status").and_then(Value::as_str) != Some("active") {
            return Err(EngineError::PolicyViolation(format!(
                "trust audit schedule {schedule_resource_id} is not active"
            )));
        }
        let expires_at = parse_datetime(required_map_str(metadata, "expiresAt")?)?;
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(format!(
                "trust audit schedule {schedule_resource_id} is expired"
            )));
        }
        let selectors = string_array_from(metadata.get("selectors"), "selectors")?;
        let scope_token = required_map_str(metadata, "scopeToken")?;
        let grant_ceiling = metadata
            .get("grantCeiling")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation("trust audit schedule missing grantCeiling".to_owned())
            })?;
        ensure_grant_ceiling_narrows_caller(self, invocation, grant_ceiling)?;
        let packages = self.packages_matching_selectors(&selectors, 500)?;
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
                scope_token,
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

pub(in crate::engine) fn trust_audit_schedule_resource_id(
    scope_token: &str,
    schedule_id: &str,
) -> String {
    format!("decision:module-trust-audit:{scope_token}:{schedule_id}")
}

fn validate_schedule_token(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty()
        || value.len() > 64
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'))
    {
        return Err(EngineError::PolicyViolation(format!(
            "invalid {label} {value:?}"
        )));
    }
    Ok(())
}

pub(in crate::engine) fn parse_trust_audit_wall_clock_time(value: &str) -> Result<(u32, u32)> {
    let Some((hour, minute)) = value.split_once(':') else {
        return Err(EngineError::PolicyViolation(
            "wallClockTime must use HH:MM".to_owned(),
        ));
    };
    let hour = hour.parse::<u32>().map_err(|_| {
        EngineError::PolicyViolation("wallClockTime hour must be numeric".to_owned())
    })?;
    let minute = minute.parse::<u32>().map_err(|_| {
        EngineError::PolicyViolation("wallClockTime minute must be numeric".to_owned())
    })?;
    if hour > 23 || minute > 59 {
        return Err(EngineError::PolicyViolation(
            "wallClockTime must be a valid 24-hour time".to_owned(),
        ));
    }
    Ok((hour, minute))
}

pub(in crate::engine) fn trust_audit_day_of_week_number(value: &str) -> Result<u32> {
    match value {
        "monday" | "mon" | "1" => Ok(1),
        "tuesday" | "tue" | "2" => Ok(2),
        "wednesday" | "wed" | "3" => Ok(3),
        "thursday" | "thu" | "4" => Ok(4),
        "friday" | "fri" | "5" => Ok(5),
        "saturday" | "sat" | "6" => Ok(6),
        "sunday" | "sun" | "7" => Ok(7),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported dayOfWeek {other}"
        ))),
    }
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
