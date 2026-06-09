//! Scoped-token and capability metadata validation for local external workers.

use super::*;

pub(super) fn validate_worker_token(hello: &WorkerHello) -> Result<()> {
    let token = &hello.worker_token;
    if token.plugin_id.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken.pluginId is required".to_owned(),
        ));
    }
    if token.namespace_claims.is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken.namespaceClaims must not be empty".to_owned(),
        ));
    }
    for claim in &hello.worker.namespace_claims {
        if !token_claims_namespace(&token.namespace_claims, claim) {
            return Err(EngineError::PolicyViolation(format!(
                "worker namespace claim {claim} exceeds scoped token claims {:?}",
                token.namespace_claims
            )));
        }
    }
    if hello.worker.authority_grant != token.authority_grant_id {
        return Err(EngineError::PolicyViolation(format!(
            "worker authority grant {} does not match scoped token grant {}",
            hello.worker.authority_grant, token.authority_grant_id
        )));
    }
    if token.authority_grant_revision == 0 || token.authority_grant_hash.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken authority grant revision and hash are required".to_owned(),
        ));
    }
    if token.resource_selectors.is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken.resourceSelectors must not be empty".to_owned(),
        ));
    }
    if visibility_rank(&hello.default_visibility) > visibility_rank(&token.visibility_ceiling) {
        return Err(EngineError::PolicyViolation(format!(
            "worker visibility {:?} exceeds token visibility ceiling {:?}",
            hello.default_visibility, token.visibility_ceiling
        )));
    }
    if let Some(expected) = token.session_id.as_deref()
        && hello.session_id.as_deref() != Some(expected)
    {
        return Err(EngineError::PolicyViolation(
            "worker sessionId does not match scoped token".to_owned(),
        ));
    }
    if let Some(expected) = token.workspace_id.as_deref()
        && hello.workspace_id.as_deref() != Some(expected)
    {
        return Err(EngineError::PolicyViolation(
            "worker workspaceId does not match scoped token".to_owned(),
        ));
    }
    if let Some(expires_at) = token.expires_at.as_deref() {
        let expires_at = chrono::DateTime::parse_from_rfc3339(expires_at)
            .map_err(|error| {
                EngineError::PolicyViolation(format!("invalid worker token expiry: {error}"))
            })?
            .with_timezone(&Utc);
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "worker scoped token is expired".to_owned(),
            ));
        }
    }
    Ok(())
}

pub(super) fn validate_external_capability_metadata(
    definition: &FunctionDefinition,
    namespace_claims: &[String],
    token: &ScopedWorkerToken,
) -> Result<()> {
    if !definition.visibility.is_agent_visible() {
        return Ok(());
    }
    if definition.request_schema.is_none() || definition.response_schema.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} requires request and response schemas",
            definition.id
        )));
    }
    let required = [
        "contractId",
        "implementationId",
        "pluginId",
        "trustTier",
        "contextPrimerLevel",
        "runtimeRequirements",
    ];
    for key in required {
        if definition.metadata.get(key).is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "external visible function {} requires capability metadata `{key}`",
                definition.id
            )));
        }
    }
    let contract_id = definition
        .metadata
        .get("contractId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let implementation_id = definition
        .metadata
        .get("implementationId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let plugin_id = definition
        .metadata
        .get("pluginId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let trust_tier = definition
        .metadata
        .get("trustTier")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if plugin_id != token.plugin_id {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} pluginId {plugin_id} does not match scoped token plugin {}",
            definition.id, token.plugin_id
        )));
    }
    if trust_tier != token.trust_tier {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} trustTier {trust_tier} does not match scoped token trust {}",
            definition.id, token.trust_tier
        )));
    }
    let contract_namespace = contract_id
        .split_once("::")
        .map(|(namespace, _)| namespace)
        .unwrap_or(contract_id);
    let claims_match = |value: &str| {
        namespace_claims.iter().any(|claim| {
            value == claim || value.starts_with(&format!("{claim}::")) || value.contains(claim)
        })
    };
    if !claims_match(definition.id.namespace())
        || !claims_match(contract_namespace)
        || !claims_match(implementation_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} metadata must stay within namespace claims {:?}",
            definition.id, namespace_claims
        )));
    }
    Ok(())
}

pub(super) fn stamp_external_capability_metadata(
    definition: &mut FunctionDefinition,
    token: &ScopedWorkerToken,
) {
    if !definition.visibility.is_agent_visible() {
        return;
    }
    let health_state = external_health_state(definition, token);
    let Some(metadata) = definition.metadata.as_object_mut() else {
        return;
    };
    metadata.insert(
        "pluginId".to_owned(),
        Value::String(token.plugin_id.clone()),
    );
    metadata.insert(
        "trustTier".to_owned(),
        Value::String(token.trust_tier.clone()),
    );
    metadata.insert(
        "signatureStatus".to_owned(),
        Value::String(token.signature_status.clone()),
    );
    metadata.insert(
        "healthState".to_owned(),
        Value::String(health_state.to_owned()),
    );
}

fn external_health_state(
    definition: &FunctionDefinition,
    token: &ScopedWorkerToken,
) -> &'static str {
    if definition.health == FunctionHealth::Healthy
        && token.trust_tier == "session_generated"
        && matches!(
            token.signature_status.as_str(),
            "session_scoped" | "engine_issued"
        )
    {
        "healthy"
    } else {
        "candidate"
    }
}

fn token_claims_namespace(claims: &[String], value: &str) -> bool {
    claims.iter().any(|claim| {
        value == claim || value.starts_with(&format!("{claim}::")) || value.contains(claim)
    })
}

fn visibility_rank(visibility: &WorkerVisibility) -> u8 {
    match visibility {
        WorkerVisibility::Session => 0,
        WorkerVisibility::Workspace => 1,
        WorkerVisibility::System => 2,
    }
}
