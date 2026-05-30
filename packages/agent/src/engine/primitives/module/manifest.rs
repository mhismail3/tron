//! Module package manifest validation and runtime entrypoint parsing.
//!
//! Worker package manifests are the canonical package boundary for module
//! activation. This submodule owns manifest normalization, digest validation,
//! declared-capability comparison, and local-process runtime parsing so the
//! lifecycle root can orchestrate resources and grants without also owning
//! package grammar.

use super::*;

pub(super) enum RuntimeEntryPoint {
    ExistingOrBuiltin,
    LocalProcess(Box<LocalProcessRuntime>),
}

pub(super) struct LocalProcessRuntime {
    pub(super) worker_id: String,
    pub(super) command_ref: ResourceVersionRef,
    pub(super) executable_refs: Vec<ResourceVersionRef>,
    pub(super) expected_function_ids: Vec<String>,
    pub(super) args: Vec<String>,
    pub(super) visibility: String,
    pub(super) timeout_ms: Option<u64>,
    pub(super) environment_policy: Value,
}

#[derive(Clone)]
pub(super) struct ResourceVersionRef {
    pub(super) resource_id: String,
    pub(super) version_id: String,
    pub(super) content_hash: Option<String>,
}

pub(super) struct DeclaredCapability {
    pub(super) raw: Value,
    pub(super) function_id: FunctionId,
    pub(super) effect: EffectClass,
    pub(super) risk: RiskLevel,
    pub(super) required_authority: Vec<String>,
    pub(super) output_resource_kinds: Vec<String>,
}

pub(super) fn validate_manifest(manifest: &Value) -> Result<()> {
    for field in [
        "packageId",
        "version",
        "manifestSchemaId",
        "sourceProvenance",
        "packageDigest",
        "trustTier",
        "signatureStatus",
        "declaredWorkerKind",
        "namespace",
        "declaredCapabilities",
        "requiredGrants",
        "configSchema",
        "runtimeEntryPoint",
        "healthPolicy",
        "sandboxProcessPolicy",
        "redactionPolicy",
    ] {
        if manifest.get(field).is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "worker_package manifest missing {field}"
            )));
        }
    }
    if required_value_str(manifest, "manifestSchemaId")? != MANIFEST_SCHEMA_ID {
        return Err(EngineError::PolicyViolation(format!(
            "worker_package manifestSchemaId must be {MANIFEST_SCHEMA_ID}"
        )));
    }
    let provenance = required_object(manifest.get("sourceProvenance"), "sourceProvenance")?;
    match provenance.get("kind").and_then(Value::as_str) {
        Some(BUILTIN_PROVENANCE) => {}
        Some(LOCAL_DIGEST_PINNED) => {
            let files = manifest
                .get("declaredFiles")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "local_digest_pinned packages require declaredFiles resource refs"
                            .to_owned(),
                    )
                })?;
            if files.is_empty() {
                return Err(EngineError::PolicyViolation(
                    "local_digest_pinned packages require at least one declared file ref"
                        .to_owned(),
                ));
            }
            for file in files {
                for field in ["resourceId", "versionId", "contentHash"] {
                    let _ = file.get(field).and_then(Value::as_str).ok_or_else(|| {
                        EngineError::PolicyViolation(format!(
                            "declaredFiles entries require {field}"
                        ))
                    })?;
                }
            }
        }
        Some(other) => {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported package provenance {other}"
            )));
        }
        None => {
            return Err(EngineError::PolicyViolation(
                "package sourceProvenance requires kind".to_owned(),
            ));
        }
    }
    let digest = required_value_str(manifest, "packageDigest")?;
    let computed = manifest_digest(manifest)?;
    if digest != computed {
        return Err(EngineError::PolicyViolation(format!(
            "packageDigest mismatch: expected {computed}, got {digest}"
        )));
    }
    let namespace = required_value_str(manifest, "namespace")?;
    validate_namespace(namespace)?;
    let declared = declared_capabilities(manifest)?;
    validate_manifest_runtime(manifest, &declared)?;
    let grants = required_object(manifest.get("requiredGrants"), "requiredGrants")?;
    for field in [
        "allowedCapabilities",
        "allowedNamespaces",
        "allowedAuthorityScopes",
        "allowedResourceKinds",
        "resourceSelectors",
        "fileRoots",
    ] {
        let values = string_array_from(grants.get(field), field)?;
        if values.is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "requiredGrants.{field} must not be empty"
            )));
        }
    }
    let _ = parse_risk(required_map_str(grants, "maxRisk")?)?;
    let _ = required_map_str(grants, "networkPolicy")?;
    schema::validate_schema_definition(
        &FunctionId::new(CONFIGURE_FUNCTION)?,
        "module_config_schema",
        manifest.get("configSchema").unwrap(),
    )?;
    reject_raw_secrets(manifest)?;
    reject_raw_secrets(manifest.get("redactionPolicy").unwrap())?;
    Ok(())
}

pub(super) fn normalize_package_manifest(mut manifest: Value) -> Result<Value> {
    let digest = required_value_str(&manifest, "packageDigest")?.to_owned();
    let provenance = manifest
        .get("sourceProvenance")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let kind = source_kind(&manifest)?;
    let (source_status, effective_trust, signature_verification) = match kind.as_str() {
        BUILTIN_PROVENANCE => (
            SOURCE_STATUS_TRUSTED_BUILTIN,
            BUILTIN_PROVENANCE,
            json!({"status": SOURCE_STATUS_TRUSTED_BUILTIN}),
        ),
        LOCAL_DIGEST_PINNED => (
            SOURCE_STATUS_UNVERIFIED,
            "untrusted",
            json!({"status": "not_verified"}),
        ),
        _ => unreachable!("validate_manifest rejects unsupported provenance"),
    };
    manifest["sourceRef"] = json!({"provenance": provenance});
    manifest["sourceDigest"] = json!(digest);
    manifest["sourceTrustStatus"] = json!(source_status);
    manifest["effectiveTrustTier"] = json!(effective_trust);
    if manifest.get("signature").is_none() {
        manifest["signature"] = Value::Null;
    }
    if manifest.get("signatureKeyRef").is_none() {
        manifest["signatureKeyRef"] = Value::Null;
    }
    manifest["signatureVerification"] = signature_verification;
    manifest["sourceEvidenceRefs"] = json!([]);
    manifest["sourceApprovalRefs"] = json!([]);
    manifest["conformanceEvidenceRefs"] = json!([]);
    manifest["policyDiagnostics"] = json!({
        "source": {"status": source_status},
        "conformance": {"status": "not_required"},
    });
    Ok(manifest)
}

pub(super) fn source_kind(manifest: &Value) -> Result<String> {
    required_object(manifest.get("sourceProvenance"), "sourceProvenance")?
        .get("kind")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            EngineError::PolicyViolation("package sourceProvenance requires kind".to_owned())
        })
}

pub(super) fn package_has_signature(manifest: &Value) -> bool {
    manifest
        .get("signature")
        .is_some_and(|value| !value.is_null())
        || manifest
            .get("signatureKeyRef")
            .is_some_and(|value| !value.is_null())
}

pub(super) fn package_selector_matches(
    selectors: &[String],
    manifest: &Value,
    package_resource_id: &str,
) -> Result<bool> {
    let package_id = required_value_str(manifest, "packageId")?;
    let namespace = required_value_str(manifest, "namespace")?;
    Ok(selectors.iter().any(|selector| {
        selector == "*"
            || selector == package_id
            || selector == package_resource_id
            || selector == &format!("namespace:{namespace}")
            || selector == &format!("{namespace}/*")
    }))
}

pub(super) fn declared_capabilities(manifest: &Value) -> Result<Vec<DeclaredCapability>> {
    let namespace = required_value_str(manifest, "namespace")?;
    let capabilities = manifest
        .get("declaredCapabilities")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            EngineError::PolicyViolation(
                "worker_package declaredCapabilities must be an array".to_owned(),
            )
        })?;
    if capabilities.is_empty() {
        return Err(EngineError::PolicyViolation(
            "worker_package must declare at least one capability".to_owned(),
        ));
    }
    let mut seen_function_ids = BTreeSet::new();
    let mut declared = Vec::new();
    for capability in capabilities {
        let function_id = FunctionId::new(required_value_str(capability, "functionId")?)?;
        if !seen_function_ids.insert(function_id.clone()) {
            return Err(EngineError::PolicyViolation(format!(
                "worker_package declaredCapabilities contains duplicate functionId {function_id}"
            )));
        }
        if function_id.namespace() != namespace {
            return Err(EngineError::PolicyViolation(format!(
                "declared capability {} exceeds package namespace {namespace}",
                function_id
            )));
        }
        let effect = parse_effect(required_value_str(capability, "effectClass")?)?;
        let risk = parse_risk(required_value_str(capability, "risk")?)?;
        let required_authority =
            string_array_from(capability.get("requiredAuthority"), "requiredAuthority")?;
        let output_resource_kinds =
            string_array_from(capability.get("outputResourceKinds"), "outputResourceKinds")?;
        if effect.requires_idempotency()
            && !capability
                .get("idempotent")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        {
            return Err(EngineError::PolicyViolation(format!(
                "declared mutating capability {} requires idempotency",
                function_id
            )));
        }
        if effect.requires_idempotency() && output_resource_kinds.is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "declared mutating capability {} requires an output resource contract",
                function_id
            )));
        }
        declared.push(DeclaredCapability {
            raw: capability.clone(),
            function_id,
            effect,
            risk,
            required_authority,
            output_resource_kinds,
        });
    }
    Ok(declared)
}

pub(super) async fn registered_capabilities_for_worker(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    worker_id: &WorkerId,
    namespace: &str,
) -> Result<Vec<FunctionDefinition>> {
    let actor = ActorContext {
        actor_id: invocation.causal_context.actor_id.clone(),
        actor_kind: ActorKind::System,
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        authority_scopes: Vec::new(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    };
    Ok(host
        .discover_functions(&FunctionQuery {
            actor: Some(actor),
            include_internal: true,
            ..FunctionQuery::default()
        })
        .await
        .into_iter()
        .filter(|function| {
            &function.owner_worker == worker_id && function.id.namespace() == namespace
        })
        .collect())
}

pub(super) fn validate_registered_capabilities(
    declared: &[DeclaredCapability],
    registered: &[FunctionDefinition],
) -> Result<()> {
    for function in registered {
        let Some(declared) = declared
            .iter()
            .find(|declared| declared.function_id == function.id)
        else {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} is not declared by package",
                function.id
            )));
        };
        if function.effect_class != declared.effect {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} effect exceeds package manifest",
                function.id
            )));
        }
        if function.risk_level > declared.risk {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} risk exceeds package manifest",
                function.id
            )));
        }
        for scope in &function.required_authority.scopes {
            if !declared
                .required_authority
                .iter()
                .any(|allowed| allowed == scope)
            {
                return Err(EngineError::PolicyViolation(format!(
                    "registered capability {} authority exceeds package manifest",
                    function.id
                )));
            }
        }
        if function.effect_class.requires_idempotency() && function.idempotency.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} is mutating without idempotency",
                function.id
            )));
        }
        if !declared.output_resource_kinds.is_empty() {
            let DurableOutputContract::ResourceBacked {
                produced_resource_kinds,
                ..
            } = &function.output_contract
            else {
                return Err(EngineError::PolicyViolation(format!(
                    "registered capability {} lacks resource-backed output contract",
                    function.id
                )));
            };
            for kind in &declared.output_resource_kinds {
                if !produced_resource_kinds
                    .iter()
                    .any(|candidate| candidate == kind)
                {
                    return Err(EngineError::PolicyViolation(format!(
                        "registered capability {} output kinds exceed package manifest",
                        function.id
                    )));
                }
            }
        }
    }
    for declared in declared {
        if !registered
            .iter()
            .any(|function| function.id == declared.function_id)
        {
            return Err(EngineError::PolicyViolation(format!(
                "declared capability {} was not registered by worker",
                declared.function_id
            )));
        }
    }
    Ok(())
}

fn validate_manifest_runtime(manifest: &Value, declared: &[DeclaredCapability]) -> Result<()> {
    let entry = required_object(manifest.get("runtimeEntryPoint"), "runtimeEntryPoint")?;
    let worker_id = required_map_str(entry, "workerId")?;
    let _ = validate_runtime_entrypoint_with_declared(manifest, worker_id, declared)?;
    Ok(())
}

pub(super) fn validate_runtime_entrypoint(
    manifest: &Value,
    worker_id: &str,
) -> Result<RuntimeEntryPoint> {
    let declared = declared_capabilities(manifest)?;
    validate_runtime_entrypoint_with_declared(manifest, worker_id, &declared)
}

fn validate_runtime_entrypoint_with_declared(
    manifest: &Value,
    worker_id: &str,
    declared: &[DeclaredCapability],
) -> Result<RuntimeEntryPoint> {
    let entry = required_object(manifest.get("runtimeEntryPoint"), "runtimeEntryPoint")?;
    let kind = entry.get("kind").and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation("runtimeEntryPoint requires kind".to_owned())
    })?;
    if entry
        .get("workerId")
        .and_then(Value::as_str)
        .is_some_and(|declared| declared != worker_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "activation workerId {worker_id} does not match manifest runtimeEntryPoint"
        )));
    }
    match kind {
        "existing_worker" | "builtin" => Ok(RuntimeEntryPoint::ExistingOrBuiltin),
        "local_process" => parse_local_process_runtime(manifest, entry, declared),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported runtimeEntryPoint kind {other}"
        ))),
    }
}

fn parse_local_process_runtime(
    manifest: &Value,
    entry: &serde_json::Map<String, Value>,
    declared: &[DeclaredCapability],
) -> Result<RuntimeEntryPoint> {
    if manifest
        .get("sourceProvenance")
        .and_then(|source| source.get("kind"))
        .and_then(Value::as_str)
        != Some(LOCAL_DIGEST_PINNED)
    {
        return Err(EngineError::PolicyViolation(
            "local_process packages must use local_digest_pinned provenance".to_owned(),
        ));
    }
    reject_raw_secrets(&Value::Object(entry.clone()))?;
    let worker_id = required_map_str(entry, "workerId")?.to_owned();
    let declared_files = resource_version_refs(manifest.get("declaredFiles"), "declaredFiles")?;
    let executable_refs = resource_version_refs(entry.get("executableRefs"), "executableRefs")?;
    if executable_refs.is_empty() {
        return Err(EngineError::PolicyViolation(
            "local_process runtimeEntryPoint.executableRefs must not be empty".to_owned(),
        ));
    }
    for executable_ref in &executable_refs {
        if !declared_files.iter().any(|declared_file| {
            declared_file.resource_id == executable_ref.resource_id
                && declared_file.version_id == executable_ref.version_id
                && declared_file.content_hash == executable_ref.content_hash
        }) {
            return Err(EngineError::PolicyViolation(
                "local_process executableRefs must be declaredFiles refs".to_owned(),
            ));
        }
    }
    let command = required_object(entry.get("commandTemplate"), "commandTemplate")?;
    if required_map_str(command, "kind")? != "materialized_file" {
        return Err(EngineError::PolicyViolation(
            "local_process commandTemplate must target a materialized_file ref".to_owned(),
        ));
    }
    let command_ref = ResourceVersionRef {
        resource_id: required_map_str(command, "resourceId")?.to_owned(),
        version_id: required_map_str(command, "versionId")?.to_owned(),
        content_hash: command
            .get("contentHash")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    };
    if !executable_refs.iter().any(|reference| {
        reference.resource_id == command_ref.resource_id
            && reference.version_id == command_ref.version_id
    }) {
        return Err(EngineError::PolicyViolation(
            "local_process commandTemplate must reference one runtimeEntryPoint.executableRefs entry"
                .to_owned(),
        ));
    }
    let expected_function_ids =
        string_array_from(entry.get("expectedFunctionIds"), "expectedFunctionIds")?;
    if expected_function_ids.is_empty() {
        return Err(EngineError::PolicyViolation(
            "local_process runtimeEntryPoint.expectedFunctionIds must not be empty".to_owned(),
        ));
    }
    let declared_function_ids = declared
        .iter()
        .map(|capability| capability.function_id.as_str().to_owned())
        .collect::<Vec<_>>();
    ensure_same_set(
        &expected_function_ids,
        &declared_function_ids,
        "local_process expectedFunctionIds",
    )?;
    let working_directory = required_object(entry.get("workingDirectory"), "workingDirectory")?;
    if required_map_str(working_directory, "kind")? != "package_file_parent" {
        return Err(EngineError::PolicyViolation(
            "local_process workingDirectory must be package_file_parent".to_owned(),
        ));
    }
    let environment_policy = entry.get("environmentPolicy").cloned().ok_or_else(|| {
        EngineError::PolicyViolation(
            "local_process runtimeEntryPoint requires environmentPolicy".to_owned(),
        )
    })?;
    if environment_policy.get("mode").and_then(Value::as_str) != Some("empty") {
        return Err(EngineError::PolicyViolation(
            "local_process environmentPolicy.mode must be empty".to_owned(),
        ));
    }
    let args = literal_args(entry.get("argsTemplate"))?;
    let visibility = entry
        .get("visibility")
        .and_then(Value::as_str)
        .unwrap_or("session")
        .to_owned();
    if !matches!(visibility.as_str(), "session" | "workspace" | "system") {
        return Err(EngineError::PolicyViolation(format!(
            "unsupported local_process visibility {visibility}"
        )));
    }
    let timeout_ms = entry.get("timeoutMs").and_then(Value::as_u64);
    if timeout_ms.is_some_and(|value| !(100..=60_000).contains(&value)) {
        return Err(EngineError::PolicyViolation(
            "local_process timeoutMs must be between 100 and 60000".to_owned(),
        ));
    }
    Ok(RuntimeEntryPoint::LocalProcess(Box::new(
        LocalProcessRuntime {
            worker_id,
            command_ref,
            executable_refs,
            expected_function_ids,
            args,
            visibility,
            timeout_ms,
            environment_policy,
        },
    )))
}

pub(super) fn resource_version_refs(
    value: Option<&Value>,
    field: &str,
) -> Result<Vec<ResourceVersionRef>> {
    let items = value.and_then(Value::as_array).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an array"))
    })?;
    items
        .iter()
        .map(|item| {
            let object = item.as_object().ok_or_else(|| {
                EngineError::PolicyViolation(format!("{field} entries must be objects"))
            })?;
            Ok(ResourceVersionRef {
                resource_id: required_map_str(object, "resourceId")?.to_owned(),
                version_id: required_map_str(object, "versionId")?.to_owned(),
                content_hash: object
                    .get("contentHash")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            })
        })
        .collect()
}

fn literal_args(value: Option<&Value>) -> Result<Vec<String>> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let items = value
        .as_array()
        .ok_or_else(|| EngineError::PolicyViolation("argsTemplate must be an array".to_owned()))?;
    if items.len() > 64 {
        return Err(EngineError::PolicyViolation(
            "argsTemplate may contain at most 64 entries".to_owned(),
        ));
    }
    items
        .iter()
        .map(|item| {
            let object = item.as_object().ok_or_else(|| {
                EngineError::PolicyViolation("argsTemplate entries must be objects".to_owned())
            })?;
            if object.len() != 1 || !object.contains_key("literal") {
                return Err(EngineError::PolicyViolation(
                    "argsTemplate entries must be literal-only in this phase".to_owned(),
                ));
            }
            required_map_str(object, "literal").map(ToOwned::to_owned)
        })
        .collect()
}

fn parse_effect(value: &str) -> Result<EffectClass> {
    match value {
        "PureRead" | "pure_read" => Ok(EffectClass::PureRead),
        "DeterministicCompute" | "deterministic_compute" => Ok(EffectClass::DeterministicCompute),
        "IdempotentWrite" | "idempotent_write" => Ok(EffectClass::IdempotentWrite),
        "AppendOnlyEvent" | "append_only_event" => Ok(EffectClass::AppendOnlyEvent),
        "ReversibleSideEffect" | "reversible_side_effect" => Ok(EffectClass::ReversibleSideEffect),
        "ExternalSideEffect" | "external_side_effect" => Ok(EffectClass::ExternalSideEffect),
        "IrreversibleSideEffect" | "irreversible_side_effect" => {
            Ok(EffectClass::IrreversibleSideEffect)
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported capability effectClass {other}"
        ))),
    }
}

fn validate_namespace(namespace: &str) -> Result<()> {
    if namespace.trim().is_empty()
        || namespace.contains("::")
        || !namespace
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
    {
        return Err(EngineError::PolicyViolation(format!(
            "invalid package namespace {namespace}"
        )));
    }
    Ok(())
}

pub(super) fn manifest_digest(manifest: &Value) -> Result<String> {
    let mut canonical = manifest.clone();
    if let Some(object) = canonical.as_object_mut() {
        for field in [
            "packageDigest",
            "sourceRef",
            "sourceDigest",
            "sourceTrustStatus",
            "effectiveTrustTier",
            "signature",
            "signatureKeyRef",
            "signatureVerification",
            "sourceEvidenceRefs",
            "sourceApprovalRefs",
            "conformanceEvidenceRefs",
            "policyDiagnostics",
        ] {
            object.remove(field);
        }
    }
    let bytes = serde_json::to_vec(&canonical).map_err(|error| EngineError::LedgerFailure {
        operation: "module.manifest_digest",
        message: error.to_string(),
    })?;
    Ok(format!("sha256:{:x}", Sha256::digest(bytes)))
}
