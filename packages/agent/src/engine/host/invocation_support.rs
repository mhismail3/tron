//! Shared invocation helpers for leases, retry policy, and panic projection.

use super::*;

pub(super) fn release_after_primary(
    release: Result<Option<EngineResourceLease>>,
    primary: Result<Value>,
) -> Result<Value> {
    match (primary, release) {
        (Ok(value), Ok(_)) => Ok(value),
        (Err(error), Ok(_)) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(release_error)) => {
            tracing::warn!(
                ?release_error,
                "resource lease release failed after engine function already failed"
            );
            Err(error)
        }
    }
}

pub(super) fn queue_retryable_delivery_failure(
    prepared: &PreparedSyncInvocation,
    handler_result: &Result<Value>,
) -> Option<EngineError> {
    match handler_result {
        Err(error @ EngineError::WorkerTransportFailure { .. })
            if !prepared.function.effect_class.is_mutating() && prepared.idempotency.is_none() =>
        {
            Some(error.clone())
        }
        _ => None,
    }
}

pub(super) fn lease_request_from_requirement(
    requirement: &ResourceLeaseRequirement,
    invocation: &Invocation,
) -> Result<AcquireResourceLease> {
    if requirement.resolver_id != "payload_template" {
        return match requirement.failure_behavior {
            ResourceLeaseFailureBehavior::FailClosed => Err(EngineError::PolicyViolation(format!(
                "unsupported resource lease resolver {} for {}",
                requirement.resolver_id, invocation.function_id
            ))),
        };
    }
    if !requirement.exclusive {
        return Err(EngineError::PolicyViolation(format!(
            "resource lease for {} must be exclusive in this engine version",
            invocation.function_id
        )));
    }
    let resource_id = render_resource_template(&requirement.resource_id_template, invocation)?;
    Ok(AcquireResourceLease {
        resource_kind: requirement.resource_kind.clone(),
        resource_id,
        holder_invocation_id: invocation.id.clone(),
        function_id: invocation.function_id.clone(),
        actor_id: invocation.causal_context.actor_id.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        trace_id: invocation.causal_context.trace_id.clone(),
        parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
        idempotency_key: invocation.causal_context.idempotency_key.clone(),
        ttl_ms: requirement.ttl_ms,
    })
}

fn render_resource_template(template: &str, invocation: &Invocation) -> Result<String> {
    let mut rendered = String::new();
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        let (prefix, after_start) = rest.split_at(start);
        rendered.push_str(prefix);
        let after_start = &after_start[1..];
        let Some(end) = after_start.find('}') else {
            return Err(EngineError::PolicyViolation(format!(
                "resource lease template {template} has an unclosed field"
            )));
        };
        let (field, after_field) = after_start.split_at(end);
        rendered.push_str(&resource_template_value(invocation, field)?);
        rest = &after_field[1..];
    }
    rendered.push_str(rest);
    if rendered.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "resource lease resolved an empty resource id".to_owned(),
        ));
    }
    Ok(rendered)
}

fn resource_template_value(invocation: &Invocation, field: &str) -> Result<String> {
    let field = field.trim();
    if field.is_empty() {
        return Err(EngineError::PolicyViolation(
            "resource lease template field must not be empty".to_owned(),
        ));
    }
    let value = if field.starts_with('/') {
        invocation
            .payload
            .pointer(field)
            .map(ValueRef::Json)
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "resource lease resolver could not find payload field {field}"
                ))
            })?
    } else {
        let payload_value = field
            .split('.')
            .try_fold(&invocation.payload, |value, segment| value.get(segment))
            .map(ValueRef::Json);
        let context_value = resource_template_context_value(invocation, field);
        select_resource_template_value(field, payload_value, context_value)?
    };
    value.into_scalar_string(field)
}

fn select_resource_template_value<'a>(
    field: &str,
    payload_value: Option<ValueRef<'a>>,
    context_value: Option<ValueRef<'a>>,
) -> Result<ValueRef<'a>> {
    match (payload_value, context_value) {
        (Some(payload), Some(context)) => {
            let payload_scalar = payload.scalar_string(field)?;
            let context_scalar = context.scalar_string(field)?;
            if payload_scalar != context_scalar {
                return Err(EngineError::PolicyViolation(format!(
                    "resource lease payload field {field} does not match invocation context"
                )));
            }
            Ok(context)
        }
        (Some(payload), None) => Ok(payload),
        (None, Some(context)) => Ok(context),
        (None, None) => Err(EngineError::PolicyViolation(format!(
            "resource lease resolver could not find payload or invocation context field {field}"
        ))),
    }
}

fn resource_template_context_value<'a>(
    invocation: &'a Invocation,
    field: &str,
) -> Option<ValueRef<'a>> {
    match field {
        "sessionId" | "session_id" => invocation
            .causal_context
            .session_id
            .as_deref()
            .map(ValueRef::BorrowedStr),
        "workspaceId" | "workspace_id" => invocation
            .causal_context
            .workspace_id
            .as_deref()
            .map(ValueRef::BorrowedStr),
        "actorId" | "actor_id" => Some(ValueRef::OwnedString(
            invocation.causal_context.actor_id.to_string(),
        )),
        "authorityGrantId" | "authority_grant_id" => Some(ValueRef::OwnedString(
            invocation.causal_context.authority_grant_id.to_string(),
        )),
        "traceId" | "trace_id" => Some(ValueRef::OwnedString(
            invocation.causal_context.trace_id.to_string(),
        )),
        "invocationId" | "invocation_id" => Some(ValueRef::OwnedString(invocation.id.to_string())),
        "parentInvocationId" | "parent_invocation_id" => invocation
            .causal_context
            .parent_invocation_id
            .as_ref()
            .map(|id| ValueRef::OwnedString(id.to_string())),
        "idempotencyKey" | "idempotency_key" => invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .map(ValueRef::BorrowedStr),
        _ => None,
    }
}

enum ValueRef<'a> {
    Json(&'a Value),
    BorrowedStr(&'a str),
    OwnedString(String),
}

impl ValueRef<'_> {
    fn into_scalar_string(self, field: &str) -> Result<String> {
        self.scalar_string(field)
    }

    fn scalar_string(&self, field: &str) -> Result<String> {
        match self {
            Self::Json(Value::String(value)) if !value.trim().is_empty() => Ok(value.clone()),
            Self::Json(Value::Number(value)) => Ok(value.to_string()),
            Self::Json(Value::Bool(value)) => Ok(value.to_string()),
            Self::BorrowedStr(value) if !value.trim().is_empty() => Ok((*value).to_owned()),
            Self::OwnedString(value) if !value.trim().is_empty() => Ok((*value).clone()),
            Self::Json(Value::String(_)) | Self::BorrowedStr(_) | Self::OwnedString(_) => {
                Err(EngineError::PolicyViolation(format!(
                    "resource lease field {field} must not be empty"
                )))
            }
            Self::Json(_) => Err(EngineError::PolicyViolation(format!(
                "resource lease field {field} must be a scalar"
            ))),
        }
    }
}

impl EngineHost {
    pub(super) fn acquire_resource_lease_for_invocation(
        &mut self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<Option<EngineResourceLease>> {
        let Some(requirement) = &function.resource_lease else {
            return Ok(None);
        };
        let request = lease_request_from_requirement(requirement, invocation)?;
        let lease = {
            self.primitives
                .leases
                .lock()
                .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
                .acquire(request)?
        };
        let _ = self.publish_stream_event_sync(PublishStreamEvent {
            topic: "resource.leases".to_owned(),
            payload: json!({
                "type": "resource_lease.acquired",
                "lease": lease.clone(),
            }),
            visibility: VisibilityScope::System,
            session_id: None,
            workspace_id: None,
            producer: "resource_lease".to_owned(),
            trace_id: Some(lease.trace_id.clone()),
            parent_invocation_id: Some(lease.holder_invocation_id.clone()),
        });
        Ok(Some(lease))
    }

    pub(super) fn release_resource_lease_sync(
        &mut self,
        lease_id: &str,
    ) -> Result<Option<EngineResourceLease>> {
        let lease = {
            self.primitives
                .leases
                .lock()
                .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
                .release(lease_id)?
        };
        if let Some(lease) = lease.as_ref() {
            let _ = self.publish_stream_event_sync(PublishStreamEvent {
                topic: "resource.leases".to_owned(),
                payload: json!({
                    "type": "resource_lease.released",
                    "lease": lease,
                }),
                visibility: VisibilityScope::System,
                session_id: None,
                workspace_id: None,
                producer: "resource_lease".to_owned(),
                trace_id: Some(lease.trace_id.clone()),
                parent_invocation_id: Some(lease.holder_invocation_id.clone()),
            });
        }
        Ok(lease)
    }

    pub(super) fn record_compensation_for_result_sync(
        &mut self,
        invocation: &Invocation,
        contract: Option<CompensationContract>,
        result: &InvocationResult,
        resource_lease_ids: Vec<String>,
    ) -> Option<EngineCompensationRecord> {
        let Some(contract) = contract else {
            return None;
        };
        let record = compensation_record(invocation, result, contract, resource_lease_ids);
        let stored = self
            .primitives
            .compensation
            .lock()
            .map_err(|_| EngineError::HandlerFailed("compensation store lock poisoned".to_owned()))
            .and_then(|mut store| store.record(record));
        match stored {
            Ok(record) => {
                let _ = self.publish_stream_event_sync(PublishStreamEvent {
                    topic: "compensation.records".to_owned(),
                    payload: json!({
                        "type": "compensation.recorded",
                        "compensation": record.clone(),
                    }),
                    visibility: VisibilityScope::System,
                    session_id: None,
                    workspace_id: None,
                    producer: "compensation".to_owned(),
                    trace_id: Some(result.trace_id.clone()),
                    parent_invocation_id: Some(result.invocation_id.clone()),
                });
                Some(record)
            }
            Err(error) => {
                tracing::error!(?error, "failed to record engine compensation contract");
                None
            }
        }
    }

    fn publish_stream_event_sync(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        self.primitives
            .streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .publish(event)
    }
}

pub(super) fn panic_payload_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&'static str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string panic payload".to_owned()
    }
}
