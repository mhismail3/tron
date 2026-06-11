//! Governed worker activation primitive implementation.

use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::WORKER_WORKER_ID;
use crate::engine::authority::grants::grant_policy_hash;
use crate::engine::durability::resources::{CreateResource, EngineResourceScope};
use crate::engine::kernel::ids::{ActorId, AuthorityGrantId, FunctionId, WorkerId};
use crate::engine::kernel::types::{
    FunctionDefinition, Provenance, VisibilityScope, WorkerDefinition, WorkerKind,
};
use crate::engine::primitives::runtime::{PrimitiveRuntimeHost, actor_context};
use crate::engine::runtime::worker_protocol::{
    ScopedWorkerToken, WORKER_PROTOCOL_VERSION, WorkerAuthPolicy, WorkerHello, WorkerIdentity,
    WorkerRegistrationMode, WorkerVisibility,
};
use crate::engine::{DeriveGrant, EngineError, Result, RiskLevel};

use super::worker_activation_governance::validate_activation_governance;

const WORKER_ACTIVATION_KIND: &str = "worker_activation";
const WORKER_ACTIVATION_SCHEMA_ID: &str = "tron.resource.worker_activation.v1";
const ACTIVATION_MAX_TTL_HOURS: i64 = 24;

pub(super) fn issue_activation_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "functionId",
            "candidateResourceId",
            "decisionResourceId",
            "evidenceResourceIds",
            "targetVisibility",
            "activationReason",
            "idempotencyKey"
        ],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string", "minLength": 1},
            "candidateResourceId": {"type": "string", "minLength": 1},
            "decisionResourceId": {"type": "string", "minLength": 1},
            "evidenceResourceIds": {"type": "array", "minItems": 1, "items": {"type": "string", "minLength": 1}},
            "targetVisibility": {"type": "string", "enum": ["session", "workspace"]},
            "workspaceId": {"type": "string", "minLength": 1},
            "activationReason": {"type": "string", "minLength": 1},
            "expiresAt": {"type": "string"},
            "idempotencyKey": {"type": "string", "minLength": 1}
        }
    })
}

pub(in crate::engine::primitives) fn issue_activation(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    ensure_activation_idempotency(invocation)?;
    let request = WorkerActivationRequest::from_invocation(invocation)?;
    let governance = validate_activation_governance(host, invocation, &request)?;
    let worker_id = worker_id_for_activation(&request, &governance.governance_fingerprint)?;
    let worker_actor = ActorId::new(format!("worker:{worker_id}"))?;
    let expires_at = request.expires_at;
    let grant_id = AuthorityGrantId::new(format!(
        "worker-activation-grant:{}",
        short_fingerprint(&request.fingerprint_seed())
    ))?;
    let grant = host.derive_authority_grant(DeriveGrant {
        grant_id: Some(grant_id),
        parent_grant_id: AuthorityGrantId::new("worker-runtime")?,
        subject_actor_id: Some(worker_actor.clone()),
        subject_worker_id: Some(worker_id.clone()),
        subject_invocation_id: None,
        allowed_capabilities: vec![
            request.function_id.as_str().to_owned(),
            "stream::publish".to_owned(),
        ],
        allowed_namespaces: vec![request.function_id.namespace().to_owned()],
        allowed_authority_scopes: activation_authority_scopes(&governance.expected_function),
        allowed_resource_kinds: vec![WORKER_ACTIVATION_KIND.to_owned()],
        resource_selectors: vec![format!("stream:{}:*", request.function_id.namespace())],
        file_roots: vec!["/".to_owned()],
        network_policy: "loopback".to_owned(),
        max_risk: std::cmp::max(governance.expected_function.risk_level, RiskLevel::Medium),
        budget: json!({"class": "worker_activation"}),
        expires_at: Some(expires_at),
        can_delegate: false,
        provenance: json!({
            "source": "worker::issue_activation",
            "activationReason": request.activation_reason,
            "decisionResourceId": request.decision_resource_id,
            "evidenceResourceIds": request.evidence_resource_ids,
            "candidateResourceId": request.candidate_resource_id,
            "governanceFingerprint": governance.governance_fingerprint,
        }),
        trace_id: invocation.causal_context.trace_id.clone(),
    })?;

    let mut expected_function = governance.expected_function;
    expected_function.owner_worker = worker_id.clone();
    expected_function.visibility = request.target_visibility.clone();
    expected_function.provenance = scoped_provenance(
        worker_actor.clone(),
        request.target_visibility.clone(),
        request.session_id.clone(),
        request.workspace_id.clone(),
    )?;
    ensure_activation_function_metadata(&mut expected_function, &worker_id);
    let worker = scoped_worker_definition(
        &worker_id,
        worker_actor,
        grant.grant_id.clone(),
        request.target_visibility.clone(),
        request.session_id.clone(),
        request.workspace_id.clone(),
        request.function_id.namespace(),
    )?;
    let token = activation_worker_token(
        &worker,
        &grant,
        &expected_function,
        &request,
        &governance.governance_fingerprint,
    )?;
    let token_fingerprint = fingerprint_json(&token)?;
    let activation_resource_id = format!(
        "worker_activation:{}",
        short_fingerprint(&format!(
            "{}:{}:{}",
            request.fingerprint_seed(),
            grant.grant_id,
            token_fingerprint
        ))
    );
    let mut token = token;
    token.activation_resource_id = Some(activation_resource_id.clone());
    let token_fingerprint = fingerprint_json(&token)?;
    let hello = activation_hello(
        worker,
        token.clone(),
        request.target_visibility.clone(),
        request.session_id.clone(),
        request.workspace_id.clone(),
    )?;
    let activation_payload = activation_payload(
        "issued",
        &request,
        &worker_id,
        &grant,
        &token_fingerprint,
        &governance.governance_fingerprint,
        &expected_function,
    )?;
    host.create_resource(CreateResource {
        resource_id: Some(activation_resource_id.clone()),
        kind: WORKER_ACTIVATION_KIND.to_owned(),
        schema_id: Some(WORKER_ACTIVATION_SCHEMA_ID.to_owned()),
        scope: activation_resource_scope(&request)?,
        owner_worker_id: WorkerId::new(WORKER_WORKER_ID)?,
        owner_actor_id: invocation.causal_context.actor_id.clone(),
        lifecycle: Some("issued".to_owned()),
        policy: json!({
            "tokenStorage": "redacted_fingerprint_only",
            "networkPolicy": "loopback",
            "registrationMode": "volatile"
        }),
        initial_payload: Some(activation_payload),
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;

    Ok(json!({
        "activationResourceId": activation_resource_id,
        "workerId": worker_id,
        "expiresAt": expires_at.to_rfc3339(),
        "activationBundle": {
            "workerHello": hello,
            "scopedWorkerToken": token,
            "expectedFunctionDefinition": expected_function,
        }
    }))
}

pub(super) struct WorkerActivationRequest {
    pub(super) function_id: FunctionId,
    pub(super) candidate_resource_id: String,
    pub(super) decision_resource_id: String,
    pub(super) evidence_resource_ids: Vec<String>,
    pub(super) target_visibility: VisibilityScope,
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
    pub(super) activation_reason: String,
    pub(super) expires_at: DateTime<Utc>,
    pub(super) idempotency_key: String,
}

impl WorkerActivationRequest {
    fn from_invocation(invocation: &crate::engine::Invocation) -> Result<Self> {
        let function_id =
            FunctionId::new(required_payload_str(&invocation.payload, "functionId")?)?;
        let candidate_resource_id =
            non_empty_payload_string(&invocation.payload, "candidateResourceId")?;
        let decision_resource_id =
            non_empty_payload_string(&invocation.payload, "decisionResourceId")?;
        let evidence_resource_ids =
            non_empty_string_array(&invocation.payload, "evidenceResourceIds")?;
        ensure_unique("evidenceResourceIds", &evidence_resource_ids)?;
        let target_visibility = match required_payload_str(&invocation.payload, "targetVisibility")?
        {
            "session" => VisibilityScope::Session,
            "workspace" => VisibilityScope::Workspace,
            other => {
                return Err(EngineError::PolicyViolation(format!(
                    "worker activation does not support target visibility {other}"
                )));
            }
        };
        let activation_reason = non_empty_payload_string(&invocation.payload, "activationReason")?;
        let idempotency_key = non_empty_payload_string(&invocation.payload, "idempotencyKey")?;
        let actor = actor_context(&invocation.causal_context);
        let requested_workspace_id = optional_payload_string(&invocation.payload, "workspaceId")?;
        let workspace_id = match target_visibility {
            VisibilityScope::Workspace => {
                requested_workspace_id.or_else(|| invocation.causal_context.workspace_id.clone())
            }
            VisibilityScope::Session => requested_workspace_id,
            _ => None,
        };
        let session_id = invocation.causal_context.session_id.clone();
        match target_visibility {
            VisibilityScope::Session => {
                if session_id.as_deref().is_none_or(str::is_empty) {
                    return Err(EngineError::PolicyViolation(
                        "session worker activation requires invocation sessionId".to_owned(),
                    ));
                }
            }
            VisibilityScope::Workspace => {
                let workspace = workspace_id.as_deref().ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace worker activation requires workspaceId".to_owned(),
                    )
                })?;
                if !actor.actor_kind.is_admin_like()
                    && invocation.causal_context.workspace_id.as_deref() != Some(workspace)
                {
                    return Err(EngineError::PolicyViolation(
                        "workspace worker activation requires matching workspace authority"
                            .to_owned(),
                    ));
                }
            }
            _ => unreachable!("activation target visibility is narrowed above"),
        }
        let expires_at = activation_expiry(&invocation.payload)?;
        Ok(Self {
            function_id,
            candidate_resource_id,
            decision_resource_id,
            evidence_resource_ids,
            target_visibility,
            session_id,
            workspace_id,
            activation_reason,
            expires_at,
            idempotency_key,
        })
    }

    fn fingerprint_seed(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}",
            self.function_id,
            self.candidate_resource_id,
            self.decision_resource_id,
            self.target_visibility.as_str(),
            self.idempotency_key
        )
    }
}

fn ensure_activation_idempotency(invocation: &crate::engine::Invocation) -> Result<()> {
    let payload_key = required_payload_str(&invocation.payload, "idempotencyKey")?;
    if payload_key.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "worker::issue_activation requires non-empty idempotencyKey".to_owned(),
        ));
    }
    match invocation.causal_context.idempotency_key.as_deref() {
        Some(context_key) if context_key == payload_key => Ok(()),
        _ => Err(EngineError::PolicyViolation(
            "worker::issue_activation idempotencyKey must match causal context".to_owned(),
        )),
    }
}

fn activation_expiry(payload: &Value) -> Result<DateTime<Utc>> {
    let now = Utc::now();
    let max = now + Duration::hours(ACTIVATION_MAX_TTL_HOURS);
    let expires_at = match optional_payload_string(payload, "expiresAt")? {
        Some(raw) => DateTime::parse_from_rfc3339(&raw)
            .map_err(|error| EngineError::PolicyViolation(format!("invalid expiresAt: {error}")))?
            .with_timezone(&Utc),
        None => max,
    };
    if expires_at <= now {
        return Err(EngineError::PolicyViolation(
            "worker activation expiresAt must be in the future".to_owned(),
        ));
    }
    if expires_at > max {
        return Err(EngineError::PolicyViolation(format!(
            "worker activation expiresAt cannot exceed {ACTIVATION_MAX_TTL_HOURS}h"
        )));
    }
    Ok(expires_at)
}

fn scoped_provenance(
    created_by: ActorId,
    target: VisibilityScope,
    session_id: Option<String>,
    workspace_id: Option<String>,
) -> Result<Provenance> {
    let provenance = Provenance::new(created_by, "worker_activation");
    match target {
        VisibilityScope::Session => {
            Ok(provenance.with_session_id(session_id.ok_or_else(|| {
                EngineError::PolicyViolation("session activation requires sessionId".to_owned())
            })?))
        }
        VisibilityScope::Workspace => {
            Ok(provenance.with_workspace_id(workspace_id.ok_or_else(|| {
                EngineError::PolicyViolation("workspace activation requires workspaceId".to_owned())
            })?))
        }
        _ => Err(EngineError::PolicyViolation(
            "worker activation only supports session or workspace visibility".to_owned(),
        )),
    }
}

fn scoped_worker_definition(
    worker_id: &WorkerId,
    owner_actor: ActorId,
    grant_id: AuthorityGrantId,
    target: VisibilityScope,
    session_id: Option<String>,
    workspace_id: Option<String>,
    namespace: &str,
) -> Result<WorkerDefinition> {
    let mut worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        owner_actor.clone(),
        grant_id,
    )
    .with_namespace_claim(namespace);
    worker.visibility = target.clone();
    worker.provenance = scoped_provenance(owner_actor, target, session_id, workspace_id)?;
    Ok(worker)
}

fn activation_worker_token(
    worker: &WorkerDefinition,
    grant: &crate::engine::EngineGrant,
    expected_function: &FunctionDefinition,
    request: &WorkerActivationRequest,
    governance_fingerprint: &str,
) -> Result<ScopedWorkerToken> {
    let metadata = &expected_function.metadata;
    let plugin_id = metadata
        .get("pluginId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("session_generated.{}", worker.id.as_str()));
    let trust_tier = metadata
        .get("trustTier")
        .and_then(Value::as_str)
        .unwrap_or("session_generated")
        .to_owned();
    let signature_status = metadata
        .get("signatureStatus")
        .and_then(Value::as_str)
        .unwrap_or("engine_issued")
        .to_owned();
    Ok(ScopedWorkerToken {
        plugin_id,
        namespace_claims: worker.namespace_claims.clone(),
        authority_grant_id: grant.grant_id.clone(),
        authority_grant_revision: grant.revision,
        authority_grant_hash: grant_policy_hash(grant),
        resource_selectors: grant.resource_selectors.clone(),
        visibility_ceiling: worker_visibility(&request.target_visibility)?,
        trust_tier,
        session_id: request.session_id.clone(),
        workspace_id: request.workspace_id.clone(),
        expires_at: Some(request.expires_at.to_rfc3339()),
        signature_status,
        activation_resource_id: None,
        governance_fingerprint: Some(governance_fingerprint.to_owned()),
    })
}

fn activation_hello(
    worker: WorkerDefinition,
    worker_token: ScopedWorkerToken,
    target: VisibilityScope,
    session_id: Option<String>,
    workspace_id: Option<String>,
) -> Result<WorkerHello> {
    Ok(WorkerHello {
        protocol_version: WORKER_PROTOCOL_VERSION,
        identity: WorkerIdentity::from_worker(&worker),
        worker,
        loopback_only: true,
        auth_policy: WorkerAuthPolicy::LoopbackBearer,
        registration_mode: WorkerRegistrationMode::Volatile,
        default_visibility: worker_visibility(&target)?,
        session_id,
        workspace_id,
        heartbeat_interval_ms: 15_000,
        supported_capabilities: Vec::new(),
        worker_token,
    })
}

fn worker_visibility(target: &VisibilityScope) -> Result<WorkerVisibility> {
    match target {
        VisibilityScope::Session => Ok(WorkerVisibility::Session),
        VisibilityScope::Workspace => Ok(WorkerVisibility::Workspace),
        _ => Err(EngineError::PolicyViolation(
            "worker activation only supports session or workspace visibility".to_owned(),
        )),
    }
}

fn ensure_activation_function_metadata(function: &mut FunctionDefinition, worker_id: &WorkerId) {
    let namespace = function.id.namespace().to_owned();
    let local_name = function
        .id
        .as_str()
        .split_once("::")
        .map(|(_, local)| local)
        .unwrap_or(function.id.as_str());
    let Some(metadata) = function.metadata.as_object_mut() else {
        function.metadata = json!({});
        return ensure_activation_function_metadata(function, worker_id);
    };
    metadata
        .entry("contractId")
        .or_insert_with(|| Value::String(function.id.as_str().to_owned()));
    metadata
        .entry("implementationId")
        .or_insert_with(|| Value::String(format!("session_generated.{namespace}.{local_name}")));
    metadata
        .entry("pluginId")
        .or_insert_with(|| Value::String(format!("session_generated.{worker_id}")));
    metadata
        .entry("trustTier")
        .or_insert_with(|| Value::String("session_generated".to_owned()));
    metadata
        .entry("signatureStatus")
        .or_insert_with(|| Value::String("engine_issued".to_owned()));
    metadata
        .entry("contextPrimerLevel")
        .or_insert_with(|| Value::String("catalog".to_owned()));
    let runtime_requirements = metadata
        .entry("runtimeRequirements")
        .or_insert_with(|| json!({}));
    if let Some(runtime_requirements) = runtime_requirements.as_object_mut() {
        runtime_requirements.insert("workerKind".to_owned(), json!("external"));
        runtime_requirements.insert("registrationMode".to_owned(), json!("volatile"));
        runtime_requirements.insert("networkPolicy".to_owned(), json!("loopback"));
    } else {
        *runtime_requirements = json!({
            "workerKind": "external",
            "registrationMode": "volatile",
            "networkPolicy": "loopback"
        });
    }
}

fn activation_payload(
    status: &str,
    request: &WorkerActivationRequest,
    worker_id: &WorkerId,
    grant: &crate::engine::EngineGrant,
    token_fingerprint: &str,
    governance_fingerprint: &str,
    expected_function: &FunctionDefinition,
) -> Result<Value> {
    Ok(json!({
        "status": status,
        "functionId": request.function_id.as_str(),
        "workerId": worker_id.as_str(),
        "candidateResourceId": request.candidate_resource_id,
        "decisionResourceId": request.decision_resource_id,
        "evidenceResourceIds": request.evidence_resource_ids,
        "targetVisibility": request.target_visibility.as_str(),
        "scope": {
            "sessionId": request.session_id,
            "workspaceId": request.workspace_id,
        },
        "activationReason": request.activation_reason,
        "expiresAt": request.expires_at.to_rfc3339(),
        "grantId": grant.grant_id.as_str(),
        "tokenFingerprint": token_fingerprint,
        "governanceFingerprint": governance_fingerprint,
        "expectedFunctionDefinition": expected_function,
        "registrationMode": "volatile",
        "networkPolicy": "loopback",
        "tokenStorage": {
            "redacted": true,
            "fingerprint": token_fingerprint,
            "authorityGrantId": grant.grant_id.as_str(),
            "authorityGrantRevision": grant.revision
        },
        "metadata": {
            "issuedBy": "worker::issue_activation",
            "maxTtlHours": ACTIVATION_MAX_TTL_HOURS
        }
    }))
}

fn activation_resource_scope(request: &WorkerActivationRequest) -> Result<EngineResourceScope> {
    match request.target_visibility {
        VisibilityScope::Session => Ok(EngineResourceScope::Session(
            request.session_id.clone().ok_or_else(|| {
                EngineError::PolicyViolation("session activation requires sessionId".to_owned())
            })?,
        )),
        VisibilityScope::Workspace => Ok(EngineResourceScope::Workspace(
            request.workspace_id.clone().ok_or_else(|| {
                EngineError::PolicyViolation("workspace activation requires workspaceId".to_owned())
            })?,
        )),
        _ => Err(EngineError::PolicyViolation(
            "worker activation only supports session or workspace visibility".to_owned(),
        )),
    }
}

fn activation_authority_scopes(function: &FunctionDefinition) -> Vec<String> {
    let mut scopes = function.required_authority.scopes.clone();
    scopes.push("stream.write".to_owned());
    scopes.sort();
    scopes.dedup();
    if scopes.is_empty() {
        scopes.push("stream.write".to_owned());
    }
    scopes
}

fn worker_id_for_activation(
    request: &WorkerActivationRequest,
    governance_fingerprint: &str,
) -> Result<WorkerId> {
    WorkerId::new(format!(
        "worker-activation:{}",
        short_fingerprint(&format!(
            "{}:{governance_fingerprint}",
            request.fingerprint_seed()
        ))
    ))
}

pub(super) fn fingerprint_json<T: serde::Serialize>(value: &T) -> Result<String> {
    let bytes = serde_json::to_vec(value).map_err(|error| {
        EngineError::PolicyViolation(format!("failed to fingerprint activation payload: {error}"))
    })?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn short_fingerprint(value: &str) -> String {
    let hash = hex::encode(Sha256::digest(value.as_bytes()));
    hash.chars().take(16).collect()
}

fn required_payload_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn non_empty_payload_string(payload: &Value, field: &str) -> Result<String> {
    let value = required_payload_str(payload, field)?;
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        )));
    }
    Ok(value.to_owned())
}

fn optional_payload_string(payload: &Value, field: &str) -> Result<Option<String>> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        ))),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "{field} must be a string, got {other}"
        ))),
    }
}

fn non_empty_string_array(payload: &Value, field: &str) -> Result<Vec<String>> {
    let items = payload
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::PolicyViolation(format!("{field} must be an array")))?;
    if items.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must contain at least one resource id"
        )));
    }
    items
        .iter()
        .map(|item| {
            let Some(value) = item.as_str() else {
                return Err(EngineError::PolicyViolation(format!(
                    "{field} entries must be strings"
                )));
            };
            if value.trim().is_empty() {
                return Err(EngineError::PolicyViolation(format!(
                    "{field} entries must be non-empty"
                )));
            }
            Ok(value.to_owned())
        })
        .collect()
}

fn ensure_unique(field: &str, values: &[String]) -> Result<()> {
    let mut seen = std::collections::BTreeSet::new();
    for value in values {
        if !seen.insert(value) {
            return Err(EngineError::PolicyViolation(format!(
                "{field} contains duplicate value {value}"
            )));
        }
    }
    Ok(())
}
